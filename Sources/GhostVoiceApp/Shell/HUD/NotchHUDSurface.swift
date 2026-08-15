import AppKit
import Foundation
import GhostVoiceCore

/// **notch HUD**（FR-2 / FR-3）。
///
/// ## 配線
///
/// ```
/// session.stateStream()             ┐
/// session.levelStream()             ├→ HUDPresenter（間引き・保持）→ HUDPanel（NSPanel）
/// session.notices()                 │
/// session.assetInstallationEvents() ┘
/// ```
///
/// ## `SessionMirror` を使わない理由
///
/// ミラーは `@Observable` なので、**暫定テキストが届くたびに `state` が変わる。**
/// HUD が `body` からミラーを読むと、`HUDPresenter` の間引きより手前で再描画が走ってしまう
/// （間引きの意味が消える）。**分配器はどれも「呼ぶたびに独立したストリームを返す」**
/// （`SessionBroadcast`）ので、HUD が自分の 1 本を持ってよい——ミラーの購読とは競合しない。
/// 設定画面や履歴画面がミラーを使うことは妨げない。
///
/// ## メインスレッドを塞がないこと
///
/// **メインスレッドを塞ぐと `CGEventTap` の配送が p50 0.045 ms → 12.8 ms へ悪化する**
/// （ランループ検証の実測）。HUD が重くなると PTT の押下・解放の検知が鈍る。ここで守っているのは:
///
/// 1. 録音中の中身の更新を `HUDPresenter` が間引く（最短 50 ms 間隔）
/// 2. `HUDDisplay` が `Equatable` で、**変わっていなければ描画も `setFrame` もしない**
/// 3. **継続アニメーションを 1 つも置かない**（`HUDContentView`）
@MainActor
public final class NotchHUDSurface: AppSurface {

    private let services: AppServices
    private var panel: HUDPanel?
    private var presenter: HUDPresenter
    private var tasks: [Task<Void, Never>] = []
    private var wakeTask: Task<Void, Never>?
    private var scheduledWake: ContinuousClock.Instant?
    private var screenObserver: (any NSObjectProtocol)?
    private var rehearsalTask: Task<Void, Never>?

    /// - Parameter entry: `NSApplication.run()` が始まった後であることの証。
    ///   **この引数がある限り、起動時に非表示の window を用意しておく実装は書けない。**
    public init(_ entry: RunLoopEntry, services: AppServices) {
        self.services = services
        self.presenter = HUDPresenter(
            languageBadge: HUDLanguageBadge.text(
                forLocaleIdentifier: services.settings.settings.localeIdentifier))

        if let placement = HUDPlacement.resolve(screens: HUDScreenSnapshot.current()) {
            panel = HUDPanel(entry, placement: placement)
            // **どこへ出したかを毎回言う。** notch の座標は機体とディスプレイ構成で変わり、
            // 「出ていない」と「見えない場所に出ている」は外からは区別できない。
            AppDiagnostics.note("[HUD] \(placement.diagnosticDescription)")
            if !placement.isOnBuiltInDisplay {
                // FR-3 は「常に内蔵ディスプレイへ」だが、内蔵が無い構成では物理的に果たせない。
                // **黙って外部へ出すと、出ていること自体が誤りに見える。**
                AppDiagnostics.note(
                    "[HUD] 内蔵ディスプレイが見つかりません（クラムシェル）。主ディスプレイのメニューバー直下に表示します。")
            }
        } else {
            AppDiagnostics.note("[HUD] 表示できる画面がありません。HUD は出しません。")
        }

        observeScreenChanges(entry)
        subscribe()

        // **キー監視が始まっていないことは、HUD でしか利用者に見えない。**
        // `.app` を Finder から起動すると標準エラーはどこにも出ない。
        if let failure = services.hotkeyFailure {
            let wake = presenter.announce(
                HUDMessage(text: AppPermissionGuidance.summary(for: failure), severity: .warning),
                hold: .seconds(10), at: .now)
            panel?.render(presenter.display)
            schedule(wake)
        }
    }

    public func teardown() {
        rehearsalTask?.cancel()
        wakeTask?.cancel()
        for task in tasks { task.cancel() }
        tasks = []
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panel?.close()
        panel = nil
    }

    // MARK: - 購読

    private func subscribe() {
        guard let session = services.session else {
            // `--shell-only` / キー監視を開始できなかったとき。**HUD は出るが何も映らない。**
            return
        }
        tasks.append(
            Task { [weak self] in
                for await state in session.stateStream() {
                    guard let self else { return }
                    // **発話の合間にだけ設定を読み直す。** 録音中に読むと、
                    // 暫定テキストが届く回数だけロックを取ることになる。
                    if case .recording = state {} else {
                        self.presenter.languageBadge = HUDLanguageBadge.text(
                            forLocaleIdentifier: self.services.settings.settings.localeIdentifier)
                    }
                    self.handle(.state(state))
                }
            })
        tasks.append(
            Task { [weak self] in
                for await level in session.levelStream() { self?.handle(.level(level)) }
            })
        tasks.append(
            Task { [weak self] in
                for await notice in session.notices() { self?.handle(.notice(notice)) }
            })
        tasks.append(
            Task { [weak self] in
                for await event in session.assetInstallationEvents() {
                    self?.handle(.installation(event))
                }
            })
    }

    // MARK: - 反映

    private func handle(_ event: HUDEvent) {
        if event == .tick { scheduledWake = nil }
        let wake = presenter.apply(event, at: .now)
        panel?.render(presenter.display)
        schedule(wake)
    }

    private func schedule(_ instant: ContinuousClock.Instant?) {
        // **同じ時刻へ何度も張り直さない。** 暫定テキストが届くたびに `Task` を作ると、
        // 間引いた意味が生成と取り消しの費用に消える。
        guard instant != scheduledWake else { return }
        wakeTask?.cancel()
        scheduledWake = instant
        guard let instant else {
            wakeTask = nil
            return
        }
        wakeTask = Task { [weak self] in
            try? await Task.sleep(until: instant, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.handle(.tick)
        }
    }

    // MARK: - ディスプレイ構成の変化

    /// 抜き差し・配置変更で notch の座標は変わる（U-7 / V-22）。
    ///
    /// - Note: **通知が来ることは実測していない**（抜き差しの操作が要る）。
    ///   来なくても、HUD が古い座標に出続けるだけで挿入は壊れない。
    private func observeScreenChanges(_ entry: RunLoopEntry) {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let placement = HUDPlacement.resolve(screens: HUDScreenSnapshot.current())
                else { return }
                if let panel = self.panel {
                    panel.relocate(to: placement)
                } else {
                    // 画面が 1 枚も無い状態から復帰した。**ここも `run()` の後である。**
                    self.panel = HUDPanel(entry, placement: placement)
                    self.panel?.render(self.presenter.display)
                }
            }
        }
    }
}

// MARK: - 目視確認のための素振り

/// `--hud-check` が呼ぶ口。**製品の経路ではない。**
@MainActor
public protocol HUDRehearsing: AnyObject {
    /// 表示を一巡させる。マイクもキー監視も認識も使わない。
    func startRehearsal(seconds: Double, onFinish: @escaping @MainActor () -> Void)
}

extension NotchHUDSurface: HUDRehearsing {

    public func startRehearsal(seconds: Double, onFinish: @escaping @MainActor () -> Void) {
        rehearsalTask?.cancel()
        rehearsalTask = Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                for step in HUDRehearsal.script {
                    guard !Task.isCancelled, ContinuousClock.now < deadline else { break }
                    guard let self else { return }
                    self.panel?.render(step.display)
                    AppDiagnostics.note("[HUD 素振り] \(step.note)")
                    try? await Task.sleep(for: step.duration)
                }
            }
            self?.panel?.render(.hidden)
            AppDiagnostics.note("[HUD 素振り] 終了しました。")
            onFinish()
        }
    }
}

/// 素振りの筋書き。**純粋な値**なので、抜けがないことを検査できる。
public enum HUDRehearsal {

    public struct Step: Sendable, Equatable {
        public let display: HUDDisplay
        public let duration: Duration
        public let note: String
    }

    /// **`HUDDisplay` の全種類を 1 度ずつ通る。**
    ///
    /// 利用者が目視で確かめるもの（README の手順）:
    ///
    /// - 切り欠きの直下に帯が出るか（V-20。**切り欠きそのものに画素があるかは未実測**）
    /// - 切り欠きの左右のメニューバーが隠れていないか
    /// - Space を切り替えても、他アプリをフルスクリーンにしても出続けるか（V-21）
    /// - 外部ディスプレイを繋いでも**内蔵**に出るか（FR-3）
    public static let script: [Step] = [
        Step(
            display: .recording(
                HUDRecording(level: 0.02, languageBadge: "日", volatileText: "")),
            duration: .milliseconds(700), note: "録音中（無音）"),
        Step(
            display: .recording(
                HUDRecording(level: 0.12, languageBadge: "日", volatileText: "これは表示の確認です")),
            duration: .milliseconds(700), note: "録音中（暫定テキストあり）"),
        Step(
            display: .recording(
                HUDRecording(
                    level: 0.22, languageBadge: "日",
                    volatileText: "これは表示の確認です。切り欠きの左右にメニューバーが見えていることを確かめてください")),
            duration: .seconds(1), note: "録音中（大音量・長い暫定テキスト）"),
        Step(display: .processing(.finalizing), duration: .milliseconds(500), note: "確定中"),
        Step(display: .processing(.refining), duration: .milliseconds(500), note: "整形中"),
        Step(display: .processing(.inserting), duration: .milliseconds(500), note: "挿入中"),
        Step(display: .completed, duration: .milliseconds(600), note: "完了（チェックマーク）"),
        Step(display: .processing(.revising), duration: .milliseconds(800), note: "差し替え中（控えめ）"),
        // **文言は Core の 1 箇所から取る**（`SessionFailureNotice` /
        // `SessionNoticeAnnouncement`）。素振りに写しを置くと、Core の文言を直したときに
        // **素振りだけが古い嘘を出し続ける**——実際に R-9 の文言でそうなりかけた（再レビュー B-3）。
        Step(
            display: .message(
                HUDMessage(
                    text: SessionFailureNotice(.noSpeechRecognized).summary, severity: .warning)),
            duration: .seconds(1), note: "エラー"),
        Step(
            display: .message(
                HUDMessage(
                    text: SessionFailureNotice(.refusedSecureInput).summary, severity: .refusal)),
            duration: .seconds(1), note: "拒否（エラーとして出さない）"),
        Step(
            display: .message(HUDMessage(text: Self.lostSummary, severity: .lost)),
            duration: .milliseconds(1200), note: "喪失の疑い（最も強い表示）"),
        Step(display: .hidden, duration: .milliseconds(600), note: "非表示"),
    ]

    /// R-9 の告知の要約。
    ///
    /// **nil にはならない**——`.textMayHaveBeenLost` は「告げない 2 つ」に入っていない
    /// （`SessionNoticeAnnouncementTests` が固定している）。それでも `??` を置くのは、
    /// 素振りの都合で製品コードを `try!` にしないためである。
    private static var lostSummary: String {
        SessionNoticeAnnouncement(.textMayHaveBeenLost)?.summary ?? "入力欄のテキストが失われた可能性があります。"
    }
}

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

    /// **検査のための覗き口。** いま何を出すことになっているか（`HUDPresenter` の結論）。
    var currentDisplayForTests: HUDDisplay { presenter.display }

    /// **検査のための覗き口。** 窓が実際に出ているか。窓を作れていなければ nil。
    ///
    /// **`presenter.display` だけを見る検査では足りない**——2026-08-15 の実機欠陥は
    /// 「出すつもりになっていたか」ではなく「窓が order-in されたか」の側で起きた。
    var panelIsVisibleForTests: Bool? { panel?.isVisibleForTests }

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
            AppDiagnostics.note("[HUD] セッションがありません。HUD は出ますが何も映りません。")
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
                // **ここへ落ちたら HUD は永久に何も映さない。**
                // `SessionBroadcast` は終端後に購読すると即座に終端したものを返すので、
                // 「一度も回らずにここへ来る」形もありうる。**黙って抜けさせない。**
                AppDiagnostics.note("[HUD] 状態の購読が終わりました。以後 HUD は何も映しません。")
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
        // **購読が成立したことを起動時に 1 行で言う。**
        //
        // 分配器は登録済みの購読者にしか配らない（`SessionBroadcast.yield`）。
        // ここが 0 のままなら、録音しても状態は誰にも届かない——
        // **利用者から見れば「HUD がまったく出ない」としか見えず、ログにも何も出なかった**
        // （2026-08-15 の実機欠陥。窓は作られていたのに一度も order-in されていなかった）。
        tasks.append(
            Task { [weak self] in
                // 購読の登録は上の各タスクが最初に走ったときに起きる。1 回譲ってから数える。
                await Task.yield()
                guard self != nil else { return }
                let count = session.stateSubscriberCount
                if count > 0 {
                    AppDiagnostics.note("[HUD] 状態の購読を開始しました（購読者 \(count)）。")
                } else {
                    AppDiagnostics.note(
                        "[HUD] **状態を購読できていません。** 録音しても HUD は何も映しません。")
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

// MARK: - 終了待ち

extension NotchHUDSurface: ShutdownAnnouncingSurface {

    /// **終了待ちを帯に出す。**
    ///
    /// `handle(_:)` を通さないのは、これが `SessionState` の並びに由来しないためである
    /// （`announce(_:hold:at:)` と同じ理由）。**`.idle` でも出る**——
    /// 「`.idle` なら非表示」の規則は「発話が無いときに邪魔をしない」ためのもので、
    /// 終了待ちは発話の有無に関わらず**利用者の行動（キーを離す）を待っている。**
    ///
    /// - Important: **フォーカスは奪わない。** 通る先は `HUDPanel.render` だけで、
    ///   そこは `orderFrontRegardless()`（`makeKeyAndOrderFront` ではない）である。
    ///   利用者は終了待ちの間も挿入先アプリで作業している。
    public func showShutdown(_ announcement: ShutdownAnnouncement) {
        guard let text = announcement.hudText else { return }
        let wake = presenter.announceShutdown(
            HUDMessage(text: text, severity: HUDPresenter.severity(for: announcement.weight)),
            hold: Self.hold(for: announcement), at: .now)
        panel?.render(presenter.display)
        schedule(wake)
    }

    /// どれだけ譲らないか。**秒数は媒体の関心である**（`HUDPresenter.hold` と同じ規律）。
    ///
    /// **どれも要件値ではない。** 待ちの告知は「次の『まだ待っています』が来るまで」を
    /// 覆えばよく、余白の 1 秒は刻みが遅れた回に帯が消えないためだけにある。
    static func hold(for announcement: ShutdownAnnouncement) -> Duration {
        switch announcement {
        case .waiting(let grace): grace + .seconds(1)
        case .stillWaiting(let remaining): min(remaining, Shutdown.heartbeat) + .seconds(1)
        // 打ち切った後はプロセスが畳まれるまでの短い間だけ。
        case .gaveUp, .utteranceInterrupted, .finished: .seconds(8)
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

            // **まず配線を通す。**
            //
            // 素振りが `HUDPanel.render` を直に叩いていた頃、この確認は
            // **`HUDPresenter` も `handle(_:)` も 1 行も通らなかった**——
            // つまり「素振りは出るのに録音では出ない」を切り分けられなかった。
            // ここは製品と同じ経路（`HUDEvent` → `HUDPresenter` → `HUDPanel`）である。
            for step in HUDRehearsal.wiringScript {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { break }
                guard let self else { return }
                AppDiagnostics.note("[HUD 素振り/配線] \(step.note)")
                self.handle(step.event)
                try? await Task.sleep(for: step.duration)
            }

            while !Task.isCancelled, ContinuousClock.now < deadline {
                for step in HUDRehearsal.script {
                    guard !Task.isCancelled, ContinuousClock.now < deadline else { break }
                    guard let self else { return }
                    self.panel?.render(step.display)
                    AppDiagnostics.note("[HUD 素振り] \(step.note)")
                    try? await Task.sleep(for: step.duration)
                }
            }
            // **終了待ちだけは製品とまったく同じ経路で 1 度出す。**
            //
            // 上の `script` は `HUDPanel.render` を直に叩く（見た目の網羅が目的）。
            // ここは `showShutdown` → `HUDPresenter.announceShutdown` → `HUDPanel` と
            // いう本番の経路であり、**「窓の出し入れ」のログもここでしか出ない。**
            // 実機で確かめられるのはこの 1 手である（`--hud-check` の受け入れ条件）。
            if let self, !Task.isCancelled {
                // **先に引っ込める。** 出しっぱなしのまま差し替えると、`HUDPanel` は
                // 「出したとき」にしか矩形と level を言わない（表示の切り替わりでしか
                // 呼ばないのは、暫定テキストの更新回数だけ行を増やさないため）。
                // **終了待ちのための `窓を出しました` を 1 行残す**のがここの目的である。
                self.panel?.render(.hidden)
                try? await Task.sleep(for: .milliseconds(400))
                AppDiagnostics.note("[HUD 素振り/配線] 終了待ち（製品と同じ経路）")
                self.showShutdown(.stillWaiting(remaining: HUDRehearsal.shutdownRemaining))
                try? await Task.sleep(for: .seconds(2))
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

    /// 配線を通す 1 手。**`HUDDisplay` ではなく `HUDEvent` を持つ**——
    /// 製品が受け取るのはこちらであり、`HUDPresenter` を通らない確認は
    /// 「録音では出ない」を一度も捕まえられない。
    public struct EventStep: Sendable, Equatable {
        public let event: HUDEvent
        public let duration: Duration
        public let note: String

        public init(event: HUDEvent, duration: Duration, note: String) {
            self.event = event
            self.duration = duration
            self.note = note
        }
    }

    /// **製品と同じ経路で 1 発話ぶんを通す筋書き。**
    ///
    /// `script` は `HUDPanel` を直に叩く（見た目の網羅が目的）。こちらは
    /// **`stateStream()` から届くのと同じ `HUDEvent` を `handle(_:)` へ入れる**ので、
    /// 「窓は作れているのに録音で出ない」形の欠陥をここで踏める。
    ///
    /// - Important: **`.idle` で終わること。** 終わらないと素振りの後に表示が残る。
    public static let wiringScript: [EventStep] = [
        EventStep(
            event: .state(.recording(volatileText: "")), duration: .milliseconds(600),
            note: "録音開始（状態 → 間引き → 窓）"),
        EventStep(event: .level(0.15), duration: .milliseconds(200), note: "音量が届く"),
        EventStep(
            event: .state(.recording(volatileText: "これは配線の確認です")),
            duration: .milliseconds(600), note: "暫定テキストが届く"),
        EventStep(event: .state(.finalizing), duration: .milliseconds(400), note: "確定中"),
        EventStep(event: .state(.inserting), duration: .milliseconds(400), note: "挿入中"),
        EventStep(
            event: .state(.idle), duration: .milliseconds(800), note: "完了 → 畳む"),
    ]

    /// **`HUDDisplay` の全種類を 1 度ずつ通る。**
    ///
    /// 利用者が目視で確かめるもの（README の手順）:
    ///
    /// - **1 枚の黒い島に見えるか**（切り欠きが島の中に埋まっているか。V-20。
    ///   **切り欠きそのものに画素があるかは未実測**だが、**どちらでも島に見えるはず**である）
    /// - **形が滑らかに広がって縮むか**（畳んだ島 ↔ 広げた島）
    /// - **暫定テキストが複数行見えるか**（最大 `HUDIslandMetrics.volatileLineLimit` 行）
    /// - Space を切り替えても、他アプリをフルスクリーンにしても出続けるか（V-21）
    /// - 外部ディスプレイを繋いでも**内蔵**に出るか（FR-3）
    public static let script: [Step] = [
        Step(
            display: .recording(
                HUDRecording(level: 0.02, languageBadge: "日", volatileText: "")),
            duration: .milliseconds(700), note: "録音中（無音・畳んだ島）"),
        Step(
            display: .recording(
                HUDRecording(level: 0.12, languageBadge: "日", volatileText: "これは表示の確認です")),
            duration: .milliseconds(700), note: "録音中（暫定テキストあり・島が広がる）"),
        Step(
            display: .recording(
                HUDRecording(
                    level: 0.22, languageBadge: "日",
                    volatileText: "これは表示の確認です。島が 1 枚の黒い面に見えているか、切り欠きが島の中に埋まっているかを確かめてください")),
            duration: .seconds(1), note: "録音中（大音量・長い暫定テキスト）"),
        // **複数行が見えることの確認**（利用者の「1 行分しか見えない」への対応）。
        // 上限（`HUDIslandMetrics.volatileLineLimit` 行）を超えても
        // **島がそれ以上高くならない**ことを、ここで目に見える形にしている。
        Step(
            display: .recording(
                HUDRecording(
                    level: 0.18, languageBadge: "日",
                    volatileText:
                        "行数の上限の確認です。ここから長い発話が続きます。暫定テキストは末尾を見せるので、"
                        + "喋るほどに先頭が省略されていきます。上限を超えても島はこれ以上高くなりません。"
                        + "画面を覆わないための決めごとです。")),
            duration: .milliseconds(1400), note: "録音中（行数の上限。島はこれ以上高くならない）"),
        // **縮むところを見せる。** 広がるだけでは形が変わったことが判らない。
        Step(
            display: .recording(
                HUDRecording(level: 0.05, languageBadge: "日", volatileText: "")),
            duration: .milliseconds(700), note: "録音中（無音へ戻る・島が縮む）"),
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
        // **終了待ち。** 実機ではこれが出ないまま利用者が猶予 10 秒を使い切った
        // （2026-08-15）。文言・重さともに Core の 1 箇所から取る。
        Step(
            display: .message(
                HUDMessage(
                    text: Self.shutdownWaitSummary,
                    severity: HUDPresenter.severity(for: Self.shutdownWait.weight))),
            duration: .milliseconds(1200), note: "終了待ち（PTT キーを離してくださいの案内）"),
        Step(display: .hidden, duration: .milliseconds(600), note: "非表示"),
    ]

    /// 素振りで見せる「残り」。**実測ではない。** 目視のための数である。
    public static let shutdownRemaining: Duration = .seconds(9)

    /// 素振りが見せる終了待ちの告知。**文言は Core の 1 箇所から取る。**
    static var shutdownWait: ShutdownAnnouncement { .stillWaiting(remaining: shutdownRemaining) }

    /// **nil にはならない**——`.stillWaiting` は `hudText` を必ず持つ
    /// （`ShutdownAnnouncementTests` が固定している）。`??` を置くのは、
    /// 素振りの都合で製品コードを `try!` にしないためである（`lostSummary` と同じ）。
    static var shutdownWaitSummary: String {
        shutdownWait.hudText ?? "終了待ち: PTT キーを離してください"
    }

    /// R-9 の告知の要約。
    ///
    /// **nil にはならない**——`.textMayHaveBeenLost` は「告げない 2 つ」に入っていない
    /// （`SessionNoticeAnnouncementTests` が固定している）。それでも `??` を置くのは、
    /// 素振りの都合で製品コードを `try!` にしないためである。
    private static var lostSummary: String {
        SessionNoticeAnnouncement(.textMayHaveBeenLost)?.summary ?? "入力欄のテキストが失われた可能性があります。"
    }
}

import Foundation
import Observation
import Synchronization

/// **`DictationSession` の状態を、MainActor から同期で読める写しにする**（調査 A-3 の欠落 2）。
///
/// ## なぜ要るか
///
/// `DictationSession` は actor なので `state` / `isBusy` / `latestMetrics` はすべて
/// `await` が要る。**SwiftUI の `body` は同期なので `await` できない。**
/// 各画面がそれぞれミラーを作ると、同じ `stateUpdates` を 3 人で読むことになり、
/// `AsyncStream` の単一消費者制約に触れて異常終了する（A-4）。**Core に 1 つ置く。**
///
/// ## 使い方
///
/// ```swift
/// @State private var mirror = SessionMirror()
/// // …アプリの起動時に 1 度だけ…
/// mirror.follow(session)          // 購読を始める。手放すと止まる
/// // …SwiftUI の body から…
/// if case .recording(let text) = mirror.state { Text(text) }
/// ```
///
/// ## 何を映していないか（重要）
///
/// - **`isBusy` は「公表された状態」から導いた近似である。** actor 側の `isBusy` は
///   `phase` を見ており、**`phase` が立ってから最初の `emit` までに窓がある**
///   （`DictationSession.isBusy` の注記。実測 1.0〜3.0 ms）。
///   **終了処理はここを見てはならない**——窓の中で「待機だ」と判断してホットキーを
///   止めると、キー解放が二度と届かず**その発話が丸ごと消える。**
///   終了は必ず `await session.isBusy` を見ること。
/// - **`latestMetrics` は `.idle` になった時点で読み直す。** それ以外の状態では
///   前の発話の値が入っていることがある（actor 側と同じ約束。`SessionNarration` も同じ）。
/// - **(a) の分岐では `latestMetrics` が 2 度変わる。** 挿入直後は
///   `refine == 0` / `revision == nil` で、差し替えが終わってから本当の値が入る
///   （`Metrics.Sample.rewriting(refine:revision:)`）。
@MainActor
@Observable
public final class SessionMirror {

    /// 最後に公表された状態。
    public private(set) var state: SessionState = .idle

    /// 発話を抱えていそうか。**近似である**（上の「何を映していないか」）。
    public private(set) var isBusy: Bool = false

    /// 直近の発話の計測値。`.idle` のたびに読み直す。
    public private(set) var latestMetrics: Metrics.Sample?

    /// いま Undo で戻せるものがあるか（FR-7。「戻す」ボタンの活性）。
    public private(set) var canUndo: Bool = false

    /// 直近の通知（差し替え・Undo の顛末）。**表示したら `clearNotice()` で畳むこと。**
    public private(set) var notice: SessionNotice?

    /// マイク音量（RMS）。**録音していない間は 0 に戻す。**
    public private(set) var level: Float = 0

    /// モデル導入の進み具合。導入が走っていなければ nil。
    public private(set) var installation: AssetInstallationEvent?

    /// **`nonisolated` にしてある。** `deinit` は MainActor の外から呼ばれうるので、
    /// そこからも取り消せる必要がある（放置すると、画面が消えた後も購読タスクが残る）。
    private nonisolated let tasks = Mutex<[Task<Void, Never>]>([])

    public init() {}

    deinit {
        for task in tasks.withLock({ $0 }) { task.cancel() }
    }

    /// **セッションの購読を始める。プロセスにつき 1 回だけ呼ぶこと。**
    ///
    /// 2 回呼ぶと購読が二重になる（`AsyncStream` の制約には触れないが、
    /// 同じ値が 2 度届いて無駄な再描画が起きる）。既に購読していれば何もしない。
    ///
    /// - Important: **`session.run()` より前に呼んでよい。** 分配器は購読者が
    ///   居なくても壊れない。`run()` が戻ると購読は自然に終わる。
    public func follow(_ session: DictationSession) {
        guard tasks.withLock({ $0.isEmpty }) else { return }
        var started: [Task<Void, Never>] = []

        started.append(
            Task { [weak self] in
                for await state in session.stateStream() {
                    guard let self else { return }
                    self.apply(state, from: session)
                }
            })
        started.append(
            Task { [weak self] in
                for await level in session.levelStream() { self?.level = level }
            })
        started.append(
            Task { [weak self] in
                for await notice in session.notices() {
                    guard let self else { return }
                    self.notice = notice
                    self.canUndo = await session.canUndo
                }
            })
        started.append(
            Task { [weak self] in
                for await event in session.assetInstallationEvents() {
                    self?.installation = event
                }
            })
        tasks.withLock { $0 = started }
    }

    /// 購読をやめる。**二度呼んでも安全。**
    public func stop() {
        let running = tasks.withLock { current -> [Task<Void, Never>] in
            let all = current
            current.removeAll()
            return all
        }
        for task in running { task.cancel() }
    }

    /// 表示し終えた通知を畳む。
    public func clearNotice() { notice = nil }

    private func apply(_ state: SessionState, from session: DictationSession) {
        self.state = state
        switch state {
        case .idle:
            isBusy = false
            // **録音が終わったら音量を落とす。** タップが外れると値が来なくなるだけで、
            // 「無音の 0」は流れてこない。残しておくとインジケータが振れたまま止まる。
            level = 0
        case .recording, .finalizing, .refining, .inserting:
            isBusy = true
        case .revising:
            // **差し替えは「忙しい」に数えない**（設計 opus §3.3）。
            // 保留中でも次の PTT は受け付けられる。
            isBusy = false
        case .failed:
            isBusy = true  // 直後に必ず `.idle` が続く
        }
        // **`.idle` のときにしか計測値を読み直さない。** `.recording` は暫定テキストの
        // たびに来るので（長い発話では数百件）、そこで actor へ問い合わせると
        // **actor を暫定表示の回数だけ叩く**ことになる。約束は `SessionNarration` と同じ。
        guard case .idle = state else { return }
        Task { [weak self] in
            let metrics = await session.latestMetrics
            let canUndo = await session.canUndo
            guard let self else { return }
            self.latestMetrics = metrics
            self.canUndo = canUndo
        }
    }
}

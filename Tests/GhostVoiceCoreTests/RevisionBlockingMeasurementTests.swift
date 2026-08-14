import ApplicationServices
import Foundation
import Synchronization
import Testing

@testable import GhostVoiceCore

/// **V-36 の実測: 差し替えが PTT をどれだけ待たせるか。**
///
/// **これが答えを出した問い**（トラック A4 の懸念 1。当時の文言をそのまま引く）:
///
/// > 差し替えは actor 上で同期に走る。**PTT と重なると `startRecording` を待たせる**
/// > （NFR-P1 の 50 ms を食う）。所要は未実測。
///
/// **結論（実測 2026-08-15）**: 代役の欄に対しては**最大 3.5 ms で予算を食わない。**
/// 待たされる量はほぼ `12 × AX 1 往復 + 2 ms` なので、
/// **1 往復が約 4 ms を超える相手では 50 ms を破る**（詳細設計書 §10.1）。
///
/// `applyRevision` は actor の上で
/// **履歴の書き込み（ディスク）→ `replacer.replace`（AX の往復 5〜8 回）** を
/// 同期に行う。その間、**actor 隔離の呼び出しはすべて待たされる**——
/// `startRecording` も `state` の読みも同じである。
///
/// ## 測り方
///
/// 別のタスクから `await session.state` を叩き続け、**1 回ごとの実所要**を記録する。
/// `state` は actor 隔離なので、**差し替えが actor を握っている間はここが待たされる。**
/// 待たされた量がそのまま「PTT が押されていたら待たされたはずの量」である。
///
/// **`startRecording` そのものを測らないのは、押下の瞬間を差し替えの最中へ
/// 当てる必要があり、当たったか外れたかを標本から区別できないため。**
/// 探り針なら窓の全体を舐めるので、**最大値が意味を持つ。**
///
/// ## 何を通しているか
///
/// | 部品 | 本物か |
/// |---|---|
/// | `DictationSession` / `TextReplacer` / `HistoryStore`（**ディスク書き込み**） | **本物** |
/// | 認識・整形 | 代役（所要を固定して窓を作るため） |
/// | AX の相手 | **代役の欄。** 実アプリの往復コストは別項で外挿する |
/// | 挿入先のアプリ | **代役。実機のアプリへは 1 文字も書かない** |
///
/// `GHOST_VOICE_E_MEASURE=1` を付けたときだけ走る。
@Suite(
    "E: 差し替えが actor を握る時間（V-36）",
    .serialized,
    .enabled("GHOST_VOICE_E_MEASURE=1 を付けると実行される") {
        ProcessInfo.processInfo.environment["GHOST_VOICE_E_MEASURE"] == "1"
    }
)
struct RevisionBlockingMeasurement {

    static let passes = 5

    @Test("低負荷と負荷下で、差し替えが actor 隔離の呼び出しを待たせる量を測る")
    func measuresBlocking() async throws {
        for loaded in [false, true] {
            let load = loaded ? BackgroundLoad(workers: 16) : nil
            defer { load?.stop() }
            if loaded { try await Task.sleep(for: .milliseconds(500)) }

            for injectedPerCall in [Duration.zero, .milliseconds(2), .milliseconds(10)] {
                let result = try await run(injectedPerCall: injectedPerCall)
                let label = loaded ? "負荷下" : "低負荷"
                print(
                    "=== \(label) / AX 1 回あたりの注入 \(Self.micros(injectedPerCall)) ms ==="
                )
                print("  AX 呼び出し回数: 挿入 \(result.axCallsPerInsertion) 回"
                      + " / **差し替え \(result.axCallsPerRevision) 回**")
                print("  待たされた量 中央値: \(Self.micros(result.median)) ms")
                print("  待たされた量 **最大**: \(Self.micros(result.maximum)) ms")
                print("  標本数: \(result.sampleCount) / 差し替え \(result.revisions) 回")
            }
        }
    }

    /// **押下 → 録音開始を直接測る。** 探り針は代理量なので、
    /// 「PTT を差し替えの最中に押したら実際どうなるか」をもう一度別の形で確かめる。
    ///
    /// 押下の瞬間は**差し替えの最初の AX 呼び出しに合わせて撃つ**（時計で狙わない）。
    /// これが待たされる量の最大に当たる。
    @Test("差し替えの最中に PTT を押したときの 押下 → 録音開始")
    func measuresPressDuringRevision() async throws {
        for loaded in [false, true] {
            let load = loaded ? BackgroundLoad(workers: 16) : nil
            defer { load?.stop() }
            if loaded { try await Task.sleep(for: .milliseconds(500)) }

            for injectedPerCall in [Duration.zero, .milliseconds(2), .milliseconds(10)] {
                let samples = try await pressDuringRevision(injectedPerCall: injectedPerCall)
                let sorted = samples.sorted()
                print(
                    "=== \(loaded ? "負荷下" : "低負荷") / AX 1 回あたりの注入 "
                    + "\(Self.micros(injectedPerCall)) ms ===")
                print("  押下 → 録音開始: " + sorted.map(Self.micros).joined(separator: ", ") + " ms")
                print("  中央値 \(Self.micros(sorted[sorted.count / 2])) ms"
                      + " / **最大 \(Self.micros(sorted[sorted.count - 1])) ms**"
                      + "（NFR-P1 は 50 ms）")
            }
        }
    }

    private func pressDuringRevision(injectedPerCall: Duration) async throws -> [Duration] {
        var samples: [Duration] = []
        try await withTempRoot { root in
            let accessibility = LatencyInjectingAccessibility(
                BlockingWorld.accessibility(for: BlockingWorld.freshField()),
                perCall: injectedPerCall)
            let settings = SettingsStore(rootURL: root)
            try settings.update { $0.refinementApplyMode = .afterInsert }
            let hotkey = StubHotkeyMonitor()
            let history = HistoryStore(rootURL: root, limit: 200)
            let session = DictationSession(
                settings: settings,
                hotkey: hotkey,
                audio: StubAudioCapture(),
                transcriber: StubTranscriber(finalText: "えー、整形される発話です"),
                refiner: StubRefiner(result: "整形された発話です。", delay: .milliseconds(200)),
                insertion: BlockingWorld.stack(accessibility: accessibility),
                history: history,
                vocabulary: VocabularyStore(rootURL: root),
                isSecureInputEnabled: { false },
                postEventAuthorization: PostEventAuthorization(probe: { false })
            )
            let notices = NoticeLog()
            let collector = notices.follow(session)
            defer { collector.cancel() }
            let run = Task { await session.run() }
            defer { run.cancel() }

            for pass in 1...Self.passes {
                let baseline = history.entries.count
                hotkey.emit(.pressed)
                try await waitUntil("\(pass) 回目の録音が始まる") {
                    if case .recording = await session.state { return true }
                    return false
                }
                hotkey.emit(.released)
                // **挿入が終わった時点で仕掛ける。**「`.idle` になったら」で待つと、
                // (a) の分岐は挿入直後と差し替え後の 2 回 `.idle` になるので、
                // 2 回目を掴んだ標本は「差し替えの最中に押せなかった」まま
                // 30 秒待って落ちる（対処前後の両方で観測した）。
                // 履歴に載るのは挿入の直後・差し替えの開始より前なので、ここが唯一の
                // 「必ず差し替えより前」の目印である。**この発話ぶんが増えたことを見る**
                // （件数の絶対値で見ると、前の周回の分で既に成立していて早すぎる）。
                try await waitUntil("\(pass) 回目の挿入が終わる", timeout: .seconds(30)) {
                    history.entries.count > baseline
                }

                let pressedAt = PressStamp()
                accessibility.arm {
                    pressedAt.stamp()
                    hotkey.emit(.pressed)
                }
                try await waitUntil("\(pass) 回目の再録音が始まる", timeout: .seconds(30)) {
                    if case .recording = await session.state { return true }
                    return false
                }
                let started = ContinuousClock.now
                samples.append(started - (pressedAt.value ?? started))

                hotkey.emit(.released)
                try await waitUntil("\(pass) 回目の後始末", timeout: .seconds(30)) {
                    await session.state == .idle && notices.notices.count >= pass
                }
                accessibility.rebind(BlockingWorld.accessibility(for: BlockingWorld.freshField()))
            }
        }
        return samples
    }

    /// ミリ秒を小数 3 桁で。`Metrics.milliseconds` は整数へ丸めるので、
    /// **1 ms 未満の量が全部 0 になって「握っていない」と読めてしまう。**
    static func micros(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.3f", value)
    }

    private struct Result {
        var median: Duration
        var maximum: Duration
        var sampleCount: Int
        var revisions: Int
        var axCallsPerRevision: Int
        var axCallsPerInsertion: Int
    }

    private func run(injectedPerCall: Duration) async throws -> Result {
        var samples: [Duration] = []
        var revisions = 0
        var axCalls = 0
        var insertCalls = 0
        var axInsertCalls = 0

        try await withTempRoot { root in
            let field = BlockingWorld.freshField()
            let accessibility = LatencyInjectingAccessibility(
                BlockingWorld.accessibility(for: field), perCall: injectedPerCall)
            let settings = SettingsStore(rootURL: root)
            try settings.update { $0.refinementApplyMode = .afterInsert }
            let hotkey = StubHotkeyMonitor()
            let transcriber = StubTranscriber(finalText: "えー、整形される発話です")
            let history = HistoryStore(rootURL: root, limit: 200)
            let stack = BlockingWorld.stack(accessibility: accessibility)
            let session = DictationSession(
                settings: settings,
                hotkey: hotkey,
                audio: StubAudioCapture(),
                transcriber: transcriber,
                refiner: StubRefiner(result: "整形された発話です。", delay: .milliseconds(200)),
                insertion: stack,
                history: history,
                vocabulary: VocabularyStore(rootURL: root),
                isSecureInputEnabled: { false },
                postEventAuthorization: PostEventAuthorization(probe: { false })
            )
            let notices = NoticeLog()
            let collector = notices.follow(session)
            defer { collector.cancel() }
            let run = Task { await session.run() }
            defer { run.cancel() }

            let probe = ProbeLog()
            for pass in 1...Self.passes {
                hotkey.emit(.pressed)
                try await waitUntil("\(pass) 回目の録音が始まる") {
                    if case .recording = await session.state { return true }
                    return false
                }
                let callsAtRelease = accessibility.callCount
                hotkey.emit(.released)
                // **挿入が終わって待機へ戻るまでは測らない。** そこまでの actor の
                // 占有は確定と挿入のもので、V-36 が問うている差し替えとは別である。
                try await waitUntil("\(pass) 回目が待機へ戻る", timeout: .seconds(30)) {
                    await session.state == .idle
                }
                insertCalls = accessibility.callCount - callsAtRelease

                // **探り針。** actor 隔離の呼び出しの実所要を、保留中の差し替えの窓だけで測る。
                let callsBefore = accessibility.callCount
                let prober = Task {
                    while !Task.isCancelled {
                        let start = ContinuousClock.now
                        _ = await session.state
                        probe.record(ContinuousClock.now - start)
                        try? await Task.sleep(for: .microseconds(200))
                    }
                }
                try await waitUntil("\(pass) 回目の差し替えが終わる", timeout: .seconds(30)) {
                    notices.notices.count == pass
                }
                prober.cancel()
                axCalls = accessibility.callCount - callsBefore
                revisions += 1
                // **発話ごとに欄を空へ戻す。** 溜め込むと範囲の算術が長くなって計測に混ざる。
                accessibility.rebind(BlockingWorld.accessibility(for: BlockingWorld.freshField()))
            }

            samples = probe.samples
            axInsertCalls = insertCalls
        }

        let sorted = samples.sorted()
        return Result(
            median: sorted.isEmpty ? .zero : sorted[sorted.count / 2],
            maximum: sorted.last ?? .zero,
            sampleCount: sorted.count,
            revisions: revisions,
            axCallsPerRevision: axCalls,
            axCallsPerInsertion: axInsertCalls
        )
    }
}

/// 計測用の世界。**差し替えが必ず成立する素直な欄**を用意する
/// （相手アプリの当たり外れは V-28 の担当で、ここで測りたいのは actor を握る時間である）。
enum BlockingWorld {

    static let ownProcess: pid_t = 4_242
    static let targetProcess: pid_t = 424_242

    static func freshField() -> FakeTextField {
        FakeTextField(content: "", selection: AXTextRange(location: 0, length: 0))
    }

    static func accessibility(for field: FakeTextField) -> any ReplacementCapableAccessibility {
        let element = FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: true,
            processIdentifier: targetProcess, acceptsWrite: true,
            isSelectedTextRangeSettable: true, identity: UUID()
        )
        return SwitchingAccessibility(FakeAccessibility(focused: element, field: field))
    }

    static func stack(accessibility: any ReplacementCapableAccessibility) -> InsertionStack {
        let epoch = InsertionEpoch()
        let clipboard = StubClipboard()
        let inserter = CompositeInserter(
            primary: AccessibilityInserter(
                accessibility: accessibility, ownProcessIdentifier: ownProcess, epoch: epoch),
            fallback: StubInserter(canInsert: false, succeeds: false),
            lastResort: clipboard,
            epoch: epoch,
            isSecureInputEnabled: { false }
        )
        let replacer = TextReplacer(
            accessibility: accessibility, clipboard: clipboard, epoch: epoch,
            ownProcessIdentifier: ownProcess, isSecureInputEnabled: { false }
        )
        return InsertionStack(inserter: inserter, replacer: replacer, clipboard: clipboard)
    }
}

/// 押下した瞬間の記録。
final class PressStamp: Sendable {
    private let storage = Mutex<ContinuousClock.Instant?>(nil)
    func stamp() { storage.withLock { $0 = ContinuousClock.now } }
    var value: ContinuousClock.Instant? { storage.withLock { $0 } }
}

/// 探り針の記録。
final class ProbeLog: Sendable {
    private let storage = Mutex<[Duration]>([])
    func record(_ value: Duration) { storage.withLock { $0.append(value) } }
    var samples: [Duration] { storage.withLock { $0 } }
}

/// AX の 1 呼び出しごとに固定の遅れを入れる包み。
///
/// **代役の欄は AX の往復を払わない。** 実アプリでは 1 属性あたり数 ms〜数十 ms 掛かる
/// （要件定義書 §2.8.5 の実測: Chrome アドレスバーへの挿入 12〜34 ms、メモ 307 ms）。
/// ここで既知の量を注入して、**握る時間が往復コストにどう比例するか**を測る。
///
/// 遅れは `Thread.sleep` で入れる。**await にしてはならない**——
/// 実際の AX の往復は同期呼び出しでスレッドを塞ぐので、
/// 中断点を作ると測りたい性質（actor を握り続けること）が消える。
final class LatencyInjectingAccessibility: ReplacementCapableAccessibility, @unchecked Sendable {

    private let inner: Mutex<any ReplacementCapableAccessibility>
    private let perCall: Duration
    private let calls = Mutex(0)
    /// 次の 1 回目の呼び出しで撃つ合図。**差し替えの開始点そのもの**を掴むために要る
    /// （外から時計で狙うと、当たったか外れたかを標本から区別できない）。
    private let armed: Mutex<(@Sendable () -> Void)?> = Mutex(nil)

    init(_ initial: any ReplacementCapableAccessibility, perCall: Duration) {
        self.inner = Mutex(initial)
        self.perCall = perCall
    }

    /// 次の AX 呼び出しの**直前**に 1 度だけ呼ぶ。
    func arm(_ action: @escaping @Sendable () -> Void) { armed.withLock { $0 = action } }

    func rebind(_ next: any ReplacementCapableAccessibility) {
        inner.withLock { $0 = next }
    }

    var callCount: Int { calls.withLock { $0 } }

    private func toll<R>(_ body: (any ReplacementCapableAccessibility) -> R) -> R {
        calls.withLock { $0 += 1 }
        if let action = armed.withLock({ current -> (@Sendable () -> Void)? in
            defer { current = nil }
            return current
        }) { action() }
        if perCall > .zero {
            Thread.sleep(forTimeInterval: Double(perCall.components.attoseconds) / 1e18
                         + Double(perCall.components.seconds))
        }
        return inner.withLock { body($0) }
    }

    func focusedElement() -> (any FocusedElement)? { toll { $0.focusedElement() } }
    func role(of element: any FocusedElement) -> String? { toll { $0.role(of: element) } }
    func isSelectedTextSettable(_ element: any FocusedElement) -> Bool {
        toll { $0.isSelectedTextSettable(element) }
    }
    func processIdentifier(of element: any FocusedElement) -> pid_t? {
        toll { $0.processIdentifier(of: element) }
    }
    func setSelectedText(_ text: String, on element: any FocusedElement) -> Bool {
        toll { $0.setSelectedText(text, on: element) }
    }
    func isSelectedTextRangeSettable(_ element: any FocusedElement) -> Bool {
        toll { $0.isSelectedTextRangeSettable(element) }
    }
    func selectedRange(of element: any FocusedElement) -> AXTextRange? {
        toll { $0.selectedRange(of: element) }
    }
    func setSelectedRange(_ range: AXTextRange, on element: any FocusedElement) -> Bool {
        toll { $0.setSelectedRange(range, on: element) }
    }
    func matches(_ expected: String, in range: AXTextRange, of element: any FocusedElement)
        -> RangeMatch
    {
        toll { $0.matches(expected, in: range, of: element) }
    }
    func isSameElement(_ lhs: any FocusedElement, _ rhs: any FocusedElement) -> Bool {
        toll { $0.isSameElement(lhs, rhs) }
    }
}

/// 計測の 2 条件目を作る背景負荷。**必ず止める**（`defer` で `stop()`）。
final class BackgroundLoad: Sendable {

    private let processes: Mutex<[Process]> = Mutex([])

    init(workers: Int) {
        var started: [Process] = []
        for _ in 0..<workers {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { started.append(process) }
        }
        processes.withLock { $0 = started }
    }

    func stop() {
        let running = processes.withLock { current -> [Process] in
            defer { current = [] }
            return current
        }
        for process in running {
            process.terminate()
            process.waitUntilExit()
        }
    }
}

// MARK: - 常時走る退行検知（計測ではない）

/// **差し替えが actor を握り続けていないことを、毎回の `swift test` で見る。**
///
/// V-36 の実測（2026-08-15 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2 / 各 5 標本）:
///
/// | AX 1 往復の注入 | 押下 → 録音開始（最大） 対処前 → **対処後** |
/// |---|---|
/// | 0 ms（代役の欄） | 1.9 / 2.5 ms → **2.7 / 2.6 ms** |
/// | 2 ms | 39.1 / 37.9 ms → **2.0 / 2.2 ms** |
/// | 10 ms | 164.2 / 170.0 ms → **3.1 / 3.0 ms** |
///
/// （各セルは 低負荷 / 負荷下。負荷は `yes` 16 本）
///
/// **対処前は「待たされる量 ≒ 12 × AX 1 往復」だった**——差し替えを
/// `DictationSession` の actor 上で同期に走らせていたためである。AX の往復の上限は
/// 1 回 0.5 秒なので、**固まった相手では最大約 6 秒 actor が塞がり、
/// その間 PTT の押下も解放も処理されない**（＝喋っているのに録音が始まらず、
/// 発話が丸ごと落ちる。最終レビュー 視点3 の指摘 2）。
///
/// **対処後は往復コストに依存しない。** 差し替えは actor を手放して走り
/// （`DictationSession.runOffActor`）、挿入との重なりは世代の錠
/// （`InsertionEpoch.withExclusiveWrite`）が塞ぐ。
///
/// ここが守るのは**その性質そのもの**——
/// **AX が遅い相手でも押下が待たされないこと**である。
/// だから注入 0 ms では測らない（対処前でも通ってしまい、何も掴めない）。
///
/// ## 線の引き直し（2026-08-15。再レビュー C-1 と同じ形の欠陥だった）
///
/// **注入 10 ms・線 25 ms では、全件並列実行の裾で落ちた**——実観測 173.4 ms（1 回）。
/// 25 ms は「対処後の実測 3 ms」に対しては十分でも、**対処前の信号（164 ms）と
/// 並列実行の雑音（173 ms）が重なっていた**ので、線をどこへ動かしても
/// 「雑音で落ちる」か「退行を見逃す」のどちらかになる。**信号の側を大きくして離す。**
///
/// **注入を 40 ms にした**（対処前の待ち ≒ 12 往復 × 40 ms ≒ 480 ms）。
/// 対処後は往復コストに依存しないので、実測は 10 ms のときと変わらない:
///
/// | 条件 | 回数 | 押下 → 録音開始 |
/// |---|---|---|
/// | 低負荷・この検査だけ（注入 40 ms） | 3 | 1.40 / 1.44 / 1.92 ms |
/// | 全件並列（注入 40 ms） | 3 | 2.11 / 2.24 / 2.28 ms |
/// | 全件並列（注入 10 ms。引き直す前） | 8 | 0.04〜2.89 ms（**別に 173.4 ms が 1 回**） |
///
/// **線は 250 ms（壊れ検知であって要件値ではない）。** 実測の最大 2.3 ms の約 100 倍、
/// 観測された最悪の雑音 173 ms より上、**対処前の信号 480 ms のおよそ半分**なので、
/// **actor を握る実装へ戻した瞬間に赤くなる。**
/// 要件は NFR-P1 の 50 ms で、それを見るのは実アプリでの計測（V-36 / V-28）である。
@Suite("差し替えが PTT を待たせないこと（V-36 の退行検知）")
struct RevisionBlockingRegressionTests {

    @Test("AX が遅い相手でも、差し替えの最中の押下から録音開始までが壊れ検知の線を割らない")
    func pressDuringRevisionStaysResponsive() async throws {
        try await withTempRoot { root in
            // **1 往復 40 ms を注入する。** 0 ms だと差し替えが actor を握っていても
            // 通ってしまい、この検査は何も掴まない（対処前の実測 2.5 ms）。
            // 10 ms では対処前の信号（164 ms）が並列実行の雑音（実観測 173 ms）に
            // 埋もれたので、**信号の側を大きくして離した**（上の表）。
            let accessibility = LatencyInjectingAccessibility(
                BlockingWorld.accessibility(for: BlockingWorld.freshField()),
                perCall: .milliseconds(40))
            let settings = SettingsStore(rootURL: root)
            try settings.update { $0.refinementApplyMode = .afterInsert }
            let hotkey = StubHotkeyMonitor()
            let history = HistoryStore(rootURL: root, limit: 20)
            let session = DictationSession(
                settings: settings,
                hotkey: hotkey,
                audio: StubAudioCapture(),
                transcriber: StubTranscriber(finalText: "えー、整形される発話です"),
                refiner: StubRefiner(result: "整形された発話です。", delay: .milliseconds(50)),
                insertion: BlockingWorld.stack(accessibility: accessibility),
                history: history,
                vocabulary: VocabularyStore(rootURL: root),
                isSecureInputEnabled: { false },
                postEventAuthorization: PostEventAuthorization(probe: { false })
            )
            let run = Task { await session.run() }
            defer { run.cancel() }

            hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await session.state { return true }
                return false
            }
            hotkey.emit(.released)
            // **挿入が終わった時点で仕掛ける。** (a) の分岐は挿入直後と差し替え後の
            // 2 回 `.idle` になるので、`.idle` で待つと 2 回目を掴んで
            // 「差し替えの最中に押せなかった」まま落ちうる。履歴に載るのは
            // 挿入の直後・差し替えの開始より前なので、ここが唯一の確かな目印である。
            try await waitUntil("挿入が終わる", timeout: .seconds(30)) {
                !history.entries.isEmpty
            }

            // **差し替えの最初の AX 呼び出しに合わせて押す。** 時計で狙うと
            // 当たったか外れたかを結果から区別できない（外れれば必ず速いので、
            // 検査が何も掴んでいないことに気づけない）。
            let pressedAt = PressStamp()
            accessibility.arm {
                pressedAt.stamp()
                hotkey.emit(.pressed)
            }
            try await waitUntil("再び録音が始まる", timeout: .seconds(30)) {
                if case .recording = await session.state { return true }
                return false
            }
            let started = ContinuousClock.now
            let pressed = try #require(pressedAt.value, "差し替えの最中に押せていない")
            let elapsed = started - pressed

            hotkey.emit(.released)
            try await waitUntil("後始末", timeout: .seconds(30)) { await session.state == .idle }

            print("V-36 退行検知: 押下から録音開始まで \(elapsed)")
            #expect(
                elapsed < .milliseconds(250),
                "差し替えが actor を握る時間が伸びている（線は壊れ検知。要件 NFR-P1 は 50 ms）: \(elapsed)")
        }
    }
}

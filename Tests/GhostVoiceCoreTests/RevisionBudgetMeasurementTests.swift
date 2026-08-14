import AVFAudio
import ApplicationServices
import Foundation
import Synchronization
import Testing

@testable import GhostVoiceCore

extension SpeechDependentTests {

    /// **(a) と (b) の実分布を、同じ機体・同じ発話で並べて測る**（トラック A4 の受け入れ条件 5）。
    ///
    /// これを測るまで **(b) の打ち切り（`refinementTimeoutMs`）を動かしてはならない。**
    /// フェーズ 1 で 500 ms を動かさなかったのと同じ理由である——
    /// 分布を見ずに既定値を動かすのは、推定値の上に実装を積むのと変わらない。
    ///
    /// ## 何を通しているか
    ///
    /// | 部品 | 本物か |
    /// |---|---|
    /// | 認識（`SpeechAnalyzerTranscriber`） | **本物。** フィクスチャ音声を実時間で流す |
    /// | 整形（`FoundationModelRefiner`） | **本物。** Apple Intelligence を実際に回す |
    /// | 挿入と差し替え（`AccessibilityInserter` / `TextReplacer`） | **本物。** ただし相手は代役の欄 |
    /// | マイク | 代役（**開かない**。台本どおりに喋らせられない） |
    /// | 挿入先のアプリ | **代役（`FakeTextField`）。実機のアプリへは 1 文字も書かない** |
    /// | クリップボード | 代役（`StubClipboard`。`NSPasteboard.general` に触れない） |
    ///
    /// ## 発話長を変える理由
    ///
    /// **既定 750 ms を決めたときの実測はすべて 3 秒の発話だった**（要件定義書 §2.8.4 (2)）。
    /// 実機の肉声では 40 字以上の 8 件がすべて打ち切られており、
    /// **「入力が長ければ生成も長くかかる」という依存が条件に入っていなかった。**
    /// ここは発話長を変えて測る。**NFR-P6b の 2 秒 / 3 秒の根拠（V-25）にも当たる。**
    ///
    /// ## 既定の `swift test` では走らない
    ///
    /// 実認識と実 LLM を何十回も回すので数分掛かり、**機体を飽和させる。**
    /// 実時間を閾値にしている既存の検査は、飽和した条件で `Task.sleep` のタイマー配送が
    /// 遅れると落ちる。計測は必要なときに明示的に回すものである
    /// （`GHOST_VOICE_MEASURE` が確立した opt-in の前例に倣うが、
    /// **別の変数にしてある**——あちらは (b) だけを測る既存の計測で、目的が違う）。
    @Suite(
        "A4: (a)/(b) の実分布と (b) の打ち切りの引き直し",
        .enabled("GHOST_VOICE_A4_MEASURE=1 を付けると実行される") {
            ProcessInfo.processInfo.environment["GHOST_VOICE_A4_MEASURE"] == "1"
        },
        .enabled("音声フィクスチャが要る") { SpeechFixtures.audioExists },
        .enabled(if: FoundationModelRefiner().isAvailable, "Apple Intelligence が要る")
    )
    struct RevisionBudgetMeasurement {

        /// 1 発話に流す音声の長さ。**3 秒だけで決めた既定値を疑うための軸である。**
        static let utteranceSeconds: [Double] = [3, 6, 10]
        static let sampleCount = 5

        @Test("(a) と (b) の M5a / M3 / M6 を発話長ごとに実測する")
        func measuresBothBranches() async throws {
            for seconds in Self.utteranceSeconds {
                for mode in [RefinementApplyMode.beforeInsert, .afterInsert] {
                    let (samples, lengths, applied) = try await run(seconds: seconds, mode: mode)
                    report(
                        samples, seconds: seconds, mode: mode, lengths: lengths, applied: applied)
                }
            }
        }

        private func run(
            seconds: Double, mode: RefinementApplyMode
        ) async throws -> ([Metrics.Sample], [Int], Int) {
            let transcriber = SpeechAnalyzerTranscriber()
            try await transcriber.prepare(locale: .jaJP, kind: .dictation)
            let format = try #require(await transcriber.requiredAudioFormat)
            let buffers = try SpeechFixtures.buffers(
                from: SpeechFixtures.audioURL, to: format, limitSeconds: seconds)

            let refiner = FoundationModelRefiner()
            // 初回の respond はモデルのロードを含んで実測 3.3 秒。計測に混ぜない。
            await refiner.prewarm()

            var samples: [Metrics.Sample] = []
            var lengths: [Int] = []
            var applied = 0
            try await withTempRoot { root in
                let world = MeasurementWorld()
                let settings = SettingsStore(rootURL: root)
                try settings.update {
                    $0.refinementApplyMode = mode
                    // **打ち切りは既定のまま測る。** 引き直しは分布を見てから決める。
                    $0.refinementTimeoutMs = Settings.default.refinementTimeoutMs
                    $0.revisionDeadlineMs = Settings.default.revisionDeadlineMs
                }
                let hotkey = StubHotkeyMonitor()
                let audio = ReplayAudioCapture(buffers: buffers, interval: .milliseconds(100))
                let history = HistoryStore(rootURL: root, limit: 200)
                let session = DictationSession(
                    settings: settings,
                    hotkey: hotkey,
                    audio: audio,
                    transcriber: transcriber,
                    refiner: refiner,
                    insertion: world.stack,
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

                for pass in 1...Self.sampleCount {
                    hotkey.emit(.pressed)
                    try await waitUntil("\(pass) 回目の録音が始まる") {
                        if case .recording = await session.state { return true }
                        return false
                    }
                    await audio.waitForPlayback()
                    hotkey.emit(.released)
                    try await waitUntil("\(pass) 回目が待機へ戻る", timeout: .seconds(60)) {
                        await session.state == .idle
                    }
                    if mode == .afterInsert {
                        // **(a) は挿入の後に差し替えが走る。** 顛末が出るまで待たないと
                        // M3 も M6 も入らない標本を数えてしまう。
                        try await waitUntil("\(pass) 回目の差し替えが終わる", timeout: .seconds(60)) {
                            notices.notices.count == pass
                        }
                    }
                    samples.append(try #require(await session.latestMetrics))
                    let entry = try #require(history.entries.first)
                    lengths.append(entry.rawText.count)
                    if entry.refinedText != nil { applied += 1 }
                    world.reset()
                }
            }
            return (samples, lengths, applied)
        }

        private func report(
            _ samples: [Metrics.Sample], seconds: Double, mode: RefinementApplyMode,
            lengths: [Int], applied: Int
        ) {
            let label = mode == .afterInsert ? "(a) 生テキスト先行" : "(b) 整形を待つ"
            print("=== \(label) / 発話 \(seconds) 秒 / n=\(samples.count) ===")
            for (index, sample) in samples.enumerated() {
                print(
                    "  #\(index + 1) M2=\(sample.finalizeMs) M3=\(sample.refineMs)"
                    + " M4=\(sample.insertMs) M5a=\(sample.totalMs)"
                    + " M6=\(sample.revisionMs.map(String.init) ?? "-")")
            }
            for (name, values) in [
                ("M2 確定", samples.map(\.finalize)),
                ("M3 整形", samples.map(\.refine)),
                ("M4 挿入", samples.map(\.insert)),
                ("M5a 合計", samples.map(\.total)),
            ] {
                let sorted = values.sorted()
                print(
                    "  \(name): 中央値 \(Metrics.milliseconds(sorted[sorted.count / 2])) ms"
                    + " / 最小 \(Metrics.milliseconds(sorted[0])) ms"
                    + " / 最大 \(Metrics.milliseconds(sorted[sorted.count - 1])) ms")
            }
            let revisions = samples.compactMap(\.revision).sorted()
            if !revisions.isEmpty {
                print(
                    "  M6 差し替え: 中央値 \(Metrics.milliseconds(revisions[revisions.count / 2])) ms"
                    + " / 最大 \(Metrics.milliseconds(revisions[revisions.count - 1])) ms")
            }
            print("  生テキストの長さ（字）: \(lengths)")
            print("  **整形が履歴へ入った発話: \(applied)/\(samples.count)**")
            let overBudget = samples.filter { !$0.meetsTarget }.count
            let refineOver750 = samples.filter { $0.refine > .milliseconds(750) }.count
            print("  NFR-P6a（1000 ms）未達: \(overBudget)/\(samples.count)")
            print("  整形が 750 ms を超えた: \(refineOver750)/\(samples.count)")
        }
    }
}

/// 計測用の挿入先。**差し替えが必ず成立する素直な欄**を用意する。
///
/// 実機のアプリの当たり外れを計測へ混ぜないためである（そちらは V-23〜V-27 の担当）。
/// ここで測りたいのは**配線の所要**であって、相手アプリの相性ではない。
final class MeasurementWorld: Sendable {

    private let field: Mutex<FakeTextField>
    private let accessibility: SwitchingAccessibility
    private let identity = UUID()
    let stack: InsertionStack

    init() {
        let field = FakeTextField(content: "", selection: AXTextRange(location: 0, length: 0))
        let element = FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: true,
            processIdentifier: 424_242, acceptsWrite: true,
            isSelectedTextRangeSettable: true, identity: identity
        )
        let accessibility = SwitchingAccessibility(
            FakeAccessibility(focused: element, field: field))
        let epoch = InsertionEpoch()
        let clipboard = StubClipboard()
        let inserter = CompositeInserter(
            primary: AccessibilityInserter(
                accessibility: accessibility, ownProcessIdentifier: 4_242, epoch: epoch),
            fallback: StubInserter(canInsert: false, succeeds: false),
            lastResort: clipboard,
            epoch: epoch,
            isSecureInputEnabled: { false }
        )
        let replacer = TextReplacer(
            accessibility: accessibility, clipboard: clipboard, epoch: epoch,
            ownProcessIdentifier: 4_242, isSecureInputEnabled: { false }
        )
        self.field = Mutex(field)
        self.accessibility = accessibility
        self.stack = InsertionStack(
            inserter: inserter, replacer: replacer, clipboard: clipboard)
    }

    /// 発話ごとに欄を空へ戻す。**溜め込むと範囲の算術が長くなって計測に混ざる。**
    func reset() {
        let fresh = FakeTextField(content: "", selection: AXTextRange(location: 0, length: 0))
        field.withLock { $0 = fresh }
        let element = FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: true,
            processIdentifier: 424_242, acceptsWrite: true,
            isSelectedTextRangeSettable: true, identity: identity
        )
        accessibility.swap(to: FakeAccessibility(focused: element, field: fresh))
    }
}

import AVFAudio
import AppKit
import Foundation
import Testing

@testable import GhostVoiceCore

/// フィクスチャの音声を**実時間で**流す音声取得の代役。
///
/// マイクは開かない（開いても台本どおりに喋らせられない）が、
/// **`AudioCapturing` の契約はそのまま守る**: `stopTap()` は末尾を配ってから終端する。
/// M5a の計測はキー解放から測るので、それまでに解析器が追いついている必要がある。
/// まとめて流し込むと未処理ぶんの消化時間まで確定に混ざる（V-2 と同じ注意）。
final class ReplayAudioCapture: AudioCapturing, @unchecked Sendable {

    private let buffers: [AVAudioPCMBuffer]
    private let interval: Duration
    private let lock = NSLock()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var pump: Task<Void, Never>?
    private let levelStream = AsyncStream<Float>.makeStream().stream

    init(buffers: [AVAudioPCMBuffer], interval: Duration) {
        self.buffers = buffers
        self.interval = interval
    }

    var level: AsyncStream<Float> { levelStream }

    /// **常に 0 を返す。この代役ではドロップを観測できない。**
    ///
    /// 形式変換の失敗は `EngineAudioCapture` の変換経路でしか起きず、ここは
    /// 変換を通さない。したがって `Metrics.Sample.droppedBuffers` は必ず
    /// `0 - 0 = 0` になる。**この計測から「ドロップが無かった」とは言えない**
    /// （言えるのは「測っていない」だけ）。発話ごとの差分そのものの検査は
    /// `countsDroppedBuffersPerUtterance` が `StubAudioCapture` で行う。
    var droppedBufferCount: Int { 0 }

    func prepare() throws {}

    func startTap(format: AVAudioFormat?) throws -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        lock.withLock { self.continuation = continuation }
        pump = Task { [buffers, interval] in
            for buffer in buffers {
                if Task.isCancelled { break }
                continuation.yield(SpeechFixtures.detachedCopy(of: buffer))
                try? await Task.sleep(for: interval)
            }
        }
        return stream
    }

    func stopTap() {
        pump?.cancel()
        pump = nil
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    /// 台本を流し終えるまで待つ。キー解放はこの後に送る。
    func waitForPlayback() async {
        await pump?.value
    }
}

extension SpeechDependentTests {

    /// M5a（キー解放 → テキストが挿入先に現れるまで）を端から端まで実測する。詳細設計書 §10。
    ///
    /// - Note: **これは「整形を待ってから挿入する」分岐の M5a である**（要件定義書 §2.8.6 の (b)）。
    ///   生テキストを先に挿入する分岐（FR-5(a)）は未実装であり、その M5a は未実測（V-28）。
    ///
    /// **本物を通す。** 認識は `SpeechAnalyzerTranscriber`、整形は
    /// `FoundationModelRefiner`、挿入は `CompositeInserter.system(...)` である。
    /// 代役はマイク（台本どおりに喋らせられない）とホットキーだけ。
    ///
    /// > **挿入は `.clipboardOnly` 経路に固定して測る。** M4 の実測値は
    /// > **クリップボードへ残す経路のコスト**であって、⌘V の往復（Task 8 実測 p50 33 ms）も
    /// > 復元待ち（120 ms）も含まない。権限のある機体での確定は V-3 が担う（利用者が実施）。
    /// >
    /// > **固定するのは安全のためでもある。** 実物のまま組むと、AX 権限のある機体では
    /// > `swift test` を回した瞬間に**フォーカス中のアプリへテキストが書き込まれる**。
    /// > Task 7 が `GHOST_VOICE_MIC_TESTS=1` で塞いだのと同じ種類の境界で、
    /// > 「この機体では権限が無いから安全」は**別の機体では成り立たない**。
    /// > 適用外を返す AX 判定と、送出できない送出器を挿して塞いである。
    ///
    /// > **クリップボードは名前付きのものを使う。** `NSPasteboard.general` に触れると
    /// > 開発機で `swift test` を回した瞬間にユーザーのクリップボードが消える。
    /// > **既定の `swift test` では走らない。** `GHOST_VOICE_MEASURE=1 swift test` で有効になる。
    /// >
    /// > 10 発話 × 3 秒の実認識と実 LLM を回すので 40 秒近く掛かり、**機体を飽和させる。**
    /// > 実時間を閾値にしている既存のテストは、飽和した条件で `Task.sleep` のタイマー配送が
    /// > 遅れると落ちる（申し送り【12】の断続的失敗と同じ形）。計測は必要なときに明示的に
    /// > 回すもので、毎回の回帰検査に混ぜる性質のものではない。
    /// > Task 7 が `GHOST_VOICE_MIC_TESTS=1` で確立した opt-in の前例に倣う。
    @Suite(
        "M5a: キー解放から挿入完了まで",
        .enabled("GHOST_VOICE_MEASURE=1 を付けると実行される") {
            ProcessInfo.processInfo.environment["GHOST_VOICE_MEASURE"] == "1"
        },
        .enabled("音声フィクスチャが要る") { SpeechFixtures.audioExists },
        .enabled(if: FoundationModelRefiner().isAvailable, "Apple Intelligence が要る")
    )
    struct EndToEndLatency {

        /// 1 発話ぶんに流す音声の長さ。PTT の 1 発話は数秒の短文である。
        static let utteranceSeconds = 3.0
        static let sampleCount = 10

        @Test("M5a の分布を実測する（要件は NFR-P6a 1000 ms、検査線は 1500 ms）")
        func measuresEndToEndLatency() async throws {
            let transcriber = SpeechAnalyzerTranscriber()
            try await transcriber.prepare(locale: .jaJP, kind: .dictation)
            let format = try #require(await transcriber.requiredAudioFormat)
            let buffers = try SpeechFixtures.buffers(
                from: SpeechFixtures.audioURL, to: format,
                limitSeconds: Self.utteranceSeconds)

            let refiner = FoundationModelRefiner()
            // 初回の respond はモデルのロードを含んで実測 3.3 秒。計測に混ぜない。
            await refiner.prewarm()

            var samples: [Metrics.Sample] = []

            try await withNamedPasteboard { pasteboard in
                try await withTempRoot { root in
                    let audio = ReplayAudioCapture(buffers: buffers, interval: .milliseconds(100))
                    let hotkey = StubHotkeyMonitor()
                    let session = DictationSession.forTests(
                        settings: SettingsStore(rootURL: root),
                        hotkey: hotkey,
                        audio: audio,
                        transcriber: transcriber,
                        refiner: refiner,
                        inserter: CompositeInserter.system(
                            // フォーカス中の実アプリへ書き込まない。適用外を返させる。
                            accessibility: FakeAccessibility(focused: nil),
                            pasteboard: pasteboard,
                            // ⌘V を実際に送出しない。`.clipboardOnly` へ落ちる。
                            sender: StubPasteShortcutSender(canSend: false)
                        ),
                        history: HistoryStore(rootURL: root, limit: 50),
                        vocabulary: VocabularyStore(rootURL: root)
                    )

                    let run = Task { await session.run() }
                    defer { run.cancel() }

                    for pass in 1...Self.sampleCount {
                        hotkey.emit(.pressed)
                        try await waitUntil("\(pass) 回目の録音が始まる") {
                            if case .recording = await session.state { return true }
                            return false
                        }
                        // 台本を流し終えてから解放する。M5a の窓はここから開く。
                        await audio.waitForPlayback()
                        hotkey.emit(.released)
                        try await waitUntil("\(pass) 回目が待機へ戻る", timeout: .seconds(30)) {
                            await session.state == .idle
                        }
                        let sample = try #require(await session.latestMetrics)
                        samples.append(sample)
                    }
                }
            }

            report(samples)

            // **この境界は要件値ではない。** 要件は NFR-P6a（1000 ms）で、実測との比較は
            // レポート側の 2 条件計測が担う。ここが見るのは「桁で壊れた」水準だけ。
            // 1500 ms は要件値の 1.5 倍（Task 7 で確立した壊れ検知の線の決め方）。
            let median = Self.median(samples.map(\.total))
            #expect(
                median < .milliseconds(1_500),
                "M5a の中央値が桁で悪化している（要件 NFR-P6a は 1000 ms。ここは壊れ検知の線）")
        }

        private func report(_ samples: [Metrics.Sample]) {
            let totals = samples.map(\.total)
            print("M5a サンプル数: \(samples.count)（1 発話 \(Self.utteranceSeconds) 秒）")
            print("M5a 区間別 (ms):")
            for (index, sample) in samples.enumerated() {
                print(
                    "  #\(index + 1) M2=\(sample.finalizeMs) M3=\(sample.refineMs)"
                    + " M4=\(sample.insertMs) 合計=\(sample.totalMs)")
            }
            for (name, values) in [
                ("M2 確定", samples.map(\.finalize)),
                ("M3 整形", samples.map(\.refine)),
                ("M4 挿入", samples.map(\.insert)),
                ("M5a 合計", totals),
            ] {
                let sorted = values.sorted()
                print(
                    "M5a \(name): 中央値 \(Metrics.milliseconds(Self.median(values))) ms"
                    + " / p90 \(Metrics.milliseconds(Self.percentile(sorted, 0.9))) ms"
                    + " / 最大 \(Metrics.milliseconds(sorted[sorted.count - 1])) ms"
                    + " / 最小 \(Metrics.milliseconds(sorted[0])) ms")
            }
            let over = samples.filter { $0.refine > .milliseconds(500) }.count
            print("M5a 整形が 500 ms を超えた発話: \(over)/\(samples.count)")
            print("M5a NFR-P6a（1000 ms）を満たした発話: \(samples.filter(\.meetsTarget).count)/\(samples.count)")
            print("M5a 挿入経路: .clipboardOnly 固定（⌘V の往復と復元待ちは未計上。V-3 待ち）")
            print("M5a 捨てたバッファ: 未計測（代役の droppedBufferCount は定数 0）")
        }

        static func median(_ values: [Duration]) -> Duration {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        static func percentile(_ sorted: [Duration], _ fraction: Double) -> Duration {
            let index = min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.down)))
            return sorted[index]
        }
    }
}

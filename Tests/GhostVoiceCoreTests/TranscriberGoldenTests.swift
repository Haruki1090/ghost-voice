import Testing
import Foundation
@testable import GhostVoiceCore

/// 固定音声に対する認識結果の回帰確認（詳細設計書 §11.2）。
/// OS 更新でモデルが変わりうるため、完全一致ではなく CER の閾値で判定する。
@Suite(
    "認識のゴールデンテスト",
    .serialized,
    .enabled("音声フィクスチャと ja-JP のモデル資産が要る（say -v Kyoko -f jp-meeting.txt -o jp-meeting.aiff）") {
        await SpeechFixtures.isReady
    }
)
struct TranscriberGoldenTests {

    private static let ja = Locale(identifier: "ja-JP")

    private func transcribe(_ kind: TranscriberKind) async throws -> String {
        let transcriber = SpeechAnalyzerTranscriber()
        try await transcriber.prepare(locale: Self.ja, kind: kind)
        return try await transcriber.transcribeFile(at: SpeechFixtures.audioURL)
    }

    @Test("DictationTranscriber の日本語 CER が 10% 未満")
    func dictationAccuracy() async throws {
        let result = try await transcribe(.dictation)
        let cer = CharacterErrorRate.compute(reference: try SpeechFixtures.referenceText(), hypothesis: result)
        print("DictationTranscriber CER: \(String(format: "%.4f", cer))")
        print("DictationTranscriber text: \(result)")
        #expect(cer < 0.10)
    }

    @Test("SpeechTranscriber の日本語 CER が 15% 未満")
    func speechAccuracy() async throws {
        let result = try await transcribe(.speech)
        let cer = CharacterErrorRate.compute(reference: try SpeechFixtures.referenceText(), hypothesis: result)
        print("SpeechTranscriber CER: \(String(format: "%.4f", cer))")
        print("SpeechTranscriber text: \(result)")
        #expect(cer < 0.15)
    }

    /// V-1: 既定の種別（`Settings.default.transcriberKind`）が実測で優位な側であること。
    /// 逆転したら既定値を差し替える、という設計判断（詳細設計書 §12）をテストで縛る。
    @Test("既定の種別は日本語で CER が低い方である")
    func defaultKindIsTheMoreAccurateOne() async throws {
        let reference = try SpeechFixtures.referenceText()
        let dictationCER = CharacterErrorRate.compute(
            reference: reference, hypothesis: try await transcribe(.dictation))
        let speechCER = CharacterErrorRate.compute(
            reference: reference, hypothesis: try await transcribe(.speech))

        print("V-1 合成音声: dictation CER=\(String(format: "%.4f", dictationCER)) speech CER=\(String(format: "%.4f", speechCER))")

        let better: TranscriberKind = dictationCER <= speechCER ? .dictation : .speech
        #expect(Settings.default.transcriberKind == better,
                "実測で \(better) が優位。Settings.default.transcriberKind を合わせること")
    }

    /// 103 秒の音声に対する一括変換の所要。
    ///
    /// 閾値 30 秒の根拠: 既定構成（`.progressiveShortDictation`）の実測は 8.87〜15.32 秒で、
    /// 同一マシンでも 1.7 倍のばらつきがある。詳細設計書 §11.2 が挙げていた
    /// 2.72〜3.07 秒は暫定結果を出さないプリセットの値であり、暫定結果
    /// （HUD のライブ表示に必須）を有効にすると 2〜4 倍かかる。
    /// ここは「桁で壊れたこと」を捕まえる線であり、性能目標そのものではない。
    /// PTT の実際の予算はストリーミング側の V-2（実測 62 ms）で見る。
    @Test("103 秒の音声を 30 秒以内に処理できる")
    func throughput() async throws {
        let transcriber = SpeechAnalyzerTranscriber()
        try await transcriber.prepare(locale: Self.ja, kind: .dictation)

        let start = ContinuousClock.now
        let text = try await transcriber.transcribeFile(at: SpeechFixtures.audioURL)
        let elapsed = ContinuousClock.now - start

        print("throughput: \(elapsed) for 103s audio (\(text.count) chars)")
        #expect(elapsed < .seconds(30))
        #expect(!text.isEmpty)
    }

    /// 同じインスタンスで 2 回続けて呼べること。
    /// `SpeechModule` は 1 つの `SpeechAnalyzer` にしか装着できず、
    /// 使い回すとフレームワーク内部で異常終了する（実測）。
    @Test("同じインスタンスで繰り返し変換できる")
    func repeatedUseOnSameInstance() async throws {
        let transcriber = SpeechAnalyzerTranscriber()
        try await transcriber.prepare(locale: Self.ja, kind: .dictation)

        let first = try await transcriber.transcribeFile(at: SpeechFixtures.audioURL)
        let second = try await transcriber.transcribeFile(at: SpeechFixtures.audioURL)

        #expect(!first.isEmpty)
        #expect(first == second)
    }
}

/// V-1 の本命。合成音声ではなく肉声で 2 つのモジュールを比べる。
/// 録音は個人の音声データのためリポジトリに含めない。手順は `SpeechFixtures` を参照。
@Suite(
    "LiveVoice: 肉声での V-1",
    .serialized,
    .enabled("Tests/Fixtures/live-voice.{aiff,txt} を置くと実行される") {
        await SpeechFixtures.liveVoiceIsReady
    }
)
struct LiveVoiceComparisonTests {

    @Test("肉声でも既定の種別が CER の低い方である")
    func defaultKindWinsOnLiveVoice() async throws {
        let reference = try SpeechFixtures.liveVoiceReferenceText()
        var measured: [TranscriberKind: Double] = [:]

        for kind in TranscriberKind.allCases {
            let transcriber = SpeechAnalyzerTranscriber()
            try await transcriber.prepare(locale: Locale(identifier: "ja-JP"), kind: kind)
            let text = try await transcriber.transcribeFile(at: SpeechFixtures.liveVoiceAudioURL)
            let cer = CharacterErrorRate.compute(reference: reference, hypothesis: text)
            measured[kind] = cer
            print("V-1 肉声 \(kind): CER=\(String(format: "%.4f", cer))")
            print("V-1 肉声 \(kind): \(text)")
        }

        let better = try #require(measured.min { $0.value < $1.value }?.key)
        #expect(Settings.default.transcriberKind == better,
                "肉声の実測で \(better) が優位。Settings.default.transcriberKind を合わせること")
    }
}

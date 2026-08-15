import Testing
import Foundation
@testable import GhostVoiceCore

extension SpeechDependentTests {

    /// 固定音声に対する認識結果の回帰確認（詳細設計書 §11.2）。
    /// OS 更新でモデルが変わりうるため、完全一致ではなく CER の閾値で判定する。
    @Suite(
        "認識のゴールデンテスト",
        .enabled("音声フィクスチャが要る（cd Tests/Fixtures && say -v Kyoko -f jp-meeting.txt -o jp-meeting.aiff）") {
            SpeechFixtures.audioExists
        }
    )
    struct Golden {

        private func transcribe(_ kind: TranscriberKind) async throws -> String {
            let transcriber = SpeechAnalyzerTranscriber()
            try await transcriber.prepare(locale: .jaJP, kind: kind)
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

        /// **既定値の根拠そのもの。**
        ///
        /// 精度差は 529 字中 1 文字しかなく（要件定義書 §2.5）、既定を `.dictation` にしている
        /// 理由は精度ではなく**句読点・疑問符を付与する出力の体裁**である。
        /// その体裁が失われたら、既定値の根拠が消える。そこをここで縛る。
        @Test("既定の種別は疑問文に疑問符を付ける（既定値選択の根拠）")
        func defaultKindPunctuatesQuestions() async throws {
            let text = try await transcribe(Settings.default.transcriberKind)
            // 原稿の末尾は「何かご質問はございますか。」
            #expect(text.contains("ございますか？"),
                    "既定の種別が疑問符を付与しない。既定値の根拠（出力の体裁）が失われている: 末尾=\(text.suffix(20))")
        }

        /// V-1: 既定値を見直すべき**有意な**精度差がついていないこと。
        ///
        /// 「CER が低い方を既定にする」という判定にはしない。実測差が 0.19 ポイント
        /// （比 0.94）しかないため、その判定では OS 更新のたびに結論が裏返り、
        /// 体裁を理由に選んだ既定値の変更を毎回強制することになる。
        @Test("既定の種別に有意な精度の不利が無い")
        func defaultKindHasNoSignificantAccuracyPenalty() async throws {
            let reference = try SpeechFixtures.referenceText()
            var measured: [TranscriberKind: Double] = [:]
            for kind in TranscriberKind.allCases {
                measured[kind] = CharacterErrorRate.compute(
                    reference: reference, hypothesis: try await transcribe(kind))
            }

            let current = Settings.default.transcriberKind
            let currentCER = try #require(measured[current])
            print("V-1 合成音声: " + TranscriberKind.allCases
                .map { "\($0) CER=\(String(format: "%.4f", measured[$0] ?? .nan))" }
                .joined(separator: " "))

            for (kind, cer) in measured where kind != current {
                #expect(!AccuracySignificance.isSignificantlyBetter(cer, than: currentCER),
                        """
                        \(kind) の CER \(String(format: "%.4f", cer)) が既定 \(current) の \
                        \(String(format: "%.4f", currentCER)) を有意に下回った。\
                        Settings.default.transcriberKind の見直しを検討すること
                        """)
            }
        }

        /// 103 秒の音声に対する一括変換の所要。
        ///
        /// 閾値 30 秒の根拠: 既定構成（`.progressiveShortDictation`）の実測は 8.9〜15.3 秒で、
        /// 同一マシンでも 1.7 倍のばらつきがある。要件定義書 §2.2 の初版が挙げていた
        /// 2.72〜3.07 秒は暫定結果を出さない構成に近い値であり、暫定結果
        /// （HUD のライブ表示に必須）を有効にすると 2〜4 倍かかる。
        /// ここは「桁で壊れたこと」を捕まえる線であり、性能目標そのものではない。
        /// PTT の実際の予算はストリーミング側の M2（実測 中央値 75.9〜82.5 ms / 最大 155.1 ms）で見る。
        @Test("103 秒の音声を 30 秒以内に処理できる")
        func throughput() async throws {
            let transcriber = SpeechAnalyzerTranscriber()
            try await transcriber.prepare(locale: .jaJP, kind: .dictation)

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
            try await transcriber.prepare(locale: .jaJP, kind: .dictation)

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
        .enabled("Tests/Fixtures/live-voice.{aiff,txt} を置くと実行される") {
            SpeechFixtures.liveVoiceExists
        }
    )
    struct LiveVoice {

        /// 合成音声版と同じ方針で、**有意差がついたときだけ**落とす。
        /// 肉声 V-1 は既定値を決める材料であって、ノイズ幅で決着させる場ではない。
        @Test("肉声で既定の種別に有意な精度の不利が無い")
        func defaultKindHasNoSignificantPenaltyOnLiveVoice() async throws {
            let reference = try SpeechFixtures.liveVoiceReferenceText()
            var measured: [TranscriberKind: Double] = [:]

            for kind in TranscriberKind.allCases {
                let transcriber = SpeechAnalyzerTranscriber()
                try await transcriber.prepare(locale: .jaJP, kind: kind)
                let text = try await transcriber.transcribeFile(at: SpeechFixtures.liveVoiceAudioURL)
                let cer = CharacterErrorRate.compute(reference: reference, hypothesis: text)
                measured[kind] = cer
                print("V-1 肉声 \(kind): CER=\(String(format: "%.4f", cer))")
                print("V-1 肉声 \(kind): \(text)")
            }

            let current = Settings.default.transcriberKind
            let currentCER = try #require(measured[current])

            for (kind, cer) in measured where kind != current {
                #expect(!AccuracySignificance.isSignificantlyBetter(cer, than: currentCER),
                        """
                        肉声の実測で \(kind) の CER \(String(format: "%.4f", cer)) が \
                        既定 \(current) の \(String(format: "%.4f", currentCER)) を有意に下回った。\
                        Settings.default.transcriberKind を見直すこと
                        """)
            }
        }
    }
}

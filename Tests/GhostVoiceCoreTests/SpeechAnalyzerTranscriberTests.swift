import Testing
import Foundation
import AVFAudio
import Speech
@testable import GhostVoiceCore

/// モデル資産を要さない、契約そのものの検証。
@Suite("SpeechAnalyzerTranscriber の契約")
struct SpeechAnalyzerTranscriberContractTests {

    @Test("prepare 前に begin すると notPrepared")
    func beginBeforePrepareThrows() async throws {
        let transcriber = SpeechAnalyzerTranscriber()
        await #expect(throws: TranscriptionError.notPrepared) {
            _ = try await transcriber.begin()
        }
    }

    @Test("prepare 前に transcribeFile すると notPrepared")
    func transcribeFileBeforePrepareThrows() async throws {
        let transcriber = SpeechAnalyzerTranscriber()
        await #expect(throws: TranscriptionError.notPrepared) {
            _ = try await transcriber.transcribeFile(at: SpeechFixtures.audioURL)
        }
    }

    @Test("prepare 前の requiredAudioFormat は nil")
    func formatIsNilBeforePrepare() async {
        let transcriber = SpeechAnalyzerTranscriber()
        let format = await transcriber.requiredAudioFormat
        #expect(format == nil)
    }

    /// 未対応ロケールでは `AssetInventory` が SFSpeechError を投げる。
    /// 生のまま漏らさず、呼び出し側が扱える型へ翻訳すること。
    @Test("未対応ロケールは localeUnsupported に翻訳する")
    func unsupportedLocaleIsTranslated() async throws {
        let transcriber = SpeechAnalyzerTranscriber()
        await #expect(throws: TranscriptionError.localeUnsupported("zu-ZA")) {
            try await transcriber.prepare(locale: Locale(identifier: "zu-ZA"), kind: .dictation)
        }
    }

    /// `SpeechTranscriber` は 30 ロケール、`DictationTranscriber` は 54 ロケールに対応する。
    /// `supportedLocale(equivalentTo:)` は識別子を正規化するだけで所属を見ないため、
    /// これに頼ると非対応の組み合わせが素通りし、ロケール枠（上限 5）を 1 つ消費した上で
    /// 不透明な失敗になる。種別ごとの対応表で弾くこと。
    @Test("そのモジュールが対応していないロケールは localeUnsupported")
    func rejectsLocaleUnsupportedByTheSelectedModule() async throws {
        // nl-NL は DictationTranscriber のみ対応（SpeechTranscriber の 30 ロケールに無い）
        let transcriber = SpeechAnalyzerTranscriber()
        await #expect(throws: TranscriptionError.localeUnsupported("nl-NL")) {
            try await transcriber.prepare(locale: Locale(identifier: "nl-NL"), kind: .speech)
        }
    }

    /// 種別の取り違えは CER が変わるだけで例外にならず、気付きにくい。
    @Test("種別ごとに対応するモジュールを作る")
    func makesModuleMatchingKind() {
        let ja = Locale(identifier: "ja-JP")

        switch TranscriptionModule.make(locale: ja, kind: .dictation) {
        case .dictation: break
        case .speech: Issue.record(".dictation が SpeechTranscriber を作った")
        }

        switch TranscriptionModule.make(locale: ja, kind: .speech) {
        case .speech: break
        case .dictation: Issue.record(".speech が DictationTranscriber を作った")
        }
    }

    /// プリセットの取り違えも例外にならない。詳細設計書 §4.2 の選択を固定する。
    @Test("PTT 向けのプリセットを使う")
    func usesPushToTalkPresets() {
        #expect(TranscriptionModule.dictationPreset == .progressiveShortDictation)
        #expect(TranscriptionModule.speechPreset == .progressiveTranscription)

        // 選択の理由は HUD のライブ表示（FR-2）に暫定結果が要ること。
        // 暫定結果を出さないプリセットへ替えたらここで落ちる。
        #expect(TranscriptionModule.dictationPreset.reportingOptions.contains(.volatileResults))
        #expect(TranscriptionModule.speechPreset.reportingOptions.contains(.volatileResults))
    }
}

extension SpeechDependentTests {

/// 実際にモデルを回す経路。`.serialized` は親スイートに掛かっている
/// （スイート間の並行が確保状態を壊すため。`SpeechDependentTests` の解説を参照）。
@Suite(
    "SpeechAnalyzerTranscriber のストリーミング",
    .enabled("音声フィクスチャが要る") { SpeechFixtures.audioExists }
)
struct Streaming {

    private func prepared() async throws -> SpeechAnalyzerTranscriber {
        let transcriber = SpeechAnalyzerTranscriber()
        try await transcriber.prepare(locale: .jaJP, kind: .dictation)
        return transcriber
    }

    @Test("prepare すると認識器の要求形式が決まる")
    func exposesRequiredAudioFormat() async throws {
        let transcriber = try await prepared()
        let format = try #require(await transcriber.requiredAudioFormat)
        #expect(format.sampleRate == 16000)
        #expect(format.channelCount == 1)
    }

    /// `AssetInventory.status` はロケールを確保するまで、導入済みでも `.supported` を返す。
    /// 状態確認を確保より先に置くと、導入済みの ja-JP に対してもダウンロードを要求する。
    /// 起動のたびにモデル取得を走らせる（オフラインでは失敗する）ため、順序を固定する。
    @Test("導入済みのモデルにダウンロードを要求しない")
    func doesNotRequestDownloadForInstalledModel() async throws {
        // 確保はプロセス内に残る。他のテストが先に確保していると、順序が誤っていても
        // `.installed` が返って誤りが隠れる。アプリ起動直後と同じ「未確保」から始める。
        //
        // この解放はプロセス全体の状態を触るため、資産を回す他のスイートと並行しては
        // ならない。直列化は親スイート `SpeechDependentTests` の `.serialized` が担う。
        let normalized = try #require(
            await DictationTranscriber.supportedLocale(equivalentTo: .jaJP))
        _ = await AssetInventory.release(reservedLocale: normalized)

        let transcriber = SpeechAnalyzerTranscriber()
        try await transcriber.prepare(locale: .jaJP, kind: .dictation)
        #expect(await transcriber.didRequestAssetInstallation == false)
    }

    /// ESC による中断では `finish()` を経ずに次の発話が始まる。
    /// 前のセッションを畳まないと、その結果ストリームは終わらないまま残り、
    /// HUD 側の消費ループが永久に待つ。
    @Test("finish を経ずに次の発話を始めても前のストリームは終了する")
    func abandonedSessionIsTornDown() async throws {
        let transcriber = try await prepared()
        let format = try #require(await transcriber.requiredAudioFormat)
        let buffers = try SpeechFixtures.buffers(
            from: SpeechFixtures.audioURL, to: format, limitSeconds: 2)

        let abandoned = try await transcriber.begin()
        for buffer in buffers { await transcriber.feed(SpeechFixtures.detachedCopy(of: buffer)) }

        // finish() を呼ばずに次の発話へ
        let next = try await transcriber.begin()

        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { for try await _ in abandoned {} } catch {}
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(ended, "中断された発話のストリームが終了しない")

        // 次の発話は正常に完結できる
        for buffer in buffers { await transcriber.feed(SpeechFixtures.detachedCopy(of: buffer)) }
        try await transcriber.finish()
        var finalText = ""
        for try await update in next {
            if case .final(let text) = update { finalText += text }
        }
        #expect(!finalText.isEmpty)
    }

    /// `isFinal` による振り分けを、実際の結果列で確かめる。
    ///
    /// 判定を反転させる／無視する変異は「確定として受け取った件数」に出る。
    /// 暫定結果は伸びていく途中経過なので、全部を確定として連結すると
    /// 発話そのものより遥かに長い文字列になる。
    @Test("暫定結果と確定結果を isFinal で振り分ける")
    func routesVolatileAndFinalByIsFinal() async throws {
        let transcriber = try await prepared()
        let format = try #require(await transcriber.requiredAudioFormat)
        let buffers = try SpeechFixtures.buffers(
            from: SpeechFixtures.audioURL, to: format, limitSeconds: 8)

        let stream = try await transcriber.begin()
        for buffer in buffers { await transcriber.feed(SpeechFixtures.detachedCopy(of: buffer)) }
        try await transcriber.finish()

        var volatileCount = 0, finalCount = 0, finalText = ""
        for try await update in stream {
            switch update {
            case .volatile: volatileCount += 1
            case .final(let text): finalCount += 1; finalText += text
            }
        }

        print("streaming: volatile=\(volatileCount) final=\(finalCount) finalText=\(finalText)")
        #expect(volatileCount > 0, "HUD のライブ表示に暫定結果が要る")
        #expect(finalCount >= 1)
        // 8 秒の発話に対する確定結果は 1〜数件。暫定結果まで確定として数えるとここが崩れる。
        #expect(finalCount <= 4)
        #expect(finalText.contains("本日はお時間"))
        // 8 秒ぶんの日本語は 50 字前後。暫定結果を連結すると数百字になる。
        #expect(finalText.count < 150, "確定結果が長すぎる: \(finalText.count) 字")
    }

    /// PTT は 1 起動で何度も発話する。2 回目で落ちないこと。
    @Test("同じインスタンスで発話を繰り返せる")
    func supportsRepeatedUtterances() async throws {
        let transcriber = try await prepared()
        let format = try #require(await transcriber.requiredAudioFormat)
        let buffers = try SpeechFixtures.buffers(
            from: SpeechFixtures.audioURL, to: format, limitSeconds: 5)

        for pass in 1...3 {
            let stream = try await transcriber.begin()
            for buffer in buffers { await transcriber.feed(SpeechFixtures.detachedCopy(of: buffer)) }
            try await transcriber.finish()

            var finalText = ""
            for try await update in stream {
                if case .final(let text) = update { finalText += text }
            }
            #expect(!finalText.isEmpty, "発話 \(pass) の確定結果が空")
        }
    }

    /// V-2: キー解放（最後のバッファ供給）から確定結果を受け取るまで。
    /// 詳細設計書 §10 の M2。当初の推定値 300 ms をここで実測へ置き換えた。
    ///
    /// **消費は `begin()` 直後に始める。** `finish()` の後に消費を始めると
    /// 「`finish()` 復帰 ≦ `.final` 受信」が構造上保証されてしまい、
    /// 到着時刻ではなく自分の待ち順を測ることになる。
    @Test("V-2: 最後のバッファ供給から確定までの所要")
    func measuresFinalizationLatency() async throws {
        let transcriber = try await prepared()
        let format = try #require(await transcriber.requiredAudioFormat)
        let buffers = try SpeechFixtures.buffers(
            from: SpeechFixtures.audioURL, to: format, limitSeconds: 6)

        let stream = try await transcriber.begin()

        let log = UpdateLog()
        let consumer = Task {
            for try await update in stream {
                switch update {
                case .final: await log.recordFinal(at: ContinuousClock.now)
                case .volatile: await log.recordVolatile()
                }
            }
        }

        // 実時間で供給する。まとめて流し込むと未処理分の消化時間まで測ってしまう。
        //
        // ただしこの形は楽観側に寄る。最後のバッファ供給から 100 ms 待った時点を
        // キー解放としているため、解析器に 1 バッファぶんの先行処理を許している。
        // 実機は 10〜15 ms 程度これより大きくなる見込み（詳細設計書 §10）。
        for buffer in buffers {
            await transcriber.feed(SpeechFixtures.detachedCopy(of: buffer))
            try await Task.sleep(for: .milliseconds(100))
        }

        let released = ContinuousClock.now
        try await transcriber.finish()
        let finishReturned = ContinuousClock.now
        try await consumer.value          // 結果ストリームの終了まで待つ

        let finals = await log.finals
        let volatiles = await log.volatileCount
        // キー解放より前に届いた確定結果は当該発話の確定ではない（長い発話では途中で確定が出る）
        let finalAt = try #require(finals.first { $0 >= released },
                                   "キー解放以降に確定結果が届いていない（確定 \(finals.count) 件）")

        print("V-2 供給した暫定 \(volatiles) 件 / 確定 \(finals.count) 件"
              + "（うちキー解放前 \(finals.filter { $0 < released }.count) 件）")
        print("V-2 キー解放 → finish() 復帰: \(finishReturned - released)")
        print("V-2 キー解放 → .final 受信: \(finalAt - released)")

        // 閾値 300 ms の根拠: 13 回の実測は 40〜177 ms（中央値 約 70 ms）。
        // 最大値はビルドと並走した際の外れ値であり、要件（NFR-P3 200 ms）の 1.5 倍を
        // 検査線に取る。要件そのものより緩いが、桁の異なる回帰は確実に捕まえる。
        #expect(finalAt - released < .milliseconds(300), "NFR-P3 の予算 200 ms を大きく超えた")
    }

    /// M1 の一部: `begin()` の所要（キー押下 → バッファを供給できる状態）。
    ///
    /// V-2 の計測窓はキー解放から開くため、`begin()` の費用は**定義上そこに現れない**。
    /// 発話ごとにモジュールを作り直す設計（§4.3.1）の費用はここに出る。
    /// NFR-P1（キー押下 → 録音開始 50 ms）の予算をこれと AudioCapture 側で分け合う。
    @Test("M1: begin() の所要")
    func measuresBeginLatency() async throws {
        let transcriber = try await prepared()

        for pass in 1...3 {
            let start = ContinuousClock.now
            let stream = try await transcriber.begin()
            let elapsed = ContinuousClock.now - start
            print("M1 begin() 所要 #\(pass): \(elapsed)")
            #expect(elapsed < .milliseconds(50), "NFR-P1 の予算 50 ms を begin() だけで使い切った")

            try await transcriber.finish()
            for try await _ in stream {}
        }
    }
}
}

/// 更新の到着時刻を実時間で記録する。計測用。
actor UpdateLog {
    private(set) var finals: [ContinuousClock.Instant] = []
    private(set) var volatileCount = 0

    func recordFinal(at instant: ContinuousClock.Instant) { finals.append(instant) }
    func recordVolatile() { volatileCount += 1 }
}

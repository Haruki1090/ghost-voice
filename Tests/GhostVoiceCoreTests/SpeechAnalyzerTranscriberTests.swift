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

    /// V-14: **`SpeechAnalyzer` は音声認識の TCC（`kTCCServiceSpeechRecognition`）を要求しない。**
    ///
    /// 要件定義書は当初これを必要権限に挙げていた。実際には
    /// `SFSpeechRecognizer.authorizationStatus()` が `.notDetermined` のまま認識が通る。
    /// **この検査が無いと、権限の案内（FR-10 / `--check`）に音声認識が無いことが
    /// 「実装漏れ」なのか「要らないから」なのか、読む側から区別できない。**
    ///
    /// 許可済みの機体では前提（未確認のまま）が作れないので、そのときは走らせない。
    @Test(
        "V-14: 音声認識の許可が未確認のままでも認識できる",
        .enabled(if: SFSpeechRecognizer.authorizationStatus() != .authorized,
                 "この機体では音声認識が許可済みで、未確認のままの検証ができない")
    )
    func recognizesWithoutSpeechRecognitionAuthorization() async throws {
        let before = SFSpeechRecognizer.authorizationStatus()
        let transcriber = try await prepared()
        let format = try #require(await transcriber.requiredAudioFormat)
        let buffers = try SpeechFixtures.buffers(
            from: SpeechFixtures.audioURL, to: format, limitSeconds: 3)

        let stream = try await transcriber.begin()
        for buffer in buffers { await transcriber.feed(SpeechFixtures.detachedCopy(of: buffer)) }
        try await transcriber.finish()

        var finalText = ""
        for try await update in stream {
            if case .final(let text) = update { finalText += text }
        }

        print("V-14 音声認識の許可: 認識前 \(before.rawValue) / 認識後 "
              + "\(SFSpeechRecognizer.authorizationStatus().rawValue)（0=notDetermined）")
        #expect(!finalText.isEmpty, "音声認識の許可なしでは認識できていない")
        // **要求もしていないこと**を見る。黙ってダイアログを出す実装になっていないか。
        #expect(SFSpeechRecognizer.authorizationStatus() == before,
                "認識の過程で音声認識の許可状態が変わった")
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
        let streamEnded = ContinuousClock.now

        let finals = await log.finals
        let volatiles = await log.volatileCount
        // キー解放より前に届いた確定結果は当該発話の確定ではない（長い発話では途中で確定が出る）
        let finalAt = try #require(finals.first { $0 >= released },
                                   "キー解放以降に確定結果が届いていない（確定 \(finals.count) 件）")

        print("V-2 供給した暫定 \(volatiles) 件 / 確定 \(finals.count) 件"
              + "（うちキー解放前 \(finals.filter { $0 < released }.count) 件）")
        print("V-2 キー解放 → finish() 復帰: \(finishReturned - released)")
        print("V-2 キー解放 → .final 受信: \(finalAt - released)")
        // **M2 の定義はこちらへ移った**（V-12 の修正）。「最初の確定」で先へ進むと
        // 解放後に届く 2 件目が読まれず、発話の末尾が失われる（要件定義書 §2.8.4）。
        // 待つべきは「これ以上テキストが来ない」と判る時点＝結果ストリームの終端である。
        print("V-2 キー解放 → 結果ストリーム終端（現行の M2）: \(streamEnded - released)")
        print("V-2 .final から終端までの上乗せ: \(streamEnded - finalAt)")

        // **この境界は要件値ではない。** 要件は `docs/01-requirements.md`（NFR-P3 200 ms）、
        // 実測は各タスクレポートの 2 条件計測が担う。ここが見るのは「明らかに壊れている」水準だけ。
        //
        // 500 ms の根拠: 実測分布は 40〜177 ms（13 回・中央値 約 70 ms）と 4.4 倍のばらつきを持つ。
        // これは**単一観測**の判定なので、負荷が乗った回に上振れすると 300 ms 線では落ちた
        // （実際に 307.7 ms で落ちている）。5〜8 回に 1 回落ちるゲートは読み飛ばされるようになり、
        // 無いより悪い。桁の異なる回帰（700 ms〜数秒）は 500 ms でも確実に捕まる。
        #expect(finalAt - released < .milliseconds(500),
                "確定レイテンシが桁で悪化している（要件 NFR-P3 は 200 ms。ここは壊れ検知の線）")
        // **現行の M2 はこちらである。** 同じ根拠で同じ線を置く。
        #expect(streamEnded - released < .milliseconds(500),
                "終端までの所要が桁で悪化している（要件 NFR-P3 は 200 ms。ここは壊れ検知の線）")
    }

    /// M1 の一部: `begin()` の所要（キー押下 → バッファを供給できる状態）。
    ///
    /// V-2 の計測窓はキー解放から開くため、`begin()` の費用は**定義上そこに現れない**。
    /// 発話ごとにモジュールを作り直す設計（§4.3.1）の費用はここに出る。
    /// NFR-P1（キー押下 → 録音開始 50 ms）の予算をこれと AudioCapture 側で分け合う。
    ///
    /// ## 1 回目と 2 回目以降は別の量である（実測 / 2026-08-14 / M3 / macOS 26.5.2）
    ///
    /// | 条件 | 1 回目 | 2 回目以降 |
    /// |---|---|---|
    /// | 低負荷（load average 5.2〜6.0） | 中央値 44.2 ms / 最小 39.3 / **最大 540.4**（n=8） | 中央値 1.6 ms / 最大 3.2（n=16） |
    /// | 負荷下（`yes` 16 本、load average 13） | **中央値 64.5 ms** / 最小 55.6 / 最大 195.7（n=5） | 中央値 2.2 ms / 最大 5.8（n=10） |
    ///
    /// **プロセス最初の `begin()` は NFR-P1 の予算 50 ms を超えうる**（負荷下では中央値で超えた）。
    /// これは断続的な失敗ではなく実装の性質である。**この費用は、フェーズ 2 で
    /// `DictationSession.warmUpTranscriber()` の捨て往復が起動時に払う形にした**
    /// （詳細設計書 §10。それまでは起動後の最初の発話が払っていた）。
    /// **ここはその「1 回目」の費用そのものを測る場所であり、依然として意味がある。**
    ///
    /// ## 線の決め方（規律 10）
    ///
    /// **旧構成は 50 ms、すなわち NFR-P1 の要件値そのものを合否線にしていた。**
    /// 上の分布のちょうど真ん中に線があるので、1 回目が当たるたびに落ちる
    /// （Task 11 で単独実行 8 回中 2 回、実測 87 ms / 146 ms）。
    /// **要件値を検査線に使わない**（規律 10）。ここは 2 つに分けて、それぞれ壊れ検知の線を置く。
    ///
    /// - 1 回目: **2 秒**。実測最大 540 ms の約 3.7 倍。捕まえるのは「ハングと桁違いの回帰」
    /// - 2 回目以降: **50 ms**。実測最大 5.8 ms の約 8.6 倍。**要件値と同じ数だが意味が違う**——
    ///   NFR-P1 の合否をここで判定しているのではなく、ウォーム経路が桁で悪化したことを見ている
    ///
    /// **要件値そのものは緩めていない。** NFR-P1 の達成可否は V-9（M1a の実測 0.088〜0.118 ms）と
    /// 上の 1 回目の実測が示すもので、この検査の線ではない。
    @Test("M1: begin() の所要")
    func measuresBeginLatency() async throws {
        let transcriber = try await prepared()

        for pass in 1...3 {
            let start = ContinuousClock.now
            let stream = try await transcriber.begin()
            let elapsed = ContinuousClock.now - start
            print("M1 begin() 所要 #\(pass): \(elapsed)")

            if pass == 1 {
                #expect(
                    elapsed < .seconds(2),
                    "初回の begin() が桁で悪化している（線は壊れ検知。要件値ではない）: \(elapsed)")
            } else {
                #expect(
                    elapsed < .milliseconds(50),
                    "ウォーム後の begin() が桁で悪化している（線は壊れ検知。要件値ではない）: \(elapsed)")
            }

            try await transcriber.finish()
            for try await _ in stream {}
        }
    }

    /// **起動時の捨て往復**（`DictationSession.warmUpTranscriber()`）を実物で確かめる。
    ///
    /// 起動後の最初の `begin()` は実測 中央値 44.2 ms（低負荷）／ 64.5 ms（負荷下）・
    /// 最大 540.4 ms 掛かり、**その費用は発話の頭の取りこぼしとして出る**
    /// （`begin()` 復帰前のバッファは黙って捨てられる）。起動時に 1 往復させて
    /// 捨てておけば、最初の発話が払うのはウォーム後の値（実測 中央値 1.00 ms（低負荷）／
    /// 3.0 ms（負荷下））になる。
    ///
    /// ここで確かめるのは 2 つ。
    ///
    /// 1. **捨てた解析器が確実に畳まれること。** `SpeechModule` のインスタンスは
    ///    1 つの `SpeechAnalyzer` にしか装着できない（§4.3.1）。畳まれていなければ
    ///    次の発話が認識されない（あるいは異常終了する）。
    /// 2. **往復の費用**（`begin()` と、入力を 1 バッファも与えない `finish()`）。
    ///    起動直後に押された場合、その押下はこの残りを待つ。
    ///
    /// - Note: **1 回目が「コールド」かどうかは、このスイートの実行順に依る。**
    ///   同一プロセスで先に別の検査が解析器を作っていれば、ここはウォームな値になる。
    ///   コールドを見るときは `--filter` で単独実行すること。
    @Test("M1a: 起動時の捨て往復と、その直後の begin()")
    func throwawayRoundTripLeavesNoLiveAnalyzer() async throws {
        let transcriber = try await prepared()
        let format = try #require(await transcriber.requiredAudioFormat)
        let buffers = try SpeechFixtures.buffers(
            from: SpeechFixtures.audioURL, to: format, limitSeconds: 5)

        // --- 捨て往復。**音声は 1 バッファも供給しない。**
        let coldStart = ContinuousClock.now
        let throwaway = try await transcriber.begin()
        let coldBegin = ContinuousClock.now - coldStart
        let finishStart = ContinuousClock.now
        try await transcriber.finish()
        let throwawayFinish = ContinuousClock.now - finishStart
        // 実装と同じく、`finish()` を跨いでからストリームを手放す。
        withExtendedLifetime(throwaway) {}

        // --- 起動後の最初の発話に当たる往復
        let warmStart = ContinuousClock.now
        let stream = try await transcriber.begin()
        let warmBegin = ContinuousClock.now - warmStart
        for buffer in buffers { await transcriber.feed(SpeechFixtures.detachedCopy(of: buffer)) }
        try await transcriber.finish()

        var text = ""
        for try await update in stream {
            if case .final(let recognized) = update { text += recognized }
        }

        print("M1a 捨て往復 begin(): \(coldBegin)")
        print("M1a 捨て往復 finish()（入力ゼロ）: \(throwawayFinish)")
        print("M1a 捨て往復 合計: \(coldBegin + throwawayFinish)")
        print("M1a 捨て往復の直後の begin(): \(warmBegin)")

        // **これが 1 の検査である。** 捨てた解析器が生きたままだと、
        // 2 つ目の解析器へ同じ種類のモジュールを装着することになる。
        #expect(!text.isEmpty, "捨て往復のあとの発話が認識されない（解析器が畳まれていない）")

        // **どちらも壊れ検知の線であって要件値ではない**（規律 10）。
        // NFR-P1 の達成可否は V-9 の M1a 実測と、上の出力が示す。
        //
        // **どちらも 2 秒に置いてある。もっと締めた線は置けない。** 実測（2026-08-14 /
        // M3 / macOS 26.5.2 / 各 8 回）では、負荷下でコールドの `begin()` が
        // 中央値 158 ms / 最大 1110 ms、ウォームが 中央値 3.0 ms / **最大 106 ms** で、
        // **2 つの分布が重なる。** さらに「1 回目がコールドか」は同一プロセス内の
        // 実行順に依るので、比（ウォーム ≪ コールド）で判定することもできない。
        // ウォーム経路の回帰は `measuresBeginLatency` の 50 ms 線が担当する。
        #expect(
            throwawayFinish < .seconds(2),
            "入力ゼロの finish() が桁で悪化している（線は壊れ検知）: \(throwawayFinish)")
        #expect(
            warmBegin < .seconds(2),
            "捨て往復の直後の begin() が桁で悪化している（線は壊れ検知）: \(warmBegin)")
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

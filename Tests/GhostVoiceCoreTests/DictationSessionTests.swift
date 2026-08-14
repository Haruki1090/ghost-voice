import Foundation
import Testing

@testable import GhostVoiceCore

/// `condition` が真になるまで待つ。
///
/// **固定 sleep で「たぶん終わっただろう」と決めない。** 状態機械のテストは
/// 待ち時間を決め打ちすると、機体の負荷で成否が変わる断続的失敗の温床になる。
/// ここは「成立するまで待ち、成立しなければ落ちる」ので、余裕を長く取っても遅くならない。
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("\(description) が \(timeout) 以内に成立しなかった", sourceLocation: sourceLocation)
}

@Suite("DictationSession")
struct DictationSessionTests {

    /// テスト用の組み立て。**実マイクも実 LLM も実挿入も通らない。**
    private struct Rig {
        let session: DictationSession
        let hotkey: StubHotkeyMonitor
        let audio: StubAudioCapture
        let transcriber: StubTranscriber
        let refiner: SpyRefiner
        let inserter: RecordingInserter
        let history: HistoryStore
        let settings: SettingsStore
        let root: URL
    }

    private func makeRig(
        root: URL,
        transcriber: StubTranscriber = StubTranscriber(),
        refiner: SpyRefiner = SpyRefiner(result: "整形後テキストです"),
        inserter: RecordingInserter = RecordingInserter(),
        audio: StubAudioCapture = StubAudioCapture(),
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { false },
        maxRecordingDuration: Duration = .seconds(120),
        finalizeDeadline: Duration = .seconds(5)
    ) -> Rig {
        let hotkey = StubHotkeyMonitor()
        let history = HistoryStore(rootURL: root, limit: 50)
        let settings = SettingsStore(rootURL: root)
        let session = DictationSession(
            settings: settings,
            hotkey: hotkey,
            audio: audio,
            transcriber: transcriber,
            refiner: refiner,
            inserter: inserter,
            history: history,
            vocabulary: VocabularyStore(rootURL: root),
            isSecureInputEnabled: isSecureInputEnabled,
            // 実 API（`CGPreflightPostEventAccess()`）は 1 回 10.6 ms 掛かる。
            // テストが機体の権限状態に依存しないよう偽物を挿す。
            postEventAuthorization: PostEventAuthorization(probe: { false }),
            maxRecordingDuration: maxRecordingDuration,
            finalizeDeadline: finalizeDeadline
        )
        return Rig(
            session: session, hotkey: hotkey, audio: audio, transcriber: transcriber,
            refiner: refiner, inserter: inserter, history: history, settings: settings,
            root: root
        )
    }

    /// 1 発話ぶんを流し、挿入まで終わるのを待つ。
    private func speak(_ rig: Rig, frames: Int = 1_600) async throws {
        let run = Task { await rig.session.run() }
        defer { run.cancel() }

        rig.hotkey.emit(.pressed)
        try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
        rig.audio.emit(frames: frames)
        rig.hotkey.emit(.released)
        try await waitUntil("待機へ戻る") { await rig.session.state == .idle }
    }

    // MARK: - 正常系

    @Test("整形が成功したら整形後テキストを挿入する")
    func insertsRefinedText() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            try await speak(rig)
            #expect(rig.inserter.inserted == ["整形後テキストです"])
        }
    }

    @Test("整形がタイムアウトしたら生テキストを挿入する")
    func fallsBackToRawText() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, refiner: SpyRefiner(result: "整形後", delay: .seconds(5)))
            try await speak(rig)
            #expect(rig.inserter.inserted == ["えー、生テキストです"])
        }
    }

    @Test("中断したら何も挿入しない")
    func cancelInsertsNothing() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.cancelled)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            #expect(rig.inserter.inserted.isEmpty)
        }
    }

    @Test("挿入後に履歴が残る")
    func recordsHistory() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            try await speak(rig)

            let entry = try #require(rig.history.entries.first)
            #expect(entry.rawText == "えー、生テキストです")
            #expect(entry.refinedText == "整形後テキストです")
            #expect(entry.insertionMethod == .ax)
        }
    }

    // MARK: - 発話の端が落ちないこと

    /// **`stopTap()` が配る末尾は、`finish()` より前に認識器へ届かねばならない。**
    ///
    /// `removeTap` は保留中の端数バッファを配ってから返り、リサンプラは内部に
    /// 遅延ぶん（実測 231 フレーム = 14.4 ms）を抱えている（詳細設計書 §3.4）。
    /// 供給の完走を待たずに `finish()` を撃つと、解析器の入力はもう閉じており、
    /// その末尾は認識されない。**発話の最後の一言が消える。**
    @Test("タップの末尾は確定より前に認識器へ届く")
    func feedsTailBeforeFinishing() async throws {
        try await withTempRoot { root in
            // **供給に時間を掛けさせる。** 0 秒で供給できてしまうと、待っていない
            // 実装でも末尾がたまたま間に合い、検査が機体の速さ次第になる。
            let rig = makeRig(
                root: root,
                transcriber: StubTranscriber(StubTranscriber.Script(feedDelay: .milliseconds(30))),
                audio: StubAudioCapture(tailFrames: 800)
            )
            try await speak(rig, frames: 1_600)

            #expect(rig.transcriber.fedFrames == 2_400, "末尾のバッファが供給されていない")
            #expect(
                rig.transcriber.fedFramesAtFinish == 2_400,
                "確定を撃った時点で末尾が未供給だった（発話の末尾が落ちる）")
        }
    }

    /// **`begin()` はタップ装着より先。** `feed` は `begin()` 復帰前のバッファを
    /// 黙って捨てる（エラーにも記録にもならない）ので、順序を逆にすると
    /// **発話の頭が落ちる**（Task 5 申し送り）。
    @Test("認識を開始してからタップを張る")
    func beginsTranscriptionBeforeTappingAudio() async throws {
        try await withTempRoot { root in
            let order = CallOrder()
            let rig = makeRig(root: root)
            rig.transcriber.order = order
            rig.audio.order = order

            try await speak(rig)

            #expect(order.calls == ["transcriber.begin", "audio.startTap"])
        }
    }

    /// **整形は `.final` の到着で始まる。`finish()` の復帰を待たない。**
    ///
    /// 実測では `.final` が `finish()` の復帰より 5〜48 ms 早く届く（V-2）。
    /// ここでは代役でその差を 1 秒に広げ、待っていないことを検査できる形にしている。
    @Test("確定は finish() の復帰ではなく .final の到着で先へ進む")
    func proceedsOnFinalNotOnFinishReturn() async throws {
        try await withTempRoot { root in
            let rig = makeRig(
                root: root,
                transcriber: StubTranscriber(StubTranscriber.Script(finishDelay: .seconds(1)))
            )
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }

            let released = ContinuousClock.now
            rig.hotkey.emit(.released)
            try await waitUntil("挿入が終わる") { !rig.inserter.inserted.isEmpty }
            let elapsed = ContinuousClock.now - released

            #expect(rig.inserter.inserted == ["整形後テキストです"])
            // finish() は 1 秒掛かる。300 ms で通るなら、待っていない。
            #expect(elapsed < .milliseconds(300), "finish() の復帰を待っている（実測 \(elapsed)）")
        }
    }

    /// 録音の途中で出る確定で先へ進んではならない。長い発話では実際に起こる。
    @Test("録音中に確定が届いても挿入は始まらない")
    func midRecordingFinalDoesNotFinish() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.transcriber.emitFinal("途中の確定です。")
            try await Task.sleep(for: .milliseconds(80))

            #expect(rig.inserter.inserted.isEmpty, "録音中の確定で挿入が走った")
            #expect(await rig.session.state == .recording(volatileText: "えー"))

            // 解放後は、途中の確定と最後の確定が連結された全文が挿入対象になる。
            rig.hotkey.emit(.released)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }
            #expect(rig.refiner.refinedInputs == ["途中の確定です。えー、生テキストです"])
        }
    }

    /// 確定処理に入ったら、遅れて届く暫定結果で録音中へ戻ってはならない。
    ///
    /// 戻ると HUD が「確定中」から「録音中」へ巻き戻るだけでなく、**その状態で
    /// 解放がもう 1 度届くと確定処理が二重に走る**（最大録音時間の満了とキー解放は
    /// 別々のタスクから来るので、現実に競合しうる）。
    @Test("確定処理に入ったあとの暫定結果で録音中へ戻らない")
    func lateVolatileDoesNotReopenRecording() async throws {
        try await withTempRoot { root in
            let rig = makeRig(
                root: root,
                transcriber: StubTranscriber(StubTranscriber.Script(finishesStream: false)),
                refiner: SpyRefiner(result: "整形後テキストです", delay: .milliseconds(300))
            )
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.released)
            try await waitUntil("整形へ入る") { await rig.session.state == .refining }

            rig.transcriber.emitVolatile("遅れて届いた暫定")
            try await Task.sleep(for: .milliseconds(50))
            #expect(await rig.session.state == .refining, "確定処理中に録音中へ戻った")

            // 戻っていれば、ここで送る解放が 2 回目の確定処理を起こす。
            rig.hotkey.emit(.released)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }
            try await Task.sleep(for: .milliseconds(50))
            #expect(rig.inserter.inserted.count == 1, "確定処理が二重に走った")
        }
    }

    /// 確定が来ないまま締め切りに達したら、暫定テキストへ縮退する。
    /// **黙って捨てない。** 音声は再現できない。
    @Test("確定が来なくても暫定テキストへ縮退する")
    func fallsBackToVolatileText() async throws {
        try await withTempRoot { root in
            let rig = makeRig(
                root: root,
                transcriber: StubTranscriber(
                    StubTranscriber.Script(emitsFinal: false, finishesStream: false)),
                refiner: SpyRefiner(result: nil),
                finalizeDeadline: .milliseconds(150)
            )
            try await speak(rig)
            #expect(rig.inserter.inserted == ["えー"])
        }
    }

    // MARK: - secure input（唯一の例外）

    /// **整形の手前で弾く。** 挿入時にしか見ないと、拒否する頃には発話が既に
    /// `FoundationModels` を通っている（基本設計書 §7 が挙げる害の 1 番目）。
    @Test("secure input 中は整形にも挿入にも履歴にも渡さない")
    func secureInputStopsEverything() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, isSecureInputEnabled: { true })
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }

            try await speak(rig)

            #expect(rig.refiner.refinedInputs.isEmpty, "パスワードが LLM 整形へ渡った")
            #expect(rig.inserter.inserted.isEmpty)
            #expect(rig.history.entries.isEmpty, "パスワードが history.json へ平文で入った")
            try await waitUntil("拒否が記録される") {
                await log.states.contains(.failed(.refusedSecureInput))
            }
        }
    }

    /// 中断の経路は挿入器を通らないので、例外を挿入側だけに実装すると
    /// **ここから履歴へパスワードが入る**（基本設計書 §4 の注記）。
    @Test("secure input 中は中断した発話も履歴に残さない")
    func secureInputStopsCancelHistory() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, isSecureInputEnabled: { true })
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.cancelled)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            #expect(rig.history.entries.isEmpty)
        }
    }

    /// 挿入器が `.refusedSecureInput` を返した場合も履歴に記録してはならない。
    /// 録音中は無効で、挿入の瞬間に有効になった場合がこれに当たる。
    @Test("挿入器が secure input で拒否したら履歴に記録しない")
    func refusedInsertionIsNotRecorded() async throws {
        try await withTempRoot { root in
            let rig = makeRig(
                root: root, inserter: RecordingInserter(outcome: .refusedSecureInput))
            try await speak(rig)

            #expect(rig.inserter.inserted == ["整形後テキストです"], "挿入は試みられている")
            #expect(rig.history.entries.isEmpty, "拒否された挿入が履歴に残った")
        }
    }

    // MARK: - 中断

    /// 基本設計書 §4: 中断時、録音済み内容は破棄せず履歴に残す（発話を失わないため）。
    @Test("中断した発話も履歴には残る")
    func cancelStillRecordsHistory() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.cancelled)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            let entry = try #require(rig.history.entries.first, "中断で発話が消えた")
            #expect(entry.rawText == "えー、生テキストです")
            // 挿入していないので、事実どおりに記録する。
            #expect(entry.insertionMethod == .notInserted)
            // 整形していないので Undo の対象にはならない（戻すべき挿入が無い）。
            #expect(entry.refinedText == nil)
            #expect(rig.history.undoCandidate() == nil)
            #expect(rig.refiner.refinedInputs.isEmpty, "中断した発話を整形へ回した")
        }
    }

    /// 前の発話の結果ストリームが終わらないまま次が始まっても、次の発話が壊れないこと。
    ///
    /// 認識ストリームが終端しない経路は現実にある（中断や失敗の後）。前の消費タスクの
    /// 後始末や、遅れて届く前の発話の結果が今の発話へ漏れると、次の 2 つが起きる。
    ///
    /// - 前のストリームの**終了**が今の発話の確定待ちを解く
    ///   → **まだ届いていない確定を待たずに暫定テキストで挿入する**
    /// - 前のストリームの**確定**が今の発話のテキストへ混ざる
    ///   → 前の発話の文が今の発話の頭に付く
    @Test("前の発話の結果ストリームが残っていても次の発話は汚染されない")
    func staleResultStreamDoesNotCorruptNextUtterance() async throws {
        try await withTempRoot { root in
            let rig = makeRig(
                root: root,
                // ストリームを終端しない。1 発話目の消費タスクが生き残る。
                transcriber: StubTranscriber(StubTranscriber.Script(finishesStream: false))
            )
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            // 1 発話目
            rig.hotkey.emit(.pressed)
            try await waitUntil("1 発話目の録音が始まる") {
                await Self.label(rig.session.state) == "recording"
            }
            rig.hotkey.emit(.released)
            try await waitUntil("1 発話目が終わる") { rig.inserter.inserted.count == 1 }

            // 2 発話目。**録音中に、1 発話目のストリームへ遅れた結果を流し込む。**
            rig.hotkey.emit(.pressed)
            try await waitUntil("2 発話目の録音が始まる") {
                await Self.label(rig.session.state) == "recording"
            }
            rig.transcriber.emitFinal("前の発話の残りです。", onStream: 0)
            rig.transcriber.finishStream(0)
            try await Task.sleep(for: .milliseconds(50))

            // 遅れた終了で確定待ちが解かれていれば、ここで既に処理が進んでしまっている。
            #expect(await Self.label(rig.session.state) == "recording")

            rig.hotkey.emit(.released)
            try await waitUntil("2 発話目が終わる") { rig.inserter.inserted.count == 2 }

            // 前の発話の文が混ざらず、暫定テキストへも落ちていないこと。
            #expect(rig.refiner.refinedInputs == ["えー、生テキストです", "えー、生テキストです"])
        }
    }

    // MARK: - 中断（処理中）

    /// **整形中の ESC は間に合う。** 処理窓は実測 400〜800 ms あり、人が押すのに十分な長さ。
    /// 押した意味は 1 つ——「これを挿入するな」——なので、挿入も履歴の整形結果も残さない。
    @Test("整形中に ESC を押したら挿入しない")
    func cancelDuringRefiningStopsInsertion() async throws {
        try await withTempRoot { root in
            let rig = makeRig(
                root: root,
                refiner: SpyRefiner(result: "整形後テキストです", delay: .milliseconds(300)))
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.released)
            try await waitUntil("整形へ入る") { await rig.session.state == .refining }

            rig.hotkey.emit(.cancelled)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            #expect(rig.inserter.inserted.isEmpty, "ESC を押したのに挿入された")

            // 発話は失わない。履歴には残す（基本設計書 §4）。
            let entry = try #require(rig.history.entries.first, "中断で発話が消えた")
            #expect(entry.rawText == "えー、生テキストです")
            #expect(entry.insertionMethod == .notInserted)
            // 整形結果を残すと、一度も挿入していない文字列が Undo 対象になる。
            #expect(entry.refinedText == nil)
            #expect(rig.history.undoCandidate() == nil)
        }
    }

    /// 確定を待っている間の ESC も間に合う。認識器が遅い機体ではこの窓が最も長い。
    @Test("確定待ちの間に ESC を押したら挿入しない")
    func cancelDuringFinalizingStopsInsertion() async throws {
        try await withTempRoot { root in
            let rig = makeRig(
                root: root,
                // 確定を流さない。締め切りまで `.finalizing` に留まる。
                transcriber: StubTranscriber(
                    StubTranscriber.Script(emitsFinal: false, finishesStream: false)),
                finalizeDeadline: .seconds(3)
            )
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.released)
            try await waitUntil("確定待ちへ入る") { await rig.session.state == .finalizing }

            rig.hotkey.emit(.cancelled)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            #expect(rig.inserter.inserted.isEmpty, "ESC を押したのに挿入された")
            #expect(rig.refiner.refinedInputs.isEmpty, "中断した発話を整形へ回した")
            #expect(rig.history.entries.first?.insertionMethod == .notInserted)
        }
    }

    /// **処理中に押下が先着していると、その後の ESC は処理中の発話には届かない。**
    ///
    /// `run()` は `.pressed` を受けた時点で `startRecording()` の頭
    /// （`await completionTask?.value`）で止まるため、後続の `.cancelled` は
    /// 処理が終わるまで配送されない。**これは既知の例外として正本に書いてある**
    /// （基本設計書 §4）。
    ///
    /// ただし ESC が捨てられるわけではない。配送された時点では**次の発話が録音中**なので、
    /// **そちらが中断される。** ユーザーは PTT を押し直して新しい発話を始めた後に ESC を
    /// 押しており、「新しい方を止める」は読みとして妥当である。ここではその挙動を固定する。
    @Test("処理中に押下が先着すると ESC は次の発話へ効く")
    func cancelAfterQueuedPressAppliesToNextUtterance() async throws {
        try await withTempRoot { root in
            let rig = makeRig(
                root: root,
                refiner: SpyRefiner(result: "整形後テキストです", delay: .milliseconds(300)))
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.released)
            try await waitUntil("整形へ入る") { await rig.session.state == .refining }

            // 処理中に押下 → その後 ESC。押下が先にループを掴む。
            rig.hotkey.emit(.pressed)
            rig.hotkey.emit(.cancelled)

            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }
            try await Task.sleep(for: .milliseconds(80))

            // 1 発話目は完走する（ESC はこちらには届いていない）。
            #expect(rig.inserter.inserted == ["整形後テキストです"])
            // 2 発話目は中断された（挿入されていない・履歴は .notInserted）。
            #expect(rig.transcriber.beginCount == 2, "2 発話目が始まっていない")
            #expect(rig.history.entries.count == 2)
            #expect(rig.history.entries.first?.insertionMethod == .notInserted)
            #expect(await rig.session.state == .idle)
        }
    }

    /// **挿入を始めた後の ESC は手遅れとして扱い、完走させる。**
    ///
    /// ⌘V を送出した後に中断すると、クリップボードの復元だけが走って
    /// テキストがどこにも残らない（Task 8 が潰した欠陥と同じ形）。
    /// 「中断が効かない」より「テキストが消える」ほうが重い。
    @Test("挿入を始めた後の ESC では完走する")
    func cancelAfterInsertionStartedIsIgnored() async throws {
        try await withTempRoot { root in
            let inserter = RecordingInserter(delay: .milliseconds(300))
            let rig = makeRig(root: root, inserter: inserter)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.released)
            try await waitUntil("挿入へ入る") { await rig.session.state == .inserting }

            rig.hotkey.emit(.cancelled)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            #expect(inserter.inserted == ["整形後テキストです"], "挿入が途中で止められた")
            // 完走したので、中断ではなく通常の挿入として記録される。
            #expect(rig.history.entries.first?.insertionMethod == .ax)
            #expect(rig.history.entries.first?.refinedText == "整形後テキストです")
        }
    }

    // MARK: - 安全弁

    /// 左右のデバイスビットを報告しない入力源が混ざると、キーを離しても押下と
    /// 判定し続ける経路が残っている（詳細設計書 §2.3）。**時間で抜ける道が要る。**
    @Test("最大録音時間に達したら解放を待たずに確定する")
    func stopsAtMaxRecordingDuration() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, maxRecordingDuration: .milliseconds(120))
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            // **解放を送らない。** 監視器が解放を取りこぼした状態を模す。
            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            try await waitUntil("解放を待たずに終わる") { await rig.session.state == .idle }

            // 中断ではなく確定として扱う。ユーザーは喋っていたのだから届ける。
            #expect(rig.inserter.inserted == ["整形後テキストです"])
        }
    }

    @Test("上限に達したあとも次の発話を受け付ける")
    func acceptsNextUtteranceAfterMaxDuration() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, maxRecordingDuration: .milliseconds(120))
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("1 発話目が終わる") { !rig.inserter.inserted.isEmpty }

            rig.hotkey.emit(.pressed)
            try await waitUntil("2 発話目の録音が始まる") {
                await Self.label(rig.session.state) == "recording"
            }
            rig.hotkey.emit(.released)
            try await waitUntil("2 発話目が終わる") { rig.inserter.inserted.count == 2 }
        }
    }

    /// **確定から挿入までは、待っているタスクがキャンセルされても最後まで走らねばならない。**
    ///
    /// キャンセルされたタスクの中では `AsyncStream.next()` が即座に nil を返す（実測）。
    /// この経路を素通しにすると `withTimeout` が常に nil を返して整形が必ず縮退し、
    /// `PasteboardInserter` の復元待ち 120 ms も 0 になって、
    /// **⌘V が処理される前にクリップボードが戻り発話が消える**（Task 8 が潰した欠陥）。
    @Test("処理中に run() が畳まれても発話は最後まで届く")
    func completesUtteranceEvenIfRunIsCancelled() async throws {
        try await withTempRoot { root in
            let rig = makeRig(
                root: root, refiner: SpyRefiner(result: "整形後テキストです", delay: .milliseconds(200)))
            let run = Task { await rig.session.run() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.released)
            try await waitUntil("整形へ入る") { await rig.session.state == .refining }

            // アプリ終了に相当する。処理中の発話を巻き添えにしてはならない。
            run.cancel()

            try await waitUntil("挿入が終わる") { !rig.inserter.inserted.isEmpty }
            #expect(rig.inserter.inserted == ["整形後テキストです"], "整形が縮退した")
            #expect(rig.history.entries.count == 1)
        }
    }

    // MARK: - 縮退

    @Test("認識できなかったら挿入も履歴もしない")
    func emptyTranscriptInsertsNothing() async throws {
        try await withTempRoot { root in
            let rig = makeRig(
                root: root,
                transcriber: StubTranscriber(
                    StubTranscriber.Script(finalText: "   ", volatileText: ""))
            )
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }

            try await speak(rig)

            #expect(rig.inserter.inserted.isEmpty)
            #expect(rig.history.entries.isEmpty)
            try await waitUntil("失敗が記録される") {
                await log.states.contains(.failed(.noSpeechRecognized))
            }
        }
    }

    @Test("認識を開始できなければ録音せず失敗を知らせる")
    func reportsTranscriptionFailure() async throws {
        try await withTempRoot { root in
            let rig = makeRig(
                root: root,
                transcriber: StubTranscriber(
                    StubTranscriber.Script(beginError: TranscriptionError.notPrepared))
            )
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }

            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("失敗が届く") {
                await log.states.contains(.failed(.transcriptionUnavailable))
            }

            #expect(rig.audio.startCount == 0, "認識が始まっていないのにタップを張った")
            #expect(await rig.session.state == .idle)
        }
    }

    @Test("タップを張れなければ失敗を知らせ、認識セッションを閉じる")
    func reportsAudioFailure() async throws {
        try await withTempRoot { root in
            let audio = StubAudioCapture()
            audio.startError = AudioCaptureError.notPrepared
            let rig = makeRig(root: root, audio: audio)
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }

            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("失敗が届く") {
                await log.states.contains(.failed(.audioUnavailable))
            }
            try await waitUntil("認識セッションが閉じる") { rig.transcriber.finishCount == 1 }
        }
    }

    @Test("整形が無効なら整形器を呼ばず生テキストを挿入する")
    func skipsRefinementWhenDisabled() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            try rig.settings.update { $0.refinementEnabled = false }

            try await speak(rig)

            #expect(rig.refiner.refinedInputs.isEmpty)
            #expect(rig.inserter.inserted == ["えー、生テキストです"])
            #expect(rig.history.entries.first?.refinedText == nil)
        }
    }

    /// **設定は発話の頭で 1 度だけ写し取る。** 整形と履歴で別々に読み直すと、
    /// 発話の途中で設定が変わったときに 1 発話へ 2 つの設定が混ざる。
    @Test("発話の途中で設定が変わっても 1 発話には 1 つの設定しか使わない")
    func usesOneSettingsSnapshotPerUtterance() async throws {
        try await withTempRoot { root in
            let rig = makeRig(
                root: root,
                refiner: SpyRefiner(result: "整形後テキストです", delay: .milliseconds(300)))
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.released)
            try await waitUntil("整形へ入る") { await rig.session.state == .refining }

            // 整形の最中にロケールを変える。この発話は既に ja-JP で始まっている。
            try rig.settings.update { $0.localeIdentifier = "en-US" }

            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            #expect(
                rig.history.entries.first?.localeIdentifier == "ja-JP",
                "履歴が設定を読み直して、整形と別のロケールを記録した")
        }
    }

    // MARK: - 状態機械としての振る舞い

    @Test("1 発話は idle → recording → finalizing → refining → inserting → idle を辿る")
    func emitsStatesInOrder() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }

            try await speak(rig)
            // **`state` が `.idle` でも、記録側がそこまで消費しているとは限らない。**
            // `stateUpdates` の消費は別タスクなので、待たずに読むと末尾を取りこぼす。
            try await waitUntil("状態の記録が最後まで追いつく") { await log.states.last == .idle }

            // 暫定テキストの更新は何度でも来るので、種類の並びだけを見る。
            let shape = await log.states.map(Self.label)
            #expect(shape.first == "recording")
            #expect(shape.suffix(4) == ["finalizing", "refining", "inserting", "idle"])
        }
    }

    private static func label(_ state: SessionState) -> String {
        switch state {
        case .idle: "idle"
        case .recording: "recording"
        case .finalizing: "finalizing"
        case .refining: "refining"
        case .inserting: "inserting"
        case .failed: "failed"
        }
    }

    @Test("録音中の押下は無視する")
    func ignoresRepeatedPress() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.pressed)
            rig.hotkey.emit(.pressed)
            try await Task.sleep(for: .milliseconds(60))

            #expect(rig.transcriber.beginCount == 1, "録音中に認識を張り直した")
            #expect(rig.audio.startCount == 1)
        }
    }

    @Test("待機中の解放は無視する")
    func ignoresReleaseWhileIdle() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.released)
            rig.hotkey.emit(.cancelled)
            try await Task.sleep(for: .milliseconds(60))

            #expect(rig.audio.stopCount == 0)
            #expect(rig.inserter.inserted.isEmpty)
            #expect(await rig.session.state == .idle)
        }
    }

    @Test("2 発話を続けて処理できる")
    func handlesTwoUtterances() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            for pass in 1...2 {
                rig.hotkey.emit(.pressed)
                try await waitUntil("\(pass) 発話目の録音が始まる") {
                    await rig.session.state == .recording(volatileText: "えー")
                }
                rig.hotkey.emit(.released)
                try await waitUntil("\(pass) 発話目が終わる") { rig.inserter.inserted.count == pass }
            }

            #expect(rig.transcriber.beginCount == 2)
            #expect(rig.transcriber.finishCount == 2)
            #expect(rig.history.entries.count == 2)
        }
    }

    // MARK: - 計測

    @Test("発話ごとに計測値が残る")
    func recordsMetrics() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, refiner: SpyRefiner(result: "整形後", delay: .milliseconds(120)))
            try await speak(rig)

            let sample = try #require(await rig.session.latestMetrics)
            #expect(sample.refineMs >= 100, "整形の所要が計測されていない（\(sample.refineMs) ms）")
            // **`total` と `totalMs` の関係はここで表明しない。**
            // `total` は `finalize + refine + insert` と**定義されている**ので、
            // 同じ値から同じ式を組み立てて比べても決して落ちない。
            // `totalMs` を切り捨ての和と比べる形（`>= 和` / `<= 和 + 2`）も同じで、
            // **どちらも床関数の恒等式なのでどんな実装でも成り立つ。**
            // 意味のある表明が見つからないので置かない（`refineMs >= 100` が実質を見ている）。
            #expect(sample.meetsTarget)
        }
    }

    /// **計測値は発話ごとに畳む。** 中断や失敗で終わった発話の後に読んだとき、
    /// 前の発話の値が「今の発話の計測値」として返ってはならない。
    @Test("中断した発話の後に前の発話の計測値が残らない")
    func clearsMetricsBetweenUtterances() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            // 1 発話目は成功させ、計測値を残す。
            rig.hotkey.emit(.pressed)
            try await waitUntil("1 発話目の録音") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.released)
            try await waitUntil("1 発話目が終わる") { !rig.inserter.inserted.isEmpty }
            #expect(await rig.session.latestMetrics != nil)

            // 2 発話目は中断する。挿入していないので計測値は無い。
            rig.hotkey.emit(.pressed)
            try await waitUntil("2 発話目の録音") { await Self.label(rig.session.state) == "recording" }
            rig.hotkey.emit(.cancelled)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            #expect(await rig.session.latestMetrics == nil, "前の発話の計測値が残っている")
        }
    }

    /// `droppedBufferCount` はインスタンス生涯の累計なので、
    /// **差分を取っていないと前の発話ぶんまで数えてしまう**（Task 7 申し送り）。
    @Test("捨てたバッファの数は発話ごとの差分で残る")
    func countsDroppedBuffersPerUtterance() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            // 発話の前に 3 件捨てた体にする。これは今回の発話のぶんではない。
            rig.audio.dropBuffers(3)

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            rig.audio.dropBuffers(2)
            rig.hotkey.emit(.released)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            let sample = try #require(await rig.session.latestMetrics)
            #expect(sample.droppedBuffers == 2, "累計をそのまま報告している")
        }
    }

    // MARK: - 起動

    /// マイク権限が無いなど `prepare()` が投げた場合、**起動時にそれを知らせる。**
    /// 黙って進むと、ユーザーには「押しても何も起きない」としか見えない（FR-10）。
    @Test("音声エンジンを準備できなければ起動時に知らせる")
    func reportsAudioWarmUpFailure() async throws {
        try await withTempRoot { root in
            let audio = StubAudioCapture()
            audio.prepareError = AudioCaptureError.microphoneAccessNotGranted(.denied)
            let rig = makeRig(root: root, audio: audio)
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }

            await rig.session.warmUp()

            try await waitUntil("失敗が届く") {
                await log.states.contains(.failed(.audioUnavailable))
            }
            #expect(await rig.session.state == .idle)
        }
    }

    /// 捨て推論は実測でコールド 1.9〜3.3 秒掛かる。**これを待ってから
    /// ホットキーを読み始めると、起動直後の数秒間、押しても何も起きない。**
    @Test("起動は整形器の捨て推論を待たない")
    func startupDoesNotBlockOnPrewarm() async throws {
        try await withTempRoot { root in
            let refiner = SpyRefiner(result: "整形後テキストです")
            refiner.prewarmDelay = .seconds(3)
            let rig = makeRig(root: root, refiner: refiner)

            let started = ContinuousClock.now
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }
            let elapsed = ContinuousClock.now - started

            #expect(elapsed < .seconds(1), "捨て推論の完了を待っている（実測 \(elapsed)）")
            #expect(rig.audio.prepareCount == 1, "音声エンジンのウォームアップは待つ")

            // **待たないことと、呼ばないことは違う。** 上の検査だけだと、捨て推論を
            // まるごと消す変更が素通りする（消せば当然「待っていない」ので通る）。
            try await waitUntil("捨て推論が投げられている") { refiner.prewarmCount == 1 }
        }
    }
}

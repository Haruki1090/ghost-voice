import Foundation
import Testing

@testable import GhostVoiceCore

/// **終了要求で録音の途中を打ち切ったとき、その発話はどこへ行くのか。**
///
/// ## この世界がテストに 1 つも無かった
///
/// 実機 2026-08-15（利用者の機体）:
///
/// ```
/// 16:53:55  [HUD] 窓を出しました                              ← 録音開始
/// 16:54:02  [終了] 進行中の発話を待っています…                  ← 録音中に SIGTERM
/// 16:54:12  [終了] 10.0 seconds 待っても待機へ戻りませんでした。打ち切ります。
/// 16:54:12  [終了] 発話の途中で終了したため、この発話は挿入されませんでした。
/// ```
///
/// **その時刻の履歴エントリは存在しなかった。** 打ち切られた発話は、欄にも
/// クリップボードにも履歴にも、**どこにも残っていなかった。**
/// この製品の最優先原則「発話を失わない」に正面から反する。
///
/// **ESC による中断は `.notInserted` として履歴へ残す**（基本設計書 §4）のに、
/// 終了の打ち切りだけ穴が空いていた。**同じ「途中でやめる」なのに片側だけである。**
///
/// ## ここで駆動するもの
///
/// `Shutdown.perform` の `stopHotkey` は監視器のイベント列を終端する。
/// `DictationSession.run()` はそこでループを抜ける——**代役の監視器でも
/// まったく同じことが起きる**ので、この経路は決定的に踏める。
/// 実機でしか踏めなかったのは、駆動する検査が無かったからである。
@Suite("終了で打ち切った発話の行き先")
struct ShutdownSalvageTests {

    private struct Rig {
        let session: DictationSession
        let hotkey: StubHotkeyMonitor
        let audio: StubAudioCapture
        let transcriber: StubTranscriber
        let history: HistoryStore
    }

    private func makeRig(
        root: URL,
        historyLimit: Int = 50,
        transcriber: StubTranscriber = StubTranscriber(),
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { false }
    ) -> Rig {
        let hotkey = StubHotkeyMonitor()
        let audio = StubAudioCapture()
        let history = HistoryStore(rootURL: root, limit: historyLimit)
        let session = DictationSession.forTests(
            settings: SettingsStore(rootURL: root),
            hotkey: hotkey,
            audio: audio,
            transcriber: transcriber,
            refiner: SpyRefiner(result: "整形後"),
            inserter: RecordingInserter(),
            history: history,
            vocabulary: VocabularyStore(rootURL: root),
            isSecureInputEnabled: isSecureInputEnabled,
            postEventAuthorization: PostEventAuthorization(probe: { false }),
            maxRecordingDuration: .seconds(120),
            finalizeDeadline: .seconds(5))
        return Rig(
            session: session, hotkey: hotkey, audio: audio, transcriber: transcriber,
            history: history)
    }

    /// **押しっぱなしのまま終了要求が来て、猶予が尽きる**ところまで進める。
    ///
    /// 猶予を短くしてあるのは待ち時間を削るためで、**通る経路は既定と同じ 1 本**である
    /// （`Shutdown.perform`）。
    /// - Parameter speak: **録音が始まってから**呼ばれる。認識結果を流すのはここである
    ///   （`begin()` の前に流しても、ストリームがまだ無いので黙って捨てられる）。
    private func shutdownWhileHoldingTheKey(
        _ rig: Rig, grace: Duration = .milliseconds(80),
        speak: @Sendable () async throws -> Void = {}
    ) async throws -> [ShutdownAnnouncement] {
        let run = Task { await rig.session.run() }
        rig.hotkey.emit(.pressed)
        try await waitUntil("録音が始まる") {
            if case .recording = await rig.session.state { return true }
            return false
        }
        try await speak()

        let log = AnnouncementLog()
        await Shutdown.perform(
            grace: grace, poll: .milliseconds(10),
            // **キーは離さない。** 猶予が尽きて打ち切られるのがこの検査の主題である。
            stopHotkey: { rig.hotkey.stop() },
            awaitRun: { await run.value },
            isBusy: { await rig.session.isBusy },
            salvage: { await rig.session.shutdownSalvage },
            announce: { log.record($0) })
        return log.announcements
    }

    /// 流した暫定が**状態機械へ届くまで**待つ。
    /// **固定 sleep で「届いただろう」と決めない**（認識結果は別タスク経由で届く）。
    private func waitForVolatile(_ rig: Rig, _ text: String) async throws {
        try await waitUntil("暫定『\(text)』が届く") {
            if case .recording(let current) = await rig.session.state { return current == text }
            return false
        }
    }

    // MARK: - 残ること

    /// **最優先の 1 件。** 打ち切ってもテキストが残ること。
    @Test("猶予切れで打ち切った発話は、そこまでのテキストが履歴に残る")
    func interruptedUtteranceIsRetainedInHistory() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let announcements = try await shutdownWhileHoldingTheKey(rig) {
                rig.transcriber.emitVolatile("こんにちは。いま話しかけています")
                try await self.waitForVolatile(rig, "こんにちは。いま話しかけています")
            }

            let entries = rig.history.entries
            #expect(entries.count == 1, "打ち切った発話がどこにも残っていない")
            #expect(entries.first?.rawText == "こんにちは。いま話しかけています")
            // **挿入していないので `.notInserted`**（ESC で中断した発話と同じ扱い）。
            #expect(entries.first?.insertionMethod == .notInserted)
            #expect(entries.first?.refinedText == nil, "整形していないのに整形結果が入っている")
            #expect(
                announcements.contains(
                    .utteranceInterrupted(.retainedInHistory(provisional: true))),
                "履歴に在ることを告げていない: \(announcements)")
        }
    }

    /// **確定していないテキストであることが後から判ること。**
    /// 確定済みと同じ顔で並ぶと、利用者は「認識がおかしい」と読む。
    @Test("打ち切りで残した発話には暫定の印が付く")
    func salvagedEntryIsMarkedProvisional() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            _ = try await shutdownWhileHoldingTheKey(rig) {
                rig.transcriber.emitVolatile("とちゅうまで")
                try await self.waitForVolatile(rig, "とちゅうまで")
            }
            #expect(rig.history.entries.first?.isProvisional == true, "暫定の印が無い")
        }
    }

    /// **確定済みの前半を落とさないこと。**
    /// 長い発話では確定が録音中にも届く。暫定だけを見ると前半がまるごと消える。
    @Test("確定済みの前半と未確定の末尾を繋いで残す")
    func salvageJoinsFinalAndVolatile() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            _ = try await shutdownWhileHoldingTheKey(rig) {
                rig.transcriber.emitFinal("前半は確定しています。")
                rig.transcriber.emitVolatile("後半はまだ確定していません")
                try await self.waitForVolatile(rig, "後半はまだ確定していません")
            }
            #expect(rig.history.entries.first?.rawText == "前半は確定しています。後半はまだ確定していません")
        }
    }

    // MARK: - 残せなかったとき

    /// **残せなかったのなら、そう言うこと。**
    /// 「挿入されませんでした」だけでは、どこにも無いのか履歴にはあるのかが判らない。
    @Test("履歴へ残せなかったら、どこにも無いことを告げる")
    func saysSoWhenNothingCouldBeRetained() async throws {
        try await withTempRoot { root in
            // 上限 0。**設定画面のステッパーで到達できる構成**であり、
            // `append` は何も保存せず例外も投げない（最終レビュー A-1 と同じ穴）。
            let rig = makeRig(root: root, historyLimit: 0)
            let announcements = try await shutdownWhileHoldingTheKey(rig) {
                rig.transcriber.emitVolatile("どこにも残らない発話")
                try await self.waitForVolatile(rig, "どこにも残らない発話")
            }

            #expect(rig.history.entries.isEmpty)
            #expect(
                announcements.contains(.utteranceInterrupted(.lost)),
                "どこにも無いことを告げていない: \(announcements)")
            #expect(
                !announcements.contains(
                    .utteranceInterrupted(.retainedInHistory(provisional: true))),
                "残っていないのに『履歴にあります』と言っている")
        }
    }

    /// **`isBusy` で代用してはならない。**
    /// 救出は `finishIdle()` まで走るので、成功直後の `isBusy` は偽である。
    /// そこだけを見ていると**打ち切ったことすら告げずに終わる。**
    @Test("救出に成功しても、打ち切ったことは告げる")
    func stillAnnouncesAfterASuccessfulSalvage() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let announcements = try await shutdownWhileHoldingTheKey(rig) {
                rig.transcriber.emitVolatile("残った発話")
                try await self.waitForVolatile(rig, "残った発話")
            }
            #expect(await !rig.session.isBusy, "救出後も処理中のままになっている")
            #expect(
                announcements.contains { if case .utteranceInterrupted = $0 { true } else { false } },
                "打ち切ったことを 1 度も告げていない: \(announcements)")
        }
    }

    // MARK: - 例外（secure input）

    /// **唯一の例外。** パスワード入力中は履歴も作らない
    /// （基本設計書 §7 / 要件定義書 FR-4）。ここを抜くと `history.json` へ
    /// パスワードが入る——**挿入側にだけ例外を置いた実装が実際にそうなった。**
    @Test("secure input 中は打ち切っても履歴を作らない")
    func secureInputLeavesNothingBehind() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, isSecureInputEnabled: { true })
            let announcements = try await shutdownWhileHoldingTheKey(rig) {
                rig.transcriber.emitVolatile("ぱすわーどかもしれない")
                try await self.waitForVolatile(rig, "ぱすわーどかもしれない")
            }

            #expect(rig.history.entries.isEmpty, "secure input 中の発話が履歴へ入った")
            #expect(announcements.contains(.utteranceInterrupted(.refusedSecureInput)))
        }
    }

    // MARK: - 打ち切っていないとき

    /// **何も抱えていなければ、打ち切りのことは言わない。**
    /// 毎回言うと、本当に打ち切った回が埋もれる。
    @Test("待機中に終了しても打ち切りのことは言わない")
    func nothingIsAnnouncedWhenIdle() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let run = Task { await rig.session.run() }
            let log = AnnouncementLog()
            await Shutdown.perform(
                grace: .seconds(1), poll: .milliseconds(10),
                stopHotkey: { rig.hotkey.stop() },
                awaitRun: { await run.value },
                isBusy: { await rig.session.isBusy },
                salvage: { await rig.session.shutdownSalvage },
                announce: { log.record($0) })

            #expect(rig.history.entries.isEmpty)
            #expect(
                !log.announcements.contains {
                    if case .utteranceInterrupted = $0 { true } else { false }
                }, "抱えていないのに打ち切りを告げている: \(log.announcements)")
        }
    }

    /// **一言も認識されていなければ、空の履歴を作らない。**
    /// 失うものが無いので告げもしない。
    @Test("認識が空なら履歴も作らず、打ち切りも告げない")
    func emptyRecognitionLeavesNoEntry() async throws {
        try await withTempRoot { root in
            // 暫定を 1 件も流さない代役。
            let rig = makeRig(
                root: root, transcriber: StubTranscriber(StubTranscriber.Script(volatileText: "")))
            let announcements = try await shutdownWhileHoldingTheKey(rig)
            #expect(rig.history.entries.isEmpty)
            #expect(
                !announcements.contains {
                    if case .utteranceInterrupted = $0 { true } else { false }
                }, "残すものが無いのに告げている: \(announcements)")
        }
    }

    /// **キーを離せば普通に完走すること。** 救出の追加で通常経路を壊していないか。
    @Test("猶予の内側でキーを離せば、挿入まで走って救出は起きない")
    func releasingTheKeyStillCompletesNormally() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root)
            let run = Task { await rig.session.run() }
            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }

            let release = Task {
                try? await Task.sleep(for: .milliseconds(30))
                rig.audio.emit(frames: 1_600)
                rig.hotkey.emit(.released)
            }
            defer { release.cancel() }

            let log = AnnouncementLog()
            await Shutdown.perform(
                grace: .seconds(5), poll: .milliseconds(10),
                stopHotkey: { rig.hotkey.stop() },
                awaitRun: { await run.value },
                isBusy: { await rig.session.isBusy },
                salvage: { await rig.session.shutdownSalvage },
                announce: { log.record($0) })

            #expect(await rig.session.shutdownSalvage == .nothingHeld, "普通に完走したのに救出が走った")
            let entry = rig.history.entries.first
            #expect(entry?.isProvisional == false, "確定した発話に暫定の印が付いている")
            #expect(entry?.insertionMethod != .notInserted, "挿入したのに未挿入で記録している")
        }
    }
}

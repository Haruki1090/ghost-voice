import Foundation
import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

/// **FR-11「ホットキーを設定画面から変更できる」の画面側。**
///
/// 打鍵の判定そのものは Core にある（`HotkeyCaptureState` / `CGEventTapHotkeyMonitor`）。
/// ここが見るのは **画面が Core の規則を書き直していないこと**と、
/// **捕獲の状態が画面に出ていること**である。
@Suite("設定画面の打鍵の捕獲（FR-11）")
@MainActor
struct SettingsHotkeyCaptureTests {

    // MARK: - 捕獲

    @Test("修飾キー単独を捕まえて PTT の draft へ入れる（保存はしない）")
    func capturesModifierOnlyIntoDraft() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let hotkey = HotkeyControlSpy()
        let model = try makeModel(in: temp, hotkey: hotkey)

        model.beginCapture(.pushToTalk)
        #expect(model.capturingField == .pushToTalk, "捕獲中であることが画面に出ていない")
        #expect(hotkey.isCapturing)

        hotkey.deliver(.captured(CapturedHotkey(keyCode: 0x3A, modifiers: [.option])))
        await waitForCaptureToSettle(model)

        #expect(model.draft.hotkey == (try HotkeyBinding(keyCode: 0x3A, modifiers: [.option])))
        #expect(model.capturingField == nil, "決着したのに捕獲中のまま")
        #expect(!temp.exists("settings.json"), "捕獲だけで保存している")
    }

    @Test("修飾キー + 文字キーを捕まえて Undo の draft へ入れる")
    func capturesComboIntoUndoDraft() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let hotkey = HotkeyControlSpy()
        let model = try makeModel(in: temp, hotkey: hotkey)

        model.beginCapture(.undo)
        hotkey.deliver(.captured(CapturedHotkey(keyCode: 0x07, modifiers: [.control, .command])))
        await waitForCaptureToSettle(model)

        #expect(model.draft.undoHotkey.keyCode == 0x07)
        #expect(model.draft.undoHotkey.modifiers == [.control, .command])
        // **PTT は変わっていない。** 欄を取り違えていない。
        #expect(model.draft.hotkey == .rightOption)
    }

    /// **規則は Core に 1 つだけ**（`HotkeyBinding.init`）。画面は理由を出すだけである。
    @Test("`HotkeyBinding` が認めない組は、どの規則に触れたかを添えて断る")
    func rejectsInvalidCaptureWithCoreExplanation() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let hotkey = HotkeyControlSpy()
        let model = try makeModel(in: temp, hotkey: hotkey)

        model.beginCapture(.pushToTalk)
        // 範囲外のキーコード（手編集の打ち間違いと同じ形）。
        hotkey.deliver(.captured(CapturedHotkey(keyCode: 610, modifiers: [])))
        await waitForCaptureToSettle(model)

        #expect(model.draft.hotkey == .rightOption, "認めない組が draft へ入った")
        let message = try #require(model.captureMessage)
        // **文言は Core が持っている**（`HotkeyBindingError.explanation`）。
        #expect(message == HotkeyBindingError.keyCodeOutOfRange(610).explanation)
    }

    /// **修飾キー単独に足された修飾キーは、Core の案内どおり落ちる。**
    /// 足しても押した瞬間に単独で発火する（実測 / §2.3）ので、足させないのが正しい。
    @Test("修飾キー単独に混ざった修飾キーは落ちる")
    func extraModifiersAreDroppedOnCapture() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let hotkey = HotkeyControlSpy()
        let model = try makeModel(in: temp, hotkey: hotkey)

        model.beginCapture(.pushToTalk)
        hotkey.deliver(.captured(CapturedHotkey(keyCode: 0x3D, modifiers: [.option, .shift])))
        await waitForCaptureToSettle(model)

        #expect(model.draft.hotkey == .rightOption)
        #expect(model.draft.hotkey.modifiers == [.option])
        #expect(model.captureMessage == nil, "落とせたのに断っている")
    }

    @Test("ESC の取り消しではキーが変わらず、取りやめたことを言う")
    func cancelledCaptureChangesNothing() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let hotkey = HotkeyControlSpy()
        let model = try makeModel(in: temp, hotkey: hotkey)

        model.beginCapture(.pushToTalk)
        hotkey.deliver(.cancelled)
        await waitForCaptureToSettle(model)

        #expect(model.draft.hotkey == .rightOption)
        #expect(model.capturingField == nil)
        #expect(model.captureMessage?.contains("取りやめ") == true)
    }

    /// **閉じ忘れると PTT が効かない**（捕獲中は PTT が発火しない）。
    @Test("取りやめ・破棄では監視器の捕獲モードを必ず閉じる")
    func cancelClosesTheMonitorCaptureMode() throws {
        let temp = try SettingsHistoryTempDirectory()
        let hotkey = HotkeyControlSpy()
        let model = try makeModel(in: temp, hotkey: hotkey)

        model.beginCapture(.pushToTalk)
        model.cancelCapture()
        #expect(!hotkey.isCapturing)
        #expect(model.capturingField == nil)

        model.beginCapture(.undo)
        model.discard()
        #expect(!hotkey.isCapturing, "破棄したのに捕獲が残っている")
    }

    /// 2 度目の捕獲を始めたら、**古い決着は捨てる。**
    /// 捨てないと、取り違えた欄へ後からキーが入る。
    @Test("欄を切り替えたら、前の欄の決着は捨てる")
    func staleOutcomeIsDiscarded() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let hotkey = HotkeyControlSpy()
        let model = try makeModel(in: temp, hotkey: hotkey)

        model.beginCapture(.pushToTalk)
        model.beginCapture(.undo)
        // 監視器は前の捕獲を閉じてから新しいものを開いている。
        #expect(hotkey.beginCount == 2)
        #expect(hotkey.endCount >= 1)

        hotkey.deliver(.captured(CapturedHotkey(keyCode: 0x07, modifiers: [.control, .command])))
        await waitForCaptureToSettle(model)
        #expect(model.draft.hotkey == .rightOption, "古い欄へ入った")
        #expect(model.draft.undoHotkey.keyCode == 0x07)
    }

    /// **黙って何も起きない形にしない。**
    @Test("キー監視が動いていなければ、捕獲できない理由を言う")
    func explainsWhenTheMonitorIsMissing() throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp, hotkey: nil)

        model.beginCapture(.pushToTalk)

        #expect(model.capturingField == nil)
        let message = try #require(model.captureMessage)
        #expect(message.contains("settings.json"), "手編集という逃げ道を案内していない")
    }

    // MARK: - 監視器への反映（**保存しただけでは効かない**）

    /// フェーズ 1 では PTT キーを変えてもプロセスを再起動するまで効かなかった
    /// （持ち越し項目 10）。**ここが FR-11 の「変更できる」の実体である。**
    @Test("保存すると PTT キーが監視器へ反映される")
    func savingRebindsThePushToTalkKey() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let hotkey = HotkeyControlSpy()
        let model = try makeModel(in: temp, hotkey: hotkey)

        try model.setHotkey(keyCode: 0x3A, modifiers: [.option])  // 左 Option
        await model.save()

        #expect(hotkey.reboundPushToTalk == [try HotkeyBinding(keyCode: 0x3A, modifiers: [.option])])
        guard case .saved(_, let rebound, _) = try #require(model.lastSave) else {
            Issue.record("保存できていない: \(String(describing: model.lastSave))")
            return
        }
        #expect(rebound.pushToTalk)
        #expect(!rebound.undo)
        #expect(model.lastSave?.message.contains("PTT キーを反映") == true)
    }

    @Test("PTT キーを変えていなければ、監視器を触らない（タップの張り替えは約 40 ms 掛かる）")
    func unchangedHotkeyDoesNotRebind() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let hotkey = HotkeyControlSpy()
        let model = try makeModel(in: temp, hotkey: hotkey)

        model.draft.historyLimit = 12
        await model.save()

        #expect(hotkey.reboundPushToTalk.isEmpty)
    }

    /// **ファイルは書けているので「一部だけ反映された」と言う。黙らない。**
    @Test("監視器への反映に失敗したら、一部だけ反映されたことを告げる")
    func failedRebindIsReportedAsPartial() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let hotkey = HotkeyControlSpy(rebindError: HotkeyError.tapDisabledAtStart)
        let model = try makeModel(in: temp, hotkey: hotkey)

        try model.setHotkey(keyCode: 0x3A, modifiers: [.option])
        await model.save()

        guard case .writeFailed(_, let partial) = try #require(model.lastSave) else {
            Issue.record("顛末が違う: \(String(describing: model.lastSave))")
            return
        }
        #expect(partial)
        // **ディスクには新しいキーが入っている**（次の起動では効く）。
        #expect(SettingsStore(rootURL: temp.url).settings.hotkey.keyCode == 0x3A)
    }

    // MARK: - 補助

    private func makeModel(
        in temp: SettingsHistoryTempDirectory,
        hotkey: (any HotkeyControlling)?,
        hotkeyFailure: HotkeyError? = nil
    ) throws -> SettingsViewModel {
        SettingsViewModel(
            settings: SettingsStore(rootURL: temp.url),
            vocabulary: VocabularyStore(rootURL: temp.url),
            history: HistoryStore(rootURL: temp.url, limit: 50),
            session: nil,
            hotkey: hotkey,
            hotkeyFailure: hotkeyFailure,
            directory: temp.url)
    }

    /// 決着は `Task { @MainActor in … }` で MainActor へ持ち上げられる。
    ///
    /// **`capturingField` が nil へ戻ることが決着の合図である**（成功でも失敗でも
    /// 取り消しでも同じ）。期限を切ってあるので、届かなければ検査が落ちる
    /// ——待ち続けて停止にしない。
    private func waitForCaptureToSettle(
        _ model: SettingsViewModel, function: String = #function
    ) async {
        for _ in 0..<1_000 {
            if model.capturingField == nil { return }
            await Task.yield()
        }
        Issue.record("捕獲の決着が届かなかった: \(function)")
    }
}

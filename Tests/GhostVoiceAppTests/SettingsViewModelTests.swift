import Foundation
import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

/// 設定画面（FR-11）の振る舞い。
@Suite("設定画面（FR-11）")
@MainActor
struct SettingsViewModelTests {

    // MARK: - ホットキーの妥当性（**検査は Core に 1 つだけ**）

    @Test("PTT と修飾キーが衝突する Undo キーは保存できず、ファイルは 1 バイトも変わらない")
    func rejectsConflictingUndoHotkey() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)

        // 既定の PTT は右 Option。**⌥ を含む Undo キーはこれに当たる**（§8.3）。
        try model.setUndoHotkey(keyCode: 0x06, modifiers: [.option, .command])

        #expect(model.hotkeyConflict == .hotkeyConflict, "保存を押す前から画面に出ている")
        await model.save()

        #expect(model.lastSave == .rejectedHotkeyConflict)
        #expect(!temp.exists("settings.json"), "1 バイトも書いていない")
    }

    @Test("修飾キー単独のキーに、追加の修飾キーを付けさせない（付けても無視されて単独で発火する）")
    func modifierOnlyKeyDropsExtraModifiers() throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)

        // 右 Option（0x3D）を押しながら ⇧ も押していた、という入力。
        try model.setHotkey(keyCode: 0x3D, modifiers: [.option, .shift])

        // **⇧ は落ちる。** 正しいのは「そのキー自身の修飾キー」だけである。
        #expect(model.draft.hotkey == HotkeyBinding.rightOption)
        #expect(model.draft.hotkey.modifiers == [.option])
    }

    @Test("範囲外のキーコードは `HotkeyBindingError` として利用者へ返る")
    func rejectsOutOfRangeKeyCode() throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)

        #expect(throws: HotkeyBindingError.keyCodeOutOfRange(610)) {
            try model.setHotkey(keyCode: 610, modifiers: [])
        }
        #expect(model.draft.hotkey == HotkeyBinding.rightOption, "draft は変わっていない")
    }

    @Test("Undo キーの単体変更は、PTT との衝突があってもその場では投げない（途中の状態を許す）")
    func undoHotkeyEditDoesNotThrowOnConflict() throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)

        // 先に Undo を ⌥ 付きにしてから、PTT を ⌥ でないものへ移す、という順序を許す。
        try model.setUndoHotkey(keyCode: 0x06, modifiers: [.option, .command])
        #expect(model.hotkeyConflict != nil)

        try model.setHotkey(keyCode: 0x3E, modifiers: [.control])  // 右 Control
        #expect(model.hotkeyConflict == nil, "PTT を移したら衝突は解ける")
    }

    // MARK: - 保存

    @Test("保存すると、設定・辞書・履歴の上限がまとめて反映される")
    func saveAppliesEverything() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let session = SettingsSessionSpy()
        let history = HistoryStore(rootURL: temp.url, limit: 50)
        let model = try makeModel(in: temp, session: session, history: history)

        model.draft.refinementEnabled = false
        model.draft.historyLimit = 5
        model.vocabularyTerms = [VocabularyTerm(canonical: "Ghost Voice", misheard: ["ゴーストボイス"])]
        await model.save()

        #expect(model.lastSave?.isFailure == false)
        let reloaded = SettingsStore(rootURL: temp.url)
        #expect(reloaded.settings.refinementEnabled == false)
        #expect(reloaded.settings.historyLimit == 5)
        #expect(VocabularyStore(rootURL: temp.url).terms.count == 1)
        #expect(history.limit == 5, "実行中の履歴ストアへも反映される（次の発話を待たない）")
    }

    @Test("ロケールを変えると `prepareTranscriber` を通る")
    func localeChangeGoesThroughPrepare() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let session = SettingsSessionSpy()
        let model = try makeModel(in: temp, session: session)

        model.draft.localeIdentifier = "en-US"
        await model.save()

        #expect(
            session.prepared == [
                SettingsSessionSpy.Prepared(localeIdentifier: "en-US", kind: .dictation)
            ])
        #expect(model.lastSave == .saved(
            transcriberReloaded: true, undoHotkeyRebound: false, quarantined: []))
    }

    @Test("ロケールを変えていなければ `prepareTranscriber` を呼ばない（ロケール枠は有限）")
    func unchangedLocaleDoesNotPrepare() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let session = SettingsSessionSpy()
        let model = try makeModel(in: temp, session: session)

        model.draft.refinementTimeoutMs = 800
        await model.save()

        #expect(session.prepared.isEmpty)
    }

    @Test("録音中は言語を切り替えられず、**ファイルも 1 バイトも書かない**")
    func busySessionRejectsSaveWithoutWriting() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let session = SettingsSessionSpy(prepareError: DictationSessionError.busy)
        let model = try makeModel(in: temp, session: session)

        model.draft.localeIdentifier = "en-US"
        await model.save()

        #expect(model.lastSave == .rejectedSessionBusy)
        #expect(!temp.exists("settings.json"), "画面には en-US、認識器は ja-JP、という状態を作らない")
    }

    @Test("認識器の準備そのものが失敗しても、ファイルは 1 バイトも変わらない")
    func failedPreparationDoesNotWrite() async throws {
        struct Unavailable: Error {}
        let temp = try SettingsHistoryTempDirectory()
        let session = SettingsSessionSpy(prepareError: Unavailable())
        let model = try makeModel(in: temp, session: session)

        model.draft.localeIdentifier = "en-US"
        await model.save()

        if case .rejectedTranscriberUnavailable = model.lastSave {} else {
            Issue.record("認識器の失敗として返っていない: \(String(describing: model.lastSave))")
        }
        #expect(!temp.exists("settings.json"))
    }

    @Test("Undo キーを変えたら監視器へ反映する（保存しただけでは効かない）")
    func undoHotkeyIsReboundOnSave() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let session = SettingsSessionSpy()
        let model = try makeModel(in: temp, session: session)

        let newBinding = try HotkeyBinding(keyCode: 0x07, modifiers: [.control, .command])  // ⌃⌘X
        try model.setUndoHotkey(keyCode: 0x07, modifiers: [.control, .command])
        await model.save()

        #expect(session.rebound == [newBinding])
    }

    @Test("Undo キーを変えていなければ監視器へは触らない")
    func unchangedUndoHotkeyDoesNotRebind() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let session = SettingsSessionSpy()
        let model = try makeModel(in: temp, session: session)

        model.draft.historyLimit = 20
        await model.save()

        #expect(session.rebound.isEmpty)
    }

    @Test("辞書が上限を超えたら保存しない")
    func rejectsTooManyTerms() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)

        model.vocabularyTerms = (0...VocabularyStore.maxTerms).map {
            VocabularyTerm(canonical: "語\($0)")
        }
        await model.save()

        #expect(model.lastSave == .rejectedTooManyTerms(limit: VocabularyStore.maxTerms))
        #expect(!temp.exists("settings.json"))
    }

    @Test("セッションが無くても（`--shell-only`）保存できる")
    func savesWithoutSession() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp, session: nil)

        model.draft.localeIdentifier = "en-US"
        await model.save()

        #expect(model.lastSave == .saved(
            transcriberReloaded: false, undoHotkeyRebound: false, quarantined: []))
        #expect(SettingsStore(rootURL: temp.url).settings.localeIdentifier == "en-US")
    }

    @Test("元に戻すとディスクの内容へ戻る")
    func discardRestores() throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)

        model.draft.historyLimit = 999
        #expect(model.hasUnsavedChanges)
        model.discard()
        #expect(!model.hasUnsavedChanges)
        #expect(model.draft.historyLimit == Settings.default.historyLimit)
    }

    // MARK: - 表示

    @Test("修飾キー単独のバインドは左右が判る名前で出す")
    func hotkeyLabelKeepsSide() {
        #expect(HotkeyLabel.text(for: .rightOption) == "右 Option")
        #expect(HotkeyLabel.text(for: .controlCommandZ) == "⌃⌘Z")
    }

    @Test("表に無いキーコードは、元の数へ戻せる形で出す")
    func hotkeyLabelKeepsUnknownKeyCode() throws {
        let binding = try HotkeyBinding(keyCode: 0x7A, modifiers: [.command])
        #expect(HotkeyLabel.text(for: binding) == "⌘キーコード 0x7A")
    }

    // MARK: - 道具

    private func makeModel(
        in temp: SettingsHistoryTempDirectory,
        session: (any SettingsSessionControlling)? = nil,
        history: HistoryStore? = nil
    ) throws -> SettingsViewModel {
        SettingsViewModel(
            settings: SettingsStore(rootURL: temp.url),
            vocabulary: VocabularyStore(rootURL: temp.url),
            history: history ?? HistoryStore(rootURL: temp.url, limit: 50),
            session: session,
            directory: temp.url)
    }
}

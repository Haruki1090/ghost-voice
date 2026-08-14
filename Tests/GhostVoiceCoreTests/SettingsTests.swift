import Foundation
import Testing
@testable import GhostVoiceCore

@Suite("Settings")
struct SettingsTests {

    @Test("既定値が仕様どおり")
    func defaults() {
        let s = Settings.default
        #expect(s.hotkey == .rightOption)
        #expect(s.undoHotkey == .controlCommandZ)
        #expect(s.localeIdentifier == "ja-JP")
        #expect(s.transcriberKind == .dictation)
        #expect(s.refinementEnabled)
        // 打ち切りは NFR-P4 の目標値 500 ms ではなく NFR-P6a の予算から決まる（詳細設計書 §10）。
        #expect(s.refinementTimeoutMs == 750)
        #expect(s.historyLimit == 50)
    }

    @Test("未知のキーを含む JSON を読み込める")
    func decodesWithUnknownKeys() throws {
        let json = """
        {"hotkey":{"keyCode":61,"modifiers":["option"]},
         "undoHotkey":{"keyCode":6,"modifiers":["control","command"]},
         "localeIdentifier":"en-US","transcriberKind":"speech",
         "refinementEnabled":false,"refinementTimeoutMs":800,
         "historyLimit":10,"futureFeature":"ignored"}
        """
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(s.localeIdentifier == "en-US")
        #expect(s.transcriberKind == .speech)
        #expect(s.refinementTimeoutMs == 800)
        // 複数フラグの修飾キーが実際に復元されること。
        // 名前が一致しなくても throw せず空集合になるため、明示的に確かめる。
        #expect(s.undoHotkey == .controlCommandZ)
    }

    // MARK: - ホットキーの妥当性（詳細設計書 §12-9 の受け入れ条件）

    /// **Undo ホットキーに ⌥ を含めてはならない**（詳細設計書 §8.3）。PTT の既定が
    /// 右 Option なので、⌥ を含む Undo を押すと**録音が始まる。** これまでこの検査は
    /// `SettingsStore.update` にしか無く、**手編集した `settings.json` は素通りしていた**
    /// （持ち越し項目 12 / 最終レビュー M-7）。
    @Test("手編集の JSON でも PTT と衝突する Undo キーは弾かれる")
    func decodeRejectsConflictingUndoHotkey() {
        let json = """
            {"hotkey":{"keyCode":61,"modifiers":["option"]},
             "undoHotkey":{"keyCode":6,"modifiers":["option","command"]},
             "localeIdentifier":"ja-JP","transcriberKind":"dictation",
             "refinementEnabled":true,"refinementTimeoutMs":750,"historyLimit":50}
            """
        #expect(throws: SettingsError.hotkeyConflict) {
            try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        }
    }

    /// PTT が修飾キー単独でなくなれば、⌥ を含む Undo キーは正当になる。
    /// 「⌥ 禁止」を固定値として焼き付けていないことの反証。
    @Test("PTT が ⌥ を使わないなら ⌥ を含む Undo キーは通る")
    func decodeAcceptsOptionUndoWhenPTTDoesNotUseOption() throws {
        let json = """
            {"hotkey":{"keyCode":60,"modifiers":["shift"]},
             "undoHotkey":{"keyCode":6,"modifiers":["option","command"]},
             "localeIdentifier":"ja-JP","transcriberKind":"dictation",
             "refinementEnabled":true,"refinementTimeoutMs":750,"historyLimit":50}
            """
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(s.undoHotkey.modifiers == [.option, .command])
    }

    /// 妥当性検査は 1 か所（`validateHotkeys`）に集める（§12-9「一括で検証する」）。
    @Test("validateHotkeys は自己矛盾したバインドと衝突の両方を見る")
    func validateHotkeysCoversBothInvariants() throws {
        #expect(throws: Never.self) { try Settings.default.validateHotkeys() }

        var conflicting = Settings.default
        conflicting.undoHotkey = try HotkeyBinding(keyCode: 0x06, modifiers: [.option, .command])
        #expect(throws: SettingsError.hotkeyConflict) { try conflicting.validateHotkeys() }
    }
}

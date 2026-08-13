import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("SettingsStore")
struct SettingsStoreTests {

    private func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("ファイルが無いときは既定値を返す")
    func returnsDefaultWhenMissing() throws {
        let store = SettingsStore(rootURL: try makeTempRoot())
        #expect(store.settings == Settings.default)
    }

    @Test("保存した値を読み戻せる")
    func persistsAcrossInstances() throws {
        let root = try makeTempRoot()
        let store = SettingsStore(rootURL: root)
        try store.update { $0.localeIdentifier = "en-US"; $0.historyLimit = 7 }

        let reloaded = SettingsStore(rootURL: root)
        #expect(reloaded.settings.localeIdentifier == "en-US")
        #expect(reloaded.settings.historyLimit == 7)
    }

    @Test("破損した JSON からは既定値へ復旧する")
    func recoversFromCorruptFile() throws {
        let root = try makeTempRoot()
        let file = root.appendingPathComponent("settings.json")
        try Data("{ this is not json".utf8).write(to: file)

        let store = SettingsStore(rootURL: root)
        #expect(store.settings == Settings.default)
    }

    @Test("PTT と衝突する Undo キーは拒否される")
    func rejectsConflictingUndoHotkey() throws {
        let store = SettingsStore(rootURL: try makeTempRoot())
        #expect(throws: SettingsError.hotkeyConflict) {
            try store.update { $0.undoHotkey = HotkeyBinding(keyCode: 0x06, modifiers: [.option, .command]) }
        }
        // 拒否されたので既定値のまま
        #expect(store.settings.undoHotkey == .controlCommandZ)
    }

    /// 設定ファイルは人間が読み書きできること（詳細設計書 §9.1）。
    /// 保存先のファイル名と、修飾キーが文字列配列であることを固定する。
    /// これが無いと、上の 3 件は保存先が `settings.json` でなくても素通りしてしまう。
    @Test("settings.json に人間が読める形で書き出す")
    func writesHumanReadableSettingsJSON() throws {
        let root = try makeTempRoot()
        let store = SettingsStore(rootURL: root)
        try store.update { $0.undoHotkey = HotkeyBinding(keyCode: 0x06, modifiers: [.control, .command]) }

        let text = try String(contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(text.contains("\"undoHotkey\""))
        #expect(text.contains("\"control\""))
        #expect(text.contains("\"command\""))
        #expect(text.contains("\n"), "pretty-printed でないと人間が読み書きできない")
    }
}

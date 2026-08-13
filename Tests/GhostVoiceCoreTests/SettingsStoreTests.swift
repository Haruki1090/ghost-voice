import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("SettingsStore")
struct SettingsStoreTests {

    @Test("ファイルが無いときは既定値を返す")
    func returnsDefaultWhenMissing() throws {
        try withTempRoot { root in
            let store = SettingsStore(rootURL: root)
            #expect(store.settings == Settings.default)
        }
    }

    @Test("保存した値を読み戻せる")
    func persistsAcrossInstances() throws {
        try withTempRoot { root in
            let store = SettingsStore(rootURL: root)
            try store.update { $0.localeIdentifier = "en-US"; $0.historyLimit = 7 }

            let reloaded = SettingsStore(rootURL: root)
            #expect(reloaded.settings.localeIdentifier == "en-US")
            #expect(reloaded.settings.historyLimit == 7)
        }
    }

    @Test("破損した JSON からは既定値へ復旧する")
    func recoversFromCorruptFile() throws {
        try withTempRoot { root in
            let file = root.appendingPathComponent("settings.json")
            try Data("{ this is not json".utf8).write(to: file)

            let store = SettingsStore(rootURL: root)
            #expect(store.settings == Settings.default)
        }
    }

    @Test("PTT と衝突する Undo キーは拒否される")
    func rejectsConflictingUndoHotkey() throws {
        try withTempRoot { root in
            let store = SettingsStore(rootURL: root)
            #expect(throws: SettingsError.hotkeyConflict) {
                try store.update { $0.undoHotkey = HotkeyBinding(keyCode: 0x06, modifiers: [.option, .command]) }
            }
            // 拒否されたので既定値のまま
            #expect(store.settings.undoHotkey == .controlCommandZ)
        }
    }

    /// 設定ファイルは人間が読み書きできること（詳細設計書 §9.1）。
    /// 保存先のファイル名と、修飾キーが文字列配列であることを固定する。
    /// これが無いと、上の 3 件は保存先が `settings.json` でなくても素通りしてしまう。
    @Test("settings.json に人間が読める形で書き出す")
    func writesHumanReadableSettingsJSON() throws {
        try withTempRoot { root in
            let store = SettingsStore(rootURL: root)
            try store.update { $0.undoHotkey = HotkeyBinding(keyCode: 0x06, modifiers: [.control, .command]) }

            let text = try String(contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8)
            #expect(text.contains("\"undoHotkey\""))
            #expect(text.contains("\"control\""))
            #expect(text.contains("\"command\""))
            #expect(text.contains("\n"), "pretty-printed でないと人間が読み書きできない")
        }
    }

    /// 復元できなかったファイルを退避せずに保存すると、`.atomic` write が
    /// 元の内容を復旧不能に消す。ユーザーが手編集した設定を失わせないための保護。
    @Test("復元できなかったファイルは上書きの前に .corrupt へ退避する")
    func quarantinesUnreadableFileBeforeOverwriting() throws {
        try withTempRoot { root in
            let original = "{ this is not json"
            try Data(original.utf8).write(to: root.appendingPathComponent("settings.json"))

            let store = SettingsStore(rootURL: root)
            try store.update { $0.historyLimit = 7 }

            let quarantined = root.appendingPathComponent("settings.json.corrupt")
            #expect(FileManager.default.fileExists(atPath: quarantined.path))
            #expect(try String(contentsOf: quarantined, encoding: .utf8) == original)
            // 本体には新しい設定が書かれている
            #expect(SettingsStore(rootURL: root).settings.historyLimit == 7)
        }
    }

    /// 正常な初回起動でゴミを作らないこと。
    @Test("ファイルが無いときは .corrupt を作らない")
    func doesNotQuarantineWhenAbsent() throws {
        try withTempRoot { root in
            let store = SettingsStore(rootURL: root)
            try store.update { $0.historyLimit = 7 }

            let quarantined = root.appendingPathComponent("settings.json.corrupt")
            #expect(!FileManager.default.fileExists(atPath: quarantined.path))
        }
    }

    /// 退避は最初の保存の 1 回だけ。2 回目の保存で、健全になった設定を
    /// `.corrupt` へ流し込んでしまわないこと。
    @Test("退避後の保存は .corrupt を書き換えない")
    func quarantinesOnlyOnce() throws {
        try withTempRoot { root in
            let original = "{ this is not json"
            try Data(original.utf8).write(to: root.appendingPathComponent("settings.json"))

            let store = SettingsStore(rootURL: root)
            try store.update { $0.historyLimit = 7 }
            try store.update { $0.historyLimit = 9 }

            let quarantined = root.appendingPathComponent("settings.json.corrupt")
            #expect(try String(contentsOf: quarantined, encoding: .utf8) == original)
            #expect(SettingsStore(rootURL: root).settings.historyLimit == 9)
        }
    }
}

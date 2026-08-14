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

    /// **I-4: 読めなかったことを保持する。**
    ///
    /// フェーズ 1 の設定手段は `settings.json` の手編集だけである。カンマ 1 つの
    /// 打ち間違いで**全設定が無言で既定へ戻る**と、利用者に見える症状は
    /// 「`en-US` にしたのに日本語で認識される」だけになり、原因に辿り着けない。
    /// **「無い（正常な初回起動）」と「読めなかった」を潰さない**のがこの型の役目で、
    /// `LoadOutcome` はそのために作られた（Task 2）。
    @Test("復元できなかったときは読み込み失敗を保持する")
    func keepsLoadFailureWhenUnreadable() throws {
        try withTempRoot { root in
            try Data("{ this is not json".utf8)
                .write(to: root.appendingPathComponent("settings.json"))

            let store = SettingsStore(rootURL: root)
            #expect(store.loadFailure != nil, "読めなかったことを握り潰している")
            // 既定値では動く（起動しなくなるより良い）
            #expect(store.settings == Settings.default)
        }
    }

    /// **無いことは失敗ではない。** ここを区別しないと、初回起動のたびに
    /// 「設定を読めませんでした」と出て、本当の失敗が埋もれる。
    @Test("ファイルが無いだけなら読み込み失敗にしない")
    func absentFileIsNotAFailure() throws {
        try withTempRoot { root in
            let store = SettingsStore(rootURL: root)
            #expect(store.loadFailure == nil)
            #expect(store.settings == Settings.default)
        }
    }

    @Test("読めたときは読み込み失敗にしない")
    func loadedFileIsNotAFailure() throws {
        try withTempRoot { root in
            let first = SettingsStore(rootURL: root)
            try first.update { $0.historyLimit = 7 }

            let second = SettingsStore(rootURL: root)
            #expect(second.loadFailure == nil)
            #expect(second.settings.historyLimit == 7)
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

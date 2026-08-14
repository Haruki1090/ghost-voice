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
            let optionCommandZ = try HotkeyBinding(keyCode: 0x06, modifiers: [.option, .command])
            #expect(throws: SettingsError.hotkeyConflict) {
                try store.update { $0.undoHotkey = optionCommandZ }
            }
            // 拒否されたので既定値のまま
            #expect(store.settings.undoHotkey == .controlCommandZ)
        }
    }

    // MARK: - 手編集した settings.json も検査を通ること（持ち越し項目 4 / 12）

    /// 手で `⇧ + 右 Option` を書いた設定ファイル。判定側は追加の修飾キーを見ないので、
    /// **右 Option 単独で録音が始まる**（詳細設計書 §2.3）。読み込めてしまうと
    /// 「Shift を押していないのに録音が始まる」状態が既定になる。
    @Test("手編集の settings.json の自己矛盾したホットキーは読み込み失敗として扱う")
    func rejectsSelfContradictoryHotkeyFromHandEditedFile() throws {
        try withTempRoot { root in
            let json = """
                {"hotkey":{"keyCode":61,"modifiers":["option","shift"]},
                 "undoHotkey":{"keyCode":6,"modifiers":["control","command"]},
                 "localeIdentifier":"en-US","transcriberKind":"dictation",
                 "refinementEnabled":true,"refinementTimeoutMs":750,"historyLimit":50}
                """
            try Data(json.utf8).write(to: root.appendingPathComponent("settings.json"))

            let store = SettingsStore(rootURL: root)
            #expect(store.loadFailure != nil, "自己矛盾したホットキーを黙って受け入れている")
            #expect(store.settings == Settings.default)
        }
    }

    /// PTT（右 Option）と衝突する Undo キーを手で書いた場合。Undo を押すたびに
    /// 録音が始まる（詳細設計書 §8.3）。
    @Test("手編集の settings.json の衝突したホットキーは読み込み失敗として扱う")
    func rejectsConflictingHotkeysFromHandEditedFile() throws {
        try withTempRoot { root in
            let json = """
                {"hotkey":{"keyCode":61,"modifiers":["option"]},
                 "undoHotkey":{"keyCode":6,"modifiers":["option","command"]},
                 "localeIdentifier":"en-US","transcriberKind":"dictation",
                 "refinementEnabled":true,"refinementTimeoutMs":750,"historyLimit":50}
                """
            try Data(json.utf8).write(to: root.appendingPathComponent("settings.json"))

            let store = SettingsStore(rootURL: root)
            #expect(store.loadFailure != nil, "衝突したホットキーを黙って受け入れている")
            #expect(store.settings == Settings.default)
        }
    }

    /// 拒否しすぎていないこと。妥当な手編集はそのまま効く。
    @Test("妥当な手編集の settings.json はそのまま読める")
    func acceptsValidHandEditedFile() throws {
        try withTempRoot { root in
            let json = """
                {"hotkey":{"keyCode":61,"modifiers":["option"]},
                 "undoHotkey":{"keyCode":6,"modifiers":["control","command"]},
                 "localeIdentifier":"en-US","transcriberKind":"speech",
                 "refinementEnabled":false,"refinementTimeoutMs":900,"historyLimit":12}
                """
            try Data(json.utf8).write(to: root.appendingPathComponent("settings.json"))

            let store = SettingsStore(rootURL: root)
            #expect(store.loadFailure == nil)
            #expect(store.settings.localeIdentifier == "en-US")
            #expect(store.settings.historyLimit == 12)
        }
    }

    /// 設定ファイルは人間が読み書きできること（詳細設計書 §9.1）。
    /// 保存先のファイル名と、修飾キーが文字列配列であることを固定する。
    /// これが無いと、上の 3 件は保存先が `settings.json` でなくても素通りしてしまう。
    @Test("settings.json に人間が読める形で書き出す")
    func writesHumanReadableSettingsJSON() throws {
        try withTempRoot { root in
            let store = SettingsStore(rootURL: root)
            let controlCommandZ = try HotkeyBinding(keyCode: 0x06, modifiers: [.control, .command])
            try store.update { $0.undoHotkey = controlCommandZ }

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

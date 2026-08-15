import Foundation
import Testing

@testable import GhostVoiceApp

/// **命題を、ソースそのものに対して固定する。**
///
/// 振る舞いの検査では捕まえられない種類の間違いがある——
/// 「別の場所にもう 1 つ実装が生えた」「危ない口を呼ぶ形が書かれた」は、
/// **どちらも自分のテストでは緑になる。** ここは grep を検査として置く。
///
/// 対象は**トラック D が書いたソースだけ**である（`Sources/GhostVoiceApp/Shell/Settings`
/// と `.../History`）。他トラックのファイルは見ない。
@Suite("設定・履歴のソースが満たすべき命題")
struct SettingsHistorySourceContractTests {

    @Test("走査の対象が実在する（空集合に対して緑になっていない）")
    func scanTargetIsNotEmpty() throws {
        let files = TrackDSources.files
        #expect(files.count >= 8, "設定 5 本 + 履歴 4 本を見込んでいる: \(files.map(\.lastPathComponent))")
        for file in files {
            #expect(try !TrackDSources.text(of: file).isEmpty)
        }
    }

    // MARK: - 命題 1: ホットキーの妥当性検査を画面側で二重に持たない

    @Test("**ホットキーの規則を画面側で書き直していない**（検査は Core に 1 つだけ）")
    func hotkeyRulesAreNotDuplicated() throws {
        // Core が持っている規則を、画面側が独自に書いていないか。
        //
        // - 修飾キー単独の表（キーコードと修飾キーの対応）→ `HotkeyBinding.modifierOnlyKeys`
        // - 仮想キーコードの範囲 → `HotkeyBinding.validKeyCodes`
        // - PTT と Undo の衝突 → `HotkeyBinding.conflicts(with:)` / `Settings.validateHotkeys()`
        let forbidden: [(pattern: String, rule: String)] = [
            ("0...0x7F", "仮想キーコードの範囲"),
            ("0x7F", "仮想キーコードの上限"),
            ("isDisjoint", "修飾キーの衝突判定"),
            ("hotkeyConflict =", "衝突の自前判定"),
            ("SettingsError.hotkeyConflict", "衝突の値を自前で組み立てること"),
        ]

        var violations: [String] = []
        for file in TrackDSources.files {
            for line in try TrackDSources.code(of: file) {
                for rule in forbidden where line.text.contains(rule.pattern) {
                    violations.append(
                        "\(file.lastPathComponent):\(line.line) \(rule.rule): \(line.text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(violations.isEmpty, "画面側に規則の写しがある:\n\(violations.joined(separator: "\n"))")
    }

    @Test("**代わりに Core の入口をちゃんと呼んでいる**（規則が無いだけの空実装でない）")
    func hotkeyRulesAreDelegatedToCore() throws {
        let sources = try TrackDSources.files.map { try TrackDSources.text(of: $0) }.joined()
        // 単体の不変条件は `HotkeyBinding` の初期化子が見る。
        #expect(sources.contains("HotkeyBinding(keyCode:"))
        // 修飾キー単独の正解は Core の表から取る。
        #expect(sources.contains("HotkeyBinding.ownModifier(forKeyCode:"))
        // PTT と Undo の関係は一括の入口が見る。
        #expect(sources.contains("validateHotkeys()"))
    }

    // MARK: - 命題 2: `SettingsStore.update` のクロージャから `settings` を読まない

    @Test("**`update` のクロージャの中で store を読んでいない**（`NSLock` は非再帰）")
    func updateClosureDoesNotReadStore() throws {
        let url = TrackDSources.repoRoot.appendingPathComponent(
            "Sources/GhostVoiceApp/Shell/Settings/SettingsViewModel.swift")
        let lines = try TrackDSources.code(of: url)

        let updateLines = lines.filter { $0.text.contains(".update {") }
        #expect(updateLines.count == 1, "`update` を呼ぶ箇所は 1 つだけ")

        // 唯一の呼び出しは「丸ごと代入」の 1 行で閉じている。読む余地が構造として無い。
        let call = try #require(updateLines.first)
        #expect(call.text.contains("try settingsStore.update { $0 = next }"))

        // 逆向きの確認: `settings` を読む形がクロージャの中に無いこと。
        #expect(!lines.contains { $0.text.contains("update { _ = ") })
        #expect(!lines.contains { $0.text.contains(".settings }") })
    }

    // MARK: - 命題 3: `HistoryStore.append` を画面から呼ばない

    @Test("**画面は履歴へ書かない**（`append` は同期 I/O で MainActor から呼んではならない）")
    func screensNeverAppendToHistory() throws {
        var violations: [String] = []
        for file in TrackDSources.files {
            for line in try TrackDSources.code(of: file) where line.text.contains(".append(") {
                // `entries.append` のような自前の配列操作は対象外。
                // ストアへの追記だけを見る。
                if line.text.contains("store.append") || line.text.contains("history.append") {
                    violations.append("\(file.lastPathComponent):\(line.line)")
                }
            }
        }
        #expect(violations.isEmpty, "画面が履歴へ書いている: \(violations)")
    }

    // MARK: - 命題 4: MainActor を塞ぐ書き込みの口を持たない

    @Test("**アクターを離れる地点は `BackgroundWrite` の 1 箇所だけ**")
    func onlyOneConcurrentHop() throws {
        var hops: [String] = []
        for file in TrackDSources.files {
            for line in try TrackDSources.code(of: file)
            where line.text.trimmingCharacters(in: .whitespaces) == "@concurrent" {
                hops.append(file.lastPathComponent)
            }
        }
        #expect(hops == ["BackgroundWrite.swift"], "見つかった地点: \(hops)")
    }

    @Test("`Task.detached` を書き散らしていない")
    func noDetachedTasks() throws {
        var violations: [String] = []
        for file in TrackDSources.files {
            for line in try TrackDSources.code(of: file) where line.text.contains("Task.detached") {
                violations.append("\(file.lastPathComponent):\(line.line)")
            }
        }
        #expect(violations.isEmpty, "規律が守られたか確かめられない形: \(violations)")
    }

    // MARK: - 命題 5: `AsyncStream` を 1 本につき 1 人で読む

    @Test("**ストリームを読む地点は履歴の購読 1 箇所だけ**")
    func singleStreamConsumer() throws {
        var consumers: [String] = []
        for file in TrackDSources.files {
            for line in try TrackDSources.code(of: file) where line.text.contains("for await") {
                consumers.append("\(file.lastPathComponent):\(line.line)")
            }
        }
        #expect(consumers.count == 1, "見つかった地点: \(consumers)")
        #expect(consumers.first?.hasPrefix("HistoryViewModel.swift") == true)

        // `changes()` を呼ぶ箇所も 1 つ。**1 本を 2 箇所で読み回さない。**
        var streamCalls: [String] = []
        for file in TrackDSources.files {
            for line in try TrackDSources.code(of: file) where line.text.contains(".changes()") {
                streamCalls.append("\(file.lastPathComponent):\(line.line)")
            }
        }
        #expect(streamCalls.count == 1, "見つかった地点: \(streamCalls)")
    }

    // MARK: - 命題 6: Undo の窓を画面側に書かない

    @Test("**Undo の 10 秒窓を画面側で持っていない**（`HistoryStore.undoWindow` が唯一の出どころ）")
    func undoWindowIsNotHardCoded() throws {
        // 文言そのものは **Core へ移した**（`SessionNoticeAnnouncement`。統括の裁定）。
        // 唯一の出どころであることは Core 側の検査が固定している。
        let core = TrackDSources.repoRoot.appendingPathComponent(
            "Sources/GhostVoiceCore/Support/SessionNoticeAnnouncement.swift")
        #expect(try TrackDSources.code(of: core).contains { $0.text.contains("HistoryStore.undoWindow") })

        // **画面側には秒数が 1 つも無い。** 片方だけ変えたときに嘘になる。
        for file in TrackDSources.files {
            for line in try TrackDSources.code(of: file) {
                #expect(!line.text.contains("10 秒"), "\(file.lastPathComponent):\(line.line)")
                #expect(!line.text.contains("10秒"), "\(file.lastPathComponent):\(line.line)")
            }
        }
    }

    // MARK: - 命題 6b: 通知の文言を画面側で作り直していない

    /// **`SessionNotice` の文言は Core に 1 箇所だけある**（統括の裁定「Core へ寄せる」）。
    /// 以前は HUD と Undo の UI の 2 箇所にあり、CLI には 1 箇所も無かった。
    @Test("**`SessionNotice` の文言を画面側で作っていない**")
    func noticeWordingLivesInCoreOnly() throws {
        let appRoot = TrackDSources.repoRoot.appendingPathComponent("Sources/GhostVoiceApp")
        var violations: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: appRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            for line in try TrackDSources.code(of: url) {
                // Core の翻訳器を呼ぶ行は違反ではない。**自前で `SessionNotice` を
                // `switch` して文言を作る形だけを見る。**
                if line.text.contains("case .undoDeclined")
                    || line.text.contains("case .undoCopiedRawTextToClipboard")
                    || line.text.contains("case .undoUnavailable")
                {
                    violations.append("\(url.lastPathComponent):\(line.line)")
                }
            }
        }
        #expect(violations.isEmpty, "画面側に通知の文言がある: \(violations)")
    }

    // MARK: - 命題 7: 提示の仕方が doc コメントにある

    @Test("**提示の仕方（どの窓／どのメニューから開くか）が doc コメントに書いてある**")
    func presentationIsDocumented() throws {
        let expectations: [(file: String, phrases: [String])] = [
            (
                "Sources/GhostVoiceApp/Shell/Settings/SettingsViewModel.swift",
                ["NSStatusItem", "NSHostingView", "RunLoopEntry", "NSApp.hide(nil)"]
            ),
            (
                "Sources/GhostVoiceApp/Shell/History/HistoryViewModel.swift",
                ["NSStatusItem", "NSHostingView", "RunLoopEntry", "窓を閉じて前面が戻ってから"]
            ),
        ]
        for expectation in expectations {
            let text = try TrackDSources.text(
                of: TrackDSources.repoRoot.appendingPathComponent(expectation.file))
            for phrase in expectation.phrases {
                #expect(text.contains(phrase), "\(expectation.file) に「\(phrase)」が無い")
            }
        }
    }

    // MARK: - 命題 8: 本物の挿入器を既定で握らない

    @Test("**本物の挿入器を作る箇所は 1 つだけ**（検査から届かない場所に置く）")
    func systemInserterIsBuiltInOnePlace() throws {
        var sites: [String] = []
        for file in TrackDSources.files {
            for line in try TrackDSources.code(of: file)
            where line.text.contains("CompositeInserter.system") {
                sites.append("\(file.lastPathComponent):\(line.line)")
            }
        }
        #expect(sites.count == 1, "見つかった地点: \(sites)")
        #expect(sites.first?.hasPrefix("HistoryTextOutput.swift") == true)

        // ViewModel の初期化子は既定引数で本物を作らない。**作ると検査が実機へ文字を出す。**
        let historyModel = try TrackDSources.text(
            of: TrackDSources.repoRoot.appendingPathComponent(
                "Sources/GhostVoiceApp/Shell/History/HistoryViewModel.swift"))
        #expect(!historyModel.contains("= SystemHistoryTextOutput"))
    }

    // MARK: - 命題 9: 利用者の実機の保存先を既定で掴まない

    @Test("`StorageRoot.default` を既定にしてよいのは設定画面の 1 引数だけ")
    func storageRootDefaultIsNarrow() throws {
        var sites: [String] = []
        for file in TrackDSources.files {
            for line in try TrackDSources.code(of: file)
            where line.text.contains("StorageRoot.default") {
                sites.append("\(file.lastPathComponent):\(line.line)")
            }
        }
        #expect(sites.count == 1, "見つかった地点: \(sites)")
        #expect(sites.first?.hasPrefix("SettingsViewModel.swift") == true)
    }
}

import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("AtomicJSONFile")
struct AtomicJSONFileTests {

    private struct Stamped: Codable, Sendable, Equatable {
        var at: Date
    }

    private func makeFile(in root: URL, name: String = "data.json") -> AtomicJSONFile<Stamped> {
        AtomicJSONFile(
            url: root.appendingPathComponent(name),
            fallback: Stamped(at: Date(timeIntervalSince1970: 0))
        )
    }

    /// 「まだ無い」と「あるのに復元できない」を取り違えると、一過性の I/O 失敗の直後の
    /// 保存がユーザーデータの上書き消去になる。呼び出し側が区別できることを固定する。
    @Test("不在と復元不能を区別する")
    func distinguishesAbsentFromUnreadable() throws {
        try withTempRoot { root in
            let file = makeFile(in: root)

            switch file.loadOutcome() {
            case .absent: break
            case .loaded, .unreadable: Issue.record("ファイル不在は .absent であるべき")
            }

            try Data("{ this is not json".utf8).write(to: root.appendingPathComponent("data.json"))
            switch file.loadOutcome() {
            case .unreadable: break
            case .loaded, .absent: Issue.record("破損ファイルは .unreadable であるべき")
            }

            let value = Stamped(at: Date(timeIntervalSince1970: 1_700_000_000))
            try file.save(value)
            switch file.loadOutcome() {
            case .loaded(let loaded): #expect(loaded == value)
            case .absent, .unreadable: Issue.record("保存済みの値は .loaded であるべき")
            }
        }
    }

    /// 退避は `save` の責務。呼び出し側が「読めなかったら次の保存の前に退避する」を
    /// 手書きすると、新しい利用者が忘れた時点で保護が消える。忘れようが無いことを固定する。
    @Test("復元できなかったファイルは save が自動で .corrupt へ退避する")
    func saveQuarantinesUnreadableFileAutomatically() throws {
        try withTempRoot { root in
            let original = "{ this is not json"
            try Data(original.utf8).write(to: root.appendingPathComponent("data.json"))

            let file = makeFile(in: root)
            _ = file.load()  // 復元できなかったことを file 自身が覚える
            try file.save(Stamped(at: Date(timeIntervalSince1970: 1_700_000_000)))

            let quarantined = root.appendingPathComponent("data.json.corrupt")
            #expect(try String(contentsOf: quarantined, encoding: .utf8) == original)
            #expect(file.load() == Stamped(at: Date(timeIntervalSince1970: 1_700_000_000)))
        }
    }

    /// 退避は復元に失敗した 1 回だけ。2 回目の保存で、健全になった中身を
    /// `.corrupt` へ流し込んで前回の退避物を失わせないこと。
    @Test("2 回目の save は .corrupt を書き換えない")
    func quarantinesOnlyOnce() throws {
        try withTempRoot { root in
            let original = "{ this is not json"
            try Data(original.utf8).write(to: root.appendingPathComponent("data.json"))

            let file = makeFile(in: root)
            _ = file.load()
            try file.save(Stamped(at: Date(timeIntervalSince1970: 1)))
            try file.save(Stamped(at: Date(timeIntervalSince1970: 2)))

            let quarantined = root.appendingPathComponent("data.json.corrupt")
            #expect(try String(contentsOf: quarantined, encoding: .utf8) == original)
            #expect(file.load() == Stamped(at: Date(timeIntervalSince1970: 2)))
        }
    }

    /// 健全なファイルや初回起動で `.corrupt` を作らないこと。
    /// これが無いと「常に退避する」実装が上の 2 件を素通りする。
    @Test("復元できたファイルと不在のファイルは退避しない")
    func doesNotQuarantineReadableOrAbsentFile() throws {
        try withTempRoot { root in
            let quarantined = root.appendingPathComponent("data.json.corrupt")

            let absent = makeFile(in: root)
            _ = absent.load()
            try absent.save(Stamped(at: Date(timeIntervalSince1970: 1)))
            #expect(!FileManager.default.fileExists(atPath: quarantined.path))

            let readable = makeFile(in: root)
            _ = readable.load()
            try readable.save(Stamped(at: Date(timeIntervalSince1970: 2)))
            #expect(!FileManager.default.fileExists(atPath: quarantined.path))
        }
    }

    /// Date は既定だと `776543210.123`（2001 年からの秒数）になり、
    /// 人間が読み書きできるという要求（詳細設計書 §9.1）を履歴ファイルで満たせない。
    @Test("Date を ISO8601 文字列として書き、読み戻せる")
    func encodesDatesAsISO8601() throws {
        try withTempRoot { root in
            let file = makeFile(in: root)
            let value = Stamped(at: Date(timeIntervalSince1970: 1_700_000_000))
            try file.save(value)

            let text = try String(contentsOf: root.appendingPathComponent("data.json"), encoding: .utf8)
            #expect(text.contains("2023-11-14T"), "ISO8601 の日付文字列が見当たらない: \(text)")
            #expect(!text.contains("721692800"), "2001 年基準の秒数で書かれている: \(text)")

            #expect(file.load() == value)
        }
    }
}

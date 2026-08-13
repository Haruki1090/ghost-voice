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

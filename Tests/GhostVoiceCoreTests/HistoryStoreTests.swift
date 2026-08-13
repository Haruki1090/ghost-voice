import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("HistoryStore")
struct HistoryStoreTests {

    /// `.iso8601` は秒精度なので、往復して等値を見るテストは整数秒の Date を使う。
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEntry(
        raw: String = "生テキスト",
        refined: String? = "整形後テキスト",
        at date: Date = Date()
    ) -> HistoryEntry {
        HistoryEntry(
            id: UUID(), timestamp: date, rawText: raw, refinedText: refined,
            localeIdentifier: "ja-JP", insertionMethod: .ax
        )
    }

    @Test("新しいものが先頭に来る")
    func newestFirst() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            try store.append(makeEntry(raw: "1つ目"))
            try store.append(makeEntry(raw: "2つ目"))
            #expect(store.entries.map(\.rawText) == ["2つ目", "1つ目"])
        }
    }

    @Test("上限を超えた分は古いものから削除される")
    func trimsToLimit() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 3)
            for i in 1...5 { try store.append(makeEntry(raw: "\(i)")) }
            #expect(store.entries.map(\.rawText) == ["5", "4", "3"])
        }
    }

    /// 上限ちょうどは削らないこと。これが無いと `>` と `>=` の取り違えを見逃す。
    @Test("上限ちょうどの件数は削られない")
    func keepsExactlyLimitEntries() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 3)
            for i in 1...3 { try store.append(makeEntry(raw: "\(i)")) }
            #expect(store.entries.map(\.rawText) == ["3", "2", "1"])
        }
    }

    /// 上限を 1 件超えた時点で削ること。5 件追加してから見る形だと、上限を
    /// 1 件ずらした実装でも最終的に辻褄が合ってしまう（ミューテーション M3）。
    @Test("上限を 1 件超えた時点で削られる")
    func trimsAsSoonAsLimitIsExceeded() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 3)
            for i in 1...4 { try store.append(makeEntry(raw: "\(i)")) }
            #expect(store.entries.map(\.rawText) == ["4", "3", "2"])
        }
    }

    /// `historyLimit` は人が手で編集する設定ファイルから来る（詳細設計書 §9.1）うえ、
    /// `Settings` 側に範囲の検証が無い。負数がそのまま `removeLast` へ渡ると
    /// 「Can't remove more items from a collection than it contains」で落ち、
    /// 発話を失ううえアプリごと巻き添えになる。
    @Test("不正な上限でも落ちず、履歴を持たない", arguments: [0, -1])
    func survivesNonPositiveLimit(limit: Int) throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: limit)
            try store.append(makeEntry(raw: "落ちないこと"))

            #expect(store.entries.isEmpty)
            #expect(HistoryStore(rootURL: root, limit: 50).entries.isEmpty)
        }
    }

    @Test("保存した履歴を読み戻せる")
    func persists() throws {
        try withTempRoot { root in
            try HistoryStore(rootURL: root, limit: 50).append(makeEntry(raw: "残る"))
            #expect(HistoryStore(rootURL: root, limit: 50).entries.first?.rawText == "残る")
        }
    }

    /// 挿入経路は V-3 の実地データ、ロケールは再現条件として使う（詳細設計書 §9.3）。
    /// 往復で落ちる項目があると、履歴を残す意味そのものが欠ける。
    ///
    /// 期待値は `HistoryEntry` を通さないリテラルで書く。読み戻した項目どうしを
    /// `==` で比べると、初期化子が項目を握り潰す実装でも期待値が同じように壊れて
    /// 素通りする（ミューテーション M15 / M17 で実際に生き延びた）。
    @Test("読み戻した履歴は全項目と並び順を保つ")
    func persistsAllFieldsAndOrder() throws {
        try withTempRoot { root in
            let oldID = UUID()
            let newID = UUID()
            let newDate = Self.fixedDate.addingTimeInterval(60)
            let store = HistoryStore(rootURL: root, limit: 50)
            try store.append(HistoryEntry(
                id: oldID, timestamp: Self.fixedDate, rawText: "古い生",
                refinedText: nil, localeIdentifier: "en-US", insertionMethod: .clipboardOnly
            ))
            try store.append(HistoryEntry(
                id: newID, timestamp: newDate, rawText: "新しい生",
                refinedText: "新しい整形", localeIdentifier: "ja-JP", insertionMethod: .pasteboard
            ))

            let reloaded = HistoryStore(rootURL: root, limit: 50).entries
            #expect(reloaded.map(\.id) == [newID, oldID])
            #expect(reloaded.map(\.timestamp) == [newDate, Self.fixedDate])
            #expect(reloaded.map(\.rawText) == ["新しい生", "古い生"])
            #expect(reloaded.map(\.refinedText) == ["新しい整形", nil])
            #expect(reloaded.map(\.localeIdentifier) == ["ja-JP", "en-US"])
            #expect(reloaded.map(\.insertionMethod) == [.pasteboard, .clipboardOnly])
        }
    }

    /// 切り詰めがキャッシュ上だけで、ファイルには全件書かれていないこと。
    /// 履歴は 1 MB 以下に収める必要がある（要件定義書 NFR-S2）。
    @Test("切り詰めた結果がファイルにも反映される")
    func persistsTrimmedList() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 2)
            for i in 1...4 { try store.append(makeEntry(raw: "\(i)")) }

            #expect(HistoryStore(rootURL: root, limit: 50).entries.map(\.rawText) == ["4", "3"])
        }
    }

    /// 履歴もユーザーが読める形のファイル（詳細設計書 §9.1）。
    /// これが無いと、上のテスト群は保存先が `history.json` でなくても素通りする。
    @Test("history.json に人間が読める形で書き出す")
    func writesHumanReadableHistoryJSON() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            try store.append(makeEntry(raw: "生です", refined: "整形です", at: Self.fixedDate))

            let text = try String(
                contentsOf: root.appendingPathComponent("history.json"), encoding: .utf8
            )
            #expect(text.contains("\"rawText\""))
            #expect(text.contains("\"生です\""))
            #expect(text.contains("\"整形です\""))
            #expect(text.contains("2023-11-14T"), "日時が人間に読めない形式になっている")
            #expect(text.contains("\n"), "pretty-printed でないと人間が読み書きできない")
        }
    }

    /// 音声は再現できないので、発話を失わないことが最優先（要件定義書 NFR-V2）。
    /// `HistoryStore` は退避のコードを 1 行も持たないが、init で読むことが前提。
    @Test("復元できなかった履歴は上書きの前に .corrupt へ退避される")
    func quarantinesUnreadableFile() throws {
        try withTempRoot { root in
            let original = "{ this is not json"
            try Data(original.utf8).write(to: root.appendingPathComponent("history.json"))

            let store = HistoryStore(rootURL: root, limit: 50)
            #expect(store.entries.isEmpty)
            try store.append(makeEntry(raw: "新しい発話"))

            let quarantined = root.appendingPathComponent("history.json.corrupt")
            #expect(try String(contentsOf: quarantined, encoding: .utf8) == original)
            #expect(HistoryStore(rootURL: root, limit: 50).entries.map(\.rawText) == ["新しい発話"])
        }
    }

    @Test("10 秒以内に整形挿入した履歴は Undo 対象になる")
    func undoCandidateWithinWindow() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(raw: "戻す先", at: now.addingTimeInterval(-5)))

            #expect(store.undoCandidate(now: now)?.rawText == "戻す先")
        }
    }

    /// 猶予ちょうどは受け付けること。これが無いと `<=` と `<` の取り違えを見逃す。
    @Test("ちょうど 10 秒前の履歴は Undo 対象になる")
    func undoCandidateAtWindowBoundary() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(at: now.addingTimeInterval(-HistoryStore.undoWindow)))

            #expect(store.undoCandidate(now: now) != nil)
        }
    }

    @Test("10 秒を超えた履歴は Undo 対象にならない")
    func undoCandidateExpires() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(at: now.addingTimeInterval(-11)))

            #expect(store.undoCandidate(now: now) == nil)
        }
    }

    @Test("整形していない履歴は Undo 対象にならない")
    func undoCandidateRequiresRefinement() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(refined: nil, at: now))

            #expect(store.undoCandidate(now: now) == nil)
        }
    }

    @Test("履歴が空なら Undo 対象は無い")
    func undoCandidateWithoutEntries() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            #expect(store.undoCandidate(now: Date()) == nil)
        }
    }

    /// Undo が戻すのは直前に挿入した文字列だけ。直近が対象外のときに 1 つ前まで
    /// 遡ると、ユーザーが見ていない箇所の文字列を書き換えることになる。
    @Test("直近が整形なしなら、さらに前の整形済み履歴は Undo 対象にならない")
    func undoCandidateDoesNotLookPastUnrefinedLatest() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(raw: "前の発話", refined: "前の整形", at: now))
            try store.append(makeEntry(raw: "直近の発話", refined: nil, at: now))

            #expect(store.undoCandidate(now: now) == nil)
        }
    }

    @Test("直近が猶予切れなら、さらに前の新しい履歴は Undo 対象にならない")
    func undoCandidateDoesNotLookPastExpiredLatest() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(raw: "前の発話", at: now))
            try store.append(makeEntry(raw: "直近の発話", at: now.addingTimeInterval(-30)))

            #expect(store.undoCandidate(now: now) == nil)
        }
    }
}

@Suite("HistoryEntry")
struct HistoryEntryTests {

    @Test("整形したときは整形後テキストが挿入された文字列")
    func insertedTextPrefersRefined() {
        let entry = HistoryEntry(
            rawText: "生", refinedText: "整形", localeIdentifier: "ja-JP", insertionMethod: .ax
        )
        #expect(entry.insertedText == "整形")
    }

    @Test("整形しなかったときは生テキストが挿入された文字列")
    func insertedTextFallsBackToRaw() {
        let entry = HistoryEntry(
            rawText: "生", refinedText: nil, localeIdentifier: "ja-JP", insertionMethod: .ax
        )
        #expect(entry.insertedText == "生")
    }
}

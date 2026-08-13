import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("VocabularyStore")
struct VocabularyStoreTests {

    @Test("初期状態は空")
    func startsEmpty() throws {
        try withTempRoot { root in
            #expect(VocabularyStore(rootURL: root).terms.isEmpty)
        }
    }

    @Test("保存した辞書を読み戻せる")
    func persists() throws {
        try withTempRoot { root in
            let store = VocabularyStore(rootURL: root)
            try store.replace([VocabularyTerm(canonical: "Nexadata", misheard: ["ネクサデータ"])])

            let reloaded = VocabularyStore(rootURL: root)
            #expect(reloaded.terms == [VocabularyTerm(canonical: "Nexadata", misheard: ["ネクサデータ"])])
        }
    }

    @Test("正規表記が重複する項目は先勝ちで除去される")
    func deduplicates() throws {
        try withTempRoot { root in
            let store = VocabularyStore(rootURL: root)
            try store.replace([
                VocabularyTerm(canonical: "Nexadata", misheard: ["ネクサデータ"]),
                VocabularyTerm(canonical: "Nexadata", misheard: ["ネクサ"]),
            ])

            #expect(store.terms.count == 1)
            #expect(store.terms[0].misheard == ["ネクサデータ"])
        }
    }

    @Test("空白のみの項目は除去され、前後の空白は落とされる")
    func dropsBlankTerms() throws {
        try withTempRoot { root in
            let store = VocabularyStore(rootURL: root)
            try store.replace([
                VocabularyTerm(canonical: "  "),
                VocabularyTerm(canonical: " Swift "),
            ])

            #expect(store.terms.map(\.canonical) == ["Swift"])
        }
    }

    /// 上限ちょうどは通ること。これが無いと `<` と `<=` の取り違えを見逃す。
    @Test("100 語ちょうどは受け付ける")
    func acceptsExactlyMaxTerms() throws {
        try withTempRoot { root in
            let store = VocabularyStore(rootURL: root)
            try store.replace((0..<100).map { VocabularyTerm(canonical: "T\($0)") })
            #expect(store.terms.count == 100)
        }
    }

    @Test("100 語を超える登録は拒否され、既存の辞書を壊さない")
    func rejectsOverLimit() throws {
        try withTempRoot { root in
            let store = VocabularyStore(rootURL: root)
            try store.replace([VocabularyTerm(canonical: "Nexadata")])

            #expect(throws: VocabularyError.tooManyTerms) {
                try store.replace((0..<101).map { VocabularyTerm(canonical: "T\($0)") })
            }
            #expect(store.terms.map(\.canonical) == ["Nexadata"])
            #expect(VocabularyStore(rootURL: root).terms.map(\.canonical) == ["Nexadata"])
        }
    }

    /// 辞書はユーザーが手で編集する前提のファイル（詳細設計書 §9.1）。
    /// これが無いと、上のテスト群は保存先が `vocabulary.json` でなくても素通りする。
    @Test("vocabulary.json に人間が読める形で書き出す")
    func writesHumanReadableVocabularyJSON() throws {
        try withTempRoot { root in
            let store = VocabularyStore(rootURL: root)
            try store.replace([VocabularyTerm(canonical: "microCMS", misheard: ["マイクロシーエムエス"])])

            let text = try String(contentsOf: root.appendingPathComponent("vocabulary.json"), encoding: .utf8)
            #expect(text.contains("\"canonical\""))
            #expect(text.contains("\"microCMS\""))
            #expect(text.contains("\"マイクロシーエムエス\""))
            #expect(text.contains("\n"), "pretty-printed でないと人間が読み書きできない")
        }
    }

    /// `VocabularyStore` は退避のコードを 1 行も持っていない（`grep quarantine` が当たらない）。
    /// それでも保護が効くこと ＝ 保護が利用者側の書き忘れに依存していないことの証拠。
    @Test("復元できなかった辞書は上書きの前に .corrupt へ退避される")
    func quarantinesUnreadableFileWithoutStoreSideCode() throws {
        try withTempRoot { root in
            let original = "{ this is not json"
            try Data(original.utf8).write(to: root.appendingPathComponent("vocabulary.json"))

            let store = VocabularyStore(rootURL: root)
            #expect(store.terms.isEmpty)
            try store.replace([VocabularyTerm(canonical: "Swift")])

            let quarantined = root.appendingPathComponent("vocabulary.json.corrupt")
            #expect(try String(contentsOf: quarantined, encoding: .utf8) == original)
            #expect(VocabularyStore(rootURL: root).terms.map(\.canonical) == ["Swift"])
        }
    }
}

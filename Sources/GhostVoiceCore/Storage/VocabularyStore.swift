import Foundation

public enum VocabularyError: Error, Equatable {
    case tooManyTerms
}

public final class VocabularyStore: @unchecked Sendable {
    /// 辞書は整形プロンプトへ毎回注入されるため、長すぎるとレイテンシに響く。
    public static let maxTerms = 100

    private let file: AtomicJSONFile<[VocabularyTerm]>
    private let lock = NSLock()
    private var cached: [VocabularyTerm]

    public init(rootURL: URL = StorageRoot.default) {
        // 復元できなかったファイルの退避は `file` 側が覚えていて `save` が行う。
        self.file = AtomicJSONFile(
            url: rootURL.appendingPathComponent("vocabulary.json"),
            fallback: []
        )
        self.cached = file.load()
    }

    public var terms: [VocabularyTerm] {
        lock.withLock { cached }
    }

    /// - Throws: `VocabularyError.tooManyTerms` — 正規化後の件数が `maxTerms` を超える場合。
    ///   このとき保存もキャッシュ更新も行わない。
    public func replace(_ terms: [VocabularyTerm]) throws {
        let cleaned = Self.normalize(terms)
        guard cleaned.count <= Self.maxTerms else { throw VocabularyError.tooManyTerms }
        try lock.withLock {
            try file.save(cleaned)
            cached = cleaned
        }
    }

    /// 空白のみの項目を除去し、正規表記の重複を先勝ちで畳む。
    static func normalize(_ terms: [VocabularyTerm]) -> [VocabularyTerm] {
        var seen = Set<String>()
        return terms.compactMap { term in
            let canonical = term.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty, seen.insert(canonical).inserted else { return nil }
            return VocabularyTerm(canonical: canonical, misheard: term.misheard)
        }
    }
}

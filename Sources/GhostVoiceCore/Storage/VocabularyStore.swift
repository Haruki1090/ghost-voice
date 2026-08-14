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

    /// **読み込みに失敗したか。** ファイルが無い（正常な初回起動）とは区別する。
    ///
    /// 手で編集する JSON がフェーズ 1 の唯一の設定手段なので、カンマ 1 つの打ち間違いで
    /// **全設定が無言で既定へ戻る**（フェーズ 1 の最終レビュー I-4）。利用者から見えるのは
    /// 「`en-US` にしたのに日本語で認識される」で、原因に辿り着く手掛かりが無い。
    /// **保持だけして、表に出すのは CLI の仕事**（`--check` と起動時の 1 行）。
    public let loadFailure: (any Error)?

    public init(rootURL: URL = StorageRoot.default) {
        // 復元できなかったファイルの退避は `file` 側が覚えていて `save` が行う。
        self.file = AtomicJSONFile(
            url: rootURL.appendingPathComponent("vocabulary.json"),
            fallback: []
        )
        // **`load()` ではなく `loadOutcome()`。** 「無い」と「読めなかった」を潰さない。
        switch file.loadOutcome() {
        case .loaded(let value):
            self.cached = value
            self.loadFailure = nil
        case .absent:
            self.cached = []
            self.loadFailure = nil
        case .unreadable(let error):
            self.cached = []
            self.loadFailure = error
        }
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

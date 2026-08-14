import Foundation

public struct VocabularyTerm: Codable, Sendable, Equatable {
    /// 正しい表記
    public let canonical: String
    /// 誤認識されやすい表記（任意）
    public let misheard: [String]

    public init(canonical: String, misheard: [String] = []) {
        self.canonical = canonical
        self.misheard = misheard
    }
}

import Foundation

public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    /// 整形前の書き起こし。Undo で復元する対象。
    public let rawText: String
    /// 整形後の書き起こし。整形せずに挿入した場合は nil。
    public let refinedText: String?
    public let localeIdentifier: String
    public let insertionMethod: InsertionMethod

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        refinedText: String?,
        localeIdentifier: String,
        insertionMethod: InsertionMethod
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.refinedText = refinedText
        self.localeIdentifier = localeIdentifier
        self.insertionMethod = insertionMethod
    }

    /// 実際に挿入された文字列。
    public var insertedText: String { refinedText ?? rawText }
}

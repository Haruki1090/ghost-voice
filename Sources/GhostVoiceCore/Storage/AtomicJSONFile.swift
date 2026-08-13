import Foundation

public enum StorageRoot {
    public static var `default`: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhostVoice", isDirectory: true)
    }
}

/// JSON ファイルの原子的な読み書き。
///
/// 読み込み失敗（ファイル無し・破損）は握りつぶして `fallback` を返す。
/// 設定や履歴が壊れてもアプリが起動しなくなることを避けるため。
public struct AtomicJSONFile<T: Codable & Sendable>: Sendable {
    private let url: URL
    private let fallback: T

    public init(url: URL, fallback: T) {
        self.url = url
        self.fallback = fallback
    }

    public func load() -> T {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(T.self, from: data)
        else { return fallback }
        return value
    }

    public func save(_ value: T) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

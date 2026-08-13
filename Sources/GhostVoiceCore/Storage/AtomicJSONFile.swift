import Foundation

public enum StorageRoot {
    public static var `default`: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhostVoice", isDirectory: true)
    }
}

/// 読み込みの結果。
///
/// 「ファイルがまだ無い（正常な初回起動）」と「あるのに値を復元できなかった」を
/// 区別するために存在する。両者を同じ既定値へ潰すと、一過性の I/O 失敗のあとの
/// 保存がユーザーデータの上書き消去になるため。
public enum LoadOutcome<T: Sendable>: Sendable {
    case loaded(T)
    /// ファイルが存在しない（正常な初回起動）
    case absent
    /// 読めた/読めないに関わらず、値を復元できなかった
    case unreadable(any Error)
}

/// JSON ファイルの原子的な読み書き。
///
/// 読み込み失敗（ファイル無し・破損）は握りつぶして `fallback` を返す。
/// 設定や履歴が壊れてもアプリが起動しなくなることを避けるため。
/// 失敗の種類が必要な呼び出し側は `loadOutcome()` を使うこと。
public struct AtomicJSONFile<T: Codable & Sendable>: Sendable {
    private let url: URL
    private let fallback: T

    public init(url: URL, fallback: T) {
        self.url = url
        self.fallback = fallback
    }

    /// 復元できなかった場合も含め、常に値を返す。
    public func load() -> T {
        switch loadOutcome() {
        case .loaded(let value): return value
        case .absent, .unreadable: return fallback
        }
    }

    /// 失敗の種類を呼び出し側へ伝える読み込み。
    public func loadOutcome() -> LoadOutcome<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try Self.makeDecoder().decode(T.self, from: data))
        } catch {
            return .unreadable(error)
        }
    }

    public func save(_ value: T) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.makeEncoder().encode(value).write(to: url, options: .atomic)
    }

    /// 復元できなかったファイルを `<name>.corrupt` へ退避する。
    ///
    /// `save` は `.atomic` write なので、退避せずに書くと元の内容は復旧不能になる。
    /// `loadOutcome()` が `.unreadable` を返したときに、最初の `save` の前に呼ぶこと。
    /// 退避先は 1 スロットで、既存の `.corrupt` は上書きする。対象が無ければ何もしない。
    public func quarantine() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        let destination = url.appendingPathExtension("corrupt")
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: url, to: destination)
    }

    /// 設定・辞書・履歴のいずれも人間が読み書きできること（詳細設計書 §9.1）。
    /// Date は既定だと 2001 年からの秒数の実数になるため ISO8601 に固定する。
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

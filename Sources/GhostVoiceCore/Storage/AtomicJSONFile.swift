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
///
/// 復元できなかったファイルの退避もここが担う。読み込みで `.unreadable` だったことを
/// 自分で覚えておき、次の `save` の直前に一度だけ `<name>.corrupt` へ逃がす。
/// 呼び出し側は何も書かなくてよい（書き忘れによって保護が消えることが無い）。
///
/// 直前の読み込み結果という可変状態を持つため参照型。`Sendable` は `lock` が
/// その状態を守ることで担保する。
public final class AtomicJSONFile<T: Codable & Sendable>: @unchecked Sendable {
    private let url: URL
    private let fallback: T
    private let lock = NSLock()
    /// 復元できなかった実ファイルがまだ残っているか。
    /// 次の保存で上書き消去する前に退避する必要がある。
    private var needsQuarantine = false

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
    ///
    /// 副作用として、次の `save` が退避を要するかどうかを更新する。
    public func loadOutcome() -> LoadOutcome<T> {
        lock.withLock {
            let outcome = readWithoutLocking()
            if case .unreadable = outcome {
                needsQuarantine = true
            } else {
                // 読めた／消えた以上、逃がすべき中身はもう残っていない
                needsQuarantine = false
            }
            return outcome
        }
    }

    /// 直前の読み込みが `.unreadable` だった場合は、書く前に実ファイルを退避する。
    ///
    /// - Important: 退避が働くのは、この `save` より前に `load()` / `loadOutcome()` を
    ///   呼んでいる場合だけ。退避の要否は読み込み結果から決まるので、一度も読まずに
    ///   書いた呼び出し側は、破損ファイルを退避せずに上書きする（初期値は「退避不要」）。
    ///   ストアは init で必ず読み込んでからキャッシュを持つ形にすること。
    /// - Important: **権限を明示する**（ディレクトリ 0700 / ファイル 0600）。
    ///   umask 任せにしていた頃、実機の `history.json` は 0644 だった。
    ///   **いま安全なのは親ディレクトリ（`~/Library/Application Support`）が 700 だから
    ///   であって、このコードが守っているからではない。** 保存先は `init(rootURL:)` で
    ///   差し替えられるので、`~/Library` の外へ置いた瞬間に保護が消える
    ///   （最終レビュー 視点5 の P-3）。`history.json` には認識テキストが平文で入る。
    public func save(_ value: T) throws {
        try lock.withLock {
            if needsQuarantine {
                try quarantineWithoutLocking()
                needsQuarantine = false
            }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Self.makeEncoder().encode(value).write(to: url, options: .atomic)
            // **`.atomic` は書き込みのたびに新しい実体へ差し替える**ので、
            // 権限も毎回付け直す（`createDirectory` の attributes は既存のディレクトリには効かない）。
            try Self.restrict(url)
            try Self.restrict(directory)
        }
    }

    /// **退避したファイルを消す。**
    ///
    /// 中身は**利用者の発話そのもの**である（`history.json` には認識テキストが平文で入る）。
    /// 「履歴を全部消す」を押したのに退避先が残っていると、
    /// **利用者が消したつもりのテキストがディスクに残り続ける**
    /// （最終レビュー 視点5 の P-2）。
    ///
    /// - Important: 消す判断は呼び出し側が持つ。ここは「言われたら消す」だけである。
    /// - Note: 退避が無ければ何もしない。**二度呼んでも安全。**
    public func removeQuarantinedCopy() throws {
        try lock.withLock {
            let destination = Self.quarantineURL(for: url)
            guard FileManager.default.fileExists(atPath: destination.path) else { return }
            try FileManager.default.removeItem(at: destination)
        }
    }

    private func readWithoutLocking() -> LoadOutcome<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try Self.makeDecoder().decode(T.self, from: data))
        } catch {
            return .unreadable(error)
        }
    }

    /// 復元できなかったファイルを `<name>.corrupt` へ退避する。
    ///
    /// `save` は `.atomic` write なので、退避せずに書くと元の内容は復旧不能になる。
    /// 退避先は 1 スロットで、既存の `.corrupt` は上書きする。対象が無ければ何もしない。
    private func quarantineWithoutLocking() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        let destination = Self.quarantineURL(for: url)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: url, to: destination)
        // **退避先の中身は発話そのものである。** 元のファイルの権限を引き継ぐので、
        // 手編集などで緩くなっていたらここで締め直す。
        try Self.restrict(destination)
    }

    /// 退避先。**1 スロットだけ。**
    static func quarantineURL(for url: URL) -> URL {
        url.appendingPathExtension("corrupt")
    }

    /// 本人だけが読み書きできる形にする。
    ///
    /// ディレクトリは 0700、ファイルは 0600。**置き場所に依存せず閉じる**ためで、
    /// 親ディレクトリの権限を当てにしない。
    private static func restrict(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: isDirectory.boolValue ? 0o700 : 0o600],
            ofItemAtPath: url.path)
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

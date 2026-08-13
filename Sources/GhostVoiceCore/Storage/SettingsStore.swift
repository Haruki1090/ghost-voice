import Foundation

public enum SettingsError: Error, Equatable {
    /// Undo ホットキーが PTT キーの修飾キーと衝突している
    case hotkeyConflict
}

public final class SettingsStore: @unchecked Sendable {
    private let file: AtomicJSONFile<Settings>
    private let lock = NSLock()
    private var cached: Settings

    public init(rootURL: URL = StorageRoot.default) {
        // 復元できなかったファイルの退避は `file` 側が覚えていて `save` が行う。
        self.file = AtomicJSONFile(
            url: rootURL.appendingPathComponent("settings.json"),
            fallback: Settings.default
        )
        self.cached = file.load()
    }

    public var settings: Settings {
        lock.withLock { cached }
    }

    /// 設定を変更して保存する。
    ///
    /// - Important: `mutate` はロックを保持したまま実行される。`NSLock` は非再帰なので、
    ///   このクロージャの中から同じ store の `settings` を読んではならない（自己デッドロックする）。
    ///   クロージャは渡された `inout Settings` だけを触ること。
    /// - Throws: `SettingsError.hotkeyConflict` — 変更後の Undo キーが PTT キーと衝突する場合。
    ///   このとき保存もキャッシュ更新も行わない。
    public func update(_ mutate: (inout Settings) -> Void) throws {
        try lock.withLock {
            var next = cached
            mutate(&next)
            guard !next.hotkey.conflicts(with: next.undoHotkey) else {
                throw SettingsError.hotkeyConflict
            }
            try file.save(next)
            cached = next
        }
    }
}

import Foundation

public enum SettingsError: Error, Equatable {
    /// Undo ホットキーが PTT キーの修飾キーと衝突している
    case hotkeyConflict
}

public final class SettingsStore: @unchecked Sendable {
    private let file: AtomicJSONFile<Settings>
    private let lock = NSLock()
    private var cached: Settings
    /// 復元できなかった実ファイルがまだ残っているか。
    /// 次の保存で上書き消去する前に退避する必要がある。
    private var needsQuarantine: Bool

    public init(rootURL: URL = StorageRoot.default) {
        let file = AtomicJSONFile(
            url: rootURL.appendingPathComponent("settings.json"),
            fallback: Settings.default
        )
        self.file = file
        switch file.loadOutcome() {
        case .loaded(let settings):
            self.cached = settings
            self.needsQuarantine = false
        case .absent:
            self.cached = .default
            self.needsQuarantine = false
        case .unreadable:
            self.cached = .default
            self.needsQuarantine = true
        }
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
            if needsQuarantine {
                try file.quarantine()
                needsQuarantine = false
            }
            try file.save(next)
            cached = next
        }
    }
}

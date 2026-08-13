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
        self.file = AtomicJSONFile(
            url: rootURL.appendingPathComponent("settings.json"),
            fallback: .default
        )
        self.cached = file.load()
    }

    public var settings: Settings {
        lock.withLock { cached }
    }

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

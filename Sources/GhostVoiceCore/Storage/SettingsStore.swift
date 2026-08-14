import Foundation

public enum SettingsError: Error, Equatable {
    /// Undo ホットキーが PTT キーの修飾キーと衝突している
    case hotkeyConflict
}

public final class SettingsStore: @unchecked Sendable {
    private let file: AtomicJSONFile<Settings>
    private let lock = NSLock()
    private var cached: Settings

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
            url: rootURL.appendingPathComponent("settings.json"),
            fallback: Settings.default
        )
        // **`load()` ではなく `loadOutcome()`。** 「無い」と「読めなかった」を潰さない。
        switch file.loadOutcome() {
        case .loaded(let value):
            self.cached = value
            self.loadFailure = nil
        case .absent:
            self.cached = Settings.default
            self.loadFailure = nil
        case .unreadable(let error):
            self.cached = Settings.default
            self.loadFailure = error
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
            try file.save(next)
            cached = next
        }
    }
}

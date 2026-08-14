import Foundation

public struct Settings: Codable, Sendable, Equatable {
    public var hotkey: HotkeyBinding
    public var undoHotkey: HotkeyBinding
    public var localeIdentifier: String
    public var transcriberKind: TranscriberKind
    public var refinementEnabled: Bool
    public var refinementTimeoutMs: Int
    public var historyLimit: Int

    public init(
        hotkey: HotkeyBinding = .rightOption,
        undoHotkey: HotkeyBinding = .controlCommandZ,
        localeIdentifier: String = "ja-JP",
        transcriberKind: TranscriberKind = .dictation,
        refinementEnabled: Bool = true,
        refinementTimeoutMs: Int = 750,
        historyLimit: Int = 50
    ) {
        self.hotkey = hotkey
        self.undoHotkey = undoHotkey
        self.localeIdentifier = localeIdentifier
        self.transcriberKind = transcriberKind
        self.refinementEnabled = refinementEnabled
        self.refinementTimeoutMs = refinementTimeoutMs
        self.historyLimit = historyLimit
    }

    public static let `default` = Settings()

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    /// 整形の打ち切り時間。
    ///
    /// **既定は 750 ms で、NFR-P4 の目標値 500 ms とは別の数である。** 500 ms は
    /// 「整形にこれくらいで終わってほしい」という目標で、こちらは「これを超えたら
    /// 待つより生テキストを出す方がましになる」境界である。両者を同じ数にしていた
    /// 当初の既定では、**実運用に近い負荷の下で 3〜5 割の発話が整形されずに終わった**
    /// （Task 10 の M5 実測。超過分は 501〜527 ms とわずかに超えるものが大半だった）。
    ///
    /// 上限は NFR-P6（発話終了 → 挿入完了 1000 ms）が決める。実測の最悪値で
    /// M2 が 177 ms、M4 の予算が NFR-P5 の 50 ms なので、
    /// 177 + 750 + 50 = 977 ms で収まる（詳細設計書 §10）。
    public var refinementTimeout: Duration { .milliseconds(refinementTimeoutMs) }
}

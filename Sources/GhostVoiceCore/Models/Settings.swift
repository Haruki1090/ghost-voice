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
        refinementTimeoutMs: Int = 500,
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

    public var refinementTimeout: Duration { .milliseconds(refinementTimeoutMs) }
}

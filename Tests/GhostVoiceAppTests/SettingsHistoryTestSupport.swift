import Foundation
import GhostVoiceCore
import Synchronization
import Testing

@testable import GhostVoiceApp

// MARK: - 一時ディレクトリ

/// 検査ごとに作り捨てる保存先。
///
/// **`StorageRoot.default` を絶対に使わない。** 利用者の実機の
/// `~/Library/Application Support/GhostVoice/` を検査が書き換えることになる
/// （`COMMON.md` の安全制約）。
final class SettingsHistoryTempDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghost-voice-track-d-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ contents: String, to name: String) throws {
        try contents.write(
            to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func text(of name: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - セッションの代役

/// `SettingsSessionControlling` の代役。**呼ばれ方を記録する。**
///
/// 戻り値だけを見る検査では「呼ばれなかったこと」が検査できないので、
/// 引数もそのまま残す（`AppShutdownTests` の `CallOrder` と同じ考え方）。
final class SettingsSessionSpy: SettingsSessionControlling {
    struct Prepared: Sendable, Equatable {
        let localeIdentifier: String
        let kind: TranscriberKind
    }

    private let prepareCalls = Mutex<[Prepared]>([])
    private let rebindCalls = Mutex<[HotkeyBinding]>([])
    private let prepareError: (any Error)?
    private let rebindError: (any Error)?

    init(prepareError: (any Error)? = nil, rebindError: (any Error)? = nil) {
        self.prepareError = prepareError
        self.rebindError = rebindError
    }

    var prepared: [Prepared] { prepareCalls.withLock { $0 } }
    var rebound: [HotkeyBinding] { rebindCalls.withLock { $0 } }

    func prepareTranscriber(locale: Locale, kind: TranscriberKind) async throws {
        if let prepareError { throw prepareError }
        prepareCalls.withLock {
            $0.append(Prepared(localeIdentifier: locale.identifier, kind: kind))
        }
    }

    func rebindUndoHotkey(to binding: HotkeyBinding) async throws {
        if let rebindError { throw rebindError }
        rebindCalls.withLock { $0.append(binding) }
    }
}

// MARK: - 履歴の出口の代役

/// `HistoryTextOutput` の代役。
///
/// **本物（`SystemHistoryTextOutput.system()`）を検査から使ってはならない。**
/// `CGEvent.post` と AX 書き込みが走り、そのとき前面にあるアプリへ文字が出る。
final class HistoryTextOutputSpy: HistoryTextOutput {
    private let inserted = Mutex<[String]>([])
    private let copied = Mutex<[String]>([])
    private let outcome: InsertionOutcome
    private let copySucceeds: Bool

    init(outcome: InsertionOutcome = .inserted(.ax), copySucceeds: Bool = true) {
        self.outcome = outcome
        self.copySucceeds = copySucceeds
    }

    var insertedTexts: [String] { inserted.withLock { $0 } }
    var copiedTexts: [String] { copied.withLock { $0 } }

    func insert(_ text: String) async -> InsertionOutcome {
        inserted.withLock { $0.append(text) }
        return outcome
    }

    func copy(_ text: String) -> Bool {
        copied.withLock { $0.append(text) }
        return copySucceeds
    }
}

// MARK: - 履歴の作り置き

func makeHistoryEntry(
    rawText: String = "生テキスト",
    refinedText: String? = "整形後テキスト",
    method: InsertionMethod = .ax,
    timestamp: Date = Date(),
    locale: String = "ja-JP"
) -> HistoryEntry {
    HistoryEntry(
        timestamp: timestamp, rawText: rawText, refinedText: refinedText,
        localeIdentifier: locale, insertionMethod: method)
}

// MARK: - ソース走査

/// **命題を「残存 0 件」の形で確かめるための走査。**
///
/// 「直しました」ではなく「この命題を含む箇所は全部で N 箇所あり、残存は 0 件」で
/// 報告するのが本プロジェクトの規律である（`COMMON.md` §4）。
/// **その N と 0 を、報告書ではなく検査で固定する。**
enum TrackDSources {
    /// リポジトリの根。テストの置き場所から辿る（作業ディレクトリに依存しない）。
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // GhostVoiceAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // リポジトリの根

    /// トラック D が書いたソース（設定・履歴）。
    static var files: [URL] {
        let roots = [
            repoRoot.appendingPathComponent("Sources/GhostVoiceApp/Shell/Settings"),
            repoRoot.appendingPathComponent("Sources/GhostVoiceApp/Shell/History"),
        ]
        return roots.flatMap { root -> [URL] in
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
        }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func text(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// doc コメント（`///`）と `//` のコメント行を落とした本文。
    ///
    /// **命題の検査は「コードがそうなっているか」であって「コメントに何と書いてあるか」
    /// ではない。** 落とさないと、注意書きに書いた語がそのまま違反として数えられる。
    static func code(of url: URL) throws -> [(line: Int, text: String)] {
        try text(of: url)
            .components(separatedBy: .newlines)
            .enumerated()
            .map { (line: $0.offset + 1, text: $0.element) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }
}

// MARK: - スレッドの確認

/// いまメインスレッドか。
///
/// **`Thread.isMainThread` は `noasync` なので async 文脈から直に読めない。**
/// 同期の関数に包む。包んでも意味は変わらない（実行中のスレッドを見るだけ）。
func isRunningOnMainThread() -> Bool { Thread.isMainThread }

// MARK: - キー監視器の代役

/// `HotkeyControlling` の代役。**捕獲の決着を検査から流し込める。**
///
/// **本物（`CGEventTapHotkeyMonitor`）を検査から使ってはならない。**
/// `CGEvent.tapCreate` は入力監視の権限ダイアログを誘発する（`COMMON.md` の安全制約）。
final class HotkeyControlSpy: HotkeyControlling {
    private let handler = Mutex<(@Sendable (HotkeyCaptureOutcome) -> Void)?>(nil)
    private let beginCalls = Mutex<Int>(0)
    private let endCalls = Mutex<Int>(0)
    private let rebinds = Mutex<[HotkeyBinding]>([])
    private let rebindError: (any Error)?

    init(
        currentPushToTalkBinding: HotkeyBinding = .rightOption,
        rebindError: (any Error)? = nil
    ) {
        self.currentPushToTalkBinding = currentPushToTalkBinding
        self.rebindError = rebindError
    }

    let currentPushToTalkBinding: HotkeyBinding

    var beginCount: Int { beginCalls.withLock { $0 } }
    var endCount: Int { endCalls.withLock { $0 } }
    var isCapturing: Bool { handler.withLock { $0 != nil } }
    var reboundPushToTalk: [HotkeyBinding] { rebinds.withLock { $0 } }

    func beginCapture(_ onEvent: @escaping @Sendable (HotkeyCaptureOutcome) -> Void) {
        beginCalls.withLock { $0 += 1 }
        handler.withLock { $0 = onEvent }
    }

    func endCapture() {
        let had = handler.withLock { current -> Bool in
            let existed = current != nil
            current = nil
            return existed
        }
        if had { endCalls.withLock { $0 += 1 } }
    }

    func rebindPushToTalk(to binding: HotkeyBinding) throws {
        if let rebindError { throw rebindError }
        rebinds.withLock { $0.append(binding) }
    }

    /// 決着を配る。**本物と同じく 1 打鍵で閉じる。**
    func deliver(_ outcome: HotkeyCaptureOutcome) {
        let current = handler.withLock { existing -> (@Sendable (HotkeyCaptureOutcome) -> Void)? in
            let value = existing
            existing = nil
            return value
        }
        current?(outcome)
    }
}

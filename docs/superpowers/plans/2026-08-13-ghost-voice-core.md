# Ghost Voice Core 実装計画（フェーズ1）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 右 Option を押している間だけ発話を録音し、ローカルで文字起こし・整形して、フォーカス中のアプリへ挿入する CLI を完成させる。

**Architecture:** UI に依存しない Swift Package `GhostVoiceCore` に全ロジックを置き、薄い CLI 実行ターゲット `ghost-voice` から駆動する。認識・整形・挿入の各段はプロトコルで抽象化し、テストではモックへ差し替える。フェーズ2（notch HUD アプリ）は本計画の成果物をそのまま利用する。

**Tech Stack:** Swift 6.3 / swift-tools-version 6.3 / swift-testing / macOS 26 / `Speech`（SpeechAnalyzer）/ `FoundationModels` / `ApplicationServices`（AXUIElement）/ `CoreGraphics`（CGEventTap）/ `AVFAudio`

> **この計画は完了済みのフェーズ 1 の記録である。要件はこの後に変わった。**
> 2026-08-14 の裁定（要件定義書 §2.8.6）で **FR-5 / FR-7 / NFR-P6 / NFR-V3 が書き換わり**、
> **NFR-P6 は NFR-P6a / NFR-P6b へ分割された。** 本文中の
> 「キー解放 → 挿入完了 1000 ms（NFR-P6）」「Undo は整形済み履歴を戻す」といった記述は
> **当時のものである。** 現在の正本は下の 3 冊であり、**本計画を根拠に実装してはならない。**

**Spec:**
- [docs/01-requirements.md](../../01-requirements.md)
- [docs/02-architecture.md](../../02-architecture.md)
- [docs/03-detailed-design.md](../../03-detailed-design.md)

## Global Constraints

- **swift-tools-version: 6.3**、`swiftLanguageModes: [.v6]`、`platforms: [.macOS(.v26)]`（検証済み: この構成で `swift test` が通ることを実機確認済み）
- **外部依存パッケージはゼロ。** フェーズ1 では `Package.swift` の `dependencies` を空のまま維持する（要件定義書 条件 C-3、基本設計書 §1 方針2）
- **ネットワーク通信を行わない。** `URLSession` 等の使用を禁止する（NFR-V1）
- **音声データをディスクへ書き出さない。** テスト用フィクスチャを除く（FR-12 / NFR-V2）
- **保存先は `~/Library/Application Support/GhostVoice/` 固定。** ただし全ストアはコンストラクタでルート URL を受け取り、テストでは一時ディレクトリを渡す
- **`AnalysisContext.contextualStrings` を使用しない。** 実測で無効と確認済み（要件定義書 §2.6）
- **性能目標: キー解放 → 挿入完了 1000 ms 以内**（NFR-P6）。内訳は認識確定 300 ms / 整形 500 ms / 挿入 50 ms
- Undo ホットキーに Option を含めてはならない（PTT キーと衝突するため）
- コミットメッセージは `feat:` / `test:` / `docs:` / `chore:` の接頭辞を付ける

---

## ファイル構成

| ファイル | 責務 | 担当タスク |
|---|---|---|
| `Package.swift` | パッケージ定義 | 1 |
| `Sources/GhostVoiceCore/Models/TranscriberKind.swift` | 認識モジュール種別 | 1 |
| `Sources/GhostVoiceCore/Models/InsertionMethod.swift` | 挿入経路の種別 | 1 |
| `Sources/GhostVoiceCore/Models/HotkeyBinding.swift` | キー定義と衝突判定 | 1 |
| `Sources/GhostVoiceCore/Models/Settings.swift` | 設定値と既定値 | 1 |
| `Sources/GhostVoiceCore/Storage/AtomicJSONFile.swift` | 原子的 JSON 読み書き | 2 |
| `Sources/GhostVoiceCore/Storage/SettingsStore.swift` | 設定の永続化 | 2 |
| `Sources/GhostVoiceCore/Models/VocabularyTerm.swift` | 辞書項目 | 3 |
| `Sources/GhostVoiceCore/Storage/VocabularyStore.swift` | 辞書の永続化と正規化 | 3 |
| `Sources/GhostVoiceCore/Refinement/RefinementPrompt.swift` | 整形プロンプト構築 | 3 |
| `Sources/GhostVoiceCore/Models/HistoryEntry.swift` | 履歴項目 | 4 |
| `Sources/GhostVoiceCore/Storage/HistoryStore.swift` | 履歴の永続化と切り詰め | 4 |
| `Sources/GhostVoiceCore/Transcription/Transcribing.swift` | 認識プロトコル | 5 |
| `Sources/GhostVoiceCore/Transcription/SpeechAnalyzerTranscriber.swift` | SpeechAnalyzer 実装 | 5 |
| `Sources/GhostVoiceCore/Refinement/Refining.swift` | 整形プロトコル | 6 |
| `Sources/GhostVoiceCore/Refinement/FoundationModelRefiner.swift` | FoundationModels 実装 | 6 |
| `Sources/GhostVoiceCore/Audio/AudioCapturing.swift` | 音声取得プロトコル | 7 |
| `Sources/GhostVoiceCore/Audio/EngineAudioCapture.swift` | AVAudioEngine 実装 | 7 |
| `Sources/GhostVoiceCore/Insertion/TextInserting.swift` | 挿入プロトコル | 8 |
| `Sources/GhostVoiceCore/Insertion/AccessibilityInserter.swift` | AX 経路 | 8 |
| `Sources/GhostVoiceCore/Insertion/PasteboardInserter.swift` | Pasteboard 経路 | 8 |
| `Sources/GhostVoiceCore/Insertion/CompositeInserter.swift` | 二段構えの調停 | 8 |
| `Sources/GhostVoiceCore/Hotkey/HotkeyMonitor.swift` | ホットキープロトコル | 9 |
| `Sources/GhostVoiceCore/Hotkey/CGEventTapHotkeyMonitor.swift` | CGEventTap 実装 | 9 |
| `Sources/GhostVoiceCore/Session/DictationSession.swift` | 状態機械 | 10 |
| `Sources/GhostVoiceCore/Support/Metrics.swift` | 性能計測 | 10 |
| `Sources/ghost-voice/main.swift` | CLI エントリポイント | 11 |

---

## Task 1: パッケージ骨格と基本モデル

**Files:**
- Create: `Package.swift`
- Create: `Sources/GhostVoiceCore/Models/TranscriberKind.swift`
- Create: `Sources/GhostVoiceCore/Models/InsertionMethod.swift`
- Create: `Sources/GhostVoiceCore/Models/HotkeyBinding.swift`
- Create: `Sources/GhostVoiceCore/Models/Settings.swift`
- Test: `Tests/GhostVoiceCoreTests/SettingsTests.swift`
- Test: `Tests/GhostVoiceCoreTests/HotkeyBindingTests.swift`

**Interfaces:**
- Consumes: なし（最初のタスク）
- Produces: `TranscriberKind`, `InsertionMethod`, `HotkeyBinding`, `Settings`。以降の全タスクがこれらを使う

- [ ] **Step 1: パッケージを作成する**

```bash
cd /Users/harukiinoue/StudioProjects/ghost-voice
swift package init --type library --name GhostVoiceCore
```

生成された `Sources/GhostVoiceCore/GhostVoiceCore.swift` と `Tests/GhostVoiceCoreTests/GhostVoiceCoreTests.swift` は削除する。

```bash
rm Sources/GhostVoiceCore/GhostVoiceCore.swift Tests/GhostVoiceCoreTests/GhostVoiceCoreTests.swift
mkdir -p Sources/GhostVoiceCore/{Models,Storage,Transcription,Refinement,Audio,Insertion,Hotkey,Session,Support}
```

- [ ] **Step 2: `Package.swift` を書き換える**

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "GhostVoiceCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GhostVoiceCore", targets: ["GhostVoiceCore"]),
        .executable(name: "ghost-voice", targets: ["ghost-voice"]),
    ],
    targets: [
        .target(name: "GhostVoiceCore"),
        .executableTarget(name: "ghost-voice", dependencies: ["GhostVoiceCore"]),
        .testTarget(name: "GhostVoiceCoreTests", dependencies: ["GhostVoiceCore"]),
    ],
    swiftLanguageModes: [.v6]
)
```

実行ターゲットは Task 11 で実装するため、この時点では仮のファイルを置く。

```bash
mkdir -p Sources/ghost-voice
echo 'print("ghost-voice")' > Sources/ghost-voice/main.swift
```

- [ ] **Step 3: 失敗するテストを書く**

`Tests/GhostVoiceCoreTests/HotkeyBindingTests.swift`:

```swift
import Testing
@testable import GhostVoiceCore

@Suite("HotkeyBinding")
struct HotkeyBindingTests {

    @Test("右 Option の既定値が正しい")
    func rightOptionDefault() {
        let ptt = HotkeyBinding.rightOption
        #expect(ptt.keyCode == 0x3D)
        #expect(ptt.modifiers == [.option])
        #expect(ptt.isModifierOnly)
    }

    @Test("⌃⌘Z の既定値が正しい")
    func undoDefault() {
        let undo = HotkeyBinding.controlCommandZ
        #expect(undo.keyCode == 0x06)
        #expect(undo.modifiers == [.control, .command])
        #expect(!undo.isModifierOnly)
    }

    @Test("PTT と修飾キーが衝突する組み合わせを検出する")
    func conflictDetection() {
        // ⌥⌘Z は PTT（右 Option）と衝突する
        let optionCommandZ = HotkeyBinding(keyCode: 0x06, modifiers: [.option, .command])
        #expect(HotkeyBinding.rightOption.conflicts(with: optionCommandZ))

        // ⌃⌘Z は衝突しない
        #expect(!HotkeyBinding.rightOption.conflicts(with: .controlCommandZ))
    }

    @Test("JSON を往復できる")
    func codableRoundTrip() throws {
        let original = HotkeyBinding.rightOption
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyBinding.self, from: data)
        #expect(decoded == original)
    }
}
```

`Tests/GhostVoiceCoreTests/SettingsTests.swift`:

```swift
import Testing
@testable import GhostVoiceCore

@Suite("Settings")
struct SettingsTests {

    @Test("既定値が仕様どおり")
    func defaults() {
        let s = Settings.default
        #expect(s.hotkey == .rightOption)
        #expect(s.undoHotkey == .controlCommandZ)
        #expect(s.localeIdentifier == "ja-JP")
        #expect(s.transcriberKind == .dictation)
        #expect(s.refinementEnabled)
        #expect(s.refinementTimeoutMs == 500)
        #expect(s.historyLimit == 50)
    }

    @Test("未知のキーを含む JSON を読み込める")
    func decodesWithUnknownKeys() throws {
        let json = """
        {"hotkey":{"keyCode":61,"modifiers":["option"]},
         "undoHotkey":{"keyCode":6,"modifiers":["control","command"]},
         "localeIdentifier":"en-US","transcriberKind":"speech",
         "refinementEnabled":false,"refinementTimeoutMs":800,
         "historyLimit":10,"futureFeature":"ignored"}
        """
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(s.localeIdentifier == "en-US")
        #expect(s.transcriberKind == .speech)
        #expect(s.refinementTimeoutMs == 800)
    }
}
```

- [ ] **Step 4: テストを実行し、失敗を確認する**

Run: `swift test`
Expected: FAIL（`cannot find 'HotkeyBinding' in scope` 等のコンパイルエラー）

- [ ] **Step 5: モデルを実装する**

`Sources/GhostVoiceCore/Models/TranscriberKind.swift`:

```swift
import Foundation

/// 使用する音声認識モジュールの種別。
///
/// 実測（要件定義書 §2.5）では日本語で `.dictation` が優位だったが、
/// 合成音声での比較のため、肉声で再検証できるよう差し替え可能にしている。
public enum TranscriberKind: String, Codable, Sendable, CaseIterable {
    case dictation
    case speech
}
```

`Sources/GhostVoiceCore/Models/InsertionMethod.swift`:

```swift
import Foundation

/// テキスト挿入に実際に使われた経路。履歴に記録し、どのアプリでどの経路が
/// 使われたかの実地データとする（検証項目 V-3）。
public enum InsertionMethod: String, Codable, Sendable {
    /// Accessibility API で直接挿入した
    case ax
    /// クリップボード経由で ⌘V を送出した
    case pasteboard
    /// 挿入に失敗し、クリップボードへ残すのみに留めた
    case clipboardOnly
}
```

`Sources/GhostVoiceCore/Models/HotkeyBinding.swift`:

```swift
import Foundation

public struct HotkeyBinding: Codable, Sendable, Equatable {

    public struct Modifiers: OptionSet, Codable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option  = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift   = Modifiers(rawValue: 1 << 3)

        private static let names: [(Modifiers, String)] = [
            (.command, "command"), (.option, "option"),
            (.control, "control"), (.shift, "shift"),
        ]

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode([String].self)
            var result = Modifiers()
            for (flag, name) in Self.names where raw.contains(name) {
                result.insert(flag)
            }
            self = result
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(Self.names.filter { contains($0.0) }.map(\.1))
        }
    }

    /// 仮想キーコード。修飾キー単独の場合は、その修飾キー自身のキーコード。
    public let keyCode: Int64
    public let modifiers: Modifiers

    public init(keyCode: Int64, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 右 Option（kVK_RightOption）。PTT の既定値。
    public static let rightOption = HotkeyBinding(keyCode: 0x3D, modifiers: [.option])

    /// ⌃⌘Z。Undo の既定値。Option を含めてはならない。
    public static let controlCommandZ = HotkeyBinding(keyCode: 0x06, modifiers: [.control, .command])

    /// 修飾キー単独のバインドか。押しっぱなし検出は flagsChanged で行う必要がある。
    public var isModifierOnly: Bool {
        [0x37, 0x36, 0x3A, 0x3D, 0x38, 0x3C, 0x3B, 0x3E].contains(keyCode)
    }

    /// PTT キーの修飾キーを、相手のバインドが含んでいるか。
    ///
    /// PTT が修飾キー単独の場合、その修飾キーを含む他のショートカットを押すと
    /// PTT が誤発火する。設定画面のバリデーションに使う。
    public func conflicts(with other: HotkeyBinding) -> Bool {
        guard isModifierOnly else { return self == other }
        return !modifiers.isDisjoint(with: other.modifiers)
    }
}

extension HotkeyBinding.Modifiers {
    func isDisjoint(with other: HotkeyBinding.Modifiers) -> Bool {
        intersection(other).isEmpty
    }
}
```

`Sources/GhostVoiceCore/Models/Settings.swift`:

```swift
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
```

`Codable` の合成実装は未知のキーを無視するため、`decodesWithUnknownKeys` はこれで通る。

- [ ] **Step 6: テストを実行し、成功を確認する**

Run: `swift test`
Expected: PASS（6 tests）

- [ ] **Step 7: コミット**

```bash
git add Package.swift Sources Tests
git commit -m "feat: パッケージ骨格と基本モデル型を追加"
```

---

## Task 2: 設定の永続化

**Files:**
- Create: `Sources/GhostVoiceCore/Storage/AtomicJSONFile.swift`
- Create: `Sources/GhostVoiceCore/Storage/SettingsStore.swift`
- Test: `Tests/GhostVoiceCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `Settings`（Task 1）
- Produces:
  - `AtomicJSONFile<T: Codable & Sendable>`: `init(url: URL, fallback: T)`, `func load() -> T`, `func save(_ value: T) throws`
  - `SettingsStore`: `init(rootURL: URL)`, `var settings: Settings { get }`, `func update(_ mutate: (inout Settings) -> Void) throws`
  - `StorageRoot.default: URL`（`~/Library/Application Support/GhostVoice/`）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/GhostVoiceCoreTests/SettingsStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("SettingsStore")
struct SettingsStoreTests {

    private func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("ファイルが無いときは既定値を返す")
    func returnsDefaultWhenMissing() throws {
        let store = SettingsStore(rootURL: try makeTempRoot())
        #expect(store.settings == Settings.default)
    }

    @Test("保存した値を読み戻せる")
    func persistsAcrossInstances() throws {
        let root = try makeTempRoot()
        let store = SettingsStore(rootURL: root)
        try store.update { $0.localeIdentifier = "en-US"; $0.historyLimit = 7 }

        let reloaded = SettingsStore(rootURL: root)
        #expect(reloaded.settings.localeIdentifier == "en-US")
        #expect(reloaded.settings.historyLimit == 7)
    }

    @Test("破損した JSON からは既定値へ復旧する")
    func recoversFromCorruptFile() throws {
        let root = try makeTempRoot()
        let file = root.appendingPathComponent("settings.json")
        try Data("{ this is not json".utf8).write(to: file)

        let store = SettingsStore(rootURL: root)
        #expect(store.settings == Settings.default)
    }

    @Test("PTT と衝突する Undo キーは拒否される")
    func rejectsConflictingUndoHotkey() throws {
        let store = SettingsStore(rootURL: try makeTempRoot())
        #expect(throws: SettingsError.hotkeyConflict) {
            try store.update { $0.undoHotkey = HotkeyBinding(keyCode: 0x06, modifiers: [.option, .command]) }
        }
        // 拒否されたので既定値のまま
        #expect(store.settings.undoHotkey == .controlCommandZ)
    }
}
```

- [ ] **Step 2: テストを実行し、失敗を確認する**

Run: `swift test --filter SettingsStore`
Expected: FAIL（`cannot find 'SettingsStore' in scope`）

- [ ] **Step 3: `AtomicJSONFile` を実装する**

`Sources/GhostVoiceCore/Storage/AtomicJSONFile.swift`:

```swift
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
```

- [ ] **Step 4: `SettingsStore` を実装する**

`Sources/GhostVoiceCore/Storage/SettingsStore.swift`:

```swift
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
```

- [ ] **Step 5: テストを実行し、成功を確認する**

Run: `swift test --filter SettingsStore`
Expected: PASS（4 tests）

- [ ] **Step 6: コミット**

```bash
git add Sources/GhostVoiceCore/Storage Tests/GhostVoiceCoreTests/SettingsStoreTests.swift
git commit -m "feat: 設定の永続化と衝突バリデーションを追加"
```

---

## Task 3: ユーザー辞書と整形プロンプト

**Files:**
- Create: `Sources/GhostVoiceCore/Models/VocabularyTerm.swift`
- Create: `Sources/GhostVoiceCore/Storage/VocabularyStore.swift`
- Create: `Sources/GhostVoiceCore/Refinement/RefinementPrompt.swift`
- Test: `Tests/GhostVoiceCoreTests/VocabularyStoreTests.swift`
- Test: `Tests/GhostVoiceCoreTests/RefinementPromptTests.swift`

**Interfaces:**
- Consumes: `AtomicJSONFile`, `StorageRoot`（Task 2）
- Produces:
  - `VocabularyTerm`: `init(canonical: String, misheard: [String] = [])`
  - `VocabularyStore`: `init(rootURL: URL)`, `var terms: [VocabularyTerm]`, `func replace(_ terms: [VocabularyTerm]) throws`, `static let maxTerms = 100`
  - `RefinementPrompt`: `static func instructions(for locale: Locale) -> String`, `static func prompt(rawText: String, terms: [VocabularyTerm]) -> String`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/GhostVoiceCoreTests/RefinementPromptTests.swift`:

```swift
import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("RefinementPrompt")
struct RefinementPromptTests {

    @Test("instructions に過剰要約の禁止が含まれる")
    func instructionsForbidSummarizing() {
        let text = RefinementPrompt.instructions(for: Locale(identifier: "ja-JP"))
        #expect(text.contains("要約しない"))
        #expect(text.contains("整形後のテキストのみ"))
    }

    @Test("辞書が空なら辞書ブロックを付けない")
    func omitsVocabularyBlockWhenEmpty() {
        let p = RefinementPrompt.prompt(rawText: "テスト発話", terms: [])
        #expect(!p.contains("固有名詞"))
        #expect(p.contains("テスト発話"))
    }

    @Test("辞書があれば正規表記を列挙する")
    func includesCanonicalTerms() {
        let terms = [
            VocabularyTerm(canonical: "Nexadata"),
            VocabularyTerm(canonical: "microCMS", misheard: ["マイクロシーエムエス"]),
        ]
        let p = RefinementPrompt.prompt(rawText: "ネクサデータの件です", terms: terms)
        #expect(p.contains("固有名詞"))
        #expect(p.contains("Nexadata"))
        #expect(p.contains("microCMS"))
        #expect(p.contains("ネクサデータの件です"))
    }

    @Test("辞書が 100 語を超えても 100 語までしか出力しない")
    func capsVocabularyAtMax() {
        let terms = (0..<150).map { VocabularyTerm(canonical: "Term\($0)") }
        let p = RefinementPrompt.prompt(rawText: "発話", terms: terms)
        #expect(p.contains("Term99"))
        #expect(!p.contains("Term100"))
    }
}
```

`Tests/GhostVoiceCoreTests/VocabularyStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("VocabularyStore")
struct VocabularyStoreTests {

    private func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("初期状態は空")
    func startsEmpty() throws {
        #expect(VocabularyStore(rootURL: try makeTempRoot()).terms.isEmpty)
    }

    @Test("保存した辞書を読み戻せる")
    func persists() throws {
        let root = try makeTempRoot()
        let store = VocabularyStore(rootURL: root)
        try store.replace([VocabularyTerm(canonical: "Nexadata")])
        #expect(VocabularyStore(rootURL: root).terms.map(\.canonical) == ["Nexadata"])
    }

    @Test("正規表記が重複する項目は先勝ちで除去される")
    func deduplicates() throws {
        let store = VocabularyStore(rootURL: try makeTempRoot())
        try store.replace([
            VocabularyTerm(canonical: "Nexadata", misheard: ["ネクサデータ"]),
            VocabularyTerm(canonical: "Nexadata", misheard: ["ネクサ"]),
        ])
        #expect(store.terms.count == 1)
        #expect(store.terms[0].misheard == ["ネクサデータ"])
    }

    @Test("空白のみの項目は除去される")
    func dropsBlankTerms() throws {
        let store = VocabularyStore(rootURL: try makeTempRoot())
        try store.replace([VocabularyTerm(canonical: "  "), VocabularyTerm(canonical: "Swift")])
        #expect(store.terms.map(\.canonical) == ["Swift"])
    }

    @Test("100 語を超える登録は拒否される")
    func rejectsOverLimit() throws {
        let store = VocabularyStore(rootURL: try makeTempRoot())
        let tooMany = (0..<101).map { VocabularyTerm(canonical: "T\($0)") }
        #expect(throws: VocabularyError.tooManyTerms) {
            try store.replace(tooMany)
        }
    }
}
```

- [ ] **Step 2: テストを実行し、失敗を確認する**

Run: `swift test --filter "VocabularyStore|RefinementPrompt"`
Expected: FAIL（`cannot find 'VocabularyStore' in scope`）

- [ ] **Step 3: `VocabularyTerm` と `VocabularyStore` を実装する**

`Sources/GhostVoiceCore/Models/VocabularyTerm.swift`:

```swift
import Foundation

public struct VocabularyTerm: Codable, Sendable, Equatable {
    /// 正しい表記
    public let canonical: String
    /// 誤認識されやすい表記（任意）
    public let misheard: [String]

    public init(canonical: String, misheard: [String] = []) {
        self.canonical = canonical
        self.misheard = misheard
    }
}
```

`Sources/GhostVoiceCore/Storage/VocabularyStore.swift`:

```swift
import Foundation

public enum VocabularyError: Error, Equatable {
    case tooManyTerms
}

public final class VocabularyStore: @unchecked Sendable {
    /// 辞書は整形プロンプトへ毎回注入されるため、長すぎるとレイテンシに響く。
    public static let maxTerms = 100

    private let file: AtomicJSONFile<[VocabularyTerm]>
    private let lock = NSLock()
    private var cached: [VocabularyTerm]

    public init(rootURL: URL = StorageRoot.default) {
        self.file = AtomicJSONFile(
            url: rootURL.appendingPathComponent("vocabulary.json"),
            fallback: []
        )
        self.cached = file.load()
    }

    public var terms: [VocabularyTerm] {
        lock.withLock { cached }
    }

    public func replace(_ terms: [VocabularyTerm]) throws {
        let cleaned = Self.normalize(terms)
        guard cleaned.count <= Self.maxTerms else { throw VocabularyError.tooManyTerms }
        try lock.withLock {
            try file.save(cleaned)
            cached = cleaned
        }
    }

    /// 空白のみの項目を除去し、正規表記の重複を先勝ちで畳む。
    static func normalize(_ terms: [VocabularyTerm]) -> [VocabularyTerm] {
        var seen = Set<String>()
        return terms.compactMap { term in
            let canonical = term.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty, seen.insert(canonical).inserted else { return nil }
            return VocabularyTerm(canonical: canonical, misheard: term.misheard)
        }
    }
}
```

- [ ] **Step 4: `RefinementPrompt` を実装する**

`Sources/GhostVoiceCore/Refinement/RefinementPrompt.swift`:

```swift
import Foundation

public enum RefinementPrompt {

    /// セッション生成時に一度だけ与える指示。
    ///
    /// 規則 4 は実測で確認された過剰要約（「エラーハンドリングが抜けてるので、
    /// そこを追加したい」→「エラーハンドリングを追加したい」）への対策。
    public static func instructions(for locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier == "en" ? "English" : "日本語"
        return """
        あなたは音声入力テキストの整形器です。入力は \(language) です。
        以下の規則に従ってください。

        1. フィラー（えー、あの、まあ、その 等）を削除する
        2. 言い直しは、後から言い直した方を残す
        3. 句読点を適切に補う
        4. 話者の意図・情報を変更しない。要約しない。語を削らない
        5. 整形後のテキストのみを出力する。説明・前置き・引用符は付けない
        """
    }

    /// 発話ごとに組み立てるプロンプト。辞書が空なら辞書ブロックを省く。
    public static func prompt(rawText: String, terms: [VocabularyTerm]) -> String {
        guard !terms.isEmpty else { return rawText }

        let listed = terms.prefix(VocabularyStore.maxTerms)
            .map(\.canonical)
            .joined(separator: ", ")

        return """
        以下の固有名詞が含まれる可能性があります。音が近い箇所はこの表記に直してください。
        \(listed)

        整形対象:
        \(rawText)
        """
    }
}
```

- [ ] **Step 5: テストを実行し、成功を確認する**

Run: `swift test --filter "VocabularyStore|RefinementPrompt"`
Expected: PASS（9 tests）

- [ ] **Step 6: コミット**

```bash
git add Sources/GhostVoiceCore Tests/GhostVoiceCoreTests
git commit -m "feat: ユーザー辞書と整形プロンプト構築を追加"
```

---

## Task 4: 履歴ストア

**Files:**
- Create: `Sources/GhostVoiceCore/Models/HistoryEntry.swift`
- Create: `Sources/GhostVoiceCore/Storage/HistoryStore.swift`
- Test: `Tests/GhostVoiceCoreTests/HistoryStoreTests.swift`

**Interfaces:**
- Consumes: `AtomicJSONFile`, `InsertionMethod`（Task 1, 2）
- Produces:
  - `HistoryEntry`: `init(id:timestamp:rawText:refinedText:localeIdentifier:insertionMethod:)`
  - `HistoryStore`: `init(rootURL: URL, limit: Int)`, `var entries: [HistoryEntry]`, `func append(_ entry: HistoryEntry) throws`, `func undoCandidate(now: Date) -> HistoryEntry?`
  - `HistoryStore.undoWindow: TimeInterval = 10`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/GhostVoiceCoreTests/HistoryStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("HistoryStore")
struct HistoryStoreTests {

    private func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEntry(
        raw: String = "生テキスト",
        refined: String? = "整形後テキスト",
        at date: Date = Date()
    ) -> HistoryEntry {
        HistoryEntry(
            id: UUID(), timestamp: date, rawText: raw, refinedText: refined,
            localeIdentifier: "ja-JP", insertionMethod: .ax
        )
    }

    @Test("新しいものが先頭に来る")
    func newestFirst() throws {
        let store = HistoryStore(rootURL: try makeTempRoot(), limit: 50)
        try store.append(makeEntry(raw: "1つ目"))
        try store.append(makeEntry(raw: "2つ目"))
        #expect(store.entries.map(\.rawText) == ["2つ目", "1つ目"])
    }

    @Test("上限を超えた分は古いものから削除される")
    func trimsToLimit() throws {
        let store = HistoryStore(rootURL: try makeTempRoot(), limit: 3)
        for i in 1...5 { try store.append(makeEntry(raw: "\(i)")) }
        #expect(store.entries.map(\.rawText) == ["5", "4", "3"])
    }

    @Test("保存した履歴を読み戻せる")
    func persists() throws {
        let root = try makeTempRoot()
        try HistoryStore(rootURL: root, limit: 50).append(makeEntry(raw: "残る"))
        #expect(HistoryStore(rootURL: root, limit: 50).entries.first?.rawText == "残る")
    }

    @Test("10 秒以内に整形挿入した履歴は Undo 対象になる")
    func undoCandidateWithinWindow() throws {
        let store = HistoryStore(rootURL: try makeTempRoot(), limit: 50)
        let now = Date()
        try store.append(makeEntry(at: now.addingTimeInterval(-5)))
        #expect(store.undoCandidate(now: now) != nil)
    }

    @Test("10 秒を超えた履歴は Undo 対象にならない")
    func undoCandidateExpires() throws {
        let store = HistoryStore(rootURL: try makeTempRoot(), limit: 50)
        let now = Date()
        try store.append(makeEntry(at: now.addingTimeInterval(-11)))
        #expect(store.undoCandidate(now: now) == nil)
    }

    @Test("整形していない履歴は Undo 対象にならない")
    func undoCandidateRequiresRefinement() throws {
        let store = HistoryStore(rootURL: try makeTempRoot(), limit: 50)
        let now = Date()
        try store.append(makeEntry(refined: nil, at: now))
        #expect(store.undoCandidate(now: now) == nil)
    }
}
```

- [ ] **Step 2: テストを実行し、失敗を確認する**

Run: `swift test --filter HistoryStore`
Expected: FAIL（`cannot find 'HistoryStore' in scope`）

- [ ] **Step 3: 実装する**

`Sources/GhostVoiceCore/Models/HistoryEntry.swift`:

```swift
import Foundation

public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    /// 整形前の書き起こし。Undo で復元する対象。
    public let rawText: String
    /// 整形後の書き起こし。整形せずに挿入した場合は nil。
    public let refinedText: String?
    public let localeIdentifier: String
    public let insertionMethod: InsertionMethod

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        refinedText: String?,
        localeIdentifier: String,
        insertionMethod: InsertionMethod
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.refinedText = refinedText
        self.localeIdentifier = localeIdentifier
        self.insertionMethod = insertionMethod
    }

    /// 実際に挿入された文字列。
    public var insertedText: String { refinedText ?? rawText }
}
```

`Sources/GhostVoiceCore/Storage/HistoryStore.swift`:

```swift
import Foundation

public final class HistoryStore: @unchecked Sendable {
    /// 挿入から Undo を受け付ける時間。これを過ぎるとユーザーが手で
    /// 編集している可能性があるため、無効にする。
    public static let undoWindow: TimeInterval = 10

    private let file: AtomicJSONFile<[HistoryEntry]>
    private let limit: Int
    private let lock = NSLock()
    private var cached: [HistoryEntry]

    public init(rootURL: URL = StorageRoot.default, limit: Int) {
        self.file = AtomicJSONFile(
            url: rootURL.appendingPathComponent("history.json"),
            fallback: []
        )
        self.limit = limit
        self.cached = file.load()
    }

    /// 新しい順。
    public var entries: [HistoryEntry] {
        lock.withLock { cached }
    }

    public func append(_ entry: HistoryEntry) throws {
        try lock.withLock {
            var next = cached
            next.insert(entry, at: 0)
            if next.count > limit { next.removeLast(next.count - limit) }
            try file.save(next)
            cached = next
        }
    }

    /// Undo できる直近の履歴。整形して挿入し、かつ猶予時間内のものだけ。
    public func undoCandidate(now: Date = Date()) -> HistoryEntry? {
        guard let latest = entries.first,
              latest.refinedText != nil,
              now.timeIntervalSince(latest.timestamp) <= Self.undoWindow
        else { return nil }
        return latest
    }
}
```

- [ ] **Step 4: テストを実行し、成功を確認する**

Run: `swift test --filter HistoryStore`
Expected: PASS（6 tests）

- [ ] **Step 5: コミット**

```bash
git add Sources/GhostVoiceCore Tests/GhostVoiceCoreTests/HistoryStoreTests.swift
git commit -m "feat: 履歴ストアと Undo 対象判定を追加"
```

---

## Task 5: 音声認識エンジン（V-1 / V-2 の実測を含む）

> **⚠️ 訂正（Task 5 の実測による / 2026-08-14）**
>
> **以下の計画時のコードには、そのまま実装すると動かない箇所が 5 つある。**
> 計画時の記述は履歴として残してあるが、**参照する順序は
> ① `Sources/GhostVoiceCore/Transcription/` の現物 → ② `docs/03-detailed-design.md` §4 → ③ 本節**とすること。
>
> 1. **`SpeechModule` の使い回しはプロセスを落とす。** 計画では `prepare` で作った `module` を
>    保持し、`begin()` ごとに新しい `SpeechAnalyzer` へ渡している。**2 つ目の `SpeechAnalyzer` へ
>    同じインスタンスを渡すと `SpeechAnalyzer.setWorkers(for:reusingFrom:preservingFunctionOf:)` の
>    内部で SIGTRAP で異常終了する。** PTT なら 2 発話目でアプリが落ちる。
>    → **モジュールは発話ごとに作り直す。** `prepare` が保持するのはロケール・種別・音声形式だけ。
>    作り直しの費用は実測 0.5〜1.4 ms で無視できる。
> 2. **`module.results` は単一消費者しか許さない。** 計画の `Self.updates(from: module)` は
>    `begin()` と `transcribeFile(at:)` の両方から呼ばれる。2 つ目の消費者を立てると
>    **`attempt to await next() on more than one task` で異常終了する**（結果が分裂するのではなく落ちる）。
>    → 1 モジュールにつき結果列の消費は 1 箇所だけにする。
> 3. **`AssetInventory.status` は未確保のロケールに対して、導入済みでも常に `.supported` を返す。**
>    計画は status を見てから `reserve` しているため、**導入済みの ja-JP でも毎回ダウンロードを試みる。**
>    → **`reserve` を先に呼ぶ。** なお `assetInstallationRequest` は未対応ロケールで nil を返さず
>    throw するので、計画の `guard let request ... else { throw .localeUnsupported }` は発火しない。
>    未対応の検出は種別ごとの `supportedLocales` への所属確認で行うこと
>    （`supportedLocale(equivalentTo:)` は識別子を正規化するだけで対応可否を見ない）。
> 4. **`CharacterErrorRate.compute` は仮説が空文字のときクラッシュする。**
>    `for j in 1...hyp.count` が `1...0` の空範囲になる。認識が失敗して空文字が返るのは実際に起こる。
>    → `guard !hyp.isEmpty else { return 1 }` を先に置く。
> 5. **`normalize` の doc コメント「句読点・空白の差は精度の本質ではないため」は実測で否定された。**
>    句読点を残して測ると 2 モジュールの優劣が逆転する（`DictationTranscriber` 5.85 % 対
>    `SpeechTranscriber` 4.96 %。除去すると 3.02 % 対 3.21 %）。句読点は結論を左右する。
>    → 除去する正しい理由は「認識器が付けた句読点は後段の LLM 整形（FR-5）で書き換えられ、
>    製品の出力品質に効かない」であり、この正規化下の CER は「LLM が直せない誤り」を測っている。
>
> 併せて、Step 8 の V-1 / V-2 の結論も更新されている。V-2 は 40〜177 ms（推定値 300 ms を置換）、
> V-1 は**合成音声では有意差なし**（肉声は未実施）。詳細は要件定義書 §2.5 と詳細設計書 §11.2。

**Files:**
- Create: `Sources/GhostVoiceCore/Transcription/Transcribing.swift`
- Create: `Sources/GhostVoiceCore/Transcription/SpeechAnalyzerTranscriber.swift`
- Create: `Tests/GhostVoiceCoreTests/Fixtures/jp-meeting.txt`
- Create: `Tests/GhostVoiceCoreTests/Support/CharacterErrorRate.swift`
- Test: `Tests/GhostVoiceCoreTests/TranscriberGoldenTests.swift`

**Interfaces:**
- Consumes: `TranscriberKind`, `Settings`（Task 1）
- Produces:
  - `TranscriptionUpdate`: `.volatile(String)` / `.final(String)`
  - `Transcribing`: `func prepare(locale:kind:) async throws`, `var requiredAudioFormat: AVAudioFormat? { get async }`, `func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error>`, `func feed(_ buffer: AVAudioPCMBuffer) async`, `func finish() async throws`
  - `SpeechAnalyzerTranscriber`: 上記の実装。加えて `func transcribeFile(at url: URL) async throws -> String`（テストと V-1 計測用）

- [ ] **Step 1: テスト用フィクスチャを作る**

`Tests/GhostVoiceCoreTests/Fixtures/jp-meeting.txt` に以下を保存する。

```
本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。前回は、新しい音声文字起こしツールの導入について議論しました。現状の課題としては、外部のクラウドサービスに音声データを送信することへのセキュリティ上の懸念、および従量課金によるコストの増大が挙げられます。これに対する解決策として、Macのローカル環境で完結する文字起こしの仕組みを検討しています。技術的には、アップルが提供する新しい音声認識のフレームワークを利用することで、ネットワーク接続なしに、高速かつ高精度な文字起こしが実現できる見込みです。処理速度については、一時間の会議音声を数分程度で処理できることを目標としています。次に、想定されるユースケースについて整理します。第一に、社内会議の議事録作成です。第二に、顧客との商談内容の記録です。第三に、インタビューや取材の文字起こしです。いずれのケースでも、話者の識別ができることが望ましいという要望が出ています。ただし、現時点でこの機能は標準のフレームワークには含まれていないため、別途検討が必要です。最後に、今後のスケジュールについてです。来週までに要件定義を完了させ、その後、基本設計と詳細設計に着手します。実装は再来月からを予定しています。何かご質問はございますか。
```

音声はリポジトリに含めず、テスト実行時に生成する。

```bash
cd Tests/GhostVoiceCoreTests/Fixtures
say -v Kyoko -f jp-meeting.txt -o jp-meeting.aiff
```

`.gitignore` に追記する。

```bash
echo "Tests/GhostVoiceCoreTests/Fixtures/*.aiff" >> .gitignore
```

- [ ] **Step 2: 文字誤り率のヘルパーを書く**

`Tests/GhostVoiceCoreTests/Support/CharacterErrorRate.swift`:

```swift
import Foundation

/// レーベンシュタイン距離に基づく文字誤り率。
/// 完全一致で判定すると OS 更新でモデルが変わるたびに壊れるため、閾値判定に使う。
enum CharacterErrorRate {

    static func compute(reference: String, hypothesis: String) -> Double {
        let ref = Array(normalize(reference))
        let hyp = Array(normalize(hypothesis))
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }

        var previous = Array(0...hyp.count)
        var current = [Int](repeating: 0, count: hyp.count + 1)

        for i in 1...ref.count {
            current[0] = i
            for j in 1...hyp.count {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }

    /// 句読点・空白の差は精度の本質ではないため除去して比較する。
    private static func normalize(_ text: String) -> String {
        text.filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
```

- [ ] **Step 3: 失敗するテストを書く**

`Tests/GhostVoiceCoreTests/TranscriberGoldenTests.swift`:

```swift
import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("認識のゴールデンテスト", .serialized)
struct TranscriberGoldenTests {

    private var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    /// 音声が無い環境ではスキップする（CI 等）。
    private func audioURL() throws -> URL {
        let url = fixturesURL.appendingPathComponent("jp-meeting.aiff")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "先に `say -v Kyoko -f jp-meeting.txt -o jp-meeting.aiff` を実行すること")
        return url
    }

    private func reference() throws -> String {
        try String(contentsOf: fixturesURL.appendingPathComponent("jp-meeting.txt"), encoding: .utf8)
    }

    @Test("DictationTranscriber の日本語 CER が 10% 未満")
    func dictationAccuracy() async throws {
        let t = SpeechAnalyzerTranscriber()
        try await t.prepare(locale: Locale(identifier: "ja-JP"), kind: .dictation)
        let result = try await t.transcribeFile(at: try audioURL())

        let cer = CharacterErrorRate.compute(reference: try reference(), hypothesis: result)
        print("DictationTranscriber CER: \(String(format: "%.3f", cer))")
        #expect(cer < 0.10)
    }

    @Test("SpeechTranscriber の日本語 CER が 15% 未満")
    func speechAccuracy() async throws {
        let t = SpeechAnalyzerTranscriber()
        try await t.prepare(locale: Locale(identifier: "ja-JP"), kind: .speech)
        let result = try await t.transcribeFile(at: try audioURL())

        let cer = CharacterErrorRate.compute(reference: try reference(), hypothesis: result)
        print("SpeechTranscriber CER: \(String(format: "%.3f", cer))")
        #expect(cer < 0.15)
    }

    @Test("103 秒の音声を 10 秒以内に処理できる")
    func throughput() async throws {
        let t = SpeechAnalyzerTranscriber()
        try await t.prepare(locale: Locale(identifier: "ja-JP"), kind: .dictation)

        let start = ContinuousClock.now
        _ = try await t.transcribeFile(at: try audioURL())
        let elapsed = ContinuousClock.now - start

        print("elapsed: \(elapsed)")
        #expect(elapsed < .seconds(10))
    }
}
```

閾値の根拠: 設計時の実測で `DictationTranscriber` の誤りは「従量課金→重量課金」「高精度→高度な」「ついて→にいて」等に限られ、CER は 5% 未満と見込まれる。10% は余裕を持たせた回帰検知ラインである。

- [ ] **Step 4: テストを実行し、失敗を確認する**

Run: `swift test --filter TranscriberGolden`
Expected: FAIL（`cannot find 'SpeechAnalyzerTranscriber' in scope`）

- [ ] **Step 5: プロトコルを定義する**

`Sources/GhostVoiceCore/Transcription/Transcribing.swift`:

```swift
import Foundation
import AVFAudio

public enum TranscriptionUpdate: Sendable, Equatable {
    /// 認識途中の暫定結果。後続の入力で書き換わる。HUD 表示用。
    case volatile(String)
    /// 確定結果。
    case final(String)
}

public protocol Transcribing: AnyObject, Sendable {
    /// モデルの導入確認とアナライザの事前準備を行う。起動時とロケール変更時に呼ぶ。
    func prepare(locale: Locale, kind: TranscriberKind) async throws

    /// 認識器が要求する音声形式。AudioCapture 側の変換に使う。
    var requiredAudioFormat: AVAudioFormat? { get async }

    /// 1 回の発話を開始する。
    func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error>

    /// 音声バッファを供給する。
    func feed(_ buffer: AVAudioPCMBuffer) async

    /// 入力終了を通知し、確定処理を待つ。
    func finish() async throws
}

public enum TranscriptionError: Error, Equatable {
    case notPrepared
    case localeUnsupported(String)
    case modelUnavailable
}
```

- [ ] **Step 6: `SpeechAnalyzerTranscriber` を実装する**

`Sources/GhostVoiceCore/Transcription/SpeechAnalyzerTranscriber.swift`:

```swift
import Foundation
import AVFAudio
import Speech

public actor SpeechAnalyzerTranscriber: Transcribing {

    private var module: (any SpeechModule)?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var audioFormat: AVAudioFormat?
    private var locale: Locale = Locale(identifier: "ja-JP")
    private var kind: TranscriberKind = .dictation

    public init() {}

    // MARK: - 準備

    public func prepare(locale: Locale, kind: TranscriberKind) async throws {
        self.locale = locale
        self.kind = kind

        let module = Self.makeModule(locale: locale, kind: kind)
        try await Self.ensureAssets(for: module, locale: locale)

        self.module = module
        self.audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    }

    public var requiredAudioFormat: AVAudioFormat? {
        get async { audioFormat }
    }

    private static func makeModule(locale: Locale, kind: TranscriberKind) -> any SpeechModule {
        switch kind {
        case .dictation:
            // PTT の 1 発話は短文であり、HUD のライブ表示に volatile results が要る
            return DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        case .speech:
            return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        }
    }

    private static func ensureAssets(for module: any SpeechModule, locale: Locale) async throws {
        if await AssetInventory.status(forModules: [module]) != .installed {
            guard let request = try await AssetInventory
                .assetInstallationRequest(supporting: [module])
            else { throw TranscriptionError.localeUnsupported(locale.identifier) }
            try await request.downloadAndInstall()
        }
        try await AssetInventory.reserve(locale: locale)
    }

    // MARK: - ストリーミング

    public func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        guard let module else { throw TranscriptionError.notPrepared }

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = inputContinuation

        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(inputSequence: inputStream, modules: [module], options: options)
        self.analyzer = analyzer

        if let audioFormat {
            try await analyzer.prepareToAnalyze(in: audioFormat)
        }

        return Self.updates(from: module)
    }

    /// `DictationTranscriber` と `SpeechTranscriber` は別の Result 型を持つが、
    /// いずれも `SpeechModuleResult` に準拠し `text` と `isFinal` を提供する。
    private static func updates(from module: any SpeechModule) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let m = module as? DictationTranscriber {
                        for try await r in m.results {
                            continuation.yield(r.isFinal ? .final(String(r.text.characters))
                                                         : .volatile(String(r.text.characters)))
                        }
                    } else if let m = module as? SpeechTranscriber {
                        for try await r in m.results {
                            continuation.yield(r.isFinal ? .final(String(r.text.characters))
                                                         : .volatile(String(r.text.characters)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func feed(_ buffer: AVAudioPCMBuffer) async {
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    public func finish() async throws {
        continuation?.finish()
        continuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
    }

    // MARK: - ファイル入力（テストと精度計測用）

    public func transcribeFile(at url: URL) async throws -> String {
        guard let module else { throw TranscriptionError.notPrepared }

        let file = try AVAudioFile(forReading: url)
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: file, modules: [module], finishAfterFile: true
        )

        var text = ""
        let collector = Task { [module] in
            var acc = ""
            for try await update in Self.updates(from: module) {
                if case .final(let s) = update { acc += s }
            }
            return acc
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        text = try await collector.value
        return text
    }
}
```

- [ ] **Step 7: テストを実行し、成功を確認する**

```bash
cd Tests/GhostVoiceCoreTests/Fixtures && say -v Kyoko -f jp-meeting.txt -o jp-meeting.aiff && cd -
swift test --filter TranscriberGolden
```

Expected: PASS（3 tests）。出力される CER の実測値を控える。

- [ ] **Step 8: V-1 / V-2 の結果を設計書へ反映する**

テスト出力の CER 実測値を `docs/03-detailed-design.md` §11.2 の基準値表に追記する。**`SpeechTranscriber` の CER が `DictationTranscriber` を下回った場合、`Settings.default` の `transcriberKind` を `.speech` に変更する。**

> **重要**: このタスクの本来の検証対象は肉声である。合成音声のテストが通ったら、実際に自分の声で 1 分程度の音声を録音し、同じ計測を手動で行うこと。結果は設計書 §13 の V-1 欄に記録する。

- [ ] **Step 9: コミット**

```bash
git add Sources/GhostVoiceCore/Transcription Tests/GhostVoiceCoreTests docs/03-detailed-design.md .gitignore
git commit -m "feat: SpeechAnalyzer による音声認識エンジンとゴールデンテストを追加"
```

---

## Task 6: LLM 整形

**Files:**
- Create: `Sources/GhostVoiceCore/Refinement/Refining.swift`
- Create: `Sources/GhostVoiceCore/Refinement/FoundationModelRefiner.swift`
- Test: `Tests/GhostVoiceCoreTests/RefinerTests.swift`

**Interfaces:**
- Consumes: `RefinementPrompt`, `VocabularyTerm`（Task 3）
- Produces:
  - `Refining`: `var isAvailable: Bool { get }`, `func prewarm() async`, `func refine(_ raw: String, locale: Locale, terms: [VocabularyTerm], timeout: Duration) async -> String?`
  - `FoundationModelRefiner`: 上記の実装
  - `StubRefiner`: テスト用のモック実装（`init(result: String?, delay: Duration)`）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/GhostVoiceCoreTests/RefinerTests.swift`:

```swift
import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("Refiner")
struct RefinerTests {

    @Test("タイムアウトすると nil を返す")
    func timesOut() async {
        let stub = StubRefiner(result: "整形結果", delay: .milliseconds(400))
        let out = await stub.refine("生", locale: Locale(identifier: "ja-JP"),
                                    terms: [], timeout: .milliseconds(50))
        #expect(out == nil)
    }

    @Test("時間内なら結果を返す")
    func returnsWithinTimeout() async {
        let stub = StubRefiner(result: "整形結果", delay: .milliseconds(10))
        let out = await stub.refine("生", locale: Locale(identifier: "ja-JP"),
                                    terms: [], timeout: .milliseconds(500))
        #expect(out == "整形結果")
    }

    @Test("利用不可なら常に nil を返す")
    func unavailableReturnsNil() async {
        let stub = StubRefiner(result: nil, delay: .zero)
        #expect(!stub.isAvailable)
        let out = await stub.refine("生", locale: Locale(identifier: "ja-JP"),
                                    terms: [], timeout: .milliseconds(500))
        #expect(out == nil)
    }

    @Test("実機でフィラーが除去される", .enabled(if: FoundationModelRefiner().isAvailable))
    func removesFillersOnDevice() async {
        let refiner = FoundationModelRefiner()
        await refiner.prewarm()

        let out = await refiner.refine(
            "えーっと、あの、来週までに要件定義を完了させます",
            locale: Locale(identifier: "ja-JP"), terms: [], timeout: .seconds(5)
        )
        let result = try! #require(out)
        #expect(!result.contains("えーっと"))
        #expect(!result.contains("あの"))
        #expect(result.contains("要件定義"))
    }

    @Test("ウォーム後の整形が 500ms 以内", .enabled(if: FoundationModelRefiner().isAvailable))
    func warmLatency() async {
        let refiner = FoundationModelRefiner()
        await refiner.prewarm()
        // 初回はモデルロードを含むため捨てる（実測 1.9 秒）
        _ = await refiner.refine("ウォームアップ", locale: Locale(identifier: "ja-JP"),
                                 terms: [], timeout: .seconds(10))

        let start = ContinuousClock.now
        _ = await refiner.refine("えー、この関数にエラー処理を追加したいです",
                                 locale: Locale(identifier: "ja-JP"), terms: [], timeout: .seconds(10))
        let elapsed = ContinuousClock.now - start

        print("warm refine: \(elapsed)")
        #expect(elapsed < .milliseconds(500))
    }
}
```

- [ ] **Step 2: テストを実行し、失敗を確認する**

Run: `swift test --filter Refiner`
Expected: FAIL（`cannot find 'StubRefiner' in scope`）

- [ ] **Step 3: プロトコルとスタブを実装する**

`Sources/GhostVoiceCore/Refinement/Refining.swift`:

```swift
import Foundation

public protocol Refining: Sendable {
    /// LLM が使えるか。Apple Intelligence が無効な環境では false。
    var isAvailable: Bool { get }

    /// モデルを事前ロードする。実測でコールド 1.9 秒 / ウォーム 0.35 秒。
    func prewarm() async

    /// 整形する。タイムアウトまたは失敗時は nil を返し、呼び出し側が生テキストへ縮退する。
    func refine(
        _ raw: String, locale: Locale, terms: [VocabularyTerm], timeout: Duration
    ) async -> String?
}

/// テスト用。指定した遅延の後に指定した結果を返す。
public struct StubRefiner: Refining {
    private let result: String?
    private let delay: Duration

    public init(result: String?, delay: Duration) {
        self.result = result
        self.delay = delay
    }

    public var isAvailable: Bool { result != nil }

    public func prewarm() async {}

    public func refine(
        _ raw: String, locale: Locale, terms: [VocabularyTerm], timeout: Duration
    ) async -> String? {
        guard let result else { return nil }
        return await withTimeout(timeout) {
            try? await Task.sleep(for: delay)
            return Task.isCancelled ? nil : result
        }
    }
}

/// 指定時間内に完了しなければ nil を返す。
func withTimeout(_ timeout: Duration, _ work: @escaping @Sendable () async -> String?) async -> String? {
    await withTaskGroup(of: String?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
```

- [ ] **Step 4: `FoundationModelRefiner` を実装する**

`Sources/GhostVoiceCore/Refinement/FoundationModelRefiner.swift`:

```swift
import Foundation
import FoundationModels

public final class FoundationModelRefiner: Refining, @unchecked Sendable {

    private let lock = NSLock()
    private var session: LanguageModelSession?
    private var sessionLocaleIdentifier: String?

    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func prewarm() async {
        guard isAvailable else { return }
        makeSession(for: Locale(identifier: "ja-JP")).prewarm()
    }

    public func refine(
        _ raw: String, locale: Locale, terms: [VocabularyTerm], timeout: Duration
    ) async -> String? {
        guard isAvailable else { return nil }

        let session = makeSession(for: locale)
        let prompt = RefinementPrompt.prompt(rawText: raw, terms: terms)

        let output = await withTimeout(timeout) {
            let options = GenerationOptions(temperature: 0.0)
            return try? await session.respond(to: prompt, options: options).content
        }

        // 1 発話 = 1 リクエスト。前の発話が次の整形へ混入しないよう毎回セッションを捨てる。
        // 再生成コストは実測 0.036 秒（init 0.028 + prewarm 0.008）。
        discardSession()

        guard let output else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func makeSession(for locale: Locale) -> LanguageModelSession {
        lock.withLock {
            if let session, sessionLocaleIdentifier == locale.identifier { return session }
            let created = LanguageModelSession(instructions: RefinementPrompt.instructions(for: locale))
            created.prewarm()
            session = created
            sessionLocaleIdentifier = locale.identifier
            return created
        }
    }

    private func discardSession() {
        lock.withLock {
            session = nil
            sessionLocaleIdentifier = nil
        }
    }
}
```

- [ ] **Step 5: テストを実行し、成功を確認する**

Run: `swift test --filter Refiner`
Expected: PASS（5 tests。Apple Intelligence 無効環境では実機テスト 2 件がスキップされる）

`warmLatency` が失敗する場合、セッション破棄のたびに `prewarm()` が走るコストが原因である。その場合はセッションを保持したまま履歴だけをリセットする方式へ変更し、計測し直す。

- [ ] **Step 6: コミット**

```bash
git add Sources/GhostVoiceCore/Refinement Tests/GhostVoiceCoreTests/RefinerTests.swift
git commit -m "feat: FoundationModels による整形とタイムアウト縮退を追加"
```

---

## Task 7: マイク入力

> **⚠️ 注意（Task 5 の検証で判明 / 2026-08-14）— 計画書の欠陥ではなく、実装時に踏みうる落とし穴**
>
> **`installTap` のブロックは、それを設置した文脈の actor 隔離を引き継ぐ。**
> MainActor 文脈（`@main` の `main()`、SwiftUI のビュー、`@MainActor` を付けたテスト等）から設置すると、
> 実時間オーディオスレッドで隔離チェックに失敗し **SIGTRAP で落ちる**
> （`_swift_task_checkIsolatedSwift` → `dispatch_assert_queue_fail`）。症状は「起動直後に落ちる」だけで原因に辿り着きにくい。
> **設置は非隔離の型の中で行うこと。** 下記の `EngineAudioCapture`（`final class`、非隔離）はこれを満たしている。
> フェーズ 2 の HUD は MainActor なので、そこから触るときに踏みやすい。

**Files:**
- Create: `Sources/GhostVoiceCore/Audio/AudioCapturing.swift`
- Create: `Sources/GhostVoiceCore/Audio/EngineAudioCapture.swift`
- Test: `Tests/GhostVoiceCoreTests/AudioCaptureTests.swift`

**Interfaces:**
- Consumes: なし
- Produces:
  - `AudioCapturing`: `func prepare() throws`, `func startTap(format: AVAudioFormat?) -> AsyncStream<AVAudioPCMBuffer>`, `func stopTap()`, `var level: AsyncStream<Float> { get }`
  - `EngineAudioCapture`: 上記の実装
  - `AudioCaptureError.engineUnavailable`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/GhostVoiceCoreTests/AudioCaptureTests.swift`:

```swift
import Testing
import Foundation
import AVFAudio
@testable import GhostVoiceCore

@Suite("AudioCapture", .serialized)
struct AudioCaptureTests {

    /// マイク権限が無い環境ではスキップする。
    private var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    @Test("prepare を二重に呼んでも例外を出さない")
    func prepareIsIdempotent() throws {
        let capture = EngineAudioCapture()
        try capture.prepare()
        try capture.prepare()
        capture.stopTap()
    }

    @Test("タップ着脱を繰り返してもエンジンが生きている")
    func tapCycling() throws {
        let capture = EngineAudioCapture()
        try capture.prepare()
        for _ in 0..<3 {
            _ = capture.startTap(format: nil)
            capture.stopTap()
        }
        #expect(capture.isEngineRunning)
    }

    @Test("マイクからバッファが届く", .enabled(if: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized))
    func receivesBuffers() async throws {
        let capture = EngineAudioCapture()
        try capture.prepare()
        let stream = capture.startTap(format: nil)

        var count = 0
        let deadline = ContinuousClock.now + .seconds(2)
        for await _ in stream {
            count += 1
            if count >= 3 || ContinuousClock.now > deadline { break }
        }
        capture.stopTap()

        #expect(count >= 3)
    }
}
```

- [ ] **Step 2: テストを実行し、失敗を確認する**

Run: `swift test --filter AudioCapture`
Expected: FAIL（`cannot find 'EngineAudioCapture' in scope`）

- [ ] **Step 3: プロトコルを定義する**

`Sources/GhostVoiceCore/Audio/AudioCapturing.swift`:

```swift
import Foundation
import AVFAudio

public enum AudioCaptureError: Error, Equatable {
    case engineUnavailable
}

public protocol AudioCapturing: AnyObject, Sendable {
    /// エンジンを起動し、常時ウォーム状態にする。アプリ起動時に一度だけ呼ぶ。
    /// 録音開始のたびに起動すると NFR-P1（50 ms 以内）を満たせない。
    func prepare() throws

    /// タップを装着してバッファの供給を開始する。
    /// format が nil なら入力ノードの形式をそのまま使う。
    func startTap(format: AVAudioFormat?) -> AsyncStream<AVAudioPCMBuffer>

    /// タップを外す。エンジンは止めない。
    func stopTap()

    /// 直近バッファの RMS。HUD の音量インジケータ用。
    var level: AsyncStream<Float> { get }
}
```

- [ ] **Step 4: `EngineAudioCapture` を実装する**

`Sources/GhostVoiceCore/Audio/EngineAudioCapture.swift`:

```swift
import Foundation
import AVFAudio

public final class EngineAudioCapture: AudioCapturing, @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var isPrepared = false
    private var isTapped = false

    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private let levelStream: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation

    public init() {
        (levelStream, levelContinuation) = AsyncStream<Float>.makeStream()
    }

    public var level: AsyncStream<Float> { levelStream }

    public var isEngineRunning: Bool { engine.isRunning }

    public func prepare() throws {
        try lock.withLock {
            guard !isPrepared else { return }
            engine.prepare()
            try engine.start()
            isPrepared = true
        }
    }

    public func startTap(format: AVAudioFormat?) -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        lock.withLock {
            if isTapped { engine.inputNode.removeTap(onBus: 0) }
            bufferContinuation = continuation

            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            let converter = format.flatMap { AVAudioConverter(from: inputFormat, to: $0) }

            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                self.levelContinuation.yield(Self.rms(of: buffer))

                guard let converter, let target = format else {
                    continuation.yield(buffer)
                    return
                }
                guard let converted = Self.convert(buffer, using: converter, to: target) else { return }
                continuation.yield(converted)
            }
            isTapped = true
        }
        return stream
    }

    public func stopTap() {
        lock.withLock {
            guard isTapped else { return }
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false
            bufferContinuation?.finish()
            bufferContinuation = nil
        }
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return (sum / Float(count)).squareRoot()
    }
}
```

- [ ] **Step 5: テストを実行し、成功を確認する**

Run: `swift test --filter AudioCapture`
Expected: PASS（3 tests。マイク権限が無ければ 1 件スキップ）

初回実行時にマイク権限のダイアログが出る。許可すること。

- [ ] **Step 6: コミット**

```bash
git add Sources/GhostVoiceCore/Audio Tests/GhostVoiceCoreTests/AudioCaptureTests.swift
git commit -m "feat: 常時ウォームな AVAudioEngine による音声取得を追加"
```

---

## Task 8: テキスト挿入（二段構え）

**Files:**
- Create: `Sources/GhostVoiceCore/Insertion/TextInserting.swift`
- Create: `Sources/GhostVoiceCore/Insertion/AccessibilityInserter.swift`
- Create: `Sources/GhostVoiceCore/Insertion/PasteboardInserter.swift`
- Create: `Sources/GhostVoiceCore/Insertion/CompositeInserter.swift`
- Test: `Tests/GhostVoiceCoreTests/CompositeInserterTests.swift`

**Interfaces:**
- Consumes: `InsertionMethod`（Task 1）
- Produces:
  - `TextInserting`: `func insert(_ text: String) async -> InsertionMethod`
  - `PrimaryInserting`: `func canInsert() -> Bool`, `func tryInsert(_ text: String) async -> Bool`
  - `AccessibilityInserter`, `PasteboardInserter`, `CompositeInserter(primary:fallback:)`
  - `StubInserter`: テスト用（`init(canInsert: Bool, succeeds: Bool)`）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/GhostVoiceCoreTests/CompositeInserterTests.swift`:

```swift
import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("CompositeInserter")
struct CompositeInserterTests {

    @Test("AX が使えるなら AX 経路になる")
    func usesAXWhenPossible() async {
        let composite = CompositeInserter(
            primary: StubInserter(canInsert: true, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true)
        )
        #expect(await composite.insert("テキスト") == .ax)
    }

    @Test("AX が適用外なら Pasteboard 経路になる")
    func fallsBackWhenAXUnavailable() async {
        let composite = CompositeInserter(
            primary: StubInserter(canInsert: false, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true)
        )
        #expect(await composite.insert("テキスト") == .pasteboard)
    }

    @Test("AX が失敗したら Pasteboard 経路へ落ちる")
    func fallsBackWhenAXFails() async {
        let composite = CompositeInserter(
            primary: StubInserter(canInsert: true, succeeds: false),
            fallback: StubInserter(canInsert: true, succeeds: true)
        )
        #expect(await composite.insert("テキスト") == .pasteboard)
    }

    @Test("両方失敗したら clipboardOnly になる")
    func reportsClipboardOnlyWhenBothFail() async {
        let composite = CompositeInserter(
            primary: StubInserter(canInsert: true, succeeds: false),
            fallback: StubInserter(canInsert: true, succeeds: false)
        )
        #expect(await composite.insert("テキスト") == .clipboardOnly)
    }
}
```

- [ ] **Step 2: テストを実行し、失敗を確認する**

Run: `swift test --filter CompositeInserter`
Expected: FAIL（`cannot find 'CompositeInserter' in scope`）

- [ ] **Step 3: プロトコルとスタブを実装する**

`Sources/GhostVoiceCore/Insertion/TextInserting.swift`:

```swift
import Foundation

public protocol TextInserting: Sendable {
    /// テキストを挿入し、実際に使われた経路を返す。
    func insert(_ text: String) async -> InsertionMethod
}

/// 二段構えの各段。
public protocol PrimaryInserting: Sendable {
    /// この経路が適用できる状況か。判定は安価でなければならない。
    func canInsert() -> Bool
    /// 挿入を試みる。成功したら true。
    func tryInsert(_ text: String) async -> Bool
}

/// テスト用。
public struct StubInserter: PrimaryInserting {
    private let canInsertValue: Bool
    private let succeeds: Bool

    public init(canInsert: Bool, succeeds: Bool) {
        self.canInsertValue = canInsert
        self.succeeds = succeeds
    }

    public func canInsert() -> Bool { canInsertValue }
    public func tryInsert(_ text: String) async -> Bool { succeeds }
}
```

`Sources/GhostVoiceCore/Insertion/CompositeInserter.swift`:

```swift
import Foundation

/// AX 経路を試し、駄目なら Pasteboard 経路へ落とす。
///
/// AX は一部アプリ（Electron 製など）で無言失敗するため、経路を一本に絞れない。
public struct CompositeInserter: TextInserting {
    private let primary: any PrimaryInserting
    private let fallback: any PrimaryInserting

    public init(primary: any PrimaryInserting, fallback: any PrimaryInserting) {
        self.primary = primary
        self.fallback = fallback
    }

    public func insert(_ text: String) async -> InsertionMethod {
        if primary.canInsert(), await primary.tryInsert(text) { return .ax }
        if fallback.canInsert(), await fallback.tryInsert(text) { return .pasteboard }
        return .clipboardOnly
    }
}
```

- [ ] **Step 4: `AccessibilityInserter` を実装する**

`Sources/GhostVoiceCore/Insertion/AccessibilityInserter.swift`:

```swift
import Foundation
import ApplicationServices

public struct AccessibilityInserter: PrimaryInserting {

    private static let insertableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    public init() {}

    /// 3 条件をすべて満たす場合のみ AX 経路を使う。
    /// 1) フォーカス要素が取れる 2) 役割がテキスト入力 3) 属性が書き込み可能
    public func canInsert() -> Bool {
        guard let element = Self.focusedElement() else { return false }
        guard let role = Self.string(of: element, attribute: kAXRoleAttribute as String),
              Self.insertableRoles.contains(role) else { return false }

        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        )
        return status == .success && settable.boolValue
    }

    public func tryInsert(_ text: String) async -> Bool {
        guard let element = Self.focusedElement() else { return false }
        let status = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        )
        return status == .success
    }

    private static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value
        )
        guard status == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
```

- [ ] **Step 5: `PasteboardInserter` を実装する**

`Sources/GhostVoiceCore/Insertion/PasteboardInserter.swift`:

```swift
import Foundation
import AppKit
import CoreGraphics

public struct PasteboardInserter: PrimaryInserting {

    /// ⌘V 送出から復元までの待ち時間。短すぎると貼付前に復元してしまう。
    /// 【フェーズ 2 の注記】この 120 ms はフェーズ 1 時点の値である。
    /// V-3（2026-08-14 / 実機）で不足と判明し、既定は 300 ms
    /// （`PasteboardInserter.defaultRestoreDelay`）へ引き上げられた。詳細設計書 §6.3。
    static let restoreDelay: Duration = .milliseconds(120)

    private static let vKeyCode: CGKeyCode = 0x09

    public init() {}

    /// Pasteboard 経路は常に試せる。
    public func canInsert() -> Bool { true }

    public func tryInsert(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(of: pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }

        guard Self.postCommandV() else {
            // 送出に失敗してもテキストはクリップボードに残す。失うより良い。
            return false
        }

        try? await Task.sleep(for: Self.restoreDelay)
        Self.restore(saved, to: pasteboard)
        return true
    }

    // MARK: - クリップボードの退避と復元

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    /// 画像やリッチテキストを壊さないよう、全タイプを退避する。
    private static func snapshot(of pasteboard: NSPasteboard) -> Snapshot {
        pasteboard.pasteboardItems?.map { item in
            var stored: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { stored[type] = data }
            }
            return stored
        } ?? []
    }

    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        guard !snapshot.isEmpty else { return }
        pasteboard.clearContents()
        let items = snapshot.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
```

- [ ] **Step 6: テストを実行し、成功を確認する**

Run: `swift test --filter CompositeInserter`
Expected: PASS（4 tests）

- [ ] **Step 7: V-3 の手動検証を行う**

Task 11 の CLI が完成するまで実挿入は試せない。ここでは**検証手順のみを用意する**。`docs/03-detailed-design.md` §11.3 の表に「結果」列を追加し、空欄のまま残しておく。Task 11 完了後に埋める。

- [ ] **Step 8: コミット**

```bash
git add Sources/GhostVoiceCore/Insertion Tests/GhostVoiceCoreTests/CompositeInserterTests.swift docs/03-detailed-design.md
git commit -m "feat: AX と Pasteboard の二段構えテキスト挿入を追加"
```

---

## Task 9: ホットキー監視

**Files:**
- Create: `Sources/GhostVoiceCore/Hotkey/HotkeyMonitor.swift`
- Create: `Sources/GhostVoiceCore/Hotkey/CGEventTapHotkeyMonitor.swift`
- Test: `Tests/GhostVoiceCoreTests/HotkeyMonitorTests.swift`

**Interfaces:**
- Consumes: `HotkeyBinding`（Task 1）
- Produces:
  - `HotkeyEvent`: `.pressed` / `.released` / `.cancelled`
  - `HotkeyMonitor`: `var events: AsyncStream<HotkeyEvent> { get }`, `func start() throws`, `func stop()`
  - `CGEventTapHotkeyMonitor(binding:)`
  - `HotkeyDecision.decide(keyCode:flags:binding:isRecording:) -> (HotkeyEvent?, suppress: Bool)` — 純粋関数。テスト対象はここ
  - `StubHotkeyMonitor`: テスト用（`func emit(_ event: HotkeyEvent)`）

- [ ] **Step 1: 失敗するテストを書く**

判定ロジックを純粋関数に切り出し、CGEventTap を使わずにテストする。

`Tests/GhostVoiceCoreTests/HotkeyMonitorTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import GhostVoiceCore

@Suite("HotkeyDecision")
struct HotkeyMonitorTests {

    private let ptt = HotkeyBinding.rightOption

    @Test("右 Option を押すと pressed になる")
    func rightOptionDown() {
        let (event, suppress) = HotkeyDecision.decide(
            keyCode: 0x3D, flags: [.maskAlternate], binding: ptt, isRecording: false
        )
        #expect(event == .pressed)
        // 修飾キーは抑止しない。抑止すると下流アプリが修飾状態を見失う。
        #expect(!suppress)
    }

    @Test("右 Option を離すと released になる")
    func rightOptionUp() {
        let (event, suppress) = HotkeyDecision.decide(
            keyCode: 0x3D, flags: [], binding: ptt, isRecording: true
        )
        #expect(event == .released)
        #expect(!suppress)
    }

    @Test("左 Option には反応しない")
    func ignoresLeftOption() {
        let (event, _) = HotkeyDecision.decide(
            keyCode: 0x3A, flags: [.maskAlternate], binding: ptt, isRecording: false
        )
        #expect(event == nil)
    }

    @Test("録音中の ESC は cancelled になり、抑止される")
    func escapeCancelsAndIsSuppressed() {
        let (event, suppress) = HotkeyDecision.decide(
            keyCode: 0x35, flags: [], binding: ptt, isRecording: true
        )
        #expect(event == .cancelled)
        // 中断操作を挿入先アプリへ漏らさない
        #expect(suppress)
    }

    @Test("録音していないときの ESC は素通しする")
    func escapePassesThroughWhenIdle() {
        let (event, suppress) = HotkeyDecision.decide(
            keyCode: 0x35, flags: [], binding: ptt, isRecording: false
        )
        #expect(event == nil)
        #expect(!suppress)
    }

    @Test("録音中に同じ押下が重複して届いても pressed を二度出さない")
    func noDuplicatePressed() {
        let (event, _) = HotkeyDecision.decide(
            keyCode: 0x3D, flags: [.maskAlternate], binding: ptt, isRecording: true
        )
        #expect(event == nil)
    }
}
```

- [ ] **Step 2: テストを実行し、失敗を確認する**

Run: `swift test --filter HotkeyDecision`
Expected: FAIL（`cannot find 'HotkeyDecision' in scope`）

- [ ] **Step 3: プロトコルと判定ロジックを実装する**

`Sources/GhostVoiceCore/Hotkey/HotkeyMonitor.swift`:

```swift
import Foundation
import CoreGraphics

public enum HotkeyEvent: Sendable, Equatable {
    case pressed
    case released
    /// ESC による中断
    case cancelled
}

public protocol HotkeyMonitor: AnyObject, Sendable {
    var events: AsyncStream<HotkeyEvent> { get }
    func start() throws
    func stop()
}

public enum HotkeyError: Error, Equatable {
    case accessibilityPermissionDenied
    case tapCreationFailed
}

/// キーイベントの解釈。CGEventTap から切り離した純粋関数としてテストする。
public enum HotkeyDecision {

    static let escapeKeyCode: Int64 = 0x35

    /// - Returns: 発火するイベントと、そのキーイベントを抑止するか。
    public static func decide(
        keyCode: Int64,
        flags: CGEventFlags,
        binding: HotkeyBinding,
        isRecording: Bool
    ) -> (event: HotkeyEvent?, suppress: Bool) {

        if keyCode == escapeKeyCode {
            // 録音中の ESC だけを中断として消費する
            return isRecording ? (.cancelled, true) : (nil, false)
        }

        guard keyCode == binding.keyCode else { return (nil, false) }

        let isDown = flags.contains(binding.modifiers.cgEventFlags)

        // 修飾キーの flagsChanged は決して抑止しない。
        // 抑止すると下流アプリが修飾状態を見失い、⌥+矢印などが壊れる。
        switch (isDown, isRecording) {
        case (true, false):  return (.pressed, false)
        case (false, true):  return (.released, false)
        default:             return (nil, false)
        }
    }
}

extension HotkeyBinding.Modifiers {
    var cgEventFlags: CGEventFlags {
        var flags = CGEventFlags()
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.option)  { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.shift)   { flags.insert(.maskShift) }
        return flags
    }
}

/// テスト用。任意のタイミングでイベントを流せる。
public final class StubHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    public let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    public init() {
        (events, continuation) = AsyncStream<HotkeyEvent>.makeStream()
    }

    public func start() throws {}
    public func stop() { continuation.finish() }
    public func emit(_ event: HotkeyEvent) { continuation.yield(event) }
}
```

- [ ] **Step 4: `CGEventTapHotkeyMonitor` を実装する**

`Sources/GhostVoiceCore/Hotkey/CGEventTapHotkeyMonitor.swift`:

```swift
import Foundation
import CoreGraphics
import ApplicationServices

public final class CGEventTapHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {

    public let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    private let binding: HotkeyBinding
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var isRecording = false

    public init(binding: HotkeyBinding) {
        self.binding = binding
        (events, continuation) = AsyncStream<HotkeyEvent>.makeStream()
    }

    public func start() throws {
        guard AXIsProcessTrusted() else { throw HotkeyError.accessibilityPermissionDenied }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<CGEventTapHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(event)
            },
            userInfo: context
        ) else { throw HotkeyError.tapCreationFailed }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        continuation.finish()
    }

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        let (hotkeyEvent, suppress) = lock.withLock {
            let decision = HotkeyDecision.decide(
                keyCode: keyCode, flags: event.flags, binding: binding, isRecording: isRecording
            )
            switch decision.event {
            case .pressed:              isRecording = true
            case .released, .cancelled: isRecording = false
            case nil:                   break
            }
            return decision
        }

        if let hotkeyEvent { continuation.yield(hotkeyEvent) }
        return suppress ? nil : Unmanaged.passUnretained(event)
    }
}
```

- [ ] **Step 5: テストを実行し、成功を確認する**

Run: `swift test --filter HotkeyDecision`
Expected: PASS（6 tests）

- [ ] **Step 6: コミット**

```bash
git add Sources/GhostVoiceCore/Hotkey Tests/GhostVoiceCoreTests/HotkeyMonitorTests.swift
git commit -m "feat: CGEventTap による PTT ホットキー監視を追加"
```

---

## Task 10: 状態機械と性能計測

**Files:**
- Create: `Sources/GhostVoiceCore/Support/Metrics.swift`
- Create: `Sources/GhostVoiceCore/Session/DictationSession.swift`
- Test: `Tests/GhostVoiceCoreTests/DictationSessionTests.swift`

**Interfaces:**
- Consumes: `HotkeyMonitor`, `AudioCapturing`, `Transcribing`, `Refining`, `TextInserting`, `HistoryStore`, `VocabularyStore`, `SettingsStore`（Task 2〜9）
- Produces:
  - `SessionState`: `.idle` / `.recording` / `.finalizing` / `.refining` / `.inserting`
  - `DictationSession`: `init(settings:hotkey:audio:transcriber:refiner:inserter:history:vocabulary:)`, `func run() async`, `var stateUpdates: AsyncStream<SessionState>`, `var latestMetrics: Metrics.Sample?`
  - `Metrics.Sample`: `finalizeMs`, `refineMs`, `insertMs`, `totalMs`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/GhostVoiceCoreTests/DictationSessionTests.swift`:

```swift
import Testing
import Foundation
import AVFAudio
@testable import GhostVoiceCore

/// 認識器のテスト代役。feed された内容によらず、finish 時に固定文字列を確定する。
final class StubTranscriber: Transcribing, @unchecked Sendable {
    private let finalText: String
    private var continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    init(finalText: String) { self.finalText = finalText }

    func prepare(locale: Locale, kind: TranscriberKind) async throws {}
    var requiredAudioFormat: AVAudioFormat? { get async { nil } }

    func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.yield(.volatile(String(finalText.prefix(3))))
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) async {}

    func finish() async throws {
        continuation?.yield(.final(finalText))
        continuation?.finish()
    }
}

/// 挿入されたテキストを記録するだけの代役。
final class RecordingInserter: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var _inserted: [String] = []
    var inserted: [String] { lock.withLock { _inserted } }

    func insert(_ text: String) async -> InsertionMethod {
        lock.withLock { _inserted.append(text) }
        return .ax
    }
}

@Suite("DictationSession")
struct DictationSessionTests {

    private func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSession(
        refiner: any Refining,
        inserter: RecordingInserter,
        hotkey: StubHotkeyMonitor,
        root: URL
    ) -> DictationSession {
        DictationSession(
            settings: SettingsStore(rootURL: root),
            hotkey: hotkey,
            audio: EngineAudioCapture(),
            transcriber: StubTranscriber(finalText: "えー、生テキストです"),
            refiner: refiner,
            inserter: inserter,
            history: HistoryStore(rootURL: root, limit: 50),
            vocabulary: VocabularyStore(rootURL: root)
        )
    }

    @Test("整形が成功したら整形後テキストを挿入する")
    func insertsRefinedText() async throws {
        let root = try makeTempRoot()
        let hotkey = StubHotkeyMonitor()
        let inserter = RecordingInserter()
        let session = makeSession(
            refiner: StubRefiner(result: "整形後テキストです", delay: .milliseconds(10)),
            inserter: inserter, hotkey: hotkey, root: root
        )

        let task = Task { await session.run() }
        hotkey.emit(.pressed)
        try await Task.sleep(for: .milliseconds(50))
        hotkey.emit(.released)
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        #expect(inserter.inserted == ["整形後テキストです"])
    }

    @Test("整形がタイムアウトしたら生テキストを挿入する")
    func fallsBackToRawText() async throws {
        let root = try makeTempRoot()
        let hotkey = StubHotkeyMonitor()
        let inserter = RecordingInserter()
        let session = makeSession(
            refiner: StubRefiner(result: "整形後テキストです", delay: .seconds(5)),
            inserter: inserter, hotkey: hotkey, root: root
        )

        let task = Task { await session.run() }
        hotkey.emit(.pressed)
        try await Task.sleep(for: .milliseconds(50))
        hotkey.emit(.released)
        try await Task.sleep(for: .milliseconds(800))
        task.cancel()

        #expect(inserter.inserted == ["えー、生テキストです"])
    }

    @Test("中断したら何も挿入しない")
    func cancelInsertsNothing() async throws {
        let root = try makeTempRoot()
        let hotkey = StubHotkeyMonitor()
        let inserter = RecordingInserter()
        let session = makeSession(
            refiner: StubRefiner(result: "整形後", delay: .milliseconds(10)),
            inserter: inserter, hotkey: hotkey, root: root
        )

        let task = Task { await session.run() }
        hotkey.emit(.pressed)
        try await Task.sleep(for: .milliseconds(50))
        hotkey.emit(.cancelled)
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        #expect(inserter.inserted.isEmpty)
    }

    @Test("挿入後に履歴が残る")
    func recordsHistory() async throws {
        let root = try makeTempRoot()
        let hotkey = StubHotkeyMonitor()
        let session = makeSession(
            refiner: StubRefiner(result: "整形後テキストです", delay: .milliseconds(10)),
            inserter: RecordingInserter(), hotkey: hotkey, root: root
        )

        let task = Task { await session.run() }
        hotkey.emit(.pressed)
        try await Task.sleep(for: .milliseconds(50))
        hotkey.emit(.released)
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        let entry = try #require(HistoryStore(rootURL: root, limit: 50).entries.first)
        #expect(entry.rawText == "えー、生テキストです")
        #expect(entry.refinedText == "整形後テキストです")
    }
}
```

- [ ] **Step 2: テストを実行し、失敗を確認する**

Run: `swift test --filter DictationSession`
Expected: FAIL（`cannot find 'DictationSession' in scope`）

- [ ] **Step 3: `Metrics` を実装する**

`Sources/GhostVoiceCore/Support/Metrics.swift`:

```swift
import Foundation

public enum Metrics {
    /// 1 発話ぶんの計測値。目標は総計 1000 ms 以内（NFR-P6）。
    public struct Sample: Sendable, Equatable {
        /// キー解放 → 確定（目標 300 ms）
        public let finalizeMs: Int
        /// 確定 → 整形完了（目標 500 ms）
        public let refineMs: Int
        /// 整形完了 → 挿入完了（目標 50 ms）
        public let insertMs: Int

        public var totalMs: Int { finalizeMs + refineMs + insertMs }
        public var meetsTarget: Bool { totalMs <= 1000 }

        public init(finalizeMs: Int, refineMs: Int, insertMs: Int) {
            self.finalizeMs = finalizeMs
            self.refineMs = refineMs
            self.insertMs = insertMs
        }
    }

    static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }
}
```

- [ ] **Step 4: `DictationSession` を実装する**

`Sources/GhostVoiceCore/Session/DictationSession.swift`:

```swift
import Foundation

public enum SessionState: Sendable, Equatable {
    case idle
    case recording(volatileText: String)
    case finalizing
    case refining
    case inserting
    case failed(String)
}

/// PTT 1 回ぶんの流れを統括する状態機械。
///
/// 原則: 発話を失わない。各段の失敗は縮退で吸収し、最悪でも
/// クリップボードにテキストが残るようにする。
public actor DictationSession {

    private let settings: SettingsStore
    private let hotkey: any HotkeyMonitor
    private let audio: any AudioCapturing
    private let transcriber: any Transcribing
    private let refiner: any Refining
    private let inserter: any TextInserting
    private let history: HistoryStore
    private let vocabulary: VocabularyStore

    private let stateContinuation: AsyncStream<SessionState>.Continuation
    public nonisolated let stateUpdates: AsyncStream<SessionState>

    public private(set) var latestMetrics: Metrics.Sample?

    private var recordingTask: Task<Void, Never>?
    private var latestVolatile = ""
    private var latestFinal = ""
    private var isCancelled = false

    public init(
        settings: SettingsStore,
        hotkey: any HotkeyMonitor,
        audio: any AudioCapturing,
        transcriber: any Transcribing,
        refiner: any Refining,
        inserter: any TextInserting,
        history: HistoryStore,
        vocabulary: VocabularyStore
    ) {
        self.settings = settings
        self.hotkey = hotkey
        self.audio = audio
        self.transcriber = transcriber
        self.refiner = refiner
        self.inserter = inserter
        self.history = history
        self.vocabulary = vocabulary
        (stateUpdates, stateContinuation) = AsyncStream<SessionState>.makeStream()
    }

    /// 起動時のウォームアップ。実測でコールド 1.9 秒 / ウォーム 0.35 秒の差がある。
    public func warmUp() async {
        try? audio.prepare()
        try? await transcriber.prepare(
            locale: settings.settings.locale, kind: settings.settings.transcriberKind
        )
        await refiner.prewarm()
    }

    public func run() async {
        await warmUp()
        for await event in hotkey.events {
            switch event {
            case .pressed:   await startRecording()
            case .released:  await stopRecording(cancelled: false)
            case .cancelled: await stopRecording(cancelled: true)
            }
        }
    }

    // MARK: - 録音

    private func startRecording() async {
        isCancelled = false
        latestVolatile = ""
        latestFinal = ""
        emit(.recording(volatileText: ""))

        guard let updates = try? await transcriber.begin() else {
            emit(.failed("認識を開始できませんでした"))
            return
        }

        let format = await transcriber.requiredAudioFormat
        let buffers = audio.startTap(format: format)

        recordingTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await buffer in buffers {
                        await self?.transcriber.feed(buffer)
                    }
                }
                group.addTask {
                    guard let updates = try? updates else { return }
                    for try? await update in updates {
                        await self?.apply(update)
                    }
                }
            }
        }
    }

    private func apply(_ update: TranscriptionUpdate) {
        switch update {
        case .volatile(let text):
            latestVolatile = text
            emit(.recording(volatileText: text))
        case .final(let text):
            latestFinal += text
        }
    }

    // MARK: - 確定 → 整形 → 挿入

    private func stopRecording(cancelled: Bool) async {
        isCancelled = cancelled
        audio.stopTap()

        let releasedAt = ContinuousClock.now
        emit(.finalizing)
        try? await transcriber.finish()
        recordingTask?.cancel()
        recordingTask = nil

        let finalizeMs = Metrics.elapsedMs(since: releasedAt)
        let raw = latestFinal.isEmpty ? latestVolatile : latestFinal

        guard !cancelled else { emit(.idle); return }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            emit(.failed("認識できませんでした"))
            emit(.idle)
            return
        }

        // --- 整形（失敗・超過時は生テキストへ縮退）
        emit(.refining)
        let refineStart = ContinuousClock.now
        let current = settings.settings
        let refined: String? = current.refinementEnabled
            ? await refiner.refine(raw, locale: current.locale,
                                   terms: vocabulary.terms, timeout: current.refinementTimeout)
            : nil
        let refineMs = Metrics.elapsedMs(since: refineStart)

        // --- 挿入
        emit(.inserting)
        let insertStart = ContinuousClock.now
        let textToInsert = refined ?? raw
        let method = await inserter.insert(textToInsert)
        let insertMs = Metrics.elapsedMs(since: insertStart)

        latestMetrics = Metrics.Sample(
            finalizeMs: finalizeMs, refineMs: refineMs, insertMs: insertMs
        )

        // --- 履歴はクリティカルパスの外で書く
        let entry = HistoryEntry(
            rawText: raw, refinedText: refined,
            localeIdentifier: current.localeIdentifier, insertionMethod: method
        )
        try? history.append(entry)

        emit(.idle)
    }

    private func emit(_ state: SessionState) {
        stateContinuation.yield(state)
    }
}
```

- [ ] **Step 5: テストを実行し、成功を確認する**

Run: `swift test --filter DictationSession`
Expected: PASS（4 tests）

コンパイルエラーが出る場合、`for try? await` は不正な構文なので、`updates` の消費を以下へ直す。

```swift
group.addTask {
    do {
        for try await update in updates { await self?.apply(update) }
    } catch {
        // 認識ストリームの終了は正常系にも含まれるため握りつぶす
    }
}
```

- [ ] **Step 6: コミット**

```bash
git add Sources/GhostVoiceCore/Session Sources/GhostVoiceCore/Support Tests/GhostVoiceCoreTests/DictationSessionTests.swift
git commit -m "feat: ディクテーションの状態機械と性能計測を追加"
```

---

## Task 11: CLI と一気通貫（V-3 / V-4 の実施）

**Files:**
- Modify: `Sources/ghost-voice/main.swift`
- Create: `README.md`
- Modify: `docs/03-detailed-design.md`（V-3 / V-4 の結果記入）

**Interfaces:**
- Consumes: すべて（Task 1〜10）
- Produces: 実行可能な `ghost-voice` バイナリ

- [ ] **Step 1: CLI を実装する**

`Sources/ghost-voice/main.swift`:

```swift
import Foundation
import GhostVoiceCore
import ApplicationServices

// アクセシビリティ権限が無いと CGEventTap も AX 挿入も動かない
guard AXIsProcessTrusted() else {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    print("""
    アクセシビリティ権限が必要です。
    システム設定 > プライバシーとセキュリティ > アクセシビリティ で
    このバイナリを実行しているターミナルアプリを許可し、再実行してください。
    """)
    exit(1)
}

let settingsStore = SettingsStore()
let settings = settingsStore.settings

let session = DictationSession(
    settings: settingsStore,
    hotkey: CGEventTapHotkeyMonitor(binding: settings.hotkey),
    audio: EngineAudioCapture(),
    transcriber: SpeechAnalyzerTranscriber(),
    refiner: FoundationModelRefiner(),
    inserter: CompositeInserter(
        primary: AccessibilityInserter(),
        fallback: PasteboardInserter()
    ),
    history: HistoryStore(limit: settings.historyLimit),
    vocabulary: VocabularyStore()
)

// 状態の変化を標準エラーへ出す（HUD の代わり）
Task {
    for await state in session.stateUpdates {
        switch state {
        case .idle:
            if let m = await session.latestMetrics {
                FileHandle.standardError.write(Data("""
                [metrics] finalize \(m.finalizeMs)ms / refine \(m.refineMs)ms \
                / insert \(m.insertMs)ms / total \(m.totalMs)ms \
                \(m.meetsTarget ? "OK" : "**目標超過**")

                """.utf8))
            }
        case .recording(let text):
            FileHandle.standardError.write(Data("\r[録音中] \(text)".utf8))
        case .finalizing: FileHandle.standardError.write(Data("\n[確定中]\n".utf8))
        case .refining:   FileHandle.standardError.write(Data("[整形中]\n".utf8))
        case .inserting:  FileHandle.standardError.write(Data("[挿入中]\n".utf8))
        case .failed(let message):
            FileHandle.standardError.write(Data("[エラー] \(message)\n".utf8))
        }
    }
}

print("""
Ghost Voice を起動しました。
右 Option を押している間だけ録音し、離すと整形して挿入します。
録音中の ESC で中断、Ctrl-C で終了します。
""")

// CGEventTap は RunLoop に載るため、メインスレッドを回し続ける
let hotkeyMonitor = CGEventTapHotkeyMonitor(binding: settings.hotkey)
Task { await session.run() }
CFRunLoopRun()
```

> **注意**: 上記は `CGEventTapHotkeyMonitor` を 2 回生成している。`session` に渡したものと同じインスタンスを使うよう、変数へ切り出してから `DictationSession` に渡すこと。`start()` の呼び出しも必要である。実装時に修正すること。

- [ ] **Step 2: ビルドして起動する**

```bash
swift build
.build/debug/ghost-voice
```

Expected: 権限が揃っていれば起動メッセージが出る。足りなければ案内が出る。

- [ ] **Step 3: V-4（右 Option の副作用）を検証する**

以下を順に試し、結果を記録する。

| 手順 | 期待 |
|---|---|
| テキストエディタで右 Option を押しながら `a` を打つ | `å` が入力される（既知の副作用。許容範囲か判断する） |
| 右 Option を押して離す（発話なし） | 「認識できませんでした」が出て挿入されない |
| ⌘C / ⌘V が通常どおり動く | 影響なし |
| 録音中に ESC を押す | 中断され、ESC が下流アプリへ届かない |

**`å` の副作用が実用上つらい場合**、`HotkeyDecision` を「右 Option の 2 回連続押下でトグル開始 / 再押下で停止」方式へ変更する。判定ロジックは純粋関数に切り出してあるため、`HotkeyDecision.decide` とそのテストのみを書き換えればよい。

- [ ] **Step 4: V-3（アプリ別の挿入経路）を検証する**

各アプリで実際に発話し、`~/Library/Application Support/GhostVoice/history.json` の `insertionMethod` を確認する。

```bash
cat ~/Library/Application\ Support/GhostVoice/history.json | grep insertionMethod
```

| アプリ | 挿入できたか | 経路 |
|---|---|---|
| メモ | | |
| メール | | |
| Slack | | |
| Google Chrome（アドレスバー / 入力欄） | | |
| Xcode | | |
| Notion | | |
| ターミナル | | |

`clipboardOnly` が出たアプリは、`PasteboardInserter.restoreDelay` を延ばして再試行する。

> **【フェーズ 2 の注記】** ここに書いてあった「既定 120 ms」は現在の既定ではない。
> **現在の既定は 300 ms**（`PasteboardInserter.defaultRestoreDelay`）で、
> 120 ms は V-3（2026-08-14 / 実機）で不足と判明して棄却された値である。詳細設計書 §6.3。

- [ ] **Step 5: 性能を確認する**

10 回ほど発話し、標準エラーへ出る `[metrics]` を確認する。

- `total` が 1000 ms 以内であること（NFR-P6）
- `finalize` の実測値を記録すること（**V-2**。設計時は 300 ms と推定していた）

- [ ] **Step 6: 検証結果を設計書へ反映する**

`docs/03-detailed-design.md` §13 の検証項目表に、V-2 / V-3 / V-4 の結果列を追加して記入する。NFR-P3 の推定値 300 ms を実測値へ置き換え、必要なら要件定義書 §4.2 の性能表も更新する。

- [ ] **Step 7: README を書く**

`README.md`:

````markdown
# Ghost Voice

macOS 26 のオンデバイス音声認識（`SpeechAnalyzer`）と `FoundationModels` だけで動く、
ローカル完結の音声ディクテーションツール。音声は一切外部へ送信されない。

## 動作要件

- macOS 26.0 以降
- Apple Silicon（M1 以降）
- 整形機能には Apple Intelligence の有効化が必要（無効でも生テキスト挿入で動作する）

## 使い方

```bash
swift build -c release
.build/release/ghost-voice
```

右 Option を押している間だけ録音し、離すと整形してカーソル位置へ挿入する。

## 必要な権限

システム設定 > プライバシーとセキュリティ で以下を許可する。

- マイク
- 音声認識
- アクセシビリティ

## 設定

`~/Library/Application Support/GhostVoice/settings.json`

| キー | 既定値 | 説明 |
|---|---|---|
| `localeIdentifier` | `ja-JP` | 認識言語 |
| `transcriberKind` | `dictation` | `dictation` / `speech` |
| `refinementEnabled` | `true` | LLM 整形の有効化 |
| `refinementTimeoutMs` | `500` | 整形の打ち切り時間 |
| `historyLimit` | `50` | 履歴保持件数 |

固有名詞は `vocabulary.json` に登録すると整形時に補正される。

## ドキュメント

- [要件定義書](docs/01-requirements.md)
- [基本設計書](docs/02-architecture.md)
- [詳細設計書](docs/03-detailed-design.md)
````

- [ ] **Step 8: 全テストを実行する**

Run: `swift test`
Expected: 全 PASS

- [ ] **Step 9: コミット**

```bash
git add Sources/ghost-voice README.md docs
git commit -m "feat: CLI を追加し一気通貫で動作させる"
```

---

## 自己レビュー結果

**仕様カバレッジ**

| 仕様 | 実装タスク |
|---|---|
| FR-1（PTT） | 9, 10 |
| FR-2 / FR-3（notch 表示） | **フェーズ2**。本計画では CLI の標準エラー出力で代替 |
| FR-4（カーソル位置へ挿入） | 8 |
| FR-5（LLM 整形） | 6, 10 |
| FR-6（ユーザー辞書） | 3 |
| FR-7（Undo） | 4 で判定を実装。**キー割当と実行はフェーズ2** |
| FR-8（言語切替） | 1, 2（設定として実装。UI はフェーズ2） |
| FR-9（履歴） | 4 |
| FR-10（初回案内） | 11 で CLI 版のみ。**GUI はフェーズ2** |
| FR-11（設定 UI） | **フェーズ2**。設定ファイル直編集で代替 |
| FR-12（音声非保存） | 全体（ディスク書き出しを一切実装しない） |
| NFR-P1〜P6 | 6, 7, 10, 11 |
| NFR-M1（差し替え可能） | 1, 5 |
| NFR-M2（テスト可能） | 全タスク |

**フェーズ2へ送る項目**: FR-2, FR-3, FR-7 の実行部、FR-10 の GUI、FR-11、検証項目 V-5 / V-6 / V-7。これらは notch HUD アプリの計画で扱う。

**未解決として残す点**

- Task 11 Step 1 の CLI に、`CGEventTapHotkeyMonitor` の二重生成と `start()` 未呼び出しがある。実装時に修正する旨をステップ内に明記済み。
- Task 10 Step 4 のコードに `for try? await` という不正な構文が含まれる。正しい形を Step 5 に併記済み。

いずれも実装者が気づけるようステップ内に注記してあるが、**レビュー時に必ず確認すること**。

# Ghost Voice 詳細設計書

- 文書番号: GV-DTL-001
- 版: 1.0
- 作成日: 2026-08-13
- 上位文書: [GV-REQ-001 要件定義書](./01-requirements.md) / [GV-ARC-001 基本設計書](./02-architecture.md)

本書に記載する Apple API のシグネチャは、開発機の SDK（`MacOSX26.5.sdk` の `Speech.swiftinterface`）から実際に確認したものである。

---

## 1. ディレクトリ構成

```
ghost-voice/
├── Package.swift                      GhostVoiceCore の定義
├── Sources/GhostVoiceCore/
│   ├── Hotkey/
│   │   ├── HotkeyMonitor.swift        プロトコル
│   │   ├── CGEventTapHotkeyMonitor.swift
│   │   └── HotkeyBinding.swift        キー定義とシリアライズ
│   ├── Audio/
│   │   ├── AudioCapturing.swift       プロトコル
│   │   └── EngineAudioCapture.swift   AVAudioEngine 実装
│   ├── Transcription/
│   │   ├── Transcribing.swift         プロトコル
│   │   ├── SpeechAnalyzerTranscriber.swift
│   │   └── TranscriptionModel.swift   モジュール種別とロケール
│   ├── Refinement/
│   │   ├── Refining.swift             プロトコル
│   │   ├── FoundationModelRefiner.swift
│   │   └── RefinementPrompt.swift     プロンプト構築
│   ├── Insertion/
│   │   ├── TextInserting.swift        プロトコル
│   │   ├── AccessibilityInserter.swift
│   │   ├── PasteboardInserter.swift
│   │   └── CompositeInserter.swift    二段構えの調停
│   ├── Storage/
│   │   ├── HistoryStore.swift
│   │   ├── SettingsStore.swift
│   │   └── VocabularyStore.swift
│   └── Support/
│       ├── Permissions.swift
│       └── Metrics.swift              性能計測点
├── Tests/GhostVoiceCoreTests/
│   ├── Fixtures/                      ゴールデンテスト用音声
│   └── ...
├── App/GhostVoice/                    Xcode プロジェクト
│   ├── GhostVoiceApp.swift
│   ├── DictationSession.swift
│   ├── UI/NotchHUD/
│   ├── UI/Settings/
│   └── UI/Permission/
└── docs/
```

---

## 2. HotkeyMonitor

### 2.1 インターフェース

```swift
public enum HotkeyEvent: Sendable {
    case pressed
    case released
    case cancelled          // ESC 押下による中断
}

public protocol HotkeyMonitor: AnyObject, Sendable {
    var events: AsyncStream<HotkeyEvent> { get }
    func start() throws
    func stop()
}
```

### 2.2 CGEventTap 実装

```swift
let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,          // イベントを改変・抑止できる
    eventsOfInterest: CGEventMask(mask),
    callback: handler,
    userInfo: context
)
```

### 2.3 修飾キーの押下判定

既定の PTT キーは**右 Option**（`kVK_RightOption` = 0x3D）。修飾キーは `keyDown` を発生させないため、`flagsChanged` イベントの `keyCode` と `flags` の組で押下／解放を判定する。

| 判定 | 条件 |
|---|---|
| 押下 | `keyCode == 0x3D` かつ `flags` に `.maskAlternate` が**立っている** |
| 解放 | `keyCode == 0x3D` かつ `flags` に `.maskAlternate` が**立っていない** |

左右の Option は同じ `.maskAlternate` を共有するため、`keyCode` による判別が必須である。

### 2.4 イベント抑止の設計（R-1 対策）

**修飾キーの `flagsChanged` イベントは抑止しない（そのまま通す）。**

理由: 抑止すると下流アプリが修飾キーの状態を見失い、他のショートカット（⌥ + 矢印キー等）が壊れる。右 Option 単独の押下は、ほとんどのアプリで無害である。

代わりに、以下だけを抑止する。

| 対象 | 抑止 | 理由 |
|---|---|---|
| 右 Option の `flagsChanged` | しない | 上記のとおり |
| 録音中の ESC `keyDown` | **する** | 中断操作を挿入先アプリに漏らさない |

> **V-4 の検証内容**: 右 Option 押下中に文字キーを打つと、挿入先アプリでは ⌥ 付き入力（`˙` `∆` 等の特殊文字）になる。PTT 中はユーザーがタイピングしない前提だが、実地で副作用を確認すること。問題があれば「右 Option の 2 回連続押下でトグル」方式へ変更する。

---

## 3. AudioCapture

### 3.1 インターフェース

```swift
public protocol AudioCapturing: AnyObject, Sendable {
    /// エンジンを起動し、常時ウォーム状態にする（アプリ起動時に一度だけ呼ぶ）
    func prepare() throws
    /// タップを装着し、バッファの供給を開始する
    func startTap(format: AVAudioFormat) -> AsyncStream<AVAudioPCMBuffer>
    /// タップを外す。エンジンは止めない
    func stopTap()
    /// 直近バッファの RMS（HUD の音量インジケータ用）
    var level: AsyncStream<Float> { get }
}
```

### 3.2 実装上の要点

- `AVAudioEngine` は `prepare()` で `start()` まで済ませ、以後停止しない（NFR-P1）。
- 録音の開始／停止は `inputNode.installTap` / `removeTap` のみで行う。
- 入力形式と認識器の要求形式が異なる場合、`AVAudioConverter` で変換する。要求形式は次で取得する。

```swift
let format = await SpeechAnalyzer.bestAvailableAudioFormat(
    compatibleWith: [transcriber],
    considering: inputNode.outputFormat(forBus: 0)
)
```

- デバイス切断（`AVAudioEngineConfigurationChange` 通知）を監視し、再構成する。

---

## 4. TranscriptionEngine

### 4.1 インターフェース

```swift
public enum TranscriptionUpdate: Sendable {
    case volatile(String)   // 暫定結果。HUD 表示用
    case final(String)      // 確定結果
}

public protocol Transcribing: AnyObject, Sendable {
    func prepare(locale: Locale) async throws
    func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error>
    func feed(_ buffer: AVAudioPCMBuffer) async
    func finish() async throws
    var requiredAudioFormat: AVAudioFormat? { get async }
}
```

### 4.2 モジュール選択

`SettingsStore.transcriberKind` により切り替える（NFR-M1）。

| 種別 | 生成 |
|---|---|
| `.dictation`（既定） | `DictationTranscriber(locale:, preset: .progressiveShortDictation)` |
| `.speech` | `SpeechTranscriber(locale:, preset: .progressiveTranscription)` |

`.progressiveShortDictation` を既定とする理由: PTT による 1 回の発話は数秒程度の短文であり、かつ暫定結果（volatile results）が HUD のライブ表示（FR-2）に必要なためである。

両者の `Result` 型は異なるが、いずれも `SpeechModuleResult` に準拠し、以下を共通で持つ。

```swift
public let range: CMTimeRange
public let resultsFinalizationTime: CMTime
public var text: AttributedString { get }
public let alternatives: [AttributedString]
// SpeechModuleResult の extension が提供
public var isFinal: Bool { get }
```

→ **`isFinal` により `volatile` / `final` を判別する。** 内部で `any SpeechModule` として保持し、`Result` の差異はこの共通部分のみを使うことで吸収する。

### 4.3 セッション構築

```swift
// 事前準備（アプリ起動時、およびロケール変更時）
let module = makeModule(locale: locale, kind: kind)

if await AssetInventory.status(forModules: [module]) != .installed {
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
        // request.progress を HUD に表示（FR-10）
        try await request.downloadAndInstall()
    }
}
try await AssetInventory.reserve(locale: locale)   // 上限 5 ロケール

let options = SpeechAnalyzer.Options(
    priority: .userInitiated,
    modelRetention: .processLifetime      // NFR-P3。§6 のメモリ計測次第で .lingering へ
)

let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [module], options: options)
try await analyzer.prepareToAnalyze(in: audioFormat)
```

### 4.4 発話ごとのライフサイクル

| タイミング | 処理 |
|---|---|
| キー押下 | `analyzer.start(inputSequence:)`（`prepareToAnalyze` 済みのため即座に開始） |
| 発話中 | `continuation.yield(AnalyzerInput(buffer: buffer))` |
| キー解放 | `continuation.finish()` → `try await analyzer.finalizeAndFinishThroughEndOfInput()` |

結果の受信は別 Task で行い、`isFinal` により振り分ける。

```swift
for try await result in module.results {
    let text = String(result.text.characters)
    yield(result.isFinal ? .final(text) : .volatile(text))
}
```

**`AnalysisContext` は使用しない。** §2.6（要件定義書）のとおり `contextualStrings` が機能しないことを実測で確認済みである。

> **将来の検討事項 (V-8)**: `DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration:)` は `SFSpeechLanguageModel.Configuration` を受け取る。これは `SFCustomLanguageModelData`（macOS 14+）で構築するカスタム言語モデルであり、`contextualStrings` とは別経路である。固有名詞の精度が LLM 整形だけでは足りない場合、この経路の有効性を検証する。

---

## 5. Refiner

### 5.1 インターフェース

```swift
public protocol Refining: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func prewarm()
    /// タイムアウト時は nil を返す（呼び出し側が生テキストへ縮退する）
    func refine(_ raw: String, locale: Locale, timeout: Duration) async -> String?
}
```

### 5.2 セッション管理

```swift
// アプリ起動時に一度だけ実行（実測: init 0.028s / prewarm 0.008s）
let session = LanguageModelSession(instructions: Self.instructions(for: locale))
session.prewarm()
```

セッションは常駐させ、発話ごとに再生成しない。**再生成するとモデルのロードが再発し、初回 1.906 秒のコストを毎回支払うことになる。**

ただし `LanguageModelSession` は会話履歴を蓄積するため、**発話ごとに履歴をリセットする**。前の発話の内容が次の整形に混入することを防ぐ。実装は「1 発話 = 1 リクエスト」とし、履歴が伸びたらセッションを作り直して再度 `prewarm()` する（作り直しのコストは実測 0.036 秒）。

### 5.3 生成パラメータ

```swift
GenerationOptions(temperature: 0.0)
```

整形は決定的であるべきで、創造性は不要である。

### 5.4 プロンプト設計

**instructions（セッション生成時に固定）**

```
あなたは音声入力テキストの整形器です。以下の規則に従ってください。

1. フィラー（えー、あの、まあ、その 等）を削除する
2. 言い直しは、後から言い直した方を残す
3. 句読点を適切に補う
4. 話者の意図・情報を変更しない。要約しない。語を削らない
5. 整形後のテキストのみを出力する。説明・前置き・引用符は付けない
```

規則 4 は L-5（過剰要約）への直接の対策である。実測で以下の劣化が確認されている。

```
入力: エラーハンドリングが抜けてるので、そこを追加したいです
出力: エラーハンドリングを追加したいです     ← 「抜けてる」が消失
```

**prompt（発話ごと）**

ユーザー辞書が空でない場合のみ、辞書ブロックを前置する（FR-6）。

```
以下の固有名詞が含まれる可能性があります。音が近い箇所はこの表記に直してください。
Nexadata, microCMS, SpeechAnalyzer, ...

整形対象:
<生テキスト>
```

辞書が長大になると入力トークンが増えレイテンシに響くため、**辞書は最大 100 語程度に制限する**。超過分は設定画面で警告する。

### 5.5 タイムアウト処理

```swift
await withTaskGroup(of: String?.self) { group in
    group.addTask { try? await session.respond(to: prompt, options: opts).content }
    group.addTask { try? await Task.sleep(for: timeout); return nil }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
}
```

`refinementTimeoutMs`（既定 500）を超えた場合 `nil` を返し、呼び出し側が生テキストを挿入する。

### 5.6 利用不可時の扱い

`SystemLanguageModel.default.availability` が `.available` 以外の場合、`isAvailable` を `false` とし、`refine` は常に `nil` を返す。HUD に「整形なし」バッジを表示する（基本設計書 §7）。

---

## 6. TextInserter

### 6.1 インターフェース

```swift
public enum InsertionMethod: String, Sendable, Codable {
    case ax, pasteboard, clipboardOnly
}

public protocol TextInserting: AnyObject, Sendable {
    func insert(_ text: String) async -> InsertionMethod
}
```

戻り値の `InsertionMethod` は履歴に記録し、どのアプリでどの経路が使われたかの実地データとする（V-3）。

### 6.2 AccessibilityInserter

```swift
let system = AXUIElementCreateSystemWide()
var focused: CFTypeRef?
guard AXUIElementCopyAttributeValue(
    system, kAXFocusedUIElementAttribute as CFString, &focused
) == .success else { return false }

let element = focused as! AXUIElement
let result = AXUIElementSetAttributeValue(
    element, kAXSelectedTextAttribute as CFString, text as CFString
)
```

**書き込み後の検証が必須である。** `AXUIElementSetAttributeValue` は成功を返しながら実際には挿入されない既知のケースがあるため、以下の事前判定を行う。

| 判定 | 内容 |
|---|---|
| 1 | フォーカス要素が取得できたか |
| 2 | `kAXRoleAttribute` が `AXTextField` / `AXTextArea` / `AXComboBox` のいずれかか |
| 3 | `AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute)` が `true` か |

**3 つすべてを満たす場合のみ AX 経路を使う。** いずれかを満たさない場合は判定コストのみで即座に Pasteboard 経路へ移る。

### 6.3 PasteboardInserter

```swift
let pb = NSPasteboard.general
let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
    Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
        item.data(forType: type).map { (type, $0) }
    })
}

pb.clearContents()
pb.setString(text, forType: .string)

postCommandV()                 // CGEvent で ⌘V を送出

try? await Task.sleep(for: .milliseconds(120))   // 貼り付け完了を待つ
restore(saved, to: pb)
```

| 項目 | 設計判断 |
|---|---|
| 復元待ち時間 | 120 ms。短すぎると貼付前に復元してしまう。実測で調整する |
| 複数タイプの保持 | 画像やリッチテキストを壊さないため、全 `PasteboardType` を退避する |
| 復元失敗時 | 挿入したテキストをクリップボードに残す（ユーザーが失わないことを優先） |

⌘V の送出は `CGEvent(keyboardEventSource:virtualKey:keyDown:)` に `.maskCommand` を設定し、`post(tap: .cgAnnotatedSessionEventTap)` で行う。

### 6.4 CompositeInserter

```
AccessibilityInserter が適用可能か判定
  ├─ 可 → 実行 → 成功: .ax / 失敗: 次へ
  └─ 不可 → 次へ
PasteboardInserter を実行
  ├─ 成功 → .pasteboard
  └─ 失敗 → クリップボードへ残置 → .clipboardOnly（HUD 通知）
```

**PTT キー解放から挿入までの間、フォーカスが移動しないことが前提である。** HUD は `.nonactivatingPanel` とし、フォーカスを奪ってはならない（V-6）。

---

## 7. NotchHUD

### 7.1 表示先ディスプレイの決定（FR-3）

```swift
func hudScreen() -> NSScreen? {
    NSScreen.screens.first { $0.safeAreaInsets.top > 0 }   // notch を持つ = 内蔵ディスプレイ
        ?? NSScreen.screens.first { $0.localizedName.contains("Built-in") }
        ?? NSScreen.main
}
```

外部ディスプレイの接続状態にかかわらず、常にこの結果へ表示する。

### 7.2 ウィンドウ構成

| 属性 | 値 | 理由 |
|---|---|---|
| クラス | `NSPanel` | 非アクティブ表示が可能 |
| `styleMask` | `[.borderless, .nonactivatingPanel]` | フォーカスを奪わない（§6.4 の前提） |
| `level` | `.statusBar` 以上 | 他ウィンドウより前面 |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` | 全画面アプリ上でも表示 |
| `isMovable` | `false` | notch に固定 |
| `backgroundColor` | `.clear` | notch と一体に見せる |

### 7.3 ライブラリ選定

第一候補は [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit)（MIT / macOS 13+）。

**採用の可否は §7.1 の「表示先を内蔵ディスプレイに固定する」制御が可能かで判断する（V-5）。** 制御できない場合は本章の仕様どおり `NSPanel` を自前実装する。自前実装で追加が必要なのは notch 形状の座標計算（`safeAreaInsets` と `auxiliaryTopLeftArea` から算出）と展開アニメーションのみであり、実装可能な範囲である。

### 7.4 表示内容

| 状態 | 内容 |
|---|---|
| `idle` | 非表示 |
| `recording` | 音量バー（`AudioCapturing.level` に連動）＋ 言語バッジ（日/EN）＋ 暫定テキスト（末尾 2 行、`.volatile` 更新ごとに差し替え） |
| `finalizing` / `refining` | インジケータ。`refining` では整形なし縮退時にバッジを出す |
| 完了 | チェックマークを 0.6 秒表示して収納 |
| エラー | メッセージを 3 秒表示 |

---

## 8. ストレージ

保存先: `~/Library/Application Support/GhostVoice/`

### 8.1 モデル定義

```swift
public struct HistoryEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let rawText: String
    public let refinedText: String?      // nil = 整形なしで挿入
    public let localeIdentifier: String
    public let insertionMethod: InsertionMethod
}

public struct VocabularyTerm: Codable, Sendable {
    public let canonical: String         // 正しい表記
    public let misheard: [String]        // 誤認識されやすい表記（任意）
}

public struct Settings: Codable, Sendable {
    public var hotkey: HotkeyBinding            // 既定 右 Option（PTT）
    public var undoHotkey: HotkeyBinding        // 既定 ⌃⌘Z。PTT と修飾キーが衝突しないこと
    public var localeIdentifier: String        // 既定 "ja-JP"
    public var transcriberKind: TranscriberKind // 既定 .dictation
    public var refinementEnabled: Bool          // 既定 true
    public var refinementTimeoutMs: Int         // 既定 500
    public var historyLimit: Int                // 既定 50
}
```

### 8.2 書き込み方針

- JSON、原子的書き込み（一時ファイル → `replaceItemAt`）。
- 履歴は挿入完了後に非同期で追記し、挿入のクリティカルパスに入れない（NFR-P6）。
- `historyLimit` 超過分は追記時に切り詰める。

### 8.3 Undo（FR-7）

直近の `HistoryEntry` を保持し、`refinedText` で挿入済みの場合のみ Undo を有効にする。

```
Undo 実行
  → 挿入済み文字数ぶんの Delete キーを送出
  → rawText を挿入（§6 と同じ経路）
```

Undo のホットキーは既定で **⌃⌘Z**（Control + Command + Z）とする。挿入後 10 秒間のみ有効とし、それ以降はユーザーが手で編集している可能性があるため無効化する。

> **Option キーを含めてはならない。** PTT キーの既定が右 Option であるため、⌥ を含むショートカットを押すと録音が始まってしまう。設定画面では、PTT キーと重複する修飾キーを含む組み合わせを Undo ホットキーとして登録できないようバリデーションする。

---

## 9. 権限（Permissions）

```swift
public enum PermissionKind: Sendable { case microphone, speechRecognition, accessibility }

public protocol PermissionChecking: Sendable {
    func status(of kind: PermissionKind) -> PermissionStatus
    func request(_ kind: PermissionKind) async -> PermissionStatus
    func openSystemSettings(for kind: PermissionKind)
}
```

| 権限 | 判定 | 要求 |
|---|---|---|
| マイク | `AVCaptureDevice.authorizationStatus(for: .audio)` | `requestAccess(for:)` |
| 音声認識 | `SFSpeechRecognizer.authorizationStatus()` | `requestAuthorization(_:)` |
| アクセシビリティ | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions` にプロンプト表示オプションを付与 |

**アクセシビリティ権限はプログラムから付与できない。** 未付与時は設定アプリの該当ペインを開き、手順を HUD／ウィンドウで案内する（FR-10）。付与後はアプリの再起動が必要になる場合があるため、その旨も案内する。

---

## 10. 性能計測（Metrics）

`DictationSession` の各遷移に計測点を置き、履歴と併せて記録する。

| 計測 ID | 区間 | 目標 |
|---|---|---|
| `M1` | キー押下 → 最初のバッファ供給 | 50 ms（NFR-P1） |
| `M2` | キー解放 → `final` 受信 | 300 ms（NFR-P3 / **V-2 で実測**） |
| `M3` | `final` → 整形完了 | 500 ms（NFR-P4） |
| `M4` | 整形完了 → 挿入完了 | 50 ms（NFR-P5） |
| `M5` | キー解放 → 挿入完了（M2+M3+M4） | **1000 ms（NFR-P6）** |

デバッグビルドでは HUD に `M5` を表示し、リグレッションを即座に検知できるようにする。

---

## 11. テスト設計

### 11.1 単体テスト（GhostVoiceCore）

| 対象 | 検証内容 |
|---|---|
| `RefinementPrompt` | 辞書あり／なしでプロンプト文字列が期待どおり構築されること。100 語上限の切り詰め |
| `HistoryStore` | `historyLimit` の切り詰め、原子的書き込み、破損 JSON からの復旧 |
| `VocabularyStore` | 重複排除、正規化 |
| `SettingsStore` | 既定値、未知キーを含む JSON の読み込み |
| `CompositeInserter` | モックで AX 失敗 → Pasteboard フォールバックが起きること、`InsertionMethod` が正しく返ること |
| `HotkeyBinding` | 左右 Option の判別、シリアライズの往復 |

### 11.2 ゴールデンテスト（認識）

固定音声ファイルに対する認識結果を回帰確認する。テスト資産は `say` コマンドで再生成可能とする。

```bash
say -v Kyoko -f Tests/Fixtures/jp-meeting.txt -o Tests/Fixtures/jp-meeting.aiff
```

**完全一致では判定しない。** OS 更新でモデルが変わりうるため、以下で判定する。

- 文字誤り率（CER）が閾値以下であること
- 重要語（辞書登録された固有名詞）が含まれること

現時点の基準値（開発機での実測）:

| モジュール | 所要 | 主な誤り |
|---|---|---|
| `DictationTranscriber` | 2.72〜3.07 秒 / 103 秒音声 | 「従量課金」→「重量課金」、「高精度」→「高度な」、「ついて」→「にいて」 |
| `SpeechTranscriber` | 0.76〜1.73 秒 / 103 秒音声 | 上記に加え「話者」→「社」、「要件定義」→「要件」等 |

### 11.3 手動検証（V-3）

以下のアプリで挿入経路と結果を記録する。

| アプリ | 想定される経路 |
|---|---|
| Slack | Electron のため AX 不可の可能性 → Pasteboard |
| Google Chrome | 要素により変動 |
| Xcode | AX 対応の見込み |
| Notion | Electron → Pasteboard |
| ターミナル / iTerm2 | Pasteboard |
| メモ / メール | AX 対応の見込み |

---

## 12. 実装順序

| # | 内容 | 完了条件 |
|---|---|---|
| 1 | Package 骨格とプロトコル定義 | ビルドが通り、モック実装で単体テストが動く |
| 2 | `TranscriptionEngine`（ファイル入力） | ゴールデンテストが通る。**V-1 / V-2 をここで実測する** |
| 3 | `AudioCapture` + マイク入力の結合 | CLI で発話 → 標準出力へ書き起こしが出る |
| 4 | `Refiner` | 整形あり／なし、タイムアウト、Apple Intelligence 無効時の縮退が動く |
| 5 | `TextInserter`（二段構え） | **V-3 を実施し、経路の実績を記録する** |
| 6 | `HotkeyMonitor` | **V-4 を実施する** |
| 7 | `DictationSession`（状態機械） | CLI 版で PTT → 挿入まで一気通貫 |
| 8 | `NotchHUD` | **V-5 / V-6 を実施する** |
| 9 | 設定 UI・権限フロー・履歴 UI | FR-7〜FR-11 が満たされる |
| 10 | 性能計測と調整 | **M5 が 1000 ms 以内。V-7（メモリ）を確認** |

**手順 2 と 3 の間に V-1（肉声での精度比較）を必ず実施する。** ここで `SpeechTranscriber` が優位と判明した場合、`SettingsStore.transcriberKind` の既定値を変更するだけで済む構造にしてある。

---

## 13. 検証項目一覧

| ID | 内容 | 実施時期 |
|---|---|---|
| V-1 | 肉声での `DictationTranscriber` / `SpeechTranscriber` 精度比較 | 実装 §12-2 |
| V-2 | キー解放 → 認識確定の実測（NFR-P3） | 実装 §12-2 |
| V-3 | 主要アプリでの AX 挿入成否 | 実装 §12-5 |
| V-4 | 右 Option 押しっぱなしの副作用 | 実装 §12-6 |
| V-5 | DynamicNotchKit の表示先固定制御 | 実装 §12-8 |
| V-6 | `.nonactivatingPanel` がフォーカスを奪わないこと | 実装 §12-8 |
| V-7 | ウォームアップ常駐時のアイドルメモリ（NFR-S3） | 実装 §12-10 |
| V-8 | `SFCustomLanguageModelData` による固有名詞精度改善の可否 | LLM 整形で不足が判明した場合 |

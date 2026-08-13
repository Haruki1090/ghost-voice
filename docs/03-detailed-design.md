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
│   │   ├── Transcribing.swift         プロトコルと TranscriptionError
│   │   ├── SpeechAnalyzerTranscriber.swift
│   │   └── TranscriptionModule.swift  2 モジュールの列挙・生成・結果変換
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
├── Tests/
│   ├── Fixtures/                      ゴールデンテスト用の原稿と音声（音声は非コミット）
│   └── GhostVoiceCoreTests/
│       ├── Support/                   CER・フィクスチャ読み込み
│       └── ...
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
public enum MicrophoneAuthorization: Sendable, Equatable {
    case notDetermined, restricted, denied, authorized
}

public enum AudioCaptureError: Error, Equatable {
    case notPrepared
    case engineUnavailable
    case microphoneAccessNotGranted(MicrophoneAuthorization)
}

public protocol AudioCapturing: AnyObject, Sendable {
    /// エンジンを起動し、常時ウォーム状態にする（アプリ起動時に一度だけ呼ぶ）
    func prepare() throws
    /// タップを装着し、バッファの供給を開始する。nil なら入力ノードの形式をそのまま流す
    func startTap(format: AVAudioFormat?) throws -> AsyncStream<AVAudioPCMBuffer>
    /// タップを外す。エンジンは止めない
    func stopTap()
    /// 直近バッファの RMS（HUD の音量インジケータ用）。**消費者は 1 つに限る**
    var level: AsyncStream<Float> { get }
}
```

`startTap` が `throws` なのは、`prepare()` を経ずに入力ノードへ触れさせないためである（§3.3）。

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
  **再構成では発話中のストリームを終了させない。** ここで `finish()` すると、
  デバイスが切り替わった瞬間に発話が丸ごと失われる。通知は CoreAudio 側のスレッドから
  届くため、処理は自前の直列キューへ逃がす（実時間スレッドでロックを取らないため）。

### 3.3 マイク権限と入力ノード（実測 / 2026-08-14）

**マイク権限が `.authorized` でないプロセスで `AVAudioEngine.inputNode` に触れると、
実測 510 秒ブロックしてから返る**（M3 / macOS 26.5.2 / バンドルされていない CLI プロセス）。
権限は付与されないまま返るため、そのまま進めても無音を録り続けることになる。

→ `prepare()` は**入力ノードへ触れる前に** `AVCaptureDevice.authorizationStatus(for: .audio)` を
確かめ、`.authorized` でなければ `microphoneAccessNotGranted` を投げる。順序を入れ替えてはならない。
権限の**要求**は `AudioCapture` の仕事ではなく `PermissionFlow`（§9）の仕事である。

**手動レンダリング（`enableManualRenderingMode`）はハードウェアを一切開かない。**
エンジン生成から停止まで権限状態は `notDetermined` のまま変化せず、ダイアログも出ない。
テストはこの経路でタップの着脱・形式変換・状態遷移を実物として検証する
（`Tests/GhostVoiceCoreTests/Support/ManualRenderingRig.swift`）。
このとき `enableManualRenderingMode` は **`inputNode` に触れる前に**呼ぶこと。順序が逆だと上記の 510 秒を踏む。

### 3.4 発話の末尾を落とさないための順序（実測）

`stopTap()` は **`removeTap` → コンバータの `drain` → `finish`** の順でなければならない。

| 事実 | 実測値 |
|---|---|
| `removeTap` は保留中の端数バッファをブロックへ一度配ってから返る | 48000 フレームを流して `removeTap` 前 43200 / 後 48000 |
| リサンプラは内部に遅延ぶんを抱え、`.endOfStream` を通知しないと返さない | 48 kHz→16 kHz で 231 フレーム（14.4 ms）、44.1 kHz→16 kHz で 111 フレーム |
| `AsyncStream` は `finish()` 後もバッファ済み要素を配る | 5 件 yield → finish → 5 件とも受信 |
| `finish()` 後の `yield` は `.terminated` を返して捨てられる | 捨てられた要素は届かない |

→ `finish()` を先に呼ぶと、上記 2 段ぶんの末尾がすべて捨てられる。

`AVAudioConverter` の出力容量は `フレーム数 × レート比 + 1` で足りる（1〜4000 フレームで超過 0 件。
ちょうど容量に達する n が存在するため **+1 は削れない**）。生成コストは中央値 0.013 ms（20 回）で、
発話ごとに作り直しても NFR-P1 の予算には影響しない。

### 3.5 タップのバッファ長は要求どおりにならない（実測）

`installTap(bufferSize:)` は**要求値であって実際の長さではない**。手動レンダリング / 48 kHz での実測:

| 要求 | 実際に届いた長さ |
|---|---|
| 1024 | 4800（100 ms） |
| 4800 | 4800 |
| 16000 | 16000 |

**4800 フレーム未満は切り上げられた。** 小さく要求しておくと系が許す限り細かく届くため、
実装は 1024 を要求している。この下限は M1（§10）の意味に直接効く。

---

## 4. TranscriptionEngine

### 4.1 インターフェース

```swift
public enum TranscriptionUpdate: Sendable, Equatable {
    case volatile(String)   // 暫定結果。HUD 表示用
    case final(String)      // 確定結果
}

public protocol Transcribing: AnyObject, Sendable {
    func prepare(locale: Locale, kind: TranscriberKind) async throws
    func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error>
    func feed(_ buffer: sending AVAudioPCMBuffer) async
    func finish() async throws
    var requiredAudioFormat: AVAudioFormat? { get async }
}

public enum TranscriptionError: Error, Equatable {
    case notPrepared
    case localeUnsupported(String)
    case modelUnavailable
    case localeReservationLimitReached
}
```

`AVAudioPCMBuffer` は `Sendable` ではない。実装をアクターにする以上、`feed` の引数は
`sending` で所有権を渡す必要がある（Swift 6 の厳格な並行性検査）。実運用では
AudioCapture がタップごとに新しいバッファを作るため、この制約は自然に満たされる。

### 4.2 モジュール選択

`SettingsStore.transcriberKind` により切り替える（NFR-M1）。

| 種別 | 生成 |
|---|---|
| `.dictation`（既定） | `DictationTranscriber(locale:, preset: .progressiveShortDictation)` |
| `.speech` | `SpeechTranscriber(locale:, preset: .progressiveTranscription)` |

`.progressiveShortDictation` を既定とする理由: PTT による 1 回の発話は数秒程度の短文であり、かつ暫定結果（volatile results）が HUD のライブ表示（FR-2）に必要なためである。

両者の `Result` 型は異なる。`text` と `alternatives` は**各々の `Result` 型が持つもので、
プロトコル `SpeechModuleResult` は公開していない。**

```swift
// SpeechModuleResult が要求するのはこの 2 つだけ
public var range: CMTimeRange { get }
public var resultsFinalizationTime: CMTime { get }
// extension が提供
public var isFinal: Bool { get }

// text / alternatives は DictationTranscriber.Result と SpeechTranscriber.Result が各々持つ
public var text: AttributedString { get }
public let alternatives: [AttributedString]
```

→ **`any SpeechModule` として保持するとテキストが取り出せない。** 2 種類を列挙型
（`TranscriptionModule`）で保持し、種別の取りこぼしをコンパイラに検出させる。
`text` / `isFinal` を要求する内部プロトコルを両 `Result` 型に後付けし、
結果列の変換だけをジェネリックにまとめる。

→ **`isFinal` により `volatile` / `final` を判別する。**

### 4.3 セッション構築

**確保（`reserve`）が資産確認（`status`）より先である。** `AssetInventory.status` は
未確保のロケールに対して、モデルが導入済みでも `.supported` を返す（実測）。
順序を逆にすると、導入済みの ja-JP に対してもダウンロードを試みることになる。

```swift
// 事前準備（アプリ起動時、およびロケール変更時）

// 1. 種別ごとの対応表で弾く。`supportedLocale(equivalentTo:)` は識別子を
//    正規化するだけで対応可否を見ないため、それ単独では判定に使えない（§4.2 の注記）
guard let locale = await TranscriptionModule.supportedLocale(equivalentTo: requested, kind: kind)
else { throw TranscriptionError.localeUnsupported(requested.identifier) }

// 2. 確保が先。逆順にすると status が `.supported` を返し、導入済みでもダウンロードへ入る
try await AssetInventory.reserve(locale: locale)   // 上限 5 ロケール

// 3. 資産の確認。`assetInstallationRequest` は非対応でも非 nil を返しうるので、
//    nil 判定を「未対応の検出」に使ってはならない（検出は 1 で済ませてある）
let module = TranscriptionModule.make(locale: locale, kind: kind)
if await AssetInventory.status(forModules: [module.speechModule]) != .installed {
    guard let request = try await AssetInventory
        .assetInstallationRequest(supporting: [module.speechModule])
    else { throw TranscriptionError.modelUnavailable }
    // request.progress を HUD に表示（FR-10）
    try await request.downloadAndInstall()
}

let options = SpeechAnalyzer.Options(
    priority: .userInitiated,
    modelRetention: .processLifetime      // NFR-P3。§6 のメモリ計測次第で .lingering へ
)
```

`AssetInventory.reserve` は `SFSpeechError` を投げる。呼び出し側が扱える型へ翻訳すること
（code 11 → `localeReservationLimitReached` / code 15 → `localeUnsupported`）。

`AssetInventory` の実測（macOS 26.5.2 / Xcode 26.6）:

| 事実 | 内容 |
|---|---|
| `status` の意味 | 未確保なら常に `.supported`。確保後に `.installed` / `.supported`（＝要ダウンロード）へ分かれる |
| `reserve` の冪等性 | 同一ロケールの 2 回目以降は `false` を返すだけで、枠を消費しない |
| 確保の寿命 | プロセス内のみ。プロセスをまたいで残らない |
| 未対応ロケール | `reserve` が `SFSpeechError` code 15 を投げる。`assetInstallationRequest` も同じく投げるため、nil 判定では捕まらない |
| 上限超過 | `SFSpeechError` code 11。→ `TranscriptionError.localeReservationLimitReached` へ翻訳する |
| `release(reservedLocale:)` | **正規形（`ja_JP`）でしか成功しない。** `ja-JP` を渡すと `false` を返して何もしない |

### 4.3.1 モジュールの寿命（重要）

**`SpeechModule` のインスタンスは、1 つの `SpeechAnalyzer` にしか装着できない。**
2 つ目の `SpeechAnalyzer` へ同じインスタンスを渡すと、
`SpeechAnalyzer.setWorkers(for:reusingFrom:preservingFunctionOf:)` の内部で異常終了する（実測）。

→ **モジュールは発話ごとに作り直す。** `prepare` が保持するのはロケール・種別・音声形式だけである。
モデル本体は `modelRetention: .processLifetime` がプロセス内に保持するため、
作り直しの費用はモジュール生成に限られる。

**その費用は `begin()` に現れる。実測 1.2〜1.4 ms**（モジュール生成 + `SpeechAnalyzer` 生成 +
`prepareToAnalyze`）。NFR-P1 の予算 50 ms に対して十分小さい。
V-2（M2）はキー解放から開く計測窓のため、`begin()` の費用は**定義上そこに含まれない**。

> **`begin()` が返る前に供給されたバッファは黙って捨てられる。** `feed(_:)` はセッションが
> 無ければ何もしない（エラーにも記録にもならない）。呼び出し側は `begin()` の完了を待って
> からタップを装着すること。待たずに流すと発話の頭が落ちる。

**`module.results` は単一消費者しか許さない。** 2 つ目の消費者を立てると
`attempt to await next() on more than one task` で異常終了する。
1 モジュールにつき結果列の消費は 1 箇所に限ること。

### 4.4 発話ごとのライフサイクル

| タイミング | 処理 |
|---|---|
| キー押下 | モジュールを生成 → `SpeechAnalyzer(inputSequence:)` → `prepareToAnalyze(in:)` |
| 発話中 | `continuation.yield(AnalyzerInput(buffer: buffer))` |
| キー解放 | `continuation.finish()` → `try await analyzer.finalizeAndFinishThroughEndOfInput()` |
| 中断（ESC） | `continuation.finish()` → `await analyzer.cancelAndFinishNow()` |

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
public protocol Refining: Sendable {
    /// LLM が使えるか。Apple Intelligence が無効な環境では false。
    var isAvailable: Bool { get }

    /// モデルを事前ロードする。起動時に一度呼ぶ（§5.2 のとおり捨て推論を通すので
    /// コールド時は数秒掛かる。投げっぱなしで呼び、発話の待ち合わせには使わない）。
    func prewarm() async

    /// 整形する。タイムアウトまたは失敗時は nil を返し、呼び出し側が生テキストへ縮退する。
    ///
    /// `timeout` は実時間の上限として守られる（§5.5）。
    func refine(
        _ raw: String, locale: Locale, terms: [VocabularyTerm], timeout: Duration
    ) async -> String?
}
```

`terms` はユーザー辞書（FR-6）。`AnyObject` 制約は付けない — 実装
（`FoundationModelRefiner`）は可変状態を持たず、テスト用の `StubRefiner` は構造体である。

### 5.2 セッション管理

**1 リクエスト = 1 セッション。セッションは持ち越さない。**

```swift
// 発話ごとに作る（実測: init 0.001〜0.002s / prewarm() 0.000s）
let session = LanguageModelSession(instructions: Self.instructions(for: locale))
session.prewarm()
```

当初は「セッションを常駐させ再利用する。再生成するとモデルのロードが再発し初回 1.906 秒を毎回払う」と設計していたが、**Task 6 の実測でこれは誤りだった。**

- **セッションを作り直してもモデルの再ロードは起きない。** 実測で `init` 0.001〜0.002 秒、
  `prewarm()` 0.000 秒、`respond` は 0.339 秒のまま。**モデルの常駐はセッションではなく
  プロセス外のデーモン側**にあり、セッションやプロセスの生存期間とは独立している
  （`prewarm()` を一度も呼ばない新規プロセスでも 1 回目の `respond` が 0.376 秒だった）
- 逆に**使い回す側に実害がある。** 会話履歴が蓄積し、同じ発話でも直前に何を喋ったかで
  整形結果が変わる（実測: 直前に「品川オフィス」の発話があると指示語「そこ」が残り、
  無ければ落ちる）。`transcript` は 1 発話あたり 2 エントリで単調増加し、
  20 発話で所要が 0.288 → 0.372 秒へ漂流した。長時間の常駐は
  `exceededContextWindowSize` に向かう

セッションを保持しなければ「1 発話 = 1 セッション」が**構造で保証される**（持ち越す入れ物が
存在しない）。`FoundationModelRefiner` は可変状態を持たない。

**`prewarm()` は捨て推論を 1 回通す必要がある。** `LanguageModelSession.prewarm()` を呼ぶだけでは
モデルのロードが完了しない。実測で `prewarm()` が 0.013 秒で返った後も 1 回目の `respond` に
3.318 秒掛かり、2 回目が 0.347 秒だった。ロードを実際に強いるのは `respond` の方である。
捨て推論に渡す発話は**フィラー付きの文にすること**（単語だけだとモデルが整形と解さず暴走する。
実測で「テスト」は 53.5 秒走った末に失敗し、「えー、テストです」は 0.309 秒で返った）。

### 5.3 生成パラメータ

```swift
GenerationOptions(temperature: 0.0)
```

整形は決定的であるべきで、創造性は不要である。

### 5.4 プロンプト設計

**instructions（セッション生成時に固定）**

```
あなたは音声入力テキストの整形器です。入力は {日本語 | English} です。
以下の規則に従ってください。

1. フィラー（えー、あの、まあ、その 等）を削除する
2. 言い直しは、後から言い直した方を残す
3. 句読点を適切に補う
4. 話者の意図・情報を変更しない。要約しない。語を削らない
5. 整形後のテキストのみを出力する。説明・前置き・引用符は付けない
```

言語名は `locale` から決める（`en` なら `English`、それ以外は `日本語`）。ja-JP の指示のまま
英語を渡すと、実測で「会議は明日の午前10時に開催されます。」と**日本語へ訳された**。

規則 4 は L-5（過剰要約）への対策として書いたが、**実測で効いていない。対策として数えないこと**
（要件定義書 §2.8 L-5 / R-3）。Task 6 で同じ劣化が再現した。

```
入力: えー、エラーハンドリングが抜けてるので、そこを追加したいです
出力: エラーハンドリングを追加します。            ← 「抜けてる」が消失
```

**過剰要約に対する実効的な安全網は Undo（FR-7）である。** 長さによる自動検出は採れない。
過剰要約は「短くなる」方向であり、フィラー除去による正常な短縮（実測で 出力/入力 = 0.53 の
例がある）と区別が付かないため、下限を設けると正常な整形を誤って捨てることになる。

**prompt（発話ごと）**

**`整形対象:` の枠は辞書の有無に関わらず必ず付ける。** 辞書ブロックだけが条件付き（FR-6）。

```
以下の固有名詞が含まれる可能性があります。音が近い箇所はこの表記に直してください。
Nexadata, microCMS, SpeechAnalyzer, ...

次の誤認識は、矢印の右の表記へ直してください。
ネクサデータ → Nexadata

整形対象:
<生テキスト>
```

辞書が空のときはこうなる。

```
整形対象:
<生テキスト>
```

**枠を落として発話を裸で渡してはならない。** 命令文に読める発話（「この関数にエラー処理を
追加したい」等）でモデルが整形ではなく**その依頼への回答**を返す。実測（新規セッション・
temperature 0・5 発話）で、裸だと 4/5 が逸脱し、枠を付けると 1/5 に下がった（L-7 / R-7）。

枠を付けても逸脱は残る。真の原因は「1 ターンのユーザーメッセージとして命令文を渡せば、
`instructions` よりその場の指示が勝つことがある」という LLM 一般の性質にあり、枠はその寄与を
減らすだけで消しはしない。**残りは出力側の検査（§5.5.1）で受け止める。**

辞書が長大になると入力トークンが増えレイテンシに響くため、**辞書は最大 100 語程度に制限する**。超過分は設定画面で警告する。

なお**辞書の写像は語によって効かない**（L-6 / R-8）。`ネクサデータ → Nexadata` は通るが
`マイクロシーエムエス → microCMS` は正規表記の綴りを 5 通り試しても 1 度も通らなかった。
改善案（写像を `instructions` 側へ移す / 命令を強める）はいずれも悪化したため採用していない。
特に**命令を強めるとフィラー除去（規則 1）が壊れる**。

### 5.5 タイムアウト処理

`refinementTimeoutMs`（既定 500）を超えた場合 `nil` を返し、呼び出し側が生テキストを挿入する。

**`timeout` は実時間の上限として守る。打ち切った生成の完了は待たない。**

```swift
let stream = AsyncStream<String?>.makeStream()

let workTask = Task {
    stream.continuation.yield(await work())
    stream.continuation.finish()
}
let timeoutTask = Task {
    try? await Task.sleep(for: timeout)
    stream.continuation.yield(nil)
    stream.continuation.finish()
}
// 待ちはしないが cancel は送る。止められる作業なら止めて計算資源を返す。
defer {
    workTask.cancel()
    timeoutTask.cancel()
}

var results = stream.stream.makeAsyncIterator()
return await results.next() ?? nil
```

当初は `withTaskGroup` で生成とスリープを競争させる形にしていたが、**採用しない。**
`withTaskGroup` はスコープを抜ける際に子タスクの完了を待つため、生成が打ち切りに応じない場合に
呼び出しの実時間が `timeout` を超え、**その間ユーザーへの文字入力が止まる。**
実測（キャンセルを尊重しない 2 秒の作業を 50ms で打ち切る）で、待つ実装 2.132 秒 対
待たない実装 0.059 秒。

現行の `FoundationModels` の `respond` は実際にはキャンセルに応じる（暴走した生成を 500ms で
打ち切っても待つ実装で 0.529 秒で返った）ので今のところ実害は出ないが、**その挙動に依存しない
形にしてある。** 上限が OS 側の応答性に左右されなくなる。

代償として、**打ち切った生成はデーモン側で走り続けうる**（`cancel()` は送るが応答は保証しない）。
挿入が止まるよりはましと判断した。打ち切りが連続する状況での電力・発熱は Task 10 で確認する。

セッションはリクエストごとに作るため、打ち切った生成が次の発話と衝突して
`concurrentRequests`（応答中の再呼び出し）になることはない。

### 5.5.1 出力の検査

タイムアウトを生き延びた出力も、そのまま挿入してよいとは限らない。`RefinementGuard` が
**整形と呼べる形をしているか**だけを検査し、通らなければ捨てて生テキストへ縮退する。

| 検査 | 根拠 |
|---|---|
| 空・空白のみでない | 整形が失敗している |
| コードフェンス（```` ``` ````）を含まない | 整形された発話に現れない。依頼を実行した結果のコード片である |
| 長さが `max(入力 × 1.5, 入力 + 16 字)` 以下 | 整形はフィラー削除・言い直しの畳み込み・句読点補完なので入力より大きく伸びない |

長さの閾値は実測から決めた。正常な整形 12 発話は 出力/入力 が最大 1.00（増分 0 字）、
逸脱は最小 2.6 倍（+39 字）で、間が完全に空いている。1.5 倍は句読点の補完と正規表記への置換
（ジーエイエス 6 字 → Google Apps Script 18 字）の余地、+16 字の下駄は「はい」→「はい。」の
ような短文で比が跳ねるぶん。

コードフェンスの検査は長さと別に要る。**入力と同程度の短いコード片**（30 字の発話に対する
40 字のコード片は比 1.33）は長さの検査を素通りする。

**タイムアウトだけでは防げない。** 逸脱の多くは生成に 1.3〜3.4 秒掛かって打ち切られるが、
実測 0.505 秒の例があり、既定の 500ms をすり抜けうる。

入力側も検査する。空白だけの認識結果はモデルへ投げない（往復ぶん挿入が遅れるだけで
得るものが無い）。

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

**マイク権限の判定は、マイクを掴む前に行うこと。** 未許可のまま `AVAudioEngine.inputNode` へ
触れると実測 510 秒ブロックする（§3.3）。判定 API 自体はハードウェアを開かないので安全である。

**アクセシビリティ権限はプログラムから付与できない。** 未付与時は設定アプリの該当ペインを開き、手順を HUD／ウィンドウで案内する（FR-10）。付与後はアプリの再起動が必要になる場合があるため、その旨も案内する。

---

## 10. 性能計測（Metrics）

`DictationSession` の各遷移に計測点を置き、履歴と併せて記録する。

| 計測 ID | 区間 | 目標 |
|---|---|---|
| `M1a` | キー押下 → **タップ武装**（取りこぼしが止まる時点） | 50 ms（NFR-P1）。うち `begin()` は**実測 1.2〜1.4 ms**。**実マイクでの実測は未実施**（V-9） |
| `M1b` | キー押下 → 最初のバッファ**到達** | **50 ms では届かない。** タップの粒度が下限（手動レンダリング実測 100 ms / §3.5）。M5 の内訳として扱う |
| `M2` | キー解放 → `final` 受信 | **実測 40〜177 ms**（中央値 約 70 ms / 13 回。V-2 実施済み。当初の推定値 300 ms を置き換えた） |
| `M3` | `final` → 整形完了 | 500 ms（NFR-P4）。**実測 中央値 0.389 秒（低負荷）／ 0.461 秒（負荷下、10 件中 1 件が 500ms 超）**。余裕は薄い（下記） |
| `M4` | 整形完了 → 挿入完了 | 50 ms（NFR-P5） |
| `M5` | キー解放 → 挿入完了（M2+M3+M4） | **1000 ms（NFR-P6）** |

### M1 を 2 つに分けた理由（Task 7 の実測）

初版は M1 を「キー押下 → 最初のバッファ供給」1 本で定義していたが、**この定義では 50 ms を満たせない。**
`installTap` のバッファ長には下限があり、48 kHz では 1024 を要求しても 4800 フレーム（100 ms）ぶきざみでしか
届かない（§3.5）。

ただし**音は失われていない。** タップ設置以降の音はすべて最初のバッファに含まれており、
遅れるのは「配達」だけである。取りこぼしが止まる時点＝タップ武装（M1a）と、
配達の遅れ（M1b）を分けて扱う。NFR-P1 が守るべきは M1a である。

**M1b はパイプライン遅延として M5 に効く。** キー解放時点で最大 100 ms ぶんの音がタップ内に
残っている可能性があるが、`removeTap` がそれを吐き出す（§3.4）ため、失われるのではなく
M2 の前に積み上がる。

### M3（整形）の計測条件と外れ値

ウォーム済み（`prewarm()` で捨て推論を通した後）の `refine()` 全体を計測。
命令文に読める発話は入れない（逸脱した生成は長文を吐いて 1.3〜3.4 秒掛かるため、
「整形に要る時間」ではなく「逸脱の発生率」を測ってしまう）。

**整形レイテンシは同時実行負荷に敏感である。** 同じテストを負荷条件だけ変えて実測した
（10 サンプル / 同一発話列 / 同一機体）:

| 条件 | 中央値 | 最大 | 500ms 超 |
|---|---|---|---|
| 整形テストのみ実行（低負荷） | 0.389 秒 | 0.413 秒 | 0/10 |
| `swift test` 全体（認識スイートが並行実行） | **0.461 秒** | **0.518 秒** | **1/10** |

```
低負荷 : [0.346, 0.357, 0.413, 0.389, 0.396, 0.395, 0.410, 0.356, 0.362, 0.351]
負荷下 : [0.518, 0.461, 0.489, 0.483, 0.459, 0.453, 0.485, 0.392, 0.384, 0.369]
```

レビュアーが独立に観測した外れ値（`[0.358, 0.368, 0.586, 0.400, 0.381]`、max 0.586 秒）も
これで説明が付く。

**既定タイムアウト 500ms の余裕は、当初報告した中央値 0.386 秒ベースの見積もりより
はっきり薄い。負荷下では中央値 0.461 秒（余裕 39 ms）で、500ms を超える発話が実際に出る。**
超えても生テキストへ縮退するので壊れはしないが、**整形が効かない発話の割合が
見積もりより高くなる。**

実運用では認識と整形は同時に走らないが、**ユーザーの他アプリが機体を使っている状況は
これに近い**。Task 10 は実機で分布（中央値ではなく上側の裾）を取り、
`refinementTimeoutMs` の既定値を引き上げるか判断すること。
NFR-P6 の 1000 ms 予算のうち M2 が実測 40〜177 ms なので、引き上げる余地はある。

テストは**中央値**を閾値判定に使っている。最大値で判定すると負荷条件で落ちる不安定な
テストになり、しかも落ちても対処のしようが無い（500ms を超えた発話は生テキストへ
縮退するのが正しい振る舞い）。代わりに分布と 500ms 超の件数を毎回出力する。

M2 の計測条件: 6 秒の日本語音声を 100 ms ごとに実時間で供給し、最後のバッファ供給から
`.final` を受け取るまで（13 回計測）。`DictationTranscriber` / `.progressiveShortDictation` /
`modelRetention: .processLifetime`（MacBook Pro M3 / macOS 26.5.2 / Xcode 26.6）。
**結果の消費は `begin()` 直後に別 Task で開始している。** `finish()` の後に消費を始めると
「`finish()` 復帰 ≦ `.final` 受信」が構造上保証され、到着時刻ではなく待ち順を測ることになる。

> **この計測は楽観側に寄っている。** 最後のバッファを供給してから 100 ms 待った時点を
> 「キー解放」としているため、解析器に 1 バッファぶんの先行処理を許している。
> 実際の PTT ではキー解放は最後のタップから 0〜1 タップ間隔のどこかで起きるため、
> **実機の値は 10〜15 ms 程度これより大きくなると見込まれる。**
> 40〜177 ms という結論を覆す規模ではないが、NFR-P3 を 200 ms とした根拠としては
> 楽観側の値である。Task 10 が実機で測った値がずれた場合、まずこの構造を疑うこと。

**`.final` は `finalizeAndFinishThroughEndOfInput()` の復帰より前に届く。**

| 計測 | キー解放 → `.final` | キー解放 → `finish()` 復帰 | 差 |
|---|---|---|---|
| 実測 7 組 | 40〜177 ms | 51〜182 ms | `.final` が 5〜48 ms 早い |

→ **後段（LLM 整形）の起動は `finish()` の復帰ではなく、ストリームの `.final` を待って始めること。**
`finish()` を待つと 5〜48 ms を無駄にする。

**M2 が想定の 1/4 で済んだぶん、M5 の予算 1000 ms はほぼ全て M3（LLM 整形）に充てられる。**

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
音声はリポジトリに含めない（`.gitignore` 済み）。原稿テキストのみコミットする。

```bash
cd Tests/Fixtures && say -v Kyoko -f jp-meeting.txt -o jp-meeting.aiff
```

> フィクスチャはテストターゲット（`Tests/GhostVoiceCoreTests/`）の**外**に置く。
> 中に置くと SwiftPM が unhandled files を警告し、解消に `Package.swift` の変更が要る。

**完全一致では判定しない。** OS 更新でモデルが変わりうるため、以下で判定する。

- 文字誤り率（CER）が閾値以下であること
- 重要語（辞書登録された固有名詞）が含まれること

CER はレーベンシュタイン距離 ÷ 参照文字数。**句読点と空白は除去して比較する。**

除去する理由は「認識器の句読点が製品の出力に効かない」ためである。本アプリの経路は
認識 → LLM 整形（句読点を補う。§5.4 の規則 3）→ 挿入であり、認識器が付けた句読点は
後段で書き換えられる。除去側の CER は **LLM が直せない誤り**を測っている。

**この正規化の選択は結論を左右する。**

| 正規化 | `DictationTranscriber` | `SpeechTranscriber` | 優位 |
|---|---|---|---|
| 句読点を除去（採用） | 3.02 % | 3.21 % | Dictation |
| 句読点を残す | 5.85 % | 4.96 % | **Speech** |

逆転の原因は読点である。原稿の読点 18 個に対し `DictationTranscriber` は 3 個しか出さず、
`SpeechTranscriber` は 10 個出す。**「Dictation は句読点を補うから正規化しないと不利」は誤りで、
実際は逆に読点を落としている。**（句点は両者とも 16 個で原稿の 17 個にほぼ一致する。）
どちらの正規化でも差は 1 ポイント未満であり、有意ではない。

#### 基準値（合成音声 `say -v Kyoko` / 103 秒 / MacBook Pro M3 / macOS 26.5.2）

| モジュール | CER | 一括変換の所要 | 誤りの数（参照 529 字） |
|---|---|---|---|
| `DictationTranscriber`（既定） | **3.02 %** | 8.9〜15.3 秒 | 11 箇所 / 距離 16 |
| `SpeechTranscriber` | **3.21 %** | 1.4〜3.1 秒 | 13 箇所 / 距離 17 |

所要は専用プロセスでの 3 回計測（下の表と要件定義書 §2.2 と同じ値）。
テストスイート内の実行は負荷が異なり、`DictationTranscriber` で 7.7〜15.5 秒、
`SpeechTranscriber` で 1.2 秒台の観測がある。**同一構成でも 2 倍のばらつきがある**
ことが、ゴールデンテストの閾値を 30 秒に取っている理由である。

両者の差は 529 字中 1 文字ぶんであり、**合成音声では実質的に互角である。**
要件定義書 §2.5 の初版が述べていた「明確に優位」は、この計測では再現しなかった（→ §13 V-1）。

**既定 `.dictation` の根拠は精度ではなく固有名詞の英字化である。** `.dictation` は
「Mac」「Apple」を英字で出し、`.speech` は「マック」「アップル」と出す。本ツールの想定利用
（Slack・エディタ・技術文書への音声入力）では、技術用語が正しい表記で出ることが実利になる。

CER は判断材料にしない（どちらの正規化でも差は 1 ポイント未満）。
**一括変換の速度も判断材料にしない。** `.speech` が 4〜6 倍速いが、速度が効くのは
録音済みファイルの一括文字起こしであり、要件定義書 §5 でスコープ外としている。
PTT で効くのは 1 発話あたりの確定レイテンシ（V-2）で、両モジュールとも体感差は生じない。

**この判断は肉声（V-1、未実施）で有意差が出れば覆る。**

質的な違いは残る。

| 観点 | `DictationTranscriber` | `SpeechTranscriber` |
|---|---|---|
| 句点（。） | 16 個（原稿 17） | 16 個（原稿 17） |
| 読点（、） | **3 個（原稿 18）。ほとんど落とす** | 10 個（原稿 18） |
| 疑問符（？） | **付与する**（「ございますか？」） | 付与しない |
| 固有名詞 | 英字へ正規化（アップル→`Apple`） | かな維持（Mac→マック） |
| 固有の誤り | 「という」→「と言う」、「セキュリティ」→「セキュリティー」 | 「話者」→「社」、「文字起こし」→「文字を起こし」、「挙げられ」→「上げられ」 |

両モジュールに共通の誤り: 「従量課金」→「重量課金」、「高精度」→「高度」、
「基本設計」→「基本設定」、「詳細設計」→「詳細設定」、「第三」→「第 3」、「一時間」→「1 時間」、
「および」→「及び」。

**誤りの過半は聞き違いではなく表記の正規化である**（漢数字→算用数字、かな→英字、かな→漢字）。
これらは LLM 整形（FR-5）とユーザー辞書（FR-6）で吸収できる余地が大きい。

**所要時間の注記**: 上表の所要は暫定結果（`volatileResults`）を有効にした値である。
HUD のライブ表示（FR-2）に暫定結果が要るため、これが製品の構成である。
**暫定結果は一括変換の所要を 2〜4 倍にする。**

| モジュール / プリセット | 所要（3 回の最小〜最大） |
|---|---|
| `DictationTranscriber` / `.progressiveShortDictation`（製品構成） | 8.9〜15.3 秒 |
| `DictationTranscriber` / `.progressiveLongDictation` | 9.6〜10.1 秒 |
| `DictationTranscriber` / `.longDictation` | 3.7〜5.4 秒 |
| `DictationTranscriber` / `.shortDictation` | 3.7〜6.2 秒（**テキストを返さない**。長尺には使えない） |
| `SpeechTranscriber` / `.progressiveTranscription` | 1.4〜3.1 秒 |
| `SpeechTranscriber` / `.transcription` | 1.0〜1.4 秒 |

要件定義書 §2.2 の初版値（`SpeechTranscriber` 0.76〜1.73 秒 / `DictationTranscriber` 2.72〜3.07 秒）は、
**暫定結果なしの構成に近いが一致はしていない。** `SpeechTranscriber` は `.transcription` の
1.0〜1.4 秒と重なるが、`DictationTranscriber` の 2.72〜3.07 秒は**どの構成でも再現しなかった**
（最も近い `.longDictation` でも最小 3.67 秒）。§2.2 は製品構成の値へ差し替え済みである。

PTT の 1 発話は数秒であり、確定までのレイテンシは V-2 のとおり中央値 約 70 ms なので、
一括変換の所要は製品の体感には効かない。

ゴールデンテストの閾値は Dictation 10 % / Speech 15 %、一括変換は 30 秒とする。
閾値は「桁で壊れたこと」を捕まえる線であり、性能目標そのものではない。

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
| 3 | `AudioCapture` + マイク入力の結合 | CLI で発話 → 標準出力へ書き起こしが出る。**ここで V-9 / V-10 を実測する**（マイク権限が要る） |
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

| ID | 内容 | 実施時期 | 結果 |
|---|---|---|---|
| V-1 | 肉声での `DictationTranscriber` / `SpeechTranscriber` 精度比較 | 実装 §12-2 | **未完（肉声）**。合成音声のみ実施し CER 3.02 % vs 3.21 %（§11.2）。既定は `.dictation` を維持。肉声の録音が要るため保留 |
| V-2 | キー解放 → 認識確定の実測（NFR-P3） | 実装 §12-2 | **完了**。40〜177 ms / 中央値 約 70 ms（推定値 300 ms を置き換え。§10） |
| V-3 | 主要アプリでの AX 挿入成否 | 実装 §12-5 | 未実施 |
| V-4 | 右 Option 押しっぱなしの副作用 | 実装 §12-6 | 未実施 |
| V-5 | DynamicNotchKit の表示先固定制御 | 実装 §12-8 | 未実施 |
| V-6 | `.nonactivatingPanel` がフォーカスを奪わないこと | 実装 §12-8 | 未実施 |
| V-7 | ウォームアップ常駐時のアイドルメモリ（NFR-S3） | 実装 §12-10 | 未実施 |
| V-8 | `SFCustomLanguageModelData` による固有名詞精度改善の可否 | LLM 整形で不足が判明した場合 | 未実施 |
| V-9 | **実マイクでの NFR-P1**（M1a のタップ武装、M1b の初回バッファ到達、タップ長の実際値） | 実装 §12-3 | **未実施。マイク権限が要る。** 手動レンダリングでは原理的に測れない（レンダリングを自分で駆動するため）。権限が `.authorized` の環境では `AudioCapture の実マイク` スイートが自動で走る |
| V-10 | デバイス切断（`AVAudioEngineConfigurationChange`）の実挙動 | 実機での確認時 | **未実施。** 合成通知での再構成は検証済みだが、実際のデバイス抜き差しでは通知の到達スレッド・`isRunning` の状態・タップの残存が異なりうる |

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
│   │   ├── HotkeyMonitor.swift        プロトコル・HotkeyEvent・HotkeyDecision（判定）
│   │   ├── HotkeyCapture.swift        フェーズ 2。**打鍵の捕獲**（`CapturedHotkey` /
│   │   │                               `HotkeyCaptureState`）。§2.6。
│   │   │                              **2 本目のタップを立てないための型**
│   │   └── CGEventTapHotkeyMonitor.swift
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
│   │   ├── CompositeInserter.swift    二段構えの調停
│   │   ├── ReplacementAnchor.swift    フェーズ 2。差し替えの錨（`ReplacementAnchor` /
│   │   │                               `AnchoredInsertion` / `InsertionEpoch`）。§8.3
│   │   └── TextReplacer.swift         フェーズ 2。差し替え（FR-5(a)）と Undo（FR-7）。§8.3
│   │                                  **危険な書き込み経路は 1 本にする**——`undo(_:)` は
│   │                                   `replace(_:with: anchor.previousText)` の包みであり、
│   │                                   向きが違うだけの操作を 2 か所に書かない
│   ├── Models/
│   │   ├── HotkeyBinding.swift        キー定義とシリアライズ。**不正な組は作れない**（§2.3）
│   │   ├── Settings.swift             設定（既定値の出所）と SettingsError
│   │   ├── HistoryEntry.swift
│   │   ├── InsertionMethod.swift      履歴に残す挿入経路（4 ケース）
│   │   ├── TranscriberKind.swift
│   │   └── VocabularyTerm.swift
│   ├── Storage/
│   │   ├── AtomicJSONFile.swift       原子的な読み書き・退避・LoadOutcome
│   │   ├── HistoryStore.swift
│   │   ├── SettingsStore.swift
│   │   └── VocabularyStore.swift
│   ├── Session/
│   │   ├── DictationSession.swift     状態機械（基本設計書 §4）
│   │   ├── SessionBroadcast.swift     単一消費者のストリームを何人へでも配り直す（§10 の欠落 1 / 3）
│   │   └── SessionMirror.swift        MainActor から同期で読める状態の写し（欠落 2）
│   └── Support/
│       ├── Metrics.swift              性能計測点
│       ├── SessionFailureNotice.swift 縮退の理由 → 媒体に依らない表示材料（§8.5）
│       │                              **Models/ は「JSON になる値」だけを置く場所なので、
│       │                               永続化しない派生型はここに置く**
│       ├── SessionNoticeAnnouncement.swift
│       │                              フェーズ 2。**通知（差し替えと Undo の顛末）→
│       │                               媒体に依らない表示材料**（§8.5）。
│       │                              **出すか出さないかも Core が決める**
│       ├── ShutdownSequence.swift     終了の待ち合わせと段取り（発話を落とさない順序）。
│       │                              **CLI と .app がここを共有する。**
│       │                               ShutdownWaitOutcome / ShutdownGate /
│       │                               ShutdownAnnouncement（文言）/ Shutdown（段取り）
│       └── PermissionInquiry.swift    権限の照会。**4 つの TCC サービスと API の
│                                       対応表はここ 1 枚だけ**（基本設計書 §10）。
│                                       PermissionStatus / PermissionProbes /
│                                       PermissionRequests
│                                      （挿入時の権限の保持は
│                                       Insertion/PasteboardInserter.swift の
│                                       PostEventAuthorization。照会の実 API 呼び出しと
│                                       キャッシュは別の関心である）
├── Sources/GhostVoiceCLI/             CLI の中身（**検査対象**）
│   ├── CommandLineOptions.swift       引数の解釈
│   ├── SessionNarration.swift         状態 → 表示行。stateUpdates の唯一の消費者
│   ├── PermissionGuidance.swift       権限の案内と --check の報告（**文言だけ。照会はしない**）
│   ├── ConsoleOutput.swift            出力先の差し替え口と、終了の文言の端末向けの体裁
│   │                                  （**文言そのものは Core の ShutdownAnnouncement**）
│   └── GhostVoiceRuntime.swift        本物の依存を繋いで回すだけ
├── Sources/ghost-voice/main.swift     GhostVoiceRuntime.main() を呼ぶだけ
├── Tests/
│   ├── Fixtures/                      ゴールデンテスト用の原稿と音声（音声は非コミット）
│   └── GhostVoiceCoreTests/
│       ├── Support/                   CER・フィクスチャ読み込み
│       └── ...
├── Sources/GhostVoiceApp/             フェーズ 2 のアプリ（**Xcode プロジェクトは作らない**）
│   ├── Main/main.swift                薄い @main。中身は Shell/ へ
│   ├── Shell/                         器（**検査対象**）
│   │   ├── GhostVoiceAppDelegate.swift 起動と終了の順序。**終了は素通ししない**（§8.10）
│   │   ├── AppSessionRuntime.swift    常駐セッションの持ち主。終了は Core の段取りを通す
│   │   ├── AppPermissions.swift       許可の**要求**と設定ペインを開くこと
│   │   │                              （**照会は Core の PermissionInquiry**）
│   │   ├── AppPermissionGuidance.swift 権限の案内（許可の相手は Ghost Voice 自身）
│   │   ├── AppLaunchOptions.swift / AppDiagnostics.swift / AppSurface.swift /
│   │   ├── LaunchSequence.swift       run() が回り始めた後にだけ画面を作る（§8.9）
│   │   └── HUD/                       notch HUD（§7）
│   │       ├── HUDScreenSnapshot.swift **NSScreen を読む唯一の場所**（§7.1）
│   │       ├── HUDPlacement.swift     どの画面のどこへ出すか（純粋な値の変換）
│   │       ├── HUDDisplay.swift       いま何を出しているか（描画の唯一の入力）
│   │       ├── HUDPresenter.swift     状態の並び → 表示。保持と間引き（§7.4）
│   │       ├── HUDWindowContract.swift window に課す約束（level 26 など。§7.2）
│   │       ├── HUDPanel.swift         **NSPanel を作る唯一の場所**（RunLoopEntry が要る）
│   │       ├── HUDContentView.swift   SwiftUI。**継続アニメーションを置かない**
│   │       └── NotchHUDSurface.swift  分配器の購読と配線。`--hud-check` の素振り
│   ├── Shell/Settings/             設定画面（FR-11。§14）
│   │   ├── SettingsViewModel.swift    状態と操作。**打鍵の捕獲もここが握る**（§2.6）
│   │   ├── SettingsView.swift         SwiftUI
│   │   ├── StoreFileNotice.swift      「読めなかった」を利用者に見せる翻訳（§14.1）
│   │   ├── HotkeyControl.swift        **監視器へ触る面**（捕獲と PTT キーの反映）
│   │   ├── SettingsSessionControl.swift `DictationSession` へ触る 2 口
│   │   ├── MisheardListText.swift     誤認識表記の並び ⇄ 1 つの入力欄
│   │   ├── BackgroundWrite.swift      **同期 I/O を呼び出し元のアクターから外す唯一の地点**
│   │   └── HotkeyLabel.swift          バインドの表示
│   ├── Shell/History/                 履歴画面（FR-9。§14.4）
│   │   ├── HistoryViewModel.swift / HistoryView.swift / HistoryTextOutput.swift
│   └── Shell/Windows/                 **提示の配線**（§14.6.1）
│       ├── AppWindow.swift            **NSWindow を作る唯一の場所**（RunLoopEntry が要る）。
│       │                              **前面の返し方も持つ**（V-43 / V-44）
│       └── StatusMenuSurface.swift    NSStatusItem のメニューと、窓の開け閉め。
│                                      `--window-check` の素振り
├── Resources/                         フェーズ 2
│   ├── Info.plist                     テンプレート（基本設計書 §10）
│   └── GhostVoice.entitlements
├── Scripts/make-app.sh                フェーズ 2。`.app` の組み立てと codesign
└── docs/
```

> **画面はすべて `Shell/` の下に置く。** `Package.swift` の `GhostVoiceApp` ターゲットは
> `path: "Sources/GhostVoiceApp/Shell"` なので、**`Sources/GhostVoiceApp/` の直下に置いたファイルは
> ターゲットに含まれず、コンパイルもテストもされない**（`Main/` は別ターゲット `GhostVoice`）。
> 当初の `UI/NotchHUD/` という置き場はこの理由で成立しない。

**フェーズ 2 のアプリも SwiftPM の実行ファイルターゲットとして作り、`.app` は `Scripts/make-app.sh` が後段で組み立てる**（基本設計書 §10）。
`main.swift` と同じ理由で、**`@main` は薄く保ち、中身は検査可能なターゲットへ置く。**
SwiftUI の `@main struct App` が `swift build` だけで通ること、`View` を含むライブラリとテストターゲットを
同居させても `swift test` が影響を受けないことは実測済みである（2026-08-14 / M3 / macOS 26.5.2 / Swift 6.3.3）。

**`main.swift` には組み立てを書かない。** 理由は 2 つある。

1. トップレベルコードは検査から呼べない。CLI の判断（文言・引数・終了の順序）が全部そこに乗ると、
   一気通貫の経路だけが無検査で残る
2. **Swift 6 のトップレベルコードは `@MainActor` 隔離である。** そこに置いた変数を
   シグナル源のスレッドから触ると落ちる（実測: 同じ処理を素の script として書くと
   SIGINT の受信時に **SIGTRAP / 終了コード 133**。`enum` の `static func` の中では起きない）

---

## 2. HotkeyMonitor

### 2.1 インターフェース

```swift
public enum HotkeyEvent: Sendable {
    case pressed
    case released
    case cancelled          // **利用者の意図**: ESC による中断（「これを挿入するな」）
    case interrupted        // **事故**: タップが無効化され、解放を取りこぼした
}

public protocol HotkeyMonitor: AnyObject, Sendable {
    var events: AsyncStream<HotkeyEvent> { get }
    func start() throws
    func stop()
    /// セッションが確定〜整形の処理中かを知らせる。**この間の ESC も中断として届ける**
    /// （ただし抑止しない。§2.4）。
    func setSessionBusy(_ busy: Bool)
}

public enum HotkeyError: Error, Equatable, Sendable {
    case eventTapNotPermitted(TapPermissionSnapshot)   // tapCreate が nil を返した
    case tapDisabledAtStart                            // 生成できたが有効化できなかった
    case alreadyRunning
    case stopped                                       // stop 済み。ストリームは復活しない
}
```

`stop()` は `AsyncStream` を終端する。**終端は取り消せないので、停止した監視器は再起動できない**（`start()` は `.stopped` を投げる）。再開したい場合は作り直す。

**ホットキー設定（`Settings.hotkey`）が変わったときは `rebind(to:)` を呼ぶ**（フェーズ 2 で追加。欠落 9 / 持ち越し項目 10）。監視するイベント種別は `start()` 時に決まる（§2.3 の `keyUp` の要否がバインドによって変わる）ので、`rebind` は**タップを張り替える。**

```swift
public protocol HotkeyMonitor {
    var currentBinding: HotkeyBinding { get }   // いま監視しているバインド
    func rebind(to binding: HotkeyBinding) throws
}
```

**作り直しではなく張り替えにしたのは、`stop()` がストリームを終端するから**である。作り直す設計では、`DictationSession` が `let` で握っている監視器を差し替える手段（＝公開 API か組み立て方の変更）が要る。同じインスタンスの中でタップだけを替えれば、その波及は起きない。

- **録音中に呼ぶと `.interrupted` が流れる。** 新しいバインドでは古いキーの解放が届かないので、出さないと録音が終わらない状態で固まる（§2.3 の「退避経路が残す穴」と同じ形）。**`.cancelled` ではない**ので、そこまでの発話は確定して挿入される（基本設計書 §7 の縮退表）。設定画面は録音していないときに呼ぶこと。上の縮退は保険である。
- 張り替えに失敗したときは `.idle` へ戻す。権限を直した利用者が `start()` でやり直せる。

`CGEventTapHotkeyMonitor` は `isActive` を持つ。**`start()` が成功しても、あとでタップが無効化されて false になりうる**（下記）。ホットキーが黙って効かなくなる唯一の経路なので、Task 10 / 11 はここを見てユーザーへ知らせること。

#### 中断（意図）と取りこぼし（事故）を同じ列挙子で運ばない

**利用者が ESC を押した**のと、**OS がタップを切った**のは、起きたことも望ましい結末も違う。

| 事象 | 利用者の意図 | セッション側の扱い |
|---|---|---|
| 録音中・処理中の ESC（`.cancelled`） | 「これを挿入するな」 | 挿入しない。履歴へ `.notInserted` で残す |
| タップ無効化（`.interrupted`） | **無い。喋っている最中に監視が死んだだけ** | **中断ではなく確定**。そこまでの発話を挿入する（基本設計書 §7） |

後者を `.cancelled` に相乗りさせていた頃は、**この場合に発話をどうするかを誰も決めておらず、
結果として「捨てる」になっていた**（フェーズ 1 の最終レビュー I-2）。最大録音時間の満了
（§2.4 の注記）とまったく同じ状況なので、扱いも同じにする。

### 2.2 CGEventTap 実装

```swift
// keyUp は修飾キー以外のバインドのときだけ含める（§2.3）
var mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
if !binding.isModifierOnly { mask |= (1 << CGEventType.keyUp.rawValue) }

let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,          // イベントを改変・抑止できる
    eventsOfInterest: CGEventMask(mask),
    callback: handler,
    userInfo: context
)
```

#### 権限の門番は `tapCreate` 自身である（Task 9 実測）

**`AXIsProcessTrusted()` を起動の門番にしてはならない。** §6.2 の取り違えと同じ形で、`kTCCServiceAccessibility` と `kTCCServiceListenEvent` は隣り合った別レコードであり、片方だけ許可された機体では事前照会と実際の可否がずれる。CoreGraphics のヘッダはこう定めている。

> If the tap is not permitted to monitor these events when the tap is created, then the appropriate bits in the mask are cleared. If that results in an empty mask, then **NULL is returned**.

つまり `tapCreate` の nil が権威ある答えである。**先に `tapCreate` を試し、nil だったときに初めて**両方の照会を行い、権限案内がどちらのペインへ導くべきかの手掛かりとして `TapPermissionSnapshot`（`listenEventAccess` / `accessibilityTrusted`）に載せる。

実測（macOS 26.5.2 / M3、`AXIsProcessTrusted() == false` かつ `CGPreflightListenEventAccess() == false` の機体）:

| 呼び出し | 結果 | 所要 |
|---|---|---|
| `tapCreate(.cgSessionEventTap, .defaultTap)` | **nil** | 約 40 ms |
| `tapCreate(.cgSessionEventTap, .listenOnly)` | **非 nil。ただし恒久的に無効** | 約 26 ms |
| `tapCreate(.cghidEventTap, .defaultTap)` | nil | 約 47 ms |
| `tapCreateForPid(自プロセス, .defaultTap)` | nil | 約 0.3 ms |
| `CGPreflightListenEventAccess()` | false | 初回 13.9 ms / 以降 p50 **10.657 ms** |
| `AXIsProcessTrusted()` | false | 初回 44.7 ms / 以降 p50 0.0005 ms |

- **`tapCreate` はブロックしない。** 権限が無くても約 40 ms で nil を返す（Task 7 の `AVAudioEngine.inputNode` は未許可のまま 510 秒ブロックした）。12 秒の期限を切って確認済み。
- **`.listenOnly` へ替えてはならない。** 権限が無くても非 nil の `CFMachPort` が返るが、そのタップは `CGEvent.tapEnable(enable: true)` を通しても無効のままで、**イベントを 1 件も配送しない。** 「start に成功したのにホットキーが効かない」という §6.3 と同じ形の沈黙した失敗になる。`.defaultTap` は ESC の抑止にも要る。念のため `start()` で `tapIsEnabled` まで確かめる。
- **どちらの TCC レコードが門番かは確定できていない。** 計測機では両方 false で一致しており、値の一致は同一性ではない（§6.2 と同じ理由）。上の設計はどちらであっても正しく動く。

#### タップの無効化からの復帰

無効化の通知は **2 種類あり、意味が違う。** `CGEvent.h` は「タップが応答しなくなった**か、無効化が要求された**とき」に通知すると定めている。

| 通知 | 意味 | 扱い |
|---|---|---|
| `kCGEventTapDisabledByTimeout` | コールバックが遅くタップが応答しなくなった | **再有効化する** |
| `kCGEventTapDisabledByUserInput` | **無効化が要求された** | **再有効化しない** |

- timeout を放置すると**ホットキーが二度と反応しない**（アプリは生きているのでユーザーからは原因が判らない）。だから張り直す。
- UserInput を張り直すのは**要求を無視して蘇ること**なので行わない。

**どちらも無制限には扱わない。** 原因不明の連続無効化に対して張り直し続けると、無効化と `.interrupted` の応酬が止まらなくなる（`events` は無制限バッファである）。`maxReEnableAttempts`（10 回）で諦める。

いずれの場合も、無効化されていた間に PTT キーの解放を取りこぼしている可能性があるため、**録音中だったなら `.interrupted` を出す**（出さないと録音が終わらない状態で固まる）。**`.cancelled` ではない**——利用者は中断を要求していないので、セッション側はこれを確定として扱う（§2.1 の表 / 基本設計書 §7）。

**諦めた場合、ホットキーは以後反応しない。** 監視器を作り直す以外に復帰の手立ては無い。`isActive` が false になるので、Task 10 / 11 はそれを見てユーザーへ知らせること。

#### `start()` と `stop()` の競合

`tapCreate` は実測で約 40 ms 掛かる。その間 `tap` はまだ nil なので、割り込んだ `stop()` は破棄すべきタップを見つけられずに終わる。**そこで `.running` へ巻き戻すと、誰にも参照されない有効なタップがランループに残り、監視器は `.running` を名乗るのにストリームは終端済み**という、`.listenOnly` と同じ形の沈黙した失敗になる。生成後にロック下で `.stopped` を再確認し、そうなっていたら生成したタップを自分で破棄して `.stopped` を投げる。失敗時の後始末も同様に、**割り込んだ `stop()` が付けた `.stopped` を `.idle` へ巻き戻さない。**

#### キー判定のコスト

`handle` は**キーイベントごとに、しかもアプリへ配送される前に**走る。ここで `CGPreflightListenEventAccess()`（p50 10.7 ms）を呼ぶと、打鍵のたびに 10 ms がシステム全体の入力に乗る。**hot path は権限照会に一切触れない**（キャッシュではなく不参照）。実測は 1 打鍵あたり p50 0.75 μs（§2.5）。

### 2.3 修飾キーの押下判定

既定の PTT キーは**右 Option**（`kVK_RightOption` = 0x3D）。修飾キーは `keyDown` を発生させないため、`flagsChanged` イベントの `keyCode` と `flags` の組で押下／解放を判定する。

**左右の Option は同じ `.maskAlternate` を共有するため、汎用マスクだけでは判定できない。** 左 Option を押したまま右 Option を離すと `.maskAlternate` は立ったままなので、汎用マスクで判定すると**解放を取りこぼして録音が終わらなくなる。** 左右は `CGEventFlags` の下位に載っている device-dependent ビット（`IOKit/hidsystem/IOLLEvent.h`）で区別する。

| 修飾キー | 左のビット | 右のビット | 汎用マスク |
|---|---|---|---|
| Option | `0x20`（`NX_DEVICELALTKEYMASK`） | `0x40`（`NX_DEVICERALTKEYMASK`） | `.maskAlternate` |
| Shift | `0x02` | `0x04` | `.maskShift` |
| Command | `0x08` | `0x10` | `.maskCommand` |
| Control | `0x01` | `0x2000` | `.maskControl` |

| 判定 | 条件 |
|---|---|
| 押下 | `keyCode == 0x3D` かつ `flags` に**右 Option のデバイスビット**が立っている |
| 解放 | `keyCode == 0x3D` かつ**右 Option のデバイスビット**が立っていない |

> **退避経路**: 汎用マスクが立っているのに左右どちらのデバイスビットも無い入力源では、従来どおり汎用マスクで押下とみなす。ここで解放と誤判定すると、そういう入力源では PTT が押した瞬間に切れて**まったく使えなくなる**（取りこぼしより重い方へ倒れる）。実キーボードがデバイスビットを立てることは V-4 で確認する。

#### 退避経路が残す穴（意図したトレードオフ）

**この退避経路は「離したのに押下と判定し続ける」経路を実際に作っている。** 正確に書く。

- **入力源が 1 つだけなら詰まらない。** 全て解放すれば汎用マスクも落ちるので、解放は必ず検出される
- **詰まるのは入力源が混在した場合である。** デバイスビットを立てる実キーボードと、汎用マスクしか立てない入力源（仮想キーボード、リマッパ、合成イベント）が同時に ⌥ を保持している状態で右 Option を離すと、`flags` は汎用マスクだけになり、**押下継続と判定されて録音が終わらない**

つまり §2.3 の修正前と同じ症状が、混在時に限って残る。**それでもこちらを選ぶ**のは、逆に倒すと「デバイスビットを報告しない入力源では PTT が押した瞬間に切れて一切使えない」という、より広い範囲の破綻になるためである。

> **この状態から抜ける手段が、監視器の側には ESC（`.cancelled`）とタップ無効化通知しか無い。** 時間による安全弁は `DictationSession` 側に置いた（`maxRecordingDuration`、既定 120 秒。基本設計書 §4）。`HotkeyMonitor` 側に置かないのは、適切な上限が録音の要件（NFR）側の値であり、監視器はキーの状態しか知らないためである。上限に達したときは**中断ではなく確定**として扱う（ユーザーは喋っていたのだから、そこまでの発話は届ける）。

#### 修飾キー単独のバインドでは追加の修飾キーを見ない

`isModifierDown` はデバイスビットが引ければ `binding.modifiers` を参照しない。したがって「⇧ + 右 Option」を設定できてしまうと、**右 Option 単独で発火する。**

**フェーズ 2 でモデル側が禁じるようにした（持ち越し項目 4）。** `HotkeyBinding` の初期化子は `throws` で、修飾キー単独のバインドには**そのキー自身の修飾キーちょうど**しか許さない（`HotkeyBinding(keyCode: 0x3D, modifiers: [.option, .shift])` は `HotkeyBindingError.modifierOnlyKeyRequiresItsOwnModifier` を投げる）。`Codable` の復元も同じ初期化子を通るので、**手編集した `settings.json` にも効く**（§12-9 / 持ち越し項目 12）。

修飾キーを空にすることも許さない。`conflicts(with:)` は修飾キー単独のバインドについて「修飾キーが重なるか」で判定するので、**空だとどの Undo キーとも衝突しなくなり、§8.3 の「Undo に ⌥ を含めない」保護が手編集 1 箇所で消える。**

#### 修飾キー以外のバインド

`Settings.hotkey` は任意の `HotkeyBinding` を取れる。**修飾キー以外を PTT に割り当てた場合、`flagsChanged` は飛んで来ない。** `keyDown` だけを監視していると解放を検出できず、**録音が永遠に終わらない。** そのため `binding.isModifierOnly` が偽のときはマスクに `keyUp` を加え、`keyDown` / `keyUp` で押下・解放を判定する（修飾キーのバインドでは `keyUp` を含めない。全打鍵の keyUp をタップに通す分だけ無駄になる）。

判定は `HotkeyDecision.decide(type:keyCode:flags:binding:isRecording:isSessionBusy:)` という純粋関数に閉じてあり、`CGEventTap` 無しでテストできる。**`isRecording`（監視器が見るキーの状態）と `isSessionBusy`（セッションの処理中）は別の量である。** 前者だけで ESC を判定していたため、正本が約束する「処理中の中断」が実機で 1 度も届いていなかった（最終レビュー I-1）。

### 2.4 イベント抑止の設計（R-1 対策）

**修飾キーの `flagsChanged` イベントは抑止しない（そのまま通す）。**

理由: 抑止すると下流アプリが修飾キーの状態を見失い、他のショートカット（⌥ + 矢印キー等）が壊れる。右 Option 単独の押下は、ほとんどのアプリで無害である。

代わりに、以下だけを抑止する。

| 対象 | 抑止 | 理由 |
|---|---|---|
| 右 Option の `flagsChanged` | しない | 上記のとおり |
| 録音中の ESC `keyDown` | **する** | 中断操作を挿入先アプリに漏らさない |
| **処理中（キー解放後）の ESC `keyDown`** | **しない** | **中断としては届けるが、抑止はしない。** 利用者はもう挿入先のアプリを操作しているので、ここで ESC を奪うと下流が壊れる（V-4 の #6）。中断が効く窓は基本設計書 §4 の 3 状態（`recording` / `finalizing` / `refining`）で、**監視器は `setSessionBusy` でその窓を知る**。**差し替えできる分岐では `refining` を通らないので窓が短くなり、代わりに保留中の差し替えの取りやめとして効く**（基本設計書 §4.1 の 14） |
| 録音中の ESC `keyUp` | しない | 抑止しても中断は漏れず、下流アプリのキー状態だけが狂う |
| PTT でも ESC でもないキー | **しない** | タップは全アプリの手前に居る。1 つでも抑止するとユーザーは文字を打てなくなる |
| **修飾キー以外の PTT の `keyDown` / `keyUp`** | **する** | 下記 |
| 修飾キーが揃っていない同じキーの打鍵 | しない | ユーザーはただ文字を打っている。抑止するとそのキーが打てなくなる |

**修飾キー以外を PTT に割り当てた場合は抑止する。** 修飾キーを抑止しない理由（下流アプリが修飾状態を見失う）は文字キーには当てはまらない。抑止しないと、たとえば**既定の Undo と同じ ⌃⌘Z**（`HotkeyBinding.controlCommandZ`）を PTT に割り当てたユーザーは、喋るたびに挿入先アプリで Undo / Redo を走らせることになる。**ユーザーが PTT として割り当てた打鍵は PTT だけのものである。**

押下を消費したなら対になる `keyUp` も消費する。押下を通したのに `keyUp` だけ消すと、下流アプリのキー状態が狂う。

> **キーリピート中に修飾キーだけ離した場合は、その時点で `.released` を出す**（キーはまだ押されている）。`⌃⌘Z` を押したまま ⌃⌘ だけ離すと、Z のキーリピートが `flags == []` の `keyDown` として届くためである。**「録音が終わらない」より「早く終わる」方を選ぶ**（§2.3 の退避経路と同じ選好）。このとき Z は抑止されず挿入先アプリへ渡る。

> **V-4 の検証内容**: 右 Option 押下中に文字キーを打つと、挿入先アプリでは ⌥ 付き入力（`˙` `∆` 等の特殊文字）になる。PTT 中はユーザーがタイピングしない前提だが、実地で副作用を確認すること。問題があれば「右 Option の 2 回連続押下でトグル」方式へ変更する。**判定は純粋関数 `HotkeyDecision` に閉じてあるので、差し替えの範囲はそこに収まる。**

### 2.5 キー判定のコスト（Task 9 実測）

`handle`（`CGEvent` からのキーコード抽出・フラグ読み取り・判定・状態遷移・抑止の返却）の 1 打鍵あたりの所要。macOS 26.5.2 / M3、5,000 回計測（1,000 回の暖機後）。

| 条件 | p50 | p99 | 最大 |
|---|---|---|---|
| 低負荷（load average 約 3.6） | 0.75 μs | 0.96 μs | 21.75 μs |
| 負荷下（`yes` 16 本、load average 約 9.7） | 0.771 μs | 1.56 μs | 46.60 μs |

CPU 負荷でほぼ動かない。**比較のため: ここで `CGPreflightListenEventAccess()` を 1 回呼ぶと 10,657 μs（p50）で、約 14,000 倍になる。**

### 2.6 打鍵の捕獲（設定画面から PTT / Undo キーを変える。FR-11）

**2 本目の `CGEventTap` は立てない**（統括の裁定）。上の実測がその理由である——判定は
1 打鍵 p50 0.75 μs で**システム全体の打鍵に乗る**ので、2 本目を立てると単純に 2 倍になり、
**設定画面を開いていない間もずっと払い続ける代償**になる。

代わりに、既存の監視器を**捕獲モード**へ入れる（`HotkeyMonitor.beginHotkeyCapture`）。

```
handle(type:event:)
  ├─ 捕獲モード？ ── はい → HotkeyCaptureState.consume(…) で決着 → 戻る
  └─ いいえ            → HotkeyDecision.decide(…)（従来どおり）
```

**捕獲モードのイベントは `HotkeyDecision.decide` を 1 度も通らない。** したがって
**捕獲中に PTT も Undo も ESC の中断も発火しない**——キーを設定しようとして録音が始まると
設定画面は使えないので、これは要件である。hot path に増えたのは **nil 比較 1 つ**だけである。

#### 何をもって「1 つの組」とみなすか

PTT の既定は修飾キー単独なので `keyDown` では捕まらない。しかし**押した瞬間に確定すると
⌃⌘Z のような組を入力できない**（⌃ を押した時点で「左 Control」で決まってしまう）。

| 入力 | いつ決まるか |
|---|---|
| 修飾キーを 1 つだけ押して離す | **離した瞬間**に「修飾キー単独」として確定 |
| 修飾キー + 文字キー | **文字キーの押下**で確定（そのとき立っている修飾キーを添える） |
| 修飾キーを 2 つ以上押して離す | **確定しない**（`HotkeyBinding` が認めない組を捕獲の側で作らせない） |
| ESC | **取り消し**（捕獲モードを閉じ、キーは変えない） |

- **抑止するのは確定させた `keyDown` と取り消しの ESC だけ。** `flagsChanged` は決して抑止しない
  （抑止すると下流アプリが修飾状態を見失う。§2.4 と同じ判断）。
- **1 打鍵で閉じる。** 決着を配ると捕獲モードは自動的に閉じる——
  **閉じ忘れで打鍵を食い続ける状態を構造で作らない。**
- **録音中に捕獲を始めると `.interrupted` を出す。** 捕獲中は PTT キーの解放が届かないので、
  出さないと録音が終わらない状態で固まる（`rebind(to:)` と同じ形の穴）。
- **ESC は捕獲では割り当てられない。** 規則としては ESC を PTT にできる（`decide` はバインドを
  ESC より先に見る）ので、`settings.json` の手編集では通る。捕獲の側で取り消しに使うのは、
  **押した瞬間に取り消せる口が他に無い**ためで、「ESC を割り当てられない」より
  「捕獲から抜けられない」ほうが害が大きい。

#### 妥当性の検査は捕獲の側に無い

捕まえた値（`CapturedHotkey`）は**まだ `HotkeyBinding` ではない。**
キーコードの範囲も修飾キー単独の表も `HotkeyBinding.init(keyCode:modifiers:)` が唯一の持ち主で、
**設定画面はそこへ通して、投げられた `HotkeyBindingError` をそのまま説明に使う**（§14.1 と同じ規律）。

#### 反映は保存のときに起きる

**`SettingsStore` へ書いただけでは監視器は古いキーを見ている**（`HotkeyMonitor.currentBinding`）。
フェーズ 1 で「設定画面で PTT キーを変えてもプロセスを再起動するまで効かなかった」のがこれである
（持ち越し項目 10）。保存の手順 6 で `rebind(to:)` / `rebindUndo(to:)` を呼ぶ（§14.2）。

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
    /// 変換に失敗して捨てたバッファの数。**インスタンス生涯の累計**
    var droppedBufferCount: Int { get }
}
```

`startTap` が `throws` なのは、`prepare()` を経ずに入力ノードへ触れさせないためである（§3.3）。

`droppedBufferCount` をプロトコルに置いてあるのは、**捨てた事実を発話ごとに残すため**である
（`DictationSession` が録音の前後で読んで差分を取り、`Metrics.Sample.droppedBuffers` に入れる）。
0 でない発話は音の一部が欠けている。累計のまま報告すると前の発話ぶんまで数える（§10）。

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

**バンドルされていない実行ファイルからは、そもそも TCC のダイアログを出せない**（実測）。
`AVCaptureDevice.requestAccess(for: .audio)` を素の CLI バイナリから呼ぶと、
**120 秒待ってもコールバックが返らず、権限は `notDetermined` のまま**である。
上記 510 秒のブロックと同じ根で、TCC に問い合わせる相手（バンドル ID と
`NSMicrophoneUsageDescription`）が無いと、待つだけでダイアログに到達しない。
検証には最小の `.app`（ad-hoc 署名）を作って `EngineAudioCapture` をリンクし、そこから計測した。
バンドル化すればダイアログは正常に出て、許可も通る（V-9 はこの方法で実施した）。

**ただし「使う」には `.app` バンドルは要らない**（実測 / 2026-08-14 / Task 11 / V-13）。
要求（ダイアログ）と使用は別の話である。**TCC の許可は実行ファイルではなく責任プロセス
（起動元のターミナルアプリ）に紐づく**ので、そのターミナルアプリが既にマイクを許可されていれば、
素の実行ファイルからも `.authorized` が返り、マイクは開く。

実測（`ghost-voice --mic-check`。`.app` バンドル無し・`Info.plist` 無し・署名無しの
`.build/debug/ghost-voice`。起動元は cmux.app）:

| 項目 | 結果 |
|---|---|
| `Bundle.main.bundleIdentifier` | nil |
| `AVCaptureDevice.authorizationStatus(for: .audio)` | **`.authorized`** |
| 1 秒のタップで届いたバッファ | **10 バッファ / 48000 フレーム（48000 Hz / 1 ch）** |
| 変換に失敗して捨てたバッファ | 0 件 |

→ **フェーズ 1 の CLI に `.app` バンドルは作らない。** 残る制約は 1 つだけである:
**起動元のターミナルアプリがマイクを許可されていない場合、そこから許可を得る手段が無い**
（ダイアログを出せないため）。その場合は許可済みの別のターミナルから起動するか、
`.app` バンドルを作る必要がある。フェーズ 2 の HUD アプリは `.app` なのでこの制約は消える。

> **代わりにフェーズ 2 では別の制約が来る。** `open` で起動した `.app` は自分自身が責任プロセスになり、
> **ターミナルアプリの許可を 1 つも引き継がない**（実測 / 2026-08-14。§9）。
> つまり「ダイアログを出せる」代わりに、**4 つの権限を Ghost Voice.app へ付け直してもらう**ことになる。

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

**4800 フレーム未満は切り上げられた。** この下限は M1（§10）の意味に直接効く。

> 初版はここに「小さく要求しておくと系が許す限り細かく届くので 1024 を指定している」と書いていたが、
> **実 HAL の掃引（下記）でこれは否定された。** 64 を指定しても 4800 になる。
> 1024 という指定に実効的な意味は無い。

**実マイクでも同じだった**（V-9）。内蔵マイクは 48000 Hz / 1 ch で、1024 を要求しても
届くのは 4800 フレーム（100.0 ms）ちょうどである。手動レンダリングでの観測がそのまま実機に当てはまる。

**実 HAL で `bufferSize` を掃引した結果、4800 は下限であって指定では下げられない**（V-9）:

| 要求 | 実際に届いた長さ | 初回到達 |
|---|---|---|
| 64 / 256 / 512 / 1024 / 2048 / 4096 / 4800 | **すべて 4800（100.0 ms）** | 105.6〜109.3 ms |
| 8192 | 8192（170.7 ms） | 170.1 ms |
| 16000 | 16000（333.3 ms） | 340.9 ms |

→ 実装は `max(要求値, 4800)` として振る舞う。**4800 未満をいくら小さく要求しても意味がない。**
1024 という指定は「将来 OS 側の下限が下がれば自動的に恩恵を受ける」以上の意味を持たない。

#### この 100 ms はハードウェアの制約ではない

同じデバイスの HAL の I/O バッファ長を直接問い合わせると **512 フレーム（10.7 ms）** である
（可変範囲 15〜4096）。**つまりハードウェアは 10.7 ms ごとに音を届けているのに、
`installTap` はそれを 4800 フレーム貯めるまで渡さない。** 100 ms の下限は
`AVAudioEngine` のタップ実装が持つものである。

`AVAudioSinkNode` を使うと **512 フレーム（10.67 ms）ごと**に受け取れることを実測で確認した
（0.5 秒で 46 回）。したがって M1b（§10）を 50 ms 以内にすることは**技術的には可能**である。

**それでも `installTap` を採用している。** 理由は §3.6。

### 3.6 なぜ `AVAudioSinkNode` ではなく `installTap` なのか

| | `installTap` | `AVAudioSinkNode` |
|---|---|---|
| 粒度（実測） | 4800 フレーム / **100.0 ms** | 512 フレーム / **10.67 ms** |
| M1b（キー押下 → 最初のバッファ） | 実測 中央値 106.5〜106.7 ms | 理論上 10.7 ms 程度 |
| バッファの受け取り | `AVAudioPCMBuffer` を OS が用意 | 実時間レンダースレッドで `AudioBufferList` を直接受ける |
| 実時間安全性 | **ブロックは実時間スレッド外**。確保は OS 側 | **実時間スレッド内**。毎秒 94 回、確保とコピーを自前で行う必要がある |
| PTT の着脱 | `installTap` / `removeTap` | 常時接続し、フラグで通す／通さないを切り替える |

**判断: `installTap` を採る。** 根拠:

1. **90 ms の短縮は M5a の予算内で吸収できる。** 差し替えできない分岐（(b)）の内訳は
   M2 45〜155 ms + M3 389〜518 ms + M4 50 ms = 484〜723 ms（M2 は V-12 の修正後の実測。§10）。
   ここに 100 ms を足しても予算 1000 ms に収まる。**差し替えできる分岐（(a)）では M3 が
   M5a に入らない**ので、余地はさらに広い（要件定義書 §2.8.6 / 基本設計書 §7.1）。
2. **実時間スレッドでの確保はグリッチの原因になる。** `AVAudioSinkNode` のブロックは
   実時間制約下にあり、そこで `malloc` を伴う確保を毎秒 94 回行うのは違反である。
   正しくやるにはロックフリーのリングバッファが要る。**取りこぼし・途切れは
   「発話を失わない」原則に対して 100 ms の遅延よりはるかに重い被害**であり、
   その risk を今この段階で取る理由がない。
3. **失われるとしても最大 1 I/O サイクル（512 フレーム ≒ 10.7 ms）で、遅れの主因は配達である**（§10 の但し書き）。

**ただし逃げ道として記録しておく。** M5a が 1000 ms を割り込むなら、
**最初に引くレバーがこれ**である。90 ms は M3 の縮退（タイムアウト短縮）より安全に取り返せる。

**現時点でこのレバーは引いていない。** Task 10 の M5（現 M5a）実測は `.clipboardOnly` 経路で
中央値 398〜411 ms / p90 419〜819 ms と予算内に収まった（§10）。ただし**⌘V を含む経路の
最悪値は計算上 1080 ms** で、そこが確定するのは V-3 である。**V-3 で 1000 ms を割り込んだら、
まずここを読むこと。**

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
    // request.progress を HUD に表示（FR-10。**HUD はフェーズ 2**）
    // フェーズ 1 の CLI は `onAssetInstallationStart` で「導入が始まった」1 行だけを出す。
    // 進捗（%）は出さない——出す先が無いため（§12-11）
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

**ただし Undo が自動で効くのは差し替え可能な経路に限る**（要件定義書 FR-7 の細目 / §8.3）。
それ以外の経路では「生テキストをクリップボードへ取り出す」に縮退し、貼り直すのは利用者である。
**なお差し替えできる経路では、整形が反映されるより前に利用者がテキストを見ている**ので、
過剰要約に気付く機会そのものは増える。

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

`refinementTimeoutMs`（既定 750。§10 で決めた）を超えた場合 `nil` を返し、呼び出し側が生テキストを挿入する。

> **打ち切り値は分岐で違う（要件定義書 §2.8.6）。** `refine(_:locale:terms:timeout:)` の
> `timeout` に何を渡すかは**呼び出し側が決める。**
>
> - **差し替えできない分岐（(b)）**: `refinementTimeoutMs`（既定 750 ms）。**生テキストの挿入がこの待ちの後ろにあるので、NFR-P6a の予算から逆算した値である。**
> - **差し替えできる分岐（(a)）**: NFR-P6b の打ち切り（**推定値 3 秒。V-25 / V-29 で置き換える**）。**生テキストは既に挿入済みなので、超えても失うのは整形だけである。**
>
> **`Refining` の実装（`FoundationModelRefiner`）は分岐を知らない。** 知っているのは
> `DictationSession` だけであり、整形器は渡された上限を守るだけでよい。

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
| **入力に無い語の追加が 3 字以下** | **整形は消す操作と句読点を足す操作しかしない。語を足したらそれは整形ではない**（下記） |

長さの閾値は実測から決めた。正常な整形 12 発話は 出力/入力 が最大 1.00（増分 0 字）、
逸脱は最小 2.6 倍（+39 字）で、間が完全に空いている。1.5 倍は句読点の補完と正規表記への置換
（ジーエイエス 6 字 → Google Apps Script 18 字）の余地、+16 字の下駄は「はい」→「はい。」の
ような短文で比が跳ねるぶん。

コードフェンスの検査は長さと別に要る。**入力と同程度の短いコード片**（30 字の発話に対する
40 字のコード片は比 1.33）は長さの検査を素通りする。

**タイムアウトだけでは防げない。** 逸脱の多くは生成に 1.3〜3.4 秒掛かって打ち切られるが、
実測 0.505 秒の例があり、既定の打ち切り（750 ms）をすり抜けうる。
**逸脱を止めるのはタイムアウトではなくこの検査である**（打ち切りを 500 → 750 ms へ
引き上げた際も、防御の担い手がここである以上、逸脱への耐性は実質変わらない。§10）。

入力側も検査する。空白だけの認識結果はモデルへ投げない（往復ぶん挿入が遅れるだけで
得るものが無い）。

#### 「入力に無い語の追加」で測る（V-37 / 2026-08-15 に指標を作り直した）

**フェーズ 1 の指標（残存率）は誤っていた。** 共通部分列を**短い方**の長さで割る形は
`max(入力の残存率, 出力の由来率)` に等しく、**2 方向の甘い方**を採る。
結果、**入力が丸ごと残っていれば追加は何字あっても 1.000** になった——
**追加に対して原理的に盲目**である。

実機で実際に起きていたこと（`say -v Kyoko` のフィクスチャ 6 秒スライスを認識させた生テキスト）:

```
raw    : 本日は…まず前回のミーティングの振替                    （36 字）
refined: 本日は…まず前回のミーティングの振替についてお話しします。（47 字）
```

**「についてお話しします」は誰も言っていない。** 旧指標は 1.000 を返し、長さの検査も通り、
**利用者の欄へ入っていた。** §10 の「判ったこと 3」で捨てられた 10 秒スライス（56 字 → 96 字）が
捨てられたのは指標が捕まえたからではなく、**長さの上限に偶然引っ掛かった**だけである。

**発話長への依存は当初の疑いと逆向きだった。** 旧指標は長い発話ほど**上がる**
（19 字 0.933 → 124 字 0.991。フィラーが長文では相対的に小さくなる）。
**5〜124 字の 9 例すべてで正当な整形は受け入れられていた。**

**残存率の向きは閾値で分けられない**（だから判定に使わない）:

| 操作 | 例 | 残存率 |
|---|---|---|
| フィラー削除（短文） | `えー、はい` → `はい。` | **0.400** |
| **逸脱（回答）** | `東京の天気どんな感じですか？` → `東京の天気は晴れています。` | **0.429** |

フィラー削除は「消す」操作で、短い発話ほど消える割合が大きい。
**分かれるのは消した量ではなく足した量である。**

現在の指標は **`unsupportedAdditions`**——
出力のうち、**入力にも句読点にも由来しない文字の数**（共通部分列を取り、句読点と空白は
両側から除いてから数える）。実測（2026-08-15 / MacBook Pro M3 / macOS 26.5.2 / temperature 0 / 各 3 回同一）:

| 種別 | 例 | 追加字数 |
|---|---|---|
| フィラー削除・句読点補完（5〜124 字の 11 例） | `えーっと、あの、来週までに…` → `来週までに…。` | **0** |
| 数量表記の正規化 | `…は十時から…` → `…は10時から…。` | **2** |
| **逸脱: 質問への回答** | `東京の天気どんな感じですか？` → `東京の天気は晴れています。` | **6** |
| **逸脱: 無関係な応答** | `おはようございます` → `承知しました。` | **5** |
| **逸脱: 続きの捏造** | `…前回は新しい` → `…新しいプロジェクトの進捗を確認し、…強化しました。` | **38** |

**正当な整形の最大は 2、逸脱の最小は 5。境界は 3 に置いてある。**

**句読点を勘定に入れないのが要点である。** 整形の仕事の一つが句読点の補完なので、
入れると**節の多い長い発話ほど落ちる**指標になり、V-37 が疑った長さ依存を直した側で作り込む
（実測: 句読点の少ない 49 字の発話で読点 2 + 句点 1 を足す）。**この量は発話長に依存しない。**

**用語の正規化（FR-6）を逸脱と分ける工夫は残してある。**
`ジーエイエスを使いました` → `Google Apps Script を使いました。` は素で測ると **16 字の追加**で、
逸脱の最小 5 字を大きく超える。だから**先に頼んだ置換を入力へ当ててから**測る
（`applyingVocabulary`）。当てた後は追加 0 字になる。**辞書を渡さなければ同じ出力が落ちる。**

#### 発話長そのものは原因ではなかった（対照実験 / 2026-08-15）

A4 が捨てられた 56 字と**同じ長さ帯の「言い終えた」発話**を、
`say -v Kyoko` で合成 → 実認識 → 実整形 → 実差し替えまで通した（挿入先は代役の欄）:

```
raw(53 字): エレ、本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。
refined  : 本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。
顛末     : refinementApplied（3/3）
```

**同じ長さ帯でも、文として終わっていれば整形は反映される。**
A4 の 0/10 は発話長ではなく、**音声を 10 秒で切って文の途中にしたこと**による。

#### 残る限界（実測に基づく。直していない）

- **文の途中で PTT を離すと、モデルは続きを捏造する。** PTT は離した瞬間に確定するので、
  **言い終える前に離せば必ずこの形になる。** 検査は捏造を捨てるので**生テキストのまま残る**が、
  **整形はその発話では効かない。**
- **プロンプト側では止められない。** 規則 6「入力が文の途中で終わっていても、続きを補わない。
  入力に無い語を足さない」を足して実測したが、**出力は 1 文字も変わらなかった**（5 例 × 3 回）。
  規則 4（要約しない）が効かないのと同じ性質である（§5.4）。
- **語の途中で切れた場合の補完（`…ありがとうござい` → `…ありがとうございます。`）は通る**（追加 2 字）。
  意味の捏造ではなく語形の補完なので許容している。**境界 3 はこれを通す位置でもある。**
- **過剰要約（L-5）は依然として捕まえられない。** 短くなる方向は「消す」操作で、
  フィラー削除と区別が付かない（§5.4 / 要件定義書 R-3）。安全網は Undo（FR-7）である。

### 5.6 利用不可時の扱い

`SystemLanguageModel.default.availability` が `.available` 以外の場合、`isAvailable` を `false` とし、`refine` は常に `nil` を返す。HUD に「整形なし」バッジを表示する（基本設計書 §7）。

---

## 6. TextInserter

### 6.1 インターフェース

```swift
public enum InsertionMethod: String, Sendable, Codable {
    case ax, pasteboard, clipboardOnly
    /// 挿入していない。**ESC で中断された発話**（§4）。挿入経路を 1 つも通っていないので、
    /// 上の 3 つと並べて「どの経路で入ったか」として読んではならない。
    case notInserted
}

/// 挿入を試みた結果。
public enum InsertionOutcome: Sendable, Equatable {
    /// 挿入を試み、この経路で決着した。**履歴に記録してよい。**
    case inserted(InsertionMethod)
    /// secure input が有効だったため、どの経路も試さず拒否した。
    /// クリップボードにも残していない。**履歴に記録してはならない。**
    case refusedSecureInput

    /// 履歴に記録してよい経路。拒否のときは nil。
    var recordableMethod: InsertionMethod? { ... }
}

public protocol TextInserting: Sendable {
    func insert(_ text: String) async -> InsertionOutcome
}

/// 差し替えの錨まで返せる挿入の口。`insert(_:)` はここから導出する（§6.5）。
public protocol AnchoringTextInserting: TextInserting {
    func insertCapturingAnchor(_ text: String) async -> AnchoredInsertion
}

/// 二段構えの各段。
public protocol PrimaryInserting: Sendable {
    func canInsert() -> Bool
    /// **`Bool` ではない。** 差し替え（§6.5）には pid・範囲・要素参照が要る。
    /// 錨を返せない段は `.inserted(anchor: nil)` を返す（挿入は成功している）。
    func tryInsert(_ text: String) async -> InsertionAttempt
}

/// 最後の砦。挿入が全滅したときに発話をクリップボードへ残す。
public protocol ClipboardLeaving: Sendable {
    @discardableResult func leave(_ text: String) -> Bool
}
```

実装はいずれも値型なので `AnyObject` は要求しない（**`TextReplacer` だけは C-7 の
締め出しを保持するため参照型である**。§6.5）。

戻り値のうち **`.inserted(method)` の `method` だけ**を履歴に記録し、どのアプリでどの経路が使われたかの実地データとする（V-3）。

**`.refusedSecureInput` は履歴に記録しない。** パスワード入力中の発話だからである（§6.4）。記録側は `recordableMethod` を開いてから `HistoryEntry` を作ること。

```swift
guard let method = outcome.recordableMethod else { return }  // 拒否は記録しない
```

`InsertionMethod` にケースを足さず別の型にしてあるのは、`HistoryEntry.insertionMethod` が `InsertionMethod` を**必須**で要求するためである。同じ enum に入れると「記録してはならないもの」が型として記録可能になる。

**`ClipboardLeaving` を `PrimaryInserting` と分けてあるのには理由がある。** 両段が `canInsert()` で「適用外」を返した場合、`tryInsert` は一度も走らない。つまり Pasteboard 経路がクリップボードへ書く機会そのものが無い。残置を挿入経路の副作用として扱うと、そこで発話が消える。

### 6.2 AccessibilityInserter

```swift
let system = AXUIElementCreateSystemWide()
var focused: CFTypeRef?
guard AXUIElementCopyAttributeValue(
    system, kAXFocusedUIElementAttribute as CFString, &focused
) == .success else { return false }

// **強制キャストしてはならない**（`focused as! AXUIElement`）。
// 属性が AXUIElement 以外を返すとプロセスが落ちる。ここは発話の出口である。
guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
let element = unsafeBitCast(focused, to: AXUIElement.self)

let result = AXUIElementSetAttributeValue(
    element, kAXSelectedTextAttribute as CFString, text as CFString
)
```

`AXUIElementSetAttributeValue` は**成功を返しながら実際には挿入されない既知のケースがある**。これに対して本実装が行うのは**事前判定のみ**であり、**書き込み後の読み戻しは行わない。**

> **記述の訂正（Task 8）。** ここには当初「**書き込み後の検証が必須である**」と書いたうえで、続けて事前判定を並べていた。**書いた時点で矛盾している。** 実装は事前判定 + API のステータス判定であり、読み戻しはしていない。事実に合わせて書き直した。

**読み戻しを実装しない理由。** 書き込み後に読み戻して「入っていない」と判定したとき、それが本当に失敗なのか、アプリがテキストを変換・整形しただけなのかを区別できない。誤って失敗と判定するとフォールバックが走り、**AX で入ったテキストの上にもう一度貼り付ける。** 二重に入るのは、入らないことより悪い場合がある（ユーザーが気づかずに送信する）。投機で防御を足すより、V-3 で実アプリの挙動を測ってから設計する。

**この設計の限界（残余リスク）。** AX が `.success` を返しながら何も入らなかった場合、`.ax` が返り**フォールバックは走らず、発話は失われる。** 検出手段を持たないため、現時点では V-3 で発生の有無を確かめることしかできない。

> **差し替え（§8.3）はこの裁定の外にある。** §8.3 の事前検査・事後検査は
> **限定された範囲の読み戻し**を行うが、(1) 事前検査で「アプリによる変換が起きていない」ことを
> 確かめた直後に書く、(2) 不一致を検知しても**再試行しない**（クリップボードへ逃がすだけ）ので、
> 上の「変換と区別が付かない」「誤検知で二重挿入になる」という 2 つの理由がどちらも成り立たない。
> **主たる挿入経路（この §6.2）へ読み戻しを足してはならない。**

**AX 経路で挿入したときは、後から差し替えるための情報（差し替えハンドル）も併せて返す。**
pid・要素参照・書き込んだ範囲・書き込んだ文字列・挿入の通し番号で、**プロセス内メモリにのみ持つ**。
Pasteboard 経路と `clipboardOnly` はハンドルを作らない（範囲を持てないため）。詳細は §8.3。

| 判定 | 内容 |
|---|---|
| 1 | フォーカス要素が取得できたか |
| 2 | **要素の持ち主が自プロセスでないか**（実測で追加。下記） |
| 3 | `kAXRoleAttribute` が `AXTextField` / `AXTextArea` / `AXComboBox` のいずれかか |
| 4 | `AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute)` が `true` か |

**4 つすべてを満たす場合のみ AX 経路を使う。** いずれかを満たさない場合は判定コストのみで即座に Pasteboard 経路へ移る。判定は**安い順**に並べる。判定 2 は `AXUIElementGetPid` だけで済み AX の往復を伴わないので、3 と 4 の問い合わせより先に置く。

#### 判定 2（自プロセスの除外）を足した理由

**自プロセスの要素へ `AXUIElementSetAttributeValue` をメインスレッド以外から投げると永久にブロックする。** 実測（macOS 26.5.2 / M3。AppKit を起動したプロセスが自分の `NSTextView` を狙う）:

| 呼び出し元 | 属性 | 結果 |
|---|---|---|
| 背景スレッド | `kAXSelectedText` | 12 秒で戻らず打ち切り |
| 背景スレッド | `kAXValue` | 12 秒で戻らず打ち切り |
| 背景スレッド | 同上 + `AXUIElementSetMessagingTimeout(2.0)` | **タイムアウトが効かない。** 12 秒で戻らず打ち切り |
| メインスレッド | `kAXSelectedText` | 52.9 ms で成功 |

読み取り（役割・可書き込み性）は背景スレッドからでも 0.1〜5.5 ms で返る。**詰まるのは書き込みだけである。**

挿入は非同期文脈＝協調スレッドプールで走るため、フォーカスが自分の HUD や設定画面にある瞬間に挿入が走ると、そのタスクが二度と返らない。メッセージングのタイムアウトでは救えないので、**狙わないことで避ける。** 自分自身へディクテーションする必要はそもそも無い。

判定 2 は `canInsert()` と `tryInsert()` の両方で行う。両者はフォーカスを別々に取り直すので、その隙にフォーカスが移りうる。

#### メッセージングの上限

`AXUIElementSetMessagingTimeout` をシステムワイド要素へ 0.5 秒で設定する。既定は 6 秒で、前面のアプリが固まっていると**適用可否の判定だけで 6 秒ユーザーを待たせる**。挿入の予算は NFR-P5 の 50 ms しかない。正常な往復は実測 0.1〜5.5 ms なので 0.5 秒は十分に緩い。

#### フォーカス要素の型検査

`kAXFocusedUIElementAttribute` の値は**強制キャストしてはならない**。`AXUIElement` 以外が返った場合にプロセスが落ちる。ここは発話の出口であり、落ちれば発話は失われる。`CFGetTypeID` で確かめてから包む。

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
| 復元待ち時間 | 120 ms。短すぎると貼付前に復元してしまう。**実測済み（下記）。値は据え置き** |
| 複数タイプの保持 | 画像やリッチテキストを壊さないため、全 `PasteboardType` を退避する |
| 送出できないとき | **試さない。**`canInsert()` が送出可否を返す（下記）。**Task 8 で新設** |
| 送出に失敗したとき | **復元しない。** 挿入したテキストをクリップボードに残す。**Task 8 で新設**（下記） |
| 元が空だったとき | 復元しない。空で上書きするとテキストが消えるだけなので残す方を選ぶ。**Task 8 で新設** |

> **「送出に失敗したとき」は Task 8 で新設した判断であり、既存規定の適用ではない。** この表には当初「**復元**失敗時 → 挿入したテキストをクリップボードに残す」しか無く、それは復元処理が失敗した場合の規定である。**送出**の失敗については何も定めていなかった。
>
> 新設した判断は「**ユーザーのクリップボードを壊さない**」を捨てて「**発話を失わない**」を取るトレードオフである。送出に失敗した時点でクリップボードにはテキストが載っており、ここで元へ戻すと**貼り付いてもいない発話がどこにも残らない**。ユーザーの元の内容を失う代償を払って発話を残す。
>
> なお本番でこの分岐に入るのは `CGEvent` の**生成**に失敗した場合だけである。TCC と secure input に由来する失敗は `canInsert()` が先に弾く。後続タスクは「既存方針」としてではなく、このトレードオフを理解したうえで踏襲すること。

⌘V の送出は `CGEvent(keyboardEventSource:virtualKey:keyDown:)` に `.maskCommand` を設定し、`post(tap: .cgAnnotatedSessionEventTap)` で行う。

#### 送出には専用の許可が要る（実測）

macOS 26.5.2 / M3。送出の許可が無いプロセス（`CGPreflightPostEventAccess() == false`）が自分の最前面ウィンドウへ ⌘V を送る。`Edit > Paste` を持つメインメニューを用意し「⌘V の結び先が無い」交絡を除いてある。

| 送出方法 | 貼り付いた回数 |
|---|---|
| `CGEvent.post(tap: .cgAnnotatedSessionEventTap)` | **0 / 3** |
| `CGEvent.post(tap: .cghidEventTap)` | **0 / 3** |
| `NSApp.postEvent(_:atStart:)`（TCC を通らない） | 3 / 3 |
| `textView.paste(nil)`（直接呼び出し） | 3 / 3 |

**`CGEvent.post` は `Void` を返す。** 捨てられたことを後から知る術が無い。送出したつもりで成功を報告すると、履歴には `.pasteboard` と記録されるのにテキストはどこにも入っておらず、しかもクリップボードは復元済み——つまり**発話が消えたうえに成功として残る**。

したがって `PasteboardInserter.canInsert()` は**常に `true` ではない**。届けられないと判っている場合は試さずに落とす。門は 2 つある。

| 門 | 判定 | 備考 |
|---|---|---|
| 送出の許可 | **`CGPreflightPostEventAccess()`**（`kTCCServicePostEvent`） | **`AXIsProcessTrusted()`（`kTCCServiceAccessibility`）ではない。** 別の TCC レコードなので片方だけ true はありうる。照会が実測 p50 10.6 ms 掛かるためキャッシュする（§9） |
| secure input | `IsSecureEventInputEnabled()` が false であること | TCC とは無関係。許可があっても届かない。実測 0.000 ms なので毎回見る（キャッシュ禁止） |

**取り違えの注意。** ここは当初 `AXIsProcessTrusted()` と書いていたが誤りである。`CGEvent.post` が要求するのは **event synthesizing access**（`kTCCServicePostEvent`）であって、AX API のアクセス権ではない。両者は隣り合った別 API（`CGPreflightPostEventAccess` / `CGPreflightListenEventAccess` / `AXIsProcessTrusted`）で、値がたまたま一致する機体では区別が付かない。

#### 復元待ち時間 120 ms の根拠（実測）

⌘V の送出から実際に貼り付く（`NSTextViewDelegate.textDidChange` が呼ばれる）まで。各条件 50 回。

| 条件 | p50 | p90 | 最大 |
|---|---|---|---|
| 低負荷（load average 約 2.5） | 33.3 ms | 35.4 ms | 36.0 ms |
| 負荷下（`yes` 16 本、load average 約 13.5） | 31.4 ms | 34.8 ms | 35.3 ms |

CPU 負荷では動かない。約 33 ms は 60 Hz の 2 フレームにあたる固定の間隔で、計算資源ではなくイベント配送の周期で決まっている。クリップボードへ書いた内容が別プロセスから見えるまでは p50 0.9 ms（負荷下 1.1 ms、最大 24.5 ms）で、支配項ではない。

**この実測には上限として扱えない留保が 2 つある。**

1. 計測は `NSApp.postEvent` で行った。計測機に送出の許可（`kTCCServicePostEvent`）が無く `CGEvent.post` が黙って捨てられるため、**WindowServer を経由する分の遅延が入っていない。**
2. 貼り付け先は自プロセスの `NSTextView` である。相手が重いアプリなら相手のランループ待ちが上乗せされる。

つまり実測 35 ms は**下限**であり、120 ms はそれに対する約 3.4 倍の余裕である。**値は据え置きとし、実アプリでの妥当性は V-3（実装 §12-11）で確かめる。**

なおこの待ち時間は NFR-P5（テキスト挿入 50 ms 以内）には数えない。挿入はテキストが貼り付いた時点で完了しており、復元はその後始末である。

#### 退避時の AppKit 警告

退避は挿入と同じ非同期文脈＝協調スレッドプールで走る。クリップボードに「約束」として載っている型があると、`data(forType:)` がその場で実体化を要求し、AppKit が `NSPasteboard: synchronous promise fulfillment requested from a background thread!` を出す。

実測（新しいクリップボードへ内容を載せ、**最初の読み取りを**協調スレッドプールから行う）:

| クリップボードの内容 | 警告 | 退避に要した時間 |
|---|---|---|
| 平文のみ | 出ない | 0.88 ms |
| 画像 + 平文 | 出ない | 0.09 ms |
| 平文の複数項目 | 出ない | 0.07 ms |
| `NSAttributedString`（ブラウザ等からのコピー） | **出る** | 0.50 ms |

**リッチテキストは日常的にコピーされる**ので警告は普通に出ると考えてよい。ただし実測ではハングせず（10 回で最大 1.43 ms）、データも欠けなかった。約束の提供元がプロセス内の AppKit だからである。**提供元が別プロセスの場合（他アプリのファイル約束など）は未検証**で、V-3 で見る。

### 6.4 CompositeInserter

```
secure input が有効か
  └─ 有効 → 何も試さず拒否 → .refusedSecureInput（クリップボードにも残さない）
AccessibilityInserter が適用可能か判定
  ├─ 可 → 実行 → 成功: .inserted(.ax) / 失敗: 次へ
  └─ 不可 → 次へ
PasteboardInserter が適用可能か判定
  ├─ 可 → 実行 → 成功: .inserted(.pasteboard) / 失敗: 次へ
  └─ 不可 → 次へ
クリップボードへ残置 → .inserted(.clipboardOnly)（HUD 通知）
```

### secure input 中は挿入そのものを拒否する

**secure input が有効なのは、ユーザーがパスワードを入力しているときである。** secure input は「この瞬間の入力を捕まえるな」という OS からの明示的な合図であり、AX 経路でそれを迂回するのは機能ではなく欠陥である。

通してしまうと次が起きる。

1. 発話が LLM 整形（`FoundationModels`）へ渡る
2. **履歴ファイルへ平文で永続化される。** `HistoryStore` は `rawText` と `refinedText` を `history.json` に平文の JSON で保存する。NFR-V2 が禁じているのは**音声**のディスク書き出しなので、テキスト履歴はこの禁止を素通りする
3. `.clipboardOnly` へ落ちればクリップボードにも残る

したがって、**判定は合成器の入口に置き、どの経路も試さず、クリップボードにも残さない。** 判定は挿入のたびに行う（ユーザーはパスワード欄に出入りする。`IsSecureEventInputEnabled()` は実測 0.000 ms）。

**ここはこの製品で唯一「発話を失う」ことを正とする分岐である。** 通常は発話を失わないことが最優先（基本設計書 §7）だが、パスワードは残す方が害が大きい。

### 戻り値を `InsertionOutcome` にした理由

```swift
public enum InsertionOutcome: Sendable, Equatable {
    case inserted(InsertionMethod)   // 履歴に記録してよい
    case refusedSecureInput          // 履歴に記録してはならない

    public var recordableMethod: InsertionMethod? { ... }
}
```

拒否を `InsertionMethod` の一ケースとして足すこともできたが、そうすると **`HistoryEntry.insertionMethod`（`InsertionMethod` 必須）へそのまま入ってしまう**。つまり「記録してはならないもの」が型として記録可能になる。分けておけば、履歴を作るには `recordableMethod` を開く一手間が要り、拒否は `nil` で落ちる。

**Task 10 への申し送り: `HistoryEntry` を作る前に弾くこと。**

```swift
guard let method = outcome.recordableMethod else { return }  // 拒否は記録しない
```

**フェーズ 2 への申し送り:** 拒否したことをユーザーへ伝える手段（HUD 表示）が要る。無言で消えると「動かない」と受け取られる。

**残置は合成器の責務であり、Pasteboard 経路の副作用ではない。** 両段が「適用外」を返した場合、`tryInsert` は一度も走らないので Pasteboard 経路がクリップボードへ書く機会が無い。合成器が `.clipboardOnly` を返す前に自分で `ClipboardLeaving.leave(_:)` を呼ぶ。**`.clipboardOnly` を返すときは、テキストが実際にクリップボードへ残っていること。**

最後の砦は Pasteboard 経路と**同じ `NSPasteboard`** を見ていなければならない。別のものを掴ませると、残したテキストがユーザーには見えない場所へ行く。組み立て（`CompositeInserter.system`）は同一インスタンスを二役で渡す。

**PTT キー解放から挿入までの間、フォーカスが移動しないことが前提である。** HUD は `.nonactivatingPanel` とし、フォーカスを奪ってはならない（V-6）。
**`.nonactivatingPanel` だけでは足りない。** `NSApp.run()` の前に window を出すとアプリが活性化し、最前面 pid が Ghost Voice 自身になる（実測。§7.2）。
**HUD の window level を 0 にしてもならない**——`frontmostProcessIdentifier()` が拾ってしまう（同）。

### 6.5 TextReplacer（挿入済みテキストの差し替え。FR-5(a) / FR-7）

**挿入済みのテキストを、後から別の文字列へ差し替える。** この 1 つの原始操作の上に必須要件が 2 つ載る。

| 要件 | 使い方 |
|---|---|
| **FR-5(a)** | 生テキストを先に挿入して NFR-P6a（1 秒）を守り、整形が返ったら整形結果へ差し替える |
| **FR-7** | 直近の挿入を整形前の生テキストへ戻す。**同じ操作を逆向きに使うだけ**（`TextReplacer.undo(_:)` は `replace(_:with: anchor.previousText)` の薄い包み） |

**二重に作らないこと。** Undo のために別の機構を建てると、危険な書き込み経路が 2 本になる。

#### 使える原始操作は 1 つしかない

**`kAXSelectedTextRange` で範囲を選び直し、`kAXSelectedText` を 1 回上書きする形だけである。**

| 案 | 失敗の形 | 判定 |
|---|---|---|
| ⌫ を n 回送る → 新テキストを挿入 | 送出は `Void`（§6.3）。⌫ が届いて挿入が届かない状態を**検出できない** | **不採用** |
| ⌘Z を送る | アンドゥ単位が判らない。戻し過ぎると利用者自身の編集を壊す | **不採用** |
| **AX で範囲を選び直して上書き** | 範囲設定も書き込みも `AXError` を返す。失敗すれば**何も起きない** | **採用** |

**⌫ と ⌘Z を落とす理由は同一である。「届いたか判らない操作で、先に消す」から。** 差し替えを「消してから書く」2 手に分けた瞬間に、その間の窓で発話が消える。**AX の範囲上書きだけが、消すことと書くことを 1 回の呼び出しに閉じ込められる。**

> **§8.3 の旧版が書いていた「挿入済み文字数ぶんの Delete キーを送出」は、この理由で採らない。** 旧版は `CGEvent.post` が `Void` を返すと判明する前に書かれていた（統括の裁定 / 2026-08-14）。**§8.3 は同日に全面的に書き換えてあり、現在の §8.3 と本節は同じ 1 手（AX の範囲上書き）を述べている。**

#### 成立条件（C-1〜C-7。**安い順に判定する**）

`AccessibilityInserter.canInsert()` と同じ規律で、**AX の往復を伴わない判定を先に置く。**

| # | 条件 | 何を防ぐか | 判定の手段 |
|---|---|---|---|
| C-7 | そのプロセスで、本セッション中に喪失の疑いを出していない | 危険な相手への再試行。**アプリ名の一覧を持たずに締め出せる** | プロセス内の集合（AX を叩かない） |
| — | 錨が失効していない（次の発話の挿入が始まっていない） | 前の発話の差し替えが次の発話へ当たること | `InsertionEpoch`（同上） |
| C-2 | 錨がプロセス内メモリに生きている | 別プロセス・別セッションからの Undo | **`ReplacementAnchor` を `Codable` にしない** |
| — | 空文字への差し替えでない | **「消すだけ」になること** | 文字列（同上） |
| — | secure input が無効 | パスワード欄での書き換え | `IsSecureEventInputEnabled()`（実測 0.000 ms） |
| C-3 | 現在の最前面 pid が挿入時の pid と一致 | 別アプリへ移ってから撃つこと | `processIdentifier(of:)` |
| C-4 | 現在のフォーカス要素が挿入時の要素と一致 | 同じアプリの別の入力欄 | `CFEqual`（**未実測。V-27**） |
| C-5 | `kAXSelectedTextRange` と `kAXSelectedText` が両方 settable | 範囲を選べない相手に書きにいくこと | `AXUIElementIsAttributeSettable`（**アプリごとの実際は未実測。V-23**） |
| C-6 | **記録した範囲を読み戻した文字列が、自分が書いた文字列と一致する** | 利用者の編集・カーソル移動・範囲の単位ずれ・アプリによる変換を**まとめて弾く** | `AXStringForRange`（**未実測。V-24**） |
| C-1 | その発話が **`.ax` 経路で挿入された** | Pasteboard / clipboardOnly には範囲が無い | 錨の有無（型で保証） |

**C-6 が要である。** 位置の算術（「n 文字ぶん戻る」）を信じず、**読み戻して一致したときだけ書く。** 一致しなければ理由を問わず中止する。**AX の範囲の単位が UTF-16 かグラフェムクラスタかという未決事項は、C-6 があれば「間違えたら中止する」に変わる。**

さらに**長さを自分で数えない。** 錨の範囲は「書き込みの前後で読んだキャレット位置の差」から作る。**相手が数えた値をそのまま使う**ので、単位が何であっても成立する。

#### 手順（5 手 + 後始末）と、各中止点で発話がどこにあるか

```
1. 事前読み : 利用者の現在の選択範囲（整数 2 つ。後で戻すため）
2. 事前検査 : AXStringForRange(記録した範囲) == 自分が書いた文字列 か
               └ 違う / 読めない → 中止（何も書き換えていない）
3. 範囲設定 : kAXSelectedTextRange ← 記録した範囲
               └ AXError → 中止（何も書き換えていない）
4. 上書き   : kAXSelectedText ← 新しい文字列   ← **内容を変えるのはこの 1 回だけ**
               └ AXError → 中止（範囲を選んだだけ。手順 6 で選択を戻す）
5. 事後検査 : AXStringForRange(新しい範囲) == 新しい文字列 か
               ├ 一致          → 成功
               ├ 元の文字列    → 無言失敗（R-4）。**何も起きていないので害は無い**
               └ どちらでもない → 喪失の疑い（下記）
6. 後始末   : 手順 1 で読んだ選択範囲を、長さの差だけ補正して書き戻す
```

| 中止点 | 結果 | 欄にあるもの | クリップボード | 履歴 |
|---|---|---|---|---|
| C-1〜C-7 のどれかが欠ける | `.declined` | **挿入済みの生テキスト** | 触らない | raw + refined |
| 手順 2 の検査が不一致・読めない | `.declined` | **同上** | 触らない | 同上 |
| 手順 3 / 4 が `AXError` | `.declined` | **同上**（選択だけ戻す） | 触らない | 同上 |
| 手順 5 が「元の文字列」（R-4） | `.silentlyIgnored` | **同上。成功として扱わない** | 触らない | 同上 |
| **手順 5 がどちらでもない** | **`.lost`** | **不明** | **新しい文字列を残す** | 同上 |
| 差し替えが成功 | `.replaced` | 新しい文字列 | 触らない | 同上 |

**表の 1 行を除いて、失敗の結末はすべて「生テキストが欄にある」である。** これは**現行実装の正常系と同じ状態**であり、この機構は「うまくいけば良くなる／失敗すれば現状のまま」という形をしている。**差し替えを丸ごと外しても製品は今と同じに動く。**

**唯一の重い行（`.lost`）は 4 重で受ける。**

1. **履歴**（呼び出し側が挿入直後に書いてある。実測 0.44 ms / §8.2）
2. **クリップボードへ残す**（`ClipboardLeaving`。挿入器と同じ `NSPasteboard`）
3. **利用者へ告げる**（`ReplacementAnnouncing`。HUD の実装は別）
4. **以後そのアプリでは試さない**（C-7）

**2 度目の書き込みはしない。** 二重挿入は入らないことより悪い（§6.2 と同じ裁定）。

#### NFR-V3 の最小例外（**利用者が明示的に承認 / 2026-08-14**）

**「そこにまだ自分の文字列があるか」を確かめずに書き換えるのは、利用者が手で編集した内容の上に書くことを許すのと同じである。** そこで例外を 1 つだけ置く。

| 読むもの | 何が返るか | 扱い |
|---|---|---|
| `kAXSelectedTextRange` | 整数 2 つ（位置・長さ） | **例外に当たらない**（文字を含まない） |
| `AXStringForRange(自分が書いた範囲)` | 自分が直前に書いた文字列 | **これだけが例外** |
| `kAXValue` / `kAXNumberOfCharacters` / `kAXVisibleCharacterRange` | 欄の全文・全長・可視範囲 | **読まない。継ぎ目にも置かない** |

承認された 4 条件と、それを固定している検査。

| 条件 | 実装での守り方 | 固定している検査 |
|---|---|---|
| 1. 範囲は自分が書いた場所に限る。前後 1 文字も広げない | 読む範囲は (a) 錨の範囲 と (b) いま書いた範囲 の 2 つだけ | `readsOnlyItsOwnRanges` / `readsOnlyItsOwnRangesWhenLost` |
| 2. 用途は比較のみ。真偽値 1 つに落とす | **`AccessibilityRangeProbing.matches(_:in:of:)` は `String` を返せない**（`RangeMatch` の 3 値） | `rangeProbeCannotReturnText` |
| 3. 保持しない（履歴・計測・整形・ログのどこへも渡さない） | 読んだ値は `SystemAccessibility.matches` の 1 行を出ない | `readBackNeverEscapes` |
| 4. 不一致だった文字列の内容を一切見ない | 不一致は `.sourceMismatch` の 1 ケースへ落ちる | `mismatchDecisionDoesNotDependOnContent` |

**例外は `AccessibilityRangeProbing` の中にしか存在しない。** 主たる挿入経路（§6.2）は読み戻しを行わないという裁定をそのまま維持する。

#### 型（`Bool` では表せなかったもの）

`PrimaryInserting.tryInsert` は `Bool` を返していたため、**pid も範囲も要素参照も表せなかった。** 契約を変えてある。

```swift
public enum InsertionAttempt: Sendable {
    case failed
    case inserted(anchor: ReplacementAnchor?)   // 錨が nil でも挿入は成功
}

public protocol AnchoringTextInserting: TextInserting {
    func insertCapturingAnchor(_ text: String) async -> AnchoredInsertion
}
// TextInserting.insert(_:) はこの既定実装から導出する（経路を 2 本にしない）
```

`ReplacementAnchor` は **`Codable` にしない**（C-2）。`HistoryEntry` に持たせてもならない——履歴は `history.json` へ落ちる。

**挿入器と差し替え器は必ず一緒に作る**（`CompositeInserter.systemStack`）。世代（`InsertionEpoch`）を共有しないと差し替えが常に失効し、クリップボードを共有しないと喪失時の退避先が誰にも見えない場所になる。**どちらも黙って壊れる形の間違いである。**

#### 自動 Undo の門

**門はメモリ上に生きている `ReplacementAnchor` であり、履歴ではない。** 錨は `.ax` 経路でしか作られないので、**挿入していない発話（`.clipboardOnly`）へ Undo を撃つ経路が構造的に消える。**

履歴側にも 2 番目の門を置く（`HistoryEntry.isAutomaticUndoCandidate`）。`refinedText != nil` と 10 秒窓だけでは `.clipboardOnly` が素通りし、**挿入していないテキストを消そうとして別の何かを消す。**

---

## 7. NotchHUD

### 7.1 表示先ディスプレイの決定（FR-3）

```swift
/// 内蔵ディスプレイ。無ければ nil（クラムシェル）。
func builtInScreen() -> NSScreen? {
    NSScreen.screens.first { screen in
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? NSNumber)?.uint32Value else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}
```

外部ディスプレイの接続状態にかかわらず、常にこの結果へ表示する。

> **当初の実装案（`safeAreaInsets.top > 0` → `localizedName.contains("Built-in")` → `NSScreen.main`）は誤りだったので差し替えた。**
> 1. **notch 非搭載の MacBook（Air M1・Intel 機・13" MBP）では内蔵でも `safeAreaInsets.top == 0`** になり、内蔵を内蔵と認識できない。
>    要件定義書 §4.3 は notch 非搭載機のフォールバック表示を認めているが、**その表示先が内蔵になる保証が消える。**
> 2. `localizedName` は**ローカライズされる**ので判定に使ってはならない（実測値は `"Built-in Retina Display"` / `"DELL S2722QC"` だった）。
> 3. **`NSScreen.main` は「キーウィンドウのある画面」であって内蔵ではない。** 実測でも `NSScreen.main != NSScreen.screens.first` だった。
>    `NSScreen.screens.first` も主ディスプレイであり、外部を主にしていれば外部が来る。

**判定は 2 段に分ける。**

| 問い | 使う API |
|---|---|
| どの画面が内蔵か（FR-3 の「常に内蔵に出す」） | `CGDisplayIsBuiltin` |
| その画面に notch があるか（表示形状の分岐） | `auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil`（かつ `safeAreaInsets.top > 0`） |

#### notch の矩形（実測 / 2026-08-14 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2 / 内蔵 + DELL S2722QC）

```
notch.width  = frame.width - auxL.width - auxR.width   // 1800 - 791 - 788 = 221
notch.height = safeAreaInsets.top                       // 38
notch.minX   = frame.minX + auxL.width                  // 791
notch.maxY   = frame.maxY                               // 1169
```

端数なくぴったり足し合う（791 + 221 + 788 = 1800）ので、「左右の可視領域の隙間 = notch」で正しい。

| 実測した事実 | 値 |
|---|---|
| 内蔵の `frame` / `safeAreaInsets.top` | 1800×1169 / **38.0** |
| `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`（内蔵） | 幅 791 / 幅 788（y 1131..1169） |
| 同（外部ディスプレイ） | **どちらも nil。`safeAreaInsets.top` は 0.0** |
| `NSStatusBar.system.thickness` | 22.0 |

- **メニューバーの高さは `safeAreaInsets.top`（38 pt）であって `NSStatusBar.system.thickness`（22.0）ではない。** notch 機ではメニューバーが notch の高さまで広がっている。**22 で計算すると 16 pt ずれる。**
- **`auxiliaryTop*Area` は nil 合体が必須。** 強制アンラップは notch 非搭載機で即クラッシュする。
- `visibleFrame` の上端（1130）と `auxiliaryTop*Area` の下端（1131）は **1 pt ずれる。** メニューバー帯へ置くならどちらを基準にするか決めておくこと。

> **未実測: notch の切り欠きそのもの（x 791..1012 / y 1131..1169）に描いた内容が見えるか（V-20）。**
> 座標は取れるが、そこは物理的にカメラハウジングであり、**描いても見えない可能性が高い**
> （Apple が `auxiliaryTop*Area` を「カメラハウジングの**脇**の領域」として定義していることが根拠。**これは推測である**）。
> スクリーンショットによる確認は画面収録の権限ダイアログを誘発するため行っていない
> （`CGPreflightScreenCaptureAccess()` が false を返す。実装時も同じ理由で行っていない）。
> → **採った形**: FR-2 の「notch 部分に表示する」は、**切り欠きの直下へ帯を張り出して視覚的に notch と連続させる**実装にした（§7.3）。
> **中身をすべて帯より下へ置いたので、切り欠きに画素が無くても表示は成立する**——
> **したがって V-20 の結果で実装は変わらない。** 見えるなら帯が繋がって見え、見えないなら中身だけが見える。
> **目視の手順は [README](../README.md) の「HUD の目視確認（`--hud-check`）」にある。**

**そのほかの未実測**: 外部ディスプレイを主にしたときの内蔵の `auxiliaryTop*Area`（V-22 と同時に見る）、
notch 非搭載の内蔵ディスプレイの実測（該当機が手元に無い。V-41）、
`NSApplication.didChangeScreenParametersNotification` による抜き差し時の再計算（V-40）。

#### 実装した形（`HUDScreenSnapshot` / `HUDPlacement`）

**`NSScreen` を読む場所を 1 箇所に閉じ込めた**（`HUDScreenSnapshot.current()`）。配置の判断（`HUDPlacement.resolve`）は値の変換だけで、`NSScreen` を 1 度も触らない。

理由は**検査できないから**である。`NSScreen` はこの機体の実際のディスプレイ構成でしか作れないので、**notch 非搭載の内蔵機（V-41）・クラムシェル（V-22）・外部を主にした構成（V-22）は `NSScreen` 越しには 1 つも検査できない。** これらは未実測のまま残る項目であり、**未実測だからこそ、コードが破綻しないことだけは固定しておく**（`Tests/GhostVoiceAppTests/HUDPlacementTests.swift`。実測した 2 画面の値をそのまま写した構成も含めてある）。

**閉じ込めは検査で守っている**——`Sources/GhostVoiceApp/` 配下で `NSScreen` を書いてよいのは `HUDScreenSnapshot.swift` だけであることをソース走査で固定した（`HUDWindowContractTests`）。

**実装を通した実測（2026-08-15 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2 / 内蔵のみ）**: 起動時の診断が

```
[HUD] 表示先: 内蔵ディスプレイ(id 1) / 切り欠きの直下（notch x 791.0, y 1131.0, w 221.0, h 38.0） / 上辺 y=1169.0 中心 x=901.5
```

を出した。**調査時（2026-08-14）の実測と 1 pt も違わない。** 座標の計算式が実機で再現することを、製品のコード経路で確かめたことになる。

#### 内蔵が見つからない構成のフォールバック

**主ディスプレイのメニューバー直下（`visibleFrame.maxY`）へ、notch のときと同じ帯を出す。** 決めた理由と、候補 (a)(b) を採らなかった理由は基本設計書 §8.1.1 にある。**FR-3 を果たせていないことは起動時の診断に 1 行出す**（`HUDPlacement.isOnBuiltInDisplay`）。

### 7.2 ウィンドウ構成

| 属性 | 値 | 理由 |
|---|---|---|
| クラス | `NSPanel` | 非アクティブ表示が可能 |
| `styleMask` | `[.borderless, .nonactivatingPanel]` | フォーカスを奪わない（§6.4 の前提）。**この組み合わせなら `canBecomeKey` / `canBecomeMain` は既定で false**（実測）。サブクラスで override する必要は無い |
| `level` | **`.statusBar + 1`（= 26）** | メニューバー項目より確実に前面。**`.maximumWindow` は採らない**（下記） |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` | 全画面アプリ上でも表示。⌘` の巡回に入れない |
| `isMovable` | `false` | notch に固定 |
| `hidesOnDeactivate` | `false` | **必須。** 他アプリが前面でも消えないため |
| `ignoresMouseEvents` | `true` | クリックも奪わない |
| `backgroundColor` | notch と連続させるなら `.black`（角丸の外を透かすなら `.clear` + `isOpaque = false`） | notch と一体に見せる |
| 表示 | **`orderFrontRegardless()`。`makeKeyAndOrderFront` は使わない** | 後者はキーウィンドウにしてしまう |

#### **HUD の window は `NSApp.run()` が始まった後にだけ生成・表示する**（実測 / 2026-08-14 / M3 / macOS 26.5.2）

`NSApp.run()` の前後で 1 要因ずつ切り分けた結果:

```
### run() の "前" に orderFrontRegardless する ###
  run() 0.6 秒後 : 最前面 = 自分自身 isActive=true    ★フォーカスを奪った

### run() の "後" に orderFrontRegardless する ###
  HUD 表示の直後 : 最前面 = 元のアプリ isActive=false  ★奪わない
  0.8 秒後       : 最前面 = 元のアプリ isActive=false
```

**`NSApp.run()` を呼ぶ前に window を `orderFrontRegardless()` すると、AppKit が `finishLaunching` の時点でアプリを活性化する。**
`setActivationPolicy(.accessory)` を先に呼んでいても起きる。**`.nonactivatingPanel` でも `canBecomeKey == false` でも防げない**（アプリごと前面に出るため）。
活性化すると `SystemAccessibility.frontmostProcessIdentifier()` が拾う最前面 pid が Ghost Voice 自身になり、**挿入先が壊れる**（§6.2）。

→ **「起動時に非表示の HUD を用意しておく」実装にしてはならない。** 生成も表示も `run()` の後に行う。

現実の構成（delegate の `applicationWillFinishLaunching` で `.accessory` を設定 → `NSApp.run()` → 起動 0.6 秒後に HUD 表示）では、
`applicationWillFinishLaunching` から HUD を消した後まで**一貫して最前面は元のアプリのままで、`NSApp.keyWindow` も `NSApp.mainWindow` も最後まで nil だった。**

#### z 順の実測（`.statusBar` 以上に何が居るか）

`.statusBar`(25) / `.statusBar+1`(26) / `.maximumWindow`(2147483631) の 3 枚を同時に出し、
`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` の並び（前面から順）で確かめた。

| 対象 | layer |
|---|---|
| メニューバー本体（`Window Server / Menubar`） | **24**（= `NSWindow.Level.mainMenu`） |
| メニューバー右側の項目（コントロールセンター等） | **25**（= `.statusBar`） |
| マイク／カメラのプライバシーインジケータ（緑ドット） | **2147483630** |
| `CGWindowLevelForKey(.maximumWindow)` | **2147483631** |

- **`.statusBar`（25）で既にメニューバー本体（24）より前面に出る。** 同 layer のコントロールセンター項目よりも前面に来た。
- **`.statusBar + 1`（26）を採る。** メニューバー項目より確実に前面になる。
- **`.maximumWindow` は採らない。** プライバシーインジケータ（2147483630）より前面に出てしまい、**録音中にマイク使用を示す緑ドットを隠しうる。** `NSStatusBar` のメニューにも被る。
- **`level` を 0（通常ウィンドウ）にしてはならない。** `frontmostProcessIdentifier()` は `kCGWindowLayer == 0` の最前面を見るので、**その瞬間に挿入先が Ghost Voice 自身になる**（§6.2）。layer 25〜26 ならこの判定に引っかからない。

#### メニューバーとの重なり

`auxiliaryTopLeftArea`（x 0..791）と `auxiliaryTopRightArea`（x 1012..1800）は、**メニューバー本体が実際に描かれている帯そのもの**である。
つまり **notch の左右にはメニューバーが居る。** HUD をそこへ重ねるとアプリのメニュー項目やステータス項目を隠す。
→ HUD は左右の帯を横断して広げるのではなく、**notch の幅（実測 221 pt）を基準に切り欠きの直下へ張り出す形**にする。
録音中に横へ広げるなら、**メニューバーを隠すことを承知の上での判断**になる。

#### メインループと終了

フェーズ 1 の CLI は `while !isShuttingDown { CFRunLoopRun() }` で自前にメインのランループを回している（`GhostVoiceRuntime.swift`）。
**フェーズ 2 のアプリではここを `NSApp.run()` に置き換える。**

- `CGEventTapHotkeyMonitor` はソースを `CFRunLoopGetMain()` の `.commonModes` へ足す。**`NSApp.run()` の下でも `.commonModes` のソースが処理されることは実測した**（2026-08-14 / M3 / macOS 26.5.2）。**タップと完全に同じ形**（`CFMachPort` 由来の version 1 ソース）を含む 4 系統、`run()` の**前後どちらで登録しても**、**メニュー追跡中・モーダル中・`LSUIElement` の `.app` バンドル内**でも発火した。**陰性対照**（`.defaultMode` にだけ足したソース）は同条件で 1 度も発火しないので、偽陽性ではない。配送遅延は p50 0.045 ms（裾は 5〜17 ms）。
  - **成立範囲の但し書き 1**: `.commonModes` は「全モード」ではない。AppKit 下のコモン集合は `kCFRunLoopDefaultMode` / `NSEventTrackingRunLoopMode` / `NSModalPanelRunLoopMode` の **3 つだけ**（実測）。それ以外でメインのランループが排他的に回る区間では処理されない——実測ではメニューを開いたときの `__kCFPasteboardPrivateMode` **1 回・0.05 ms** だけだった。
  - **成立範囲の但し書き 2**: **メインスレッドを塞げば止まる。** 実測でメインを塞いだ間、配送は **p50 12.8 ms** まで悪化した（HUD の設計がこれに縛られる。§7.4）。
  - **依然として未実測（V-19）**: **タップ固有の振る舞い全般。** `CGEvent.tapCreate` は入力監視の権限ダイアログを誘発するので一度も呼んでいない。確かめられたのは「同じ形のソースがランループで処理されること」までであり、**タップが実際にキーイベントを配送するか・`return nil` による抑止（ESC）が効くか・`.tapDisabledByTimeout` が出ないか**は権限のある実機でしか判らない。
- **`NSApp.terminate(_:)` を素通しさせてはならない。** ⌘V 送出後・クリップボード復元前に落ちると発話が失われる（§6.3）。`applicationShouldTerminate` で `.terminateLater` を返し、**CLI と共通の `GhostVoiceCore.Shutdown.perform`**（Support/ShutdownSequence.swift）を通してから返事をする。**アプリ側に 2 つ目の段取りを書かないこと**——2 箇所にあると必ずずれ、両方とも自分のテストでは緑になる。
- `.accessory`（= `LSUIElement`）のまま `NSPanel` の生成・`orderFrontRegardless()`・layer 25/26 への配置がすべて成立することは実測済みである。

**未実測**: 全 Space での表示（`.canJoinAllSpaces`）と他アプリのフルスクリーン上での表示（`.fullScreenAuxiliary`）、Mission Control / Stage Manager 下での挙動（V-21）。

### 7.3 実装方式（自前の `NSPanel`）

**`NSPanel` を自前で実装する。外部ライブラリ（DynamicNotchKit）は採用しない**（2026-08-14 に裁定。基本設計書 §8.3）。

案 B（自前実装）の難所とされていた 2 点は、どちらも実測で解決した。

| 難所 | 解決 |
|---|---|
| 内蔵ディスプレイの特定 | `CGDisplayIsBuiltin`（§7.1） |
| フォーカスを奪わないこと | `.borderless` + `.nonactivatingPanel` + `orderFrontRegardless()`、かつ `NSApp.run()` の後に表示（§7.2） |

残る差は**形状（notch の角丸との連続）と展開アニメーション**だけで、これは機能要件ではない。
自前実装なら FR-3（表示先を内蔵へ固定）を完全に制御でき、外部依存ゼロ（基本設計書 §1 の方針 2）も保てる。

**V-5（DynamicNotchKit が表示先の固定に対応するか）は「採用しないため問わない」として閉じた。**

#### 実装したパネルの形

```
 ┌────────┬─────┬────────┐   ← 画面の一番上（frame.maxY = 実測 1169）
 │ 透明   │ 黒  │ 透明   │   ← 切り欠きの帯（高さ = safeAreaInsets.top = 実測 38）
 ├────────┴─────┴────────┤      **左右は塗らない**（メニューバーが居る）
 │        中  身         │   ← 切り欠きより下。ここだけ横へ広げてよい
 └───────────────────────┘
```

- **左右の肩を透明にしてある**ので、広げてもアプリのメニュー項目もステータス項目も隠さない。`ignoresMouseEvents = true` なのでクリックも透ける。
- **中身はすべて切り欠きより下に置く。** **切り欠きそのものに画素があるかは未実測である（V-20）**が、この形なら**画素が無くても表示は成立する。** 帯の黒は「切り欠きと連続して見せる」ためだけのもので、見えなくても失うものは無い。
- 幅は 2 通りだけ（畳んだとき = 切り欠きの幅か 200 pt の広い方 / 広げたとき = 460 pt）。**変わっていなければ `setFrame` を呼ばない。**

#### window を作る場所を 1 箇所に閉じ込めた

`NSPanel` を作れるのは `HUDPanel.swift` だけで、その初期化子は **`RunLoopEntry` を要求する。** `RunLoopEntry` は `LaunchSequence.enterRunLoop`（`NSApp.run()` のイベントループが回り始めた後）でしか作られないので、**「起動時に非表示の HUD を用意しておく」実装が型として書けない。** トラック B が作った形をそのまま使っている。

**ソース走査でも固定した**（`HUDWindowContractTests`）: `Sources/GhostVoiceApp/` 配下に `makeKeyAndOrderFront` が 0 件、`NSPanel(` / `NSWindow(` と `orderFrontRegardless` は `HUDPanel.swift` にしかない、`.maximumWindow` は 0 件。

#### フォーカスを奪わないことの実測（2026-08-15 / 実装した HUD で / MacBook Pro Mac15,3 / M3 / macOS 26.5.2）

`SystemAccessibility.frontmostProcessIdentifier()` とまったく同じ規則（`CGWindowListCopyWindowInfo(.optionOnScreenOnly, .excludeDesktopElements)` の `kCGWindowLayer == 0` の最前面 pid）で、**起動前・HUD 表示中・終了後を 0.25 秒ごとに観測した**（`--hud-check`。セッションを作らないので TCC には一切触れていない）。

```
=== 起動前 ===        frontmost(layer0) pid=85997 name=Google Chrome
  （HUD が出ていない） frontmost(layer0) pid=85997  GhostVoice の窓の layer=[]
  （HUD が出ている）   frontmost(layer0) pid=85997  GhostVoice の窓の layer=[26]
  （HUD を畳んだ後）   frontmost(layer0) pid=85997  GhostVoice の窓の layer=[]
=== 終了後 ===        frontmost(layer0) pid=85997 name=Google Chrome
  最前面(layer0) が GhostVoice だった回数: 0 / 32
```

- **最前面 pid は 1 度も Ghost Voice にならなかった**（2 回とも。観測 32 回 / 28 回）。**挿入先の判定は壊れない。**
- **HUD の窓は実際に layer 26 に現れた。** 設定した値が実際にその layer に載ることを、外から観測して確かめた。
- 子プロセスは自分で終了し（終了コード 0）、**残存プロセスは 0 件。**

> **これはトラック B が窓を 1 枚も持たない状態で行った確認の、HUD を足した後のやり直しである**（統合の申し送り 8）。

### 7.4 表示内容

| 状態 | 内容 |
|---|---|
| `idle` | 非表示 |
| `recording` | 音量バー（`AudioCapturing.level` に連動）＋ 言語バッジ（日/EN）＋ 暫定テキスト（末尾 2 行、`.volatile` 更新ごとに差し替え） |
| `finalizing` / `refining` | インジケータ。`refining` では整形なし縮退時にバッジを出す |
| `revising` | **控えめな表示にとどめる**（挿入は既に終わっており、利用者は次の作業へ移っている）。**差し替えに失敗した場合だけ明示的に告げる**——特に R-9（喪失の疑い）は回収を促す必要がある（§8.3） |
| 完了 | チェックマークを 0.6 秒表示して収納 |
| エラー | メッセージを 3 秒表示 |

#### 状態をそのまま描かない（`HUDPresenter` が居る理由）

**表示は状態の関数ではない。** 状態の並びを翻訳する純粋な状態機械（`Sources/GhostVoiceApp/Shell/HUD/HUDPresenter.swift`）を通す。理由は 3 つあり、どれも状態の側では表現できない。

1. **`.failed` の直後には必ず `.idle` が続く**（`fail()` が同期で両方 emit する）。素直に描くと**エラーは 1 フレームも見えない。**
2. **完了のチェックマークは状態ではない**（`.inserting` → `.idle` の間に挟む見せ方）。
3. **暫定テキストは `.volatile` 更新のたびに届く**（長い発話では数百件）。素通しすると描画がその回数だけ走る。

#### 表示の保持時間（**どれも要件値ではない**）

| 何を | どれだけ | なぜその長さか |
|---|---|---|
| 完了のチェックマーク | 0.6 秒 | 上表のとおり |
| 失敗 | 3 秒 | 上表のとおり |
| **発話を失った疑いのある失敗** | **8 秒** | `SessionFailureNotice.speechWasLost` が真のときだけ。**毎回強く出すと本当に失った回が埋もれる** |
| 通知（Undo の顛末など） | 1.5〜2.5 秒 | 利用者の打鍵に対する返事なので、返事が要る長さだけ |
| モデルの導入中 | **期限を置かない** | いつ終わるか判らない（数分）。数秒で消すと「押しても何も起きない」へ戻る |

**保持中でも `.recording` は勝つ。** 利用者が話し始めているのに前のエラーを出し続けるのは嘘である。

#### 通知（`SessionNotice`）のうち何を出すか

| 通知 | 出すか | 理由 |
|---|---|---|
| `.refinementApplied` | **出さない** | 欄の文字が整ったこと自体が結果である。通知のためだけの通知になる |
| `.refinementNotApplied(nil)` | **出さない** | nil は「整形そのものが返らなかった」（打ち切り・利用不可・逸脱の検査に落ちた）。**これは珍しくない**——実測で 56 字の発話は整形が締め切りの内側で完了していても 10/10 で捨てられている（V-37）。毎回出すと `.textMayHaveBeenLost` が埋もれる |
| `.refinementNotApplied(理由あり)` | **出す** | こちらが「差し替えを断念した」側であり、上表が明示的に告げよと言っているもの |
| `.textMayHaveBeenLost` | **最も強く出す。話している最中でも割り込む** | R-9。この設計で唯一「発話が欄から消えうる」経路であり、回収を促す必要がある |
| `.undone` / `.undoUnavailable` / `.undoDeclined` / `.undoCopiedRawTextToClipboard` | **出す（短く）** | 利用者の打鍵（⌃⌘Z）に対する返事。返事が無いと効いたのか判らない。**ただし録音中は割り込まない** |

#### 更新の間引き（NFR-P1 / NFR-P3 を守るため）

**メインスレッドを塞ぐと `CGEventTap` の配送が p50 0.045 ms → 12.8 ms へ悪化する**（ランループ検証の実測。§7.2 の「メインループと終了」と同じ根拠）。HUD の描画はメインスレッドで走るので、**録音中の中身の更新（暫定テキストと音量）は最短 50 ms 間隔に間引く**（＝最大 20 回/秒。**50 ms は要件値ではない**）。

守っている規律:

- **間引くのは中身だけ。状態の変わり目（`.recording` へ入る／出る・`.failed`・`.idle`）は必ず即座に反映する。** ここを間引くと「録音が終わっているのに録音表示のまま」が起きる。
- **保留した最後の 1 件は必ず出す。** 話し終えた直後の暫定テキストが出ないと「言ったのに出ていない」形になる。
- **録音表示から抜けたら保留は捨てる。** 残すと処理中の表示のあとに古い暫定テキストが割り込む。
- `HUDDisplay` は `Equatable` で、**変わっていなければ描画も `setFrame` も呼ばない。**
- **継続アニメーションを 1 つも置かない**（処理中の印も動かさない）。見た目が素っ気ないことより、PTT の反応が鈍るほうが重い。

> **HUD が実際に M1a / M2 を悪化させていないかは未実測である（V-39）。** 上記は「悪化させうる経路を塞いだ」ことしか言っていない。実測にはマイクとキー監視の許可が要る。

#### 音量バー

`levelStream()` の RMS を 5 本の棒の点灯数へ落とす。**満振れとみなす RMS（0.2）は実測値ではない**——肉声の RMS がどの範囲に収まるかは測っていない（V-38）。棒の高さを連続に変えないのは、更新ごとにレイアウトを走らせないためである。

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
    // .ax / .pasteboard / .clipboardOnly / .notInserted（ESC で中断された発話）
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
    public var refinementTimeoutMs: Int         // 既定 750（§10）
    public var historyLimit: Int                // 既定 50

    // ホットキーの妥当性を一括で検証する（§12-9）。復元経路（init(from:)）と
    // 保存経路（SettingsStore.update）の両方が呼ぶ。
    public func validateHotkeys() throws       // SettingsError.hotkeyConflict
}
```

**不正なホットキーを持つ `settings.json` は復元できない。** `SettingsStore` はそれを「読めなかった」として扱い、既定値で起動して `loadFailure` に理由を持つ（下記）。元のファイルは `.corrupt` へ退避されるので、利用者は手で直せる。**一部だけ既定へ倒す縮退は採らない**——「PTT だけ既定に戻っている」状態は壊れ方が読めない（I-4 と同じ形の事故になる）。

#### 読めなかったことは保持して、表に出す

3 つのストアは init で `loadOutcome()` を使い、**「ファイルが無い（正常な初回起動）」と
「あるのに復元できなかった」を区別して** `loadFailure` に持つ。表に出すのは CLI の仕事で、
`--check` の報告と常駐起動時の 1 行が、**読めなかったファイル名を挙げて**
「既定値で動作しています」と告げる。**3 つとも見ること**——`vocabulary.json` だけが
壊れている場合、黙ると**ユーザー辞書が無言で空になり**（FR-6）、症状は
「固有名詞が直らない」だけになる。

**フェーズ 1 の設定手段は `settings.json` の手編集だけ**なので、ここを黙ると、
カンマ 1 つの打ち間違いが「書き換えたのに効かない」という症状だけを残す
（原因に辿り着く手掛かりがどこにも無い。フェーズ 1 の最終レビュー I-4）。

### 8.2 書き込み方針

- JSON、原子的書き込み（一時ファイル → `replaceItemAt`）。
- 履歴は**挿入完了後に**追記し、挿入のクリティカルパスに入れない（NFR-P6a）。**差し替えが成功したら同じ `id` の項目を更新する**（§8.3。追記だけでは 2 件に増える）。
- `historyLimit` 超過分は追記時に切り詰める。**上限は `setLimit(_:)` で実行時に変えられる**（フェーズ 2。欠落 10）。下げたときはその場で切り詰めて保存する——次の発話まで待つと、設定画面を閉じた時点の表示と実体が食い違う。負数を既定値へ丸める規則は `init` と共有する。
- **書き込みの失敗は握り潰さない。** `DictationSession` は結果を見て `.failed(.historyUnavailable(insertedElsewhere:))` を出す。**中断された発話は履歴が唯一の写しなので、黙って落とすと発話ごと消える**（基本設計書 §7 の縮退表。フェーズ 1 の最終レビュー C-1）。挿入済みかどうかで文言を変えるのは、利用者にとって失うものが違うため（履歴と Undo だけ / 発話そのもの）。

**書き込みは同期である（実装の事実。当初「非同期で追記」と書いていたのを実測で置き換えた）。**
`DictationSession` は挿入を終えた後、actor を掴んだまま `HistoryStore.append` を呼ぶ。
非同期にしていないのは、書き込みが十分に速いからである。

**実測（`historyLimit` の 50 件を保持した最悪ケース・20 回）: p50 0.44 ms / 最大 0.87 ms / 最小 0.41 ms。**
上限まで埋まった状態で毎回 50 件を書き直しても 1 ms を切る。挿入は既に終わっているので
NFR-P6a（発話終了 → テキストが出るまで）には入らず、影響するのは**次の押下**（M1a の 50 ms 予算）だけで、
その 1 % 未満に収まる。**書き込みを非同期にすると、次の発話の履歴と順序が入れ替わる余地が
生まれる**（`append` は先頭挿入なので順序が意味を持つ）ため、この速さなら同期のほうが安全である。

### 8.3 差し替え（FR-5(a)）と Undo（FR-7）

> **本節は 2026-08-14 に全面的に書き換えた。** 旧版は 6 行しかなく、
> 「挿入済み文字数ぶんの Delete キーを送出 → rawText を挿入」と定めていた。
> **これは採らない**（要件定義書 §2.8.6 の裁定 4）。
> `CGEvent.post` は `Void` を返し、届いたかを知る術が無い（§6.3）。
> 差し替えを「消してから書く」2 手に分けた瞬間に、**⌫ が届いて挿入が届かない窓で発話が消え、
> しかもそれを検出できない。** 旧版は §6.3 の実測（`CGEvent.post` が `Void`）より前に書かれている。

**FR-5(a) の差し替えと FR-7 の Undo は同一の原始操作である**（要件定義書 §2.8.6 の裁定 3）。
向きが違うだけなので、**関数も検査も後始末も 1 つにする。**

| 用途 | source（そこにあるはずの文字列） | replacement（書き込む文字列） |
|---|---|---|
| FR-5(a) の反映 | 生テキスト | 整形結果 |
| FR-7 の Undo | 整形結果 | 生テキスト |

#### 使える原始操作は 1 つしかない

carry-ins §6 が挙げた 4 案を、**「失敗したときに発話が消えうるか」だけ**で切る。

| 案 | 失敗の形 | 発話を失うか | 判定 |
|---|---|---|---|
| ⌫ を n 回送る → 新テキストを挿入 | 送出は `Void`（§6.3）。⌫ が届いて挿入が届かない状態を**検出できない** | **失う。しかも検出できない** | **不採用** |
| ⌘Z を送る（アプリの Undo に任せる） | アンドゥ単位が判らない。戻し過ぎると利用者自身の編集を壊す | 失う（利用者の編集ごと） | **不採用** |
| **AX で範囲を選び直して上書き** | 範囲設定も書き込みも `AXError` を返す。失敗すれば**何も起きない** | 原則として失わない | **採用** |
| 何も消さずクリップボードへ置く | 壊さないが「戻せる」を満たさない | 失わない | **縮退先として採用** |

**AX の範囲上書きだけが、消すことと書くことを 1 回の呼び出しに閉じ込められる。**

#### 差し替えハンドル

挿入時に握り、**プロセス内メモリにのみ持つ**（`Codable` にしない。`history.json` へ書かない）。

| 情報 | 用途 | 永続化 |
|---|---|---|
| 対象 pid | 別アプリへ書かないため | 監査用に履歴へ持ってもよいが、pid は再利用されるので**単独では判定に使わない** |
| バンドル識別子 | pid 再利用の補助・アプリ別の集計 | 可 |
| AX 要素参照 | 同じ入力欄かの照合 | **不可（メモリのみ）** |
| 記録した範囲 | 自分が書いた場所 | **不可（メモリのみ）** |
| 書き込んだ文字列（source） | 読み戻しとの比較 | raw / refined として履歴にある |
| 挿入経路 | `.ax` 以外はハンドルを作らない | 可（既存の `insertionMethod`） |
| 挿入の通し番号（epoch） | 次の発話が始まったら破棄する | 不可（メモリのみ） |

**ハンドルは `.ax` 経路でしか作られない。** これで「`clipboardOnly` の発話を戻そうとする」経路が
**構造的に消える**（`undoCandidate` の `refinedText != nil` だけを見る判定では消えなかったもの）。

#### 成立する条件（安い順に判定する）

要件定義書 §2.8.6 の C-1〜C-7。判定は `AccessibilityInserter.canInsert()` と同じ流儀で
**AX の往復を伴わないものから順に**並べる（pid の一致 → 要素の同一性 → settable の照会 → 読み戻し）。
**1 つでも欠ければ差し替えを行わない。** 断念は失敗ではなく、**縮退先が現行の正常系**である。

#### 手順（5 手 + 後始末。すべての中止点で「何も書き換えていない」状態に戻る）

```
0. 事前条件  : secure input が無効／pid・要素・epoch が一致／条件 C-1〜C-7
                └ 1 つでも欠ける → 中止（何も書き換えていない）
1. 事前読み  : 利用者の現在の選択範囲を読む（位置のみ。後で戻すため）
2. 事前検査  : AXStringForRange(記録した範囲) == source か
                └ 違う / 読めない → 中止（何も書き換えていない）
3. 範囲設定  : kAXSelectedTextRange ← 記録した範囲
                └ AXError → 中止（何も書き換えていない）
4. 上書き    : kAXSelectedText ← replacement
                └ AXError → 中止（範囲を選んだだけ。手順 6 で選択を戻す）
5. 事後検査  : AXStringForRange(新しい範囲) == replacement か
                ├ 一致        → 成功。履歴を更新する
                ├ source のまま → 無言失敗（R-4 と同じ形）。**何も起きていないので害は無い**
                └ どちらでもない → **喪失の疑い（R-9）**
6. 後始末    : 手順 1 で読んだ選択範囲を、長さの差だけ補正して書き戻す
```

- **手順 2 が要である。** 位置の算術（「n 文字ぶん戻る」）を信じない。**文字数の数え方は 3 通りに割れる**（`count` / `utf16` / `unicodeScalars`）ので、算術だけでは「判らないまま書く」経路が残る。読み戻して一致したときだけ書けば、**間違いは中止に倒れる。**
- **R-9（手順 5 の最終行）では 2 度目の書き込みをしない。** 二重に入るのは入らないことより悪い（§6.2 の裁定と同じ）。replacement をクリップボードへ残し、HUD で告げ、**そのプロセスを以後の差し替え対象から外す**（C-7）。
- **履歴は内容変更より先に確保する。** raw と refined の両方が履歴にある状態で初めて手順 3 へ進む。書けなければ差し替えを始めない。

#### NFR-V3 の例外を、実装でどう閉じ込めるか

手順 2 と 5 の読み取りだけが例外である（要件定義書 §4.2 の 4 条件）。

| 実装上の縛り | 対応する条件 |
|---|---|
| 読み取り API は**範囲を引数に取る形のものしか使わない**（`AXStringForRange`）。`kAXValue` / `kAXNumberOfCharacters` / `kAXVisibleCharacterRange` を呼ぶ経路を持たない | 1 |
| 読んだ値を受ける変数は**関数のローカルに限り、返り値は `Bool`** にする | 2・3 |
| 一致しなかった場合に**返すのは「不一致」だけ**。読んだ文字列をログ・履歴・計測・整形のどこへも渡さない | 3・4 |
| **単体検査で固定する**: 代役の AX に対し、(a) 読み取り要求の範囲が直前の書き込み範囲と完全に一致すること、(b) 不一致時に読んだ文字列がどこにも漏れないこと | 1〜4 |

> **§6.2 の「書き込み後の読み戻しはしない」という裁定は、主たる挿入経路のものであり、ここには及ばない。**
> §6.2 が読み戻しを退けた理由は「アプリによる変換と区別が付かず、誤検知でフォールバックが走ると
> **二重挿入**になる」だった。差し替えでは (1) 事前検査で「変換されていない」ことを確かめた直後に書く、
> (2) 検知しても**再試行しない**（クリップボードへ逃がすだけ）ので、その 2 つの前提がどちらも成り立たない。
> **主たる挿入経路へ読み戻しを足してはならない**（§6.2 の裁定はそのまま）。

#### Undo キーに割り当てる意味

Undo のホットキーは既定で **⌃⌘Z**（Control + Command + Z）とする。**差し替えが適用済みの場合の有効期間は
「差し替えが成功した時刻から 10 秒」**とする（挿入時刻からではない。(a) の分岐では挿入と差し替えの間に
最大で NFR-P6b ぶんの隔たりがある）。それ以降はユーザーが手で編集している可能性があるため無効化する。

| 押された時点の状態 | 何が起きるか |
|---|---|
| 差し替えが**保留中** | **差し替えを取りやめるだけ。何も書き換えない**（危険度ゼロ） |
| 差し替えが**適用済み**（10 秒窓内） | 上の手順を逆向きに実行する（source = 整形結果 / replacement = 生テキスト） |
| 差し替え不可の経路で整形結果が入っている | **生テキストをクリップボードへ置き、「自動で戻せなかった」ことを告げる**（利用者の明示操作なのでクリップボードを奪ってよい） |
| どれでもない | 何もしない。「戻せません」と表示する |

**`HistoryStore.undoCandidate` は Undo の門ではない。** 門は**メモリ上に生きている差し替えハンドル**である。
`undoCandidate` は履歴 UI（FR-9）が「直近の整形済み発話」を拾うための述語として残る。
**ただしその述語も挿入経路を見る**（`HistoryEntry.isAutomaticUndoCandidate`）。
`refinedText != nil` と 10 秒窓だけでは **`.clipboardOnly`——どこにも挿入していない発話——が素通りし、
そこへ Undo を撃つと別の何かを消す**（持ち越し項目 16。配線トラックで塞いだ）。

#### Undo キーを抑止するか（配線トラックの決定 / 2026-08-15）

**「戻せる 10 秒窓の中だけ抑止し、窓の外では下流アプリへ通す。」**

| 選択肢 | 何が起きるか | 判定 |
|---|---|---|
| 常に抑止する | **窓の外では Ghost Voice は何もしない。** 何もしないのに打鍵を奪うと、**下流アプリの Undo / Redo が理由も無く効かなくなる。** しかも窓の外である時間の方が圧倒的に長い | **不採用** |
| 常に通す | こちらが差し替えを戻すのと**同時にアプリ自身の Undo も走り、二重に効く**（利用者から見て壊れている） | **不採用** |
| **戻せるときだけ抑止する** | 判定はセッションが持つ錨で行い、**監視器へは真偽値 1 つだけを押し込む**（`HotkeyMonitor.setUndoAvailable`）。hot path が読むのはそのフラグだけである | **採用** |

**判定を hot path に置けないことが、この形を強制している。** 「いま戻せるか」を知っているのは
`DictationSession`（actor）であり、**タップのコールバックは同期の C 関数なので actor へ問い合わせられない。**
1 打鍵あたりの判定は実測 p50 0.75 μs で**システム全体の打鍵に乗る**（§2.5）ので、
ここで問い合わせや計算を行う余地はそもそも無い。

- **タップは 1 本のままである。** Undo のためにもう 1 本立てると、上記の費用が単純に 2 倍になる。
- **見るのは押下だけである。** 解放を見るにはマスクへ `keyUp` を足す必要があり（§2.1）、
  それは全打鍵の配送量を倍にする。**帰結として、抑止した押下に対応する解放は下流アプリへ届く。**
  文字キーの単独の解放を意味づけるアプリは稀という判断だが、**実アプリでの影響は未実測（V-35）。**
- **`.undoRequested` はフラグが偽でも流す。** フラグは抑止の可否だけを決める——
  門にすると、フラグとセッションがずれた瞬間に打鍵が消える。

> **Option キーを含めてはならない。** PTT キーの既定が右 Option であるため、⌥ を含むショートカットを押すと録音が始まってしまう。**この検査はフェーズ 2 で `Settings.validateHotkeys()` に集約した**（§12-9）。設定画面の実装に頼らないので、手編集した `settings.json` にも効く。

### 8.4 履歴を UI から読み書きする口（フェーズ 2 / FR-9）

フェーズ 1 の `HistoryStore` は `append` / `entries` / `undoCandidate` しか持たず、
**履歴一覧の画面が作れなかった**（欠落 6 / 7 / 10）。次の 3 つを足した。

| 口 | 何のために | 呼んでよい場所 |
|---|---|---|
| `observe(_:) -> Subscription` / `changes() -> AsyncStream` | 変更通知。**単一消費者ではない**（HUD・履歴一覧・設定画面が同時に見る） | どこからでも。**ハンドラは MainActor で呼ばれない** |
| `remove(id:)` / `remove(ids:)` / `removeAll()` | 履歴の削除（FR-9） | **MainActor から `await` してよい** |
| `setLimit(_:)` | 保持件数の実行時変更 | **MainActor から `await` してよい** |

**通知はロックの外で配る。** 購読者が通知の中で `entries` を読み直すのは自然な使い方で、
ロックを保持したまま呼ぶと `NSLock` は非再帰なので自己デッドロックする。代わりに
スナップショットへ版番号を付け、**各購読者が受け取る列は必ず単調に新しい**ことを保つ
（書き込みが別スレッドから重なったとき、古いスナップショットが後から届くのを落とす）。

**削除系は Core が背景へ逃がす**（`@concurrent` の `async`）。`append` と違って
呼ぶのは MainActor に居る画面だけであり、「同期 I/O だから MainActor から呼ぶな」という
**覚えておくべき規則を作らない**ためである（`append` は `DictationSession` の中から
同期で呼ばれる。そちらは意図した同期であって §8.2 のとおり十分に速い）。

### 8.5 失敗の表示文言（フェーズ 2 / 欠落 12）

`SessionFailure` は型であって文言ではない。しかし文言を CLI と HUD の 2 箇所で
保守すると必ず食い違う。**媒体で変わるところと変わらないところを分ける。**

| 持ち主 | 中身 |
|---|---|
| Core（`Support/SessionFailureNotice.swift`） | 1 行の要約 / 補足 / 次にできること（`SessionRemedy`）/ 意図した拒否か（`isRefusal`）/ 発話を失ったか（`speechWasLost`） |
| 媒体（CLI の `SessionNarration` / HUD） | `SessionRemedy` の言い直しだけ |

#### `SessionNotice` も同じ形にした（配線トラック / 2026-08-15）

**同じ間違いが `SessionNotice`（差し替えと Undo の顛末）で起きていた。** 文言が
HUD（`HUDPresenter.announcement`）と Undo の UI（`UndoNarration`）の**2 箇所にあり、
CLI には 1 箇所も無かった**——`ghost-voice` から Undo を撃つと**顛末が何も出なかった。**
フェーズ 1 で潰した「無言で失敗する」と同じ形である。

| 持ち主 | 中身 |
|---|---|
| Core（`Support/SessionNoticeAnnouncement.swift`） | **出すか出さないか** / 1 行の要約 / 補足 / 重さ（`Weight`）/ 失敗として出すか / **自動で消してよいか**（`isPersistent`） |
| 媒体（CLI / HUD） | 重さ → 色と保持時間の写し、強調の書き方（端末は `**`、HUD は色） |

- **`.refinementApplied` と `.refinementNotApplied(nil)` は出さない。** これも判断なので
  Core が持つ（媒体ごとに変えると片方だけ賑やかになる）。理由は §7.4 と V-37。
- **`.undoCopiedRawTextToClipboard` だけ `isPersistent` である。** 時間で畳むと
  クリップボードに在る生テキストへ辿り着けない（UC-3 の縮退が死ぬ）。
  **次の発話が始まれば消える**——「時計で消すな」であって「居座れ」ではない。

同じ「権限を許可する」でも、素の実行ファイルは「**起動しているターミナルアプリ**を許可」、
`.app` は「Ghost Voice を許可」になる（§9 / `PermissionGuidance` の注記）。
**この差は文字列ではなく媒体の側にある**ので、Core は「どのペインか」までしか言わない。
`SystemSettingsPane` は URL（`x-apple.systempreferences:`）を持たない——開けることを
実測していないため（`docs/00-development-cycle.md` §3）。開くボタンを作る画面が実測のうえで足すこと。

> **実装に着手する前に V-23 / V-24 / V-25 を実測すること**（§13）。
> V-23 が全滅なら差し替えは一度も成立せず（挙動は現状と同じになる）、
> NFR-P6b の値は V-25 まで**推定値**である。

---

## 9. 権限（Permissions）

```swift
public enum PermissionKind: Sendable {
    case microphone, speechRecognition
    /// AX API へのアクセス（`kTCCServiceAccessibility`）。フォーカス要素の取得に要る。
    case accessibility
    /// キーイベントの合成（`kTCCServicePostEvent`）。⌘V の送出に要る。
    /// **`accessibility` とは別の TCC レコードである。**
    case postEvent
}

public protocol PermissionChecking: Sendable {
    func status(of kind: PermissionKind) -> PermissionKindStatus
    func request(_ kind: PermissionKind) async -> PermissionKindStatus
    func openSystemSettings(for kind: PermissionKind)
}
```

> **これは種類ごとに問う形の素描であり、実装はこの形を採っていない。**
> 実装は一式をまとめて照会する `GhostVoiceCore.PermissionInquiry.current() -> PermissionStatus` である
> （Support/PermissionInquiry.swift）。**実 API を名指しで呼ぶのはそこ 1 箇所だけ**にしてある——
> 下の対応表を 2 つ持つと、「どれか 1 つを他の判定に流用してはならない」という規律が
> **片側だけ守られている状態**を作れてしまい、値が一致する機体では気付けない。
> 差し替え口（`PermissionProbes`）を通して、4 つを 1 つずつ落とす検査で固定している
> （`PermissionInquiryTests`）。案内の文言だけが CLI（ターミナルアプリが許可の相手）と
> `.app`（Ghost Voice 自身が相手）で分かれる。

| 権限 | 判定 | 要求 |
|---|---|---|
| マイク | `AVCaptureDevice.authorizationStatus(for: .audio)` | `requestAccess(for:)` |
| ~~音声認識~~ | **要らない**（`SpeechAnalyzer` は `kTCCServiceSpeechRecognition` を要求しない。実測 V-14） | — |
| アクセシビリティ（AX API） | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions` にプロンプト表示オプションを付与 |
| キーイベント送出 | `CGPreflightPostEventAccess()` | `CGRequestPostEventAccess()` |
| キーイベント監視（ホットキー） | **`CGEvent.tapCreate` の成否**（§2.2）。事前照会は `CGPreflightListenEventAccess()` | `CGRequestListenEventAccess()` |

> **ホットキーの判定だけは事前照会を門番にしない。** `tapCreate` が nil を返すこと自体が権威ある答えであり、事前照会は「どちらのペインへ案内するか」を決めるための補助でしかない（§2.2 に実測と根拠）。

### キー送出の権限は AX とは別レコードである

**`CGEvent.post` が要求するのは `kTCCServicePostEvent` であって `kTCCServiceAccessibility` ではない。** どちらもシステム設定の「アクセシビリティ」ペインで付与されるが、TCC のレコードは別で、**片方だけ許可された状態は原理的にありうる**。判定に `AXIsProcessTrusted()` を使うと、そのとき「送れるはずなのに送れない」状態を検出できず、**貼り付いていないのに `.pasteboard` として履歴に残る**（§6.3）。

### 照会結果のキャッシュと、その限界

`CGPreflightPostEventAccess()` は**照会のたびに実測 p50 10.6 ms**（初回 16.7 ms / 最大 24.7 ms）掛かる。挿入のたびに呼ぶと NFR-P5（50 ms）の 2 割を判定だけで使う。そこで `PostEventAuthorization` が結果を保持する。

| 項目 | 内容 |
|---|---|
| 更新の契機 | **アプリ起動時**と、**権限フローを通過した直後**に `PostEventAuthorization.shared.refresh()` を呼ぶ |
| 照会しない読み取り | `isGranted`（保持値を返すだけ） |
| **限界** | **外部で権限を変えられたときに追随しない。** ユーザーがシステム設定で許可しても、次の `refresh()` まで古い値を使う |

**限界の影響。** 発話は失われない（`.inserted(.clipboardOnly)` へ落ちてクリップボードには残る）が、**ユーザーから見ると「システム設定で許可したのに直らない」**という、原因の特定が難しい状態になる。権限フローの画面から戻った時点で必ず `refresh()` を呼ぶこと。設定変更の監視までは行わない。

なお secure input（`IsSecureEventInputEnabled()`）は TCC ではなく実行時の状態なので**キャッシュしてはならない**。実測 0.000 ms なので毎回呼んでよい。

**マイク権限の判定は、マイクを掴む前に行うこと。** 未許可のまま `AVAudioEngine.inputNode` へ
触れると実測 510 秒ブロックする（§3.3）。判定 API 自体はハードウェアを開かないので安全である。

**アクセシビリティ権限はプログラムから付与できない。** 未付与時は設定アプリの該当ペインを開き、手順を HUD／ウィンドウで案内する（FR-10）。付与後はアプリの再起動が必要になる場合があるため、その旨も案内する。

### 許可の対象は実行ファイルではなく責任プロセスである（実測 + 推論 / Task 11）

**素の実行ファイルの TCC 権限は、起動元のターミナルアプリに紐づく。**

> **どこまでが実測か。** 測ったのは「バンドル ID を持たない実行ファイルで
> `authorizationStatus` が `.authorized` を返し、実際に 48000 フレーム届いた」までである
> （§3.3）。**別のターミナルアプリから起動すると許可が付いてこないことは測っていない**
> （許可を外す実験は利用者の環境を壊すため行わない）。macOS の TCC が責任プロセスへ
> 帰属させる一般的な挙動からの推論である。**利用者が別のターミナルで詰まったら、
> ここが最初に疑う場所になる。**
>
> **ただしフェーズ 2 ではこの推論に頼らなくてよい。** 下記のとおり `.app` は自分自身が責任プロセスになるので、
> 「どのターミナルから起動したか」という問い自体が消える。**この推論は測らないまま閉じてよい。**

システム設定の一覧に `ghost-voice` は現れないので、**フェーズ 1 の案内はターミナルアプリを名指しすること**
（`PermissionGuidance` がこれを固定している）。裏返すと、**別のターミナルアプリから起動すると
許可は付いてこない——ただしこれは上記の推論であって、実測していない。**
マイクが `.authorized` であることの実測は §3.3。

#### フェーズ 2: `.app` はターミナルの許可を 1 つも引き継がない（実測 / 2026-08-14 / M3 / macOS 26.5.2）

同一の `.app` を 2 通りの経路で起動し、**照会だけ**を行った（`requestAccess` / `AXIsProcessTrustedWithOptions` /
`CGRequestListenEventAccess` などの要求系 API は一切呼んでおらず、ダイアログは 1 つも出していない）。

| 照会項目 | ターミナルから直接実行 | `open` で起動（LaunchServices） |
|---|---|---|
| `Bundle.main.bundleIdentifier` | 同じ | 同じ |
| `AVCaptureDevice.authorizationStatus(for: .audio)` | **3（`.authorized`）** | **0（`.notDetermined`）** |
| `AXIsProcessTrusted()` | **true** | **false** |
| `CGPreflightListenEventAccess()` | **true** | **false** |
| `CGPreflightPostEventAccess()` | **true** | **false** |
| `getppid()` | ターミナル | **1（launchd）** |

→ **`.app` は Finder / Dock / `open` から起動された瞬間に自分自身が責任プロセスになり、
ターミナルアプリが持つ 4 つの許可を一切引き継がない。**

したがって**フェーズ 2 では、マイク・入力監視・アクセシビリティ・キー送出の 4 つを
Ghost Voice.app に対して付け直してもらう必要がある**（FR-10）。**これは避けられない。**
案内文には「別のアプリとして扱われるため」という理由も書くこと。

| 案内に含めること | 理由 |
|---|---|
| フェーズ 1 でターミナルアプリへ与えた許可は**移行が終わるまで外さない** | 外すとフェーズ 1 の CLI が動かなくなる |
| **ターミナルから `Ghost Voice.app/Contents/MacOS/…` を直接叩かない** | ターミナルの許可を引き継いでしまい、「動いているのに Finder から起動すると動かない」という切り分け不能な状態になる（上表のケース 1） |
| マイクだけはダイアログで完結する。**入力監視とアクセシビリティはシステム設定での手作業** | `kTCCServiceAccessibility` / `kTCCServiceListenEvent` / `kTCCServicePostEvent` には `Info.plist` の usage description キーが存在しない（実測。基本設計書 §10） |
| 付与後は**アプリを終了して起動し直す** | アクセシビリティ系の許可は起動時に読まれるため、付与しただけでは反映されないことがある |
| アクセシビリティのトグル 1 つの裏に**レコードは 2 つある** | 上記「キー送出の権限は AX とは別レコードである」。**2 つを別々に照会して案内すること** |
| **`.app` を置いた場所を後から変えない** | TCC のレコードはパスも見る。**移動で無効になるかは未実測（V-18）** |
| **bundle identifier を変えたら全部やり直し** | DR に焼き込まれる（基本設計書 §10） |

フェーズ 1 の CLI は `PermissionChecking` を実装せず、次の 3 つで代替する。

| 入口 | 何をするか | ダイアログ |
|---|---|---|
| `ghost-voice --check` | 4 項目（マイク / 入力監視 / アクセシビリティ / キー送出）を常に表へ出し、secure input が有効なときだけ 1 行足す。**終了コードが見るのは「PTT が動くか」＝マイクと入力監視の 2 つだけで、アクセシビリティが無くても 0 になる**（V-3 はその状態では意味を持たないので、報告の本文がそう言う） | **出さない** |
| `ghost-voice --request-permissions` | マイク（`requestAccess`）・入力監視（`CGRequestListenEventAccess`）・アクセシビリティ（`AXIsProcessTrustedWithOptions`）へ要求を出す | 出る |
| 常駐起動時 | **`tapCreate` を先に試し**、失敗したときだけ照会して案内する（§2.2） | 出さない |

**`AXIsProcessTrusted()` を起動の門番にしてはならない。** アクセシビリティが無くても入力監視だけで
タップは開きうる（逆もありうる）。門番は `tapCreate` の可否である。

`kAXTrustedCheckOptionPrompt` は `var` 宣言なので Swift 6 の並行性検査を通らない。
文字列 `"AXTrustedCheckOptionPrompt"` を直接使う（値は実測で確認した）。

### `.app` はターミナルアプリの許可を 1 つも引き継がない（実測 / 2026-08-14 / フェーズ 2）

上の「推論」の隣にある事実が実測で埋まった。**同一の `.app`**（`Info.plist` と署名を持つ）を
2 通りの経路で起動し、**照会だけ**を行った結果である（要求系 API は 1 つも呼んでいない）。

| 照会項目 | ターミナルから実行ファイルを直接叩いた | `open`（LaunchServices）で `.app` を起動した |
|---|---|---|
| `Bundle.main.bundleIdentifier` | 同じバンドル ID | 同じバンドル ID |
| `AVCaptureDevice.authorizationStatus(for: .audio)` | **`.authorized`** | **`.notDetermined`** |
| `AXIsProcessTrusted()` | **true** | **false** |
| `CGPreflightListenEventAccess()` | **true** | **false** |
| `CGPreflightPostEventAccess()` | **true** | **false** |
| `getppid()` | ターミナルの pid | **1（launchd）** |

→ **`.app` は Finder / Dock / `open` から起動された瞬間に自分自身が責任プロセスになる。**
ターミナルアプリが持っている 4 つの許可は 1 つも引き継がれない。

**フェーズ 2 の帰結は 2 つある。**

1. **利用者は 4 つの権限を `Ghost Voice` へ付け直すことになる。** これは避けられない。
   移行手順は [README](../README.md) の「フェーズ 2: `Ghost Voice.app` への移行」にある。
2. **案内の名指し先が起動経路で変わる。** CLI（`GhostVoiceCLI.PermissionGuidance`）は
   起動元のターミナルアプリを名指しし、アプリ（`GhostVoiceApp.AppPermissionGuidance`）は
   `Ghost Voice` を名指しする。**どちらもその経路では正しく、矛盾していない。**
   同じ規則（許可は責任プロセスに付く）の当然の帰結である。

> **ターミナルから `Ghost Voice.app/Contents/MacOS/GhostVoice` を直接叩かせないこと。**
> その経路ではターミナルの許可を借りて動いてしまい、「動いているのに Finder から起動すると
> 動かない」という切り分け不能な状態になる。アプリはこれを検出して警告する
> （`Bundle.main.bundleIdentifier == nil` を見る。`.app` の中から起動していれば非 nil）。

### 許可を与える相手はビルドのたびに変わってはならない（実測 / 2026-08-14 / フェーズ 2）

TCC の許可は署名の **designated requirement（DR）** に紐づく。したがって
**DR がビルドのたびに変わる署名方式を採ってはならない。**

| 署名 | DR | 実コードを 1 行変えて再ビルドしたとき |
|---|---|---|
| ad-hoc（`codesign -s -`） | `cdhash H"…"` のみ | **DR ごと別物になる**（cdhash が変わるため） |
| Apple Development 証明書 | `identifier "com.haruki1090.GhostVoice" and anchor apple generic and certificate leaf[subject.CN] = "…" and certificate 1[…]` | **DR は 1 文字も変わらない**（実測。同一ソースで 2 回、実コードを変えて 1 回、戻して 2 回の計 5 回のビルドで確認） |

`CDHash` は同一ソースの再ビルドでは一致したが、**編集して戻すと別の値になった**
（`8b0814fc…` → `153a82d8…` → 戻した後 `1229950c…`）。
**つまり cdhash は「ソースが同じなら同じ」ではない。** DR に cdhash を入れる方式
（ad-hoc の既定）が権限の保持と両立しない理由がここにある。

**`CFBundleIdentifier` は二度と変えないこと。** DR に焼き込まれるので、変えると
TCC の許可はすべて失われ、システム設定の一覧に古い項目が残る。

---

## 10. 性能計測（Metrics）

`DictationSession` の各遷移に計測点を置き、履歴と併せて記録する。

> **旧 `M5`（キー解放 → 挿入完了 = M2+M3+M4）は `M5a` へ改称し、意味が変わった。**
> 要件定義書 §2.8.6 の裁定により、1 秒（NFR-P6a）が守るのは
> **「整形済みテキスト」ではなく「まず使えるテキスト」**になったためである。
> 差し替え可能な分岐では **M3（整形）が M5a に入らない。**
> **既存の M5 実測（398 / 411 ms）と (a) の分岐の M5a を並べて比べてはならない**——測っている量が違う。
> `Metrics.Sample.total` / `meetsTarget`（`Support/Metrics.swift`）は
> **`waitedForRefinementBeforeInsert` で 2 つの定義を切り替える**ようにした（2026-08-15 / 配線トラック）。
> (b) は `M2 + M3 + M4`、(a) は `M2 + M4` である。

| 計測 ID | 区間 | 目標 |
|---|---|---|
| `M1a` | キー押下 → **タップ武装**（取りこぼしが止まる時点） | 50 ms（NFR-P1）。**実測 中央値 0.088 ms（アイドル）／ 0.118 ms（負荷下）、最大 14.0 ms**。うち `begin()` は実測 1.2〜1.4 ms。**達成（V-9 実施済み）。プロセス最初の 1 回が別だった件は、起動時の捨て往復で吸収した**（下記。最初の発話が払う `begin()` は 中央値 1.00 ms（低負荷）／ 3.0 ms（負荷下）） |
| `M1b` | キー押下 → 最初のバッファ**到達** | **実測 中央値 106.7 ms（アイドル）／ 106.5 ms（負荷下）、最小 102.9 / 最大 139.8。50 ms では届かない。** `installTap` の粒度 100 ms が下限で、`bufferSize` では下げられない（§3.5）。**ハードウェアの制約ではなく `AVAudioEngine` の実装による**ので、`AVAudioSinkNode` なら 10.7 ms まで下げられる（採らない理由は §3.6）。M5a の内訳として扱う |
| `M2` | キー解放 → **結果ストリームの終端**（＝確定テキストが出そろう時点） | **実測 中央値 75.9 ms（低負荷）／ 82.5 ms（負荷下）、範囲 45.1〜155.1 ms**（各 8 回 / 2026-08-14 / MacBook Pro M3 / macOS 26.5.2）。**定義は V-12 の修正で「解放以降の最初の `final`」から移した**（下記）。旧定義の実測は 40〜177 ms / 中央値 約 70 ms（13 回。V-2）で、**上乗せは実測 10.3〜12.2 ms（低負荷）／ 2.0〜21.6 ms（負荷下）。保守的な上限は 約 199 ms**（別々の計測の最悪値の和。同時に起こることは未確認） |
| `M3` | `final` → 整形完了 | 目標 500 ms（NFR-P4）／**打ち切りは (b) の分岐で既定 750 ms、(a) の分岐で NFR-P6b**（下記）。**実測 中央値 355 ms（低負荷）／ 364 ms（負荷下、10 件中 2 件が 500ms 超）。すべて 3 秒の発話での値。発話長別の分布は下記「発話長と整形所要」で実測した（2026-08-15）** |
| `M4` | **挿入器の呼び出し → 復帰**（(a) では生テキスト、(b) では整形結果） | 50 ms（NFR-P5）。**実測 中央値 0 ms（両条件）。ただしこれは `.clipboardOnly` 経路に固定した計測で、⌘V の往復（33 ms）も復元待ち（120 ms）も含まない**（下記の留保 3 件） |
| **`M5a`** | **キー解放 → 最初のテキストが挿入先に現れる** | **1000 ms（NFR-P6a）。** (a) では M2 + M4、(b) では M2 + M3 + M4。**旧 `M5` の実測（`.clipboardOnly` 経路で 中央値 398 / 411 ms、p90 419 / 819 ms、全条件 10/10 達成）は (b) の分岐の値として読む。** **(a) の分岐は代役の欄に対して実測した（2026-08-15。下記）: 中央値 38〜75 ms。実アプリでの確定は V-28** |
| ~~`M5b`~~ | ~~キー解放 → 認識ストリームの終端~~ | **`M2` に吸収された（2026-08-14 の統合時）。** V-12 の修正で `M2` の定義そのものが「結果ストリームの終端」へ移ったため、`M5b` は `M2` と同じ量になった。**別 ID として残すと同じ量を 2 通りに測る**ので畳んだ。分布は `M2` の行にある |
| **`M6`** | キー解放 → **整形の反映（差し替え完了）** | **NFR-P6b（目標 2 秒 / 打ち切り 3 秒）。差し替え可能な経路のみ。実測（2026-08-15 / 代役の欄）: 19 字で 中央値 391 ms、36 字で 中央値 722 ms。実アプリでの確定は V-28** |
| **`M7`** | 差し替えトランザクションの所要（事前検査 → 事後検査） | **未実測（V-28）。** §6.2 の AX 読み取り 0.1〜5.5 ms／往復からの外挿は**推測にすぎない**（差し替えは読み 3 往復 + 書き 2 往復ある） |

### M1 を 2 つに分けた理由（Task 7 の実測）

初版は M1 を「キー押下 → 最初のバッファ供給」1 本で定義していたが、**この定義では 50 ms を満たせない。**
`installTap` のバッファ長には下限があり、48 kHz では 1024 を要求しても 4800 フレーム（100 ms）ぶきざみでしか
届かない。**`bufferSize` を 64 まで下げても変わらない**（§3.5 に実 HAL の掃引結果）。

ただし**遅れの主因は「配達」であって取りこぼしではない。** 取りこぼしが止まる時点＝タップ武装（M1a）と、
配達の遅れ（M1b）を分けて扱う。NFR-P1 が守るべきは M1a である。

### M2 の定義を「最初の確定」から「結果ストリームの終端」へ移した（V-12 の修正 / 2026-08-14）

**旧定義は発話を失う。** 「解放以降の最初の `final`」で先へ進み、そこで `latestFinal` を
`await` を挟まず同期的に読んでいたため、**その後に届いた確定は積まれても二度と読まれなかった。**
実機の肉声で再現している——121 字・区切りの多い発話で**末尾 約 38 字が失われた**
（要件定義書 §2.8.4 / §13 の V-12）。合成音声 103 秒で起きなかったのは、
**危険な条件が起きなかっただけ**である。

**待つ相手を「これ以上テキストが来ないと判る時点」＝結果ストリームの終端へ移した。**
`updatesEnded(for:)` が既に待ちを解いていたので、受け皿は増やしていない。
認識器がストリームを閉じ忘れた場合の安全弁は締め切り（`finalizeDeadline`、既定 2 秒）が担う。

#### 上乗せの実測（2026-08-14 / MacBook Pro M3 / macOS 26.5.2 / ja-JP / `.dictation`）

6 秒の日本語音声を 100 ms ごとに実時間で供給し、キー解放に相当する時点から測った
（`measuresFinalizationLatency`。**マイクは使っていない**）。各条件 8 回。

| 条件 | `.final` 受信（旧 M2） | **終端（現行 M2）** | 上乗せ |
|---|---|---|---|
| 低負荷（load average 6〜12） | 中央値 64.6 ms（35.6〜98.5） | **中央値 75.9 ms（46.0〜109.3）** | 中央値 11.1 ms（10.3〜12.2） |
| 負荷下（`yes` 16 本。load average 46〜62） | 中央値 72.0 ms（34.6〜153.1） | **中央値 82.5 ms（45.1〜155.1）** | 中央値 10.7 ms（2.0〜21.6） |

```
低負荷 終端 : [46.0, 60.6, 73.3, 74.1, 77.8, 91.6, 101.0, 109.3]
負荷下 終端 : [45.1, 52.2, 75.5, 78.2, 86.7, 107.4, 107.5, 155.1]
```

**終端は `finish()` の復帰と実測でほぼ同時である**（差は 2 µs 未満。8 回とも）。
`finish()`（`finalizeAndFinishThroughEndOfInput()`）が返る時点で結果列も閉じるためで、
**「`finish()` の復帰を待たない」という §4.1 の 3 の判断は、実質的にはここで
`.final` から終端までの 約 11 ms を払う形に変わった。**

> **この計測の負荷条件は Task 11 のときより重い**（当時は load average 13）。
> 同一機体で複数のエージェントが並走していたためで、**低負荷側も真のアイドルではない。**
> 数字は「同じ機体で同じ日に、旧定義と新定義を同じ条件で並べた差」として読むこと。

#### 予算への影響（**余裕がほぼ無くなった**）

NFR-P6a（1000 ms）の逆算は M2 の最悪値に依存する（下記「M5 の実測と…裁定」）。**この逆算が効くのは (b) の分岐（差し替えできない挿入先）だけである**——(a) の分岐では整形が M5a に入らない（要件定義書 §2.8.6）。

| | 旧 | 新 |
|---|---|---|
| M2 の保守的な上限 | 177 ms（V-2 の 13 回の最大） | **約 199 ms**（177 + 上乗せの最大 21.6） |
| 整形に割ける上限 | 773 ms | **751 ms** |
| 既定 750 ms での合計 | 177 + 750 + 50 = 977 ms | **199 + 750 + 50 = 999 ms** |

**既定の 750 ms は今もぎりぎり収まるが、余裕は 23 ms から 1 ms になった。**
今回の実測の最大は 155.1 ms で、それで計算すれば 955 ms と余裕はある。
**打ち切りをこれ以上伸ばす判断（持ち越し項目 2 / FR-5）を行うときは、
この 199 ms を前提に置き直すこと。**

> **NFR-P3（200 ms）にも張り付いた。** 保守的な上限 199 ms は要件値の 1 ms 手前である。
> ただしこれは「過去の `.final` 最大 177 ms」と「今回の上乗せ最大 21.6 ms」という
> **別々の計測の最悪値を足した値**で、同時に起こることは確認していない。
> **実マイク・肉声での確認は V-31 として登録した**（§13）。

### 起動後の最初の `begin()` は捨て往復で吸収する（実測 / 2026-08-14 / Task 11・フェーズ 2）

`begin()` の実測 1.2〜1.4 ms は**ウォーム後の値**である。**プロセスで最初の 1 回は別の量になる。**

| 条件 | 1 回目 | 2 回目以降 |
|---|---|---|
| 低負荷（load average 5.2〜6.0） | 中央値 **44.2 ms** / 最小 39.3 / **最大 540.4**（n=8） | 中央値 1.6 ms / 最大 3.2（n=16） |
| 負荷下（`yes` 16 本、load average 13） | 中央値 **64.5 ms** / 最小 55.6 / 最大 195.7（n=5） | 中央値 2.2 ms / 最大 5.8（n=10） |

**負荷下では中央値で NFR-P1 の予算 50 ms を超えた。** 実害は「起動して最初の 1 回だけ、
録音の始まりが数十 ms 遅れる（最悪 0.5 秒）」で、**取りこぼしは発話の頭に出る**
（`begin()` の復帰前に来たバッファは黙って捨てられる。§4.4）。

#### 裁定: `warmUp()` で `begin()` → `finish()` を 1 往復させて捨てる（フェーズ 2）

フェーズ 1 は「**解析器を 1 つ余計に作る副作用がある**（§4.3.1 の寿命の議論）ので、
フェーズ 2 の起動シーケンスで判断する」として事実の記録にとどめていた。**採る。**

理由 —— **失うのが発話そのもの（重さ A）である**のに対し、副作用は 2 つとも消せる。

1. **起動は待たない。** 捨て往復は整形器の捨て推論と同じく投げっぱなしにする。
   待つと**起動直後、押しても何も起きない時間**ができる（§4.1 の 9 の既存の判断）。
2. **解析器が 2 つ同時に生きる窓は作らない。** 捨て往復は `finalizeTask` の枠へ入れる。
   `startRecording()` の頭は必ず `drainFinalizeTask()` を通るので、
   **捨て往復が畳まれるまで次の `begin()` は始まらない。** 新しい待ち合わせを足しておらず、
   既にある直列性の保証をそのまま借りている。

**残る代償は「起動直後に押した場合、その押下が捨て往復の残りを待つ」ことだけ**である。
待つ量は「捨て往復を入れなければ直後の `begin()` が払っていた初回費用」と同じもので、
**増えるのは入力ゼロの `finish()` のぶん（実測 中央値 0.33 ms / 最大 1.8 ms）しかない。**

#### 測り直し（2026-08-14 / MacBook Pro M3 / macOS 26.5.2 / 各 8 回・毎回別プロセス）

`throwawayRoundTripLeavesNoLiveAnalyzer`。**マイクは使っていない。**

| 条件 | 捨て往復の `begin()`（＝旧: 最初の発話が払っていた費用） | 捨て往復の `finish()`（入力ゼロ） | **その直後の `begin()`（＝新: 最初の発話が払う費用）** |
|---|---|---|---|
| 低負荷（load average 6〜12） | 中央値 37.2 ms / 最小 34.8 / 最大 211.6 | 中央値 0.33 ms / 最大 0.57 | **中央値 1.00 ms / 最大 2.10** |
| 負荷下（`yes` 16 本。load average 46〜62） | 中央値 158.5 ms / 最小 69.7 / 最大 1110.8 | 中央値 0.73 ms / 最大 1.82 | **中央値 3.0 ms / 最大 106.1** |

```
低負荷 捨て往復 begin : [34.8, 35.0, 36.0, 36.4, 38.0, 40.6, 42.2, 211.6]
低負荷 直後の begin   : [0.92, 0.95, 0.96, 0.97, 1.02, 1.20, 1.38, 2.10]
負荷下 捨て往復 begin : [69.7, 88.8, 95.5, 119.2, 197.8, 239.6, 572.3, 1110.8]
負荷下 直後の begin   : [2.46, 2.51, 2.52, 2.73, 5.28, 5.40, 6.48, 106.1]
```

**最初の発話が払う `begin()` は、低負荷で 中央値 44.2 → 1.00 ms、負荷下で 64.5 → 3.0 ms へ下がった。**
負荷下の中央値が NFR-P1 の予算 50 ms を超える状態は解消している。

> **負荷下の最大 106.1 ms は残る。** この計測の負荷は Task 11 のとき（load average 13）より
> はるかに重い（46〜62）ので、そのまま比べられない。**「1 回目のコールドを避ければ
> ウォーム経路になる」ことは示せたが、ウォーム経路そのものの裾は負荷で伸びる。**
>
> **`begin()` のコールド／ウォームの 2 分布は、負荷下では重なる**（コールド 中央値 158.5、
> ウォーム 最大 106.1）。検査線でこの 2 つを弁別することはできないので、
> `throwawayRoundTripLeavesNoLiveAnalyzer` の線は壊れ検知（2 秒）だけに置いた。

> **M1a の計測区間そのものは測り直していない。** M1a（キー押下 → タップ武装）の実測
> 0.088〜0.118 ms は実マイクが要り（V-9 / `GHOST_VOICE_MIC_TESTS=1`）、
> **`drainFinalizeTask()` の待ちはそこに入っていない。** 上の表はその待ちの中身
> （捨て往復の残り）を分解して測ったものである。**起動直後に押した場合の M1a を
> 実マイクで確かめることは V-32 として登録した**（§13）。

> **この事実は、検査線を要件値そのものに置いていたために「断続的失敗」として現れていた**
> （`measuresBeginLatency` が 50 ms 線で 8 回中 2 回落ちる）。規律 10 に従って線を
> 壊れ検知（1 回目 2 秒 / 2 回目以降 50 ms）へ分けたので、以後は実装の性質として読める。

> **どこまで実測したかの線引き（重要）。** 「タップ設置以降の音が**すべて**最初のバッファに入る」ことは
> **直接測っていない。** 根拠は間接的なもので、M1b の実測が最小 102.9 ms・中央値 106.7 ms と
> **粒度 100.0 ms に張り付いている**ことである。既に回っている I/O サイクルに途中から乗るなら
> 到達時刻は (0, 100] ms に散らばるはずで、そうなっていない。よって
> **タップ設置時点から新しい 100 ms の窓が始まると考えられる。**
>
> **ただしバッファ内容の先頭時刻は未計測である。** I/O サイクル境界へ整列する実装なら、
> 1 サイクル（512 フレーム ≒ 10.7 ms）ぶんの頭が欠ける余地は原理的に残る。
> 実害は最大でも約 10 ms で NFR-P1 の 50 ms 予算に収まるため設計判断は変わらないが、
> **断定はしない。** 既知信号を鳴らしながらタップを張り、最初のバッファの位相を見る検証を
> **V-11** として登録した（§13）。

**M1b はパイプライン遅延として M5a に効く。** キー解放時点で最大 100 ms ぶんの音がタップ内に
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

**当初の既定タイムアウト 500ms の余裕は、設計調査時の中央値 0.386 秒ベースの見積もりより
はっきり薄かった。負荷下では中央値 0.461 秒（余裕 39 ms）で、500ms を超える発話が実際に出る。**
超えても生テキストへ縮退するので壊れはしないが、**整形が効かない発話の割合が
見積もりより高くなる。** これが下記の裁定（既定を 750 ms へ）の出発点である。

実運用では認識と整形は同時に走らないが、**ユーザーの他アプリが機体を使っている状況は
これに近い**。

### M5（現 `M5a`）の実測と、既定タイムアウトを 750 ms へ引き上げた裁定（Task 10）

**以下はすべて「整形を待ってから挿入する」構成の実測である**——現在の呼び名では
**(b) の分岐の `M5a`** にあたる。(a) の分岐（生テキストを先に挿入する）の値は**未実測（V-28）。**

`DictationSession` を通して**キー解放から挿入完了までを端から端まで**計測した。
認識は `SpeechAnalyzerTranscriber`、整形は `FoundationModelRefiner`、挿入は
`CompositeInserter.system(...)` と**すべて本物**で、代役はマイク（台本どおりに喋らせられない
ため、フィクスチャ音声を 100 ms ごとに実時間で流す）とホットキーだけである。
1 発話 3 秒 / 10 サンプル / MacBook Pro M3 / macOS 26.5.2。

**打ち切り 500 ms のとき**（この計測が下記の裁定の根拠である）:

| 条件 | M2 中央値 | M3 中央値 | M4 中央値 | **M5 中央値** | M5 p90 | M5 最大 | M3 が 500ms 超 |
|---|---|---|---|---|---|---|---|
| 計測テストのみ（低負荷） | 44 ms | 382 ms | 0 ms | **423 ms** | 550 ms | 550 ms | **0/10** |
| `swift test` 全体（負荷下） | 46 ms | 492 ms | 3 ms | **551 ms** | 866 ms | 866 ms | **4/10** |

```
低負荷 M5 : [425, 389, 423, 407, 550, 401, 429, 423, 414, 431]
負荷下 M5 : [866, 551, 574, 557, 516, 589, 461, 418, 456, 413]
負荷下 M3 : [504, 504, 508, 509, 436, 492, 419, 368, 417, 367]
```

**打ち切り 750 ms へ変更した後**（現行）:

| 条件 | M2 中央値 | M3 中央値 | M4 中央値 | **M5 中央値** | M5 p90 | M5 最大 | M3 が 500ms 超 |
|---|---|---|---|---|---|---|---|
| 計測テストのみ（低負荷） | 40 ms | 355 ms | 0 ms | **398 ms** | 419 ms | 419 ms | **0/10** |
| `swift test` 全体（負荷下） | 41 ms | 364 ms | 0 ms | **411 ms** | 819 ms | 819 ms | **2/10** |

```
低負荷 M5 : [411, 398, 389, 419, 389, 398, 393, 382, 392, 408]
負荷下 M5 : [773, 819, 480, 365, 411, 391, 404, 377, 393, 495]
負荷下 M3 : [709, 756, 441, 334, 359, 350, 364, 345, 354, 437]
```

500 ms を超えた 2 件のうち **1 件（709 ms）は 750 ms なら整形が返っており、
1 件（756 ms）は 750 ms でも切れた。** 打ち切りを上げても取り切れない裾は残る。

**NFR-P6a（1000 ms）は `.clipboardOnly` 経路でどの条件でも 10/10 で達成している**（この計測はすべて (b) の分岐にあたる）**。**
問題はそこではない（⌘V を含む経路は未計測。下記「M4 について」）。

> **捨てられたバッファについてはこの計測から何も言えない。** 供給の代役
> （`ReplayAudioCapture`）は `droppedBufferCount` に定数 0 を返すので、差分は必ず 0 になる。
> 形式変換の失敗は `EngineAudioCapture` の変換経路でしか起きない。**「0 件だった」ではなく
> 「測っていない」が正しい。** 発話ごとの差分を取る仕組みそのものの検査は、
> `StubAudioCapture` で前後に人為的なドロップを起こす単体テストが担っている。

**負荷下では 10 発話中 4 発話が整形されずに終わっていた。** しかも超過分は 501〜527 ms と
わずかで、あと数十 ms 待てば整形結果が得られたものが大半である。同じ実行の中で
Task 6 の整形テストも 3/10 が 500 ms を超えている（中央値 471 ms / 最大 585 ms）。
**FR-5（挿入前に整形する）が実運用に近い条件で 3〜5 割効かない**状態だった。

> **裁定: `refinementTimeoutMs` の既定値を 500 ms から 750 ms へ引き上げる。NFR-P4 の
> 目標値 500 ms は変えない。**
>
> 誤りは「目標値と打ち切り位置を同じ数にしていたこと」である。500 ms は
> 「整形にこれくらいで終わってほしい」という目標で、打ち切りは
> 「待つより生テキストを出す方がましになる境界」という別の概念である。
>
> 打ち切り位置は NFR-P6a の予算から逆算する。実測の最悪値で M2 が 177 ms（V-2 の 13 回計測）、
> M4 の予算が NFR-P5 の 50 ms なので、整形に割ける上限は **773 ms**。750 ms なら
> 177 + 750 + 50 = **977 ms** で NFR-P6a に収まる。
>
> **【フェーズ 2 で更新】この逆算の M2 は旧定義（解放 → 最初の `final`）の値である。**
> V-12 の修正で M2 は「解放 → 結果ストリームの終端」になり、保守的な上限は
> **約 199 ms**（177 + 上乗せの最大 21.6）へ上がった。整形に割ける上限は **751 ms**、
> 750 ms での合計は **999 ms** で、**余裕は 23 ms から 1 ms になった**（上記「M2 の定義を…」）。
> **打ち切りをこれ以上伸ばすなら、この 199 ms を前提に置き直すこと。**
>
> **逸脱した生成への耐性は実質変わらない。** 命令文に読める発話でモデルが暴走する件
> （§5.5.1）は生成に 1.3〜3.4 秒掛かるので 750 ms でも切れる。0.505 秒で返った例は
> 500 ms でも既にすり抜けていた。**逸脱を止めているのはタイムアウトではなく
> `RefinementGuard.accept` の長さ比とコードフェンスの検査である。**
>
> 代償: 整形が遅い発話で、ユーザーが最大 250 ms 長く待つ。中央値は変わらない
> （`withTimeout` は生成が終わり次第返る）。**遅い側の発話が「待たされた末に整形されない」
> から「待たされた末に整形される」へ変わる**ので、待ちに見合うものが返るようになる。
>
> 誤りだった場合のコスト: 遅い発話の体感が 250 ms 悪化する。設定値なので
> `settings.json` の 1 行で戻せる。

> **この裁定の適用範囲は、フェーズ 2 の裁定（要件定義書 §2.8.6）で「差し替えできない分岐（(b)）」に狭まった。**
> 上の予算計算（現行の M2 で 199 + 750 + 50 = 999 ms。旧定義では 177 + 750 + 50 = 977 ms）は
> (b) では形が変わらないので、**既定値 750 ms も変えない**。
> **配線トラックが (a)/(b) の実分布を 2 条件で測ったうえで、据え置きを決めた**（2026-08-15。
> 上の「(a)/(b) の実分布と、発話長と整形所要の関係」の「判ったこと 4」に選択肢と根拠がある）。
> **差し替えできる分岐（(a)）では、整形は M5a に入らない**ので、この打ち切りは使わず
> NFR-P6b（目標 2 秒 / 打ち切り 3 秒。**どちらも推定値**）で走る。
>
> **750 ms を「実用の発話長に足りる値」へ引き上げる道は採らなかった。** 実測で `total 1142 ms` と
> 既に NFR-P6（当時の定義。現 NFR-P6a）を超えており、待つ側の分岐にはもう余地が無いためである（要件定義書 §2.8.4 (2)）。

### (a)/(b) の実分布と、発話長と整形所要の関係（実測 / 2026-08-15 / 配線トラック）

**計測環境**: MacBook Pro Mac15,3 / M3 / macOS 26.5.2 / ja-JP / `.dictation` /
`FoundationModelRefiner`（実 Apple Intelligence）。**認識も整形も差し替えも本物を通す。**
音声はフィクスチャ（`say -v Kyoko`）を**実時間で**流す（マイクは開かない）。
**挿入先だけが代役の欄である**——実機のアプリへは 1 文字も書いていない（安全制約）。
再現は `GHOST_VOICE_A4_MEASURE=1 swift test --filter RevisionBudgetMeasurement`。
各条件 n=5、低負荷（load average 約 4〜6）と負荷下（`yes` 16 本 / load average 6〜70）の 2 条件。

| 発話 | 字数 | 分岐 | 条件 | M2 中央値 | M3 中央値 | **M5a 中央値** | M6 中央値 | 整形が反映された |
|---|---|---|---|---|---|---|---|---|
| 3 秒 | 19 | (b) | 低負荷 | 44 ms | 348 ms | **393 ms** | — | 5/5 |
| 3 秒 | 19 | (b) | 負荷下 | 39 ms | 362 ms | **402 ms** | — | 5/5 |
| 3 秒 | 19 | **(a)** | 低負荷 | 45 ms | 343 ms | **45 ms** | 391 ms | 5/5 |
| 3 秒 | 19 | **(a)** | 負荷下 | 38 ms | 378 ms | **38 ms** | 418 ms | 5/5 |
| 6 秒 | 36 | (b) | 低負荷 | 51 ms | 716 ms | **794 ms** | — | **4/5** |
| 6 秒 | 36 | (b) | 負荷下 | 45 ms | 667 ms | **712 ms** | — | 5/5 |
| 6 秒 | 36 | **(a)** | 低負荷 | 54 ms | 652 ms | **54 ms** | 723 ms | 5/5 |
| 6 秒 | 36 | **(a)** | 負荷下 | 45 ms | 676 ms | **45 ms** | 722 ms | 5/5 |
| 10 秒 | 56 | (b) | 低負荷 | 72 ms | **750 ms（打ち切り）** | **824 ms** | — | **0/5** |
| 10 秒 | 56 | (b) | 負荷下 | 78 ms | **750 ms（打ち切り）** | **828 ms** | — | **0/5** |
| 10 秒 | 56 | **(a)** | 低負荷 | 75 ms | 1016 ms | **75 ms** | — | **0/5**（下記） |
| 10 秒 | 56 | **(a)** | 負荷下 | 73 ms | 1067 ms | **73 ms** | — | **0/5**（下記） |

> **M4 はこの計測では 0〜1 ms である**（代役の欄は AX の往復を持たない）。
> **実アプリの M4 は V-3 の実測で AX 12〜34 ms / Pasteboard 307〜354 ms。**
> 下の予算計算はこの計測の M4 ではなく V-3 の値を使う。

#### 判ったこと 1: **(a) は M5a を 1 桁下げる**

同じ発話・同じ機体で **(b) 393〜828 ms に対し (a) 38〜75 ms。**
**しかも (a) の M5a は発話長でほとんど動かない**（19 字 45 ms → 56 字 75 ms。増分は M2 のぶん）。
これは要件定義書 §2.8.6 の裁定が期待したとおりの形である——
**整形がクリティカルパスから外れると、NFR-P6a は発話長に依存しなくなる。**

#### 判ったこと 2: **整形の所要は字数にほぼ比例する（V-25 の主要部を実測した）**

| 字数 | M3 中央値（2 条件をまとめて） |
|---|---|
| 19 字 | 343〜378 ms |
| 36 字 | 652〜716 ms |
| 56 字 | 1016〜1067 ms |

**傾きは約 18.5 ms/字、切片はほぼ 0。** 要件定義書 NFR-P6b が
「出力長にほぼ比例する【推測】」として置いていた外挿（121 字 ≒ 2.4 秒）は、
**この実測で支持される**（18.5 × 121 ≒ 2.24 秒）。**推測は実測に置き換わった。**
ただし**測ったのは 3 点だけで、121 字そのものは測っていない。**

#### 判ったこと 3: **56 字では整形が「反映されない」。ただし理由が 2 つある**

- **(b) では打ち切り。** M3 が 750 ms で頭打ちになり 10/10 が生テキストへ縮退した。
- **(a) では打ち切りではない。** M3 は 969〜1152 ms で**締め切り（3 秒）の内側に収まっている**のに、
  **整形結果は 10/10 で捨てられた。** 捨てたのは `RefinementGuard`（§5.5.1）である。

> **【この観測の解釈は 2026-08-15 の追試で覆った。§5.5.1 と要件定義書 §2.8.7 が正である。】**
>
> 当時は「残存率の閾値が正当な整形を落としている」と読んだが、**発話長は原因ではなかった。**
> この計測は**フィクスチャ音声を 10 秒で切っており、認識結果が文の途中で終わっていた**。
> 追試（同じ音声の 10 秒スライスを実際に認識させた）で得た生テキストと出力:
>
> ```
> raw(56 字): 本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。前回は新しい
> out(96 字): …前回は新しいプロジェクトの進捗を確認し、チームメンバーとのコミュニケーションを強化しました。
> ```
>
> **モデルが 40 字ぶんの会議報告を捏造していた。捨てたのは正しい。**
> 落としたのは残存率ではなく**長さの検査**（96 > 56 × 1.5）である。
> **同じ長さ帯でも「言い終えた」発話は 3/3 で整形が反映される**（§5.5.1 の対照実験）。
>
> **さらに重い事実が同じ追試で出た**: 6 秒スライス（36 字）は
> `…ミーティングの振替` → `…振替についてお話しします。` と **+11 字を捏造したうえで受け入れられていた**。
> 判ったこと 4 が「36 字は 9/10 反映された」と書いているのは、**その捏造が利用者の欄へ入っていた**という意味である。
> **指標を作り直した**（§5.5.1）。V-37 はこの追試で閉じた。

#### 判ったこと 4: **`refinementTimeoutMs` は 750 ms のまま据え置く**

引き直しの判断（配線トラック / 2026-08-15）。**上げる根拠も下げる根拠も実測から出なかった。**

| 選択肢 | 何が起きるか |
|---|---|
| **上げる（例 1000 ms）** | (b) の予算は `M2 199 + T + M4`。AX 経路の (b) でも 199 + 1000 + 34 = **1233 ms** で NFR-P6a を破る。**56 字は上げても `RefinementGuard` に落ちる**ので、破るぶんの見返りが無い |
| **下げる（例 450 ms）** | 実運用に近い 36 字の帯（M3 620〜752 ms）が**丸ごと整形されなくなる。** 下げる動機は Pasteboard 経路の (b) を 1000 ms に収めることだが、**その経路は復元待ちを含む実測 `total` が 1182〜1447 ms で、450 ms へ下げても達成しない**（要件定義書 §2.8.5）。**達成にならないのに機能だけ失う** |
| **据え置き 750 ms** | AX 経路の (b) は 199 + 750 + 34 = **983 ms ≦ 1000**。19 字と 36 字の帯で整形が効く（実測 24/25） |

**据え置きの前提が 1 つ変わった。** フェーズ 1 では (b) が唯一の経路だったので余裕 1 ms は
製品全体の余裕だったが、**フェーズ 2 では (a) が既定であり、(b) を通るのは
「差し替えられない挿入先」と「利用者が `beforeInsert` を選んだ場合」だけ**である。
前者はもともと NFR-P6a を満たしていない経路（Pasteboard）であり、
**この 1 ms の余裕が効く範囲は、フェーズ 1 より狭い。**

### M4 について（3 つの留保）

**1. 計測は `.clipboardOnly` 経路に固定してある。** AX 判定を「適用外」に、送出器を
「送出不可」に差し替えて測っている。**Task 8 が実測した ⌘V → 貼付の p50 33 ms も、
クリップボードの復元待ち 120 ms も含まれていない。** 権限のある機体での確定は
V-3 が担う（権限を付与した利用者が実施する）。

固定しているのは安全のためでもある。実物のまま組むと、**AX 権限のある機体では
`swift test` を回した瞬間にフォーカス中のアプリへテキストが書き込まれる。**
「この機体では権限が無いから安全」は別の機体では成り立たない。

**2. `insert()` の実時間には、NFR-P5 が数えないものが入る。** §6.3 は
「クリップボードの復元待ちは NFR-P5 に数えない。挿入はテキストが貼り付いた時点で
完了しており、復元はその後始末である」と定めている。しかし `Metrics.Sample.insert` は
`inserter.insert(_:)` の実時間を測るので、**Pasteboard 経路を通った場合は復元待ちの
120 ms が M4 に入る。**

したがって Pasteboard 経路の最悪ケースでは、`insert()` の復帰までで
177 + 750 + (33 + 120) = **1080 ms** となり NFR-P6a を超える。ただし
**ユーザーにテキストが見えるのはその 120 ms 前**であり、体感の M5a は 960 ms である。
（**M2 を現行定義の 199 ms で置くと 1102 ms / 体感 982 ms。** 結論は変わらない。）
一段目の AX 経路（往復 0.1〜5.5 ms）にはこの待ちが無い。

> 曖昧さを消したいなら、**復元を `insert()` の復帰後へ移す**のが筋である
> （§6.3 の「復元は後始末」という位置づけと、測る値を一致させられる）。
> Task 8 の担当範囲なのでここでは変更していない。**V-3 で実測してから判断すること。**
>
> **Task 11 も変更していない。** 権限が無く M4 の実挿入を測れないためで、
> 契約（§6.3）を実測なしに変えるべきではない（Task 10 申し送り【2】の裁定）。
> **V-3 を実施した人が、`[metrics]` の `insert` と体感のずれを見て判断すること。**

**3. 実権限 API を通していた計測で、M4 に 287 ms の外れ値が出た。** 挿入そのもの
（クリップボードへ書くだけ）ではなく、その手前の照会——`AXIsProcessTrusted()` と
`IsSecureEventInputEnabled()`——が負荷下で跳ねたものと見ている。Task 8 の実測は
それぞれ 0.001 ms / 0.000 ms（いずれもウォーム後）だが、**機体が飽和した条件では
NFR-P5 の 50 ms 予算を 1 桁超えることがある。** 未説明の観測として記録する。

テストは**中央値**を閾値判定に使っている。最大値で判定すると負荷条件で落ちる不安定な
テストになり、しかも落ちても対処のしようが無い（500ms を超えた発話は生テキストへ
縮退するのが正しい振る舞い）。代わりに分布と 500ms 超の件数を毎回出力する。

M2 の計測条件: 6 秒の日本語音声を 100 ms ごとに実時間で供給し、最後のバッファ供給から
`.final` を受け取るまで（13 回計測。**旧定義。現行定義での測り直しは上記「M2 の定義を…」**）。
`DictationTranscriber` / `.progressiveShortDictation` /
`modelRetention: .processLifetime`（MacBook Pro M3 / macOS 26.5.2 / Xcode 26.6）。
**結果の消費は `begin()` 直後に別 Task で開始している。** `finish()` の後に消費を始めると
「`finish()` 復帰 ≦ `.final` 受信」が構造上保証され、到着時刻ではなく待ち順を測ることになる。

> **この計測は楽観側に寄っている。** 最後のバッファを供給してから 100 ms 待った時点を
> 「キー解放」としているため、解析器に 1 バッファぶんの先行処理を許している。
> 実際の PTT ではキー解放は最後のタップから 0〜1 タップ間隔のどこかで起きるため、
> **実機の値は 10〜15 ms 程度これより大きくなると見込まれる。**
> 40〜177 ms という結論を覆す規模ではないが、NFR-P3 を 200 ms とした根拠としては
> 楽観側の値である。**Task 10 が `DictationSession` 越しに測った M2 は 中央値 40〜41 ms /
> 最大 74 ms で、この 40〜177 ms の範囲に収まった**（§10）。ただし供給はやはり代役
> （フィクスチャ音声の実時間再生）なので、実マイクでの確認は V-4 が担う（利用者が実施）。
> **実機の値がここからずれた場合、まずこの構造を疑うこと。**

**`.final` は `finalizeAndFinishThroughEndOfInput()` の復帰より前に届く。**

| 計測 | キー解放 → `.final` | キー解放 → `finish()` 復帰 | 差 |
|---|---|---|---|
| 実測 7 組 | 40〜177 ms | 51〜182 ms | `.final` が 5〜48 ms 早い |

→ **後段（LLM 整形）の起動は `finish()` の復帰を待たない。**
`finish()` の復帰を待つと 5〜48 ms を無駄にする。

> **【フェーズ 2 で更新】待つ相手は `.final` ではなく、結果ストリームの終端になった**
> （V-12。上記「M2 の定義を…」）。**最初の `.final` で先へ進むと発話の末尾を失う。**
> 終端は実測で `finish()` の復帰とほぼ同時（差 2 µs 未満 / 8 回）なので、
> **上の 5〜48 ms の節約は実質的に失われている**（実測の上乗せは 中央値 約 11 ms）。
> それでも「復帰そのものを待つ」設計にはしていない——復帰を待つ形にすると、
> `finish()` が返らない認識器で録音が終わらなくなり、締め切りの受け皿も別に要る。

**M2 が想定の 1/4 で済んだぶん、(b) の分岐では M5a の予算 1000 ms をほぼ全て M3（LLM 整形）に充てられる。**
**(a) の分岐では M3 が M5a に入らないので、この配分の話が当てはまらない**（要件定義書 §2.8.6 / 基本設計書 §7.1）。
**(a) では逆に、M2 が数百 ms 伸びても M5a は 1 秒に収まる**——V-12（末尾の欠落）を直すときの余地はここにある。

デバッグビルドでは HUD に `M5a` を表示し、リグレッションを即座に検知できるようにする。
**差し替えの所要（M6 / M7）は別の値として持ち、M5a と足さない。**

### 10.1 差し替えが PTT をどれだけ待たせるか（V-36 / 実測 2026-08-15）

`applyRevision` は actor の上で **履歴の書き込み（ディスク）→ `replacer.replace`** を
**同期に**行う。その間、**actor 隔離の呼び出しはすべて待たされる**——
`startRecording` も同じである。**待たされる量を測った。**

**計測環境**: MacBook Pro M3 / macOS 26.5.2 / 2026-08-15 / n=5。
`DictationSession` / `TextReplacer` / `HistoryStore`（**実ディスク書き込み**）は**本物**、
認識と整形は代役（窓の所要を固定するため）、**挿入先は代役の欄**（実アプリへは 1 文字も書いていない）。
押下の瞬間は**差し替えの最初の AX 呼び出しに合わせて撃つ**（時計で狙うと、
当たったか外れたかを標本から区別できない）。

**AX の呼び出し回数**: 挿入 **16 回** / 差し替え **12 回**。

| AX 1 往復の注入 | 押下 → 録音開始（低負荷） | 押下 → 録音開始（負荷下 `yes` 16 本） |
|---|---|---|
| **0 ms（代役の欄）** | 中央値 **1.3 ms** / 最大 **3.5 ms** | 中央値 **2.3 ms** / 最大 **2.7 ms** |
| 2 ms | 中央値 32.7 ms / 最大 35.1 ms | 中央値 32.6 ms / 最大 35.6 ms |
| 10 ms | 中央値 144.8 ms / 最大 146.6 ms | 中央値 151.2 ms / 最大 151.4 ms |

**判ったこと。**

1. **配線ぶん（履歴のディスク書き込みを含む）は NFR-P1 の 50 ms を食わない。**
   最大 3.5 ms は予算の 7 % である。**負荷を掛けても増えない**（むしろ小さい。
   探り針の計測でも同じ傾向で、負荷下の最大は 0.7〜2.3 ms）。
2. **待たされる量はほぼ `12 × AX 1 往復 + 2 ms`。** 注入 2 ms → 実測 35 ms（予測 26 ms）、
   注入 10 ms → 実測 151 ms（予測 122 ms）。**1 往復が約 4 ms を超える相手で 50 ms を破る。**
3. **したがって残る未知は「実アプリの AX 1 往復のコスト」だけである。**
   要件定義書 §2.8.5 の実測（挿入の総所要。AX 16 回を含む）から外挿すると、
   Chrome アドレスバー（12〜34 ms）なら 1 往復 ≦ 2.1 ms で**差し替えは 30 ms 程度**、
   メモ（307 ms）なら 1 往復 ≒ 19 ms で**差し替えは 230 ms** になる。
   **ただしこの外挿は「往復のコストが一様」を仮定しており、実際には書き込み系が重い可能性が高い。**
   **推測を実測として扱わないこと。** 実アプリでの確定は V-28 / V-36。

**対処は行わない（実測に基づく判断）。** 差し替えを actor の外へ出せば待たせなくなるが、
**世代の照合と実際の書き込みの間に窓ができる**——これは §8.3 の安全性の土台そのものである。
**測れた側のコスト（≦ 3.5 ms）は予算を食っておらず、測れていない側（実アプリの AX）のために
土台を崩すのは、推定値の上に実装を積むのと同じ**である。
**必要になったときの逃げ道は既にある**——設定 `refinementApplyMode = .beforeInsert` で
(a) の分岐そのものを止められる。

**退行検知は常時走る検査に置いた**（`RevisionBlockingRegressionTests`。線は 25 ms で、
**要件値ではない**）。**守っているのは「12 回に 13 回目を足させないこと」**——
actor を握ったまま同期の作業を増やす変更が入れば、実アプリでの余裕がそのぶん減る。

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
| `DictationSession` | 代役を差し込んで PTT 1 回ぶんの流れを検査する。**発話が落ちうる箇所を名指しで押さえること**: `begin()` → タップの順序、`stopTap()` の末尾が `finish()` より前に供給されること、確定が**結果ストリームの終端**で進むこと（`finish()` の復帰ではない）、**解放後に確定が 2 件届いても 2 件目を取りこぼさないこと（V-12。実音声では駆動できないので代役で決定的に駆動する）**、録音中の確定で進まないこと、ストリームが終端しなくても締め切りで抜けること、確定が来なくても暫定テキストへ縮退すること、**起動時の捨て往復が畳まれてから次の `begin()` が始まること**、secure input が整形の手前で効くこと、中断でも履歴に残ること、最大録音時間で抜けること、キャンセル文脈でも確定処理が完走すること。**フェーズ 2 で追加**: 差し替え可能と判定した発話で**整形を待たずに生テキストが挿入されること**、保留中の差し替えが**次の PTT を妨げないこと**、次の発話の挿入で保留中の差し替えが**破棄され、かつ何も書き換えられていないこと** |
| **`TextReplacer`（§8.3）** | **代役の AX で全ての中止点を通す**: 事前条件が欠ける / 事前検査が不一致 / 範囲設定が `AXError` / 書き込みが `AXError` / 事後検査が source のまま（無言失敗）/ 事後検査が第三の値（R-9）。**どの場合も ⌫ と ⌘V の追撃が 0 回であること**、R-9 でだけクリップボードへ退避して以後そのプロセスを締め出すこと、**成功時に履歴の同じ `id` が更新されること**。**Undo は同じ関数を逆向きに呼ぶだけであることを、検査でも 1 つの対象として扱う** |
| **NFR-V3 の例外（4 条件）** | **読み取り要求の範囲が「直前に自分が書き込んだ範囲」と完全に一致すること**（前後 1 文字も広げていないこと）、**読み取りの結果が `Bool` より外へ出ないこと**（履歴・計測・整形・ログのどこにも現れないこと）、**不一致だった文字列の内容が判定に使われないこと**。要件定義書 §4.2 の 4 条件を、この 3 つの検査で固定する |

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

**前提: 2 つの権限が要る。** どちらも「システム設定 > プライバシーとセキュリティ > アクセシビリティ」で付与されるが、**TCC のレコードは別**である（§9）。

| 権限 | 無いと何が起きるか |
|---|---|
| AX API アクセス（`kTCCServiceAccessibility`） | フォーカス要素が取れず AX 経路が必ず適用外になる |
| キーイベント送出（`kTCCServicePostEvent`） | ⌘V が黙って捨てられ Pasteboard 経路が適用外になる |

どちらも無い状態では全アプリで `.inserted(.clipboardOnly)` になる（§6.2 / §6.3 の実測）。**したがって V-3 は両方を付与した状態でしか意味を持たない。**

**実施の手順は [README.md](../README.md) の「V-3 / V-4 の実施手順」にある**（Task 11 で用意した）。
`ghost-voice --check` で不足を確かめ、`--request-permissions` で要求を出し、
ターミナルアプリを再起動してから各アプリを回る。所要は準備 5 分・一気通貫（Ctrl-C）の確認 2 分・V-4 が 10 分・V-3 が 20 分。

**Task 11 の実装者はここを実施できない**（権限の付与は利用者の手でしか行えない）。
下の表の「結果」欄は空のまま残してある。**埋めるのは権限を付与した人である。**

| アプリ | 想定される経路 | 結果 | 復元待ち 120 ms は足りたか | AX が成功を返したのにテキストが入らなかったか |
|---|---|---|---|---|
| Slack | Electron のため AX 不可の可能性 → Pasteboard | | | |
| Google Chrome | 要素により変動 | | | |
| Xcode | AX 対応の見込み | | | |
| Notion | Electron → Pasteboard | | | |
| ターミナル / iTerm2 | Pasteboard | | | |
| メモ / メール | AX 対応の見込み | | | |

あわせて次の 4 点を確認する。いずれも権限の無い機体では確かめられなかったもの。

1. **復元待ち 120 ms の妥当性**（§6.3）。実測の 35 ms は WindowServer 経由の遅延を含まない下限である。貼り付けが空振りするアプリが 1 つでもあれば値を上げる。
2. **AX の無言失敗**（§6.2）。最終列に 1 件でも該当があれば、**二重挿入を避ける形**で検知を設計する。案: 書き込み前に対象が空だった場合に限り読み戻して検証する（空なら「アプリによる変換」と紛れないため誤検知しにくい）。設計は V-3 の結果を見てから行う。**Task 11 では材料が無いため行っていない。**
3. **`CGPreflightPostEventAccess()` と実際の送出可否が一致するか**（§6.3）。権限を与えた機体で `canSend` が true を返しつつ ⌘V が届かない場合、「発話が消えたうえに成功として記録される」経路が再発する。**最初に確かめること。**
4. **リッチな内容を退避したときの `synchronous promise fulfillment` 警告**（§6.3）。提供元が別プロセスの場合（他アプリのファイル約束など）に遅延や失敗が出ないか。
5. **V-23 / V-24（差し替えの前提）を同じ回で取る。** 各アプリの入力欄で `AXUIElementIsAttributeSettable` を `kAXSelectedTextRange` / `kAXSelectedText` について照会し、`AXStringForRange` が読めるかを見る。**書き込みは行わない**（この回の目的は「差し替えが成立しうるか」の確認である）。**ここが全滅なら §8.3 の実装は空振りする**ので、着手より前に判ることに価値がある。
6. **発話の長さと `refine` の実測を組にして記録する（V-25 の材料）。** 履歴の `refinedText` が無ければ打ち切られている。**打ち切り 750 ms は 3 秒の合成発話で決めた値であり、実用の発話長では足りない**（要件定義書 §2.8.4 (2)）。**NFR-P6b の目標 2 秒 / 打ち切り 3 秒は推定値なので、ここで取れた値がそのまま根拠になる。**

---

## 12. 実装順序

| # | 内容 | 完了条件 |
|---|---|---|
| 1 | Package 骨格とプロトコル定義 | ビルドが通り、モック実装で単体テストが動く |
| 2 | `TranscriptionEngine`（ファイル入力） | ゴールデンテストが通る。**V-1 / V-2 をここで実測する** |
| 3 | `AudioCapture` + マイク入力の結合 | CLI で発話 → 標準出力へ書き起こしが出る。**V-9 は実施済み**。**V-10（実デバイス切断）はここで実測する** |
| 4 | `Refiner` | 整形あり／なし、タイムアウト、Apple Intelligence 無効時の縮退が動く |
| 5 | `TextInserter`（二段構え） | 二段構えが動く。**V-3 は AX API アクセスとキー送出の両権限が要るため §12-11 へ繰り延べ。手順は README にある** |
| 6 | `HotkeyMonitor` | 判定と `CGEventTap` は完了。**V-4 はキーイベント監視の権限が要るため §12-11 へ繰り延べ。手順は README にある** |
| 7 | `DictationSession`（状態機械） | **状態機械と計測は完了（Task 10）。M5（現 M5a）を 2 条件で実測し、整形の既定タイムアウトを 750 ms へ引き上げた（§10）。** CLI での一気通貫は §12-11 で完了 |
| 8 | **`.app` バンドル化・署名**と `NotchHUD` | `Scripts/make-app.sh` で `.app` が組み上がり、Apple Development 証明書で署名され、`open` から起動する（基本設計書 §10）。**バンドルが先で、HUD はその上に載せる。** **V-19（`NSApp.run()` の下で `CGEventTap` が届くか）を真っ先に潰す。** 続いて V-16 / V-17 / V-18、V-6 の残り（実バンドル・本番構成での確認）、V-20 / V-21 / V-22 を実施する。**V-5 は閉じた**（DynamicNotchKit を採用しないため。§7.3） |
| 9 | 設定 UI・権限フロー・履歴 UI | FR-7〜FR-11 が満たされる。**設定画面・履歴画面・Undo の伝え方は View と ViewModel まで実装済み（§14）。残るのは提示の配線（ステータス項目のメニューと窓）だけで、これは HUD と同じ `AppSurface` を触るため統合時に行う。** **受け入れ条件「ホットキーの妥当性は `HotkeyBinding` 自身の不変条件として一括で検証する」はフェーズ 2 で満たした**——単体の不変条件は `HotkeyBinding` の初期化子（`Codable` の復元も通る）、PTT と Undo の関係は `Settings.validateHotkeys()` が持ち、**保存経路（`SettingsStore.update`）と復元経路（`Settings.init(from:)`）の両方から呼ぶ。** 手編集した `settings.json` も検査を通る（フェーズ 1 では `update` の経路にしか無かった。最終レビュー M-7） |
| 10 | 性能計測と調整 | **M5（現 M5a）は実測済み（現行の打ち切り 750 ms で 中央値 398 / 411 ms、p90 419 / 819 ms。§10）。ただし `.clipboardOnly` 経路に固定した計測であり、⌘V の往復と復元待ちを含む確定は V-3 待ち。V-7（メモリ）は未確認** |
| 11 | **CLI と一気通貫**（`ghost-voice`） | **完了（Task 11）。** 起動・権限案内・表示・終了の待ち合わせが動く。**FR-10 は部分達成**——権限の案内は達成、**モデル導入の案内は「導入が始まったことを 1 行出す」までで、進捗（`request.progress`）は出さない**（§4.3。進捗表示は HUD と一緒に §12-8 で行う）。`--check` / `--request-permissions` / `--mic-check` を用意した。**権限の要らない V-12 / V-13 / V-14 はここで実施した。V-3 / V-4 は権限の付与が要るため利用者が実施する**（README の手順） |

**フェーズ 2 の差し替え（FR-5(a) / FR-7。§8.3）は、上表の 9 と並ぶ位置に入る。**
着手の前に **V-23 / V-24 / V-25** を実測すること（§13）。**推定値の上に実装を積まない**
（開発サイクル §6）。**V-23 が全滅なら実装は空振りするが、挙動は現状と同じになる**ので、
先に測ることの費用は実測 1 回ぶんである。

**手順 2 と 3 の間に V-1（肉声での精度比較）を必ず実施する。** ここで `SpeechTranscriber` が優位と判明した場合、`SettingsStore.transcriberKind` の既定値を変更するだけで済む構造にしてある。

---

## 13. 検証項目一覧

| ID | 内容 | 実施時期 | 結果 |
|---|---|---|---|
| V-1 | 肉声での `DictationTranscriber` / `SpeechTranscriber` 精度比較 | 実装 §12-2 | **未完（肉声）**。合成音声のみ実施し CER 3.02 % vs 3.21 %（§11.2）。既定は `.dictation` を維持。肉声の録音が要るため保留 |
| V-2 | キー解放 → 認識確定の実測（NFR-P3） | 実装 §12-2 | **完了**。旧定義（解放後の最初の `final`）で 40〜177 ms / 中央値 約 70 ms（推定値 300 ms を置き換え）。**V-12 の修正で定義が「結果ストリームの終端」へ移ったため測り直した: 中央値 75.9 ms（低負荷）／ 82.5 ms（負荷下）、最大 155.1 ms**（§10）。**実マイクでの確認は V-31** |
| V-3 | 主要アプリでの AX 挿入成否 | 実装 §12-11 | **一部実施（2026-08-14 / 実機。要件定義書 §2.8.5）。取得経路の誤りで AX が一度も使われていなかったことが判明し、修正後にメモと Chrome アドレスバーで `ax` になった**（Chrome: `insert` 12〜34 ms・`total` 662〜891 ms で **NFR-P6（現 NFR-P6a）を初達成**／メモ: `insert` 307 ms）。**R-4（AX が成功を返しながら何も入らない）は未観測。** 残りのアプリ（メール / Slack / Notion / Xcode）は未実施。二段構えの実装と単体検査は完了。実挿入には AX API アクセス（`kTCCServiceAccessibility`）とキー送出（`kTCCServicePostEvent`）の**両方**が要り、無いと全アプリで `.inserted(.clipboardOnly)` になる。**CLI と手順は用意済み**（[README](../README.md) の「V-3 / V-4 の実施手順」、記入先は §11.3 の表）。**Task 11 の実装者は権限を付与できないため実施していない。** |
| V-4 | 右 Option 押しっぱなしの副作用 | 実装 §12-11 | **未実施（利用者の権限付与待ち）**。判定ロジックと `CGEventTap` の実装・単体検査は完了。実キー入力の観測には `CGEvent.tapCreate` が通ること（`kTCCServiceListenEvent` / 入力監視）が要り、無いと 1 件も配送されない。**CLI と手順は用意済み**（[README](../README.md) の「V-3 / V-4 の実施手順」、6 項目の表）。**あわせて実キーボードが左右のデバイスビット（`NX_DEVICERALTKEYMASK` 等）を立てることを確認する**（§2.3）。**Task 11 の実装者は権限を付与できないため実施していない。** |
| ~~V-5~~ | ~~DynamicNotchKit の表示先固定制御~~ | — | **閉じた（2026-08-14）。DynamicNotchKit を採用しないため問わない。** 自前の `NSPanel` で実装する裁定に変わった（§7.3 / 基本設計書 §8.3）。**検証したから閉じたのではなく、問いが消えたから閉じたことに注意** |
| V-6 | `.nonactivatingPanel` がフォーカスを奪わないこと | 実装 §12-8 | **一部実測（2026-08-14 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2 / 使い捨ての検証プログラム）。** **実測できたこと**: (a) `.borderless` + `.nonactivatingPanel` の `NSPanel` は `canBecomeKey` / `canBecomeMain` が既定で false、(b) `NSApp.run()` の**後**に `orderFrontRegardless()` すれば最前面アプリは変わらず `NSApp.keyWindow` / `mainWindow` も nil のまま、(c) `.accessory`（`LSUIElement` 相当）でも成立、(d) **`NSApp.run()` の前に出すとアプリが活性化して最前面が自分になる**（§7.2）。 **実装した HUD で測り直した（2026-08-15 / トラック C。§7.3 の「フォーカスを奪わないことの実測」）: 起動前・HUD 表示中・終了後を 0.25 秒ごとに観測して、最前面(layer0) が Ghost Voice になった回数は 2 回とも 0（32 回 / 28 回）。HUD の窓が layer 26 に現れることも外から観測した。** これは統合の申し送り 8（HUD を足した後のやり直し）にあたる。 **なお未実測**: 実バンドル（`Ghost Voice.app`）での確認、`CGEvent.post` による ⌘V 送出と同時に HUD が出ている状況、Space 切替・フルスクリーン（V-21）・Mission Control / Stage Manager 下 |
| V-7 | ウォームアップ常駐時のアイドルメモリ（NFR-S3） | 実装 §12-10 | 未実施 |
| V-8 | `SFCustomLanguageModelData` による固有名詞精度改善の可否 | LLM 整形で不足が判明した場合 | 未実施 |
| V-9 | **実マイクでの NFR-P1**（M1a のタップ武装、M1b の初回バッファ到達、タップ長の実際値） | 実装 §12-3 | **完了**。M1a 中央値 0.088〜0.118 ms（**達成**。**起動後の最初の 1 回だけ `begin()` の初回費用で 50 ms を超えていた件——低負荷 中央値 44 ms / 最大 540 ms、負荷下 中央値 64 ms——は、フェーズ 2 で起動時の捨て往復を入れて吸収した**。§10）、M1b 中央値 106.5〜106.7 ms（50 ms 不可）、タップ長 4800 フレーム＝100.0 ms（`bufferSize` 64〜4800 のどれでも同じ）、入力 48000 Hz / 1 ch、`prepare()` 327〜456 ms。**100 ms の下限は HAL（512 フレーム）ではなく `AVAudioEngine` のタップ実装**（§3.5 / §3.6） |
| V-11 | **タップ設置時点と最初のバッファ内容の先頭時刻のずれ**（既知信号を鳴らしながらタップを張り、最初のバッファの位相を見る） | 実装 §12-3（Task 10 の計測実装のついで） | **未実施。** 原理的に最大 1 I/O サイクル（512 フレーム ≒ 10.7 ms）の頭欠けが残りうる。実害は NFR-P1 の予算内 |
| V-10 | デバイス切断（`AVAudioEngineConfigurationChange`）の実挙動 | 実機での確認時 | **未実施。** 合成通知での再構成は検証済みだが、実際のデバイス抜き差しでは通知の到達スレッド・`isRunning` の状態・タップの残存が異なりうる |
| V-12 | **キー解放後に届く確定（`.final`）が 1 回とは限らないこと** | 実装 §12-11 → **修正はフェーズ 2** | **完了。危険な条件は肉声で再現し（2026-08-14 / 実機。要件定義書 §2.8.4。121 字・区切りの多い発話で末尾 約 38 字が失われた）、フェーズ 2 で塞いだ。** 修正: **確定待ちを「解放後の最初の確定」から「結果ストリームの終端」へ移した**（§10 の「M2 の定義を…」）。`apply(.final)` は積むだけで先へ進めず、待ちを解くのは `updatesEnded` と締め切りだけになった。**代役で「解放後に `.final` が 2 件届く」経路を決定的に駆動する単体検査を立ててある**（`DictationSessionTests.doesNotDropSecondFinalAfterRelease`。修正前は赤・修正後は緑）——**実音声ではこの条件を一度も起こせていない**ので、回帰を止められるのはこの検査だけである。代償は M2 の 約 11 ms 増（§10）。 以下は再現前に行った合成音声での実測である。**録音中に届く確定は落ちない**——`latestFinal` へ積まれるだけで先へ進まないため、今回観測した 2 件目はこの安全な側である。 フィクスチャ音声を**実時間で**流して `DictationSession` を通した実測（`Tests/GhostVoiceCoreTests/FinalAfterReleaseTests.swift`。権限は一切不要）: **103 秒**の読み上げで確定は計 **2 件（録音中 1 件・解放後 1 件）**、挿入 548 字 = 確定の総和 548 字。**30 秒**では確定 1 件（167 字）。録音中に届いた確定は `latestFinal` へ積まれ、解放後の 1 件で確定待ちが解ける。**「解放後に 2 件目」という危険な条件そのものは、この音声では再現しなかった**（＝否定されたのではなく、起きなかった）。**肉声・別のロケール・別の認識種別では起こりうる。** **この検査は既定の `swift test` では走らない**（**`GHOST_VOICE_V12_SECONDS=103` で実行する**。実時間の実認識が機体を飽和させ、時間閾値を持つ既存の検査 2 件が落ちたため既定には入れていない。`GHOST_VOICE_MEASURE` と同じ扱い）。**30 秒では確定が 1 件しか出ず、取りこぼしの経路を 1 度も通らない**（積み忘れの変異が生き残る）。**再実行は必ず 103 で行うこと。** いつ回すかは README の「V-3 / V-4 の実施手順」に書いた |
| V-15 | **アイドル時の CPU（NFR-P7 の 1 % 未満）** | **V-3 の実施時**（常駐起動が要る） | **未実施。** `AVAudioEngine` を起動したまま常駐する設計（§3.2）なので、**測るまで判らない**。`ghost-voice` を起動して `top -pid <pid>` を 1 分見る。要件定義書 §4.2 に目標値だけがあり、検証項目が無かった（開発サイクル §3 の適用漏れ。フェーズ 1 の最終レビュー M-3） |
| V-13 | **素の実行ファイル（`.app` バンドル無し）でマイクを開けるか** | 実装 §12-11 | **完了（Task 11）。** 開ける。`--mic-check` で 1 秒に 10 バッファ / 48000 フレーム（48000 Hz / 1 ch、取りこぼし 0）。バンドル ID は nil、署名も `Info.plist` も無い。**許可は責任プロセス（起動元のターミナルアプリ）に紐づく**（§3.3）。**要求（ダイアログ）だけは素のバイナリから出せないという §3.3 の実測はそのまま有効である** |
| V-14 | **音声認識の TCC（`kTCCServiceSpeechRecognition`）が要るか** | 実装 §12-11 | **完了（Task 11）。要らない。** `SFSpeechRecognizer.authorizationStatus()` が `.notDetermined` のまま `SpeechAnalyzer` の認識が通り、認識の前後で状態も変わらない（`recognizesWithoutSpeechRecognitionAuthorization`）。要件定義書 FR-10 / 必要権限、基本設計書 §10（権限とビルド構成。`NSSpeechRecognitionUsageDescription` も不要）、本書 §9 の照会表からも外した。**`--check` が音声認識を持たないのは実装漏れではない** |
| V-16 | **Apple Development 証明書で署名した `.app` の TCC 許可が、再ビルド・再署名の後も残ること** | 実装 §12-8 | **未実施。** **DR の文字列が再ビルド後も 1 文字も変わらないことは実測済み**（2026-08-14。基本設計書 §10）なので残ると強く期待できるが、**許可が実際に残るかは別問題であり未実測**。確かめるには 1 度権限を付与し、コードを変えて再ビルド → 再署名 → `open` で起動 → 4 項目を照会する。**許可の付与は利用者にしか行えない** **手順**: 許可を付けた後に `Scripts/make-app.sh` を走らせ直し、4 項目の照会値が変わらないことを見る。前提である「実コードを変えて再ビルドしても DR が 1 文字も変わらない」は**実測済み**（§9） |
| V-17 | **Hardened Runtime 下で `com.apple.security.device.audio-input` が無いとマイクを開けないこと** | 実装 §12-8 | **未実施。** entitlement が必要であること自体は Apple の仕様であり、**本プロジェクトでは実測していない。** entitlement 有り／無しの 2 バンドルを作り、マイク許可済みの状態で `--mic-check` 相当を走らせる 実施時期は任意（entitlements を削るときに） |
| V-18 | **`.app` を移動すると許可が無効になるか**（`~/Downloads` → `/Applications`） | 実装 §12-8 | **未実施。** 無効になるなら手順書で「先に `/Applications` へ置く」を必須にする 手順書は「置き場所を後から変えないこと」で回避している。無効になるなら手順書の警告を強める |
| V-19 | **`NSApp.run()` の下で `CGEventTap` のイベントが届くこと** | 実装 §12-8（**最初に潰す**） | **分解して一部を実測した（2026-08-14 / M3 / macOS 26.5.2 / 使い捨ての検証プログラム）。器の作り直しは不要。** 疑いの本体は「`NSApplication.run()` が `CFRunLoopGetMain()` を `.commonModes` で回すか」であってタップ固有ではないので、**タップを作らずに確かめた**——`CFMachPort` 由来の version 1 ソース（**タップと完全に同じ形**）/ version 0 ソース / タイマー / オブザーバの 4 系統、run() の前後どちらの登録でも、メニュー追跡中・モーダル中・`LSUIElement` の `.app` バンドル内でも発火。**陰性対照**（`.defaultMode` にだけ足したソース）は同条件で 0 回なので偽陽性ではない。配送遅延 p50 0.045 ms / 最大 5〜17 ms。**AppKit 下のコモン集合は既定・イベント追跡・モーダルパネルの 3 モードだけ**である（§7.2）。 **依然として未実施（利用者の実機待ち）: タップ固有の振る舞い。** `CGEvent.tapCreate` は入力監視の権限ダイアログを誘発するので一度も呼んでいない。**タップが実際にキーイベントを配送するか・`return nil` による抑止（ESC）が効くか・`.tapDisabledByTimeout` が出ないかは未実測である。** 届かなければ PTT がまったく動かない。手順は [README](../README.md) の「フェーズ 2: `Ghost Voice.app` への移行」の 7 |
| V-20 | **notch の切り欠きそのものに描いた内容が見えるか** | 実装 §12-8 | **未実施（利用者の目視待ち）。** 座標（内蔵で x 791..1012 / y 1131..1169）は実測で取れているが、そこはカメラハウジングであり**描いても見えない可能性が高い（推測）**。**実装は「見えなくても成立する」形にしてある**——中身をすべて切り欠きより下へ置き、帯の黒は連続して見せるためだけに使う（§7.3）。したがって**この検証の結果で実装は変わらない**（見えるなら帯が繋がって見え、見えないなら中身だけが見える）。**手順**: [README](../README.md) の「HUD の目視確認（`--hud-check`）」。`--hud-check` はマイクもキー監視も触らないので**権限が無くても実施できる** |
| V-21 | **`.canJoinAllSpaces` / `.fullScreenAuxiliary` が効くこと** | 実装 §12-8 | **未実施（利用者の実機待ち）。** Space を切り替え、他アプリをフルスクリーンにして目視する。Mission Control / Stage Manager 下も併せて見る。**指定してあること自体は検査で固定済み**（`HUDWindowContractTests`）だが、**効くかどうかは目視でしか判らない。** **手順**: [README](../README.md) の「HUD の目視確認（`--hud-check`）」。`--hud-check=60` のように長めに指定して、その間に Space を切り替える |
| V-22 | **クラムシェル（内蔵が `NSScreen.screens` に無い）ときの表示先** | 実装 §12-8 | **未実施（利用者の実機待ち）。** 蓋を閉じたときの `NSScreen.screens` の中身を確かめる。**候補 (a)(b) のどちらを採るかは決着済み**——どちらも採らず「主ディスプレイのメニューバー直下」にした（基本設計書 §8.1.1。理由もそこにある）。**この検証で見るのは、決めた形が実際に成立するか**である: 内蔵が消えること、主ディスプレイへ出ること、起動時の診断が「内蔵ディスプレイが見つかりません」と言うこと。**あわせて外部ディスプレイを主にしたときの内蔵の `auxiliaryTop*Area` も見る**（§7.1 の未実測）。**手順**: [README](../README.md) の「HUD の目視確認（`--hud-check`）」 |
| V-23 | **主要アプリで `kAXSelectedTextRange` が settable か。範囲の単位が UTF-16 か** | **§8.3 の実装より前**（V-3 の残作業と同じ回で取れる） | **未実施。** 対象はメモ / メール / Chrome アドレスバー / Chrome ページ内 / Slack / Notion / Xcode / ターミナル。`AXUIElementIsAttributeSettable` の実行時の答えだけが根拠になる（**SDK ヘッダの `Writable?` は当てにならない**——`kAXSelectedText` は `Writable? No` と書かれているのに、V-3 の実測では実際に書けている）。**ここが全滅なら差し替えは一度も成立しない**（挙動は現状と同じになるので、失うのは実装の工数だけ）。**権限を付与した利用者にしか実施できない** 実装は `AXStringForRange` の一致で自衛しているので、**外れても誤った位置には書かない**（全発話が「整形を待つ」分岐へ落ちるだけ）。手順は README「V-3 / V-4 の実施手順」の 5 |
| V-24 | **同じアプリで `AXStringForRange`（`kAXStringForRangeParameterizedAttribute`）が読めるか** | **§8.3 の実装より前** | **未実施。** 読めなければ §8.3 の手順 2 / 5 が成立せず、差し替え不可へ倒れる（NFR-V3 の例外を使う余地も無くなる）。**権限を付与した利用者にしか実施できない** **SDK に定数が存在することだけは確認済み（2026-08-14）で、アプリごとの対応状況は未実測。** 読めない相手では `.unreadable` が返り、差し替えは中止される |
| V-25 | **発話長と整形所要の関係**（20 / 40 / 60 / 80 / 120 字 × 各 10 回。低負荷と負荷下の 2 条件） | **§8.3 の実装より前**（**最初に取るとよい**） | **主要部を実測した（2026-08-15 / 配線トラック。§10 の「(a)/(b) の実分布と、発話長と整形所要の関係」）: 19 字 343〜378 ms / 36 字 652〜716 ms / 56 字 1016〜1067 ms、傾き 約 18.5 ms/字。NFR-P6b の目標 2 秒の根拠だった外挿はこれで支持された。** 残るのは 80 字以上の帯と、合成音声ではなく**肉声**での確認である。以下は実測前の記述: **NFR-P6b の目標 2 秒 / 打ち切り 3 秒は推定値であり、直接の根拠は「40 字以上の 8 件が 750 ms を超えた」（下限しか判らない）と `refine 791 ms` の 1 件しかない**（要件定義書 §2.8.4 (2)）。結果次第では (b) 分岐の打ち切り値も変わる。**マイクと Apple Intelligence があれば取れる**（AX の権限は要らない） |
| V-26 | **差し替えの事後検査で「消えただけ」が起きるか。IME の変換中に撃った場合も見る** | **§8.3 の実装直後** | **未実施。** **R-9。この設計で唯一「発話が欄から消えうる」経路であり、実在するなら設計を変える**（差し替えを既定オフにし、FR-5 は (b) 分岐だけで運用する）。捨ててよい入力欄で `source → replacement → source` を各 30 回行い、**消去のみ・部分置換・別範囲の更新が 0 件**であることを確かめる **あわせて挿入直後にキャレットが挿入文字列の直後へ来るかを見る**（錨の作り方の前提。外れると錨が作られないだけ）。**代役では 4 通り（正常 / 無言失敗 / 別内容 / 消えるだけ）を再現済みで、実機での発生の有無だけが未確認である** |
| V-27 | **競合させても必ず差し替えを断念できるか**（別アプリへ移動 / 別入力欄へ移動 / カーソル移動 / 記録範囲の前・中・後への追加入力） | **§8.3 の実装直後** | **未実施。** 一致条件を失った場合に**内容変更が 0 件**であること、生テキストが回収可能であることを見る。**手順 2 と 4 の間の競合窓は原理的に閉じられない**（AX に compare-and-swap が無い）ので、ここは「必ず閉じる」ではなく「どれだけ狭いか」を測る検証である **あわせて `CFEqual` による AX 要素の同一性が時間を跨いで期待どおりかを見る**（§6.5 の C-4。外れると「別の欄だ」と判定して中止に倒れるので**誤った欄へは書かない**。症状は「差し替えが一度も効かない」）。手順は README「V-3 / V-4 の実施手順」の 5 |
| V-28 | **(a)(b) 両分岐の `M5a`（NFR-P6a）と、差し替え経路の `M6` / `M7`（NFR-P6b）** | §8.3 の実装後 | **代役の挿入先に対しては実測済み（2026-08-15。(a) の M5a 中央値 38〜75 ms / (b) 393〜828 ms / M6 391〜722 ms。§10）。`M7` と実アプリでの M4 は依然として未実測。** 以下は実測前の記述: 5 / 18 / 40 / 80 / 121 字、低負荷 / 負荷下、AX / Pasteboard の各条件で測る。**新設計が NFR-P6a を満たすという判定は、この端から端の実測まで保留する**（既存の M5 実測との算術で代用しない） **`M7` は読み 3〜4 往復 + 書き 2 の実所要であり、錨の取得が挿入に上乗せする時間も併せて測る**——錨の取得は NFR-P6a のクリティカルパスに乗るので、上乗せが大きければ `AccessibilityInserter(capturesReplacementAnchor:)` を false にして切れる |
| V-29 | **差し替えの体感**（テキストが 1〜2 秒後に書き換わることの受容性）と、**利用者が続きを打ち始めるまでの時間** | §8.3 の実装後 | **未実施。** 前者は R-10（悪ければ `refinementApplyMode` を `beforeInsert` へ）、後者は **NFR-P6b の打ち切り 3 秒の本来の根拠**である |
| V-30 | **Pasteboard 経路で、限定読み戻しによって貼付を確認できるか** | §8.3 の実装後 | **未実施。** `CGEvent.post` は `Void` を返すので送出の事実からは何も言えないが（§6.3）、**貼り付いた範囲を読み戻して一致すれば配送を確認できる**可能性がある。確認できれば (a) の分岐をこの経路へ広げられる。**できないなら FR-7 はこの経路で成立しない**（要件定義書 §2.8.6 の裁定 6 のまま） |
| V-35 | **Undo キー（既定 ⌃⌘Z）を抑止したときの下流アプリへの影響** | FR-7 の実装後 | **未実施。** 抑止するのは押下だけで、**対になる解放は下流アプリへ届く**（マスクに `keyUp` を足すと全打鍵の配送量が倍になるため。§2.1）。文字キーの単独の解放を意味づけるアプリは稀という判断が実アプリで成り立つかは未実測。**抑止は「戻せる 10 秒窓の中」だけである**——窓の外で奪うと下流の Undo / Redo が理由も無く効かなくなるので、そこは通す（§8.3） |
| V-36 | **差し替えが PTT の押下と重なったときの M1a** | §8.3 の実装後 | **代役の欄に対しては実測済み**（2026-08-15。§10.1）。差し替えは actor の上で**同期に**走り、**AX を 12 回呼ぶ**（挿入は 16 回）。押下 → 録音開始は **中央値 1.3 ms / 最大 3.5 ms**（低負荷）、**中央値 2.3 ms / 最大 2.7 ms**（負荷下）。**配線ぶんは NFR-P1 の 50 ms を食わない。** 待たされる量はほぼ `12 × AX 1 往復 + 2 ms`。**残るのは実アプリでの 1 往復のコスト**で、V-28 と同じ回に取る |
| V-37 | **長い発話で `RefinementGuard` が正当な整形を捨てていないか** | §5.5.1 の見直しの前 | **閉じた**（2026-08-15。§5.5.1）。**疑いは外れていた**——旧指標は長い発話ほど**上がり**（19 字 0.933 → 124 字 0.991）、**5〜124 字の 9 例すべてで正当な整形は受け入れられていた**。A4 の 56 字は**音声を 10 秒で切って文の途中にした**ためにモデルが 40 字ぶんを捏造したもので、捨てたのは正しい。**代わりに逆向きの穴が見つかった**（指標が「足された語」に盲目で、36 字の捏造 +11 字が受け入れられていた）ので、**指標を作り直した** |
| V-31 | **実マイク・肉声での M2（現行定義: キー解放 → 結果ストリームの終端）と NFR-P3** | 利用者が実施（V-3 / V-4 と同じ機会） | **未実施。** 代役（フィクスチャ音声の実時間再生）での実測は 中央値 75.9 ms（低負荷）／ 82.5 ms（負荷下）、最大 155.1 ms（§10）。**保守的な上限 199 ms は NFR-P3（200 ms）の 1 ms 手前**だが、これは別々の計測の最悪値を足した値で、同時に起こることは確認していない。**121 字級の長い肉声で、暫定表示の末尾と挿入テキストの末尾が一致することを併せて見る**（V-12 の修正が実機で効いているかの確認）。手順は README の「V-3 / V-4 の実施手順」の 3 と同じ |
| V-32 | **起動直後に押した場合の M1a**（捨て往復の残りを待つ経路） | 利用者が実施（V-9 と同じ機会。`GHOST_VOICE_MIC_TESTS=1`） | **未実施。** 起動時の捨て往復は `finalizeTask` の枠に入れてあり、**起動直後の押下だけが `drainFinalizeTask()` でその残りを待つ**（§10）。捨て往復の各要素は測ってある（`begin()` 中央値 37.2 ms（低負荷）／ 158.5 ms（負荷下）、入力ゼロの `finish()` 中央値 0.33 / 0.73 ms）が、**M1a の計測区間（キー押下 → タップ武装）には実マイクが要る**ため、起動直後に押した実際の M1a は未計測である |
| V-33 | **ad-hoc 署名 + DR 固定（`-r='designated => identifier "…"'`）でも許可が残るか** | OSS 公開の前（証明書を持たない人の経路） | **未実施。** tccd が与えた DR をそのまま許可レコードの csreq に使うのか、独自に cdhash を含む要件を組み立てるのかが判っていない（`TCC.db` はフルディスクアクセスが無く読めない）。**残らないなら `--allow-adhoc` の警告文を「開発中の一時的な手段」に書き換える** |
| V-34 | **発話の途中の終了要求（⌘Q / SIGTERM）で発話が失われないか（`.app` 版）** | V-19 の後 | **未実施。** `applicationShouldTerminate` は `.terminateLater` を返し、`GhostVoiceCore.Shutdown.perform` が待機へ戻るまで待ってからホットキーを止める（**CLI と同じ 1 つの実装**。門を持たない分、待つ根拠は `isBusy` だけ）。**器だけの起動（`--shell-only`）では発話が無いのでこの経路を通らない。** 実発話で確認が要る |
| V-38 | **HUD の音量バーの振れ幅が肉声に合うか** | HUD の実機確認時 | **未実施。** 満振れとみなす RMS（`HUDLevelMeter.fullScaleRMS = 0.2`）は**実測値ではない**——肉声の RMS がどの範囲に収まるかを測っていない（マイクの許可が要る）。振れないか、すぐ振り切れるならこの数だけを直す。**外れても失うのは見た目だけ**である |
| V-39 | **HUD を出した状態での M1a / M2**（HUD の描画が PTT の反応を鈍らせていないか） | V-19 の後（マイクとキー監視の許可が要る） | **未実施。** ランループ検証で「**メインスレッドを塞ぐと配送が p50 0.045 ms → 12.8 ms へ悪化する**」ことは実測されている。HUD 側は間引き（50 ms）・変化が無ければ再描画しない・継続アニメーションを置かない、で**悪化させうる経路を塞いだだけ**であり、**実際に悪化していないことは測っていない。** 測り方は既存の M1a / M2 の計測を HUD ありで回して、HUD 無し（`--shell-only` 相当）と比べる |
| V-40 | **ディスプレイの抜き差しで HUD が付いていくか** | HUD の実機確認時 | **未実施。** `NSApplication.didChangeScreenParametersNotification` を購読して再配置する実装は入れてあるが、**通知が実際に来ることを確かめていない**（抜き差しの操作が要る）。来なければ HUD が古い座標に出続けるだけで、**挿入は壊れない。** 外部ディスプレイを抜き差しし、内蔵の切り欠きに出続けることを見る |
| V-41 | **notch 非搭載の内蔵ディスプレイでの表示先** | 該当機が手に入ったとき | **未実施。手元に機体が無い**（MacBook Air M1 / Intel 機 / 13" MBP）。**コード上は防御済み**——`CGDisplayIsBuiltin` で内蔵を選び、`auxiliaryTop*Area` が nil なのでメニューバー直下へ倒れる（代役での検査あり。`HUDPlacementTests`）。ただし**代役の値は推測であり、実機が同じ値を返すことは確かめていない** |
| V-42 | **設定画面で打鍵を捕まえられるか。`HotkeyMonitor` の `CGEventTap` と干渉しないか** | 打鍵捕獲の実装時 | **実装済み・一部実測（2026-08-15 / 配線トラック）。** 裁定どおり **2 本目のタップを立てず、既存の監視器を「捕獲モード」へ入れた**（§2.6）。**干渉しないことは構造で保証されている**——捕獲モードのイベントは `HotkeyDecision.decide` を 1 度も通らないので、**捕獲中に PTT / Undo / ESC の中断が発火しえない**（合成イベントで本物の `handle` を通す検査が固定）。**残る未実測は実キーボードでの捕獲そのもの**（`CGEvent.tapCreate` が通ることが要る。V-4 と同じ制約）: ①修飾キー単独（右 Option）を離した瞬間に捕まるか、②⌃⌘Z のような組が捕まるか、③捕獲中に他アプリへ打鍵が漏れないか。手順は [README](../README.md) の「設定画面（フェーズ 2 / FR-11）」 |
| V-43 | **窓を閉じてから前面が戻るまでの待ち方** | 履歴からの再挿入の配線時 | **実測して答えが出た。時間で待つのをやめ、事実で待つ形にした（2026-08-15 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2 / 内蔵ディスプレイのみ）。** ①**活性を見る実装では原理的に足りない**: `NSApp.hide(nil)` の直後には `NSApp.isActive` が既に false（`didResignActiveNotification` は 1 度も来ない＝待った気になるだけ）、`NSWorkspace.shared.frontmostApplication` も 0 ms で切り替わる。**それでもなお `kCGWindowLayer == 0` の最前面は 24〜32 ms のあいだ Ghost Voice のままだった**（n=3）——**遅れているのは活性の帳簿ではなく window server の窓の並びである。** ②**そこで挿入先の判定そのものを待つ**: `SystemAccessibility.frontmostProcessIdentifier()` を `public` にし（トラック D2 の申し送り 1）、**その値が自分の pid でなくなるまで 4 ms 間隔で照会する**（`AppWindow.waitUntilAnotherAppIsFrontmost`）。**150 ms の整定（`frontmostSettle`）は削除した**——あれは決めごとで、実測の上限ではなかった。③**やり直した実測**: `--window-check` で設定・履歴の窓を閉じてから決着するまで、**静穏時 16 / 17 / 21 / 17 / 19 / 22 ms（3 回・6 事象）、負荷下 17 / 15 / 16 / 12 ms（2 回・4 事象。load average 10.6〜24.5）。10 事象すべて `.returned` で、上限には 1 度も達していない。** 外の観測器（同じ規則で 4 ms 間隔）は、子が「戻った」と判定した 1〜4 ms 後に同じ入れ替わりを観測しており、**判定が事実より早く出ていないことが外から裏付けられている。** **負荷下は遅くならなかった**（事実を待つので、遅い機体でも待ちが伸びるだけである）。④**上限は 600 ms**（`frontmostHandbackTimeout`。**決めごと**。観測した最大 22 ms の約 27 倍）。**上限に達したら再挿入しない**——挿入先が Ghost Voice 自身になり、AX は自プロセスを弾き、Pasteboard 経路は ⌘V がどこにも刺さらないまま 300 ms 後にクリップボードを戻すので**行き先が 1 つも残らない。** 代わりにクリップボードへ退避し、**テキストがどこにあるかを告げる**（`ActionOutcome.reinsertAbandoned`。**発話はクリップボードと履歴の両方に残る**）。**残る未実測: 上限に達する経路そのもの**（10 事象で 1 度も再現していない。振る舞いは検査 `FrontmostHandbackTests.givesUpAtTheBound` / `HistoryViewModelTests` で固定してある） |
| V-44 | **`NSApp.hide(nil)` で前面が確実に戻るか** | 設定／履歴の窓を配線した後 | **実測して達成（2026-08-15 / 同上）。戻る。** `--window-check` で設定 → 履歴の順に開閉し、`kCGWindowLayer == 0` の最前面 pid を 4 ms 間隔で追った。**窓を出していない区間では 2,451 回の観測で 1 度も奪っていない**（HUD は layer 26）。**窓を開いた区間では意図どおり Ghost Voice が最前面になり、閉じると元のアプリ（起動前と同じ pid）へ戻った。** `--hud-check`（HUD を実際に表示した状態）でも **1,488 回で奪取 0 回。** **ただし戻るまでの遅れがある**（V-43）。**残る未実測: 実バンドル（`Ghost Voice.app`）での確認**——素の実行ファイルで測った |

---

## 14. 設定画面・履歴画面・Undo の伝え方（フェーズ 2 / FR-11 / FR-9 / FR-7 の UI）

**View と ViewModel だけがここにある。** 「どの窓・どのメニューから開くか」は
各 ViewModel の doc コメントに書いてあり、**配線は統合時に行う**（HUD トラックと
`AppSurface` の実装が重なるため、同時には触らない）。

置き場所は `Sources/GhostVoiceApp/Shell/Settings/` と `.../History/` である。
`GhostVoiceApp` ターゲットの `path` が `Sources/GhostVoiceApp/Shell` なので、
その配下でないとビルドにも検査にも入らない（`Package.swift`）。

### 14.1 「読めなかった」を利用者へ見せる（統括の裁定の条件）

不正なホットキーを 1 つ含むだけで `settings.json` は**丸ごと**復元されず、
**全設定が既定値へ戻る**（§8.1 / 要件定義書 §9.1）。この設計を採る条件は
「**設定画面がこの事実を利用者へ見える形にすること**」である。無言で既定へ戻ると、
フェーズ 1 で潰した「成功と記録されるのに中身が違う」と同じ形になる。

`StoreFileNotice` がその翻訳を担う。出すのは 3 つ。

| 出すもの | なぜ |
|---|---|
| **何が失われたか**（「ホットキー・言語・整形の設定が**すべて既定値に戻っています**」） | 「読めませんでした」だけでは、利用者から見える症状（`en-US` にしたのに日本語で認識される）と結び付かない |
| **元のファイルが今どこにあるか** | 下記のとおり、退避は**保存の瞬間**に起きる |
| **心当たり**（ホットキーの 3 つの規則） | 手で書いた人にその規則は見えていない。**規則そのものは Core が持つ**ので、ここにあるのは説明文であって検査ではない |

#### `.corrupt` への退避は「読み込み」ではなく「次の保存」で起きる

`AtomicJSONFile` は復元できなかったことを覚えておき、**次の `save` の直前に一度だけ**
`<name>.corrupt` へ逃がす（§8.2）。したがって画面の文言は状態で変わる。

| 状態 | 事実 | 画面が言うこと |
|---|---|---|
| `.pending` | **元のファイルはまだ元の場所にある** | 「保存すると `.corrupt` へ退避され、上書きされます。**保存する前に開いて内容を控えてください**」 |
| `.moved` | 退避済み | 「`.corrupt` へ退避してあります。直して戻せば復帰できます」 |

**判定は場所の有無ではできない。**
`.corrupt` の存在は退避済みを意味しない（前回の起動で退避された `.corrupt` が残った
まま、新しく壊れたファイルを置ける）。**元の場所にファイルが在ることも退避前を
意味しない**——保存すると、そこには健全なファイルが書き直されるからである。
そこで**読めなかった時点の中身を控えておき、それがどちらの場所に在るか**で決める。
判らないときは `.pending` へ倒す（「控えてください」と言い続ける方が、
「退避しました」と嘘を言うより害が小さい）。

**予告もしない。** どのファイルが退避されたかは、保存の**前後の状態を比べて観測**する。
`HistoryStore.setLimit` は内容が変わらなければ 1 バイトも書かないので、
予告すると「起きていない退避を退避しましたと告げる」ことになる。

### 14.2 保存の順序（3 と 4 の順に意味がある）

1. **ホットキーの検査**（`Settings.validateHotkeys()`。ディスクへ触らない）
2. **辞書の件数の検査**（同上）
3. **認識器の切り替え**（`DictationSession.prepareTranscriber`。ロケール／種別が変わったときだけ）
4. **ファイルへ書く**（設定と辞書を**まとめて 1 回**）
5. **履歴の上限を実行時へ反映**（`HistoryStore.setLimit`）
6. **Undo キーを監視器へ反映**（`rebindUndoHotkey`。保存しただけでは効かない）

**3 を 4 より前に置くのが要点である。** 後ろに置くと、認識器の切り替えに失敗したときに
「画面には `en-US` と出ているのに認識は `ja-JP`」という状態がディスクへ焼き付く。
**フェーズ 1 で潰した「成功と記録されるのに中身が違う」と同じ形**なので、
失敗したらファイルを 1 バイトも変えない。録音中（`DictationSessionError.busy`）も同じ扱いである。

代償は、**モデルの導入を伴う言語へ切り替えると保存が数分戻らない**こと。
進捗は `SessionMirror.installation` に出る。

### 14.3 並行性（Core の罠に対する形）

| 罠 | 画面側の形 |
|---|---|
| `SettingsStore.update` の `mutate` はロックを保持したまま走る（`NSLock` は非再帰）。**クロージャから `settings` を読むと自己デッドロック** | `try store.update { $0 = next }` の**丸ごと代入 1 行しか書かない。** 読む余地が構造として無い |
| `update` / `replace` は**同期の I/O**。MainActor から呼ぶとメインスレッドが止まり、**`CGEventTap` の配送が p50 0.045 → 12.8 ms へ悪化する**（実測） | `BackgroundWrite`（`@concurrent` を持つ唯一の地点）を必ず通す |
| `AsyncStream` は単一消費者 | 履歴の購読は `changes()` を **1 本、1 つのタスクで** `for await` する。`observe(_:)` のコールバックを通知ごとに `Task { @MainActor in … }` で持ち上げる書き方は**タスクの実行順が保証されず、古い一覧が後から届く**ので採らない |
| `HistoryStore.append` は MainActor から呼んではならない | **画面は履歴へ書かない。** 書くのは `DictationSession` だけである |

**「メインスレッドを塞がない」の検査が空振りでないことは実地で確かめた。**
本番の書き手を MainActor へ釘付けにする変異を入れると、狙った 2 件だけが赤くなる
（`SettingsConcurrencyTests`）。測る場所は**書き込みの地点そのもの**であって書き手の側ではない
——書き手の側で測ると、書き手が自分で選んだ文脈を自分で報告するだけになり、
**ViewModel がその書き手を使っているか**は何も示せない。

> **付随して判ったこと（2026-08-15 / 変異検査）**: この言語モードでは
> `nonisolated` な `async` 関数は `@concurrent` が無くても呼び出し元のアクターを離れる
> （`@concurrent` を外す変異では検査が赤くならなかった）。**`@concurrent` は現状では冗長だが残す**
> ——`nonisolatedNonsendingByDefault` が有効になると意味が変わり、そのとき黙って
> メインスレッドを塞ぐ側へ倒れるためである。

### 14.4 履歴画面（FR-9）

一覧・**再挿入**・コピー・削除・全消去。集計は §9.3 の規定どおり。

- **`.notInserted` を経路の集計の分母に入れない。** 中断された発話は `.ax` / `.pasteboard` /
  `.clipboardOnly` のどれも通っていない。**除いた件数は別に持って画面へ出す**——
  黙って落とすと、一覧の件数と集計の件数が合わない理由が判らなくなる。
- **secure input で拒否された発話は履歴に現れない**（そもそも作らない）。したがって
  **「挿入できなかった割合」をこの集計から出してはならない。**
- **`.notInserted` の発話も再挿入できる。** 一度も挿入されていないので、
  **再挿入がその発話の唯一の出口である**（§4 / `InsertionMethod.notInserted`）。
- **再挿入は窓を閉じて前面が戻ってから行う。** 窓が前面のままだと挿入先が
  Ghost Voice 自身になる。`HistoryView` は**閉じる口を渡されないと再挿入のボタンを
  出さない**——順序の間違いを構造で防ぐため。
- **「前面が戻ったか」は時間ではなく事実で判定する。** 待つ相手は
  **挿入先を決めるのとまったく同じ規則**（`SystemAccessibility.frontmostProcessIdentifier()`
  ＝ `kCGWindowLayer == 0` の最前面 pid）であり、**それが自分の pid でなくなるまで
  4 ms 間隔で照会する**（`AppWindow.waitUntilAnotherAppIsFrontmost`。実測 12〜22 ms / n=10。V-43）。
  **活性（`NSApp.isActive` / `NSWorkspace.frontmostApplication`）を見る実装では原理的に足りない**
  ——活性の帳簿は 0 ms で切り替わるが、window server の窓の並びは 24〜32 ms 遅れる。
- **上限は 600 ms（決めごと）。上限に達したら再挿入しない。**
  そこで進んでも挿入先は Ghost Voice 自身であり、**AX は自プロセスを弾き、Pasteboard 経路は
  ⌘V がどこにも刺さらないまま 300 ms 後にクリップボードを元へ戻す**
  ——つまり**「挿入しました」と出しながらテキストの行き先が 1 つも残らない。**
  代わりに**クリップボードへ退避し、テキストがどこにあるかを告げる**
  （`ActionOutcome.reinsertAbandoned`）。**発話はクリップボードと履歴の両方に残る。**
  クリップボードへも置けなかった場合は**残る出口が履歴だけであることを告げ、失敗として赤く出す。**
- **`reinsert` の `focus` 引数に既定値を置かない。** 置くと「待ったかどうか」を言わずに
  挿入でき、順序の間違いが型で防げなくなる（`FocusHandback`）。
- 履歴画面が使う挿入器は、発話の挿入に使うものとは**別のインスタンス**である
  （世代を共有しない）。したがって**再挿入は差し替えの錨を作らず、Undo の対象にならない。**
  再挿入は「もう一度打ち直す」操作であって発話の続きではない。

### 14.5 Undo をどう伝えるか（FR-7 の UI。**未決だったのでここで決めた**）

実行は Core にある（`DictationSession.performUndo`）。決めたのは伝え方だけである。

> **文言そのものも Core へ移した**（`SessionNoticeAnnouncement`。統括の裁定）。
> 以前は HUD（`HUDPresenter.announcement`）と Undo の UI（`UndoNarration`）の**2 箇所にあり、
> CLI には 1 箇所も無かった**——`ghost-voice` から Undo を撃つと顛末が何も出ない、という
> **フェーズ 1 で潰した「無言で失敗する」と同じ形**である。
> `SessionFailureNotice` を Core へ置いたのとまったく同じ理由である（§8.5）。
> **媒体が決めるのは色・保持時間・強調の書き方だけ**にした。
> `.undoCopiedRawTextToClipboard` だけは `isPersistent` を立ててあり、**時間で畳まない**
> （読み落とすとクリップボードに在る生テキストへ辿り着けない）。次の発話が始まれば消える。

**出口は HUD の 1 行にする。窓は開かない。通知センターも使わない。音も鳴らさない。**

- Undo はホットキーで撃たれる。**そのとき利用者は別のアプリで作業していて、
  Ghost Voice の窓を見ていない。** 窓を開くと `NSApp.activate()` が要り、最前面が
  Ghost Voice になる。すると次の発話の挿入先が Ghost Voice 自身になる——
  **「戻せない」と告げるために次の発話を壊す**ことになる。
- 通知センターを使わないのは、**常駐の HUD が既に画面上にあるのに出口を 2 つ作ると、
  どちらに出たかで見落としが起きる**ため（`SessionNotice` が文言も発話も持たない規律には触れない）。
- 主用途が会議中の発話なので、鳴らすと使えない。

**4 つの結末を 1 つの文言に潰さない。**

| 結末 | 利用者が次にすること | 潰すと何が起きるか |
|---|---|---|
| 戻した | 無し | — |
| **クリップボードへ取り出した** | **⌘V を押す** | 「戻せません」に潰すと、**クリップボードに在る生テキストへ辿り着けない**（UC-3 の縮退が死ぬ）。読み落とすと取り返しがつかないので、**これだけ自動で消さない** |
| 断念した | もう一度やるなら手で | **何も書き換えていない**ことは言う価値がある。潰すと「何か壊されたのでは」という疑いが残る |
| 戻せるものが無い | 次へ進む | 理由を出さないと **Undo が壊れていると思われる** |

**「戻せるものが無い」には理由の候補を必ず添える。** 10 秒という窓は画面のどこにも
出ていないので、**見えない締め切りで黙って断られるのがいちばん悪い。**
秒数は `HistoryStore.undoWindow` から取り、**画面側に `10` と書かない**（片方だけ変えると嘘になる）。

### 14.6 実測が要ると判っていた 3 件（**すべて測った / 2026-08-15**）

| 内容 | 結果 | 採番 |
|---|---|---|
| **設定画面で打鍵を捕まえられるか。`CGEventTap` と干渉しないか** | **干渉しない形で実装した**（§2.6）。2 本目のタップを立てず、捕獲モードのイベントは `HotkeyDecision.decide` を 1 度も通らない——**捕獲中に PTT / Undo / ESC の中断が発火しえない。** 残るのは実キーボードでの捕獲そのもの（`CGEvent.tapCreate` が通ることが要る） | **V-42** |
| **窓を閉じてから前面が戻るまでの待ち方** | **`didResignActiveNotification` では足りなかった。** `NSApp.hide(nil)` の直後には既に非活性で通知が来ず、**それでも最前面は 24〜32 ms のあいだ Ghost Voice のままだった。** 活性を待つ実装は「待った気になるだけ」だった。**いまは挿入先の判定（`SystemAccessibility.frontmostProcessIdentifier()`）を 4 ms 間隔で直接見て待つ。時間の整定は置いていない**（実測 12〜22 ms / n=10 / 静穏・負荷下とも） | **V-43** |
| **`NSApp.hide(nil)` で前面が確実に戻るか** | **戻る。** `--window-check` で 4 ms 間隔の観測。窓を出していない区間は 2,451 回で奪取 0 回、閉じた後は起動前と同じアプリへ戻った | **V-44** |

#### 14.6.0 「キー監視を開始できなかった」を誰が言うか（HUD と設定画面の棲み分け）

**両方が言う。ただし言うことが違う。**

| 出口 | 何を言うか | なぜそこか |
|---|---|---|
| **HUD**（起動時に 10 秒） | `AppPermissionGuidance.summary(for:)` の**1 行** | **`.app` を Finder から起動すると標準エラーはどこにも出ない。** キー監視が始まっていないことは HUD でしか見えない。**気づかせるための出口である** |
| **ステータスメニュー**（常設） | 「キー入力を監視できていません（設定を開く）」の 1 項目 | HUD の 10 秒を見逃した後でも、**押しても何も起きない**理由に辿り着ける |
| **設定画面** | `AppPermissionGuidance.message(for:)` の**全文**（システム設定のパス・許可の相手・再起動が要ること） | **直すための情報である。** notch の帯は実測 221 pt しかなく、パスは載らない |

**HUD を落とさない理由**は「設定画面は利用者が開かないと出ない」ことである。
「押しても何も起きない」に気づいた利用者が設定画面へ辿り着く保証は無い。
**重ねてよいのは、片方が「気づく」でもう片方が「直す」のときだけである**——
同じ文言を 2 か所へ出すのは（§8.5 が禁じている）別の話であり、ここは**粒度が違う。**

#### 14.6.1 窓の提示の配線（`StatusMenuSurface`）

「どの窓・どのメニューから開くか」は各 ViewModel の doc コメントにあり、**その指示どおりに配線した。**

| 指示 | 実装 |
|---|---|
| 開く口は `NSStatusItem` のメニュー | 設定… / 履歴… / 終了。**`LSUIElement = true` なのでここが唯一の入口である** |
| `RunLoopEntry` を受け取ってから窓を作る | `AppWindow` が鍵を要求する。**さらに、窓は利用者がメニューを選んだ瞬間に作る**（`AppSurface` の doc が「起動時に非表示の window を用意しておく実装は禁止」と定めているため） |
| 開くときは `NSApp.activate()`、閉じたら `NSApp.hide(nil)` | `AppWindow.present()` / `windowWillClose` / `dismissAndReturnFocus` |
| 再挿入は窓を閉じて前面が戻ってから | `HistoryView` へ閉じる口を渡す。**渡さなければボタンが出ない**設計はそのまま。**閉じる口は「前面が戻ったか」を返し**（`FocusHandback`）、それを `reinsert(_:field:focus:)` へそのまま渡す——`StatusMenuSurface` 側で判断しない |
| 窓が無い / 自身が既に解放されている場合 | **`.notReturned` へ倒す。**「戻ったことを確かめられなかった」を「戻った」と読み替えると挿入先が Ghost Voice 自身になる |

**`makeKeyAndOrderFront` を使ってよいのは `AppWindow` だけ**であり、HUD で使うことは
ソース走査で禁じてある（`HUDWindowContractTests`）。**HUD とこの窓は要件が正反対である**——
HUD は絶対に活性化させてはならず、この窓は活性化しないと設定を打ち込めない。

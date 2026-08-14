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
│   │   └── TextReviser.swift          フェーズ 2。差し替え（FR-5(a)）と Undo（FR-7）。§8.3
│   │                                  **1 ファイル・1 関数にする。向きが違うだけの操作を
│   │                                   2 か所に書くと、片方だけ直る事故が起きる**
│   ├── Models/
│   │   ├── HotkeyBinding.swift        キー定義とシリアライズ
│   │   ├── Settings.swift             設定（既定値の出所）
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
│   │   └── DictationSession.swift     状態機械（基本設計書 §4）
│   └── Support/
│       └── Metrics.swift              性能計測点
│                                      （権限の保持は Insertion/PasteboardInserter.swift の
│                                       PostEventAuthorization。独立した Permissions.swift は無い）
├── Sources/GhostVoiceCLI/             CLI の中身（**検査対象**）
│   ├── CommandLineOptions.swift       引数の解釈
│   ├── SessionNarration.swift         状態 → 表示行。stateUpdates の唯一の消費者
│   ├── PermissionGuidance.swift       権限の案内と --check の報告
│   ├── Shutdown.swift                 終了の待ち合わせ（発話を落とさない順序）
│   ├── ConsoleOutput.swift            出力先の差し替え口
│   └── GhostVoiceRuntime.swift        本物の依存を繋いで回すだけ
├── Sources/ghost-voice/main.swift     GhostVoiceRuntime.main() を呼ぶだけ
├── Tests/
│   ├── Fixtures/                      ゴールデンテスト用の原稿と音声（音声は非コミット）
│   └── GhostVoiceCoreTests/
│       ├── Support/                   CER・フィクスチャ読み込み
│       └── ...
├── Sources/GhostVoiceApp/             フェーズ 2 のアプリ（**Xcode プロジェクトは作らない**）
│   ├── GhostVoiceApp.swift            薄い @main。中身は下の UI 群へ
│   ├── UI/NotchHUD/
│   ├── UI/Settings/
│   └── UI/Permission/
├── Resources/                         フェーズ 2
│   ├── Info.plist                     テンプレート（基本設計書 §10）
│   └── GhostVoice.entitlements
├── Scripts/make-app.sh                フェーズ 2。`.app` の組み立てと codesign
└── docs/
```

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

**ホットキー設定（`Settings.hotkey`）が変わったときも作り直すこと。** `binding` は不変で、監視するイベント種別は `start()` 時に一度だけ決まる（§2.3 の `keyUp` の要否がバインドによって変わる）。既存の監視器に新しいバインドを反映する手段は無い。

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

`isModifierDown` はデバイスビットが引ければ `binding.modifiers` を参照しない。したがって `HotkeyBinding(keyCode: 0x3D, modifiers: [.option, .shift])`（⇧ + 右 Option）を設定しても、**右 Option 単独で発火する。** モデル側にこれを禁じる仕組みは無いので、**設定 UI（フェーズ 2 / §12-9）は修飾キー単独のバインドに追加の修飾キーを付けさせないこと。**

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

/// 二段構えの各段。
public protocol PrimaryInserting: Sendable {
    func canInsert() -> Bool
    func tryInsert(_ text: String) async -> Bool
}

/// 最後の砦。挿入が全滅したときに発話をクリップボードへ残す。
public protocol ClipboardLeaving: Sendable {
    @discardableResult func leave(_ text: String) -> Bool
}
```

実装はいずれも値型なので `AnyObject` は要求しない。

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
> スクリーンショットによる確認は画面収録の権限ダイアログを誘発するため調査時に行っていない。
> → **含意**: FR-2 の「notch 部分に表示する」は、**切り欠きの直下へ帯を張り出して視覚的に notch と連続させる**実装になる見込み。**実装初日に目視で確かめること。**

**そのほかの未実測**: 外部ディスプレイを主にしたときの内蔵の `auxiliaryTop*Area`（V-22 と同時に見る）、
notch 非搭載の内蔵ディスプレイの実測（該当機が手元に無い）、
`NSApplication.didChangeScreenParametersNotification` による抜き差し時の再計算。

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
活性化すると `AccessibilityInserter.frontmostProcessIdentifier()` が拾う最前面 pid が Ghost Voice 自身になり、**挿入先が壊れる**（§6.2）。

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

- `CGEventTapHotkeyMonitor` はソースを `CFRunLoopGetMain()` の `.commonModes` へ足す。`NSApp.run()` はメインの CFRunLoop を回すので**届くはず**だが、**未実測（V-19）。** タップ生成が入力監視の権限ダイアログを誘発しうるため調査では確かめていない。**フェーズ 2 の最初の検証項目にする。**
- **`NSApp.terminate(_:)` を素通しさせてはならない。** ⌘V 送出後・クリップボード復元前に落ちると発話が失われる（§6.3）。`applicationShouldTerminate` で `.terminateLater` を返し、`Shutdown.perform` を通してから `exit(0)` する。
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

### 7.4 表示内容

| 状態 | 内容 |
|---|---|
| `idle` | 非表示 |
| `recording` | 音量バー（`AudioCapturing.level` に連動）＋ 言語バッジ（日/EN）＋ 暫定テキスト（末尾 2 行、`.volatile` 更新ごとに差し替え） |
| `finalizing` / `refining` | インジケータ。`refining` では整形なし縮退時にバッジを出す |
| `revising` | **控えめな表示にとどめる**（挿入は既に終わっており、利用者は次の作業へ移っている）。**差し替えに失敗した場合だけ明示的に告げる**——特に R-9（喪失の疑い）は回収を促す必要がある（§8.3） |
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
}
```

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
- `historyLimit` 超過分は追記時に切り詰める。
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

> **Option キーを含めてはならない。** PTT キーの既定が右 Option であるため、⌥ を含むショートカットを押すと録音が始まってしまう。設定画面では、PTT キーと重複する修飾キーを含む組み合わせを Undo ホットキーとして登録できないようバリデーションする。

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
    func status(of kind: PermissionKind) -> PermissionStatus
    func request(_ kind: PermissionKind) async -> PermissionStatus
    func openSystemSettings(for kind: PermissionKind)
}
```

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

---

## 10. 性能計測（Metrics）

`DictationSession` の各遷移に計測点を置き、履歴と併せて記録する。

> **旧 `M5`（キー解放 → 挿入完了 = M2+M3+M4）は `M5a` へ改称し、意味が変わった。**
> 要件定義書 §2.8.6 の裁定により、1 秒（NFR-P6a）が守るのは
> **「整形済みテキスト」ではなく「まず使えるテキスト」**になったためである。
> 差し替え可能な分岐では **M3（整形）が M5a に入らない。**
> **既存の M5 実測（398 / 411 ms）と (a) の分岐の M5a を並べて比べてはならない**——測っている量が違う。
> `Metrics.Sample.total` / `meetsTarget`（`Support/Metrics.swift`）は現在も `M2 + M3 + M4` を返すので、
> **実装が (a) の分岐を持つ時点で、この 2 つの定義も直す必要がある**（実装は別トラック）。

| 計測 ID | 区間 | 目標 |
|---|---|---|
| `M1a` | キー押下 → **タップ武装**（取りこぼしが止まる時点） | 50 ms（NFR-P1）。**実測 中央値 0.088 ms（アイドル）／ 0.118 ms（負荷下）、最大 14.0 ms**。うち `begin()` は実測 1.2〜1.4 ms。**達成（V-9 実施済み）。プロセス最初の 1 回が別だった件は、起動時の捨て往復で吸収した**（下記。最初の発話が払う `begin()` は 中央値 1.00 ms（低負荷）／ 3.0 ms（負荷下）） |
| `M1b` | キー押下 → 最初のバッファ**到達** | **実測 中央値 106.7 ms（アイドル）／ 106.5 ms（負荷下）、最小 102.9 / 最大 139.8。50 ms では届かない。** `installTap` の粒度 100 ms が下限で、`bufferSize` では下げられない（§3.5）。**ハードウェアの制約ではなく `AVAudioEngine` の実装による**ので、`AVAudioSinkNode` なら 10.7 ms まで下げられる（採らない理由は §3.6）。M5a の内訳として扱う |
| `M2` | キー解放 → **結果ストリームの終端**（＝確定テキストが出そろう時点） | **実測 中央値 75.9 ms（低負荷）／ 82.5 ms（負荷下）、範囲 45.1〜155.1 ms**（各 8 回 / 2026-08-14 / MacBook Pro M3 / macOS 26.5.2）。**定義は V-12 の修正で「解放以降の最初の `final`」から移した**（下記）。旧定義の実測は 40〜177 ms / 中央値 約 70 ms（13 回。V-2）で、**上乗せは実測 10.3〜12.2 ms（低負荷）／ 2.0〜21.6 ms（負荷下）。保守的な上限は 約 199 ms**（別々の計測の最悪値の和。同時に起こることは未確認） |
| `M3` | `final` → 整形完了 | 目標 500 ms（NFR-P4）／**打ち切りは (b) の分岐で既定 750 ms、(a) の分岐で NFR-P6b**（下記）。**実測 中央値 355 ms（低負荷）／ 364 ms（負荷下、10 件中 2 件が 500ms 超）。ただしすべて 3 秒の発話での値で、発話長別の分布は未実測（V-25）** |
| `M4` | **挿入器の呼び出し → 復帰**（(a) では生テキスト、(b) では整形結果） | 50 ms（NFR-P5）。**実測 中央値 0 ms（両条件）。ただしこれは `.clipboardOnly` 経路に固定した計測で、⌘V の往復（33 ms）も復元待ち（120 ms）も含まない**（下記の留保 3 件） |
| **`M5a`** | **キー解放 → 最初のテキストが挿入先に現れる** | **1000 ms（NFR-P6a）。** (a) では M2 + M4、(b) では M2 + M3 + M4。**旧 `M5` の実測（`.clipboardOnly` 経路で 中央値 398 / 411 ms、p90 419 / 819 ms、全条件 10/10 達成）は (b) の分岐の値として読む。** (a) の分岐は**未実測（V-28）** |
| ~~`M5b`~~ | ~~キー解放 → 認識ストリームの終端~~ | **`M2` に吸収された（2026-08-14 の統合時）。** V-12 の修正で `M2` の定義そのものが「結果ストリームの終端」へ移ったため、`M5b` は `M2` と同じ量になった。**別 ID として残すと同じ量を 2 通りに測る**ので畳んだ。分布は `M2` の行にある |
| **`M6`** | キー解放 → **整形の反映（差し替え完了）** | **NFR-P6b（目標 2 秒 / 打ち切り 3 秒。どちらも推定値）。差し替え可能な経路のみ。未実測（V-28）** |
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

NFR-P6（1000 ms）の逆算は M2 の最悪値に依存する（下記「M5 の実測と…裁定」）。

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
> 上の予算計算（177 + 750 + 50 = 977 ms）は (b) では変わらないので、**既定値 750 ms も変えない。**
> **差し替えできる分岐（(a)）では、整形は M5a に入らない**ので、この打ち切りは使わず
> NFR-P6b（目標 2 秒 / 打ち切り 3 秒。**どちらも推定値**）で走る。
>
> **750 ms を「実用の発話長に足りる値」へ引き上げる道は採らなかった。** 実測で `total 1142 ms` と
> 既に NFR-P6（当時の定義。現 NFR-P6a）を超えており、待つ側の分岐にはもう余地が無いためである（要件定義書 §2.8.4 (2)）。

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
| **`TextReviser`（§8.3）** | **代役の AX で全ての中止点を通す**: 事前条件が欠ける / 事前検査が不一致 / 範囲設定が `AXError` / 書き込みが `AXError` / 事後検査が source のまま（無言失敗）/ 事後検査が第三の値（R-9）。**どの場合も ⌫ と ⌘V の追撃が 0 回であること**、R-9 でだけクリップボードへ退避して以後そのプロセスを締め出すこと、**成功時に履歴の同じ `id` が更新されること**。**Undo は同じ関数を逆向きに呼ぶだけであることを、検査でも 1 つの対象として扱う** |
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
| 9 | 設定 UI・権限フロー・履歴 UI | FR-7〜FR-11 が満たされる。**受け入れ条件に「ホットキーの妥当性は `HotkeyBinding` 自身の不変条件として一括で検証する」を含めること**——現状の衝突検査は `SettingsStore.update` の経路にしか無く、手編集した `settings.json` は検査を通らない（フェーズ 1 では undo ホットキーを使わないので実害が無く、意図的に繰り延べた。最終レビュー M-7） |
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
| V-6 | `.nonactivatingPanel` がフォーカスを奪わないこと | 実装 §12-8 | **一部実測（2026-08-14 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2 / 使い捨ての検証プログラム）。** **実測できたこと**: (a) `.borderless` + `.nonactivatingPanel` の `NSPanel` は `canBecomeKey` / `canBecomeMain` が既定で false、(b) `NSApp.run()` の**後**に `orderFrontRegardless()` すれば最前面アプリは変わらず `NSApp.keyWindow` / `mainWindow` も nil のまま、(c) `.accessory`（`LSUIElement` 相当）でも成立、(d) **`NSApp.run()` の前に出すとアプリが活性化して最前面が自分になる**（§7.2）。 **未実測**: 実バンドル（`Ghost Voice.app`）・本番の SwiftUI 構成での確認、`CGEvent.post` による ⌘V 送出と同時に HUD が出ている状況、Space 切替・フルスクリーン（V-21）・Mission Control / Stage Manager 下 |
| V-7 | ウォームアップ常駐時のアイドルメモリ（NFR-S3） | 実装 §12-10 | 未実施 |
| V-8 | `SFCustomLanguageModelData` による固有名詞精度改善の可否 | LLM 整形で不足が判明した場合 | 未実施 |
| V-9 | **実マイクでの NFR-P1**（M1a のタップ武装、M1b の初回バッファ到達、タップ長の実際値） | 実装 §12-3 | **完了**。M1a 中央値 0.088〜0.118 ms（**達成**。**起動後の最初の 1 回だけ `begin()` の初回費用で 50 ms を超えていた件——低負荷 中央値 44 ms / 最大 540 ms、負荷下 中央値 64 ms——は、フェーズ 2 で起動時の捨て往復を入れて吸収した**。§10）、M1b 中央値 106.5〜106.7 ms（50 ms 不可）、タップ長 4800 フレーム＝100.0 ms（`bufferSize` 64〜4800 のどれでも同じ）、入力 48000 Hz / 1 ch、`prepare()` 327〜456 ms。**100 ms の下限は HAL（512 フレーム）ではなく `AVAudioEngine` のタップ実装**（§3.5 / §3.6） |
| V-11 | **タップ設置時点と最初のバッファ内容の先頭時刻のずれ**（既知信号を鳴らしながらタップを張り、最初のバッファの位相を見る） | 実装 §12-3（Task 10 の計測実装のついで） | **未実施。** 原理的に最大 1 I/O サイクル（512 フレーム ≒ 10.7 ms）の頭欠けが残りうる。実害は NFR-P1 の予算内 |
| V-10 | デバイス切断（`AVAudioEngineConfigurationChange`）の実挙動 | 実機での確認時 | **未実施。** 合成通知での再構成は検証済みだが、実際のデバイス抜き差しでは通知の到達スレッド・`isRunning` の状態・タップの残存が異なりうる |
| V-12 | **キー解放後に届く確定（`.final`）が 1 回とは限らないこと** | 実装 §12-11 → **修正はフェーズ 2** | **完了。危険な条件は肉声で再現し（2026-08-14 / 実機。要件定義書 §2.8.4。121 字・区切りの多い発話で末尾 約 38 字が失われた）、フェーズ 2 で塞いだ。** 修正: **確定待ちを「解放後の最初の確定」から「結果ストリームの終端」へ移した**（§10 の「M2 の定義を…」）。`apply(.final)` は積むだけで先へ進めず、待ちを解くのは `updatesEnded` と締め切りだけになった。**代役で「解放後に `.final` が 2 件届く」経路を決定的に駆動する単体検査を立ててある**（`DictationSessionTests.doesNotDropSecondFinalAfterRelease`。修正前は赤・修正後は緑）——**実音声ではこの条件を一度も起こせていない**ので、回帰を止められるのはこの検査だけである。代償は M2 の 約 11 ms 増（§10）。 以下は再現前に行った合成音声での実測である。**録音中に届く確定は落ちない**——`latestFinal` へ積まれるだけで先へ進まないため、今回観測した 2 件目はこの安全な側である。 フィクスチャ音声を**実時間で**流して `DictationSession` を通した実測（`Tests/GhostVoiceCoreTests/FinalAfterReleaseTests.swift`。権限は一切不要）: **103 秒**の読み上げで確定は計 **2 件（録音中 1 件・解放後 1 件）**、挿入 548 字 = 確定の総和 548 字。**30 秒**では確定 1 件（167 字）。録音中に届いた確定は `latestFinal` へ積まれ、解放後の 1 件で確定待ちが解ける。**「解放後に 2 件目」という危険な条件そのものは、この音声では再現しなかった**（＝否定されたのではなく、起きなかった）。**肉声・別のロケール・別の認識種別では起こりうる。** **この検査は既定の `swift test` では走らない**（**`GHOST_VOICE_V12_SECONDS=103` で実行する**。実時間の実認識が機体を飽和させ、時間閾値を持つ既存の検査 2 件が落ちたため既定には入れていない。`GHOST_VOICE_MEASURE` と同じ扱い）。**30 秒では確定が 1 件しか出ず、取りこぼしの経路を 1 度も通らない**（積み忘れの変異が生き残る）。**再実行は必ず 103 で行うこと。** いつ回すかは README の「V-3 / V-4 の実施手順」に書いた |
| V-15 | **アイドル時の CPU（NFR-P7 の 1 % 未満）** | **V-3 の実施時**（常駐起動が要る） | **未実施。** `AVAudioEngine` を起動したまま常駐する設計（§3.2）なので、**測るまで判らない**。`ghost-voice` を起動して `top -pid <pid>` を 1 分見る。要件定義書 §4.2 に目標値だけがあり、検証項目が無かった（開発サイクル §3 の適用漏れ。フェーズ 1 の最終レビュー M-3） |
| V-13 | **素の実行ファイル（`.app` バンドル無し）でマイクを開けるか** | 実装 §12-11 | **完了（Task 11）。** 開ける。`--mic-check` で 1 秒に 10 バッファ / 48000 フレーム（48000 Hz / 1 ch、取りこぼし 0）。バンドル ID は nil、署名も `Info.plist` も無い。**許可は責任プロセス（起動元のターミナルアプリ）に紐づく**（§3.3）。**要求（ダイアログ）だけは素のバイナリから出せないという §3.3 の実測はそのまま有効である** |
| V-14 | **音声認識の TCC（`kTCCServiceSpeechRecognition`）が要るか** | 実装 §12-11 | **完了（Task 11）。要らない。** `SFSpeechRecognizer.authorizationStatus()` が `.notDetermined` のまま `SpeechAnalyzer` の認識が通り、認識の前後で状態も変わらない（`recognizesWithoutSpeechRecognitionAuthorization`）。要件定義書 FR-10 / 必要権限、基本設計書 §10（権限とビルド構成。`NSSpeechRecognitionUsageDescription` も不要）、本書 §9 の照会表からも外した。**`--check` が音声認識を持たないのは実装漏れではない** |
| V-16 | **Apple Development 証明書で署名した `.app` の TCC 許可が、再ビルド・再署名の後も残ること** | 実装 §12-8 | **未実施。** **DR の文字列が再ビルド後も 1 文字も変わらないことは実測済み**（2026-08-14。基本設計書 §10）なので残ると強く期待できるが、**許可が実際に残るかは別問題であり未実測**。確かめるには 1 度権限を付与し、コードを変えて再ビルド → 再署名 → `open` で起動 → 4 項目を照会する。**許可の付与は利用者にしか行えない** |
| V-17 | **Hardened Runtime 下で `com.apple.security.device.audio-input` が無いとマイクを開けないこと** | 実装 §12-8 | **未実施。** entitlement が必要であること自体は Apple の仕様であり、**本プロジェクトでは実測していない。** entitlement 有り／無しの 2 バンドルを作り、マイク許可済みの状態で `--mic-check` 相当を走らせる |
| V-18 | **`.app` を移動すると許可が無効になるか**（`~/Downloads` → `/Applications`） | 実装 §12-8 | **未実施。** 無効になるなら手順書で「先に `/Applications` へ置く」を必須にする |
| V-19 | **`NSApp.run()` の下で `CGEventTap` のイベントが届くこと** | 実装 §12-8（**最初に潰す**） | **未実施。** `CGEventTapHotkeyMonitor` はソースを `CFRunLoopGetMain()` の `.commonModes` へ足すので届くはずだが（§7.2）、**これは推測である。** 届かなければ PTT がまったく動かないので、フェーズ 2 の最初に確かめる |
| V-20 | **notch の切り欠きそのものに描いた内容が見えるか** | 実装 §12-8 | **未実施。** 座標（内蔵で x 791..1012 / y 1131..1169）は実測で取れているが、そこはカメラハウジングであり**描いても見えない可能性が高い（推測）**。実機で目視 1 分。見えなければ「切り欠きの直下へ張り出す」形に確定する（§7.1） |
| V-21 | **`.canJoinAllSpaces` / `.fullScreenAuxiliary` が効くこと** | 実装 §12-8 | **未実施。** Space を切り替え、他アプリをフルスクリーンにして目視する。Mission Control / Stage Manager 下も併せて見る |
| V-22 | **クラムシェル（内蔵が `NSScreen.screens` に無い）ときの表示先** | 実装 §12-8 | **未実施。** 蓋を閉じたときの `NSScreen.screens` の中身を確かめ、基本設計書 §8.1.1 の候補 (a)(b) のどちらを採るか決める。**あわせて外部ディスプレイを主にしたときの内蔵の `auxiliaryTop*Area` も見る**（§7.1 の未実測） |
| V-23 | **主要アプリで `kAXSelectedTextRange` が settable か。範囲の単位が UTF-16 か** | **§8.3 の実装より前**（V-3 の残作業と同じ回で取れる） | **未実施。** 対象はメモ / メール / Chrome アドレスバー / Chrome ページ内 / Slack / Notion / Xcode / ターミナル。`AXUIElementIsAttributeSettable` の実行時の答えだけが根拠になる（**SDK ヘッダの `Writable?` は当てにならない**——`kAXSelectedText` は `Writable? No` と書かれているのに、V-3 の実測では実際に書けている）。**ここが全滅なら差し替えは一度も成立しない**（挙動は現状と同じになるので、失うのは実装の工数だけ）。**権限を付与した利用者にしか実施できない** |
| V-24 | **同じアプリで `AXStringForRange`（`kAXStringForRangeParameterizedAttribute`）が読めるか** | **§8.3 の実装より前** | **未実施。** 読めなければ §8.3 の手順 2 / 5 が成立せず、差し替え不可へ倒れる（NFR-V3 の例外を使う余地も無くなる）。**権限を付与した利用者にしか実施できない** |
| V-25 | **発話長と整形所要の関係**（20 / 40 / 60 / 80 / 120 字 × 各 10 回。低負荷と負荷下の 2 条件） | **§8.3 の実装より前**（**最初に取るとよい**） | **未実施。** **NFR-P6b の目標 2 秒 / 打ち切り 3 秒は推定値であり、直接の根拠は「40 字以上の 8 件が 750 ms を超えた」（下限しか判らない）と `refine 791 ms` の 1 件しかない**（要件定義書 §2.8.4 (2)）。結果次第では (b) 分岐の打ち切り値も変わる。**マイクと Apple Intelligence があれば取れる**（AX の権限は要らない） |
| V-26 | **差し替えの事後検査で「消えただけ」が起きるか。IME の変換中に撃った場合も見る** | **§8.3 の実装直後** | **未実施。** **R-9。この設計で唯一「発話が欄から消えうる」経路であり、実在するなら設計を変える**（差し替えを既定オフにし、FR-5 は (b) 分岐だけで運用する）。捨ててよい入力欄で `source → replacement → source` を各 30 回行い、**消去のみ・部分置換・別範囲の更新が 0 件**であることを確かめる |
| V-27 | **競合させても必ず差し替えを断念できるか**（別アプリへ移動 / 別入力欄へ移動 / カーソル移動 / 記録範囲の前・中・後への追加入力） | **§8.3 の実装直後** | **未実施。** 一致条件を失った場合に**内容変更が 0 件**であること、生テキストが回収可能であることを見る。**手順 2 と 4 の間の競合窓は原理的に閉じられない**（AX に compare-and-swap が無い）ので、ここは「必ず閉じる」ではなく「どれだけ狭いか」を測る検証である |
| V-28 | **(a)(b) 両分岐の `M5a`（NFR-P6a）と、差し替え経路の `M6` / `M7`（NFR-P6b）** | §8.3 の実装後 | **未実施。** 5 / 18 / 40 / 80 / 121 字、低負荷 / 負荷下、AX / Pasteboard の各条件で測る。**新設計が NFR-P6a を満たすという判定は、この端から端の実測まで保留する**（既存の M5 実測との算術で代用しない） |
| V-29 | **差し替えの体感**（テキストが 1〜2 秒後に書き換わることの受容性）と、**利用者が続きを打ち始めるまでの時間** | §8.3 の実装後 | **未実施。** 前者は R-10（悪ければ `refinementApplyMode` を `beforeInsert` へ）、後者は **NFR-P6b の打ち切り 3 秒の本来の根拠**である |
| V-30 | **Pasteboard 経路で、限定読み戻しによって貼付を確認できるか** | §8.3 の実装後 | **未実施。** `CGEvent.post` は `Void` を返すので送出の事実からは何も言えないが（§6.3）、**貼り付いた範囲を読み戻して一致すれば配送を確認できる**可能性がある。確認できれば (a) の分岐をこの経路へ広げられる。**できないなら FR-7 はこの経路で成立しない**（要件定義書 §2.8.6 の裁定 6 のまま） |
| V-31 | **実マイク・肉声での M2（現行定義: キー解放 → 結果ストリームの終端）と NFR-P3** | 利用者が実施（V-3 / V-4 と同じ機会） | **未実施。** 代役（フィクスチャ音声の実時間再生）での実測は 中央値 75.9 ms（低負荷）／ 82.5 ms（負荷下）、最大 155.1 ms（§10）。**保守的な上限 199 ms は NFR-P3（200 ms）の 1 ms 手前**だが、これは別々の計測の最悪値を足した値で、同時に起こることは確認していない。**121 字級の長い肉声で、暫定表示の末尾と挿入テキストの末尾が一致することを併せて見る**（V-12 の修正が実機で効いているかの確認）。手順は README の「V-3 / V-4 の実施手順」の 3 と同じ |
| V-32 | **起動直後に押した場合の M1a**（捨て往復の残りを待つ経路） | 利用者が実施（V-9 と同じ機会。`GHOST_VOICE_MIC_TESTS=1`） | **未実施。** 起動時の捨て往復は `finalizeTask` の枠に入れてあり、**起動直後の押下だけが `drainFinalizeTask()` でその残りを待つ**（§10）。捨て往復の各要素は測ってある（`begin()` 中央値 37.2 ms（低負荷）／ 158.5 ms（負荷下）、入力ゼロの `finish()` 中央値 0.33 / 0.73 ms）が、**M1a の計測区間（キー押下 → タップ武装）には実マイクが要る**ため、起動直後に押した実際の M1a は未計測である |

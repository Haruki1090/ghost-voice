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
│   │   └── CompositeInserter.swift    二段構えの調停
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
├── App/GhostVoice/                    Xcode プロジェクト
│   ├── GhostVoiceApp.swift
│   ├── UI/NotchHUD/
│   ├── UI/Settings/
│   └── UI/Permission/
└── docs/
```

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
| **処理中（キー解放後）の ESC `keyDown`** | **しない** | **中断としては届けるが、抑止はしない。** 利用者はもう挿入先のアプリを操作しているので、ここで ESC を奪うと下流が壊れる（V-4 の #6）。中断が効く窓は基本設計書 §4 の 3 状態（`recording` / `finalizing` / `refining`）で、**監視器は `setSessionBusy` でその窓を知る** |
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

1. **90 ms の短縮は M5 の予算内で吸収できる。** M5（キー解放 → 挿入完了）の内訳は
   M2 40〜177 ms + M3 389〜518 ms + M4 50 ms = 479〜745 ms。ここに 100 ms を足しても
   予算 1000 ms に収まる。
2. **実時間スレッドでの確保はグリッチの原因になる。** `AVAudioSinkNode` のブロックは
   実時間制約下にあり、そこで `malloc` を伴う確保を毎秒 94 回行うのは違反である。
   正しくやるにはロックフリーのリングバッファが要る。**取りこぼし・途切れは
   「発話を失わない」原則に対して 100 ms の遅延よりはるかに重い被害**であり、
   その risk を今この段階で取る理由がない。
3. **失われるとしても最大 1 I/O サイクル（512 フレーム ≒ 10.7 ms）で、遅れの主因は配達である**（§10 の但し書き）。

**ただし逃げ道として記録しておく。** M5 が 1000 ms を割り込むなら、
**最初に引くレバーがこれ**である。90 ms は M3 の縮退（タイムアウト短縮）より安全に取り返せる。

**現時点でこのレバーは引いていない。** Task 10 の M5 実測は `.clipboardOnly` 経路で
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
- 履歴は**挿入完了後に**追記し、挿入のクリティカルパスに入れない（NFR-P6）。
- `historyLimit` 超過分は追記時に切り詰める。
- **書き込みの失敗は握り潰さない。** `DictationSession` は結果を見て `.failed(.historyUnavailable(insertedElsewhere:))` を出す。**中断された発話は履歴が唯一の写しなので、黙って落とすと発話ごと消える**（基本設計書 §7 の縮退表。フェーズ 1 の最終レビュー C-1）。挿入済みかどうかで文言を変えるのは、利用者にとって失うものが違うため（履歴と Undo だけ / 発話そのもの）。

**書き込みは同期である（実装の事実。当初「非同期で追記」と書いていたのを実測で置き換えた）。**
`DictationSession` は挿入を終えた後、actor を掴んだまま `HistoryStore.append` を呼ぶ。
非同期にしていないのは、書き込みが十分に速いからである。

**実測（`historyLimit` の 50 件を保持した最悪ケース・20 回）: p50 0.44 ms / 最大 0.87 ms / 最小 0.41 ms。**
上限まで埋まった状態で毎回 50 件を書き直しても 1 ms を切る。挿入は既に終わっているので
NFR-P6（発話終了 → 挿入完了）には入らず、影響するのは**次の押下**（M1a の 50 ms 予算）だけで、
その 1 % 未満に収まる。**書き込みを非同期にすると、次の発話の履歴と順序が入れ替わる余地が
生まれる**（`append` は先頭挿入なので順序が意味を持つ）ため、この速さなら同期のほうが安全である。

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

システム設定の一覧に `ghost-voice` は現れないので、**案内はターミナルアプリを名指しすること**
（`PermissionGuidance` がこれを固定している）。裏返すと、**別のターミナルアプリから起動すると
許可は付いてこない——ただしこれは上記の推論であって、実測していない。**
マイクが `.authorized` であることの実測は §3.3。

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

| 計測 ID | 区間 | 目標 |
|---|---|---|
| `M1a` | キー押下 → **タップ武装**（取りこぼしが止まる時点） | 50 ms（NFR-P1）。**実測 中央値 0.088 ms（アイドル）／ 0.118 ms（負荷下）、最大 14.0 ms**。うち `begin()` は実測 1.2〜1.4 ms。**達成（V-9 実施済み）。ただし下記のとおり、プロセス最初の 1 回だけは別である** |
| `M1b` | キー押下 → 最初のバッファ**到達** | **実測 中央値 106.7 ms（アイドル）／ 106.5 ms（負荷下）、最小 102.9 / 最大 139.8。50 ms では届かない。** `installTap` の粒度 100 ms が下限で、`bufferSize` では下げられない（§3.5）。**ハードウェアの制約ではなく `AVAudioEngine` の実装による**ので、`AVAudioSinkNode` なら 10.7 ms まで下げられる（採らない理由は §3.6）。M5 の内訳として扱う |
| `M2` | キー解放 → `final` 受信 | **実測 40〜177 ms**（中央値 約 70 ms / 13 回。V-2 実施済み。当初の推定値 300 ms を置き換えた）。**「解放以降の最初の `final`」で先へ進む定義**。**この定義の欠陥は肉声で再現した（2026-08-14 / 実機）**——121 字の発話で**末尾 約 38 字が失われた**。解放後に 2 件目が届けば、その分は読まれずに落ちる（§13 の V-12 / 要件定義書 §2.8.4）。合成音声 103 秒では起きなかっただけである |
| `M3` | `final` → 整形完了 | 目標 500 ms（NFR-P4）／**打ち切りは既定 750 ms**（下記の裁定）。**実測 中央値 355 ms（低負荷）／ 364 ms（負荷下、10 件中 2 件が 500ms 超）** |
| `M4` | 整形完了 → 挿入完了 | 50 ms（NFR-P5）。**実測 中央値 0 ms（両条件）。ただしこれは `.clipboardOnly` 経路に固定した計測で、⌘V の往復（33 ms）も復元待ち（120 ms）も含まない**（下記の留保 3 件） |
| `M5` | キー解放 → 挿入完了（M2+M3+M4） | **1000 ms（NFR-P6）。`.clipboardOnly` 経路で 中央値 398 ms（低負荷）／ 411 ms（負荷下）、p90 419 / 819 ms、全条件 10/10 達成（Task 10 実施済み）。⌘V を含む経路は未計測で、計算上の最悪値は 1080 ms。要件の達成は未確定（下記「M4 について」／ V-3 待ち）** |

### M1 を 2 つに分けた理由（Task 7 の実測）

初版は M1 を「キー押下 → 最初のバッファ供給」1 本で定義していたが、**この定義では 50 ms を満たせない。**
`installTap` のバッファ長には下限があり、48 kHz では 1024 を要求しても 4800 フレーム（100 ms）ぶきざみでしか
届かない。**`bufferSize` を 64 まで下げても変わらない**（§3.5 に実 HAL の掃引結果）。

ただし**遅れの主因は「配達」であって取りこぼしではない。** 取りこぼしが止まる時点＝タップ武装（M1a）と、
配達の遅れ（M1b）を分けて扱う。NFR-P1 が守るべきは M1a である。

### 起動後の最初の `begin()` だけは 50 ms を超えうる（実測 / 2026-08-14 / Task 11）

`begin()` の実測 1.2〜1.4 ms は**ウォーム後の値**である。**プロセスで最初の 1 回は別の量になる。**

| 条件 | 1 回目 | 2 回目以降 |
|---|---|---|
| 低負荷（load average 5.2〜6.0） | 中央値 **44.2 ms** / 最小 39.3 / **最大 540.4**（n=8） | 中央値 1.6 ms / 最大 3.2（n=16） |
| 負荷下（`yes` 16 本、load average 13） | 中央値 **64.5 ms** / 最小 55.6 / 最大 195.7（n=5） | 中央値 2.2 ms / 最大 5.8（n=10） |

**負荷下では中央値で NFR-P1 の予算 50 ms を超えた。** `warmUp()` は `prepare()` までしか行わず
`begin()` を呼ばないので、**この費用は起動後の最初の発話が払う。** 2 回目以降は 3 桁小さい。

実害は「起動して最初の 1 回だけ、録音の始まりが数十 ms 遅れる（最悪 0.5 秒）」である。
**取りこぼしは発話の頭に出る。** 対策を採るなら `warmUp()` で `begin()` → `finish()` を
1 往復させて捨てる形になるが、**解析器を 1 つ余計に作る副作用がある**（§4.3.1 の寿命の議論）ので、
フェーズ 2 の起動シーケンスで判断する。**フェーズ 1 では事実を記録するにとどめる。**

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

**当初の既定タイムアウト 500ms の余裕は、設計調査時の中央値 0.386 秒ベースの見積もりより
はっきり薄かった。負荷下では中央値 0.461 秒（余裕 39 ms）で、500ms を超える発話が実際に出る。**
超えても生テキストへ縮退するので壊れはしないが、**整形が効かない発話の割合が
見積もりより高くなる。** これが下記の裁定（既定を 750 ms へ）の出発点である。

実運用では認識と整形は同時に走らないが、**ユーザーの他アプリが機体を使っている状況は
これに近い**。

### M5 の実測と、既定タイムアウトを 750 ms へ引き上げた裁定（Task 10）

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

**NFR-P6（1000 ms）は `.clipboardOnly` 経路でどの条件でも 10/10 で達成している。**
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
> 打ち切り位置は NFR-P6 の予算から逆算する。実測の最悪値で M2 が 177 ms（V-2 の 13 回計測）、
> M4 の予算が NFR-P5 の 50 ms なので、整形に割ける上限は **773 ms**。750 ms なら
> 177 + 750 + 50 = **977 ms** で NFR-P6 に収まる。
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
177 + 750 + (33 + 120) = **1080 ms** となり NFR-P6 を超える。ただし
**ユーザーにテキストが見えるのはその 120 ms 前**であり、体感の M5 は 960 ms である。
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
`.final` を受け取るまで（13 回計測）。`DictationTranscriber` / `.progressiveShortDictation` /
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
| `DictationSession` | 代役を差し込んで PTT 1 回ぶんの流れを検査する。**発話が落ちうる箇所を名指しで押さえること**: `begin()` → タップの順序、`stopTap()` の末尾が `finish()` より前に供給されること、確定が `.final` の到着で進むこと、録音中の確定で進まないこと、確定が来なくても暫定テキストへ縮退すること、secure input が整形の手前で効くこと、中断でも履歴に残ること、最大録音時間で抜けること、キャンセル文脈でも確定処理が完走すること |

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
| 7 | `DictationSession`（状態機械） | **状態機械と計測は完了（Task 10）。M5 を 2 条件で実測し、整形の既定タイムアウトを 750 ms へ引き上げた（§10）。** CLI での一気通貫は §12-11 で完了 |
| 8 | `NotchHUD` | **V-5 / V-6 を実施する** |
| 9 | 設定 UI・権限フロー・履歴 UI | FR-7〜FR-11 が満たされる。**受け入れ条件に「ホットキーの妥当性は `HotkeyBinding` 自身の不変条件として一括で検証する」を含めること**——現状の衝突検査は `SettingsStore.update` の経路にしか無く、手編集した `settings.json` は検査を通らない（フェーズ 1 では undo ホットキーを使わないので実害が無く、意図的に繰り延べた。最終レビュー M-7） |
| 10 | 性能計測と調整 | **M5 は実測済み（現行の打ち切り 750 ms で 中央値 398 / 411 ms、p90 419 / 819 ms。§10）。ただし `.clipboardOnly` 経路に固定した計測であり、⌘V の往復と復元待ちを含む確定は V-3 待ち。V-7（メモリ）は未確認** |
| 11 | **CLI と一気通貫**（`ghost-voice`） | **完了（Task 11）。** 起動・権限案内・表示・終了の待ち合わせが動く。**FR-10 は部分達成**——権限の案内は達成、**モデル導入の案内は「導入が始まったことを 1 行出す」までで、進捗（`request.progress`）は出さない**（§4.3。進捗表示は HUD と一緒に §12-8 で行う）。`--check` / `--request-permissions` / `--mic-check` を用意した。**権限の要らない V-12 / V-13 / V-14 はここで実施した。V-3 / V-4 は権限の付与が要るため利用者が実施する**（README の手順） |

**手順 2 と 3 の間に V-1（肉声での精度比較）を必ず実施する。** ここで `SpeechTranscriber` が優位と判明した場合、`SettingsStore.transcriberKind` の既定値を変更するだけで済む構造にしてある。

---

## 13. 検証項目一覧

| ID | 内容 | 実施時期 | 結果 |
|---|---|---|---|
| V-1 | 肉声での `DictationTranscriber` / `SpeechTranscriber` 精度比較 | 実装 §12-2 | **未完（肉声）**。合成音声のみ実施し CER 3.02 % vs 3.21 %（§11.2）。既定は `.dictation` を維持。肉声の録音が要るため保留 |
| V-2 | キー解放 → 認識確定の実測（NFR-P3） | 実装 §12-2 | **完了**。40〜177 ms / 中央値 約 70 ms（推定値 300 ms を置き換え。§10） |
| V-3 | 主要アプリでの AX 挿入成否 | 実装 §12-11 | **未実施（利用者の権限付与待ち）**。二段構えの実装と単体検査は完了。実挿入には AX API アクセス（`kTCCServiceAccessibility`）とキー送出（`kTCCServicePostEvent`）の**両方**が要り、無いと全アプリで `.inserted(.clipboardOnly)` になる。**CLI と手順は用意済み**（[README](../README.md) の「V-3 / V-4 の実施手順」、記入先は §11.3 の表）。**Task 11 の実装者は権限を付与できないため実施していない。** |
| V-4 | 右 Option 押しっぱなしの副作用 | 実装 §12-11 | **未実施（利用者の権限付与待ち）**。判定ロジックと `CGEventTap` の実装・単体検査は完了。実キー入力の観測には `CGEvent.tapCreate` が通ること（`kTCCServiceListenEvent` / 入力監視）が要り、無いと 1 件も配送されない。**CLI と手順は用意済み**（[README](../README.md) の「V-3 / V-4 の実施手順」、6 項目の表）。**あわせて実キーボードが左右のデバイスビット（`NX_DEVICERALTKEYMASK` 等）を立てることを確認する**（§2.3）。**Task 11 の実装者は権限を付与できないため実施していない。** |
| V-5 | DynamicNotchKit の表示先固定制御 | 実装 §12-8 | 未実施 |
| V-6 | `.nonactivatingPanel` がフォーカスを奪わないこと | 実装 §12-8 | 未実施 |
| V-7 | ウォームアップ常駐時のアイドルメモリ（NFR-S3） | 実装 §12-10 | 未実施 |
| V-8 | `SFCustomLanguageModelData` による固有名詞精度改善の可否 | LLM 整形で不足が判明した場合 | 未実施 |
| V-9 | **実マイクでの NFR-P1**（M1a のタップ武装、M1b の初回バッファ到達、タップ長の実際値） | 実装 §12-3 | **完了**。M1a 中央値 0.088〜0.118 ms（**達成**。ただし**起動後の最初の 1 回だけは `begin()` の初回費用で 50 ms を超えうる**——低負荷 中央値 44 ms / 最大 540 ms、負荷下 中央値 64 ms。§10）、M1b 中央値 106.5〜106.7 ms（50 ms 不可）、タップ長 4800 フレーム＝100.0 ms（`bufferSize` 64〜4800 のどれでも同じ）、入力 48000 Hz / 1 ch、`prepare()` 327〜456 ms。**100 ms の下限は HAL（512 フレーム）ではなく `AVAudioEngine` のタップ実装**（§3.5 / §3.6） |
| V-11 | **タップ設置時点と最初のバッファ内容の先頭時刻のずれ**（既知信号を鳴らしながらタップを張り、最初のバッファの位相を見る） | 実装 §12-3（Task 10 の計測実装のついで） | **未実施。** 原理的に最大 1 I/O サイクル（512 フレーム ≒ 10.7 ms）の頭欠けが残りうる。実害は NFR-P1 の予算内 |
| V-10 | デバイス切断（`AVAudioEngineConfigurationChange`）の実挙動 | 実機での確認時 | **未実施。** 合成通知での再構成は検証済みだが、実際のデバイス抜き差しでは通知の到達スレッド・`isRunning` の状態・タップの残存が異なりうる |
| V-12 | **キー解放後に届く確定（`.final`）が 1 回とは限らないこと** | 実装 §12-11 | **完了。危険な条件は肉声で再現した（2026-08-14 / 実機。要件定義書 §2.8.4）。121 字・区切りの多い発話で末尾 約 38 字が失われた。「発話を失う」欠陥としてフェーズ 2 で塞ぐ。** 以下は再現前に行った合成音声での実測である。 **解放後に 2 件目の確定が届けば、その分の文字は今も落ちる**（`completeUtterance` は解放後の最初の確定で待ちを解き、そこで `latestFinal` を**同期的に**読む。以後に積まれた確定は二度と読まれない）。**録音中に届く確定は落ちない**——`latestFinal` へ積まれるだけで先へ進まないため、今回観測した 2 件目はこの安全な側である。 フィクスチャ音声を**実時間で**流して `DictationSession` を通した実測（`Tests/GhostVoiceCoreTests/FinalAfterReleaseTests.swift`。権限は一切不要）: **103 秒**の読み上げで確定は計 **2 件（録音中 1 件・解放後 1 件）**、挿入 548 字 = 確定の総和 548 字。**30 秒**では確定 1 件（167 字）。録音中に届いた確定は `latestFinal` へ積まれ、解放後の 1 件で確定待ちが解ける。**「解放後に 2 件目」という危険な条件そのものは、この音声では再現しなかった**（＝否定されたのではなく、起きなかった）。**肉声・別のロケール・別の認識種別では起こりうる。** **この検査は既定の `swift test` では走らない**（**`GHOST_VOICE_V12_SECONDS=103` で実行する**。実時間の実認識が機体を飽和させ、時間閾値を持つ既存の検査 2 件が落ちたため既定には入れていない。`GHOST_VOICE_MEASURE` と同じ扱い）。**30 秒では確定が 1 件しか出ず、取りこぼしの経路を 1 度も通らない**（積み忘れの変異が生き残る）。**再実行は必ず 103 で行うこと。** いつ回すかは README の「V-3 / V-4 の実施手順」に書いた |
| V-15 | **アイドル時の CPU（NFR-P7 の 1 % 未満）** | **V-3 の実施時**（常駐起動が要る） | **未実施。** `AVAudioEngine` を起動したまま常駐する設計（§3.2）なので、**測るまで判らない**。`ghost-voice` を起動して `top -pid <pid>` を 1 分見る。要件定義書 §4.2 に目標値だけがあり、検証項目が無かった（開発サイクル §3 の適用漏れ。フェーズ 1 の最終レビュー M-3） |
| V-13 | **素の実行ファイル（`.app` バンドル無し）でマイクを開けるか** | 実装 §12-11 | **完了（Task 11）。** 開ける。`--mic-check` で 1 秒に 10 バッファ / 48000 フレーム（48000 Hz / 1 ch、取りこぼし 0）。バンドル ID は nil、署名も `Info.plist` も無い。**許可は責任プロセス（起動元のターミナルアプリ）に紐づく**（§3.3）。**要求（ダイアログ）だけは素のバイナリから出せないという §3.3 の実測はそのまま有効である** |
| V-14 | **音声認識の TCC（`kTCCServiceSpeechRecognition`）が要るか** | 実装 §12-11 | **完了（Task 11）。要らない。** `SFSpeechRecognizer.authorizationStatus()` が `.notDetermined` のまま `SpeechAnalyzer` の認識が通り、認識の前後で状態も変わらない（`recognizesWithoutSpeechRecognitionAuthorization`）。要件定義書 FR-10 / 必要権限、基本設計書 §10（権限とビルド構成。`NSSpeechRecognitionUsageDescription` も不要）、本書 §9 の照会表からも外した。**`--check` が音声認識を持たないのは実装漏れではない** |

# Ghost Voice

macOS 26 のオンデバイス音声認識（`SpeechAnalyzer`）と `FoundationModels` だけで動く、
ローカル完結の音声ディクテーションツール。**音声は一切外部へ送信されず、ディスクにも書かれない。**

右 Option を押している間だけ録音し、離すとカーソル位置へ挿入する。

> **整形をいつ反映するかは、フェーズ 2 の裁定で変わった**（要件定義書 §2.8.6）。
> **差し替えできる挿入先では、生テキストを先に挿入してから整形結果へ差し替える。**
> 差し替えできない挿入先では従来どおり整形を待ってから挿入する。
> **どちらの場合も、整形が間に合わなければ生テキストがそのまま残る。**
> **この差し替えはフェーズ 2 で実装・配線済みである**（機構は `TextReplacer`、
> 配線は `DictationSession`）。**実アプリに対する挙動は未実測**なので、
> 手順は下の「V-23 / V-24 / V-26 / V-27」と「V-28 / V-35 / V-36 / V-37」にある。

> **右 Option が無いキーボードの場合。** 日本語配列の MacBook 本体キーボードには、
> スペース右が「かな・command・fn」で**右 Option が存在しない配列がある**（要件定義書 L-8）。
> その場合は **システム設定 > キーボード > キーボードショートカット… > 修飾キー** で
> **caps lock を Option へ転用する**こと。**転用した caps lock は右 Option（`keyCode: 61`）
> として報告される**ので、設定を変えずにそのまま PTT キーになる（実測）。
>
> **これは妥協ではなく、右 Option より望ましい。** caps lock は日本語配列でほぼ使わないので、
> 「PTT キーを押しながら文字を打つと `å` が入る」（R-1）が実質的に起こらない。
>
> **`fn` と（転用前の）caps lock は使えない。** どちらも左右を区別するデバイス依存ビットを
> 報告しないため、押しっぱなしの判定が成立しない。

## 動作要件

- macOS 26.0 以降
- Apple Silicon（M1 以降）
- 整形機能には Apple Intelligence の有効化が必要（**無効でも生テキストの挿入で動作する**）
- 日本語モデル（システム設定 > 一般 > 言語と地域 に日本語があれば導入される）

## 使い方

```bash
swift build -c release
.build/release/ghost-voice --check          # 権限の状態を見る（何も許可を求めない）
.build/release/ghost-voice --request-permissions   # 足りない許可を求める（ダイアログが出る）
.build/release/ghost-voice                  # 常駐して待ち受ける
```

| オプション | 内容 |
|---|---|
| （なし） | 常駐して PTT ディクテーションを行う |
| `--check` | 権限と設定ファイルの場所を表示する。**許可は求めない。** 揃っていなければ終了コード 1 |
| `--request-permissions` | マイク・入力監視・アクセシビリティの許可を求める（ダイアログが出る） |
| `--mic-check` | マイクを 1 秒だけ開き、実際にバッファが届くかを見る。**録音内容は保存しない** |
| `--paste-restore-delay-ms <ミリ秒>` | ⌘V 送出後にクリップボードを戻すまでの待ち（既定 **300 ms**。`PasteboardInserter.defaultRestoreDelay` が正） |
| `--help`, `-h` | 使い方 |

常駐中の表示（標準エラー）:

```
[録音中] きょうはいい天気
[確定中]
[整形中]
[挿入中]
[metrics] finalize 70ms / refine 400ms / insert 5ms / total 475ms OK
```

- **ESC** で中断する。効くのは**録音中と、キーを離した後の確定・整形中**まで
  （挿入が始まった後は手遅れとして完走させる。止めると ⌘V の送出後にテキストが消えるため）。
  中断しても録音済みの内容は履歴へ残り、挿入だけを行わない。
  **録音中の ESC は挿入先アプリへ渡さないが、キーを離した後の ESC は通す**（アプリの操作を奪わない）
- **Ctrl-C** で終了する。**進行中の発話は最後まで見届けてから終了する**（挿入の途中でプロセスを
  落とすと、⌘V の送出後・クリップボードの復元前で消えてテキストがどこにも残らないため）

## Ghost Voice.app（フェーズ 2）

常駐アプリ（Dock に出ない `LSUIElement`）を組み立てる。**コマンド 1 本で完結する。**

```bash
Scripts/make-app.sh                  # ビルド → .app の組み立て → 署名。.build/app/Ghost Voice.app ができる
Scripts/make-app.sh --allow-adhoc    # 署名用の証明書が無い環境向け（**権限が保たれない**。下記）
Scripts/make-app.sh --help
```

`.xcodeproj` は作らない。SwiftPM の実行ファイルをスクリプトが `.app` へ組み立てる
（`swift build` / `swift test` の走らせ方を変えないため）。

> **署名は Apple Development 証明書で行う（既定）。ad-hoc は既定にしない。**
> ad-hoc 署名の designated requirement は cdhash 単体で、**実装を 1 行変えて再ビルドしただけで
> 別のアプリとして扱われる**。TCC の許可は designated requirement に紐づくので、
> ad-hoc のままだと**ビルドのたびに権限を付け直す**ことになる。
> 証明書で署名すれば、実コードを変えて再ビルドしても designated requirement は 1 文字も変わらない（実測）。
> 証明書はキーチェーンにあるものが自動で使われる（`security find-identity -v -p codesigning`）。

| 起動引数 | 内容 |
|---|---|
| （なし） | 常駐して PTT ディクテーションを行う。足りない権限があれば要求を出す（**ダイアログが出る**） |
| `--shell-only` | **器だけを起動する。** マイクもキー監視も一切触らないので TCC のダイアログが出ない。フォーカスや配置の確認用 |
| `--no-permission-prompts` | セッションは動かすが、権限の要求は出さない |
| `--hud-check` / `--hud-check=秒` | **HUD の表示を一巡させて自分で終了する。** マイクもキー監視も触らない（**権限が無くても実施できる**）。既定は 12 秒。下記「HUD の目視確認」 |
| `--window-check` / `--window-check=秒` | **設定・履歴の窓を順に開いて閉じ、自分で終了する。** マイクもキー監視も触らない。既定は 12 秒。**フォーカスの受け渡しを測るための入口である**（下記「窓のフォーカスの確認」） |

```bash
open ".build/app/Ghost Voice.app"                          # 通常起動
open ".build/app/Ghost Voice.app" --args --shell-only      # 器だけ
open ".build/app/Ghost Voice.app" --args --hud-check=60    # HUD の目視確認（60 秒）
open ".build/app/Ghost Voice.app" --args --window-check=16 # 窓のフォーカスの確認
```

起動時の案内（権限の 4 項目など）は**標準エラーと unified log の両方**へ出る。
Finder から起動すると標準エラーはどこにも出ないので、こちらで読む:

```bash
log show --last 5m --info --predicate 'subsystem == "com.haruki1090.GhostVoice"' --style compact
```

## 窓のフォーカスの確認（`--window-check`）

**窓を出したことで挿入先が壊れていないか**を測る入口である。見るのは 3 つ。

| # | 区間 | 期待 |
|---|---|---|
| 1 | 窓を出していない間（メニューバーの項目と HUD だけ） | **最前面が Ghost Voice にならない。** なったら、その状態の発話はすべて Ghost Voice 自身へ挿入される |
| 2 | 設定・履歴の窓を開いている間 | **Ghost Voice が最前面になる**（これは意図どおり。利用者が自分で開いた窓である） |
| 3 | 窓を閉じた後 | **元のアプリへ最前面が戻る。** 戻らないと次の発話が Ghost Voice 自身へ入る |

測り方は「`kCGWindowLayer == 0` の最前面 pid を外から観測する」——
**挿入先の判定（`AccessibilityInserter.frontmostProcessIdentifier()`）とまったく同じ規則である。**

**実測（2026-08-15 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2 / 内蔵ディスプレイのみ）**

- 区間 1: **2,451 回の観測で 1 度も奪っていない**（HUD は layer 26 に載る）。
  `--hud-check` でも **1,488 回で 0 回**（HUD が実際に表示されている状態）。
- 区間 3: **戻る。** ただし `NSApp.hide(nil)` でアプリの活性が切り替わってから、
  **最前面の窓が入れ替わるまでにさらに 24〜32 ms 掛かる**（n=3）。
  **活性の通知（`didResignActiveNotification`）を待つ実装では足りない**——
  その通知は 1 度も来ず（既に非活性なので）、待った気になるだけだった。
  いまは 150 ms の整定を置いてあり、**再挿入は最前面が入れ替わった後に走る。**

## HUD の目視確認（`--hud-check`）

**HUD について、目でしか確かめられないことが 5 つ残っている。** どれもコードでは判定できないので、
**実機で見て、結果をこの README ではなく `docs/03-detailed-design.md` §13 の該当行へ書き込む**こと。

```bash
open ".build/app/Ghost Voice.app" --args --hud-check=60
```

**この引数はマイクにもキー入力の監視にも触れない。** セッションを組み立てないので、
**権限を 1 つも付けていない状態でも実施できる**（そうでないと「HUD が出ないのは権限のせいか実装のせいか」が切り分けられない）。
指定した秒数のあいだ、録音中・処理中・完了・エラーなど**すべての表示を順に出し続け、終わると自分で終了する。**

まず、どこへ出したかがログに 1 行出る。**これが出ていなければ HUD は作られていない。**

```bash
log show --last 2m --info --predicate 'subsystem == "com.haruki1090.GhostVoice"' --style compact | grep HUD
# 例: [HUD] 表示先: 内蔵ディスプレイ(id 1) / 切り欠きの直下（notch x 791.0, y 1131.0, w 221.0, h 38.0） / 上辺 y=1169.0 中心 x=901.5
```

### 見るもの

| # | 検証項目 | やること | 見るところ |
|---|---|---|---|
| 1 | **V-20**（切り欠きに画素があるか） | そのまま notch を見る | 切り欠きの**左右にメニューバーが見えたまま**、切り欠きの**直下に黒い帯**が出ているか。**切り欠きの中が黒く繋がって見えるか、切り欠きの中は何も見えず帯だけが見えるか、どちらであるかを書く。** どちらでも実装は変えない（中身はすべて帯より下に描いてある） |
| 2 | **V-21**（全 Space / フルスクリーン） | 60 秒で起動し、その間に **Space を切り替える / 別のアプリをフルスクリーンにする / Mission Control を開く / Stage Manager を入れる** | **HUD が出続けるか。** 消えるものがあればどれかを書く |
| 3 | **V-22**（クラムシェル） | 外部ディスプレイを繋ぎ、**蓋を閉じて**から実行する（外部キーボードが要る） | 上記のログが「**内蔵ディスプレイが見つかりません**」と言い、主ディスプレイの**メニューバーの直下**に帯が出るか。**メニューバーの項目を隠していないか** |
| 4 | **V-40**（抜き差し） | 実行中に**外部ディスプレイを抜き差しする** | HUD が**内蔵の切り欠きに出続けるか**（外部を挿した瞬間にそちらへ移ってしまわないか）。ログの `[HUD] 表示先:` が増えるか |
| 5 | **FR-3**（表示先の固定） | 外部ディスプレイを繋ぎ、**外部を主ディスプレイにして**（システム設定 > ディスプレイ > 配置 でメニューバーを外部へ移す）実行する | HUD が**内蔵側**に出ること。外部に出たら FR-3 違反である |

### 音量バー（V-38。権限を付けた後に見る）

**満振れとみなす音量（RMS 0.2）は実測値ではない。** 実際に喋って:

- バーがまったく振れない → 数を小さくする
- 常に 5 本とも点いたまま → 数を大きくする

直す場所は `Sources/GhostVoiceApp/Shell/HUD/HUDWindowContract.swift` の `HUDLevelMeter.fullScaleRMS` 1 箇所だけである。

### HUD がフォーカスを奪っていないことの確認（すでに実測済み。やり直すとき用）

**HUD は挿入先のフォーカスを奪ってはならない。** 奪うと挿入先が Ghost Voice 自身になり、テキストがどこにも入らなくなる。
2026-08-15 に実測済み（詳細設計書 §7.3）だが、window を足したり level を変えたりしたら**必ずやり直すこと。**
見方は「`kCGWindowLayer == 0` の最前面ウィンドウの pid が Ghost Voice にならないこと」で、
これは `AccessibilityInserter` が挿入先を決めるときとまったく同じ規則である。

## 必要な権限

**フェーズ 1（CLI `ghost-voice`）とフェーズ 2（`Ghost Voice.app`）で、許可を与える相手が変わる。**
どちらも「許可は責任プロセスに付く」という同じ規則の帰結である。

| 起動するもの | 許可を与える相手 | システム設定の一覧に出る名前 |
|---|---|---|
| `ghost-voice`（素の実行ファイル） | **起動元のターミナルアプリ** | ターミナルアプリの名前（`ghost-voice` は現れない） |
| `Ghost Voice.app` | **Ghost Voice 自身**（`open` 起動時の親は launchd） | `Ghost Voice` |

**`.app` はターミナルアプリの許可を 1 つも引き継がない**（実測。詳細設計書 §9）。
フェーズ 1 の利用者は 4 つとも付け直しになる → 下の「フェーズ 2: `Ghost Voice.app` への移行」。

### フェーズ 1（CLI）の場合

**許可の対象は `ghost-voice` ではなく、これを起動しているターミナルアプリである。**
素の実行ファイルの TCC 権限は責任プロセス（起動元のアプリ）に紐づくので、
システム設定の一覧に `ghost-voice` は現れない。**別のターミナルアプリへ移ると許可も付いてこない**
（TCC の一般的な挙動からの推論。許可を外す実験は行っていないので実測ではない。詳細設計書 §9）。

| 権限 | ペイン | 無いとどうなるか |
|---|---|---|
| マイク | プライバシーとセキュリティ > マイク | 押しても録音が始まらない |
| 入力監視 | プライバシーとセキュリティ > 入力監視 | **右 Option の押下を受け取れない**（起動時に案内が出て終了する） |
| アクセシビリティ | プライバシーとセキュリティ > アクセシビリティ | AX 直接挿入と ⌘V の送出ができず、テキストはクリップボードに残るだけになる |

音声認識（`SFSpeechRecognizer`）の許可は**要らない**。`SpeechAnalyzer` はこの TCC を要求しない
（`SFSpeechRecognizer.authorizationStatus()` が `notDetermined` のまま認識できることを実測で確認）。

許可を与えたら、**ターミナルアプリを再起動してから** `--check` で確認すること。

### フェーズ 2（`Ghost Voice.app`）の場合

| 権限 | ペイン | 一覧に載せる方法 | 無いとどうなるか |
|---|---|---|---|
| マイク | プライバシーとセキュリティ > マイク | **初回起動時のダイアログで完結する** | 押しても録音が始まらない |
| 入力監視 | プライバシーとセキュリティ > 入力監視 | アプリが要求を出すと一覧に載る。**トグルは手で入れる** | **右 Option の押下を受け取れない**（PTT がまったく反応しない） |
| アクセシビリティ | プライバシーとセキュリティ > アクセシビリティ | 同上 | AX 直接挿入ができない |
| キー送出 | プライバシーとセキュリティ > アクセシビリティ | 上と同じトグル | ⌘V を送れず、テキストはクリップボードに残るだけになる |

> **アクセシビリティのトグル 1 つの裏に TCC のレコードは 2 つある**（`kTCCServiceAccessibility` と
> `kTCCServicePostEvent`）。片方だけ有効な状態は原理的にありうるので、アプリは 2 つを別々に照会して案内する。

## 設定

`~/Library/Application Support/GhostVoice/settings.json`（無ければ既定値で動く）

| キー | 既定値 | 説明 |
|---|---|---|
| `hotkey` | 右 Option（`keyCode: 61`, `modifiers: ["option"]`） | PTT キー。**右 Option が無い配列では caps lock を Option へ転用する**（冒頭の注記。設定は変えなくてよい） |
| `undoHotkey` | ⌃⌘Z | Undo キー。**自動で戻せるのは差し替えできる挿入先だけ**で、それ以外では生テキストをクリップボードへ取り出す動作に縮退する（要件定義書 FR-7 の細目）。**このキーを奪うのは「戻せる 10 秒間」だけである**——それ以外の時間は下流のアプリへそのまま通るので、アプリ自身の Undo / Redo は効いたままである |
| `localeIdentifier` | `ja-JP` | 認識言語 |
| `transcriberKind` | `dictation` | `dictation` / `speech`。日本語では `dictation` が優位（実測 CER 3.02 % 対 3.21 %） |
| `refinementEnabled` | `true` | LLM 整形の有効化 |
| `refinementTimeoutMs` | `750` | **整形の打ち切り時間。目標値（NFR-P4 の 500 ms）とは別の数**（詳細設計書 §10）。**フェーズ 2 以降、この値が効くのは「差し替えできない挿入先」と `refinementApplyMode: "beforeInsert"` を選んだ場合だけである**（要件定義書 §2.8.6）。**据え置きの根拠は実測にある**——19 字 約 350 ms / 36 字 約 680 ms / 56 字 約 1040 ms（2026-08-15。詳細設計書 §10）。上げると 1 秒（NFR-P6a）を破り、下げると実運用に近い 36 字の帯が整形されなくなる |
| `historyLimit` | `50` | 履歴の保持件数 |
| `refinementApplyMode` | `afterInsert` | **整形をいつ反映するか。** `afterInsert` = **生テキストを先に挿入し、整形が返ってから同じ場所を書き換える**（既定。テキストが出るまでの時間が発話長に依存しなくなる）。`beforeInsert` = 常に整形を待ってから挿入する（フェーズ 1 と同じ挙動）。**テキストが後から書き換わる挙動が気になる場合は `beforeInsert` にすれば完全に戻せる** |
| `revisionDeadlineMs` | `3000` | **整形の反映（差し替え）の打ち切り。** `refinementTimeoutMs` とは効く場所が違う——こちらは**生テキストが既に挿入先にある**状態での待ちなので、超えても失うのは「整形が反映されないこと」だけである |

> **`refinementApplyMode` と `revisionDeadlineMs` はフェーズ 2 で増えたキーである。**
> フェーズ 1 が書いた `settings.json` にこの 2 つが無くても、そのまま読める（既定値で埋まる）。

**ホットキーは書けば何でも通るわけではない。** 次の 2 つは読み込みの時点で弾かれ、
**その設定ファイルは丸ごと復元されない**（既定値で起動し、元のファイルは
`settings.json.corrupt` へ退避される。起動時の 1 行と `--check` が読めなかったことを告げる）。

- **修飾キー単独のキーに、そのキー以外の修飾キーを付ける**（例: `keyCode: 61` に
  `["option", "shift"]`）。判定側は追加の修飾キーを見ないので、**⇧ を押していなくても
  右 Option 単独で録音が始まる**——設定が黙って無視される状態になるため（詳細設計書 §2.3）。
  修飾キーを空（`[]`）にするのも同じ理由で弾く。
- **`undoHotkey` に PTT キーと重なる修飾キーを含める**（既定の PTT が右 Option なので、
  ⌥ を含む Undo キーがこれに当たる）。押すと Undo ではなく録音が始まる。

### 設定画面（フェーズ 2 / FR-11）

**`settings.json` を手で編集しなくても、設定画面から同じ項目を変えられる**（`Ghost Voice.app`）。

**開き方**: メニューバー右側のマイクのアイコン（`Ghost Voice`）→ **設定…**。
`LSUIElement = true` なので Dock にもアプリメニューにも出ない。**ここが唯一の入口である。**
同じメニューから **履歴…** と **Ghost Voice を終了** も選べる。

画面は次の 5 つを、JSON の直接編集ではできない形で助ける。

- **ホットキーを打鍵で設定できる。** 「変更…」を押してからキーを押す。
  修飾キーだけ（右 Option など）は**離した瞬間**に、修飾キー + 文字キー（⌃⌘Z など）は
  **文字キーを押した瞬間**に決まる。**ESC で取りやめる。**
  - **捕獲のあいだ、PTT も Undo も ESC の中断も発火しない**（キーを設定しようとして
    録音が始まらないようにするため）。画面に「いま打鍵を待っています」と出る。
  - **2 本目のキー監視を立てていない。** 既存の監視を「捕獲モード」へ入れる形なので、
    設定画面を開いていない間の打鍵の費用は 1 μs も増えない（詳細設計書 §2.5）。
  - **保存すると、その場で監視器へ反映される**（再起動は要らない）。
    保存しないと反映されない——設定画面を閉じただけでは変わらない。
  - **ESC を PTT に割り当てたい場合だけは `settings.json` の手編集が要る**
    （捕獲では ESC は「取りやめ」に使うため）。
- **ユーザー辞書を編集できる。** 正しい表記と、**誤認識されやすい表記**（`/` 区切り）を
  その場で足し引きできる。誤認識表記は FR-6（誤認識の修正）の入力そのものである。

- **読めなかったことを黙らない。** 上の規則に触れる `settings.json` は丸ごと復元されず
  全設定が既定値へ戻るが、画面は「**何が既定へ戻ったか**」「**元のファイルが今どこにあるか**」
  「**心当たり（ホットキーの 3 つの規則）**」を出す。
  **退避（`settings.json.corrupt`）は読み込みではなく次の保存で起きる**ので、
  退避される前は「**保存する前に開いて内容を控えてください**」と言う。
- **言語を変えると認識器を作り直す。** 作り直しに失敗した場合や発話の処理中だった場合は、
  **ファイルを 1 バイトも変えない**（「画面には `en-US`、認識は `ja-JP`」を作らないため）。
  モデルが未導入の言語へ切り替えると、導入のあいだ保存が数分戻らない。
- **保存する前に、PTT キーと Undo キーの衝突を出す。** 判定は復元経路とまったく同じ入口を使う。

### 履歴画面（フェーズ 2 / FR-9）

直近 N 件を一覧し、**整形前／挿入したテキストのコピー**と**再挿入**ができる。

- **中断（ESC）した発話は挿入経路を 1 つも通っていない**ので、経路の集計（AX / Pasteboard /
  クリップボードのみ）の分母から外してある。**除いた件数は画面に出る。**
  中断した発話にとっては**再挿入がその発話の唯一の出口である。**
- **再挿入は履歴の窓を閉じてから行う**（窓が前面のままだと、挿入先が Ghost Voice 自身になる）。
  ボタンを押すと、窓を閉じる → 前面が戻るのを待つ → 挿入する、の順で走る。
  **前面が戻らなかった場合はその旨を告げる**（黙って Ghost Voice 自身へ入れない）。
  > **実測（2026-08-15 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2）**: `NSApp.hide(nil)` で
  > アプリの活性はその場で切り替わるが、**最前面の窓が入れ替わるまでにさらに 24〜32 ms 掛かる。**
  > その隙に挿入すると Ghost Voice 自身へ入るので、150 ms の整定を置いてある。

固有名詞は `vocabulary.json` に登録すると整形時に補正される。

```json
[{ "canonical": "Ghost Voice", "misheard": ["ゴーストボイス", "ごーすとぼいす"] }]
```

履歴は `history.json`（`rawText` / `refinedText` / `insertionMethod` / `timestamp`）。
**secure input（パスワード欄）が有効な間の発話は、整形も挿入も履歴もクリップボードも行わない。**

## フェーズ 1 に入っていないもの

notch HUD（FR-2 / FR-3。**フェーズ 2 で実装した**）、Undo の実行（FR-7。**フェーズ 2 で実装した**）、
設定 UI（FR-11。**フェーズ 2 で実装した**。打鍵の捕獲も辞書の誤認識表記の編集も含む）、
履歴 UI（FR-9。**フェーズ 2 で実装した**）。
**CLI（`ghost-voice`）では、表示は標準エラー出力で代替し、設定は JSON の直接編集で行う**
（画面はすべて `Ghost Voice.app` にだけ入っている）。

> **`SessionNotice`（差し替えと Undo の顛末）は CLI にも出る**（フェーズ 2 で足した）。
> 以前は CLI がこれを 1 つも扱っておらず、**`ghost-voice` から Undo を撃つと何も出なかった。**
> 文言は Core の 1 箇所（`SessionNoticeAnnouncement`）から来るので、HUD と食い違わない。
>
> ```
> [通知] 整形前のテキストに戻しました。
> [通知] 戻せるものがありません。
>        戻せるのは、**挿入から 10 秒以内**の、…
> ```

> **notch HUD はフェーズ 2 の `Ghost Voice.app` にだけ入っている。**
> **CLI（`ghost-voice`）には無い**——CLI は標準エラーへの出力のままである。
> HUD は `NSApplication.run()` のイベントループを前提にしており、CLI は自前で `CFRunLoopRun()` を回すためである。
> 出方の確認は「[HUD の目視確認（`--hud-check`）](#hud-の目視確認---hud-check)」。

> **フェーズ 2 で `.app` になると、権限は付け直しになる。**
> `open` から起動した `.app` は自分自身が責任プロセスになり、**ターミナルアプリの許可を 1 つも引き継がない**
> （実測 2026-08-14 / 基本設計書 §10.1）。上の 3 つ（＋キー送出）を `Ghost Voice.app` に対して与え直すことになる。
> **移行が終わるまでターミナルアプリの許可は外さないこと**（外すとフェーズ 1 の CLI が動かなくなる）。

> **Undo が無い状態で整形が既定で有効である。**
> 要件定義書 L-5 / R-3 は「LLM が意味を削った場合の実効的な安全網は Undo である」と書いている。
> フェーズ 1 にはそれが無いので、**整形が意味を削ったときに戻す手段は無い**——
> `history.json` の `rawText`（整形前の生テキスト）を手で取り出すしかない。
> 整形をやめるなら `settings.json` の `refinementEnabled` を `false` にする。
>
> **フェーズ 2 で Undo（FR-7）を実装した。** 既定の ⌃⌘Z で、直近の発話を整形前の生テキストへ戻せる。
> **ただし自動で戻せるのは差し替えできる挿入先に限る**（要件定義書 FR-7 の細目）——
> Pasteboard 経路で挿入した発話は「戻せる」を満たせず、**生テキストをクリップボードへ取り出す**動作に縮退する。
> **上の「Undo が無い」はフェーズ 1 の状態の記述である。**

## テスト

```bash
swift test
```

> **既定の `swift test` は、一瞬だけ OS 全体の secure input を有効にする。**
> `SystemPasteShortcutSender` が本当に `IsSecureEventInputEnabled()` を見ているかを
> 実際に有効化して確かめるテストが 3 件あるため（`defer` で必ず戻し、窓は実測 17 ms）。
> **その間、他アプリの入力補助（テキスト展開・IME 補助など）が一瞬効かなくなりうる。**
> 実マイクを開くテストと性能計測は既定では走らない（`GHOST_VOICE_MIC_TESTS` /
> `GHOST_VOICE_MEASURE` / `GHOST_VOICE_V12_SECONDS` を付けたときだけ）。

## ドキュメント

| 文書 | 内容 |
|---|---|
| [開発サイクル](docs/00-development-cycle.md) | 進め方の正典。**実測が設計と食い違えば設計書を事実に合わせて直す** |
| [要件定義書](docs/01-requirements.md) | 何を作るか、何を作らないか。検証項目（V-x）の一覧 |
| [基本設計書](docs/02-architecture.md) | どう組み立てるか |
| [詳細設計書](docs/03-detailed-design.md) | どう実装するか。API の実像と実測値 |

---

## V-3 / V-4 の実施手順（権限を付与した人が行う）

フェーズ 1 で唯一残っている検証である。**どちらも実キー入力と実挿入が要るので、
権限を付与した本人にしか実施できない。**
**フェーズ 2 で足した V-23 / V-24 / V-26 / V-27（差し替えの前提）も同じ制約なので、下の 5 に並べてある。** 結果は詳細設計書
[§11.3](docs/03-detailed-design.md) と [§13](docs/03-detailed-design.md) の表へ記入する。

### 0. 準備（5 分）

```bash
swift build
.build/debug/ghost-voice --check          # いま何が足りないかを見る
.build/debug/ghost-voice --request-permissions
```

> **マイクの行で最大 60 秒沈黙したら、そのターミナルアプリにはマイクの許可が無い。**
> 素の実行ファイルからは TCC のダイアログを出せず、`requestAccess` のコールバックが
> 返らないためである（詳細設計書 §3.3）。**許可済みの別のターミナルから起動すること。**

ダイアログが出たら「システム設定を開く」を選び、**ghost-voice を起動しているターミナルアプリ**を
「入力監視」と「アクセシビリティ」で有効にする。**その後ターミナルアプリを再起動**して:

```bash
.build/debug/ghost-voice --check          # 4 項目すべてに ✓ が付いていること
.build/debug/ghost-voice --mic-check      # 「マイクは開けています」と出ること
```

> **終了コード 0 は最低条件にすぎない。** `--check` の終了コードが見ているのは
> 「PTT が動くか」（マイクと入力監視）だけで、**アクセシビリティが無くても 0 になる。**
> V-3 は AX とキー送出の両方が無いと意味を持たない（全アプリが `clipboardOnly` になる）。
> **4 行すべてに ✓ が付いていることを目で確かめること。**

> **注意**: 権限を付けた後は、`swift test` がフォーカス中のアプリへ文字を書き込まないことを
> 一度確認しておくこと。M5a の計測（`GHOST_VOICE_MEASURE=1`）は挿入経路を差し替えて塞いであるが、
> **既定の `swift test` に実挿入が混ざっていないこと**が前提である（Task 10 申し送り【6】）。

### 1. 一気通貫の確認（2 分）

**`GhostVoiceRuntime` の結線（監視器 1 個・シグナル → 終了処理 → `exit`）は、権限が無いと
実行できないため単体検査が無い。** 最初にここを 1 回通しておく。

1. `ghost-voice` を起動し、**録音中**（右 Option を押している最中）に Ctrl-C
   → `[終了] 進行中の発話を待っています…` が出て、**キーを離すまで終わらない**こと。
     離すと確定・整形・挿入まで走ってから `[終了] Ghost Voice を終了しました。` が出る
2. もう一度起動し、**挿入中**（キーを離した直後）に Ctrl-C
   → 挿入が完了してから終了すること。**テキストが消えないこと**が要点
3. 終了処理の最中にもう一度 Ctrl-C
   → `[終了] 終了処理中です。…kill -9 …` が出て、**強制終了しない**こと

### 2. V-4: 右 Option の副作用（10 分）

> **caps lock を転用している場合、#1 と #3 の意味が変わる。**
> #1（PTT キーを押しながら `a`）は caps lock では起こらない副作用なので、
> **本物の右 Option がある機体でのみ判定できる**——転用機では「該当なし」と記録する。
> #3（左 Option を押したまま PTT を離す）は**転用機でこそ意味がある**。
> 転用した caps lock が本物の左 Option と左右を取り違えないことの確認になる。

`ghost-voice` を起動した状態で、テキストエディタを開いて順に試し、結果を記録する。

| # | 操作 | 期待 | 実測 |
|---|---|---|---|
| 1 | 右 Option を押しながら `a` を打つ | `å` が入る（既知の副作用 R-1。**実用上つらいかを判断する**） | |
| 2 | 右 Option を押して離す（発話なし） | `[エラー] 認識できませんでした。` が出て、何も挿入されない | |
| 3 | 左 Option を押したまま右 Option を押して離す | **録音が止まること**（左右のデバイスビットを実キーボードが立てているかの確認。詳細設計書 §2.3） | |
| 4 | ⌘C / ⌘V を通常どおり使う | 影響なし | |
| 5 | 録音中に ESC を押す | `[エラー]` にならず中断され、**ESC が下流アプリへ届かない**（エディタの入力が中断されない） | |
| 6 | 録音していないときに ESC を押す | 下流アプリへ**届く**（ESC を奪っていないこと） | |
| 7 | **キーを離した直後（`[確定中]` / `[整形中]` の表示中）に ESC を押す** | **中断され**（挿入されない・履歴は `notInserted`）、**かつ ESC が下流アプリへも届く**（エディタの入力が中断される等） | |

**#7 が効かない場合**、監視器が処理中の窓を知らない（`setSessionBusy` が届いていない）。
**#7 で ESC が下流へ届かない場合**は逆に、その窓で抑止してしまっている。どちらも
`HotkeyDecision.decide` と `DictationSession` の `setSessionBusy` の呼び出しを見ること。

**#1 が実用上つらい場合**、`HotkeyDecision.decide` を「右 Option の 2 回連続押下でトグル開始 /
再押下で停止」へ差し替える。判定は純粋関数なので、`HotkeyDecision` とそのテストだけを直せばよい。

**#3 で録音が止まらない場合**、その入力源はデバイスビットを報告していない。
`ModifierSide` の退避経路に落ちているので、詳細設計書 §2.3 の記述を実測に合わせて直すこと。

### 3. V-3: アプリ別の挿入経路（20 分）

各アプリの入力欄にカーソルを置き、右 Option を押しながら短く喋って離す。
**挿入されたか**（目で見る）と**経路**（履歴に残る）を両方記録する。

```bash
# 直近の挿入経路を見る
# **最新は d[0] である。** HistoryStore.append は先頭挿入なので、d[-1] は最古を指す。
python3 -c "import json,pathlib;d=json.loads(pathlib.Path.home().joinpath('Library/Application Support/GhostVoice/history.json').read_text());e=d[0];print(e['insertionMethod'], '整形:', 'あり' if e.get('refinedText') else 'なし（打ち切り）', repr(e.get('refinedText') or e['rawText']))"
```

| アプリ | 挿入できたか | 経路（`insertionMethod`） | 備考 |
|---|---|---|---|
| メモ | | | |
| メール | | | |
| Slack | | | Electron。`pasteboard` の見込み |
| Google Chrome（アドレスバー） | | | |
| Google Chrome（入力欄） | | | |
| Xcode | | | |
| Notion | | | Electron。`pasteboard` の見込み |
| ターミナル | | | |

**読み方**

- `ax` … AX 直接挿入。**目で見て入っていないのに `ax` と記録されたら、それが R-4 の無言失敗である**
  （詳細設計書 §6.2。1 件でもあれば検知方法の設計が要る）
- `pasteboard` … ⌘V 経由。**入っていないのに `pasteboard` なら復元待ちが短い。**
  **既定は 300 ms である**（実機で 120 ms では「相手が読む前にクリップボードが戻り、違う内容が貼られる」
  事故が起きたため引き上げた。要件定義書 §2.8.5）。それでも入らないなら `--paste-restore-delay-ms 500` で再試行する
- `clipboardOnly` … どちらも使えず、クリップボードに残しただけ。**復元待ちを延ばしても直らない。**
  `--check` でキー送出とアクセシビリティの許可を確認する
- `notInserted` … 中断（ESC）された発話

あわせて確認すること。

1. **クリップボードが元に戻るか。** リッチテキスト（ブラウザからコピーした文字）や画像を
   クリップボードへ入れた状態で挿入し、**挿入後に元の内容が戻っている**こと（詳細設計書 §6.3）
2. **`[metrics]` の `insert`。** Pasteboard 経路では復元待ち（既定 300 ms）が乗るので、
   AX 経路（0.1〜5.5 ms）とは桁が変わる。**これは劣化ではなく、測っている量が変わっただけである**
   （Task 10 申し送り【2】）。`total` が 1000 ms（NFR-P6a）に収まるかを見る
3. **長い発話での末尾の欠落（V-12 / V-31。実機で再現し、フェーズ 2 で塞いだ）。**
   2026-08-14 の実機で、121 字の発話の末尾 約 38 字が失われた（要件定義書 §2.8.4）。
   **確定待ちを「解放後の最初の確定」から「結果ストリームの終端」へ移して塞いである**
   （詳細設計書 §10 / §13）。**ここで見るのは、修正が実機で効いているかである**——
   `[録音中]` の暫定表示の末尾と、挿入されたテキストの末尾を突き合わせること
   （履歴の `rawText` でも見られる）。**欠けていたら V-31 として報告すること。**
4. **整形が効いたかどうか（実機で 40 字以上は 8 件中 0 件）。** 履歴の `refinedText` が
   無ければ打ち切られている。**発話の長さと `refine` の実測を組にして記録する**——
   打ち切り 750 ms は 3 秒の合成発話で決めた値で、実用の発話長では足りない
   （要件定義書 §2.8.4）。**これは V-25 の材料であり、NFR-P6b の目標 2 秒 / 打ち切り 3 秒
   （どちらも推定値）の根拠になる**
5. **V-23 / V-24（差し替えの前提）。** 各アプリの入力欄で `kAXSelectedTextRange` が
   settable か、`AXStringForRange` が読めるかを照会する（**書き込みはしない**）。
   **ここが全滅なら、フェーズ 2 の差し替え（FR-5(a) / FR-7）は一度も成立しない**
   （挙動は現状と同じになる）。詳細設計書 §11.3 の 5 番

**結果の記入先**: 詳細設計書 §11.3 の表（V-3）、上の表（V-4）、§13 と要件定義書 §7 の状況欄。

### 4. V-12 の再実行（2 分。権限は要らない）

```bash
GHOST_VOICE_V12_SECONDS=103 swift test --filter FinalAfterRelease
```

**値は必ず 103**（フィクスチャの全長）。既定の `swift test` では走らない——実時間の実認識が
機体を飽和させ、時間閾値を持つ既存の検査が落ちるためである。**30 秒では確定が 1 件しか出ず、
取りこぼしの経路を 1 度も通らない**ので、短くして回しても意味が無い。

**いつ回すか**: 認識まわりを変えたとき（`SpeechAnalyzerTranscriber`、`DictationSession` の
確定待ち、ロケールや認識種別の既定）、および OS を更新したとき。
出力の `V-12 解放後に届いた確定` が **2 件以上になったら、その条件が実音声で再現した**
ということなので、詳細設計書 §13 の V-12 と §10 の M2 を更新すること
（**これまで一度も起きていない**。取りこぼしそのものは修正済みで、
`挿入された文字数 = 確定の総和` が崩れたときだけ欠陥である）。

> **この検査は V-12 の欠陥を 1 度も捕まえていない。** 回帰を止めているのは代役による
> `DictationSessionTests.doesNotDropSecondFinalAfterRelease`（既定の `swift test` で走る）で、
> こちらは「実音声でも取りこぼさない」ことを実物で確かめる側である。

### 5. V-23 / V-24 / V-26 / V-27: 差し替えの前提（15 分。**使い捨ての入力欄でのみ行うこと**）

**「挿入済みテキストを後から整形結果へ差し替える」（FR-5(a) / FR-7）が成立するかを測る。**
実装（`TextReplacer`）は全経路を代役で検査済みだが、**実アプリに対する挙動はまだ 1 つも測っていない。**

> **この手順は入力欄の内容を実際に書き換える。** 保存していない文書・チャットの入力中の文・
> パスワード欄では**絶対に行わないこと。** 空のメモや、捨ててよいテキストエディタの窓を使う。

```bash
mkdir -p /tmp/gv-probe && cat > /tmp/gv-probe/probe.swift <<'SWIFT'
// V-23 / V-24 / V-26 / V-27 の実測用。**使い捨ての入力欄でのみ実行すること。**
import ApplicationServices
import CoreGraphics
import Foundation

func frontmostPid() -> pid_t? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    for window in windows {
        if let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
           let pid = window[kCGWindowOwnerPID as String] as? pid_t { return pid }
    }
    return nil
}

func focused() -> (AXUIElement, pid_t)? {
    guard let pid = frontmostPid() else { return nil }
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
            == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (unsafeDowncast(value, to: AXUIElement.self), pid)
}

func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var flag: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(element, attribute as CFString, &flag) == .success
        && flag.boolValue
}

func selection(_ element: AXUIElement) -> CFRange? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else {
        return nil
    }
    return range
}

func setSelection(_ element: AXUIElement, _ range: CFRange) -> Bool {
    var range = range
    guard let value = AXValueCreate(.cfRange, &range) else { return false }
    return AXUIElementSetAttributeValue(
        element, kAXSelectedTextRangeAttribute as CFString, value) == .success
}

func string(_ element: AXUIElement, _ range: CFRange) -> String? {
    var range = range
    guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
        element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
            == .success
    else { return nil }
    return value as? String
}

print("5 秒以内に、使い捨ての入力欄をクリックしてください…")
Thread.sleep(forTimeInterval: 5)

guard let (element, pid) = focused() else {
    print("フォーカス要素が取れません（AX 権限か、対象アプリの問題）"); exit(1)
}
var role: CFTypeRef?
_ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
print("pid=\(pid) role=\(role as? String ?? "不明")")
print("V-23 kAXSelectedText settable      : \(settable(element, kAXSelectedTextAttribute as String))")
print("V-23 kAXSelectedTextRange settable : \(settable(element, kAXSelectedTextRangeAttribute as String))")

let marker = "検証用テキストです😀"
guard let before = selection(element) else { print("選択範囲が読めません"); exit(1) }
guard AXUIElementSetAttributeValue(
    element, kAXSelectedTextAttribute as CFString, marker as CFString) == .success else {
    print("書き込みが AXError。ここで終了（何も入っていない）"); exit(1)
}
guard let after = selection(element) else { print("書き込み後の選択範囲が読めません"); exit(1) }
let length = after.location - before.location
print("V-23 キャレット: 挿入直後 length=\(after.length)（0 が期待値）, 導いた長さ=\(length)")
print("     単位の目安: count=\(marker.count) utf16=\(marker.utf16.count) scalars=\(marker.unicodeScalars.count)")

let range = CFRange(location: before.location, length: length)
if let read = string(element, range) {
    print("V-24 AXStringForRange           : 読めた。一致=\(read == marker)")
} else {
    print("V-24 AXStringForRange           : **読めない**（この相手は差し替え不可）"); exit(0)
}

// V-27: 時間を置いてから同じ要素かを見る
Thread.sleep(forTimeInterval: 2)
if let (again, _) = focused() {
    print("V-27 CFEqual（2 秒後）           : \(CFEqual(element, again))")
}

// V-26 本番: 範囲を選び直して 1 回で上書きする
let replacement = "差し替え後"
guard setSelection(element, range) else { print("範囲の設定が AXError"); exit(1) }
guard AXUIElementSetAttributeValue(
    element, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success else {
    print("V-26 上書きが AXError（何も起きていない）"); exit(1)
}
let newLength = (selection(element)?.location ?? before.location) - before.location
let newRange = CFRange(location: before.location, length: newLength)
switch string(element, newRange) {
case replacement:
    print("V-26 事後検査                    : 一致（差し替え成功）")
case .some(let other) where other == marker || string(element, range) == marker:
    print("V-26 事後検査                    : **元の文字列のまま = R-4 の無言失敗**")
default:
    print("V-26 事後検査                    : **どちらでもない = 喪失。設計を変える材料**")
}
SWIFT
swift /tmp/gv-probe/probe.swift
```

実行したら **5 秒以内に使い捨ての入力欄をクリックする**（そこへ書き込まれる）。

| 出力 | 何が判るか | 外れたときにどうなるか |
|---|---|---|
| `V-23 kAXSelectedTextRange settable` | 範囲を選び直せる相手か | **false なら差し替えは起きない。** 挙動は現状のまま（整形を待つ分岐） |
| `V-24 AXStringForRange` | 読み戻せる相手か | **読めなければ差し替えは中止される**（生テキストが残る） |
| `V-23 導いた長さ` と `単位の目安` | AX の範囲の単位（`count` / `utf16` / `scalars` のどれと一致するか） | **実装は長さを自分で数えないので、単位が何でも成立する。** 記録だけする |
| `V-26 事後検査` | **`.lost`（消えるだけ）が実在するか** | **「どちらでもない」が 1 度でも出たら、差し替えを既定オフにする**（詳細設計書 §6.5 の唯一の重い行） |
| `V-27 CFEqual` | 時間を跨いで同じ要素と判定できるか | false なら差し替えが一度も効かない（**誤った欄へは書かない**） |

**アプリごとに繰り返す**（メモ / メール / Chrome アドレスバー / Slack / Notion / Xcode / ターミナル）。
**あわせて IME の変換中（未確定の文字がある状態）でも 1 度実行する**——ここは B（誤ったテキストが入る）を
作りうる箇所として設計が挙げている。

**結果の記入先**: 詳細設計書 §13 の V-23 / V-24 / V-26 / V-27。
**実測が設計の想定と違ったら、コードではなく設計書を事実に合わせて直すこと**（`docs/00-development-cycle.md`）。

### 6. V-28 / V-35 / V-36 / V-37: 配線した後にしか測れないもの（10 分。**捨ててよい入力欄で**）

**フェーズ 2 で「生テキストを先に挿入し、整形は後から差し替える」経路（FR-5(a)）を配線した。**
代役の入力欄に対する所要は実測済み（詳細設計書 §10）だが、**実アプリでは 1 つも測っていない。**

`ghost-voice` を起動し、**空のメモ**など捨ててよい入力欄で次を確かめる。

| # | やること | 見るもの | 外れたときにどうする |
|---|---|---|---|
| V-28 | 5 字 / 20 字 / 40 字 / 80 字 / 120 字くらいの発話を各 3 回 | **生テキストが出るまでの体感**と、`[metrics]` 行の `total`。**1 秒（NFR-P6a）を超えないこと** | 超えるなら、AX 経路が使われているか（履歴の `insertionMethod` が `ax` か）を先に見る |
| V-28 | 同上 | **書き換わるまでの体感**（整形の反映）。長い発話ほど遅れる | 遅すぎるなら `revisionDeadlineMs` ではなく体感の問題なので V-29 として記録する |
| **V-37** | **40 字以上の発話**を 5 回 | **書き換わらない発話があるか。** 履歴の `refinedText` が入っているのに欄が生テキストのままなら差し替えの断念、`refinedText` が空なら整形そのものが捨てられている | **後者が続くなら整形の検査（残存率）が厳しすぎる。** 発話の原文と認識結果を記録して詳細設計書 §5.5.1 へ回す |
| **V-35** | 発話の直後（10 秒以内）に **⌃⌘Z** を押す。**その後、10 秒以上待ってからもう一度押す** | 1 回目: 整形前の生テキストへ戻る。**2 回目: そのアプリ自身の Undo が普通に効く**（Ghost Voice は何もしない） | 2 回目でアプリの Undo が効かないなら、窓の外でも打鍵を奪っている（欠陥） |
| **V-35** | ⌃⌘Z で戻した直後に、そのアプリで **⌘Z** を押す | 二重に戻っていないか（Ghost Voice の Undo とアプリの Undo が両方走っていないか） | 両方走るなら抑止が効いていない |
| **V-36** | 長い発話をして、**書き換わる直前に PTT を押す** | 次の録音の開始が遅れて感じられるか（**差し替えは録音開始を最大で数十 ms 待たせうる**） | 体感できるほど遅いなら、差し替えを actor の外へ出す判断が要る |

**結果の記入先**: 詳細設計書 §13 の V-28 / V-35 / V-36 / V-37。

> **`refinementApplyMode` を `beforeInsert` にすれば、この経路は丸ごと止まる**（フェーズ 1 と同じ挙動へ戻る）。
> 差し替えの体感が悪い・書き換わるのが気持ち悪い、という場合はそれで完全に回避できる。

---

## フェーズ 2: `Ghost Voice.app` への移行（フェーズ 1 の利用者が踏む手順）

**フェーズ 1 でターミナルアプリへ与えた 4 つの許可は、`Ghost Voice.app` には 1 つも引き継がれない。**
`.app` は Finder / Dock / `open` から起動された瞬間に自分自身が責任プロセスになり、
起動元とは別のアプリとして扱われるためである（実測。詳細設計書 §9 の表）。
**4 つとも付け直しになる。これは避けられない。**

### 1. 組み立てる（1 分）

```bash
Scripts/make-app.sh
```

最後に `codesign -d -r-` の出力（designated requirement）が表示される。
**`cdhash` という語が出ていたら、そのビルドは権限を保てない。**
証明書で署名できていれば `identifier "com.haruki1090.GhostVoice" and anchor apple generic and …` になる。

### 2. 置き場所を決める（**後から変えない**）

```bash
cp -R ".build/app/Ghost Voice.app" /Applications/
```

> TCC のレコードはアプリのパスも見る。`~/Downloads` で許可してから `/Applications` へ移すと、
> 許可を付け直す羽目になりうる（**移動で無効になるかは未実測** = V-18）。
> **先に置き場所を決めてから許可すること。**

### 3. 起動して、要求を出させる（1 分）

```bash
open "/Applications/Ghost Voice.app"
```

- **マイクのダイアログが出たら「許可」を選ぶ。** ここだけはダイアログで完結する
- 入力監視とアクセシビリティは、アプリが要求を出した時点で**システム設定の一覧に載る**
  （その場では許可されない。載せることが目的である）

**ターミナルから `Ghost Voice.app/Contents/MacOS/GhostVoice` を直接叩かないこと。**
その経路ではターミナルの許可を借りて動いてしまい、「動いているのに Finder から起動すると
動かない」という切り分け不能な状態になる（アプリはこれを検出して警告する）。

### 4. システム設定で 2 つのトグルを入れる（2 分）

1. **システム設定 > プライバシーとセキュリティ > 入力監視** で `Ghost Voice` を**オン**
   - 何のためか: 右 Option の押下を受け取る（`CGEvent.tapCreate` / `kTCCServiceListenEvent`）
   - 無いとどうなるか: **PTT がまったく反応しない**
2. **システム設定 > プライバシーとセキュリティ > アクセシビリティ** で `Ghost Voice` を**オン**
   - 何のためか: フォーカス中の入力欄へ直接入れる（`kTCCServiceAccessibility`）と ⌘V を送る（`kTCCServicePostEvent`）
   - 無いとどうなるか: **文字は入らず、クリップボードに残るだけになる**

### 5. 終了して起動し直す（**必須**）

アクセシビリティ系の許可は**プロセスの起動時に読まれる**ので、付与しただけでは反映されない。

```bash
osascript -e 'quit app "Ghost Voice"' 2>/dev/null || pkill -f "Ghost Voice.app/Contents/MacOS/GhostVoice"
open "/Applications/Ghost Voice.app"
log show --last 2m --info --predicate 'subsystem == "com.haruki1090.GhostVoice"' --style compact
```

ログの権限一覧が **4 行とも ✓** になっていることを確認する。

### 6. フェーズ 1 の許可の後片付け（任意）

ターミナルアプリへ与えた許可は、**移行が完全に終わるまで外さないこと**
（外すと CLI の `ghost-voice` が動かなくなる）。他の用途でも使っているならそのまま残してよい。

### 7. 移行のあとに必ず行う検証（権限を付けた人にしか実施できない）

| ID | 何を見るか | 手順 | 記入先 |
|---|---|---|---|
| **V-19** | **`NSApp.run()` の下で `CGEventTap` のキーイベントが届くか** | `Ghost Voice.app` を通常起動し、テキストエディタで右 Option を押しながら短く喋って離す。**挿入されれば成立。まったく反応しなければ不成立**（その場合はフェーズ 1 の CLI が動くかを先に確かめ、権限側の問題と切り分ける） | 詳細設計書 §13 |
| **V-34** | 発話の途中の終了要求で発話が失われないか | 右 Option を押している最中に `pkill -TERM -f "Ghost Voice.app/Contents/MacOS/GhostVoice"`。**キーを離すまで終わらず**、離すと挿入まで走ってから終了すること | 詳細設計書 §13 |
| **V-16** | 再ビルドで許可が消えないか | 上記が通った後に `Scripts/make-app.sh` を走らせ直し、`/Applications` のものを置き換えて起動。**4 項目が許可のままであること** | 詳細設計書 §13 |
| **V-20 / V-21 / V-22 / V-40** | HUD が正しい場所へ出て、消えないか | 上記「[HUD の目視確認（`--hud-check`）](#hud-の目視確認---hud-check)」。**権限は要らないので、移行の前に済ませてもよい** | 詳細設計書 §13 |
| **V-38** | 音量バーの振れ幅が肉声に合うか | 通常起動して喋り、バーが振れるか／振り切れたままかを見る | 詳細設計書 §13 |
| **V-39** | HUD を出したことで PTT の反応が鈍っていないか | 通常起動で PTT を使い、**押してから録音が始まるまで・離してから文字が出るまでが体感で遅くなっていないか。** 遅ければ `--shell-only` ではない通常起動と比べる（HUD を止める引数は無いので、体感と履歴の計測値で見る） | 詳細設計書 §13 |

**V-19 が通らない場合**、キーイベントがメインのランループへ届いていない。
フェーズ 1 の CLI（`CFRunLoopRun()` を自前で回す）では届いていたので、
`NSApplication.run()` との組み合わせが原因である可能性が高い。
その場合は `CGEventTapHotkeyMonitor` の `runLoop:` を差し替えて専用スレッドで回す形が候補になる。

### うまくいかないときに疑う順序

| 症状 | 疑うところ |
|---|---|
| PTT がまったく反応しない | 入力監視。**起動し直したか**（許可は起動時に読まれる） |
| 文字が入らずクリップボードに残る | アクセシビリティ（+ キー送出）。secure input が有効な欄ではないか |
| 一覧に `Ghost Voice` が出てこない | 一度起動して要求を出させる。それでも出なければ `.app` の署名（`codesign --verify --strict`） |
| ビルドし直したら許可が外れた | designated requirement が変わっている。`codesign -d -r-` に `cdhash` が出ていないか（ad-hoc 署名になっていないか） |
| バンドル ID を変えた | **全部やり直しになる。** 変えないこと |
| HUD が 1 度も出ない | `--hud-check` で出るか。出るなら PTT 側（入力監視）、出ないならログの `[HUD] 表示先:` を見る（出ていなければ画面が 1 枚も見つかっていない） |
| HUD が外部ディスプレイに出る | **内蔵が見つかっていない**（クラムシェル）。ログの `[HUD]` の行が「内蔵ディスプレイが見つかりません」と言っているはず |
| HUD がメニューバーの項目を隠す | 帯の左右は透明のはずなので、隠しているなら不具合。ログの `中心 x=` と切り欠きの位置がずれていないか |

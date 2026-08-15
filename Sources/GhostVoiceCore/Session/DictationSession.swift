import AVFAudio
import Carbon.HIToolbox
import Foundation

/// 状態機械が外へ知らせる状態（基本設計書 §4）。
public enum SessionState: Sendable, Equatable {
    case idle
    case recording(volatileText: String)
    case finalizing
    case refining
    case inserting
    /// **挿入済みの生テキストを整形結果へ差し替えている**（FR-5(a) / 基本設計書 §4）。
    ///
    /// **差し替えできる挿入先でのみ通る。** `.inserting` → `.idle` の**後**に
    /// `.revising` → `.idle` が続く形になる（`.idle` を挟むのは、その時点で
    /// 次の PTT を受け付けるためである。差し替えは「忙しい」に数えない）。
    ///
    /// - Important: **表示は控えめにすること**（基本設計書 §8.2）。挿入は既に終わって
    ///   おり、利用者は次の作業へ移っている。**断念しても生テキストは欄に残る。**
    /// - Note: **FR-7 の Undo もこの状態を通る。** 欄を書き換えているという意味は同じで、
    ///   向き（生 → 整形／整形 → 生）だけが違う（要件定義書 §2.8.6 の裁定 3）。
    case revising
    /// 失敗。**この直後に必ず `.idle` が続く。** どれだけ表示するかは UI 側が決める。
    case failed(SessionFailure)
}

/// **利用者へ告げるが、発話の失敗ではないこと。**
///
/// `SessionFailure` と分けてあるのは意味が違うためである。`SessionFailure` は
/// 「その発話が縮退した」ことを表すが、ここに並ぶのは**発話が既に挿入先にある状態での
/// 出来事**である（差し替えが効いた／効かなかった／戻した／戻せなかった）。
/// 混ぜると、HUD が「失敗」として出すべきものとそうでないものを区別できなくなる。
///
/// - Important: **文言も発話も持たせない。** 通知に発話やその一部を載せると、
///   通知センターやログへ発話が漏れる経路が生まれる（`ReplacementNotice` と同じ規律）。
public enum SessionNotice: Sendable, Equatable {
    /// 整形結果を挿入済みのテキストへ反映した（FR-5(a) が効いた）。
    case refinementApplied
    /// **整形結果を反映できなかった。生テキストが欄にある。**
    ///
    /// - Parameter reason: 断念の理由。nil は「整形そのものが返らなかった」
    ///   （打ち切り・利用不可・逸脱の検査に落ちた）。
    ///   **どの理由でも欄の内容は変えていない。**
    case refinementNotApplied(ReplacementDecline?)
    /// **差し替えの途中で欄の内容が判らなくなった**（R-9）。
    ///
    /// 差し替えようとした文字列は**クリップボードへ退避を試みてある**
    /// （`TextReplacer.verify`。`NSPasteboard.setString` が失敗した場合は載らない）。
    /// **履歴には必ず raw と refined の両方がある**——差し替えは
    /// 「履歴へ書けてから始める」を門にしているためで、そこが 1 番目の受けである
    /// （詳細設計書 §8.3）。**これだけは重い。**
    case textMayHaveBeenLost
    /// Undo で整形前の生テキストへ戻した（FR-7）。
    case undone
    /// **戻せるものが無かった。** 10 秒窓の外・差し替えていない・そもそも挿入していない。
    case undoUnavailable
    /// Undo を試したが断念した（利用者が編集した・別のアプリへ移った等）。**何も書き換えていない。**
    case undoDeclined(ReplacementDecline)
    /// **自動では戻せない経路だったので、生テキストをクリップボードへ取り出した**
    /// （FR-7 の細目 3 行目 / UC-3 の縮退）。
    ///
    /// クリップボードを奪ってよいのは、これが**利用者の明示操作**だからである。
    case undoCopiedRawTextToClipboard
}

/// 縮退した理由。**文字列ではなく型で持つ。**
/// 表示文言は UI 側の関心であり、CLI と HUD で変える余地を残す。
public enum SessionFailure: Sendable, Equatable {
    /// 認識を開始できなかった（`prepare` 未了・モデル未導入・ロケール未対応）。
    case transcriptionUnavailable
    /// マイクのタップを装着できなかった（権限・デバイス）。
    case audioUnavailable
    /// 認識結果が空だった。
    case noSpeechRecognized
    /// secure input が有効だったので、整形も挿入も履歴もクリップボードも行わなかった。
    case refusedSecureInput
    /// 履歴へ書けなかった。
    ///
    /// **中断された発話にとって、履歴は唯一の写しである**（挿入していないので、
    /// アプリにもクリップボードにも無い）。基本設計書 §4 の「中断でも録音済み内容は
    /// 破棄せず履歴へ残す」は、書き込みが成功して初めて成り立つ。
    ///
    /// - Parameter insertedElsewhere: その発話が挿入まで到達していたか。
    ///   **true なら失うのは履歴と Undo だけ**（テキストは利用者の手元にある）。
    ///   **false なら発話そのものが失われた。** 利用者にとって意味がまったく違うので、
    ///   同じ文言にしてはならない。
    case historyUnavailable(insertedElsewhere: Bool)

    /// **どの経路でも挿入できず、クリップボードへも残せなかった**
    /// （`InsertionOutcome.failedEverywhere`）。
    ///
    /// 以前はこの縮退が `.inserted(.clipboardOnly)` に化けており、
    /// 利用者は「⌘V で貼れます」と告げられて空のクリップボードを見ることになった
    /// （最終レビュー A-2）。**テキストは履歴にだけある**ので、
    /// 案内する先は履歴画面（FR-9 の再挿入）である。
    ///
    /// - Parameter retainedInHistory: **その履歴が実際に残ったか。**
    ///   履歴上限 0（設定画面のステッパーで到達できる。`HistoryStore.normalized`）では
    ///   `append` が何も保存せず例外も投げないので、**唯一の写しであるはずの履歴が
    ///   1 件も無い。** ここを持たずに「履歴にだけ残っています」と言い切っていたため、
    ///   **発話が完全に消えているのに `speechWasLost = false` を告げていた**
    ///   （再レビュー B-1）。`historyUnavailable(insertedElsewhere:)` が
    ///   同じ区別をしているのとまったく同じ理由である。
    ///
    ///   **false になるのは上限 0 で「残らなかった」場合だけである。**
    ///   書き込みそのものが失敗した場合は `historyUnavailable` の側で告げる
    ///   （`SessionFailureNotice` の文言がこの前提に乗っている）。
    case insertionFailed(retainedInHistory: Bool)
}

/// セッションの操作そのものが受け付けられなかった。
///
/// **`SessionFailure`（発話が縮退した理由）とは別である。** こちらは
/// 「いま呼んではいけない口を呼んだ」ことを呼び出し側へ返す。
public enum DictationSessionError: Error, Equatable, Sendable {
    /// 発話を抱えている最中だった（録音中・確定〜挿入の処理中）。
    ///
    /// **待って呼び直すのは呼び出し側の判断である。** ここで待つと、
    /// 設定画面が発話 1 回ぶん（実測 400〜800 ms）固まる。
    case busy
}

/// PTT 1 回ぶんの流れを統括する状態機械。
///
/// ## 原則
///
/// **発話を失わない。** 各段の失敗は縮退で吸収し、最悪でもクリップボードに残す。
///
/// > **唯一の例外は secure input が有効な場合**（基本設計書 §7 / 要件定義書 FR-4）。
/// > そのときは整形も挿入も履歴もクリップボードへの残置も行わない。ユーザーが
/// > パスワードを入力しているためで、**「発話を失っている」と見て残置を足してはならない。**
///
/// ## 状態を購読する 2 つの口（**新しい購読者は `stateStream()` を使うこと**）
///
/// | 口 | 消費者 | MainActor から |
/// |---|---|---|
/// | `stateUpdates` | **1 つだけ。** 複数の `next()` を同時に待つと異常終了する | 取得は `await` 無しでできる |
/// | `stateStream()` | **何人でも。** 呼ぶたびに独立したストリームを返す | **呼んでよい**（`nonisolated`） |
///
/// `stateUpdates` はフェーズ 1 からの口で、CLI が使っている。**HUD・終了待ち・履歴一覧が
/// 同時に状態を要る**フェーズ 2 では足りないので、分配する口を足した（調査 A-3 の欠落 1）。
/// **同じものが両方へ流れる。**
///
/// `run()` はプロセスにつき 1 回だけ呼ぶこと（ホットキーのイベント列も単一消費者）。
///
/// ## メインのランループが要る
///
/// `CGEventTapHotkeyMonitor` は `CFRunLoopGetMain()` にソースを付けるため、
/// メインのランループが回っていないとキーイベントが届かない（Task 9 申し送り）。
/// `run()` をメインスレッドで `await` するだけの CLI では動かない。
public actor DictationSession {

    /// 録音の安全弁。**時間で必ず抜ける経路が要る。**
    ///
    /// 左右のデバイスビットを報告しない入力源が混ざると、キーを離しても押下と
    /// 判定し続ける経路が残っている（詳細設計書 §2.3 / Task 9 申し送り）。
    /// `HotkeyMonitor` 側に置かないのは、適切な上限が録音の要件側の値であり、
    /// 監視器はキーの状態しか知らないため。
    ///
    /// 上限に達したら**中断ではなく確定**として扱う。ユーザーは喋っていたのだから、
    /// そこまでの発話は届けるべきである。
    public static let defaultMaxRecordingDuration: Duration = .seconds(120)

    /// キー解放から「確定テキストが出そろう」までの締め切り。
    ///
    /// 待つ相手は**結果ストリームの終端**である（V-12。最初の確定では待ちを解かない）。
    /// 実測は 45.1〜155.1 ms（詳細設計書 §10 の M2）なので通常はまったく効かない。
    /// **認識器が黙り込んだり、
    /// 確定を出したままストリームを閉じ忘れたりしたときに録音が終わらなくなるのを
    /// 防ぐためだけにある。** 締め切りに達した場合は、そこまでに積んだ確定
    /// （1 件も無ければ暫定テキスト）で先へ進む。空で捨てるよりは残す。
    public static let defaultFinalizeDeadline: Duration = .seconds(2)

    /// 最後の発話から、マイク（`AVAudioEngine`）を止めるまでの猶予。**既定 30 秒。**
    ///
    /// 常時起動したままだと `coreaudiod` に +15 ポイント（実測 19.6〜20.3% 対 4.3〜4.8%。
    /// 2026-08-15 / M3 / macOS 26.5.2）を課し、マイクのオレンジ点が消えない。
    /// 逆に発話ごとに止めると、**毎回** 起床の 63.0 ms（最大 129.6 ms）を払う。
    /// 30 秒は「文を続けて喋る間は起きたまま、考え込んだら消える」ところに置いた裁定である
    /// （設計書 2026-08-15 §3）。**要件値ではない。**
    public static let defaultAudioIdleSleepDelay: Duration = .seconds(30)

    private let settings: SettingsStore
    private let hotkey: any HotkeyMonitor
    private let audio: any AudioCapturing
    private let transcriber: any Transcribing
    private nonisolated let refiner: any Refining
    private let inserter: any TextInserting
    /// 挿入器が錨まで返せる場合の同じもの。**(a) の分岐はこれが無いと成立しない。**
    private let anchoringInserter: (any AnchoringTextInserting)?
    /// 差し替え器。**挿入器と同じ世代・同じクリップボードで組まれたもの**
    /// （`CompositeInserter.systemStack`）。nil なら常に (b) の分岐で動く。
    private let replacer: TextReplacer?
    /// 自動で戻せない発話の生テキストを取り出す先（FR-7 の細目 3 行目）。
    private let clipboard: (any ClipboardLeaving)?

    /// **この組み立てで FR-5(a) の差し替えと FR-7 の Undo が使えるか。**
    ///
    /// 偽なら常に (b) の分岐（整形を待ってから挿入する。フェーズ 1 と同じ）で動く。
    /// **これが公開されているのは、「製品の組み立てが正しいこと」を検査が固定できる
    /// ようにするためである**——フェーズ 2 の最終レビューで、本番の 2 箇所が
    /// 差し替え器を渡しておらず、しかも検査が 1 件も落ちなかった
    /// （検査が自分で正しい組を作っていた）ことが判ったため。
    public nonisolated let canReviseInPlace: Bool
    private let history: HistoryStore
    private let vocabulary: VocabularyStore
    private let isSecureInputEnabled: @Sendable () -> Bool
    private let postEventAuthorization: PostEventAuthorization
    private let maxRecordingDuration: Duration
    private let finalizeDeadline: Duration
    /// この時間内に推論を投げていれば、デーモンはまだ温まっているとみなす
    /// （`warmRefinerForUtterance()`）。**既定 10 秒。要件値ではない。**
    private let refinerWarmthWindow: Duration
    private let audioIdleSleepDelay: Duration
    /// 待機が続いたらマイクを止める係。**押下のたびに取り消す。**
    private var audioSleepTask: Task<Void, Never>?

    private let stateContinuation: AsyncStream<SessionState>.Continuation
    /// 状態の**単一消費者**の口（フェーズ 1 からのもの。CLI が使う）。
    ///
    /// - Important: **複数の `next()` を同時に待つと異常終了する。**
    ///   2 人目からは `stateStream()` を使うこと。
    public nonisolated let stateUpdates: AsyncStream<SessionState>

    /// 状態の分配器。`stateStream()` が配る。
    private nonisolated let stateBroadcast = SessionBroadcast<SessionState>()
    /// マイク音量の分配器。`levelStream()` が配る。
    private nonisolated let levelBroadcast = SessionBroadcast<Float>()
    /// 通知の分配器。`notices()` が配る。
    private nonisolated let noticeBroadcast = SessionBroadcast<SessionNotice>()
    /// モデル導入の分配器。`assetInstallationEvents()` が配る。
    private nonisolated let assetBroadcast = SessionBroadcast<AssetInstallationEvent>()
    /// `audio.level`（単一消費者）を 1 人で読み、分配器へ流す係。
    private var levelTask: Task<Void, Never>?
    /// `transcriber.assetInstallation`（単一消費者）を 1 人で読み、分配器へ流す係。
    private var assetTask: Task<Void, Never>?

    public private(set) var state: SessionState = .idle
    public private(set) var latestMetrics: Metrics.Sample?

    /// 発話を抱えているか（録音中または確定〜挿入の処理中）。
    ///
    /// **終了処理は `state` ではなくこちらを見ること。**
    /// `state` は `emit` でしか変わらないので、**`phase` が立ってから最初の `emit` までに
    /// 窓がある**——`startRecording()` は `phase = .recording` を立ててから
    /// `transcriber.begin()` と `audio.startTap` を待ち、その後で
    /// `emit(.recording(volatileText: ""))` する。窓の長さは `begin()` の費用そのもので、
    /// **定常時 1.2〜1.4 ms**（起動後の最初の 1 発話が 44〜540 ms 掛かっていた件は、
    /// `warmUpTranscriber()` の捨て往復で吸収した。詳細設計書 §10）。
    ///
    /// この窓で `state` を見て「待機だ」と判断してホットキーを止めると、
    /// **キー解放が二度と届かず、その発話が丸ごと消える**（フェーズ 1 最終レビューの
    /// 再レビュー指摘 1。`phase` を見れば窓は消える）。
    public var isBusy: Bool { phase != .idle }

    /// 状態機械が受け付ける遷移を決める。`SessionState` と分けてあるのは、
    /// `.failed` の表示中も内部的には待機であり、次の押下を受け付けねばならないため。
    private enum Phase { case idle, recording, processing }
    private var phase: Phase = .idle

    private var feedTask: Task<Void, Never>?
    private var collectTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var finalDeadlineTask: Task<Void, Never>?

    /// 確定 → 整形 → 挿入を走らせているタスク。
    ///
    /// **`run()` のイベントループはこれを待たない。** 待つと、処理中（実測 400〜800 ms）に
    /// 届いた ESC がループの手前で滞留し、**中断が原理的に効かなくなる**。
    /// 次の押下だけが `startRecording()` の頭でこれを待ち、発話の直列性を保つ。
    private var completionTask: Task<Void, Never>?

    private var latestVolatile = ""
    private var latestFinal = ""
    private var droppedAtStart = 0

    /// **終了要求で録音を打ち切ったとき、その発話をどこへ残せたか。**
    ///
    /// `run()` が戻った後に終了処理が読む（`Shutdown.perform` の `salvage`）。
    /// **`.nothingHeld` のままなら打ち切っていない**（＝発話は普通に完走した）。
    ///
    /// `isBusy` で代用してはならない——救出は `finishIdle()` まで走るので、
    /// **救出に成功した直後の `isBusy` は偽である。** それを「何も抱えていなかった」と
    /// 読むと、**打ち切ったことも履歴に在ることも一切告げないまま終わる。**
    public private(set) var shutdownSalvage: ShutdownSalvage = .nothingHeld

    /// 整形器へ最後に推論を投げた時刻。**冷え直しの判定にだけ使う**
    /// （`warmRefinerForUtterance()`）。
    private var lastRefinerActivityAt: ContinuousClock.Instant?

    /// 発話の通し番号。**前の発話の結果ストリームを消費しているタスクが、
    /// 次の発話の状態を触るのを防ぐために要る。**
    ///
    /// 認識ストリームが終端しないまま次の発話が始まる経路がある（中断や失敗の後）。
    /// 番号を持たせずに畳もうとすると、畳まれた側の後始末が次の発話の
    /// 「確定を待っている」状態を勝手に解いてしまい、**まだ届いていない確定を
    /// 待たずに暫定テキストで挿入する**（＝発話の一部を失う）。
    private var utterance = 0

    /// 処理中に ESC が届いたか（基本設計書 §4「中断は挿入が始まる前のどの状態からでも」）。
    private var isCancelRequested = false

    /// **挿入器がクリップボードを握っている最中か**（`whileInserting(_:)`）。
    ///
    /// `PasteboardInserter` は「退避 → 貼り付け → **既定 300 ms 待つ** → 復元」の順で
    /// 動き、その待ちのあいだ **actor は解放されている。**
    /// その窓で Undo キーが届くと `offerRawTextToClipboard()` が生テキストを
    /// クリップボードへ置き、**300 ms 後の復元がそれを上書きする**——
    /// 利用者は「クリップボードへ取り出しました」に従って ⌘V を押し、
    /// **まったく別のものを貼る**（最終レビュー 視点1 の B-2）。
    ///
    /// - Important: **この欠陥は差し替え器を本番へ配線するまで到達不能だった。**
    ///   `clipboard` が nil だったので `offerRawTextToClipboard()` は必ず
    ///   `.undoUnavailable` で戻っていた。配線した結果、本番で初めて生きた経路である。
    /// - Note: **世代の錠（`InsertionEpoch`）では塞げない。** あれが直列化するのは
    ///   AX の書き込みで、クリップボードは通らない。
    private var isInsertionInFlight = false

    // MARK: - 保留中の差し替えと Undo（FR-5(a) / FR-7）

    /// 整形の完了を待って差し替えを撃つタスクと、**その持ち主の発話番号。**
    ///
    /// - Important: **発話番号を一緒に持つ理由。** (a) の分岐は挿入の直後に `.idle` へ
    ///   戻して次の PTT を受け付けるので、**保留は 2 件以上重なりうる**
    ///   （例外ではなく通常経路である）。番号を持たずに `Task` だけを置いていた頃は、
    ///   古い方の `applyRevision` が 1 行目で `pendingRevision = nil` したときに
    ///   **新しい方の持ち手まで消えていた**（最終レビュー 視点3 の指摘 3）。
    ///   消えると「保留していない」ように見えるので、
    ///   **ESC も Undo キーも新しい方を取りやめられなくなり**、
    ///   「書き込みが 1 回も起きていないので完全に安全な取消しである」という
    ///   FR-7 / 基本設計書 §4 の約束が破れる。**発話は失われない**
    ///   （生テキストは欄にも履歴にもある）が、取消しの側が壊れる。
    /// - Note: **追い越された古い方は握り直さない。** 次の発話の挿入で世代が進むので、
    ///   撃っても `.staleEpoch` で断念され、**欄は 1 文字も変わらない**
    ///   （`InsertionEpoch`）。持つべきなのは常に最新の 1 件である。
    private struct PendingRevision {
        /// この差し替えを立てた発話の番号。**持ち主の照合はこれで行う。**
        let utterance: Int
        let task: Task<Void, Never>
        /// 取りやめ（ESC / Undo キー）が届いたか。
        ///
        /// **書き込みが 1 回も起きていない段階でのみ効く**（基本設計書 §4）。
        /// 差し替えが始まった後の取りやめは受け付けない——
        /// 範囲を選んだ直後に止めると選択だけが残る。
        var isCancelled: Bool
    }

    /// 保留中の差し替え。**最新の 1 件だけを持つ**（`PendingRevision` の注記）。
    /// **`isBusy` には数えない**（設計 opus §3.3）——捨てても生テキストは欄にある。
    private var pendingRevision: PendingRevision?
    /// **Undo で戻せる場所。これが FR-7 の門である**（履歴ではない）。
    ///
    /// 錨は `.ax` 経路の挿入でしか作られず、`replace` が成功したときにだけ
    /// `previousText` を持つ。**挿入していない発話へ Undo を撃つ経路は型として存在しない。**
    private var undoAnchor: ReplacementAnchor?
    /// 上の錨が有効な期限。**差し替えが成功した時刻から 10 秒**（詳細設計書 §8.3。
    /// 挿入時刻からではない——(a) では挿入と差し替えの間に最大 NFR-P6b ぶんの隔たりがある）。
    private var undoExpiry: ContinuousClock.Instant?
    private var undoExpiryTask: Task<Void, Never>?
    /// 進行中の Undo。**`isBusy` には数えない**（`pendingRevision` と同じ理由）。
    ///
    /// `run()` のループから待たずに起こす。待つと、AX が詰まる相手で
    /// **その間の PTT が丸ごと処理されない**（最終レビュー 視点3 の指摘 2）。
    private var undoTask: Task<Void, Never>?

    /// 確定テキストが出そろったか。**「最初の確定が届いたか」ではない。**
    ///
    /// キー解放後に届く確定は **1 件とは限らない**（V-12。実機の肉声で再現した）。
    /// 最初の確定で先へ進む定義だと、その後に届いた確定は `latestFinal` へ積まれても
    /// 二度と読まれず、**発話の末尾が失われる**（要件定義書 §2.8.4: 121 字で 約 38 字）。
    ///
    /// そこで**これ以上テキストが来ないと判る時点**——結果ストリームの終端——まで待つ。
    /// 認識器が黙り込んだ場合の安全弁は締め切り（`defaultFinalizeDeadline`）が担う。
    ///
    /// 録音中の `.final` でも先へ進まない（長い発話では途中で確定が出る。V-2 の実測）。
    /// V-12 の実測（103 秒の読み上げを実時間で供給）では、確定は**録音中に 1 件・
    /// 解放後に 1 件**届いた。前者を `latestFinal` へ積まずに捨てる変異を当てると、
    /// **548 字のうち前半が丸ごと落ちて後半だけが挿入される**
    /// （`FinalAfterReleaseTests` がこの変異を殺す。ただし既定の 30 秒では確定が
    /// 1 件しか出ないので、`GHOST_VOICE_V12_SECONDS=103` で回したときだけ殺せる）。
    private var isFinalSettled = false
    private var finalWaiters: [CheckedContinuation<Void, Never>] = []

    /// **差し替え（FR-5(a) / FR-7）まで含めた本番の組み立て。これが唯一の公開初期化子である。**
    ///
    /// `CompositeInserter.systemStack(...)` が返す組をそのまま渡すこと。
    /// **挿入器と差し替え器を別々に作って渡してはならない**——世代を共有しないと
    /// 差し替えが一度も効かず、クリップボードを共有しないと喪失時の退避先が
    /// 誰にも見えない場所になる（`InsertionStack` の注記。どちらも黙って壊れる）。
    ///
    /// - Important: **差し替え器を省ける口はここには無い**（フェーズ 2 の最終レビュー）。
    ///   以前は `inserter:` だけを取る公開初期化子が併存しており、**本番の 2 箇所が
    ///   そちらを呼んでいたため、製品では差し替えも Undo も一度も動いていなかった。**
    ///   注意書きは同じ型の doc に既に書かれていたが、本番はその初期化子を
    ///   呼んでさえいなかった——**doc コメントでは守れないことが証明された**ので、
    ///   省ける口は `internal`（`forTests`）へ落として本番から到達できなくしてある。
    public init(
        settings: SettingsStore,
        hotkey: any HotkeyMonitor,
        audio: any AudioCapturing,
        transcriber: any Transcribing,
        refiner: any Refining,
        insertion: InsertionStack,
        history: HistoryStore,
        vocabulary: VocabularyStore,
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() },
        postEventAuthorization: PostEventAuthorization = .shared,
        maxRecordingDuration: Duration = DictationSession.defaultMaxRecordingDuration,
        finalizeDeadline: Duration = DictationSession.defaultFinalizeDeadline,
        audioIdleSleepDelay: Duration = DictationSession.defaultAudioIdleSleepDelay
    ) {
        self.init(
            settings: settings, hotkey: hotkey, audio: audio, transcriber: transcriber,
            refiner: refiner, inserter: insertion.inserter, replacer: insertion.replacer,
            clipboard: insertion.clipboard, history: history, vocabulary: vocabulary,
            isSecureInputEnabled: isSecureInputEnabled,
            postEventAuthorization: postEventAuthorization,
            maxRecordingDuration: maxRecordingDuration, finalizeDeadline: finalizeDeadline,
            audioIdleSleepDelay: audioIdleSleepDelay)
    }

    /// **テスト専用の組み立て。`internal` なので本番ターゲットからは到達できない。**
    ///
    /// 差し替え器を省いた（＝常に (b) の分岐で動く）セッションを作れる唯一の口である。
    /// **フェーズ 1 と同じ経路の検査を残すために置いてあり、製品の組み立てではない。**
    ///
    /// 公開初期化子として残していた頃、本番の 2 箇所がこちらを呼んでいたために
    /// **FR-5(a) の差し替えと FR-7 の Undo が製品では一度も動かなかった。**
    /// 名前と可視性の両方で「本番の組み立てではない」ことを示している。
    ///
    /// - Parameter replacer: 差し替え器。**nil なら常に (b) の分岐**——整形を待ってから
    ///   挿入する、フェーズ 1 と同じ経路で動く（`refinementApplyMode` の設定によらない）。
    /// - Parameter clipboard: 自動で戻せない発話の生テキストを取り出す先（FR-7 の細目）。
    ///   **`replacer` と同じクリップボードを渡すこと。**
    static func forTests(
        settings: SettingsStore,
        hotkey: any HotkeyMonitor,
        audio: any AudioCapturing,
        transcriber: any Transcribing,
        refiner: any Refining,
        inserter: any TextInserting,
        replacer: TextReplacer? = nil,
        clipboard: (any ClipboardLeaving)? = nil,
        history: HistoryStore,
        vocabulary: VocabularyStore,
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() },
        postEventAuthorization: PostEventAuthorization = .shared,
        maxRecordingDuration: Duration = DictationSession.defaultMaxRecordingDuration,
        finalizeDeadline: Duration = DictationSession.defaultFinalizeDeadline,
        refinerWarmthWindow: Duration = DictationSession.defaultRefinerWarmthWindow,
        audioIdleSleepDelay: Duration = DictationSession.defaultAudioIdleSleepDelay
    ) -> DictationSession {
        DictationSession(
            settings: settings, hotkey: hotkey, audio: audio, transcriber: transcriber,
            refiner: refiner, inserter: inserter, replacer: replacer, clipboard: clipboard,
            history: history, vocabulary: vocabulary,
            isSecureInputEnabled: isSecureInputEnabled,
            postEventAuthorization: postEventAuthorization,
            maxRecordingDuration: maxRecordingDuration, finalizeDeadline: finalizeDeadline,
            refinerWarmthWindow: refinerWarmthWindow,
            audioIdleSleepDelay: audioIdleSleepDelay)
    }

    private init(
        settings: SettingsStore,
        hotkey: any HotkeyMonitor,
        audio: any AudioCapturing,
        transcriber: any Transcribing,
        refiner: any Refining,
        inserter: any TextInserting,
        replacer: TextReplacer?,
        clipboard: (any ClipboardLeaving)?,
        history: HistoryStore,
        vocabulary: VocabularyStore,
        isSecureInputEnabled: @escaping @Sendable () -> Bool,
        postEventAuthorization: PostEventAuthorization,
        maxRecordingDuration: Duration,
        finalizeDeadline: Duration,
        refinerWarmthWindow: Duration = DictationSession.defaultRefinerWarmthWindow,
        audioIdleSleepDelay: Duration = DictationSession.defaultAudioIdleSleepDelay
    ) {
        self.settings = settings
        self.hotkey = hotkey
        self.audio = audio
        self.transcriber = transcriber
        self.refiner = refiner
        self.inserter = inserter
        let anchoring = inserter as? any AnchoringTextInserting
        self.anchoringInserter = anchoring
        self.replacer = replacer
        self.clipboard = clipboard
        // **(a) の分岐に必要な 3 つが揃っているか。** 経路判定（`completeUtterance`）が
        // 見ているのと同じ条件である。
        self.canReviseInPlace = (anchoring != nil && replacer != nil && clipboard != nil)
        self.history = history
        self.vocabulary = vocabulary
        self.isSecureInputEnabled = isSecureInputEnabled
        self.postEventAuthorization = postEventAuthorization
        self.maxRecordingDuration = maxRecordingDuration
        self.finalizeDeadline = finalizeDeadline
        self.refinerWarmthWindow = refinerWarmthWindow
        self.audioIdleSleepDelay = audioIdleSleepDelay
        // 消費者が居ない構成（常駐デーモン）で際限なく溜め込まないよう上限を置く。
        //
        // **1 発話が出す状態は 6 件ではない。** `.recording(volatileText:)` は暫定結果の
        // たびに emit されるので、長い発話では数百件出る。`.bufferingNewest` は古い方から
        // 捨てるため、溢れて失われるのは**古い暫定表示**だけで、`.finalizing` 以降の
        // 遷移は直近に入って残る。上限の目的はメモリであって取りこぼしの防止ではない。
        (stateUpdates, stateContinuation) = AsyncStream<SessionState>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
    }

    // MARK: - UI から使う口（調査 `core-api-and-hud.md` の A-3）

    /// **状態を購読する。呼ぶたびに独立したストリームを返す**（欠落 1）。
    ///
    /// - Important: **単一消費者ではない。** HUD・終了待ち・履歴一覧が同時に持ってよい。
    ///   ただし**1 本を 2 箇所で読み回さないこと**（`AsyncStream` の制約は 1 本ごとに掛かる）。
    /// - Important: **MainActor から呼んでよい**（`nonisolated`。ロックを取るだけ）。
    /// - Important: **取りこぼしの防止装置ではない。** 読み手が遅れると古い暫定表示から
    ///   捨てる。**終了の判定にこれを使わないこと**——終了は actor 側の `isBusy` を見る。
    /// - Note: `run()` が戻ると終端する。**`run()` の後に呼ぶと即座に終端したものが返る。**
    public nonisolated func stateStream() -> AsyncStream<SessionState> {
        stateBroadcast.stream()
    }

    /// **状態を購読している人数。**
    ///
    /// 分配器は**登録済みの購読者にしか配らない**（`SessionBroadcast.yield`）。
    /// `stateStream()` を `for await` するタスクは、**最初に走ったときに初めて登録される**ので、
    /// 「購読を始めた直後に状態を撃つ」並びは競走になる——負ければその状態は誰にも届かず、
    /// 待っている側は永久に待つ。
    ///
    /// **検査が「購読が成立するまで待つ」ために公開している**（視点4 §9 の機序 A。
    /// `SessionMirrorTests` の 3 件が 10 秒の期限まで待って落ちる断続的失敗を作っていた）。
    /// **製品の穴にはならない**——分配器の購読者数は元から `SessionBroadcast` が公開している。
    public nonisolated var stateSubscriberCount: Int { stateBroadcast.subscriberCount }

    /// **マイク音量（RMS）を購読する**（欠落 3。HUD の録音インジケータ）。
    ///
    /// `AudioCapturing.level` は単一消費者なので、**セッションが 1 人で読んで配り直す。**
    /// 読み始めるのは `warmUp()`（＝`run()` の頭）である。
    ///
    /// - Important: **単一消費者ではない**（`stateStream()` と同じ）。
    /// - Important: **MainActor から呼んでよい**（`nonisolated`）。
    /// - Important: **値は録音中にしか流れない。** タップが外れているあいだは何も来ない
    ///   （「無音の 0」も来ない）ので、UI は状態（`.recording`）の側で表示を畳むこと。
    /// - Note: 遅れた読み手には**最新の 1 件だけ**を渡す。音量は積み上げても意味が無い。
    public nonisolated func levelStream() -> AsyncStream<Float> {
        levelBroadcast.stream(bufferingPolicy: .bufferingNewest(1))
    }

    /// **利用者へ告げること（差し替え・Undo の顛末）を購読する。**
    ///
    /// `SessionState` と分けてあるのは、ここに並ぶのが**発話が既に挿入先にある状態での
    /// 出来事**だからである（`SessionNotice`）。
    ///
    /// - Important: **単一消費者ではない。MainActor から呼んでよい。**
    /// - Important: **取りこぼしうる**（分配器の既定は最新 32 件）。
    ///   ただし `.textMayHaveBeenLost` を落とさないよう、購読側は速く抜けること。
    public nonisolated func notices() -> AsyncStream<SessionNotice> {
        noticeBroadcast.stream()
    }

    /// **モデル導入の進捗を購読する**（欠落 5。HUD / 権限案内）。
    ///
    /// フェーズ 1 は「導入が始まった」の 1 回きりしか出せず、**数分掛かる導入のあいだ
    /// 利用者には「押しても何も起きない」としか見えなかった。**
    ///
    /// - Important: **単一消費者ではない。MainActor から呼んでよい。**
    /// - Important: **導入済みの環境では 1 件も流れない**（`prepare` が即座に戻る）。
    ///   「進捗が来ないこと」を異常と判定しないこと。
    public nonisolated func assetInstallationEvents() -> AsyncStream<AssetInstallationEvent> {
        assetBroadcast.stream()
    }

    /// **LLM 整形が使えるか**（欠落 4。Apple Intelligence 無効時の「整形なし」バッジ）。
    ///
    /// - Important: **MainActor から同期で読んでよい**（`nonisolated`。actor を跨がない）。
    /// - Note: **設定の `refinementEnabled` とは別の量である。** こちらは環境の能力、
    ///   あちらは利用者の意思。両方が真のときだけ整形が走る。
    public nonisolated var isRefinementAvailable: Bool { refiner.isAvailable }

    /// **いま Undo で戻せるものがあるか**（FR-7。UI の「戻す」ボタンの活性）。
    ///
    /// - Important: **actor 隔離なので `await` が要る。** SwiftUI の `body` から
    ///   直接読めない。`SessionMirror` が MainActor 側の写しを持つ。
    public var canUndo: Bool {
        guard let undoExpiry else { return pendingRevision != nil }
        return ContinuousClock.now <= undoExpiry
    }

    // MARK: - 起動

    /// 起動時のウォームアップ。実測でコールド 1.9〜3.3 秒 / ウォーム 0.4 秒の差がある。
    ///
    /// **整形器の捨て推論は投げっぱなしにする。** `prewarm()` はコールド時に数秒掛かる
    /// ので、これを待ってからホットキーを読み始めると**起動直後の数秒間、押しても
    /// 何も起きない**（基本設計書 §6）。
    ///
    /// **認識器の捨て往復も同じく投げっぱなしにする**（詳細設計書 §10）。
    /// 詳細は `warmUpTranscriber()`。
    public func warmUp() async {
        // 【Task 8 申し送り】初回コスト（実測 16.7 ms / 23.8 ms）を最初の挿入から外す。
        refreshPermissions()

        // **単一消費者の口を、1 人で読んで配り直す。** ここで読み始めないと
        // HUD は音量も導入の進捗も受け取れない（調査 A-3 の欠落 3 / 5）。
        startFanOut()

        // 監視器へ Undo のバインドを反映する（設定ファイルが正）。
        // **失敗しても起動は続ける。** ここで諦めると PTT ごと使えなくなり、
        // 失うものが「Undo が効かない」から「ディクテーションが動かない」へ跳ね上がる。
        try? hotkey.rebindUndo(to: settings.settings.undoHotkey)

        do {
            try audio.prepare()
        } catch {
            emit(.failed(.audioUnavailable))
            emit(.idle)
        }

        // **発話ごとに呼び直さない。** ロケール枠（上限 5）は有限で、
        // 相異なるロケールを 5 種類試すと `localeReservationLimitReached` に達する。
        // 枠の解放そのものは `SpeechAnalyzerTranscriber.prepare` が行うようになったが
        // （持ち越し項目 5）、**再試行の回数を人の操作の回数に縛る**という規律は残す。
        // ロケールを変えるときは `prepareTranscriber(locale:kind:)` を明示的に呼ぶ。
        let current = settings.settings
        do {
            try await transcriber.prepare(locale: current.locale, kind: current.transcriberKind)
            warmUpTranscriber()
        } catch {
            emit(.failed(.transcriptionUnavailable))
            emit(.idle)
        }

        // **起動の捨て推論も「デーモンを温めた」印である。** 印を付けないと、
        // 起動直後に押した発話が**捨て推論の後ろへもう 1 本暖機を積む**
        // （実運用で、起動 1.6 秒後に押した発話がこの形で落ちていた）。
        lastRefinerActivityAt = ContinuousClock.now
        let refiner = self.refiner
        Task.detached(priority: .utility) { await refiner.prewarm() }
    }

    /// 単一消費者のストリームを 1 人で読み、分配器へ流す係を立てる。
    ///
    /// **2 回呼んでも 2 人にならない**（既に居れば何もしない）。2 人で読むと
    /// `AsyncStream` の制約に触れて異常終了する。
    private func startFanOut() {
        if levelTask == nil {
            let levels = audio.level
            let broadcast = levelBroadcast
            levelTask = Task {
                for await level in levels { broadcast.yield(level) }
            }
        }
        if assetTask == nil {
            let events = transcriber.assetInstallation
            let broadcast = assetBroadcast
            assetTask = Task {
                for await event in events { broadcast.yield(event) }
            }
        }
    }

    /// 解析器を 1 つ作って畳む捨て往復。**起動後の最初の発話の頭を落とさないために要る。**
    ///
    /// `prepare()` までしか行わない実装では、`SpeechAnalyzer` の初回生成費用を
    /// **起動後の最初の発話が払う**——実測で 低負荷 中央値 44.2 ms / 最大 540.4、
    /// **負荷下 中央値 64.5 ms** で、**負荷下では中央値で NFR-P1 の予算 50 ms を超えた**
    /// （詳細設計書 §10）。2 回目以降は 1.6〜2.2 ms と 3 桁小さい。
    /// **その差は発話の頭の取りこぼしとして出る**（`begin()` 復帰前のバッファは黙って捨てられる）。
    ///
    /// ## 起動は待たない
    ///
    /// 待つと**起動直後、押しても何も起きない時間**ができる（基本設計書 §4.1 の 9）。
    /// 整形器の捨て推論と同じく投げっぱなしにする。
    ///
    /// ## ただし本番の `begin()` と同時に生きてはならない
    ///
    /// **`SpeechModule` のインスタンスは 1 つの `SpeechAnalyzer` にしか装着できない**
    /// （詳細設計書 §4.3.1）。捨て往復と次の発話が重なると解析器が 2 つ生きる窓ができる。
    ///
    /// そこで**`finalizeTask` の枠をそのまま使う。** `startRecording()` の頭は必ず
    /// `drainFinalizeTask()` を通るので、**捨て往復が畳まれるまで次の `begin()` は始まらない。**
    /// 新しい待ち合わせを足していないので、既にある直列性の保証をそのまま借りている。
    ///
    /// - Note: 起動直後に押された場合だけ、その押下は捨て往復の残りを待つ。
    ///   **待つ量は「どのみち払う初回費用」なので増えていない**（増えるのは捨て往復の
    ///   `finish()` ぶん。実測は本書のタスク報告と詳細設計書 §10）。
    ///   起動から最初の押下までに往復が終わっていれば 0 ms である。
    private func warmUpTranscriber() {
        let transcriber = self.transcriber
        finalizeTask = Task {
            guard let stream = try? await transcriber.begin() else { return }
            try? await transcriber.finish()
            // **結果ストリームは読み捨てる。** `finish()` を跨いで生かしておくのは、
            // 解放が先に走ると `onTermination` が結果の消費を畳んでしまうため。
            // ここを抜けた時点で解放され、消費タスクも畳まれる。
            withExtendedLifetime(stream) {}
        }
    }

    /// ロケールや認識種別を変えたときに呼ぶ（欠落 11）。
    ///
    /// **自動で再試行しないための入口である。** 失敗はそのまま投げるので、
    /// 呼び出し側（設定画面）がユーザーへ見せ、再試行の回数を人の操作の回数に縛る。
    ///
    /// - Important: **発話を抱えている間は `DictationSessionError.busy` を投げる。**
    ///   フェーズ 1 は「録音中に呼ぶな」という約束を呼び出し側へ押し付けていたが、
    ///   **守られたかを確かめる手段が呼び出し側にも無い**——`state` を読んでから
    ///   これを呼ぶまでの間に PTT が押されうるためである。**判定は actor の中でしか
    ///   安全に置けない**ので、ここで見る。
    /// - Important: **`isBusy`（`phase`）を見る。`state` ではない。**
    ///   `phase` が立ってから最初の `emit` までに窓があり、そこで `state` を見ると
    ///   「待機中だ」と誤る（`isBusy` の注記）。
    /// - Important: **MainActor から `await` してよい。** ただしモデルの導入を伴うと
    ///   数分戻らない（進捗は `assetInstallationEvents()` で見る）。
    /// - Throws: `DictationSessionError.busy` — 発話の最中。
    ///   `TranscriptionError.*` — 準備そのものの失敗。
    public func prepareTranscriber(locale: Locale, kind: TranscriberKind) async throws {
        guard phase == .idle else { throw DictationSessionError.busy }
        try await transcriber.prepare(locale: locale, kind: kind)
    }

    /// Undo のバインドを監視器へ反映する（FR-11。設定画面から）。
    ///
    /// **`SettingsStore` の保存とは別の操作である。** 保存しただけでは監視器は
    /// 古いキーを見ている（`HotkeyMonitor.currentUndoBinding` の注記）。
    ///
    /// - Important: **MainActor から `await` してよい。** タップは張り替えないので
    ///   録音中に呼んでも発話を巻き添えにしない。
    public func rebindUndoHotkey(to binding: HotkeyBinding) throws {
        try hotkey.rebindUndo(to: binding)
    }

    /// キー送出の権限を照会し直す。**起動時と権限フロー通過時に呼ぶ。**
    /// 外部で権限を変えられても追随しないので、これを呼ばない限り
    /// `.clipboardOnly` のままになりうる（詳細設計書 §9）。
    public func refreshPermissions() {
        postEventAuthorization.refresh()
        // 初回 23.8 ms を起動時に払っておく。値は使わない（状態は挿入のたびに見る）。
        _ = isSecureInputEnabled()
    }

    /// ホットキーのイベントを処理し続ける。**プロセスにつき 1 回だけ呼ぶこと。**
    ///
    /// 監視器のイベント列が終端するか、このタスクがキャンセルされると戻る。
    /// 戻る際に `stateUpdates` も終端させるので、状態を購読している側もそこで抜けられる。
    ///
    /// - Note: 処理中の発話は巻き添えにしない。イベント列が尽きた後、処理中の発話を
    ///   見届けてから `stateUpdates` を終端する（`Task<Void, Never>.value` は待つ側が
    ///   キャンセルされても早く返らないので、`run()` を畳んでも見届けは行われる）。
    ///   **ただしプロセスの寿命はここの管轄外である。** `exit()` で落とすと、⌘V の送出後・
    ///   クリップボードの復元前で切れてテキストが失われうる。**終了処理は
    ///   `state == .idle` を待ってから行うこと。**
    public func run() async {
        await warmUp()
        for await event in hotkey.events {
            switch event {
            case .pressed: await startRecording()
            case .released: stopRecording(cancelled: false)
            case .cancelled: requestCancel()
            // **取りこぼしは中断ではない**（基本設計書 §7 の縮退表）。監視が死んで
            // キー解放を受け取れなくなっただけなので、最大録音時間の満了と同じく
            // **確定として扱い、そこまでの発話を届ける。** 利用者は喋っていたのだから。
            case .interrupted: stopRecording(cancelled: false)
            // **待たない。** 待つとイベントループが止まり、その間の PTT が処理されない。
            case .undoRequested: beginUndo()
            }
        }
        // **イベント列が尽きた時点でまだ録音中なら、その発話を救う。**
        // ここへ来る経路は「終了処理がホットキーを止めた」だけである
        // （監視器の死は `.interrupted` で来るので、そちらは確定として扱われる）。
        salvageAbandonedRecording()
        await completionTask?.value
        completionTask = nil
        // **保留中の差し替えは見届けない。** 捨てても生テキストは欄にあり、
        // 待つと終了が最大 NFR-P6b（既定 3 秒）延びる（設計 opus §3.3）。
        pendingRevision?.task.cancel()
        pendingRevision = nil
        undoTask?.cancel()
        undoTask = nil
        levelTask?.cancel()
        levelTask = nil
        assetTask?.cancel()
        assetTask = nil
        stateContinuation.finish()
        stateBroadcast.finish()
        levelBroadcast.finish()
        noticeBroadcast.finish()
        assetBroadcast.finish()
    }

    /// ESC（`.cancelled`）を受けたときの分岐。**どの状態から押されたかで意味が変わる。**
    ///
    /// - 録音中: そのまま中断する
    /// - 確定待ち・整形中: 中断を予約する。挿入も履歴への整形結果も行わない
    /// - **挿入を始めた後: 何も起きない。** 予約は立つが、`completeUtterance` が
    ///   それを読むのは挿入の手前までなので、挿入は完走する。**これは意図した挙動である。**
    ///   ⌘V を送出した後に中断すると、クリップボードの復元だけが走って
    ///   **テキストがどこにも残らない**（Task 8 が潰した欠陥と同じ形）。
    ///   「中断が効かない」より「テキストが消える」ほうが重い。
    ///
    /// - Important: **挿入より後で `isCancelRequested` を読んではならない。**
    ///   読んだ瞬間に上記の欠陥が復活する。境界は
    ///   `cancelAfterInsertionStartedIsIgnored` が押さえている。
    private func requestCancel() {
        switch phase {
        case .recording: stopRecording(cancelled: true)
        case .processing: isCancelRequested = true
        // **保留中の差し替えに対する ESC は「取りやめる」として効く**（基本設計書 §4）。
        // 書き込みが 1 回も起きていないので、これは完全に安全な取消しである。
        // 保留が無ければ何も起きない（従来どおり）。
        case .idle: cancelPendingRevision()
        }
    }

    // MARK: - 録音

    private func startRecording() async {
        // 押された。マイクを止める予約が入っていれば取り消す。
        // **`await` の手前で取り消す。** 後ろに置くと、待っている間に予約が発火しうる。
        cancelAudioSleep()

        // 前の発話の確定〜挿入が走っていれば、終わるまで待つ。**押下は取りこぼさない。**
        // `run()` 側で待たないのは ESC を滞留させないためで、直列性はここが担う。
        await completionTask?.value
        completionTask = nil

        // 二重の押下は無視する。混在入力源では押下だけが繰り返し届きうる。
        //
        // **この guard が有効なのは `run()` が唯一の呼び出し元で、単一のイベントループから
        // 直列に呼ぶからである。** 判定から `phase = .recording` までの間に `await`
        // （`drainFinalizeTask()`）が挟まるので、複数の文脈からこれを呼ぶと 2 回通り抜けうる。
        // 呼び出し元を増やすときは、ここに中間相（`.starting`）を置くこと。
        guard phase == .idle else { return }

        // 前の発話の確定処理が残っていれば、先に片付ける。
        // 2 つの `SpeechAnalyzer` が同時に生きる窓を作らない（詳細設計書 §4.3.1）。
        await drainFinalizeTask()

        // 前の発話の結果ストリームを消費しているタスクは、**打ち切らずに手放す。**
        //
        // 打ち切ると、打ち切られた側の後始末（`updatesEnded(for:)`）が
        // 「いつ actor へ戻ってくるか」を呼び出し側から決められなくなる。それが
        // 次の発話の準備中に届くと、**まだ届いていない確定を待たずに先へ進む**
        // （＝暫定テキストで挿入する）。打ち切らずに通し番号で締め出せば、
        // 遅れて届いても無視されるだけで済み、**その経路をテストから駆動できる。**
        //
        // 手放したタスクは、認識器が結果ストリームを終端した時点で自然に終わる
        // （`finish()` と `cancelActiveSession()` のどちらを通っても終端する）。
        collectTask = nil

        utterance &+= 1
        let utterance = self.utterance

        phase = .recording
        latestVolatile = ""
        latestFinal = ""
        isFinalSettled = false
        isCancelRequested = false
        // **前の発話の計測値を残さない。** 中断や失敗で終わった発話の後に読むと、
        // 前の発話の値が「今の発話の計測値」として返る。
        latestMetrics = nil
        droppedAtStart = audio.droppedBufferCount

        let updates: AsyncThrowingStream<TranscriptionUpdate, Error>
        do {
            // **タップより先に `begin()`。** `feed` は `begin()` 復帰前のバッファを
            // 黙って捨てるので、順序を逆にすると発話の頭が落ちる（Task 5 申し送り）。
            updates = try await transcriber.begin()
        } catch {
            fail(.transcriptionUnavailable)
            return
        }

        let format = await transcriber.requiredAudioFormat
        let buffers: AsyncStream<AVAudioPCMBuffer>
        do {
            buffers = try audio.startTap(format: format)
        } catch {
            // 認識セッションだけが開いたまま残らないようにする。
            let transcriber = self.transcriber
            finalizeTask = Task { try? await transcriber.finish() }
            fail(.audioUnavailable)
            return
        }

        emit(.recording(volatileText: ""))

        // **喋っている間に整形器を暖める。** 冷えたまま解放を迎えると、(b) の分岐の
        // 予算（既定 750 ms）が再ロードだけで尽きる（`warmRefinerForUtterance()`）。
        warmRefinerForUtterance()

        let transcriber = self.transcriber
        feedTask = Task {
            for await buffer in buffers {
                // `for await` が渡すバッファはタスク隔離とみなされるので、
                // `sending` を要求する `feed` へそのままは渡せない。供給元は
                // タップごとに新しいオブジェクトを作り（Task 5 が手動レンダリングで
                // 確認）、ここを出た後に誰も触らないので所有権を渡してよい。
                await transcriber.feed(EngineAudioCapture.detached(buffer))
            }
        }
        collectTask = Task { [weak self] in
            do {
                for try await update in updates { await self?.apply(update, for: utterance) }
            } catch {
                // 認識ストリームの終了は正常系にも含まれるため握りつぶす。
                // 異常終了だった場合も、下の `updatesEnded(for:)` が待ちを解く。
            }
            await self?.updatesEnded(for: utterance)
        }

        startMaxDurationTimer(for: utterance)
    }

    private func startMaxDurationTimer(for utterance: Int) {
        maxDurationTask = Task { [weak self, maxRecordingDuration] in
            try? await Task.sleep(for: maxRecordingDuration)
            guard !Task.isCancelled else { return }
            await self?.stopRecordingFromTimer(for: utterance)
        }
    }

    /// 満了が `cancel()` と競り合って通り抜けた場合に、**次の発話を打ち切らない**ための門。
    /// `apply` / `updatesEnded` と同じ通し番号の締め出しをここにも掛ける。
    private func stopRecordingFromTimer(for utterance: Int) {
        guard utterance == self.utterance else { return }
        stopRecording(cancelled: false)
    }

    private func apply(_ update: TranscriptionUpdate, for utterance: Int) {
        // 前の発話ぶんの遅れて届いた結果。今の発話のテキストへ混ぜてはならない。
        guard utterance == self.utterance else { return }
        switch update {
        case .volatile(let text):
            latestVolatile = text
            if phase == .recording { emit(.recording(volatileText: text)) }
        case .final(let text):
            // **積むだけで先へ進めない。** 確定は解放の前にも後にも複数届きうる
            // （V-12）。ここで待ちを解くと、**その後に届いた確定は二度と読まれず
            // 発話の末尾が失われる。** 先へ進めるのは `updatesEnded` と締め切りだけ。
            latestFinal += text
        }
    }

    /// 結果ストリームが終わった。これ以上テキストは来ない。
    ///
    /// **確定待ちを解くのはここである**（V-12 の修正。それまでは「解放後の最初の確定」で
    /// 解いていたため、後から届いた確定が読まれなかった）。
    ///
    /// **前の発話ぶんの終了で、今の発話の確定待ちを解いてはならない。**
    private func updatesEnded(for utterance: Int) {
        guard utterance == self.utterance else { return }
        settleFinal()
    }

    // MARK: - 確定 → 整形 → 挿入

    /// 録音を終える。**確定から挿入までは待たずにタスクへ逃がす。**
    ///
    /// 待たない理由は 2 つある。
    ///
    /// 1. **キャンセルの遮蔽。** ここへ来る経路の 1 つは最大録音時間の満了で、
    ///    そのときの呼び出し元は直上で `cancel()` した `maxDurationTask` 自身である。
    ///    もう 1 つはアプリ終了時に `run()` のタスクが畳まれる場合。どちらでも、
    ///    続きがキャンセル状態のタスクで走ると次が起きる（いずれも実測で確認した）:
    ///    `AsyncStream` の `next()` が即座に nil を返すため `drainFeed` が末尾を待たずに
    ///    抜けて**発話の末尾が認識器へ届かず**、同じ理由で `withTimeout` が常に nil を
    ///    返して**整形が必ず縮退し**、`PasteboardInserter` の復元待ち（120 ms）が 0 に
    ///    なって**⌘V が処理される前にクリップボードを戻して発話を失う**
    ///    （Task 8 が潰した欠陥の再発）。非構造化タスクはキャンセルを継承しない。
    /// 2. **ESC を滞留させない。** `run()` のループがここで 400〜800 ms 止まると、
    ///    その間に届いた `.cancelled` はイベント列に溜まったままになり、
    ///    中断が原理的に効かなくなる（基本設計書 §4）。
    ///
    /// 発話の直列性は `startRecording()` の頭が `completionTask` を待つことで保つ。
    private func stopRecording(cancelled: Bool) {
        // 解放を 2 回受け取る経路（最大録音時間の満了とキー解放の競合）がある。
        guard phase == .recording else { return }
        phase = .processing
        // **キーを離した後の ESC を中断として受け取るために要る**（`HotkeyMonitor`
        // の `setSessionBusy` の注記。フェーズ 1 の最終レビュー I-1）。
        // これが無いと、下の `isCancelRequested` を立てる経路が実機で到達不能になる。
        hotkey.setSessionBusy(true)
        let releasedAt = ContinuousClock.now

        maxDurationTask?.cancel()
        maxDurationTask = nil

        completionTask = Task { [self] in
            await completeUtterance(cancelled: cancelled, releasedAt: releasedAt)
        }
    }

    private func completeUtterance(cancelled: Bool, releasedAt: ContinuousClock.Instant) async {
        let textDeadline = releasedAt + finalizeDeadline
        // **設定はここで 1 度だけ写し取る。** 整形と履歴で別々に読み直すと、
        // 発話の途中で設定が変わったときに 1 発話へ 2 つの設定が混ざる。
        let current = settings.settings
        emit(.finalizing)

        // 1. タップを外す。`removeTap` の端数バッファとリサンプラの drain 出力
        //    （実測 231 フレーム = 14.4 ms）がここでストリームへ流れる（詳細設計書 §3.4）。
        audio.stopTap()

        // 2. **末尾まで供給しきってから確定させる。** 先に `finish()` を撃つと、
        //    解析器の入力が閉じたあとに末尾が届いて、発話の末尾がそのぶん落ちる。
        await drainFeed(before: textDeadline)

        // 3. 確定を撃つ。**復帰は待たない。** `finish()`
        //    （`finalizeAndFinishThroughEndOfInput()`）の復帰より、結果ストリームの
        //    終端の方が先か同時に来る。**待つのはストリームであって復帰ではない。**
        let transcriber = self.transcriber
        finalizeTask = Task { try? await transcriber.finish() }

        // 4. **結果ストリームの終端**か締め切りを待つ（V-12 の修正）。
        //
        //    旧定義は「解放以降の**最初の**確定」で先へ進み、`latestFinal` を
        //    `await` を挟まず同期的に読んでいた。**その後に届いた確定は積まれても
        //    二度と読まれず、発話の末尾が失われた**——実機の肉声で再現している
        //    （2026-08-14。121 字の発話で末尾 約 38 字。要件定義書 §2.8.4）。
        //    合成音声 103 秒で解放後の確定が 1 件だったのは、
        //    **危険な条件が起きなかっただけ**である。
        //
        //    終端まで待てば「これ以上テキストは来ない」が保証される。**代償は
        //    最初の確定から終端までの待ちで、そのぶん M2 が伸びる**（詳細設計書 §10）。
        //    認識器がストリームを閉じ忘れた場合の安全弁は締め切りが担う。
        scheduleFinalDeadline(at: textDeadline)
        await awaitFinalSettled()

        let finalize = ContinuousClock.now - releasedAt
        // 確定が来なかった場合だけ暫定テキストへ縮退する。空で捨てるよりは残す。
        let raw = (latestFinal.isEmpty ? latestVolatile : latestFinal)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // **secure input の判定は整形の手前で行う。**
        //
        // 挿入時にしか見ない実装だと、拒否する頃には発話が既に LLM 整形
        // （`FoundationModels`）を通っている。基本設計書 §7 が挙げる害の 1 番目が
        // それであり、挿入の入口で塞いでも消えない。ここで弾けば、整形にも履歴にも
        // クリップボードにも渡らない。
        //
        // 中断（ESC）の経路もここを通る。中断時の履歴は挿入経路を通らないので、
        // 例外を挿入側だけに実装するとこの経路からパスワードが `history.json` へ入る
        // （基本設計書 §4 の注記）。
        guard !isSecureInputEnabled() else {
            fail(.refusedSecureInput)
            return
        }

        // 解放時に中断だった場合と、確定を待つ間に ESC が届いた場合の両方をここで受ける。
        guard !cancelled, !isCancelRequested else {
            finishCancelled(raw: raw, locale: current.localeIdentifier)
            return
        }

        guard !raw.isEmpty else {
            fail(.noSpeechRecognized)
            return
        }

        // --- 整形を**起動する**。待つかどうかは経路が決める（要件定義書 FR-5 の細目）。
        //
        // **経路判定より先に起動する。** 判定（`canCaptureAnchor()`）は AX の往復を
        // 数回伴うので、後から起動すると (b) の分岐でその往復ぶん整形の開始が遅れ、
        // **余裕 1 ms しかない (b) の予算（199 + 750 + 50 = 999 ms）を直接食う。**
        let refineStart = ContinuousClock.now
        let refinement = startRefinement(raw: raw, settings: current)

        // --- 経路判定（要件定義書 FR-5 の細目 / §2.8.6 の C-1〜C-7）
        //
        // **挿入してからでは遅い。** 生テキストを入れた後に「錨が取れなかった」と
        // 判っても (b) へは戻れない——整形結果を入れる手段が差し替えしか無いためである。
        if current.refinementApplyMode == .afterInsert, refinement != nil,
            let anchoringInserter, replacer != nil, anchoringInserter.canCaptureAnchor()
        {
            await insertRawThenRevise(
                raw: raw, refinement: refinement, inserter: anchoringInserter,
                settings: current, releasedAt: releasedAt, finalize: finalize,
                refineStart: refineStart)
            return
        }

        // --- (b) 差し替えできない挿入先。**整形を待ってから挿入する**（フェーズ 1 と同じ）。
        emit(.refining)
        let refined = await Self.awaitRefinement(refinement, within: current.refinementTimeout)
        let refine = ContinuousClock.now - refineStart

        // 整形は実測で 350〜750 ms 掛かる。**その間に押された ESC はまだ間に合う。**
        guard !isCancelRequested else {
            finishCancelled(raw: raw, locale: current.localeIdentifier)
            return
        }

        // --- 挿入
        //
        // **直上が最後の中断点である。ここから後で `isCancelRequested` を読まないこと**
        // （`requestCancel()` の注記。読むと ⌘V の後で止まって発話が消える）。
        emit(.inserting)
        let insertStart = ContinuousClock.now
        let outcome = await whileInserting { await inserter.insert(refined ?? raw) }
        let insert = ContinuousClock.now - insertStart

        // **挿入の直前に secure input が有効化された場合**（整形中にパスワード欄へ
        // 移った）。挿入器が拒否している以上、この発話はどこへも入っていない。
        //
        // ここを素通りさせると `.failed` が出ないまま `.idle` へ落ち、
        // **挿入されていないのに `[metrics]` だけが出て成功に見える**
        // （フェーズ 1 の最終レビュー M-2）。計測値も残さない——測ったのは
        // 「拒否に掛かった時間」であって挿入ではない。
        guard outcome != .refusedSecureInput else {
            fail(.refusedSecureInput)
            return
        }

        // **挿入したので、前の発話の錨はもう戻せる場所を指していない**（世代が進んでいる）。
        clearUndoTarget()

        latestMetrics = Metrics.Sample(
            finalize: finalize, refine: refine, insert: insert,
            droppedBuffers: audio.droppedBufferCount - droppedAtStart,
            // **(b) の分岐なので整形はクリティカルパスの上にある。**
            waitedForRefinementBeforeInsert: true
        )

        // --- 履歴はクリティカルパスの外で書く（同期 I/O。詳細設計書 §8.2）
        //
        // **`.refusedSecureInput` は履歴に記録してはならない**（Task 8 の裁定）。
        // `recordableMethod` が nil を返すのがその一手間で、ここを素通りさせると
        // パスワードが `history.json` へ平文で入る。
        // **履歴が実際に残ったか。** `.failedEverywhere` のときは唯一の写しなので、
        // 下の告知の文言がこの値で変わる（再レビュー B-1）。
        var retainedInHistory = false
        if let method = outcome.recordableMethod {
            let stored = record(
                raw: raw, refined: refined, locale: current.localeIdentifier, method: method)
            // **上限 0 は失敗にしない。** 挿入できているので発話は利用者の手元にあり、
            // 履歴を残さないのは利用者自身の指示である（`HistoryStore.normalized`）。
            // 一方、**書けなかった**のは伝える。
            if stored == .failed {
                // 手元にテキストがあるかどうかで文言が変わる。
                // **`.failedEverywhere` では手元にも無い**ので「発話そのものが失われた」。
                fail(.historyUnavailable(insertedElsewhere: outcome.leftTextWithUser))
                return
            }
            retainedInHistory = stored == .stored
        }

        // **どこにも入らず、クリップボードへも残せなかった。** 履歴だけが写しである
        // （`InsertionOutcome.failedEverywhere`）。以前はここが `.clipboardOnly` に
        // 化けており、「⌘V で貼れます」と告げていた（最終レビュー A-2）。
        //
        // **その履歴も残らなかったのなら、発話はどこにも無い。** 上限 0 は
        // 「挿入できている限りは失敗ではない」が、挿入できていないここでは話が逆になる。
        guard outcome != .failedEverywhere else {
            fail(.insertionFailed(retainedInHistory: retainedInHistory))
            return
        }

        finishIdle()
    }

    // MARK: - (a) 生テキストを先に挿入し、整形は後から差し替える（FR-5(a)）

    /// **録音の開始で整形器を暖める。投げっぱなしにする（待たない）。**
    ///
    /// ## なぜ起動時の `prewarm()` だけでは足りないのか（実測 / 2026-08-15 / M3 / macOS 26.5.2）
    ///
    /// モデルの常駐は**プロセス外のデーモン**にある（§5.2）。これは
    /// 「プロセスを作り直しても速いまま」という良い面と、
    /// **「しばらく使わないと、プロセスが生きていても冷える」という悪い面**の
    /// 両方を意味する。後者は測るまで正本に無かった。
    ///
    /// 同じ 9 字の発話を、間隔を変えて実 LLM へ通した値（`generate` の実時間）:
    ///
    /// | 直前の推論からの間隔 | 1 発目 | **その直後の 2 発目** |
    /// |---|---|---|
    /// | 連続（0 秒） | 454 ms | — |
    /// | 5 秒 | 2134 ms | 492 ms |
    /// | 10 秒 | 369 ms | 331 ms |
    /// | 15 秒 | 1082 ms | 399 ms |
    /// | 20 秒 | 1094 ms | 380 ms |
    /// | 30 秒 | 1838 ms | 362 ms |
    /// | 45 秒 | 760 ms | 336 ms |
    /// | 60 秒 | 960 ms | 336 ms |
    ///
    /// **1 発目だけが遅く、直後の 2 発目は必ず 330〜490 ms に戻る。**
    /// 眠らずに 60 秒待つ対照（`Task.sleep` を使わない忙しい待ち）でも 909 ms だったので、
    /// **プロセスの休止（App Nap）ではなくデーモン側の冷えである。**
    ///
    /// **実運用の発話間隔は 6 秒〜2.5 分**（利用者の履歴 / 2026-08-15）。
    /// つまり**ほぼ毎回この費用を払っており、(b) の予算 750 ms は再ロードだけで尽きる。**
    /// 実運用の 10 発話を 45 秒間隔で再現すると **1/10 しか間に合わなかった**
    /// のに対し、**同じ 10 発話を連続で投げれば 8/10 が検査も通って受理される。**
    /// **落としていたのは検査ではなく打ち切りである。**
    ///
    /// ## だから「発話が始まった時点」で暖める
    ///
    /// 押下から解放までの間に暖機を済ませれば、解放の時点ではデーモンが温まっている。
    /// **待たないので「押しても何も起きない時間」は作らない**（基本設計書 §6 /
    /// 詳細設計書 §4.1 の 9。認識器の捨て往復 `warmUpTranscriber()` と同じ方針である）。
    ///
    /// - Important: **暖機そのものが 1 回の推論である。** 直前に推論を投げたばかりなら
    ///   投げ直さない（`refinerWarmthWindow`）。投げ直すと発話ごとに推論が 2 回になり、
    ///   短い間隔で連射したときに**暖機が本番の後ろに並ぶ**。
    /// - Note: **印を立てるのはここと `warmUp()` の 2 箇所だけである。**
    ///   本番の整形（`startRefinement`）でも立てたくなるが、**立てていない**——
    ///   立てても効くのは「長い発話の直後にすぐ次を押した」場合だけで、
    ///   **その差を検査で固定する手段が無い**（時計を進められない）。
    ///   立てないことの代償は**余計な暖機が 1 回走ること**だけで、発話は失われない。
    private func warmRefinerForUtterance() {
        guard settings.settings.refinementEnabled, refiner.isAvailable else { return }
        let now = ContinuousClock.now
        if let last = lastRefinerActivityAt, now - last < refinerWarmthWindow { return }
        lastRefinerActivityAt = now
        let refiner = self.refiner
        Task.detached(priority: .utility) { await refiner.prewarm() }
    }

    /// `refinerWarmthWindow` の既定。
    ///
    /// **要件値ではない。** 上の実測で「1 発目が遅くなる」は 5 秒の間隔でも起きているので、
    /// **温まっている保証がある区間は「直前の推論の直後」だけ**である。
    /// ここを 0 にすると発話ごとに推論が必ず 2 回になり、連射時に暖機が本番の前へ割り込む。
    /// **10 秒は「連射のときだけ省く」ための保守的な値**で、
    /// 実運用の発話間隔（6 秒〜2.5 分）の下側の端に置いてある。
    static let defaultRefinerWarmthWindow: Duration = .seconds(10)

    /// 整形を起動する。**待たない。** 打ち切りは経路で決まる。
    ///
    /// **`Task.detached` にしてある。** 呼び出し元（`completionTask`）は終了時に
    /// 畳まれることがあり、キャンセルを継承すると `withTimeout` が常に nil を返して
    /// **整形が必ず縮退する**（`stopRecording` の注記にある実測済みの罠と同じ形）。
    ///
    /// - Parameter settings: 発話の頭で 1 度だけ写し取った設定。
    ///   **打ち切りは (a) なら `revisionDeadline`、(b) なら `refinementTimeout`。**
    ///   (a) を選んだのに錨が取れず (b) へ落ちた場合は、待つ側が短い方で打ち切る
    ///   （`awaitRefinement(_:within:)`）。
    private func startRefinement(raw: String, settings: Settings) -> Task<String?, Never>? {
        guard settings.refinementEnabled else { return nil }
        let refiner = self.refiner
        let terms = vocabulary.terms
        let locale = settings.locale
        let timeout =
            settings.refinementApplyMode == .afterInsert
            ? settings.revisionDeadline : settings.refinementTimeout
        return Task.detached(priority: .userInitiated) {
            await refiner.refine(raw, locale: locale, terms: terms, timeout: timeout)
        }
    }

    /// 整形の完了を待つ。**締め切りを過ぎたら待つのをやめる。**
    ///
    /// `withTimeout` と同じ形。**打ち切った作業の完了は待たない**——待つと、
    /// 打ち切りに応じない生成のあいだユーザーへの文字入力が止まる（`Refining` の注記）。
    private static func awaitRefinement(
        _ task: Task<String?, Never>?, within deadline: Duration
    ) async -> String? {
        guard let task else { return nil }
        let (stream, continuation) = AsyncStream<String?>.makeStream()
        let waiter = Task {
            continuation.yield(await task.value)
            continuation.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            continuation.yield(nil)
            continuation.finish()
        }
        defer {
            waiter.cancel()
            timer.cancel()
            // 待ちはしないが cancel は送る。止められる生成なら止めて計算資源を返す。
            task.cancel()
        }
        var results = stream.makeAsyncIterator()
        return await results.next() ?? nil
    }

    /// **(a) の分岐。生テキストを直ちに挿入し、整形は後から差し替える。**
    ///
    /// ここを抜けた時点で `phase` は `.idle` であり、**次の PTT を受け付ける。**
    /// 差し替えは「忙しい」に数えない（設計 opus §3.3）——捨てても生テキストは欄にある。
    ///
    /// - Important: **`.refining` を通らない。** したがって中断（ESC）が効くのは
    ///   `recording` / `finalizing` の 2 状態と、**保留中の差し替え**である
    ///   （基本設計書 §4）。
    private func insertRawThenRevise(
        raw: String,
        refinement: Task<String?, Never>?,
        inserter: any AnchoringTextInserting,
        settings: Settings,
        releasedAt: ContinuousClock.Instant,
        finalize: Duration,
        refineStart: ContinuousClock.Instant
    ) async {
        emit(.inserting)
        let insertStart = ContinuousClock.now
        let inserted = await whileInserting { await inserter.insertCapturingAnchor(raw) }
        let insert = ContinuousClock.now - insertStart

        // 挿入の直前に secure input が有効化された場合（(b) と同じ扱い）。
        guard inserted.outcome != .refusedSecureInput else {
            refinement?.cancel()
            fail(.refusedSecureInput)
            return
        }

        clearUndoTarget()

        latestMetrics = Metrics.Sample(
            finalize: finalize, refine: .zero, insert: insert,
            droppedBuffers: audio.droppedBufferCount - droppedAtStart,
            // **整形はこの後ろにある。** 足すと NFR-P6a の判定が (b) の意味になる。
            waitedForRefinementBeforeInsert: false
        )

        // **履歴は挿入の直後に書く**（整形はまだ届いていないので `refinedText` は nil）。
        // 差し替えが成功したら同じ id を更新する（詳細設計書 §8.3）。
        guard let method = inserted.outcome.recordableMethod else {
            refinement?.cancel()
            finishIdle()
            return
        }
        let entry = HistoryEntry(
            rawText: raw, refinedText: nil,
            localeIdentifier: settings.localeIdentifier, insertionMethod: method
        )
        // **書けなければ差し替えを始めない**（詳細設計書 §8.3）。
        // 履歴に写しが無いまま欄を書き換えると、`.lost`（R-9）に落ちたときの
        // 4 重の受けのうち 1 番目が抜ける。**上限 0 で「残らなかった」場合も同じ**——
        // 直後の `history.update` が対象を見つけられないので、差し替えを始めてはならない。
        let stored = record(entry)
        guard stored == .stored else {
            refinement?.cancel()
            if stored == .failed {
                fail(.historyUnavailable(insertedElsewhere: inserted.outcome.leftTextWithUser))
            } else if inserted.outcome == .failedEverywhere {
                // **上限 0 と「どこにも挿入できなかった」が重なった。**
                // 欄にもクリップボードにも履歴にも無い——発話は完全に失われている。
                // ここを下の `notify` へ落としていたために、**失敗を 1 つも出さずに
                // `.idle` で終わっていた**（再レビュー A-1）。しかも
                // `.refinementNotApplied(nil)` は `SessionNoticeAnnouncement.init?` が
                // nil を返すので、**HUD にも CLI にも何ひとつ出なかった。**
                fail(.insertionFailed(retainedInHistory: false))
            } else {
                // 上限 0。**発話は欄にある**ので失敗ではないが、整形は反映できない。
                notify(.refinementNotApplied(nil))
                finishIdle()
            }
            return
        }

        // (b) 分岐と同じ扱い。**クリップボードへも残せていない**ので、
        // 案内する先は履歴画面（FR-9 の再挿入）だけである。
        // ここへ届いているのは `stored == .stored` の場合だけなので、履歴は確かに残っている。
        guard inserted.outcome != .failedEverywhere else {
            refinement?.cancel()
            fail(.insertionFailed(retainedInHistory: true))
            return
        }

        guard let anchor = inserted.anchor else {
            // **事前判定は「見込み」であって保証ではない**（`canCaptureAnchor()`）。
            // 錨が取れなかったので整形は反映できない。**生テキストは欄にある**——
            // (b) の分岐で整形が打ち切られたときとまったく同じ結末である。
            refinement?.cancel()
            notify(.refinementNotApplied(nil))
            finishIdle()
            return
        }

        beginPendingRevision(
            anchor: anchor, entryID: entry.id, refinement: refinement,
            settings: settings, releasedAt: releasedAt, refineStart: refineStart)
    }

    /// 保留中の差し替えを立てて、待機へ戻る。
    ///
    /// - Important: **`hotkey.setSessionBusy(true)` を保ったまま `.idle` にする。**
    ///   保留中の差し替えに対する ESC を受け取るために要る——`HotkeyDecision` は
    ///   録音中でも処理中でもない ESC を下流アプリのものとして扱うので、
    ///   ここで降ろすと**「差し替えを取りやめる」という安全な取消しが到達不能になる。**
    ///   抑止はしないので下流アプリの ESC は生きたままである。
    private func beginPendingRevision(
        anchor: ReplacementAnchor,
        entryID: HistoryEntry.ID,
        refinement: Task<String?, Never>?,
        settings: Settings,
        releasedAt: ContinuousClock.Instant,
        refineStart: ContinuousClock.Instant
    ) {
        let utterance = self.utterance
        finishIdle(keepingSessionBusy: true)

        // **`Task` を作ってから代入するまでに suspension point を挟まない。**
        // ここは同期の actor 隔離関数なので、作った `Task` が `applyRevision`
        // （actor 隔離）へ入れるのはこの関数を抜けた後である。
        let task = Task { [weak self] in
            let refined = await Self.awaitRefinement(
                refinement, within: settings.revisionDeadline)
            await self?.applyRevision(
                refined, anchor: anchor, entryID: entryID, utterance: utterance,
                releasedAt: releasedAt, refineStart: refineStart)
        }
        pendingRevision = PendingRevision(
            utterance: utterance, task: task, isCancelled: false)
    }

    /// 整形が返った（あるいは打ち切られた）。**ここが唯一、欄を後から書き換える場所である。**
    ///
    /// - Important: **`replacer.replace` は同期で、AX を 12 回呼ぶ**（実測 2026-08-15）。
    ///   **actor の上では走らせない**（`runOffActor`）。
    ///
    ///   フェーズ 2 の途中まで actor 上で同期に走らせており、その意図は
    ///   「世代の照合と実際の書き込みのあいだに挿入が割り込めないこと」だった。
    ///   **代償が重すぎた**——AX の往復の上限は 1 回 0.5 秒（`SystemAccessibility`）なので、
    ///   固まった相手では**最大 12×0.5 = 約 6 秒 actor が塞がる。**
    ///   その間 `run()` は `for await event in hotkey.events` から再開できず、
    ///   **PTT の押下も解放も、届いているのに処理されない**——
    ///   利用者は喋っているのに録音が始まらず、**発話が丸ごと落ちる**
    ///   （最終レビュー 視点3 の指摘 2）。しかも `beginPendingRevision` は
    ///   意図的に `.idle` へ戻して次の PTT を受け付ける設計なので、
    ///   これは例外ではなく**通常経路**である。
    ///
    ///   **割り込みは別の手段で塞いだ**——世代の錠（`InsertionEpoch.withExclusiveWrite`）で
    ///   挿入と差し替えを直列化する。**同じ組で作られる**ことが既に規律なので、
    ///   配線が増えない。
    ///
    ///   **実測（V-36 / 詳細設計書 §10.1 / 代役の欄・実ディスク書き込み）**:
    ///   AX 1 往復あたり 10 ms を注入した相手で、押下 → 録音開始は
    ///   **166.5 ms（低負荷）/ 168.7 ms（負荷下）→ 対処後 2 ms 台**。
    ///   注入 0 ms では前後とも 3 ms 未満で変わらない。
    ///   実アプリでの 1 往復のコストは未実測（V-28 / V-36）。
    ///
    /// - Important: **ここに actor を握ったままの同期作業を足さないこと。**
    ///   `RevisionBlockingRegressionTests` が壊れ検知の線で見張っている
    ///   （**線は壊れ検知であって要件値ではない**）。
    private func applyRevision(
        _ refined: String?,
        anchor: ReplacementAnchor,
        entryID: HistoryEntry.ID,
        utterance: Int,
        releasedAt: ContinuousClock.Instant,
        refineStart: ContinuousClock.Instant
    ) async {
        // **降ろすのは自分の持ち手だけ**（`PendingRevision` の注記）。
        // 番号を見ずに nil を置くと、**追い越した新しい保留の持ち手を消す。**
        // 取りやめも同じ理由で持ち主を照合してから読む。
        let isMine = (pendingRevision?.utterance == utterance)
        let wasCancelled = isMine && (pendingRevision?.isCancelled ?? false)
        if isMine { pendingRevision = nil }

        // **この発話がまだ「直近」か。** 次の発話が始まっていたら、状態も計測値も
        // そちらのものなので触らない（差し替えそのものは撃ってよい——欄を触るのは
        // 挿入だけで、`TextReplacer` が世代と要素を照合する）。
        let isCurrent = (utterance == self.utterance)
        let canShowState = isCurrent && phase == .idle
        defer {
            // **actor を手放している間に次の発話が始まっていることがある。**
            // そのときの状態はそちらのものなので、ここからは触らない。
            if canShowState, utterance == self.utterance, phase == .idle {
                hotkey.setSessionBusy(false)
                emit(.idle)
            }
        }

        // **整形の所要は、返らなかった場合も記録する。** ここを成功時だけにすると、
        // 「打ち切りに掛かった」のか「逸脱の検査に落ちた」のかが計測から消え、
        // **(b) の打ち切りを引き直すときに見るべき分布が取れない**（M3 は (b) では
        // 常に記録されるので、片方だけ欠けた分布を比べることになる）。
        let refineElapsed = ContinuousClock.now - refineStart
        if isCurrent { latestMetrics = latestMetrics?.rewriting(refine: refineElapsed, revision: nil) }

        guard !wasCancelled else {
            notify(.refinementNotApplied(nil))
            return
        }
        guard let refined, let replacer else {
            // 整形が返らなかった（打ち切り・利用不可・逸脱の検査に落ちた）。**生テキストのまま。**
            notify(.refinementNotApplied(nil))
            return
        }

        // **履歴を先に確保する**（詳細設計書 §8.3）。raw と refined の両方が履歴に
        // ある状態で初めて欄を触る。**書けなければ差し替えを始めない**——
        // 差し替えの途中で発話が判らなくなったとき（R-9）、履歴が 1 番目の受けである。
        // **戻り値も見る。** `update` は対象が見つからなければ何も書かず `false` を返す
        // （上限 0 で押し出された／履歴画面から消された／`setLimit` で切り詰められた）。
        // 例外が出ないので、捨てているとそのまま差し替えへ進んでいた（最終レビュー C-2）。
        do {
            guard try history.update(id: entryID, refinedText: refined) else {
                // 履歴に写しが無い。**欄は 1 文字も触らない。** 生テキストが残る。
                notify(.refinementNotApplied(nil))
                return
            }
        } catch {
            notify(.refinementNotApplied(nil))
            if canShowState { emit(.failed(.historyUnavailable(insertedElsewhere: true))) }
            return
        }

        if canShowState { emit(.revising) }
        // **actor を手放して走らせる**（上の注記）。世代の錠が挿入との重なりを塞ぐ。
        let result = await Self.runOffActor { replacer.replace(anchor, with: refined) }
        let revision = ContinuousClock.now - releasedAt
        if utterance == self.utterance {
            latestMetrics = latestMetrics?.rewriting(refine: refineElapsed, revision: revision)
        }

        switch result {
        case .replaced(let newAnchor):
            setUndoTarget(newAnchor)
            notify(.refinementApplied)
        case .declined(let reason):
            notify(.refinementNotApplied(reason))
        case .silentlyIgnored:
            // AX は成功を返したが何も入らなかった（R-4）。**害は無い。生テキストが欄にある。**
            notify(.refinementNotApplied(nil))
        case .lost:
            // **この設計で唯一、発話が欄から消えうる行**（R-9）。
            // 履歴・クリップボード・告知・以後の締め出しの 4 重で受けてある。
            notify(.textMayHaveBeenLost)
        }
    }

    /// **挿入のあいだ「クリップボードは挿入器のもの」と印を立てる**
    /// （`isInsertionInFlight` の注記）。
    ///
    /// - Important: **actor を塞がない。** 印を立てるだけで、待ちは `body` の中である。
    private func whileInserting<T>(_ body: () async -> T) async -> T {
        isInsertionInFlight = true
        defer { isInsertionInFlight = false }
        return await body()
    }

    /// **actor を手放して、同期の AX 往復を走らせる。**
    ///
    /// `TextReplacer.replace` / `undo` は同期で AX を最大 12 回叩く。1 往復の上限は
    /// 0.5 秒（`SystemAccessibility.messagingTimeout`）なので、固まった相手では
    /// **約 6 秒**掛かる。それを actor の上で走らせると、その間
    /// **PTT の押下も解放も処理されず、発話が丸ごと落ちる**（最終レビュー 視点3 の指摘 2）。
    ///
    /// - Important: **`Task.detached` である。** 呼び出し元がキャンセルされても
    ///   途中で畳まない——AX の書き込みは途中で止められる操作ではなく、
    ///   止まった先の欄がどうなっているか判らなくなる（`.lost` を自分で作ることになる）。
    /// - Important: **重なりは世代の錠が塞ぐ**（`InsertionEpoch.withExclusiveWrite`）。
    ///   actor を手放しても、同じ組の挿入と AX の書き込みが交錯することは無い。
    private static func runOffActor<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await Task.detached(priority: .userInitiated) { body() }.value
    }

    /// 保留中の差し替えを取りやめる（ESC / FR-7 の 1 行目）。
    ///
    /// **書き込みは 1 回も起きていないので、これは完全に安全な取消しである。**
    ///
    /// - Important: **効くのは最新の 1 件だけである。** 追い越された古い保留は
    ///   世代が失効しているので、取りやめようと撃とうと欄は 1 文字も変わらない
    ///   （`InsertionEpoch` / `TextReplacer.replace` の `.staleEpoch`）。
    private func cancelPendingRevision() {
        guard pendingRevision != nil else { return }
        pendingRevision?.isCancelled = true
    }

    // MARK: - Undo（FR-7）

    /// 差し替えが成功した。**ここから 10 秒だけ戻せる。**
    private func setUndoTarget(_ anchor: ReplacementAnchor) {
        undoAnchor = anchor
        let expiry = ContinuousClock.now + .seconds(HistoryStore.undoWindow)
        undoExpiry = expiry
        hotkey.setUndoAvailable(true)
        undoExpiryTask?.cancel()
        undoExpiryTask = Task { [weak self] in
            try? await Task.sleep(until: expiry, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.expireUndoTarget(at: expiry)
        }
    }

    /// 窓が閉じた。**打鍵を奪うのをやめる**（`setUndoAvailable` の注記）。
    private func expireUndoTarget(at expiry: ContinuousClock.Instant) {
        guard undoExpiry == expiry else { return }
        clearUndoTarget()
    }

    private func clearUndoTarget() {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        undoExpiry = nil
        guard undoAnchor != nil else { return }
        undoAnchor = nil
        hotkey.setUndoAvailable(false)
    }

    /// **Undo キーが押された**（FR-7）。
    ///
    /// 門はここにある錨であって履歴ではない。錨は `.ax` 経路の挿入と、その上で
    /// 成功した差し替えからしか作られないので、**`.clipboardOnly` の発話へ
    /// Undo を撃つ経路は型として存在しない。**
    ///
    /// **Undo を始める。待たない。**
    ///
    /// `run()` のイベントループから呼ばれるので、**ここで待つとループが止まる。**
    /// `undo` は `replace` と同じ原始操作なので、AX が詰まる相手では最大約 6 秒掛かる。
    /// その間ループが止まると、**PTT の押下も解放も処理されない**
    /// （最終レビュー 視点3 の指摘 2。`applyRevision` と同じ形が `performUndo` にもあった）。
    ///
    /// - Note: 続けて 2 回撃たれても二重には戻さない。`performUndo` は書き換えの前に
    ///   `clearUndoTarget()` するので、2 回目は錨を見つけられず縮退（クリップボードへの
    ///   取り出し）へ落ちる。**これは 10 秒窓を過ぎた場合とまったく同じ結末である。**
    private func beginUndo() {
        undoTask = Task { [weak self] in await self?.performUndo() }
    }

    /// - Important: **`replace` と同じ原始操作を逆向きに使うだけである。**
    ///   したがって secure input 中は同じ判定で拒否される（`TextReplacer.replace`）。
    /// - Important: **`replacer.undo` は actor を手放して走らせる**（`runOffActor`）。
    private func performUndo() async {
        // 差し替えがまだ保留中なら、**取りやめるだけ。何も書き換えない**（FR-7 の 1 行目）。
        if pendingRevision != nil, undoAnchor == nil {
            cancelPendingRevision()
            notify(.undone)
            return
        }

        guard let replacer, let anchor = undoAnchor, let expiry = undoExpiry,
            ContinuousClock.now <= expiry
        else {
            offerRawTextToClipboard()
            return
        }

        // **一度きり。** 戻した後にもう一度撃つと、戻した先をさらに書き換えることになる。
        clearUndoTarget()

        let canShowState = (phase == .idle)
        if canShowState { emit(.revising) }
        // **actor を手放して走らせる**（`runOffActor` の注記）。
        let result = await Self.runOffActor { replacer.undo(anchor) }
        // 手放している間に次の発話が始まっていることがある。そのときの状態はそちらのもの。
        if canShowState, phase == .idle { emit(.idle) }

        switch result {
        case .replaced:
            notify(.undone)
        case .declined(let reason):
            notify(.undoDeclined(reason))
        case .silentlyIgnored:
            notify(.undoDeclined(.textWriteFailed))
        case .lost:
            notify(.textMayHaveBeenLost)
        }
    }

    /// 自動で戻せない場合の縮退（要件定義書 FR-7 の細目 3 行目 / UC-3）。
    ///
    /// **差し替えできない経路で挿入した直近の発話に限り、生テキストをクリップボードへ置く。**
    /// クリップボードを奪ってよいのは、これが**利用者の明示操作**だからである。
    /// 該当が無ければ何もしない（「戻せません」を告げるだけ）。
    ///
    /// - Important: **secure input 中は行わない。**
    ///   ここは、挿入・差し替え・Undo 本体・再挿入のうちで**唯一 secure input の判定を
    ///   通らない「クリップボードへ置く」経路**だった。到達しないと考えられてはいた
    ///   ——この関数を呼ぶのは Undo キーの打鍵だけで、secure input が有効な間は
    ///   `CGEventTap` にキーイベントが配送されないためである——が、
    ///   **それは偶然の性質に依存した守り方であり、UI から Undo を撃てるようにした
    ///   瞬間に穴が開く**（最終レビュー 視点5 の P-4）。**推定に頼らず判定を置く。**
    /// - Important: **挿入がクリップボードを握っている最中は行わない**
    ///   （`isInsertionInFlight` の注記。最終レビュー 視点1 の B-2）。
    ///   置いた生テキストは `PasteboardInserter` の復元に上書きされるので、
    ///   **「取り出しました」が嘘になる。** 縮退は「戻せません」——
    ///   **発話は履歴にある**ので、告げないより告げ間違えない方を取る。
    private func offerRawTextToClipboard() {
        guard !isSecureInputEnabled() else {
            notify(.undoUnavailable)
            return
        }
        guard !isInsertionInFlight else {
            notify(.undoUnavailable)
            return
        }
        guard let clipboard, let latest = history.entries.first,
            latest.isManualUndoFallbackCandidate,
            (0...HistoryStore.undoWindow).contains(Date().timeIntervalSince(latest.timestamp))
        else {
            notify(.undoUnavailable)
            return
        }
        // **戻り値を見る。**「クリップボードへ取り出しました」は主張であって、
        // 置けていないのにそう告げると、利用者は ⌘V を押して何も貼れない
        // （`CompositeInserter` の最後の砦と同じ形。最終レビュー A-2）。
        // 置けなくても発話は履歴にある——だから「戻せません」で済ませてよい。
        guard clipboard.leave(latest.rawText) else {
            notify(.undoUnavailable)
            return
        }
        notify(.undoCopiedRawTextToClipboard)
    }

    /// 中断された発話の後始末。
    ///
    /// 基本設計書 §4: 中断でも録音済み内容は破棄せず履歴へ残す。挿入はしていないので
    /// `.notInserted` で記録する。**整形結果は残さない。** `refinedText` を入れると
    /// 履歴側の述語（`HistoryEntry.isAutomaticUndoCandidate`）の一方の条件を満たしてしまい、
    /// **一度も挿入していない文字列が「直近の整形済み発話」として履歴 UI に載る。**
    /// **経路（`.notInserted`）でも弾かれるので二重に守られているが、ここを緩めないこと。**
    ///
    /// - Important: **上限 0 でも「成功」にしてはならない。** `append` は何も保存せず
    ///   例外も投げないので、2 値で扱っていた頃は成功として待機へ落ちていた。
    ///   中断された発話にとって履歴は**唯一の写し**なので、残らなかったのなら
    ///   それは「発話そのものが失われた」である（最終レビュー A-1）。
    private func finishCancelled(raw: String, locale: String) {
        if !raw.isEmpty,
            record(raw: raw, refined: nil, locale: locale, method: .notInserted) != .stored
        {
            // **この発話はどこにも残っていない。** 挿入していないので手元にも無い。
            fail(.historyUnavailable(insertedElsewhere: false))
            return
        }
        finishIdle()
    }

    /// **終了要求で録音の途中を打ち切るときの、最後の写し。**
    ///
    /// ## なぜ要るのか（実機 2026-08-15 / 利用者の機体）
    ///
    /// 利用者が PTT キーを押したまま喋っている最中に `SIGTERM` が届いた。
    /// 猶予 10 秒を使い切って打ち切られ——**そこまでの発話は欄にもクリップボードにも
    /// 履歴にも、どこにも残らなかった。** 打ち切りそのものは設計どおりである
    /// （無限に待つと終了できないプロセスになる。それは直前に直した欠陥そのものである）。
    /// **穴は「打ち切ったあとに何もしていない」ことだった。**
    ///
    /// ## ESC との非対称を埋める
    ///
    /// **ESC による中断は `.notInserted` として履歴へ残す**（基本設計書 §4 /
    /// `InsertionMethod.notInserted`）。同じ「発話の途中でやめる」なのに、
    /// 終了の打ち切りだけ穴が空いていた。**ここで同じ扱いに揃える。**
    ///
    /// ## 確定を撃たない理由
    ///
    /// ここは**終了処理の中**であり、既に猶予を使い切っている。認識器へ確定
    /// （`finish()`）を撃って結果ストリームの終端を待つと、**打ち切ったはずの終了が
    /// さらに最大 `finalizeDeadline` 延びる。** 終了を延ばさないことがこの経路の要件なので、
    /// **その時点でメモリに在るものをそのまま残す**——確定済みの前半（`latestFinal`）＋
    /// 未確定の末尾（`latestVolatile`）である。
    ///
    /// **したがってこのテキストは確定していない。** `isProvisional: true` を立てて、
    /// 利用者が履歴で見たときに確定済みのものと区別できるようにする。
    ///
    /// - Important: **secure input 中は何も残さない**（基本設計書 §7 / FR-4 の唯一の例外）。
    ///   `completeUtterance` が整形の手前で同じ判定をしているのと同じ理由で、
    ///   ここを抜くとパスワードが `history.json` へ入る。
    private func salvageAbandonedRecording() {
        guard phase == .recording else { return }
        phase = .processing
        // 録音の後片付け。**タップを外さないとマイクを掴んだままプロセスが消える。**
        audio.stopTap()
        maxDurationTask?.cancel()
        maxDurationTask = nil

        guard !isSecureInputEnabled() else {
            shutdownSalvage = .refusedSecureInput
            fail(.refusedSecureInput)
            return
        }

        // **確定済みの前半と未確定の末尾を繋ぐ。** `completeUtterance` の
        // 「`latestFinal` が空なら `latestVolatile`」とは条件が違う——あちらは
        // 確定を撃った後なので末尾も `latestFinal` に入っている。ここは撃っていない。
        let raw = (latestFinal + latestVolatile).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            // 一言も認識されていなかった。**失うものが無いので告げない。**
            shutdownSalvage = .nothingHeld
            finishIdle()
            return
        }

        let stored = record(
            HistoryEntry(
                rawText: raw, refinedText: nil,
                localeIdentifier: settings.settings.localeIdentifier,
                insertionMethod: .notInserted, isProvisional: true))
        guard stored == .stored else {
            // **この発話はどこにも残っていない。** 挿入していないので手元にも無い。
            shutdownSalvage = .lost
            fail(.historyUnavailable(insertedElsewhere: false))
            return
        }
        shutdownSalvage = .retainedInHistory(provisional: true)
        finishIdle()
    }

    /// 履歴への書き込みの顛末。**「例外が出なかった」と「実際に残った」は別である。**
    ///
    /// 上限 0（設定画面のステッパーで到達できる。`HistoryStore.normalized` が
    /// 「明示的な指示として尊重する」と定めたサポート構成）では、`append` は
    /// **何も保存せず、例外も投げない。** ここを 2 値で扱っていたために、
    /// **ESC で中断した発話が欄にもクリップボードにも履歴にも残らないまま、
    /// 失敗を 1 つも出さずに待機へ落ちていた**（最終レビュー A-1）。
    private enum HistoryRecord: Equatable {
        /// 履歴に残った。
        case stored
        /// 例外は出ていないが、上限 0 なので**残っていない。**
        case notRetained
        /// 書けなかった（容量・権限・破損）。
        case failed
    }

    /// - Returns: 顛末。**握り潰してはならない。**
    ///
    /// `try?` で捨てていた頃は、書き込みが失敗しても `.failed` も出ず標準エラーにも
    /// 出ず、メモリにも残らなかった。**中断された発話ではそれが唯一の写しなので、
    /// 発話が無言のまま消える**（フェーズ 1 の最終レビュー C-1）。しかも破損ファイルの
    /// 退避に失敗する経路では、以後の `append` が投げ続ける（`AtomicJSONFile`）ので、
    /// 一度きりではなく恒久的に消え続ける。
    ///
    /// **在庫は持たない。** 溜めても書ける保証は無いうえ、書けない理由（容量・権限・
    /// 破損）は時間で解決しない。**失敗したことを利用者へ告げる**方が確実に効く。
    private func record(
        raw: String, refined: String?, locale: String, method: InsertionMethod
    ) -> HistoryRecord {
        record(
            HistoryEntry(
                rawText: raw, refinedText: refined,
                localeIdentifier: locale, insertionMethod: method
            ))
    }

    /// - Returns: 顛末。**握り潰してはならない**（上の注記）。
    private func record(_ entry: HistoryEntry) -> HistoryRecord {
        do {
            return try history.append(entry) ? .stored : .notRetained
        } catch {
            return .failed
        }
    }

    // MARK: - マイクをアイドルで寝かせる（設計書 2026-08-15）

    /// 待機へ戻ったので、猶予を過ぎたらマイクを止める予約を入れる。
    ///
    /// **掛け金を `finishIdle()` に置いているのは、そこが待機へ戻る唯一の合流点だから**
    /// である（正常終了・失敗・中断のすべてが通る）。押下側に対応する掛け金を
    /// 置かなくて済む。
    private func scheduleAudioSleep() {
        audioSleepTask?.cancel()
        audioSleepTask = Task { [weak self, audioIdleSleepDelay] in
            try? await Task.sleep(for: audioIdleSleepDelay)
            guard !Task.isCancelled else { return }
            await self?.sleepAudioIfIdle()
        }
    }

    /// 猶予が過ぎた。**まだ待機のままなら**止める。
    ///
    /// 取り消し（`cancelAudioSleep`）と二重の帯にしてある。取り消しが効かなかった場合でも、
    /// **録音中にマイクを止めて発話を丸ごと失う**ことだけは起こらないようにする。
    private func sleepAudioIfIdle() {
        audioSleepTask = nil
        guard phase == .idle else { return }
        audio.sleep()
    }

    private func cancelAudioSleep() {
        audioSleepTask?.cancel()
        audioSleepTask = nil
    }

    // MARK: - 待ち合わせ

    /// 供給タスクの完走を待つ。**ただし締め切りを過ぎたら待つのをやめる。**
    ///
    /// 音声ストリームが何かの理由で終端しないと、ここが録音の終わらない場所になる。
    /// 末尾を数十 ms 失うことと、キーを離しても永久に戻らないことでは、後者が重い。
    /// **打ち切っても供給タスクは殺さない**（残りは認識器へ届いてよい）。
    private func drainFeed(before deadline: ContinuousClock.Instant) async {
        guard let feedTask else { return }
        self.feedTask = nil

        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let waiter = Task {
            await feedTask.value
            continuation.yield(())
            continuation.finish()
        }
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            continuation.yield(())
            continuation.finish()
        }
        defer {
            waiter.cancel()
            timer.cancel()
        }
        var results = stream.makeAsyncIterator()
        _ = await results.next()
    }

    private func scheduleFinalDeadline(at deadline: ContinuousClock.Instant) {
        finalDeadlineTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.settleFinal()
        }
    }

    /// 確定待ちを解く。**何度呼んでも 1 回しか効かない。**
    private func settleFinal() {
        guard !isFinalSettled else { return }
        isFinalSettled = true
        let waiters = finalWaiters
        finalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func awaitFinalSettled() async {
        guard !isFinalSettled else { return }
        await withCheckedContinuation { continuation in
            finalWaiters.append(continuation)
        }
    }

    /// 前の発話の `finish()`（または起動時の捨て往復）が終わるのを待つ。
    ///
    /// - Important: **実際の呼び出し位置は次の押下の直後**（`startRecording()` の頭）であり、
    ///   そこは M1a（キー押下 → タップ武装、NFR-P1 の 50 ms）の計測区間の中である。
    ///   通常は前の発話の挿入が終わるまでに `finish()` も終わっているので 0 ms だが、
    ///   **Task 7 が実測した M1a にはこの待ちが入っていない。**
    ///   ここを動かすときは M1a を測り直すこと。
    ///
    ///   **起動直後の最初の押下だけは、ここで捨て往復（`warmUpTranscriber()`）を待つ。**
    ///   往復が終わっていれば 0 ms。終わっていなければ残りを待つが、その待ちは
    ///   「捨て往復を入れなければ直後の `begin()` が払っていた初回費用」と同じものである。
    private func drainFinalizeTask() async {
        guard let finalizeTask else { return }
        self.finalizeTask = nil
        await finalizeTask.value
    }

    // MARK: - 終了処理

    private func fail(_ reason: SessionFailure) {
        emit(.failed(reason))
        finishIdle()
    }

    /// 発話 1 回ぶんの後始末をして待機へ戻す。
    ///
    /// - Parameter keepingSessionBusy: 保留中の差し替えがあるので、ESC を届かせ続けるか
    ///   （`beginPendingRevision` の注記）。**降ろすのは差し替えが片付いてからである。**
    private func finishIdle(keepingSessionBusy: Bool = false) {
        // 処理は終わった。以後の ESC は下流アプリのものである。
        if !keepingSessionBusy { hotkey.setSessionBusy(false) }
        maxDurationTask?.cancel()
        maxDurationTask = nil
        finalDeadlineTask?.cancel()
        finalDeadlineTask = nil
        collectTask = nil
        isCancelRequested = false
        phase = .idle
        emit(.idle)

        // 待機へ戻った。猶予を過ぎたらマイクを止める（設計書 2026-08-15）。
        // **`keepingSessionBusy` でも予約してよい**——保留中の差し替えはマイクを使わない。
        scheduleAudioSleep()
    }

    private func emit(_ state: SessionState) {
        self.state = state
        stateContinuation.yield(state)
        stateBroadcast.yield(state)
    }

    private func notify(_ notice: SessionNotice) {
        noticeBroadcast.yield(notice)
    }
}

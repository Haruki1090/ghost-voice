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
    /// 失敗。**この直後に必ず `.idle` が続く。** どれだけ表示するかは UI 側が決める。
    case failed(SessionFailure)
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
/// ## 消費者はそれぞれ 1 つに限る
///
/// `stateUpdates` は `AsyncStream` なので、複数の `next()` を同時に待つと異常終了する。
/// また `run()` はプロセスにつき 1 回だけ呼ぶこと（ホットキーのイベント列も単一消費者）。
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

    /// キー解放から「確定テキストが手に入る」までの締め切り。
    ///
    /// 実測は 40〜177 ms（V-2）なので通常はまったく効かない。**認識器が黙り込んだ
    /// ときに録音が終わらなくなるのを防ぐためだけにある。** 締め切りに達した場合は
    /// 暫定テキストへ縮退する（空で捨てるよりは残す）。
    public static let defaultFinalizeDeadline: Duration = .seconds(2)

    private let settings: SettingsStore
    private let hotkey: any HotkeyMonitor
    private let audio: any AudioCapturing
    private let transcriber: any Transcribing
    private let refiner: any Refining
    private let inserter: any TextInserting
    private let history: HistoryStore
    private let vocabulary: VocabularyStore
    private let isSecureInputEnabled: @Sendable () -> Bool
    private let postEventAuthorization: PostEventAuthorization
    private let maxRecordingDuration: Duration
    private let finalizeDeadline: Duration

    private let stateContinuation: AsyncStream<SessionState>.Continuation
    public nonisolated let stateUpdates: AsyncStream<SessionState>

    public private(set) var state: SessionState = .idle
    public private(set) var latestMetrics: Metrics.Sample?

    /// 発話を抱えているか（録音中または確定〜挿入の処理中）。
    ///
    /// **終了処理は `state` ではなくこちらを見ること。**
    /// `state` は `emit` でしか変わらないので、**`phase` が立ってから最初の `emit` までに
    /// 窓がある**——`startRecording()` は `phase = .recording` を立ててから
    /// `transcriber.begin()` と `audio.startTap` を待ち、その後で
    /// `emit(.recording(volatileText: ""))` する。窓の長さは `begin()` の費用そのもので、
    /// **定常時 1.2〜1.4 ms、起動後の最初の 1 発話だけは 44〜540 ms**（詳細設計書 §10）。
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

    /// キー解放以降に確定を待っているか。**録音中の `.final` で先へ進んではならない**
    /// （長い発話では途中で確定が出る。V-2 のテストが実測で確認している）。
    ///
    /// V-12 の実測（103 秒の読み上げを実時間で供給）では、確定は**録音中に 1 件・
    /// 解放後に 1 件**届いた。前者を `latestFinal` へ積まずに捨てる変異を当てると、
    /// **548 字のうち前半が丸ごと落ちて後半だけが挿入される**
    /// （`FinalAfterReleaseTests` がこの変異を殺す。ただし既定の 30 秒では確定が
    /// 1 件しか出ないので、`GHOST_VOICE_V12_SECONDS=103` で回したときだけ殺せる）。
    private var isAwaitingFinal = false
    private var isFinalSettled = false
    private var finalWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        settings: SettingsStore,
        hotkey: any HotkeyMonitor,
        audio: any AudioCapturing,
        transcriber: any Transcribing,
        refiner: any Refining,
        inserter: any TextInserting,
        history: HistoryStore,
        vocabulary: VocabularyStore,
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() },
        postEventAuthorization: PostEventAuthorization = .shared,
        maxRecordingDuration: Duration = DictationSession.defaultMaxRecordingDuration,
        finalizeDeadline: Duration = DictationSession.defaultFinalizeDeadline
    ) {
        self.settings = settings
        self.hotkey = hotkey
        self.audio = audio
        self.transcriber = transcriber
        self.refiner = refiner
        self.inserter = inserter
        self.history = history
        self.vocabulary = vocabulary
        self.isSecureInputEnabled = isSecureInputEnabled
        self.postEventAuthorization = postEventAuthorization
        self.maxRecordingDuration = maxRecordingDuration
        self.finalizeDeadline = finalizeDeadline
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

    // MARK: - 起動

    /// 起動時のウォームアップ。実測でコールド 1.9〜3.3 秒 / ウォーム 0.4 秒の差がある。
    ///
    /// **整形器の捨て推論は投げっぱなしにする。** `prewarm()` はコールド時に数秒掛かる
    /// ので、これを待ってからホットキーを読み始めると**起動直後の数秒間、押しても
    /// 何も起きない**（基本設計書 §6）。
    public func warmUp() async {
        // 【Task 8 申し送り】初回コスト（実測 16.7 ms / 23.8 ms）を最初の挿入から外す。
        refreshPermissions()

        do {
            try audio.prepare()
        } catch {
            emit(.failed(.audioUnavailable))
            emit(.idle)
        }

        // **発話ごとに呼び直さない。** `prepare` は `reserve` の後に失敗すると
        // ロケール枠（上限 5）を解放しない（Task 5 申し送り）。再試行を毎発話で
        // 重ねると `localeReservationLimitReached` に達して回復不能になる。
        // ロケールを変えるときは `prepareTranscriber(locale:kind:)` を明示的に呼ぶ。
        let current = settings.settings
        do {
            try await transcriber.prepare(locale: current.locale, kind: current.transcriberKind)
        } catch {
            emit(.failed(.transcriptionUnavailable))
            emit(.idle)
        }

        let refiner = self.refiner
        Task.detached(priority: .utility) { await refiner.prewarm() }
    }

    /// ロケールや認識種別を変えたときに呼ぶ。
    ///
    /// **自動で再試行しないための入口である。** 失敗はそのまま投げるので、
    /// 呼び出し側（設定画面）がユーザーへ見せ、再試行の回数を人の操作の回数に縛る。
    ///
    /// - Important: **録音中に呼んではならない。** 進行中の発話の解析器を作り直す
    ///   ことになる。設定画面から呼ぶ想定なので、`state == .idle` を確かめること。
    public func prepareTranscriber(locale: Locale, kind: TranscriberKind) async throws {
        try await transcriber.prepare(locale: locale, kind: kind)
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
            }
        }
        await completionTask?.value
        completionTask = nil
        stateContinuation.finish()
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
        case .idle: break
        }
    }

    // MARK: - 録音

    private func startRecording() async {
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
        isAwaitingFinal = false
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
            latestFinal += text
            // キー解放より前の確定は当該発話の途中経過。**ここで先へ進めてはならない。**
            if isAwaitingFinal { settleFinal() }
        }
    }

    /// 結果ストリームが終わった。これ以上テキストは来ない。
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

        // 3. 確定を撃つ。**復帰は待たない。** `.final` は `finish()` の復帰より
        //    5〜48 ms 早く届く（V-2 実測）。復帰を待つと毎発話でそのぶんを捨てる。
        isAwaitingFinal = true
        let transcriber = self.transcriber
        finalizeTask = Task { try? await transcriber.finish() }

        // 4. `.final` の到着・結果ストリームの終端・締め切りのいずれかを待つ。
        scheduleFinalDeadline(at: textDeadline)
        await awaitFinalSettled()

        let finalize = ContinuousClock.now - releasedAt
        // 確定が来なかった場合だけ暫定テキストへ縮退する。空で捨てるよりは残す。
        //
        // **ここが V-12 の残存リスクの場所である**（詳細設計書 §13 / §10 の M2）。
        // 上の待ちは「解放以降の**最初の**確定」で解け、`latestFinal` はここで
        // `await` を挟まず同期的に読む。**その後に届いた確定は積まれても二度と読まれない。**
        // 103 秒の発話でも解放後の確定は 1 件だった（V-12 実測）が、**否定はされていない。**
        // 録音中に届く確定は落ちない（`apply` が積むだけで先へ進まない）。
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

        // --- 整形（失敗・超過時は生テキストへ縮退）
        emit(.refining)
        let refineStart = ContinuousClock.now
        let refined: String? = current.refinementEnabled
            ? await refiner.refine(
                raw, locale: current.locale, terms: vocabulary.terms,
                timeout: current.refinementTimeout)
            : nil
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
        let outcome = await inserter.insert(refined ?? raw)
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

        latestMetrics = Metrics.Sample(
            finalize: finalize, refine: refine, insert: insert,
            droppedBuffers: audio.droppedBufferCount - droppedAtStart
        )

        // --- 履歴はクリティカルパスの外で書く（同期 I/O。詳細設計書 §8.2）
        //
        // **`.refusedSecureInput` は履歴に記録してはならない**（Task 8 の裁定）。
        // `recordableMethod` が nil を返すのがその一手間で、ここを素通りさせると
        // パスワードが `history.json` へ平文で入る。
        if let method = outcome.recordableMethod,
            !record(raw: raw, refined: refined, locale: current.localeIdentifier, method: method)
        {
            // **テキストは利用者の手元にある。** 失ったのは履歴と Undo だけなので、
            // 中断経路とは別の文言で伝える（`SessionFailure` の注記）。
            fail(.historyUnavailable(insertedElsewhere: true))
            return
        }

        finishIdle()
    }

    /// 中断された発話の後始末。
    ///
    /// 基本設計書 §4: 中断でも録音済み内容は破棄せず履歴へ残す。挿入はしていないので
    /// `.notInserted` で記録する。**整形結果は残さない。** `refinedText` を入れると
    /// `undoCandidate` の条件（`refinedText != nil`）を満たしてしまい、
    /// **一度も挿入していない文字列を「戻せる」ことになる。**
    private func finishCancelled(raw: String, locale: String) {
        if !raw.isEmpty,
            !record(raw: raw, refined: nil, locale: locale, method: .notInserted)
        {
            // **この発話はどこにも残っていない。** 挿入していないので手元にも無い。
            fail(.historyUnavailable(insertedElsewhere: false))
            return
        }
        finishIdle()
    }

    /// - Returns: 書けたか。**握り潰してはならない。**
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
    ) -> Bool {
        do {
            try history.append(
                HistoryEntry(
                    rawText: raw, refinedText: refined,
                    localeIdentifier: locale, insertionMethod: method
                )
            )
            return true
        } catch {
            return false
        }
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

    /// 前の発話の `finish()` が終わるのを待つ。
    ///
    /// - Important: **実際の呼び出し位置は次の押下の直後**（`startRecording()` の頭）であり、
    ///   そこは M1a（キー押下 → タップ武装、NFR-P1 の 50 ms）の計測区間の中である。
    ///   通常は前の発話の挿入が終わるまでに `finish()` も終わっているので 0 ms だが、
    ///   **Task 7 が実測した M1a にはこの待ちが入っていない。**
    ///   ここを動かすときは M1a を測り直すこと。
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
    private func finishIdle() {
        // 処理は終わった。以後の ESC は下流アプリのものである。
        hotkey.setSessionBusy(false)
        maxDurationTask?.cancel()
        maxDurationTask = nil
        finalDeadlineTask?.cancel()
        finalDeadlineTask = nil
        collectTask = nil
        isAwaitingFinal = false
        isCancelRequested = false
        phase = .idle
        emit(.idle)
    }

    private func emit(_ state: SessionState) {
        self.state = state
        stateContinuation.yield(state)
    }
}

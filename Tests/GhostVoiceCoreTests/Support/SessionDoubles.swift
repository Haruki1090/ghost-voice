import AVFAudio
import Foundation
import Synchronization

@testable import GhostVoiceCore

/// 代役をまたいだ呼び出しの順序を記録する。
///
/// **順序は機体の速さで決まってはならない。** 「先に呼ばれたはず」を時刻の比較で
/// 検査すると、負荷が乗った回に入れ替わって断続的に落ちる。ここは実際の呼び出し順を
/// そのまま並べる。
final class CallOrder: Sendable {
    private let entries = Mutex<[String]>([])
    var calls: [String] { entries.withLock { $0 } }
    func record(_ name: String) { entries.withLock { $0.append(name) } }
}

/// 認識器のテスト代役。
///
/// **`.final` の配信・結果ストリームの終端・`finish()` の復帰を、それぞれ別の時刻に
/// 置けるようにしてある。** 後段が待つのは**終端**であり（V-12 の修正）、
/// 復帰ではないことを検査するには 3 つを引き離せる代役が要る。
/// `finishDelay` と `endsStreamBeforeReturning` がその隙間を作る。
final class StubTranscriber: Transcribing, @unchecked Sendable {

    struct Script: Sendable {
        var finalText = "えー、生テキストです"
        var volatileText = "えー"
        /// `.final` を流してから `finish()` が返るまでの遅延。
        var finishDelay: Duration = .zero
        /// `.final` を一切流さない（確定が来ないまま終わる経路の検査用）。
        var emitsFinal = true
        /// `.final` を流したあとストリームを終端しない（締め切りの検査用）。
        var finishesStream = true
        /// `feed` 1 回あたりの所要。
        ///
        /// **末尾の供給を待たずに確定させる実装を確実に落とすために要る。** 0 だと
        /// 供給が速すぎて、待っていない実装でも末尾がたまたま間に合ってしまい、
        /// 検査が機体の速さ次第になる（実際にミューテーションが生き残った）。
        var feedDelay: Duration = .zero
        var beginError: (any Error)?
        /// `begin()` が返るまでの遅延。
        ///
        /// **`phase = .recording` は立っているのに、まだ `emit` していない窓**を
        /// テストから作るために要る（`startRecording` は `begin()` を待ってから
        /// `emit(.recording(...))` する）。実機では `begin()` の費用がこの窓である
        /// （起動時の捨て往復を入れた後は 中央値 1.0〜3.0 ms。詳細設計書 §10）。
        var beginDelay: Duration = .zero
        /// **キー解放後に届く 2 件目の確定**（V-12）。nil なら 1 件だけ。
        ///
        /// 実機の肉声ではこれが起きて末尾 約 38 字が失われた（要件定義書 §2.8.4）。
        /// 合成音声 103 秒では起きなかったので、**実音声に頼る検査では駆動できない。**
        var secondFinalText: String?
        /// 1 件目の確定から `secondFinalText` を流すまでの間隔。
        ///
        /// **0 にしてはならない。** 0 だと 2 件目が「1 件目で解けた待ちが後段へ
        /// 戻る前」に積まれてしまい、**欠陥のある実装でもたまたま拾えてしまう。**
        /// 後段が確実に `latestFinal` を読み終える程度に離す。
        var secondFinalDelay: Duration = .zero
        /// 結果ストリームを `finish()` が返るより**前**に終端するか。
        ///
        /// 実機の順序はこちらである（`finish()` は入力を閉じてから
        /// `finalizeAndFinishThroughEndOfInput()` を待つ。§4.3.1）。
        /// **後段が「`finish()` の復帰」ではなく「ストリームの終端」で進むこと**を
        /// 検査するには、この 2 つを別々の時刻に置ける代役が要る。
        var endsStreamBeforeReturning = false
    }

    private let script: Script
    private let state = Mutex<State>(State())
    /// 他の代役と共有する順序記録。`begin()` と `startTap` の前後を見るために持つ。
    var order: CallOrder?

    private struct State {
        var continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?
        /// `begin()` のたびに作られたストリームを**すべて**取っておく。
        /// 前の発話のストリームがまだ生きている状況を、テストから作れるようにする。
        var allContinuations: [AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation] = []
        /// `feed` で受け取ったフレーム数の合計。末尾が届いたかの検査に使う。
        var fedFrames = 0
        var beginCount = 0
        /// `begin()` に**入った**回数（`beginCount` は返った回数）。
        var beginEntered = 0
        var finishCount = 0
        /// `finish()` に入った時点で `feed` 済みだったフレーム数。
        /// **供給を待たずに確定させていないか**を見るための刻み。
        var fedFramesAtFinish = 0
    }

    init(_ script: Script = Script()) { self.script = script }

    convenience init(finalText: String) {
        self.init(Script(finalText: finalText))
    }

    var fedFrames: Int { state.withLock(\.fedFrames) }
    var fedFramesAtFinish: Int { state.withLock(\.fedFramesAtFinish) }
    var beginCount: Int { state.withLock(\.beginCount) }
    var beginEntered: Int { state.withLock(\.beginEntered) }
    var finishCount: Int { state.withLock(\.finishCount) }

    func prepare(locale: Locale, kind: TranscriberKind) async throws {}

    var requiredAudioFormat: AVAudioFormat? { get async { nil } }

    /// 録音の途中で確定を流す。**長い発話では実際に起こる**（V-2 のテストが
    /// 「キー解放より前に届いた確定結果は当該発話の確定ではない」と注記している）。
    func emitFinal(_ text: String) {
        state.withLock(\.continuation)?.yield(.final(text))
    }

    func emitVolatile(_ text: String) {
        state.withLock(\.continuation)?.yield(.volatile(text))
    }

    /// `begin()` の `index` 回目に作ったストリームへ確定を流す。
    /// **前の発話ぶんの結果が遅れて届く状況**をテストから作るために要る。
    func emitFinal(_ text: String, onStream index: Int) {
        state.withLock { $0.allContinuations[index] }.yield(.final(text))
    }

    /// `begin()` の `index` 回目に作ったストリームを終端する。
    func finishStream(_ index: Int) {
        state.withLock { $0.allContinuations[index] }.finish()
    }

    func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        order?.record("transcriber.begin")
        state.withLock { $0.beginEntered += 1 }
        if script.beginDelay > .zero { try? await Task.sleep(for: script.beginDelay) }
        if let beginError = script.beginError {
            state.withLock { $0.beginCount += 1 }
            throw beginError
        }
        return AsyncThrowingStream { continuation in
            state.withLock {
                $0.continuation = continuation
                $0.allContinuations.append(continuation)
                $0.beginCount += 1
            }
            continuation.yield(.volatile(script.volatileText))
        }
    }

    func feed(_ buffer: sending AVAudioPCMBuffer) async {
        let frames = Int(buffer.frameLength)
        if script.feedDelay > .zero { try? await Task.sleep(for: script.feedDelay) }
        state.withLock { $0.fedFrames += frames }
    }

    func finish() async throws {
        order?.record("transcriber.finish")
        let continuation = state.withLock { state -> AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation? in
            state.finishCount += 1
            state.fedFramesAtFinish = state.fedFrames
            return state.continuation
        }
        if script.emitsFinal { continuation?.yield(.final(script.finalText)) }
        // **2 件目の確定。** 実機ではこれが 1 件目より後に届いて末尾が失われた（V-12）。
        if let second = script.secondFinalText {
            if script.secondFinalDelay > .zero {
                try? await Task.sleep(for: script.secondFinalDelay)
            }
            continuation?.yield(.final(second))
        }
        if script.finishesStream, script.endsStreamBeforeReturning { closeStream(continuation) }
        if script.finishDelay > .zero { try? await Task.sleep(for: script.finishDelay) }
        if script.finishesStream, !script.endsStreamBeforeReturning { closeStream(continuation) }
    }

    private func closeStream(
        _ continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?
    ) {
        continuation?.finish()
        state.withLock { $0.continuation = nil }
    }
}

/// 音声取得のテスト代役。**実マイクを開かない。**
///
/// `EngineAudioCapture` をテストへ持ち込んではならない。V-9 でマイク権限が
/// 付与された機体では、`swift test` を回すたびに実マイクが開くことになる
/// （Task 7 が `GHOST_VOICE_MIC_TESTS=1` の opt-in で塞いだ境界）。
final class StubAudioCapture: AudioCapturing, @unchecked Sendable {

    private let state = Mutex<State>(State())
    private let levelStream: AsyncStream<Float>
    var order: CallOrder?

    private struct State {
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        var prepareCount = 0
        var startCount = 0
        var stopCount = 0
        var dropped = 0
        /// `stopTap()` のたびに末尾として配るフレーム数。
        /// 実装（`removeTap` → コンバータ `drain` → `finish`）が末尾を配ることの写し。
        var tailFrames = 0
    }

    /// `prepare()` が投げるエラー。既定は成功。
    var prepareError: (any Error)?
    /// `startTap` が投げるエラー。既定は成功。
    var startError: (any Error)?

    init(tailFrames: Int = 0) {
        levelStream = AsyncStream<Float>.makeStream().stream
        state.withLock { $0.tailFrames = tailFrames }
    }

    var prepareCount: Int { state.withLock(\.prepareCount) }
    var startCount: Int { state.withLock(\.startCount) }
    var stopCount: Int { state.withLock(\.stopCount) }

    var level: AsyncStream<Float> { levelStream }

    var droppedBufferCount: Int { state.withLock(\.dropped) }

    /// 変換に失敗して捨てた体にする。`Metrics` が発話ごとの差分を取っているかの検査用。
    func dropBuffers(_ count: Int) {
        state.withLock { $0.dropped += count }
    }

    func prepare() throws {
        state.withLock { $0.prepareCount += 1 }
        if let prepareError { throw prepareError }
    }

    func startTap(format: AVAudioFormat?) throws -> AsyncStream<AVAudioPCMBuffer> {
        order?.record("audio.startTap")
        state.withLock { $0.startCount += 1 }
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        state.withLock { $0.continuation = continuation }
        return stream
    }

    func stopTap() {
        let tail = state.withLock { state -> (AsyncStream<AVAudioPCMBuffer>.Continuation?, Int) in
            state.stopCount += 1
            let continuation = state.continuation
            state.continuation = nil
            return (continuation, state.tailFrames)
        }
        // 末尾を配ってから終端する。順序を逆にすると末尾が捨てられる（Task 7 §3.4）。
        if tail.1 > 0, let buffer = Self.makeBuffer(frames: tail.1) {
            tail.0?.yield(buffer)
        }
        tail.0?.finish()
    }

    /// 録音中の 1 バッファぶんを配る。
    func emit(frames: Int) {
        guard let buffer = Self.makeBuffer(frames: frames) else { return }
        state.withLock(\.continuation)?.yield(buffer)
    }

    private static func makeBuffer(frames: Int) -> sending AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        nonisolated(unsafe) let detached = buffer
        return detached
    }
}

/// 挿入されたテキストと、返す結果を記録する代役。
final class RecordingInserter: TextInserting, @unchecked Sendable {

    private let texts = Mutex<[String]>([])
    private let outcome: InsertionOutcome
    private let delay: Duration

    init(outcome: InsertionOutcome = .inserted(.ax), delay: Duration = .zero) {
        self.outcome = outcome
        self.delay = delay
    }

    var inserted: [String] { texts.withLock { $0 } }

    func insert(_ text: String) async -> InsertionOutcome {
        if delay > .zero { try? await Task.sleep(for: delay) }
        texts.withLock { $0.append(text) }
        return outcome
    }
}

/// 呼ばれ方を記録する整形器。**渡された生テキストを残す**ので、
/// 「整形へ渡してはならない」経路の検査に使える。
final class SpyRefiner: Refining, @unchecked Sendable {

    private let calls = Mutex<[String]>([])
    /// **渡された打ち切りの値。**
    ///
    /// 記録していなかった頃、`startRefinement` の
    /// `refinementApplyMode == .afterInsert ? revisionDeadline : refinementTimeout` の
    /// **三項を逆にする変異が全件緑のまま生き残った**（視点4 の変異 A2）。
    /// 逆にすると (a) の分岐が 3000 ms ではなく 750 ms で打ち切られ、
    /// **約 40 字を超える発話では整形がほぼ必ず落ちる**——
    /// フェーズ 2 が (a) を作って解こうとした問題そのものが戻る。
    /// **代役が記録していない引数は、何を渡しても検査が通る。**
    private let timeoutCalls = Mutex<[Duration]>([])
    private let result: String?
    private let delay: Duration

    init(result: String?, delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    var refinedInputs: [String] { calls.withLock { $0 } }
    /// 渡された打ち切り（上の注記）。
    var refineTimeouts: [Duration] { timeoutCalls.withLock { $0 } }
    var prewarmCount: Int { prewarms.load(ordering: .relaxed) }
    private let prewarms = Atomic<Int>(0)

    /// 捨て推論の所要。実測ではコールド 1.9〜3.3 秒掛かる。
    /// **起動がこれを待たない**ことを検査するために遅らせられるようにしてある。
    var prewarmDelay: Duration = .zero

    var isAvailable: Bool { result != nil }

    func prewarm() async {
        if prewarmDelay > .zero { try? await Task.sleep(for: prewarmDelay) }
        prewarms.add(1, ordering: .relaxed)
    }

    func refine(
        _ raw: String, locale: Locale, terms: [VocabularyTerm], timeout: Duration
    ) async -> String? {
        calls.withLock { $0.append(raw) }
        timeoutCalls.withLock { $0.append(timeout) }
        guard let result else { return nil }
        return await withTimeout(timeout) { [delay] in
            try? await Task.sleep(for: delay)
            return Task.isCancelled ? nil : result
        }
    }
}

/// `stateUpdates` を順番どおりに集める。
actor StateLog {
    private(set) var states: [SessionState] = []

    func collect(from stream: AsyncStream<SessionState>) -> Task<Void, Never> {
        Task { [weak self] in
            for await state in stream { await self?.append(state) }
        }
    }

    private func append(_ state: SessionState) { states.append(state) }
}

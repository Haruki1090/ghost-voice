import AVFAudio
import Foundation
import Synchronization
import Testing

@testable import GhostVoiceCore

/// 非同期の列から先頭 `count` 件を集める。
///
/// `Array(sequence.prefix(n))` は同期の `Sequence` 用で、`AsyncSequence` には無い。
func collect<S: AsyncSequence & Sendable>(_ sequence: S, count: Int) async -> [S.Element]
where S.Element: Sendable {
    var result: [S.Element] = []
    guard count > 0 else { return result }
    var iterator = sequence.makeAsyncIterator()
    while let next = try? await iterator.next() {
        result.append(next)
        if result.count == count { break }
    }
    return result
}

/// **UI が Core に要求していたのに無かったもの**（調査 `core-api-and-hud.md` の A-3）を
/// 埋めた口の検査。**とくに「単一消費者か」「MainActor から呼んでよいか」を固定する**——
/// A-4 の罠はそのまま UI の事故になる。
@Suite("Core の UI 接続面")
struct SessionSurfaceTests {

    // MARK: - 分配器（欠落 1 / 3）

    /// **`AsyncStream` は複数の `next()` を同時に待つと異常終了する。**
    /// 分配器が独立したストリームを配るので、購読者は何人でもよい。
    @Test("分配器は購読者ごとに独立したストリームを配る")
    func broadcastFansOutToEveryone() async throws {
        let broadcast = SessionBroadcast<Int>()
        let first = broadcast.stream()
        let second = broadcast.stream()

        let a = Task { await collect(first, count: 2) }
        let b = Task { await collect(second, count: 2) }
        try await waitUntil("2 人とも購読を始める") { broadcast.subscriberCount == 2 }

        broadcast.yield(1)
        broadcast.yield(2)

        #expect(await a.value == [1, 2])
        #expect(await b.value == [1, 2])
    }

    @Test("購読を抜けると購読者から外れる")
    func broadcastForgetsFinishedSubscribers() async throws {
        let broadcast = SessionBroadcast<Int>()
        let consumer = Task { [stream = broadcast.stream()] in await collect(stream, count: 1) }
        try await waitUntil("購読が始まる") { broadcast.subscriberCount == 1 }
        broadcast.yield(1)
        _ = await consumer.value
        try await waitUntil("購読者が外れる") { broadcast.subscriberCount == 0 }
    }

    /// **終端後に購読した相手を待たせない。** 待たせると、終了処理を
    /// 「状態が `.idle` になるまで待つ」形で書いた側が永久に止まる。
    @Test("終端した後の購読は即座に終わる")
    func subscribingAfterFinishTerminatesImmediately() async {
        let broadcast = SessionBroadcast<Int>()
        broadcast.finish()
        var received: [Int] = []
        for await value in broadcast.stream() { received.append(value) }
        #expect(received.isEmpty)
    }

    @Test("終端すると全員のストリームが閉じる")
    func finishClosesEverySubscriber() async throws {
        let broadcast = SessionBroadcast<Int>()
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in broadcast.stream() { count += 1 }
            return count
        }
        try await waitUntil("購読が始まる") { broadcast.subscriberCount == 1 }
        broadcast.yield(1)
        broadcast.finish()
        #expect(await consumer.value == 1)
    }

    // MARK: - 状態の分配（欠落 1）

    @Test("stateStream は stateUpdates と同じものを流す")
    func stateStreamMirrorsStateUpdates() async throws {
        try await withTempRoot { root in
            let rig = SurfaceRig.make(root: root)
            let first = rig.session.stateStream()
            let second = rig.session.stateStream()

            let a = StateLog()
            let b = StateLog()
            let collectA = await a.collect(from: first)
            let collectB = await b.collect(from: second)
            defer {
                collectA.cancel()
                collectB.cancel()
            }

            let run = Task { await rig.session.run() }
            defer { run.cancel() }
            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }
            try await waitUntil("2 人とも最後まで受け取る") {
                let left = await a.states.last
                let right = await b.states.last
                return left == .idle && right == .idle
            }

            #expect(await a.states == b.states, "購読者ごとに見えるものが違う")
        }
    }

    // MARK: - マイク音量（欠落 3）

    /// `AudioCapturing.level` は単一消費者。**セッションが 1 人で読んで配り直す。**
    @Test("マイク音量が UI へ届く")
    func levelIsFannedOut() async throws {
        try await withTempRoot { root in
            let audio = LevelEmittingCapture()
            let rig = SurfaceRig.make(root: root, audio: audio)
            let levels = rig.session.levelStream()
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            let collected = Task { await collect(levels, count: 2) }
            try await waitUntil("配り係が読み始める") { audio.hasConsumer }
            audio.emitLevel(0.25)
            audio.emitLevel(0.5)

            #expect(await collected.value == [0.25, 0.5])
        }
    }

    // MARK: - モデル導入の進捗（欠落 5）

    @Test("モデル導入の進捗が UI へ届く")
    func assetInstallationProgressIsFannedOut() async throws {
        try await withTempRoot { root in
            let transcriber = InstallingTranscriber()
            let rig = SurfaceRig.make(root: root, transcriber: transcriber)
            let events = rig.session.assetInstallationEvents()
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            let collected = Task { await collect(events, count: 3) }
            try await waitUntil("配り係が読み始める") { transcriber.hasConsumer }
            transcriber.emit(.started)
            transcriber.emit(.progress(0.5))
            transcriber.emit(.completed)

            #expect(await collected.value == [.started, .progress(0.5), .completed])
        }
    }

    // MARK: - 整形の可否（欠落 4）

    /// **設定の `refinementEnabled` とは別の量である。** こちらは環境の能力。
    @Test("整形の可否を MainActor から同期で読める")
    @MainActor
    func refinementAvailabilityIsReadableSynchronously() throws {
        try withTempRoot { root in
            let available = SurfaceRig.make(root: root, refiner: SpyRefiner(result: "整形後"))
            let unavailable = SurfaceRig.make(root: root, refiner: SpyRefiner(result: nil))
            // `await` を書かずに読めることが要件である（SwiftUI の body は同期）。
            #expect(available.session.isRefinementAvailable)
            #expect(unavailable.session.isRefinementAvailable == false)
        }
    }

    // MARK: - ロケール変更の安全な入口（欠落 11）

    /// **「録音中に呼ぶな」を呼び出し側へ押し付けない。**
    /// 呼び出し側には守る手段が無い（`state` を読んでから呼ぶまでに PTT が押されうる）。
    @Test("録音中のロケール変更は Core が拒む")
    func prepareTranscriberRefusesWhileBusy() async throws {
        try await withTempRoot { root in
            let rig = SurfaceRig.make(root: root)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }

            await #expect(throws: DictationSessionError.busy) {
                try await rig.session.prepareTranscriber(locale: .jaJP, kind: .dictation)
            }
            #expect(rig.transcriber.prepareCount == 1, "録音中に認識器を作り直している")
        }
    }

    @Test("待機中のロケール変更は通る")
    func prepareTranscriberWorksWhenIdle() async throws {
        try await withTempRoot { root in
            let rig = SurfaceRig.make(root: root)
            try await rig.session.prepareTranscriber(
                locale: Locale(identifier: "en-US"), kind: .dictation)
            #expect(rig.transcriber.prepareCount == 1)
        }
    }

    // MARK: - Undo のバインド（FR-11）

    @Test("起動時に設定の Undo キーを監視器へ反映する")
    func appliesTheUndoBindingAtStartup() async throws {
        try await withTempRoot { root in
            let store = SettingsStore(rootURL: root)
            let binding = try HotkeyBinding(keyCode: 0x07, modifiers: [.control, .command])
            try store.update { $0.undoHotkey = binding }
            let rig = SurfaceRig.make(root: root, settings: store)

            await rig.session.warmUp()
            #expect(rig.hotkey.currentUndoBinding == binding)
        }
    }

    @Test("Undo キーの差し替えは監視器へ届く")
    func rebindsTheUndoHotkey() async throws {
        try await withTempRoot { root in
            let rig = SurfaceRig.make(root: root)
            let binding = try HotkeyBinding(keyCode: 0x08, modifiers: [.control, .command])
            try await rig.session.rebindUndoHotkey(to: binding)
            #expect(rig.hotkey.undoRebindings.last == binding)
        }
    }
}

// MARK: - 検査用の道具

/// 任意のタイミングで音量を流せる音声取得の代役。
final class LevelEmittingCapture: AudioCapturing, @unchecked Sendable {
    private let levels: AsyncStream<Float>
    private let continuation: AsyncStream<Float>.Continuation
    private let consumed = Atomic<Bool>(false)
    private let state = Mutex<AsyncStream<AVAudioPCMBuffer>.Continuation?>(nil)

    init() {
        (levels, continuation) = AsyncStream<Float>.makeStream()
    }

    /// 配り係が読み始めたか。**単一消費者なので 1 人しか居ないはずである。**
    var hasConsumer: Bool { consumed.load(ordering: .relaxed) }

    var level: AsyncStream<Float> {
        consumed.store(true, ordering: .relaxed)
        return levels
    }

    func emitLevel(_ value: Float) { continuation.yield(value) }

    var droppedBufferCount: Int { 0 }
    func prepare() throws {}
    func startTap(format: AVAudioFormat?) throws -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        state.withLock { $0 = continuation }
        return stream
    }
    func stopTap() {
        state.withLock {
            $0?.finish()
            $0 = nil
        }
    }
}

/// モデル導入の進捗を任意に流せる認識器の代役。
final class InstallingTranscriber: Transcribing, @unchecked Sendable {
    private let events: AsyncStream<AssetInstallationEvent>
    private let continuation: AsyncStream<AssetInstallationEvent>.Continuation
    private let consumed = Atomic<Bool>(false)
    private let inner = StubTranscriber()

    init() {
        (events, continuation) = AsyncStream<AssetInstallationEvent>.makeStream()
    }

    var hasConsumer: Bool { consumed.load(ordering: .relaxed) }

    var assetInstallation: AsyncStream<AssetInstallationEvent> {
        consumed.store(true, ordering: .relaxed)
        return events
    }

    func emit(_ event: AssetInstallationEvent) { continuation.yield(event) }

    func prepare(locale: Locale, kind: TranscriberKind) async throws {}
    var requiredAudioFormat: AVAudioFormat? { get async { nil } }
    func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        try await inner.begin()
    }
    func feed(_ buffer: sending AVAudioPCMBuffer) async { await inner.feed(buffer) }
    func finish() async throws { try await inner.finish() }
}

/// `prepare` の回数を数える認識器の代役（欠落 11 の検査用）。
final class CountingTranscriber: Transcribing, @unchecked Sendable {
    private let inner = StubTranscriber()
    private let prepares = Atomic<Int>(0)

    var prepareCount: Int { prepares.load(ordering: .relaxed) }

    func prepare(locale: Locale, kind: TranscriberKind) async throws {
        prepares.add(1, ordering: .relaxed)
    }
    var requiredAudioFormat: AVAudioFormat? { get async { nil } }
    func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        try await inner.begin()
    }
    func feed(_ buffer: sending AVAudioPCMBuffer) async { await inner.feed(buffer) }
    func finish() async throws { try await inner.finish() }
}

/// UI 接続面の検査用の組み立て。**挿入も差し替えも通らない軽い構成。**
struct SurfaceRig {
    let session: DictationSession
    let hotkey: StubHotkeyMonitor
    /// 既定の代役。呼び出し側が独自の代役を渡した場合は nil。
    let audio: StubAudioCapture?
    let transcriber: CountingTranscriber

    /// 1 バッファぶんを配る。独自の代役を渡した検査では使わない。
    func emit(frames: Int) { audio?.emit(frames: frames) }

    static func make(
        root: URL,
        audio: (any AudioCapturing)? = nil,
        transcriber: (any Transcribing)? = nil,
        refiner: SpyRefiner = SpyRefiner(result: "整形後テキストです"),
        settings: SettingsStore? = nil
    ) -> SurfaceRig {
        let hotkey = StubHotkeyMonitor()
        let counting = CountingTranscriber()
        let stub = audio == nil ? StubAudioCapture() : nil
        let usedAudio = audio ?? stub!
        let session = DictationSession(
            settings: settings ?? SettingsStore(rootURL: root),
            hotkey: hotkey,
            audio: usedAudio,
            transcriber: transcriber ?? counting,
            refiner: refiner,
            inserter: RecordingInserter(),
            history: HistoryStore(rootURL: root, limit: 50),
            vocabulary: VocabularyStore(rootURL: root),
            isSecureInputEnabled: { false },
            postEventAuthorization: PostEventAuthorization(probe: { false }),
            finalizeDeadline: .seconds(5)
        )
        return SurfaceRig(
            session: session, hotkey: hotkey, audio: stub, transcriber: counting)
    }
}

/// 欠落 2。**SwiftUI の `body` は同期なので、actor 隔離の状態を `await` できない。**
///
/// - Note: **写しは `@MainActor` である。** 検査からは `await` して読む
///   （SwiftUI の `body` は MainActor に居るので `await` 無しで読める）。
@Suite("SessionMirror（MainActor から同期で読める写し）")
struct SessionMirrorTests {

    @Test("状態と計測値が MainActor 側へ映る")
    func mirrorsStateAndMetrics() async throws {
        try await withTempRoot { root in
            let rig = SurfaceRig.make(root: root)
            let mirror = await SessionMirror()
            await mirror.follow(rig.session)
            defer { Task { @MainActor in mirror.stop() } }

            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が映る") {
                if case .recording = await mirror.state { return true }
                return false
            }
            #expect(await mirror.isBusy)

            rig.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("計測値が映る") { await mirror.latestMetrics != nil }

            #expect(await mirror.state == .idle)
            #expect(await mirror.isBusy == false)
        }
    }

    /// **`follow` を 2 回呼んでも購読は二重にならない。**
    @Test("二重に購読しない")
    func followIsIdempotent() async throws {
        try await withTempRoot { root in
            let rig = SurfaceRig.make(root: root)
            let mirror = await SessionMirror()
            await mirror.follow(rig.session)
            await mirror.follow(rig.session)
            defer { Task { @MainActor in mirror.stop() } }

            let run = Task { await rig.session.run() }
            defer { run.cancel() }
            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が映る") {
                if case .recording = await mirror.state { return true }
                return false
            }
            // **購読は 1 人ぶんだけ。** 2 人だと同じ値が 2 度届く。
            #expect(await mirror.isBusy)
        }
    }

    /// **差し替えは「忙しい」に数えない。** 保留中でも次の PTT は受け付けられる。
    @Test("revising は忙しいに数えない")
    func revisingIsNotBusy() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(200))
            let mirror = await SessionMirror()
            await mirror.follow(rig.session)
            defer { Task { @MainActor in mirror.stop() } }

            let run = Task { await rig.session.run() }
            defer { run.cancel() }
            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が映る") {
                if case .recording = await mirror.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("待機が映る") { await mirror.state == .idle }

            #expect(await mirror.isBusy == false, "保留中の差し替えを忙しいに数えている")
        }
    }

    @Test("表示し終えた通知を畳める")
    @MainActor
    func clearsNotice() {
        let mirror = SessionMirror()
        #expect(mirror.notice == nil)
        mirror.clearNotice()
        #expect(mirror.notice == nil)
    }
}

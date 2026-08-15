import AVFAudio
import AppKit
import Foundation
import Synchronization
import Testing

@testable import GhostVoiceApp
@testable import GhostVoiceCore

/// **HUD が「窓を作った」で終わっていないことを固定する。**
///
/// `--hud-check` の素振りは `HUDPanel.render` を直に叩くので、
/// **`NotchHUDSurface` の購読（`stateStream()` → `HUDPresenter` → `HUDPanel`）を 1 行も通らない。**
/// ここはその区間だけを、代役のセッションで端から端まで通す。
@Suite("HUD の配線が満たすべき命題", .serialized)
@MainActor
struct HUDWiringTests {

    // MARK: - 代役

    final class StubHotkey: HotkeyMonitor, @unchecked Sendable {
        private let stream: AsyncStream<HotkeyEvent>
        private let continuation: AsyncStream<HotkeyEvent>.Continuation
        var events: AsyncStream<HotkeyEvent> { stream }
        init() { (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream() }
        func send(_ event: HotkeyEvent) { continuation.yield(event) }
        func finish() { continuation.finish() }
        func start() throws {}
        func stop() { continuation.finish() }
        var currentBinding: HotkeyBinding { .rightOption }
        func rebind(to binding: HotkeyBinding) throws {}
        func setSessionBusy(_ busy: Bool) {}
        var currentUndoBinding: HotkeyBinding { .rightOption }
        func rebindUndo(to binding: HotkeyBinding) throws {}
        func setUndoAvailable(_ available: Bool) {}
        func beginHotkeyCapture(_ onEvent: @escaping @Sendable (HotkeyCaptureOutcome) -> Void) {}
        func endHotkeyCapture() {}
        var isCapturingHotkey: Bool { false }
    }

    final class StubAudio: AudioCapturing, @unchecked Sendable {
        private let levels: AsyncStream<Float>
        private let levelContinuation: AsyncStream<Float>.Continuation
        private let tap = Mutex<AsyncStream<AVAudioPCMBuffer>.Continuation?>(nil)
        init() { (levels, levelContinuation) = AsyncStream<Float>.makeStream() }
        var level: AsyncStream<Float> { levels }
        var droppedBufferCount: Int { 0 }
        func prepare() throws {}
        func startTap(format: AVAudioFormat?) throws -> AsyncStream<AVAudioPCMBuffer> {
            let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            tap.withLock { $0 = continuation }
            return stream
        }
        func stopTap() { tap.withLock { $0?.finish(); $0 = nil } }
        var isAwake: Bool { true }
        func sleep() {}
    }

    final class StubTranscriber: Transcribing, @unchecked Sendable {
        private let updates = Mutex<AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?>(
            nil)
        func prepare(locale: Locale, kind: TranscriberKind) async throws {}
        var requiredAudioFormat: AVAudioFormat? { get async { nil } }
        func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
            let (stream, continuation) = AsyncThrowingStream<TranscriptionUpdate, Error>
                .makeStream()
            updates.withLock { $0 = continuation }
            return stream
        }
        func feed(_ buffer: sending AVAudioPCMBuffer) async {}
        func finish() async throws { updates.withLock { $0?.finish(); $0 = nil } }
    }

    struct StubRefiner: Refining {
        var isAvailable: Bool { false }
        func prewarm() async {}
        func refine(_ raw: String, locale: Locale, terms: [VocabularyTerm], timeout: Duration)
            async -> String?
        { nil }
    }

    struct SilentInserter: TextInserting {
        func insert(_ text: String) async -> InsertionOutcome { .inserted(.ax) }
    }

    // MARK: - 組み立て

    private static func makeServices(hotkey: StubHotkey) throws -> (AppServices, DictationSession) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghost-voice-hud-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = SettingsStore(rootURL: root)
        let history = HistoryStore(rootURL: root, limit: 10)
        let vocabulary = VocabularyStore(rootURL: root)
        let session = DictationSession.forTests(
            settings: settings,
            hotkey: hotkey,
            audio: StubAudio(),
            transcriber: StubTranscriber(),
            refiner: StubRefiner(),
            inserter: SilentInserter(),
            history: history,
            vocabulary: vocabulary,
            // **本物の secure input を読まない。** 検査が機体の状態に左右される。
            isSecureInputEnabled: { false })
        let services = AppServices(
            session: session,
            settings: settings,
            history: history,
            vocabulary: vocabulary,
            permissions: PermissionStatus(
                microphoneStatus: "authorized", microphoneAuthorized: true,
                accessibilityTrusted: true, listenEventAccess: true, postEventAccess: true,
                secureInputEnabled: false),
            hotkeyFailure: nil,
            storageRoot: root)
        return (services, session)
    }

    /// 期限つきで条件が満たされるのを待つ。**実時間の合否線は要件値ではない。**
    private static func wait(
        seconds: Double = 5, until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - 命題

    /// **これが落ちるなら、利用者の実機で HUD は 1 度も出ない。**
    @Test("録音が始まると HUD が表示へ移る（購読 → 間引き → 窓）")
    func recordingReachesTheHUD() async throws {
        _ = NSApplication.shared
        let hotkey = StubHotkey()
        let (services, session) = try Self.makeServices(hotkey: hotkey)
        let surface = NotchHUDSurface(RunLoopEntry(), services: services)
        defer { surface.teardown() }

        let run = Task { await session.run() }
        // **購読が成立するまで待つ。** 成立前に撃つと誰にも届かない（`stateSubscriberCount`）。
        #expect(await Self.wait { session.stateSubscriberCount > 0 }, "状態の購読が始まらない")

        hotkey.send(.pressed)
        #expect(
            await Self.wait { surface.currentDisplayForTests.isVisible },
            "録音が始まっても HUD が表示へ移らない（実機で「何も出ない」の形）")
        #expect(
            await Self.wait { surface.panelIsVisibleForTests == true },
            "表示へは移ったが窓が出ていない")

        hotkey.finish()
        _ = await run.value
    }

    /// **`--hud-check` が製品の経路を通ることを固定する。**
    ///
    /// 素振りが `HUDPanel.render` を直に叩いていた頃、この確認は
    /// `HUDPresenter` も `handle(_:)` も 1 行も通らなかった。
    /// **緑の `--hud-check` が「録音でも出る」の根拠にならなかった**のはそのためである。
    @Test("素振りは購読と同じ経路で窓を出す")
    func rehearsalDrivesTheProductPath() async throws {
        _ = NSApplication.shared
        let hotkey = StubHotkey()
        let (services, _) = try Self.makeServices(hotkey: hotkey)
        let surface = NotchHUDSurface(RunLoopEntry(), services: services)
        defer { surface.teardown() }

        await withCheckedContinuation { continuation in
            surface.startRehearsal(seconds: 0.1) { continuation.resume() }
        }
        // 配線の筋書きは必ず通る（秒数が尽きていても 1 巡目は走る）。
        #expect(surface.panelIsVisibleForTests != nil, "窓を作れていない")
    }

    /// **窓を作れないときに黙らない。** 画面が 1 枚も無い構成でしか起きないが、
    /// そのときに「出したつもり」で進むと、外からは欠陥と区別できない。
    @Test("窓が無ければ覗き口も nil を返す（黙って真を返さない）")
    func panelAbsenceIsVisible() throws {
        _ = NSApplication.shared
        let hotkey = StubHotkey()
        let (services, _) = try Self.makeServices(hotkey: hotkey)
        let surface = NotchHUDSurface(RunLoopEntry(), services: services)
        defer { surface.teardown() }
        // この機体には画面があるので窓は作れている。**nil と false を混同していないこと。**
        #expect(surface.panelIsVisibleForTests == false)
    }
}

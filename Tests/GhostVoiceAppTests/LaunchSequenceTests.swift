import Foundation
import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

/// 画面の身代わり。**生まれた回数と畳まれた回数だけを数える。**
@MainActor
final class SpySurface: AppSurface {
    static var births = 0
    static var teardowns = 0
    init() { SpySurface.births += 1 }
    func teardown() { SpySurface.teardowns += 1 }
}

@Suite("起動の順序（window は run() の後にしか生まれない）", .serialized)
@MainActor
struct LaunchSequenceTests {

    /// 実ファイルを触らないための一時ルート。**利用者の設定を読み書きしない。**
    private func makeServices() -> AppServices {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghost-voice-app-tests-\(UUID().uuidString)")
        return AppServices(
            session: nil,
            settings: SettingsStore(rootURL: root),
            history: HistoryStore(rootURL: root, limit: 10),
            vocabulary: VocabularyStore(rootURL: root),
            permissions: PermissionStatus(
                microphoneStatus: "未確認", microphoneAuthorized: false,
                accessibilityTrusted: false, listenEventAccess: false, postEventAccess: false,
                secureInputEnabled: false, bundleIdentifier: nil),
            hotkeyFailure: nil)
    }

    /// **これが「起動時に非表示の window を用意しておく」実装を防いでいる本体である。**
    ///
    /// 画面は工場の中でしか生まれず、工場は `enterRunLoop`（= `NSApp.run()` の
    /// イベントループが回り始めた後に呼ばれる）でしか呼ばれない。
    /// 実測の根拠: run() の前に `orderFrontRegardless()` するとアプリが活性化し、
    /// 挿入先の判定（最前面 pid）が Ghost Voice 自身になる（`core-api-and-hud.md` B-3）。
    @Test("run() へ入るまで画面は 1 つも作られない")
    func nothingBeforeRunLoop() {
        SpySurface.births = 0
        let sequence = LaunchSequence(factories: [{ _, _ in SpySurface() }])
        #expect(sequence.phase == .beforeRunLoop)
        #expect(SpySurface.births == 0)
        #expect(sequence.surfaces.isEmpty)

        sequence.enterRunLoop(services: makeServices())
        #expect(sequence.phase == .running)
        #expect(SpySurface.births == 1)
        #expect(sequence.surfaces.count == 1)
    }

    @Test("2 度目の enterRunLoop では画面が増えない")
    func idempotent() {
        SpySurface.births = 0
        let sequence = LaunchSequence(factories: [{ _, _ in SpySurface() }])
        let services = makeServices()
        #expect(sequence.enterRunLoop(services: services) == 1)
        #expect(sequence.enterRunLoop(services: services) == 0)
        #expect(SpySurface.births == 1)
    }

    @Test("tearDown は作った画面を畳み、以後は 1 つも作らない")
    func tearDown() {
        SpySurface.births = 0
        SpySurface.teardowns = 0
        let sequence = LaunchSequence(factories: [{ _, _ in SpySurface() }, { _, _ in SpySurface() }])
        sequence.enterRunLoop(services: makeServices())
        sequence.tearDown()
        #expect(SpySurface.teardowns == 2)
        #expect(sequence.surfaces.isEmpty)
        #expect(sequence.phase == .tornDown)

        #expect(sequence.enterRunLoop(services: makeServices()) == 0)
        #expect(SpySurface.births == 2)
    }

    /// 画面を 1 つも渡さなくても器は成立する（フェーズ 2 の途中はこの状態で走る）。
    @Test("画面が 0 個でも成立する")
    func noSurfaces() {
        let sequence = LaunchSequence(factories: [])
        #expect(sequence.enterRunLoop(services: makeServices()) == 0)
        #expect(sequence.phase == .running)
    }
}

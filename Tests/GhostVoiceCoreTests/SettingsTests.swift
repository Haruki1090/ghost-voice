import Foundation
import Testing
@testable import GhostVoiceCore

@Suite("Settings")
struct SettingsTests {

    @Test("既定値が仕様どおり")
    func defaults() {
        let s = Settings.default
        #expect(s.hotkey == .rightOption)
        #expect(s.undoHotkey == .controlCommandZ)
        #expect(s.localeIdentifier == "ja-JP")
        #expect(s.transcriberKind == .dictation)
        #expect(s.refinementEnabled)
        // 打ち切りは NFR-P4 の目標値 500 ms ではなく NFR-P6 の予算から決まる（詳細設計書 §10）。
        #expect(s.refinementTimeoutMs == 750)
        #expect(s.historyLimit == 50)
    }

    @Test("未知のキーを含む JSON を読み込める")
    func decodesWithUnknownKeys() throws {
        let json = """
        {"hotkey":{"keyCode":61,"modifiers":["option"]},
         "undoHotkey":{"keyCode":6,"modifiers":["control","command"]},
         "localeIdentifier":"en-US","transcriberKind":"speech",
         "refinementEnabled":false,"refinementTimeoutMs":800,
         "historyLimit":10,"futureFeature":"ignored"}
        """
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(s.localeIdentifier == "en-US")
        #expect(s.transcriberKind == .speech)
        #expect(s.refinementTimeoutMs == 800)
        // 複数フラグの修飾キーが実際に復元されること。
        // 名前が一致しなくても throw せず空集合になるため、明示的に確かめる。
        #expect(s.undoHotkey == .controlCommandZ)
    }
}

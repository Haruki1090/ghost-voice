import Foundation
import Testing
@testable import GhostVoiceCore

@Suite("HotkeyBinding")
struct HotkeyBindingTests {

    @Test("右 Option の既定値が正しい")
    func rightOptionDefault() {
        let ptt = HotkeyBinding.rightOption
        #expect(ptt.keyCode == 0x3D)
        #expect(ptt.modifiers == [.option])
        #expect(ptt.isModifierOnly)
    }

    @Test("⌃⌘Z の既定値が正しい")
    func undoDefault() {
        let undo = HotkeyBinding.controlCommandZ
        #expect(undo.keyCode == 0x06)
        #expect(undo.modifiers == [.control, .command])
        #expect(!undo.isModifierOnly)
    }

    @Test("PTT と修飾キーが衝突する組み合わせを検出する")
    func conflictDetection() {
        // ⌥⌘Z は PTT（右 Option）と衝突する
        let optionCommandZ = HotkeyBinding(keyCode: 0x06, modifiers: [.option, .command])
        #expect(HotkeyBinding.rightOption.conflicts(with: optionCommandZ))

        // ⌃⌘Z は衝突しない
        #expect(!HotkeyBinding.rightOption.conflicts(with: .controlCommandZ))
    }

    @Test("JSON を往復できる")
    func codableRoundTrip() throws {
        let original = HotkeyBinding.rightOption
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyBinding.self, from: data)
        #expect(decoded == original)
    }
}

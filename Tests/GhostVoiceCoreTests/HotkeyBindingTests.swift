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

    @Test("修飾キーを人間が読める文字列配列としてエンコードする")
    func modifiersEncodeAsStringArray() throws {
        // 設定ファイルを人間が読み書きできることが要件（詳細設計書 §9.1）。
        // 合成実装の Int 表現に戻ると落ちる。
        let json = String(decoding: try JSONEncoder().encode(HotkeyBinding.controlCommandZ), as: UTF8.self)
        #expect(json.contains("\"command\"") && json.contains("\"control\""))
    }

    @Test("複数の修飾キーを含むバインドを往復できる")
    func multipleModifiersRoundTrip() throws {
        let data = try JSONEncoder().encode(HotkeyBinding.controlCommandZ)
        #expect(try JSONDecoder().decode(HotkeyBinding.self, from: data) == .controlCommandZ)
    }
}

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
    func conflictDetection() throws {
        // ⌥⌘Z は PTT（右 Option）と衝突する
        let optionCommandZ = try HotkeyBinding(keyCode: 0x06, modifiers: [.option, .command])
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

    // MARK: - 自己矛盾したバインドを作れないこと（持ち越し項目 4 / 12。詳細設計書 §12-9）

    /// **§2.3 の実測**: 修飾キー単独のバインドでは、判定側（`isModifierDown`）が
    /// デバイスビットを引けた時点で `binding.modifiers` を参照しない。したがって
    /// `⇧ + 右 Option` を設定しても**右 Option 単独で発火する**。設定が黙って
    /// 無視される状態を作れてしまうこと自体が欠陥なので、**モデルが弾く。**
    @Test("修飾キー単独のバインドに追加の修飾キーは付けられない")
    func modifierOnlyRejectsExtraModifiers() {
        #expect(throws: HotkeyBindingError.self) {
            try HotkeyBinding(keyCode: 0x3D, modifiers: [.option, .shift])
        }
    }

    /// **空の修飾キーも弾く。** `conflicts(with:)` は修飾キー単独のバインドに対して
    /// 「修飾キーが重なるか」で判定するので、`modifiers` が空だと**どの Undo キーとも
    /// 衝突しなくなる**——⌥ を含む Undo キーを禁じる §8.3 の保護が、手編集 1 箇所で消える。
    @Test("修飾キー単独のバインドは自分自身の修飾キーを持たねばならない")
    func modifierOnlyRequiresItsOwnModifier() {
        #expect(throws: HotkeyBindingError.self) {
            try HotkeyBinding(keyCode: 0x3D, modifiers: [])
        }
        // 別の修飾キーへの付け替えも同じ理由で弾く（右 Option に .shift だけ、など）。
        #expect(throws: HotkeyBindingError.self) {
            try HotkeyBinding(keyCode: 0x3D, modifiers: [.shift])
        }
    }

    /// 8 つの修飾キーすべてに正準な組があること。表を片側だけ育てると、
    /// 追加した修飾キーが「必ず不正」になって設定できなくなる。
    @Test(
        "修飾キー単独のバインドは正準な修飾キーの組を受け付ける",
        arguments: [
            (Int64(0x3A), HotkeyBinding.Modifiers.option),  // 左 Option
            (0x3D, .option),  // 右 Option
            (0x38, .shift),  // 左 Shift
            (0x3C, .shift),  // 右 Shift
            (0x37, .command),  // 左 Command
            (0x36, .command),  // 右 Command
            (0x3B, .control),  // 左 Control
            (0x3E, .control),  // 右 Control
        ])
    func modifierOnlyAcceptsCanonicalModifier(keyCode: Int64, modifier: HotkeyBinding.Modifiers)
        throws
    {
        let binding = try HotkeyBinding(keyCode: keyCode, modifiers: modifier)
        #expect(binding.isModifierOnly)
        #expect(binding.modifiers == modifier)
    }

    /// 仮想キーコードは 0...0x7F。`61` を `610` と打ち間違えた `settings.json` は、
    /// **どのキーイベントにも一致しないので PTT が恒久的に死ぬ**（しかも無言で）。
    @Test("範囲外のキーコードは弾く")
    func rejectsOutOfRangeKeyCode() {
        #expect(throws: HotkeyBindingError.self) { try HotkeyBinding(keyCode: 610, modifiers: []) }
        #expect(throws: HotkeyBindingError.self) { try HotkeyBinding(keyCode: -1, modifiers: []) }
    }

    /// 修飾キー以外のバインドは修飾キーの組を自由に選べる（⌃⌘Z など）。
    /// 上の禁止を広げすぎていないことの反証。
    @Test("修飾キー以外のバインドは修飾キーの組を自由に取れる")
    func nonModifierBindingAcceptsAnyModifiers() throws {
        #expect(try HotkeyBinding(keyCode: 0x06, modifiers: [.control, .command]).modifiers
            == [.control, .command])
        #expect(try HotkeyBinding(keyCode: 0x06, modifiers: [.option, .shift]).isModifierOnly
            == false)
    }

    // MARK: - 手編集した JSON にも不変条件が効くこと（持ち越し項目 12）

    /// **これが本項目の要**。衝突検査が `SettingsStore.update` にしか無かったため、
    /// 手編集の `settings.json` は検査を素通りしていた（最終レビュー M-7）。
    @Test("手編集の JSON から修飾キー単独 + 追加修飾キーは復元できない")
    func decodeRejectsModifierOnlyWithExtraModifiers() {
        let json = #"{"keyCode":61,"modifiers":["option","shift"]}"#
        #expect(throws: HotkeyBindingError.self) {
            try JSONDecoder().decode(HotkeyBinding.self, from: Data(json.utf8))
        }
    }

    @Test("手編集の JSON から修飾キーの無い修飾キー単独バインドは復元できない")
    func decodeRejectsModifierOnlyWithoutModifiers() {
        let json = #"{"keyCode":61,"modifiers":[]}"#
        #expect(throws: HotkeyBindingError.self) {
            try JSONDecoder().decode(HotkeyBinding.self, from: Data(json.utf8))
        }
    }

    @Test("手編集の JSON から範囲外のキーコードは復元できない")
    func decodeRejectsOutOfRangeKeyCode() {
        let json = #"{"keyCode":610,"modifiers":["option"]}"#
        #expect(throws: HotkeyBindingError.self) {
            try JSONDecoder().decode(HotkeyBinding.self, from: Data(json.utf8))
        }
    }

    /// 妥当な手編集は通ること（過剰な拒否をしていない）。
    @Test("妥当な手編集の JSON はそのまま復元できる")
    func decodeAcceptsValidHandEditedJSON() throws {
        let json = #"{"keyCode":61,"modifiers":["option"]}"#
        #expect(try JSONDecoder().decode(HotkeyBinding.self, from: Data(json.utf8)) == .rightOption)
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

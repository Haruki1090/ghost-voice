import Foundation
import GhostVoiceCore

/// バインドを人が読める形にする。**表示だけである。検査は 1 文字も持たない。**
///
/// 記号の並び順は macOS の慣例（⌃⌥⇧⌘）に合わせる。
public enum HotkeyLabel {

    /// 修飾キー単独のバインドは、そのキーの名前だけを出す。
    ///
    /// **「右 Option」と「⌥」を並べて出さない。** 右 Option を押している間だけ
    /// 録音するのが既定なので、「⌥」だけだと左右の区別が落ちる。
    static let modifierOnlyNames: [Int64: String] = [
        0x37: "左 Command", 0x36: "右 Command",
        0x3A: "左 Option", 0x3D: "右 Option",
        0x38: "左 Shift", 0x3C: "右 Shift",
        0x3B: "左 Control", 0x3E: "右 Control",
    ]

    public static func text(for binding: HotkeyBinding) -> String {
        if let name = modifierOnlyNames[binding.keyCode] {
            return name
        }
        return modifierSymbols(binding.modifiers) + keyName(binding.keyCode)
    }

    static func modifierSymbols(_ modifiers: HotkeyBinding.Modifiers) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    /// **表に無いキーコードは 16 進で出す。**
    ///
    /// 「不明」と出すと、手編集した `settings.json` のキーコードを確かめられない。
    /// 表を網羅する価値は無い（利用者は打鍵で設定する）が、**出した値から
    /// 元の数へ戻せること**には価値がある。
    static func keyName(_ keyCode: Int64) -> String {
        if let name = namedKeys[keyCode] { return name }
        return String(format: "キーコード 0x%02X", keyCode)
    }

    private static let namedKeys: [Int64: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x1F: "O",
        0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K",
        0x2D: "N", 0x2E: "M", 0x31: "スペース", 0x24: "Return", 0x30: "Tab",
        0x33: "Delete", 0x35: "Esc",
    ]
}

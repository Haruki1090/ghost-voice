import Foundation

public struct HotkeyBinding: Codable, Sendable, Equatable {

    public struct Modifiers: OptionSet, Codable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option  = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift   = Modifiers(rawValue: 1 << 3)

        private static let names: [(Modifiers, String)] = [
            (.command, "command"), (.option, "option"),
            (.control, "control"), (.shift, "shift"),
        ]

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode([String].self)
            var result = Modifiers()
            for (flag, name) in Self.names where raw.contains(name) {
                result.insert(flag)
            }
            self = result
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(Self.names.filter { contains($0.0) }.map(\.1))
        }
    }

    /// 仮想キーコード。修飾キー単独の場合は、その修飾キー自身のキーコード。
    public let keyCode: Int64
    public let modifiers: Modifiers

    public init(keyCode: Int64, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 右 Option（kVK_RightOption）。PTT の既定値。
    public static let rightOption = HotkeyBinding(keyCode: 0x3D, modifiers: [.option])

    /// ⌃⌘Z。Undo の既定値。Option を含めてはならない。
    public static let controlCommandZ = HotkeyBinding(keyCode: 0x06, modifiers: [.control, .command])

    /// 修飾キー単独のバインドか。押しっぱなし検出は flagsChanged で行う必要がある。
    public var isModifierOnly: Bool {
        [0x37, 0x36, 0x3A, 0x3D, 0x38, 0x3C, 0x3B, 0x3E].contains(keyCode)
    }

    /// PTT キーの修飾キーを、相手のバインドが含んでいるか。
    ///
    /// PTT が修飾キー単独の場合、その修飾キーを含む他のショートカットを押すと
    /// PTT が誤発火する。設定画面のバリデーションに使う。
    public func conflicts(with other: HotkeyBinding) -> Bool {
        guard isModifierOnly else { return self == other }
        return !modifiers.isDisjoint(with: other.modifiers)
    }
}

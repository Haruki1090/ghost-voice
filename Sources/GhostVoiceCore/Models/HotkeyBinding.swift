import Foundation

/// `HotkeyBinding` として成り立たない組み合わせ。
///
/// **設定画面はこれを利用者への説明に使う。** どの規則に触れたかを型で持つので、
/// 「このキーは使えません」ではなく「右 Option に Shift は足せません」と言える。
public enum HotkeyBindingError: Error, Equatable, Sendable {

    /// 仮想キーコードが範囲外（macOS の仮想キーコードは `0...0x7F`）。
    ///
    /// 手編集の `settings.json` で `61` を `610` と打ち間違えた場合がこれ。
    /// **どのキーイベントにも一致しないので、PTT が無言で恒久的に死ぬ。**
    case keyCodeOutOfRange(Int64)

    /// 修飾キー単独のバインドの `modifiers` が、そのキー自身の修飾キーと一致しない。
    ///
    /// 詳細設計書 §2.3 の実測: 修飾キー単独のバインドでは判定側が
    /// `binding.modifiers` を参照しないため、**追加の修飾キーは無視されて単独で発火する。**
    /// また `modifiers` が空だと `conflicts(with:)` がどの Undo キーとも衝突しなくなり、
    /// 「Undo に ⌥ を含めない」（§8.3）の保護が消える。
    case modifierOnlyKeyRequiresItsOwnModifier(
        keyCode: Int64, expected: HotkeyBinding.Modifiers, actual: HotkeyBinding.Modifiers)

    /// **どの規則に触れたかを利用者の言葉で言う。**
    ///
    /// 文言を Core に置くのは `SessionFailureNotice` / `SessionNoticeAnnouncement` と
    /// 同じ理由である——**設定画面と CLI（`settings.json` の手編集を案内する側）で
    /// 別々に書き直されると必ず食い違う。** 媒体で変わらないところだけをここが持つ。
    public var explanation: String {
        switch self {
        case .keyCodeOutOfRange(let keyCode):
            return
                "そのキー（コード \(keyCode)）は使えません。macOS の仮想キーコードは 0〜127 です。"
        case .modifierOnlyKeyRequiresItsOwnModifier(_, let expected, _):
            // **修飾キー単独のバインドでは、足した修飾キーは無視されて単独で発火する**
            // （実測 / 詳細設計書 §2.3）。だから足させない。
            return
                "修飾キーだけを割り当てるときは、そのキー自身（\(expected.localizedNames)）以外の"
                + "修飾キーを足せません。足しても押した瞬間に単独で発火します。"
        }
    }
}

extension HotkeyBinding.Modifiers {
    /// 利用者へ見せる修飾キーの名前。**表示は 1 箇所からしか作らない。**
    public var localizedNames: String {
        var names: [String] = []
        if contains(.control) { names.append("⌃") }
        if contains(.option) { names.append("⌥") }
        if contains(.shift) { names.append("⇧") }
        if contains(.command) { names.append("⌘") }
        return names.isEmpty ? "（無し）" : names.joined()
    }
}

/// PTT / Undo に割り当てる打鍵。
///
/// ## 不変条件（詳細設計書 §12-9 の受け入れ条件）
///
/// **不正な値を持つ `HotkeyBinding` は存在しない。** 唯一の初期化子が検証を行い、
/// `Codable` の復元もそこを通る。したがって**手編集した `settings.json` からの復元にも
/// 同じ検査が効く**（フェーズ 1 では衝突検査が `SettingsStore.update` の経路にしか
/// 無かった。持ち越し項目 4 / 12、最終レビュー M-7）。
///
/// 検証は 2 段に分かれる。**1 つのバインド単体で決まること**はこの型が持ち、
/// **PTT と Undo の関係**は `Settings.validateHotkeys()` が一括で見る。
///
/// - Important: 初期化子は `throws` である。**設定画面は捕まえて利用者へ理由を出すこと**
///   （`HotkeyBindingError` がどの規則かを持っている）。
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

    /// 修飾キー単独として扱う仮想キーコードと、そのキー自身の修飾キー。
    ///
    /// **表は 1 つだけ持つ。** `isModifierOnly` の判定と「正準な修飾キー」の両方を
    /// ここから導く。2 つの表に分けると、片方だけに足したときに
    /// 「単独扱いなのに正準な組が無い＝設定できないキー」が生まれる。
    static let modifierOnlyKeys: [Int64: Modifiers] = [
        0x37: .command,  // 左 Command
        0x36: .command,  // 右 Command
        0x3A: .option,  // 左 Option
        0x3D: .option,  // 右 Option
        0x38: .shift,  // 左 Shift
        0x3C: .shift,  // 右 Shift
        0x3B: .control,  // 左 Control
        0x3E: .control,  // 右 Control
    ]

    /// 仮想キーコードとして取りうる範囲。macOS の仮想キーコードは 7 ビットに収まる。
    static let validKeyCodes: ClosedRange<Int64> = 0...0x7F

    /// 仮想キーコード。修飾キー単独の場合は、その修飾キー自身のキーコード。
    public let keyCode: Int64
    public let modifiers: Modifiers

    /// - Throws: `HotkeyBindingError` — 不変条件に反する組み合わせ。
    ///   **設定画面はこれを利用者への説明に使うこと。**
    public init(keyCode: Int64, modifiers: Modifiers) throws {
        guard Self.validKeyCodes.contains(keyCode) else {
            throw HotkeyBindingError.keyCodeOutOfRange(keyCode)
        }
        if let own = Self.modifierOnlyKeys[keyCode], modifiers != own {
            throw HotkeyBindingError.modifierOnlyKeyRequiresItsOwnModifier(
                keyCode: keyCode, expected: own, actual: modifiers)
        }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 検証を通さない初期化子。**この型が持つ既定値の宣言にだけ使う。**
    /// 外へ出すと不変条件が不変でなくなる。
    private init(unchecked keyCode: Int64, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers
    }

    /// **手編集した `settings.json` もここを通る。**
    /// 復元の経路にだけ穴が開いていた（持ち越し項目 12）のを塞ぐ入口である。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            keyCode: container.decode(Int64.self, forKey: .keyCode),
            modifiers: container.decode(Modifiers.self, forKey: .modifiers)
        )
    }

    /// 右 Option（kVK_RightOption）。PTT の既定値。
    public static let rightOption = HotkeyBinding(unchecked: 0x3D, modifiers: [.option])

    /// ⌃⌘Z。Undo の既定値。Option を含めてはならない。
    public static let controlCommandZ = HotkeyBinding(unchecked: 0x06, modifiers: [.control, .command])

    /// そのキーコードを修飾キー単独として扱うか。**インスタンスを作らずに問える。**
    /// 設定画面がキー入力を捕まえた直後、`modifiers` を決める前に使う。
    public static func isModifierOnly(keyCode: Int64) -> Bool {
        modifierOnlyKeys[keyCode] != nil
    }

    /// そのキーコード自身の修飾キー。修飾キー単独でなければ nil。
    ///
    /// 設定画面はこれを使って、捕まえたキーから**必ず妥当なバインド**を組み立てられる
    /// （右 Option を押されたら `modifiers` は `.option` 一択である）。
    public static func ownModifier(forKeyCode keyCode: Int64) -> Modifiers? {
        modifierOnlyKeys[keyCode]
    }

    /// 修飾キー単独のバインドか。押しっぱなし検出は flagsChanged で行う必要がある。
    public var isModifierOnly: Bool {
        Self.isModifierOnly(keyCode: keyCode)
    }

    /// PTT キーの修飾キーを、相手のバインドが含んでいるか。
    ///
    /// PTT が修飾キー単独の場合、その修飾キーを含む他のショートカットを押すと
    /// PTT が誤発火する。**既定（PTT = 右 Option）では、⌥ を含む Undo キーがこれに当たる**
    /// （詳細設計書 §8.3。押すと録音が始まる）。
    ///
    /// - Important: 呼ぶ側ではなく `Settings.validateHotkeys()` を使うこと。
    ///   保存経路と復元経路の両方から呼ばれる一括の入口はそちらである。
    public func conflicts(with other: HotkeyBinding) -> Bool {
        guard isModifierOnly else { return self == other }
        return !modifiers.isDisjoint(with: other.modifiers)
    }
}

import CoreGraphics
import Foundation

public enum HotkeyEvent: Sendable, Equatable {
    case pressed
    case released
    /// ESC による中断、またはタップが無効化されて解放を取りこぼした場合。
    case cancelled
}

public protocol HotkeyMonitor: AnyObject, Sendable {
    var events: AsyncStream<HotkeyEvent> { get }
    func start() throws
    func stop()
}

/// タップを開けなかった瞬間の権限照会の答え。
///
/// **どちらが門番かをこちらで決め打ちしない**ために持ち回る。実測では
/// `CGEvent.tapCreate` の可否と個々の照会の対応を確定できなかった（§権限の項）。
/// 権限案内の画面は、この 2 つを見てユーザーを開くべきペインへ導くこと。
public struct TapPermissionSnapshot: Sendable, Equatable {
    /// `CGPreflightListenEventAccess()`（`kTCCServiceListenEvent` / 入力監視）。
    public let listenEventAccess: Bool
    /// `AXIsProcessTrusted()`（`kTCCServiceAccessibility` / アクセシビリティ）。
    public let accessibilityTrusted: Bool

    public init(listenEventAccess: Bool, accessibilityTrusted: Bool) {
        self.listenEventAccess = listenEventAccess
        self.accessibilityTrusted = accessibilityTrusted
    }
}

public enum HotkeyError: Error, Equatable, Sendable {
    /// `CGEvent.tapCreate` が nil を返した。実質的に権限が無い。
    ///
    /// CoreGraphics のヘッダによれば、キーイベントの監視を許されていない場合
    /// **要求したマスクから該当ビットが落とされ、空になった時点で NULL が返る。**
    /// つまり nil は「権限が無い」の権威ある答えであり、事前照会より信用できる。
    case eventTapNotPermitted(TapPermissionSnapshot)
    /// タップは生成できたが、使える状態にならなかった。
    ///
    /// 有効化できなかった場合（**この状態のタップは 1 件も配送しない**）と、
    /// ランループソースを作れなかった場合（無効な `CFMachPort` を渡された）を含む。
    case tapDisabledAtStart
    case alreadyRunning
    /// `stop()` 済みの監視器を再起動しようとした。ストリームは終端済みで復活しない。
    case stopped
}

/// キーイベントの解釈。`CGEventTap` から切り離した純粋関数としてテストする。
///
/// **ここを純粋関数に保つこと自体が要件である。** 要件定義書 R-1 の副作用
/// （PTT 中の打鍵が ⌥ 付き入力になる）が実地（V-4）で問題になった場合、
/// 「2 回連続押下でトグル」方式へ差し替える必要がある。差し替えの範囲を
/// この列挙型の中に閉じ込めておく（詳細設計書 §2.4）。
public enum HotkeyDecision {

    static let escapeKeyCode: Int64 = 0x35

    /// - Parameter type: `CGEventTap` のコールバックが受け取るイベント種別。
    ///   **修飾キー以外のバインドでは、これが無いと押下と解放を区別できない。**
    /// - Returns: 発火するイベントと、そのキーイベントを抑止するか。
    public static func decide(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        binding: HotkeyBinding,
        isRecording: Bool
    ) -> (event: HotkeyEvent?, suppress: Bool) {

        // **バインドを先に見る。** ESC を PTT に割り当てたユーザーから
        // PTT を奪わないため（その場合 ESC による中断は使えなくなる）。
        if keyCode == binding.keyCode {
            return pushToTalk(type: type, flags: flags, binding: binding, isRecording: isRecording)
        }

        if keyCode == escapeKeyCode {
            // **抑止するのは keyDown だけ。** keyUp まで抑止しても中断は漏れず、
            // 下流アプリのキー状態だけが狂う。
            guard type == .keyDown else { return (nil, false) }
            // 録音中の ESC だけを中断として消費する
            return isRecording ? (.cancelled, true) : (nil, false)
        }

        return (nil, false)
    }

    private static func pushToTalk(
        type: CGEventType,
        flags: CGEventFlags,
        binding: HotkeyBinding,
        isRecording: Bool
    ) -> (event: HotkeyEvent?, suppress: Bool) {

        let isDown: Bool
        /// この打鍵を PTT として消費したか（＝挿入先アプリへ渡さないか）。
        let consumed: Bool

        if binding.isModifierOnly {
            // 修飾キーは keyDown / keyUp を出さない。flagsChanged だけが手掛かり。
            guard type == .flagsChanged else { return (nil, false) }
            isDown = isModifierDown(keyCode: binding.keyCode, flags: flags, binding: binding)

            // **修飾キーの flagsChanged は決して抑止しない。**
            // 抑止すると下流アプリが修飾状態を見失い、⌥+矢印などが壊れる。
            // 右 Option 単独の押下はほとんどのアプリで無害である（設計書 §2.4）。
            consumed = false
        } else {
            // **修飾キー以外は flagsChanged を出さない。** keyUp を見なければ
            // 解放を検出できず、録音が永遠に終わらない。
            //
            // **そしてこちらは抑止する。** 修飾キーを抑止しない理由（下流が修飾状態を
            // 見失う）は文字キーには当てはまらない。抑止しないと、たとえば既定の
            // Undo と同じ ⌃⌘Z を PTT に割り当てたユーザーは、喋るたびに挿入先アプリで
            // Undo / Redo を走らせることになる。**ユーザーが PTT として割り当てた打鍵は
            // PTT だけのものである。**
            switch type {
            case .keyDown:
                isDown = flags.contains(binding.modifiers.cgEventFlags)
                // 修飾キーが揃っていなければ、ユーザーはただ文字を打っている。通す。
                consumed = isDown
            case .keyUp:
                isDown = false
                // 押下を消費していたなら、対になる keyUp も消費する。
                // 押下を通したのに keyUp だけ消すと、下流アプリのキー状態が狂う。
                consumed = isRecording
            default:
                return (nil, false)
            }
        }

        switch (isDown, isRecording) {
        case (true, false): return (.pressed, consumed)
        case (false, true): return (.released, consumed)
        default: return (nil, consumed)
        }
    }

    /// 左右を区別して修飾キーの押下を判定する。
    ///
    /// **汎用マスクだけでは左右を区別できない。** 左 Option を押したまま右 Option を
    /// 離すと `.maskAlternate` は立ったままなので、汎用マスクで判定する実装は
    /// 解放を取りこぼし、**録音が終わらなくなる。**
    ///
    /// `CGEventFlags` の下位ビットには IOLLEvent.h の device-dependent ビットが
    /// そのまま載っている（`NX_DEVICELALTKEYMASK` = 0x20 / `NX_DEVICERALTKEYMASK` = 0x40 など）。
    ///
    /// - Important: **デバイスビットを報告しない入力源への保険を入れてある。**
    ///   汎用マスクが立っているのに左右どちらのビットも無い場合は、従来どおり
    ///   汎用マスクで押下とみなす。ここで解放と誤判定すると、そういう入力源では
    ///   PTT が押した瞬間に切れて**まったく使えなくなる**（デバイスビットに頼る
    ///   実装の失敗は、取りこぼしより重い方へ倒れる）。
    ///   実キーボードがこのビットを立てることは V-4（Task 11）で確認する。
    private static func isModifierDown(
        keyCode: Int64, flags: CGEventFlags, binding: HotkeyBinding
    ) -> Bool {
        // **この退避経路は現在到達しない。** `isModifierOnly` が認める 8 個の
        // キーコードは全て `ModifierSide` の表に載っている（テスト
        // 「修飾キー単独として扱うキーコードは全て左右のビット表にある」がその不変条件）。
        // 表への追加を忘れたときに**落ちずに従来の判定へ落ちる**ための保険として残す。
        // ミューテーションテストではここを潰す変異が生き残る（等価変異）。
        guard let bits = ModifierSide.bits(forKeyCode: keyCode) else {
            return flags.contains(binding.modifiers.cgEventFlags)
        }
        let anySidePresent = (flags.rawValue & bits.bothSides) != 0
        if anySidePresent || !flags.contains(bits.generic) {
            return (flags.rawValue & bits.thisSide) != 0
        }
        // 汎用マスクだけが立っている。左右は不明なので押下とみなす。
        return true
    }
}

/// 修飾キーの仮想キーコードと、左右を区別するデバイス依存ビットの対応。
///
/// 値は `IOKit/hidsystem/IOLLEvent.h` の `NX_DEVICE*KEYMASK` に一致する。
enum ModifierSide {

    struct Bits {
        /// この仮想キーコード自身の側のビット。
        let thisSide: UInt64
        /// 同じ汎用マスクを共有する左右両方のビット。
        let bothSides: UInt64
        /// 左右を区別しない汎用マスク。
        let generic: CGEventFlags
    }

    private static let leftControl: UInt64 = 0x0000_0001
    private static let leftShift: UInt64 = 0x0000_0002
    private static let rightShift: UInt64 = 0x0000_0004
    private static let leftCommand: UInt64 = 0x0000_0008
    private static let rightCommand: UInt64 = 0x0000_0010
    private static let leftOption: UInt64 = 0x0000_0020
    private static let rightOption: UInt64 = 0x0000_0040
    private static let rightControl: UInt64 = 0x0000_2000

    static func bits(forKeyCode keyCode: Int64) -> Bits? {
        switch keyCode {
        case 0x3A:  // 左 Option
            Bits(thisSide: leftOption, bothSides: leftOption | rightOption, generic: .maskAlternate)
        case 0x3D:  // 右 Option
            Bits(thisSide: rightOption, bothSides: leftOption | rightOption, generic: .maskAlternate)
        case 0x38:  // 左 Shift
            Bits(thisSide: leftShift, bothSides: leftShift | rightShift, generic: .maskShift)
        case 0x3C:  // 右 Shift
            Bits(thisSide: rightShift, bothSides: leftShift | rightShift, generic: .maskShift)
        case 0x37:  // 左 Command
            Bits(
                thisSide: leftCommand, bothSides: leftCommand | rightCommand,
                generic: .maskCommand)
        case 0x36:  // 右 Command
            Bits(
                thisSide: rightCommand, bothSides: leftCommand | rightCommand,
                generic: .maskCommand)
        case 0x3B:  // 左 Control
            Bits(
                thisSide: leftControl, bothSides: leftControl | rightControl,
                generic: .maskControl)
        case 0x3E:  // 右 Control
            Bits(
                thisSide: rightControl, bothSides: leftControl | rightControl,
                generic: .maskControl)
        default:
            nil
        }
    }
}

extension HotkeyBinding.Modifiers {
    var cgEventFlags: CGEventFlags {
        var flags = CGEventFlags()
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.shift) { flags.insert(.maskShift) }
        return flags
    }
}

/// テスト用。任意のタイミングでイベントを流せる。
public final class StubHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    public let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    public init() {
        (events, continuation) = AsyncStream<HotkeyEvent>.makeStream()
    }

    public func start() throws {}
    public func stop() { continuation.finish() }
    public func emit(_ event: HotkeyEvent) { continuation.yield(event) }
}

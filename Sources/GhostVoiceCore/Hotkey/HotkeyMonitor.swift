import CoreGraphics
import Foundation

public enum HotkeyEvent: Sendable, Equatable {
    case pressed
    case released
    /// **利用者が中断を要求した**（ESC）。「これを挿入するな」という意図である。
    case cancelled
    /// **取りこぼし。** 監視が死んで PTT キーの解放を受け取れなくなった。
    ///
    /// **`.cancelled` と同じ扱いにしてはならない**（基本設計書 §7 の縮退表）。
    /// 利用者は喋っていたのであって、中断を要求していない。最大録音時間の満了と
    /// まったく同じ状況なので、**中断ではなく確定として扱う**（そこまでの発話を届ける）。
    ///
    /// > 以前はこれも `.cancelled` で運んでいた。**意図と事故が同じ列挙子に相乗りし、
    /// > 「決めないまま捨てる」になっていた**（フェーズ 1 の最終レビュー I-2）。
    case interrupted
    /// **Undo キー（既定 ⌃⌘Z）が押された**（FR-7）。
    ///
    /// **「戻せる」ことの保証ではない。** 監視器はキーが押されたことしか知らない。
    /// 戻せるかを決めるのは**メモリ上に生きている差し替えの錨**であり、それは
    /// `DictationSession` の側にある（要件定義書 FR-7 の細目）。
    /// 戻せない状態で押されたときは、セッションが何もしない。
    case undoRequested
}

public protocol HotkeyMonitor: AnyObject, Sendable {
    var events: AsyncStream<HotkeyEvent> { get }
    func start() throws
    func stop()

    /// いま監視している PTT のバインド。
    ///
    /// **`Settings.hotkey` の写しではない。** 設定を保存しても `rebind(to:)` を
    /// 呼ぶまで監視器は古いキーを見ている。設定画面は 2 つが食い違っていないかを
    /// これで確かめられる。
    ///
    /// - Note: MainActor から同期で読んでよい（ロックを取るだけ）。
    var currentBinding: HotkeyBinding { get }

    /// PTT のバインドを差し替える（欠落 9 / 持ち越し項目 10）。
    ///
    /// フェーズ 1 では `binding` が init 固定で、**設定画面で PTT キーを変えても
    /// プロセスを再起動するまで効かなかった。** `stop()` はストリームを終端し
    /// （`AsyncStream` は終端を取り消せない）作り直しには `DictationSession` が
    /// `let` で握っている監視器を差し替える必要があるので、**同じインスタンスの中で
    /// タップだけを張り替える。**
    ///
    /// - Important: **録音中に呼ぶと `.interrupted` が流れる。** 新しいバインドでは
    ///   古いキーの解放が届かないので、放っておくと録音が終わらない
    ///   （持ち越し項目 14 と同じ形の穴になる）。`.cancelled` ではないので、
    ///   そこまでの発話は確定して挿入される（基本設計書 §7 の縮退表）。
    /// - Important: 設定画面は**録音していないとき**に呼ぶこと。上の縮退はあくまで保険である。
    /// - Important: **MainActor から呼んでよい。** ファイル I/O は行わない
    ///   （タップの生成は実測で約 40 ms 掛かるので、設定を変えた瞬間だけに限ること）。
    /// - Throws: `HotkeyError.stopped` — `stop()` 済み。`HotkeyError.alreadyRunning` —
    ///   `start()` の最中。張り替えに失敗した場合は `start()` と同じ失敗
    ///   （`eventTapNotPermitted` / `tapDisabledAtStart`）を投げ、監視器は停止した状態になる。
    func rebind(to binding: HotkeyBinding) throws

    /// セッションが**確定〜整形の処理中**かを知らせる。
    ///
    /// **これが無いと、キーを離した後の ESC が中断として届かない。**
    /// 監視器は「PTT キーを握っている間」しか ESC を中断として扱えず、
    /// 一方で `DictationSession` は確定待ち・整形中の中断を受け付ける
    /// （基本設計書 §4「中断が効くのは recording / finalizing / refining の 3 状態」）。
    /// **2 つが別の量を見ていたため、正本の約束の半分が実装されていなかった**
    /// （フェーズ 1 の最終レビュー I-1）。
    ///
    /// - Important: **この窓では ESC を抑止しない。** キーを離した後の利用者は
    ///   挿入先のアプリを操作しているので、そこで ESC を奪うと下流のアプリが壊れる
    ///   （V-4 の #6「録音していないときの ESC は下流へ届く」の趣旨）。
    ///   中断は届き、かつ ESC も通す。
    func setSessionBusy(_ busy: Bool)

    /// いま監視している Undo のバインド（既定 ⌃⌘Z）。
    ///
    /// - Note: MainActor から同期で読んでよい（ロックを取るだけ）。
    /// - Note: `currentBinding` と同じく **`Settings.undoHotkey` の写しではない。**
    var currentUndoBinding: HotkeyBinding { get }

    /// Undo のバインドを差し替える（FR-11）。
    ///
    /// - Important: **タップは張り替えない。** 監視するイベント種別は PTT のバインドだけで
    ///   決まる（Undo は `keyDown` しか見ないので、既に必ずマスクに入っている）。
    ///   したがって録音中に呼んでも `.interrupted` は起きない。
    /// - Important: **MainActor から呼んでよい。** ロックを取るだけで I/O も AX も無い。
    /// - Throws: `HotkeyError.stopped` — `stop()` 済み。
    func rebindUndo(to binding: HotkeyBinding) throws

    /// **いま Undo で戻せるものがあるか**をセッションが知らせる（FR-7）。
    ///
    /// **これは抑止のためだけにある。** 判定そのものは `DictationSession` が持つ
    /// 錨で行う（監視器は「戻せるか」を知り得ない）。
    ///
    /// - Important: **真の間だけ Undo キーを抑止し、偽の間は下流アプリへ通す。**
    ///   10 秒窓の外では Ghost Voice は何もしないので、そこで打鍵を奪うと
    ///   **下流アプリの Undo / Redo が理由も無く効かなくなる。**
    ///   逆に真の間に通すと、こちらが差し替えを戻すのと同時に**アプリ自身の Undo も
    ///   走って二重に効く。** どちらも利用者から見て壊れているので、
    ///   「戻せるときだけ奪う」以外に正しい選択が無い。
    /// - Important: **hot path から見えるのはこのフラグの読み取りだけである。**
    ///   打鍵ごとの判定コストは実測 p50 0.75 μs で、**これはシステム全体の打鍵に乗る**
    ///   （詳細設計書 §2.5）。ここで問い合わせや計算を行ってはならない。
    func setUndoAvailable(_ available: Bool)

    /// **打鍵の捕獲を始める**（FR-11「ホットキーを設定画面から変更できる」）。
    ///
    /// **2 本目の `CGEventTap` を立てない**ための口である（統括の裁定）。判定は
    /// 1 打鍵あたり p50 0.75 μs で全システムの打鍵に乗るので、2 本目を立てると
    /// **設定画面を開いていない間もずっと 2 倍を払う**ことになる。
    ///
    /// - Important: **捕獲モードの間、PTT も Undo も ESC の中断も発火しない。**
    ///   キーを設定しようとして録音が始まると設定画面は使えないので、これは要件である。
    ///   判定は `HotkeyDecision.decide` を一度も通らない（`HotkeyCaptureState` が先に見る）。
    /// - Important: **録音中に呼ぶと `.interrupted` が流れる。** 捕獲モードでは PTT キーの
    ///   解放が届かないので、放っておくと録音が終わらない（`rebind(to:)` と同じ形の穴）。
    ///   `.cancelled` ではないので、そこまでの発話は確定して挿入される。
    /// - Important: **1 打鍵で終わる。** 決着（`.captured` / `.cancelled`）を配ると
    ///   捕獲モードは自動的に閉じる。**閉じ忘れで打鍵を食い続ける状態を構造で作らない。**
    /// - Important: **`onEvent` はタップのコールバックのスレッドから呼ばれる。**
    ///   MainActor ではない。画面は自分で持ち上げること。
    /// - Note: 二重に呼ぶと**後から呼んだほうが勝つ**（前の handler は捨てられ、
    ///   何も配られない）。捕獲は利用者の 1 操作に紐づくので、待ち行列を作る意味が無い。
    func beginHotkeyCapture(_ onEvent: @escaping @Sendable (HotkeyCaptureOutcome) -> Void)

    /// 捕獲モードを閉じる。**二度呼んでも安全。** 決着は配られない。
    ///
    /// 設定画面が窓を閉じた・キー入力の受付を止めたときに必ず呼ぶこと
    /// （呼ばなくても 1 打鍵で閉じるが、**閉じるまでは PTT が効かない**）。
    func endHotkeyCapture()

    /// いま捕獲モードか。**画面が「キーを押してください」を出しているかと一致させる。**
    var isCapturingHotkey: Bool { get }
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
    /// - Parameter isSessionBusy: セッションが確定〜整形の処理中か（`setSessionBusy`）。
    ///   **録音中でなくても、この間の ESC は中断として扱う。**
    /// - Parameter undoBinding: Undo のバインド（FR-7）。nil なら Undo を見ない。
    /// - Parameter isUndoAvailable: いま戻せるものがあるか（`setUndoAvailable`）。
    ///   **抑止するかどうかだけを決める。** 偽でも `.undoRequested` は流す——
    ///   戻せるかの最終判定はセッションが錨で行うので、フラグを門にすると
    ///   フラグとセッションがずれた瞬間に打鍵が消える。
    ///
    /// - Important: **1 打鍵につきこの関数が 1 回走るだけである**（実測 p50 0.75 μs /
    ///   詳細設計書 §2.5）。Undo のためにタップをもう 1 本立てると、
    ///   **システム全体の打鍵に乗る費用が単純に 2 倍になる。**
    ///   だから判定はこの 1 本の中で行う。
    public static func decide(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        binding: HotkeyBinding,
        isRecording: Bool,
        isSessionBusy: Bool = false,
        undoBinding: HotkeyBinding? = nil,
        isUndoAvailable: Bool = false
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

            // 録音中の ESC は中断として消費する（下流へ渡さない）。
            if isRecording { return (.cancelled, true) }

            // **処理中（キーを離した後）の ESC も中断として届ける。ただし抑止しない。**
            // 利用者はもう挿入先のアプリを触っているので、ESC を奪うと下流が壊れる。
            if isSessionBusy { return (.cancelled, false) }

            return (nil, false)
        }

        // **ESC より後に見る。** Undo を ESC に割り当てた設定では中断を優先する——
        // 中断は「これを挿入するな」であり、取り違えると発話が挿入先へ入ってしまう。
        // 一方 Undo が効かないことの害は「戻せない」だけである。
        if let undoBinding, keyCode == undoBinding.keyCode {
            return undo(type: type, flags: flags, binding: undoBinding, isAvailable: isUndoAvailable)
        }

        return (nil, false)
    }

    /// Undo キーの判定（FR-7）。
    ///
    /// **押下だけを見る。** 解放は見ない——Undo は 1 回の押下で完結する操作であり、
    /// keyUp を見に行くと**修飾キー単独の PTT でもタップのマスクへ `keyUp` を足す**
    /// ことになって、システム全体の打鍵の配送量が倍になる（詳細設計書 §2.1）。
    ///
    /// **抑止は「戻せるときだけ」である**（`HotkeyMonitor.setUndoAvailable` の注記）。
    ///
    /// - Note: **抑止した押下に対応する keyUp は下流アプリへ届く**（マスクに `keyUp` が
    ///   入っていないので抑止しようが無い）。文字キーの単独の keyUp を意味づける
    ///   アプリは稀なので、**タップの配送量を倍にしてまで塞ぐ価値は無い**と判断した。
    ///   実アプリでの影響は未実測（検証項目 V-33）。
    private static func undo(
        type: CGEventType, flags: CGEventFlags, binding: HotkeyBinding, isAvailable: Bool
    ) -> (event: HotkeyEvent?, suppress: Bool) {
        // 修飾キー単独を Undo に割り当てることは `HotkeyBinding` が既に禁じているが、
        // ここでも `flagsChanged` は見ない（押下と解放を区別できないため）。
        guard type == .keyDown else { return (nil, false) }
        // 修飾キーが揃っていなければ、ユーザーはただ文字を打っている。**必ず通す。**
        guard flags.contains(binding.modifiers.cgEventFlags) else { return (nil, false) }
        return (.undoRequested, isAvailable)
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
            isDown = isModifierDown(
                keyCode: binding.keyCode, flags: flags,
                fallback: binding.modifiers.cgEventFlags)

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
    ///   実キーボードがこのビットを立てることは V-4 で確認する
    ///   （**権限を付与した利用者が実施する**。README の手順の #3）。
    ///
    /// - Parameter fallback: デバイスビットを読めなかったときに使う汎用マスク。
    ///   **PTT の判定はバインドの修飾キー、捕獲はそのキー自身の修飾キーを渡す**
    ///   （`HotkeyCaptureState`）。**左右の判定そのものは 1 箇所しか無い**——
    ///   2 箇所に分かれると、片方だけが解放を取りこぼして録音が終わらなくなる。
    static func isModifierDown(
        keyCode: Int64, flags: CGEventFlags, fallback: CGEventFlags
    ) -> Bool {
        // **この退避経路は現在到達しない。** `isModifierOnly` が認める 8 個の
        // キーコードは全て `ModifierSide` の表に載っている（テスト
        // 「修飾キー単独として扱うキーコードは全て左右のビット表にある」がその不変条件）。
        // 表への追加を忘れたときに**落ちずに従来の判定へ落ちる**ための保険として残す。
        // ミューテーションテストではここを潰す変異が生き残る（等価変異）。
        guard let bits = ModifierSide.bits(forKeyCode: keyCode) else {
            return flags.contains(fallback)
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

    /// `CGEventFlags` から修飾キーを読む（捕獲に使う。`HotkeyCaptureState`）。
    ///
    /// **左右は区別しない。** `HotkeyBinding.Modifiers` に左右の区別が無いためで、
    /// 左右を見るのは**修飾キー単独のバインドの押下判定だけ**である
    /// （`HotkeyDecision.isModifierDown`。汎用マスクでは解放を取りこぼす）。
    ///
    /// **`.maskAlphaShift`（Caps Lock）や `.maskSecondaryFn` は落とす。**
    /// `HotkeyBinding.Modifiers` に対応する値が無く、混ぜると
    /// 「Caps Lock が入っている間だけ違うバインドが捕まる」ことになる。
    public init(cgEventFlags flags: CGEventFlags) {
        var result = HotkeyBinding.Modifiers()
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        self = result
    }
}

/// テスト用。任意のタイミングでイベントを流せる。
public final class StubHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    public let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation
    private let lock = NSLock()
    private var busyCalls: [Bool] = []
    private var binding: HotkeyBinding
    private var rebindCalls: [HotkeyBinding] = []
    private var isStopped = false
    private var undoBinding: HotkeyBinding
    private var undoRebindCalls: [HotkeyBinding] = []
    private var undoAvailableCalls: [Bool] = []
    private var captureHandler: (@Sendable (HotkeyCaptureOutcome) -> Void)?
    private var captureState = HotkeyCaptureState()
    private var captureBegins = 0
    private var captureEnds = 0
    /// **`feedPushToTalkAttempt` のためだけの録音状態。** 本物の監視器と違い、
    /// この代役は `emit(_:)` で任意のイベントを流せるので普段は状態を持たない。
    private var isRecordingForCapture = false

    public init(
        binding: HotkeyBinding = .rightOption,
        undoBinding: HotkeyBinding = .controlCommandZ
    ) {
        self.binding = binding
        self.undoBinding = undoBinding
        (events, continuation) = AsyncStream<HotkeyEvent>.makeStream()
    }

    public func start() throws {}
    public func stop() {
        lock.withLock { isStopped = true }
        continuation.finish()
    }
    public func emit(_ event: HotkeyEvent) { continuation.yield(event) }

    public var currentBinding: HotkeyBinding { lock.withLock { binding } }

    /// `rebind` の呼ばれ方。**設定画面が監視器へ反映したか**を見る。
    public var rebindings: [HotkeyBinding] { lock.withLock { rebindCalls } }

    public func rebind(to newBinding: HotkeyBinding) throws {
        try lock.withLock {
            guard !isStopped else { throw HotkeyError.stopped }
            binding = newBinding
            rebindCalls.append(newBinding)
        }
    }

    /// `setSessionBusy` の呼ばれ方。**セッションが処理中を知らせているか**を見る。
    public var sessionBusyCalls: [Bool] { lock.withLock { busyCalls } }
    public var isSessionBusy: Bool { lock.withLock { busyCalls.last ?? false } }

    public func setSessionBusy(_ busy: Bool) {
        lock.withLock { busyCalls.append(busy) }
    }

    public var currentUndoBinding: HotkeyBinding { lock.withLock { undoBinding } }

    /// `rebindUndo` の呼ばれ方。
    public var undoRebindings: [HotkeyBinding] { lock.withLock { undoRebindCalls } }

    public func rebindUndo(to newBinding: HotkeyBinding) throws {
        try lock.withLock {
            guard !isStopped else { throw HotkeyError.stopped }
            undoBinding = newBinding
            undoRebindCalls.append(newBinding)
        }
    }

    /// `setUndoAvailable` の呼ばれ方。**「戻せる窓」が開いて閉じたかを見る。**
    public var undoAvailabilityCalls: [Bool] { lock.withLock { undoAvailableCalls } }
    public var isUndoAvailable: Bool { lock.withLock { undoAvailableCalls.last ?? false } }

    public func setUndoAvailable(_ available: Bool) {
        lock.withLock { undoAvailableCalls.append(available) }
    }

    // MARK: - 捕獲モード

    /// 捕獲モードへ入った回数と抜けた回数。**画面が閉じ忘れていないかを見る。**
    public var captureBeginCount: Int { lock.withLock { captureBegins } }
    public var captureEndCount: Int { lock.withLock { captureEnds } }

    public var isCapturingHotkey: Bool { lock.withLock { captureHandler != nil } }

    public func beginHotkeyCapture(_ onEvent: @escaping @Sendable (HotkeyCaptureOutcome) -> Void) {
        let wasRecording: Bool = lock.withLock {
            captureHandler = onEvent
            captureState = HotkeyCaptureState()
            captureBegins += 1
            let recording = isRecordingForCapture
            isRecordingForCapture = false
            return recording
        }
        // **本物と同じ縮退を持つ**（捕獲中は PTT キーの解放が届かない）。
        if wasRecording { continuation.yield(.interrupted) }
    }

    public func endHotkeyCapture() {
        lock.withLock {
            guard captureHandler != nil else { return }
            captureHandler = nil
            captureState = HotkeyCaptureState()
            captureEnds += 1
        }
    }

    /// 検査から打鍵を流し込む。**本物と同じ `HotkeyCaptureState` を通す。**
    ///
    /// - Returns: 抑止したか（本物のタップなら下流へ渡さない）。
    @discardableResult
    public func feedCapture(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        let (outcome, suppress, handler): (
            HotkeyCaptureOutcome, Bool, (@Sendable (HotkeyCaptureOutcome) -> Void)?
        ) = lock.withLock {
            guard captureHandler != nil else { return (.pending, false, nil) }
            let result = captureState.consume(type: type, keyCode: keyCode, flags: flags)
            switch result.outcome {
            case .pending:
                return (result.outcome, result.suppress, nil)
            case .captured, .cancelled:
                let handler = captureHandler
                captureHandler = nil
                captureState = HotkeyCaptureState()
                captureEnds += 1
                return (result.outcome, result.suppress, handler)
            }
        }
        if case .pending = outcome {} else { handler?(outcome) }
        return suppress
    }

    /// 捕獲モード中に PTT を発火させようとする（**発火してはならない**）。
    ///
    /// 本物の `handle` と同じ順序（捕獲モードを先に見る）を素通しで再現する。
    public func feedPushToTalkAttempt(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        if isCapturingHotkey {
            feedCapture(type: type, keyCode: keyCode, flags: flags)
            return
        }
        let decision = HotkeyDecision.decide(
            type: type, keyCode: keyCode, flags: flags,
            binding: currentBinding, isRecording: lock.withLock { isRecordingForCapture },
            undoBinding: currentUndoBinding)
        if let event = decision.event {
            lock.withLock {
                switch event {
                case .pressed: isRecordingForCapture = true
                case .released, .cancelled, .interrupted: isRecordingForCapture = false
                case .undoRequested: break
                }
            }
            continuation.yield(event)
        }
    }
}

import Testing
import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization
@testable import GhostVoiceCore

// MARK: - テスト用の道具

/// 仮想キーコードと修飾フラグを持つ `CGEvent` を合成する。
///
/// **合成は権限を要さない**（Task 8 の実測。本タスクでも再確認した）。
/// これによりタップを開けない機体でも `handle` の本物のコードパス
/// ——`CGEvent` からのキーコード抽出、フラグの読み取り、状態遷移、抑止の返し方——
/// をそのまま検査できる。
private func makeEvent(keyCode: Int64, flags: CGEventFlags) -> CGEvent {
    // 0x3D のような修飾キーを渡すと OS 側が flagsChanged 型の event を返す。
    // 型は `handle` へ別途渡すので、ここでは器として使うだけでよい。
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0x00, keyDown: true)!
    event.setIntegerValueField(.keyboardEventKeycode, value: keyCode)
    event.flags = flags
    return event
}

/// IOLLEvent.h の device-dependent 修飾ビット。左右の Option 等はこれでしか区別できない。
private enum DeviceBit {
    static let leftOption: UInt64 = 0x0000_0020   // NX_DEVICELALTKEYMASK
    static let rightOption: UInt64 = 0x0000_0040  // NX_DEVICERALTKEYMASK
    static let leftShift: UInt64 = 0x0000_0002    // NX_DEVICELSHIFTKEYMASK
}

/// 汎用マスクにデバイスビットを重ねたフラグ。
private func optionFlags(_ deviceBits: UInt64) -> CGEventFlags {
    CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | deviceBits)
}

/// `stream` から最大 `count` 件を期限付きで集める。**期限を切らないと停止になる。**
private func collect(
    _ stream: AsyncStream<HotkeyEvent>, count: Int, timeout: Duration = .seconds(3)
) async -> [HotkeyEvent] {
    await withTaskGroup(of: [HotkeyEvent]?.self, returning: [HotkeyEvent].self) { group in
        group.addTask {
            var collected: [HotkeyEvent] = []
            for await event in stream {
                collected.append(event)
                if collected.count >= count { break }
            }
            return collected
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
    }
}

/// ストリームが**終端するまで**読む。終端したかどうかも返す。
///
/// **「件数が期待どおり」だけを見ると、終端し忘れの不具合を取り逃がす。**
/// 期限切れで諦めた結果と、正しく終端した結果が同じ配列になるため
/// （実際にミューテーションで `continuation.finish()` を消した変異が生き残った）。
private struct Drained {
    var events: [HotkeyEvent] = []
    var finished = false
}

private func drain(
    _ stream: AsyncStream<HotkeyEvent>, timeout: Duration = .seconds(3)
) async -> Drained {
    await withTaskGroup(of: Drained?.self, returning: Drained.self) { group in
        group.addTask {
            var result = Drained()
            for await event in stream { result.events.append(event) }
            result.finished = true
            return result
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? Drained()
    }
}

/// 呼ばれた回数を数える権限照会。**キー判定の hot path から呼ばれていないこと**の検査に使う。
private final class CountingProbe: Sendable {
    private let count = Atomic<Int>(0)
    private let value: Bool

    init(returning value: Bool) { self.value = value }

    var callCount: Int { count.load(ordering: .relaxed) }

    var probe: @Sendable () -> Bool {
        { [self] in
            count.add(1, ordering: .relaxed)
            return value
        }
    }
}

/// 権限が無くても **OS が本物の「無効なタップ」を返してくれる**唯一の経路。
///
/// `.listenOnly` は権限が無くても非 nil の `CFMachPort` を返すが、そのタップは
/// 恒久的に無効である（実測。`CGEvent.tapEnable(enable: true)` でも有効にならない）。
/// 偽物を作らずに「生成できたのに無効」の分岐を検査できる。
/// `CFMachPort` は `Sendable` ではないが、`EventTapControlling` は `Sendable` である。
/// 差し替えのために持ち込むだけなので、不検査の合意をここへ一度だけ置く。
private struct TapBox: @unchecked Sendable { let port: CFMachPort }

private func makeRealButDisabledTap() -> CFMachPort? {
    CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
        callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
        userInfo: nil
    )
}

/// タップではないが**実在する** `CFMachPort`。
/// 起動の成功経路には、ランループソースを作れる本物のポートが要る。
private func makePlainPort() -> CFMachPort? {
    var context = CFMachPortContext()
    return CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, &context, nil)
}

/// **この機体はタップを有効化できるか（＝キーイベント監視の権限があるか）。**
///
/// `CGEvent.h` は「Taps are normally enabled when created.」と定めており、
/// **「生成できたのに無効」は権限が無いことの副作用であって OS の仕様ではない。**
/// 権限のある機体では `.listenOnly` のタップが生成直後から有効になるため、
/// その状況を本物で作れない。作れるかどうかをここで判定する。
private func canOpenEnabledTap() -> Bool {
    guard let tap = makeRealButDisabledTap() else { return false }
    defer { CFMachPortInvalidate(tap) }
    return CGEvent.tapIsEnabled(tap: tap)
}

/// テスト用のランループ。**プロセス共有のメインランループを触らない。**
///
/// 起動の成功経路は `CFRunLoopAddSource` でランループを書き換える。メインの
/// ランループへ入れると、並列に走る他スイートと共有の資源を奪い合うことになる。
///
/// - Important: **`CFRunLoopGetCurrent()` を使ってはならない。** テストは協調
///   スレッドプール上で走るため、**スレッドが消えるとそのランループも消える。**
///   あとから `deinit` 経由で `CFRunLoopRemoveSource` すると落ちる
///   （ミューテーションテストで実際に SIGSEGV を踏んで気付いた）。
///   専用スレッドを 1 本立てて、プロセスの間ずっと生かしておく。
///   ランループを回す必要は無い。source の出し入れは停止中のランループでも安全である。
/// 立てたスレッドから受け取るための受け皿。
///
/// **`UnsafeMutablePointer` を `Thread` のクロージャへ渡してはならない。**
/// ポインタは非 Sendable なので `swift test` の出力に警告が残り続ける
/// （それ自体が壊れるわけではないが、警告に慣れると本物の警告を見落とす）。
/// 受け渡しは参照型 + ロックで行う。
private final class RunLoopBox: @unchecked Sendable {
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    func set(_ loop: CFRunLoop) { lock.withLock { runLoop = loop } }
    var value: CFRunLoop? { lock.withLock { runLoop } }
}

private nonisolated(unsafe) let sharedTestRunLoop: CFRunLoop = {
    let ready = DispatchSemaphore(value: 0)
    let box = RunLoopBox()

    let thread = Thread {
        box.set(CFRunLoopGetCurrent())
        ready.signal()
        // このスレッドが生きている限り、上のランループは有効なまま残る。
        while true { Thread.sleep(forTimeInterval: 3600) }
    }
    thread.name = "GhostVoiceTests.HotkeyRunLoop"
    thread.start()
    ready.wait()
    return box.value!
}()

private func testRunLoop() -> CFRunLoop { sharedTestRunLoop }

/// 生成だけを差し替え、有効化の可否は**本物の CoreGraphics に委ねる**。
/// 「OS が有効化を拒む」挙動を偽物で作らずに検査するために使う。
private struct FixedPortTapController: EventTapControlling {
    let port: TapBox?

    func create(
        mask: CGEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?
    ) -> CFMachPort? { port?.port }

    func setEnabled(_ tap: CFMachPort, _ enabled: Bool) {
        CGEvent.tapEnable(tap: tap, enable: enabled)
    }

    func isEnabled(_ tap: CFMachPort) -> Bool { CGEvent.tapIsEnabled(tap: tap) }
}

/// タップの生成と有効化を模す。
///
/// `isEnabled` は**最後に `setEnabled` へ渡された値を返す**（`canEnable` が false なら
/// 決して有効にならない）。実物と同じ因果にしてあるので、
/// 「有効化し忘れ」「false で有効化」といった変異がそのまま起動の失敗として現れる。
private final class StubEventTapController: EventTapControlling, @unchecked Sendable {
    private let port: CFMachPort?
    private let canEnable: Bool
    private let lock = NSLock()
    private var enabled = false
    private var calls: [Bool] = []
    private var creations = 0

    init(port: CFMachPort?, canEnable: Bool = true) {
        self.port = port
        self.canEnable = canEnable
    }

    var enableCalls: [Bool] { lock.withLock { calls } }
    var createCount: Int { lock.withLock { creations } }

    func create(
        mask: CGEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?
    ) -> CFMachPort? {
        lock.withLock { creations += 1 }
        return port
    }

    func setEnabled(_ tap: CFMachPort, _ enabled: Bool) {
        lock.withLock {
            calls.append(enabled)
            self.enabled = enabled && canEnable
        }
    }

    func isEnabled(_ tap: CFMachPort) -> Bool { lock.withLock { enabled } }
}

/// タップを開けない機体を模す（`create` が nil を返す）。
private func deniedController() -> StubEventTapController {
    StubEventTapController(port: nil)
}

/// `create` の**最中に**割り込みを走らせる差し替え。
///
/// 本物の `tapCreate` は実測で約 40 ms 掛かる。その窓で `stop()` が走る競合を
/// 偶然に頼らず再現するために、`create` の中から任意の処理を呼べるようにする。
private final class InterruptingTapController: EventTapControlling, @unchecked Sendable {
    private let port: CFMachPort?
    private let lock = NSLock()
    private var duringCreate: (@Sendable () -> Void)?
    private var calls: [Bool] = []

    init(port: CFMachPort?) { self.port = port }

    var enableCalls: [Bool] { lock.withLock { calls } }

    /// `create` の中で一度だけ呼ばれる処理を仕込む。
    func interrupt(with body: @escaping @Sendable () -> Void) {
        lock.withLock { duringCreate = body }
    }

    func create(
        mask: CGEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?
    ) -> CFMachPort? {
        let body = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { duringCreate = nil }
            return duringCreate
        }
        body?()
        return port
    }

    func setEnabled(_ tap: CFMachPort, _ enabled: Bool) {
        lock.withLock { calls.append(enabled) }
    }

    /// 有効化には常に成功したことにする（競合の検査に集中する）。
    func isEnabled(_ tap: CFMachPort) -> Bool { true }
}

// MARK: - 判定ロジック（権限不要）

@Suite("HotkeyDecision")
struct HotkeyDecisionTests {

    private let ptt = HotkeyBinding.rightOption

    @Test("右 Option を押すと pressed になる")
    func rightOptionDown() {
        let (event, suppress) = HotkeyDecision.decide(
            type: .flagsChanged, keyCode: 0x3D,
            flags: optionFlags(DeviceBit.rightOption), binding: ptt, isRecording: false
        )
        #expect(event == .pressed)
        // 修飾キーは抑止しない。抑止すると下流アプリが修飾状態を見失う。
        #expect(!suppress)
    }

    @Test("右 Option を離すと released になる")
    func rightOptionUp() {
        let (event, suppress) = HotkeyDecision.decide(
            type: .flagsChanged, keyCode: 0x3D, flags: [], binding: ptt, isRecording: true
        )
        #expect(event == .released)
        #expect(!suppress)
    }

    @Test("左 Option には反応しない")
    func ignoresLeftOption() {
        let (event, _) = HotkeyDecision.decide(
            type: .flagsChanged, keyCode: 0x3A,
            flags: optionFlags(DeviceBit.leftOption), binding: ptt, isRecording: false
        )
        #expect(event == nil)
    }

    @Test("録音中の ESC は cancelled になり、抑止される")
    func escapeCancelsAndIsSuppressed() {
        let (event, suppress) = HotkeyDecision.decide(
            type: .keyDown, keyCode: 0x35, flags: [], binding: ptt, isRecording: true
        )
        #expect(event == .cancelled)
        // 中断操作を挿入先アプリへ漏らさない
        #expect(suppress)
    }

    @Test("録音していないときの ESC は素通しする")
    func escapePassesThroughWhenIdle() {
        let (event, suppress) = HotkeyDecision.decide(
            type: .keyDown, keyCode: 0x35, flags: [], binding: ptt, isRecording: false
        )
        #expect(event == nil)
        #expect(!suppress)
    }

    @Test("録音中に同じ押下が重複して届いても pressed を二度出さない")
    func noDuplicatePressed() {
        let (event, _) = HotkeyDecision.decide(
            type: .flagsChanged, keyCode: 0x3D,
            flags: optionFlags(DeviceBit.rightOption), binding: ptt, isRecording: true
        )
        #expect(event == nil)
    }

    /// ESC の `keyUp` まで抑止すると、挿入先アプリは keyDown 無しの keyUp すら
    /// 受け取れなくなる。抑止するのは `keyDown` だけである。
    @Test("録音中でも ESC の keyUp は抑止しない")
    func escapeKeyUpIsNotSuppressed() {
        let (event, suppress) = HotkeyDecision.decide(
            type: .keyUp, keyCode: 0x35, flags: [], binding: ptt, isRecording: true
        )
        #expect(event == nil)
        #expect(!suppress)
    }

    /// 修飾キーの `flagsChanged` は**どの状態でも**抑止してはならない。
    /// 一箇所でも抑止すると ⌥ + 矢印などが壊れる。
    @Test(
        "右 Option の flagsChanged は決して抑止されない",
        arguments: [
            (optionFlags(DeviceBit.rightOption), false),
            (optionFlags(DeviceBit.rightOption), true),
            (CGEventFlags(), false),
            (CGEventFlags(), true),
            (optionFlags(DeviceBit.leftOption | DeviceBit.rightOption), true),
        ]
    )
    func modifierIsNeverSuppressed(flags: CGEventFlags, isRecording: Bool) {
        let (_, suppress) = HotkeyDecision.decide(
            type: .flagsChanged, keyCode: 0x3D,
            flags: flags, binding: HotkeyBinding.rightOption, isRecording: isRecording
        )
        #expect(!suppress)
    }

    /// **無関係なキーを 1 つでも抑止すると、ユーザーは文字を打てなくなる。**
    /// タップは全アプリの手前に居るので、被害はこのアプリに留まらない。
    /// A / Z / Space / Return / 矢印を、録音中と非録音中の両方で確かめる。
    @Test(
        "PTT でも ESC でもないキーは決して抑止しない",
        arguments: [0x00, 0x06, 0x31, 0x24, 0x7B, 0x35 + 1] as [Int64], [false, true]
    )
    func unrelatedKeysArePassedThrough(keyCode: Int64, isRecording: Bool) {
        for type in [CGEventType.keyDown, .keyUp] {
            let (event, suppress) = HotkeyDecision.decide(
                type: type, keyCode: keyCode, flags: [],
                binding: HotkeyBinding.rightOption, isRecording: isRecording
            )
            #expect(!suppress, "keyCode 0x\(String(keyCode, radix: 16)) を抑止している")
            #expect(event == nil)
        }
    }

    /// 修飾キーのバインドは `flagsChanged` だけで判定する。
    /// キーボードの入れ替えや合成イベントで同じキーコードの keyDown が届いても、
    /// そこから録音を始めてはならない（解放は flagsChanged でしか来ないため、
    /// 始めてしまうと終われなくなる）。
    @Test("修飾キーのバインドは keyDown / keyUp では反応しない", arguments: [
        CGEventType.keyDown, CGEventType.keyUp,
    ])
    func modifierBindingIgnoresKeyDownAndUp(type: CGEventType) {
        let (event, suppress) = HotkeyDecision.decide(
            type: type, keyCode: 0x3D, flags: optionFlags(DeviceBit.rightOption),
            binding: HotkeyBinding.rightOption, isRecording: false
        )
        #expect(event == nil)
        #expect(!suppress)
    }
}

// MARK: - 左右の修飾キーの区別（権限不要）

@Suite("HotkeyDecision の左右修飾キーの区別")
struct HotkeyDecisionSidednessTests {

    private let ptt = HotkeyBinding.rightOption

    /// **左 Option を押したまま右 Option を離すと、`.maskAlternate` は立ったままになる。**
    /// 汎用マスクだけで判定すると解放を取りこぼし、録音が終わらなくなる。
    /// 左右はデバイス依存ビットでしか区別できない。
    @Test("左 Option を押したまま右 Option を離すと released になる")
    func releaseDetectedWhileOtherOptionHeld() {
        let (event, _) = HotkeyDecision.decide(
            type: .flagsChanged, keyCode: 0x3D,
            flags: optionFlags(DeviceBit.leftOption),  // 左だけが残っている
            binding: ptt, isRecording: true
        )
        #expect(event == .released)
    }

    /// 逆向き。左 Option を押しっぱなしのまま右 Option を押したら録音は始まる。
    @Test("左 Option を押したまま右 Option を押すと pressed になる")
    func pressDetectedWhileOtherOptionHeld() {
        let (event, _) = HotkeyDecision.decide(
            type: .flagsChanged, keyCode: 0x3D,
            flags: optionFlags(DeviceBit.leftOption | DeviceBit.rightOption),
            binding: ptt, isRecording: false
        )
        #expect(event == .pressed)
    }

    /// **デバイスビットを報告しない入力源への保険。** 汎用マスクだけが立っている
    /// （左右いずれのビットも無い）ときは、従来どおり汎用マスクで押下とみなす。
    /// ここで解放と誤判定すると、そういう機体では PTT が即座に切れる。
    @Test("デバイスビットが無い入力源では汎用マスクで押下とみなす")
    func fallsBackToGenericMaskWhenDeviceBitsAbsent() {
        let (event, _) = HotkeyDecision.decide(
            type: .flagsChanged, keyCode: 0x3D,
            flags: .maskAlternate,  // デバイスビット無し
            binding: ptt, isRecording: true
        )
        #expect(event == nil, "押下が続いているとみなすべき")

        let (pressEvent, _) = HotkeyDecision.decide(
            type: .flagsChanged, keyCode: 0x3D,
            flags: .maskAlternate, binding: ptt, isRecording: false
        )
        #expect(pressEvent == .pressed)
    }

    /// 他の修飾キーのデバイスビットが立っていても、Option の判定は揺らがない。
    @Test("無関係な修飾キーのデバイスビットに引きずられない")
    func unrelatedDeviceBitsDoNotLeak() {
        let flags = CGEventFlags(
            rawValue: CGEventFlags.maskShift.rawValue | DeviceBit.leftShift
        )
        let (event, _) = HotkeyDecision.decide(
            type: .flagsChanged, keyCode: 0x3D, flags: flags, binding: ptt, isRecording: true
        )
        #expect(event == .released, "Option は全て離れている")
    }

    /// **`isModifierOnly` が認める修飾キーは、全て左右のビット表に載っていること。**
    ///
    /// 片方だけに足すと、表に無い修飾キーは汎用マスクでしか判定できず、
    /// 左右を取り違えて解放を取りこぼす。2 つの表が別々に育つのを防ぐ。
    /// この不変条件が成り立つ限り、`isModifierDown` の表引き失敗の分岐へは到達しない。
    @Test("修飾キー単独として扱うキーコードは全て左右のビット表にある")
    func everyModifierOnlyKeyCodeHasDeviceBits() {
        // `HotkeyBinding.isModifierOnly` が真になるキーコードを総当たりで拾う。
        let modifierKeyCodes = (Int64(0)...0x7F).filter {
            HotkeyBinding(keyCode: $0, modifiers: []).isModifierOnly
        }
        #expect(modifierKeyCodes.count == 8, "修飾キーの一覧が変わった: \(modifierKeyCodes)")

        for keyCode in modifierKeyCodes {
            #expect(
                ModifierSide.bits(forKeyCode: keyCode) != nil,
                "keyCode 0x\(String(keyCode, radix: 16)) が左右のビット表に無い"
            )
        }
    }

    /// 表に載っている左右のビットが、実際に相手と重ならないこと。
    /// 左右で同じビットを書くと、両方押しの判定が壊れる。
    @Test("左右のビットは互いに素で、両側の和に含まれる")
    func deviceBitsAreDisjoint() throws {
        let pairs: [(Int64, Int64)] = [(0x3A, 0x3D), (0x38, 0x3C), (0x37, 0x36), (0x3B, 0x3E)]
        for (left, right) in pairs {
            // **`!` で剥がすとテストの失敗ではなくプロセスの異常終了になる。**
            // 実行中の他のテストまで道連れにするので `#require` を使う。
            let l = try #require(ModifierSide.bits(forKeyCode: left))
            let r = try #require(ModifierSide.bits(forKeyCode: right))
            #expect(l.thisSide != r.thisSide, "0x\(String(left, radix: 16)) と左右が同じビット")
            #expect(l.bothSides == r.bothSides)
            #expect(l.bothSides == (l.thisSide | r.thisSide))
            #expect(l.generic == r.generic)
        }
    }
}

// MARK: - 修飾キー以外のバインド（権限不要）

@Suite("HotkeyDecision の非修飾キーのバインド")
struct HotkeyDecisionNonModifierTests {

    /// `Settings.hotkey` は任意の `HotkeyBinding` を取れる。修飾キー以外を PTT に
    /// 割り当てた場合、`flagsChanged` は飛んで来ないので keyDown / keyUp で判定する。
    private let ptt = HotkeyBinding(keyCode: 0x06, modifiers: [.control, .command])  // ⌃⌘Z

    @Test("⌃⌘Z の keyDown で pressed になる")
    func nonModifierKeyDown() {
        let (event, _) = HotkeyDecision.decide(
            type: .keyDown, keyCode: 0x06,
            flags: [.maskControl, .maskCommand], binding: ptt, isRecording: false
        )
        #expect(event == .pressed)
    }

    /// **これが無いと録音が永遠に終わらない。** 修飾キー以外は離しても
    /// `flagsChanged` を出さないので、`keyUp` を見なければ解放を検出できない。
    @Test("⌃⌘Z の keyUp で released になる")
    func nonModifierKeyUp() {
        let (event, _) = HotkeyDecision.decide(
            type: .keyUp, keyCode: 0x06,
            flags: [.maskControl, .maskCommand], binding: ptt, isRecording: true
        )
        #expect(event == .released)
    }

    /// 修飾キーを先に離してから文字キーを離す操作は普通に起きる。
    /// 解放の判定で修飾キーの一致を要求すると、ここで取りこぼす。
    @Test("修飾キーを先に離してから keyUp が来ても released になる")
    func nonModifierKeyUpAfterModifiersReleased() {
        let (event, _) = HotkeyDecision.decide(
            type: .keyUp, keyCode: 0x06, flags: [], binding: ptt, isRecording: true
        )
        #expect(event == .released)
    }

    /// 修飾キーが揃っていない単独の Z で録音が始まってはいけない。
    @Test("修飾キーが揃っていない keyDown では pressed にならない")
    func nonModifierRequiresModifiers() {
        let (event, _) = HotkeyDecision.decide(
            type: .keyDown, keyCode: 0x06, flags: [], binding: ptt, isRecording: false
        )
        #expect(event == nil)
    }

    /// **修飾キーが一つでも欠けていたら録音を始めてはならない。**
    /// ⌘Z（Undo）や ⌃Z（中断）で録音が始まると、ユーザーは何が起きたか判らない。
    @Test("必要な修飾キーが一部しか押されていなければ pressed にならない", arguments: [
        CGEventFlags.maskControl,
        CGEventFlags.maskCommand,
        CGEventFlags([.maskCommand, .maskShift]),
        CGEventFlags.maskAlternate,
    ])
    func nonModifierRequiresAllModifiers(flags: CGEventFlags) {
        let (event, _) = HotkeyDecision.decide(
            type: .keyDown, keyCode: 0x06, flags: flags, binding: ptt, isRecording: false
        )
        #expect(event == nil, "\(flags.rawValue) で録音が始まった")
    }

    /// `Modifiers` → `CGEventFlags` の対応は 4 種すべてが要る。
    /// 1 つでも落とすと、その修飾キーを含むバインドが押されていなくても成立する。
    @Test("option / shift のバインドでも修飾キーの一致を要求する")
    func optionShiftBindingRequiresBothModifiers() {
        let binding = HotkeyBinding(keyCode: 0x06, modifiers: [.option, .shift])

        let (pressed, _) = HotkeyDecision.decide(
            type: .keyDown, keyCode: 0x06, flags: [.maskAlternate, .maskShift],
            binding: binding, isRecording: false
        )
        #expect(pressed == .pressed)

        for partial in [CGEventFlags.maskAlternate, .maskShift, []] {
            let (event, _) = HotkeyDecision.decide(
                type: .keyDown, keyCode: 0x06, flags: partial,
                binding: binding, isRecording: false
            )
            #expect(event == nil, "\(partial.rawValue) で録音が始まった")
        }
    }

    /// **PTT に割り当てた打鍵は挿入先アプリへ渡さない。**
    /// 既定の Undo と同じ ⌃⌘Z を PTT にしたユーザーが、喋るたびに
    /// 挿入先アプリで Undo / Redo を走らせることになる。
    @Test("PTT の打鍵は抑止する（押下・キーリピート・解放）")
    func nonModifierPttKeystrokesAreSuppressed() {
        let modifiers: CGEventFlags = [.maskControl, .maskCommand]

        let (pressed, downSuppress) = HotkeyDecision.decide(
            type: .keyDown, keyCode: 0x06, flags: modifiers, binding: ptt, isRecording: false
        )
        #expect(pressed == .pressed)
        #expect(downSuppress, "PTT の押下が挿入先アプリへ漏れている")

        let (_, repeatSuppress) = HotkeyDecision.decide(
            type: .keyDown, keyCode: 0x06, flags: modifiers, binding: ptt, isRecording: true
        )
        #expect(repeatSuppress, "キーリピートが挿入先アプリへ漏れている")

        let (released, upSuppress) = HotkeyDecision.decide(
            type: .keyUp, keyCode: 0x06, flags: modifiers, binding: ptt, isRecording: true
        )
        #expect(released == .released)
        #expect(upSuppress, "PTT の解放が挿入先アプリへ漏れている")
    }

    /// **抑止するのは PTT として消費した打鍵だけ。**
    /// 修飾キーが揃っていない打鍵はユーザーが普通に文字を打っているので、
    /// 抑止すると**そのキーが打てなくなる。**
    @Test("修飾キーが揃っていない打鍵は抑止しない")
    func plainKeystrokeIsNotSuppressed() {
        let (_, downSuppress) = HotkeyDecision.decide(
            type: .keyDown, keyCode: 0x06, flags: [], binding: ptt, isRecording: false
        )
        #expect(!downSuppress, "ただの Z が打てなくなっている")

        // 押下を通したのに keyUp だけ消すと、下流アプリのキー状態が狂う。
        let (_, upSuppress) = HotkeyDecision.decide(
            type: .keyUp, keyCode: 0x06, flags: [], binding: ptt, isRecording: false
        )
        #expect(!upSuppress)
    }

    /// 押しっぱなしのキーリピートで pressed を撒き散らさない。
    @Test("キーリピートの keyDown では pressed を二度出さない")
    func nonModifierRepeatDoesNotRepress() {
        let (event, _) = HotkeyDecision.decide(
            type: .keyDown, keyCode: 0x06,
            flags: [.maskControl, .maskCommand], binding: ptt, isRecording: true
        )
        #expect(event == nil)
    }
}

// MARK: - StubHotkeyMonitor

@Suite("StubHotkeyMonitor")
struct StubHotkeyMonitorTests {

    @Test("emit したイベントが events に流れる")
    func emitsEvents() async throws {
        let monitor = StubHotkeyMonitor()
        try monitor.start()
        monitor.emit(.pressed)
        monitor.emit(.released)

        let events = await collect(monitor.events, count: 2)
        #expect(events == [.pressed, .released])
    }

    @Test("stop でストリームが終わる")
    func stopFinishesStream() async throws {
        let monitor = StubHotkeyMonitor()
        try monitor.start()
        monitor.emit(.pressed)
        monitor.stop()

        let drained = await drain(monitor.events)
        #expect(drained.finished, "stop したのにストリームが終端していない")
        #expect(drained.events == [.pressed])
    }
}

// MARK: - CGEventTapHotkeyMonitor（権限が無くても検査できる範囲）

@Suite("CGEventTapHotkeyMonitor の起動", .serialized)
struct CGEventTapHotkeyMonitorStartTests {

    /// タップを開けないとき、**黙って死んだ監視器を返してはならない。**
    @Test("タップを生成できなければ eventTapNotPermitted を投げる")
    func throwsWhenTapCannotBeCreated() {
        let listen = CountingProbe(returning: false)
        let ax = CountingProbe(returning: true)
        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: listen.probe,
            accessibilityProbe: ax.probe,
            tapController: deniedController()
        )

        #expect(throws: HotkeyError.eventTapNotPermitted(
            TapPermissionSnapshot(listenEventAccess: false, accessibilityTrusted: true)
        )) {
            try monitor.start()
        }
        // 失敗の分類のために照会が実際に走ったこと。
        // （hot path で 0 回であることの検査が、数え損ねで自明に通らないための対照でもある）
        #expect(listen.callCount == 1)
        #expect(ax.callCount == 1)
    }

    /// **生成できたことは動くことを意味しない。** `.listenOnly` は権限が無くても
    /// 非 nil を返すが、そのタップは恒久的に無効で 1 件もイベントを配送しない。
    /// ここで弾かないと「start に成功したのにホットキーが効かない」になる。
    ///
    /// **権限のある機体では実行できない。** `CGEvent.h` の
    /// 「Taps are normally enabled when created.」のとおり、権限があれば
    /// `.listenOnly` のタップは生成直後から有効になり、「生成できたのに無効」を
    /// 本物で作れないためである（偽物で作ると OS の挙動を検査したことにならない）。
    /// V-4 を回す機体ではこのテストは skip される。
    @Test(
        "生成できても有効化できないタップは tapDisabledAtStart を投げる",
        .enabled(if: !canOpenEnabledTap(), "権限がある機体では本物の無効なタップを作れない")
    )
    func throwsWhenTapCannotBeEnabled() throws {
        let disabled = try #require(
            makeRealButDisabledTap(), "OS が無効なタップを返さなくなった。前提が変わっている"
        )
        defer { CFMachPortInvalidate(disabled) }
        #expect(!CGEvent.tapIsEnabled(tap: disabled), "このタップは無効であるはず")

        let box = TapBox(port: disabled)
        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: { false },
            accessibilityProbe: { false },
            tapController: FixedPortTapController(port: box),
            runLoop: testRunLoop()
        )
        // 万一 start が成功しても、タップをランループに置き去りにしない。
        defer { monitor.stop() }

        #expect(throws: HotkeyError.tapDisabledAtStart) {
            try monitor.start()
        }
    }

    /// 有効化できなかったタップは、**無効化してから**捨てる。
    /// `stop()` と同じ順（無効化 → invalidate）に揃える。
    @Test("有効化できなかったタップは無効化してから捨てる")
    func failedTapIsDisabledBeforeDiscard() throws {
        let port = try #require(makePlainPort())
        // OS が有効化を拒む機体を模す。
        let controller = StubEventTapController(port: port, canEnable: false)
        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: { false },
            accessibilityProbe: { false },
            tapController: controller,
            runLoop: testRunLoop()
        )
        defer { monitor.stop() }

        #expect(throws: HotkeyError.tapDisabledAtStart) { try monitor.start() }
        #expect(controller.enableCalls == [true, false], "無効化せずに捨てている")
    }

    /// **無効なポートからはランループソースを作れない。**
    /// `CFMachPortCreateRunLoopSource` は `CFRunLoopSource!`（暗黙アンラップ）を返すので、
    /// nil をそのまま `CFRunLoopAddSource` へ流すと**プロセスごと落ちる。**
    /// 常駐アプリのクラッシュは沈黙した失敗より悪い。エラーとして返すこと。
    @Test("ランループソースを作れないポートでも落ちずに投げる")
    func invalidPortThrowsInsteadOfCrashing() throws {
        let port = try #require(makePlainPort())
        CFMachPortInvalidate(port)  // ソースを作れない状態にする

        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: { false },
            accessibilityProbe: { false },
            tapController: StubEventTapController(port: port),
            runLoop: testRunLoop()
        )
        defer { monitor.stop() }

        #expect(throws: HotkeyError.tapDisabledAtStart) { try monitor.start() }
        #expect(!monitor.isActive)
    }

    /// 二重起動はタップを二枚開いて解放を取りこぼす。黙って許してはならない。
    @Test("start を二度呼ぶと alreadyRunning を投げる")
    func doubleStartThrows() throws {
        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: { false },
            accessibilityProbe: { false },
            tapController: deniedController()
        )
        // 失敗した start は「起動済み」にしない。もう一度試せなければ権限付与後に復帰できない。
        #expect(throws: HotkeyError.self) { try monitor.start() }
        #expect(throws: HotkeyError.eventTapNotPermitted(
            TapPermissionSnapshot(listenEventAccess: false, accessibilityTrusted: false)
        )) { try monitor.start() }
    }

    /// `stop()` はストリームを終端する。終端した監視器を再起動すると、以後
    /// イベントは誰にも届かない。黙って成功してはならない。
    @Test("stop したあとの start は stopped を投げる")
    func startAfterStopThrows() {
        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: { false },
            accessibilityProbe: { false },
            tapController: deniedController()
        )
        monitor.stop()
        #expect(throws: HotkeyError.stopped) { try monitor.start() }
    }

    @Test("start に失敗したあとの stop で落ちない")
    func stopAfterFailedStartIsSafe() {
        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: { false },
            accessibilityProbe: { false },
            tapController: deniedController()
        )
        #expect(throws: HotkeyError.self) { try monitor.start() }
        monitor.stop()
        monitor.stop()  // 二度呼んでも落ちない
    }

    /// **タップを開けた状態（.running）を通す唯一のテスト。**
    /// 権限の無い機体では本物のタップが開けないので、ここは差し替えでしか通せない。
    /// 開けたあとの二重起動は、タップを二枚開いて解放を取りこぼす。
    @Test("起動できたあとに start を呼ぶと alreadyRunning を投げる")
    func doubleStartAfterSuccessThrows() throws {
        let port = try #require(makePlainPort())
        let controller = StubEventTapController(port: port)
        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: { false },
            accessibilityProbe: { false },
            tapController: controller,
            runLoop: testRunLoop()
        )
        defer { monitor.stop() }

        try monitor.start()
        #expect(controller.createCount == 1)

        #expect(throws: HotkeyError.alreadyRunning) { try monitor.start() }
        #expect(controller.createCount == 1, "二度目の start がタップを開いている")
    }

    /// **有効化し忘れたタップは 1 件も配送しない。** 生成しただけで満足してはならない。
    @Test("起動時にタップを有効化する")
    func startEnablesTap() throws {
        let port = try #require(makePlainPort())
        let controller = StubEventTapController(port: port)
        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: { false },
            accessibilityProbe: { false },
            tapController: controller,
            runLoop: testRunLoop()
        )

        try monitor.start()
        #expect(controller.enableCalls == [true])

        // 停止では無効化する。有効なまま放置するとイベントを掴んだままになる。
        monitor.stop()
        #expect(controller.enableCalls == [true, false])
    }

    /// **`stop()` を呼ばずに解放しても落ちない。**
    ///
    /// タップは `Unmanaged.passUnretained(self)` で `self` を retain せずに
    /// 参照している。`deinit` で無効化し損ねると、解放済みのインスタンスへ
    /// コールバックが飛ぶ。アプリ終了時に必ず通る経路である。
    @Test("start に成功したまま解放しても落ちない")
    func deinitAfterSuccessfulStartIsSafe() throws {
        let port = try #require(makePlainPort())
        do {
            let monitor = CGEventTapHotkeyMonitor(
                binding: .rightOption,
                listenAccessProbe: { false },
                accessibilityProbe: { false },
                tapController: StubEventTapController(port: port),
                runLoop: testRunLoop()
            )
            try monitor.start()
            #expect(monitor.isActive)
            // stop() を呼ばずにスコープを抜ける（deinit に任せる）
        }
        // ここまで来れば deinit が例外なく走っている。
        #expect(Bool(true))
    }

    /// **`start()` の最中に `stop()` が走っても、`.stopped` を巻き戻さない。**
    ///
    /// `create` は実測で約 40 ms 掛かる。その間 `tap` はまだ nil なので、割り込んだ
    /// `stop()` は破棄すべきタップを見つけられずに終わっている。ここで `.running` へ
    /// 巻き戻すと、**誰にも参照されない有効なタップがランループに残り、監視器は
    /// `.running` を名乗るのにストリームは終端済み**という沈黙した失敗になる。
    @Test("start の最中に stop が走ったら stopped を投げ、タップを残さない")
    func stopDuringStartDoesNotResurrect() async throws {
        let port = try #require(makePlainPort())
        let controller = InterruptingTapController(port: port)
        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: { false },
            accessibilityProbe: { false },
            tapController: controller,
            runLoop: testRunLoop()
        )
        // タップ生成の「最中」に停止が割り込む。
        controller.interrupt { monitor.stop() }

        #expect(throws: HotkeyError.stopped) { try monitor.start() }

        // 生成してしまったタップは、こちらの責任で無効化して捨てる。
        #expect(controller.enableCalls.contains(false), "生成したタップを無効化していない")
        #expect(!monitor.isActive, ".running を名乗っている")

        // 終端したストリームを持つ監視器を、黙って再起動させない。
        #expect(throws: HotkeyError.stopped) { try monitor.start() }

        let drained = await drain(monitor.events)
        #expect(drained.finished)
    }

    /// 失敗した `start()` の後始末が `.stopped` を `.idle` へ巻き戻さないこと。
    /// 巻き戻すと以後の `start()` が成功し、終端済みのストリームを持つ監視器を返す。
    @Test("start が失敗する最中に stop が走っても、あとの start は stopped を投げる")
    func stopDuringFailingStartKeepsStopped() {
        let controller = InterruptingTapController(port: nil)  // create は nil を返す
        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: { false },
            accessibilityProbe: { false },
            tapController: controller,
            runLoop: testRunLoop()
        )
        controller.interrupt { monitor.stop() }

        #expect(throws: HotkeyError.self) { try monitor.start() }
        // .idle へ戻していたら、ここが成功してしまう。
        #expect(throws: HotkeyError.stopped) { try monitor.start() }
    }

    /// **`stop()` はストリームを終端しなければならない。** 終端しないと、
    /// イベントを待っている状態機械（Task 10）が永久に待ち続ける。
    @Test("stop でイベントストリームが終端する")
    func stopFinishesEventStream() async throws {
        let port = try #require(makePlainPort())
        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: { false },
            accessibilityProbe: { false },
            tapController: StubEventTapController(port: port),
            runLoop: testRunLoop()
        )
        try monitor.start()
        _ = monitor.handle(
            type: .flagsChanged,
            event: makeEvent(keyCode: 0x3D, flags: optionFlags(DeviceBit.rightOption))
        )
        monitor.stop()

        let drained = await drain(monitor.events)
        #expect(drained.finished, "stop したのにストリームが終端していない")
        #expect(drained.events == [.pressed])
    }
}

// MARK: - 監視するイベント種別

@Suite("CGEventTapHotkeyMonitor の監視対象")
struct CGEventTapHotkeyMonitorMaskTests {

    private func contains(_ mask: CGEventMask, _ type: CGEventType) -> Bool {
        mask & CGEventMask(1 << type.rawValue) != 0
    }

    /// 修飾キーは keyUp を出さない。含めても無駄に全打鍵の keyUp を通すだけ。
    @Test("修飾キーのバインドでは keyUp を監視しない")
    func modifierBindingOmitsKeyUp() {
        let mask = CGEventTapHotkeyMonitor.eventMask(for: .rightOption)
        #expect(contains(mask, .flagsChanged))
        #expect(contains(mask, .keyDown), "ESC の抑止に要る")
        #expect(!contains(mask, .keyUp))
    }

    /// **keyUp を落とすと修飾キー以外のバインドは解放を永久に検出できない。**
    @Test("修飾キー以外のバインドでは keyUp を監視する")
    func nonModifierBindingIncludesKeyUp() {
        let mask = CGEventTapHotkeyMonitor.eventMask(for: .controlCommandZ)
        #expect(contains(mask, .keyDown))
        #expect(contains(mask, .keyUp))
    }
}

// MARK: - 本物のタップ生成（権限の有無で結果が変わる）

@Suite("CGEventTapHotkeyMonitor の実機での起動", .serialized)
struct CGEventTapHotkeyMonitorLiveTests {

    /// **`CGEvent.tapCreate` は権限が無くてもブロックしない**ことの回帰検知。
    ///
    /// Task 7 では `AVAudioEngine.inputNode` が未許可のまま 510 秒ブロックした。
    /// TCC 系の API は「エラーを返す」とは限らない。ここが将来ブロックするようになると
    /// 常駐アプリは起動時にフリーズする（Task 7 と同じ壊れ方）。
    ///
    /// **この 5 秒はハングの検知線であって要件値ではない。** 実測は権限なしで約 40 ms。
    @Test("権限の有無にかかわらず start は速やかに返る")
    func startDoesNotBlock() {
        let monitor = CGEventTapHotkeyMonitor(binding: .rightOption)
        let started = ContinuousClock.now
        let thrown: (any Error)?
        do {
            try monitor.start()
            thrown = nil
        } catch {
            thrown = error
        }
        let elapsed = ContinuousClock.now - started
        monitor.stop()

        #expect(elapsed < .seconds(5), "start がブロックしている: \(elapsed)")

        // 権限のある機体では成功し、無い機体では eventTapNotPermitted になる。
        // **どちらの機体でも意味を持つように、投げられた種類まで見る。**
        if let thrown {
            let error = thrown as? HotkeyError
            #expect(
                error == .eventTapNotPermitted(
                    TapPermissionSnapshot(
                        listenEventAccess: CGPreflightListenEventAccess(),
                        accessibilityTrusted: AXIsProcessTrusted()
                    )
                ),
                "想定外の失敗: \(thrown)"
            )
        }
        print("""
        tapCreate 実測: elapsed=\(elapsed) \
        listen=\(CGPreflightListenEventAccess()) ax=\(AXIsProcessTrusted()) \
        outcome=\(thrown.map { "\($0)" } ?? "成功")
        """)
    }
}

// MARK: - コールバック本体（合成イベントで本物のコードパスを通す）

@Suite("CGEventTapHotkeyMonitor のイベント処理")
struct CGEventTapHotkeyMonitorHandleTests {

    private func makeMonitor(
        binding: HotkeyBinding = .rightOption,
        listen: CountingProbe = CountingProbe(returning: false),
        ax: CountingProbe = CountingProbe(returning: false)
    ) -> CGEventTapHotkeyMonitor {
        CGEventTapHotkeyMonitor(
            binding: binding,
            listenAccessProbe: listen.probe,
            accessibilityProbe: ax.probe,
            tapController: deniedController()
        )
    }

    @Test("押して離すと pressed / released がこの順で流れる")
    func pressThenRelease() async {
        let monitor = makeMonitor()
        let down = makeEvent(keyCode: 0x3D, flags: optionFlags(DeviceBit.rightOption))
        let up = makeEvent(keyCode: 0x3D, flags: [])

        #expect(monitor.handle(type: .flagsChanged, event: down) != nil, "修飾キーを抑止している")
        #expect(monitor.handle(type: .flagsChanged, event: up) != nil, "修飾キーを抑止している")

        let events = await collect(monitor.events, count: 2)
        #expect(events == [.pressed, .released])
    }

    /// 抑止は `nil` を返すことで表す。**録音中の ESC だけ**が nil になる。
    @Test("録音中の ESC は cancelled を流し、イベントを抑止する")
    func escapeSuppressed() async {
        let monitor = makeMonitor()
        _ = monitor.handle(
            type: .flagsChanged,
            event: makeEvent(keyCode: 0x3D, flags: optionFlags(DeviceBit.rightOption))
        )
        let escape = makeEvent(keyCode: 0x35, flags: [])
        #expect(monitor.handle(type: .keyDown, event: escape) == nil, "ESC が下流へ漏れている")

        let events = await collect(monitor.events, count: 2)
        #expect(events == [.pressed, .cancelled])
    }

    @Test("録音していないときの ESC は素通しする")
    func escapePassesThroughWhenIdle() async {
        let monitor = makeMonitor()
        let escape = makeEvent(keyCode: 0x35, flags: [])
        #expect(monitor.handle(type: .keyDown, event: escape) != nil)

        // 素通しに加えて、誰も録音していないのにイベントを流していないこと。
        monitor.stop()
        let drained = await drain(monitor.events)
        #expect(drained.finished)
        #expect(drained.events.isEmpty, "録音していないのにイベントが流れている")
    }

    /// 中断のあとは録音していない状態に戻る。戻らないと次の押下が無視される。
    @Test("cancelled のあとにもう一度押すと pressed が出る")
    func canRecordAgainAfterCancel() async {
        let monitor = makeMonitor()
        let down = makeEvent(keyCode: 0x3D, flags: optionFlags(DeviceBit.rightOption))
        _ = monitor.handle(type: .flagsChanged, event: down)
        _ = monitor.handle(type: .keyDown, event: makeEvent(keyCode: 0x35, flags: []))
        _ = monitor.handle(type: .flagsChanged, event: makeEvent(keyCode: 0x3D, flags: []))
        _ = monitor.handle(type: .flagsChanged, event: down)

        let events = await collect(monitor.events, count: 3)
        #expect(events == [.pressed, .cancelled, .pressed])
    }

    /// **タップは重い処理をすると OS に無効化される。** 無効化されたまま放置すると
    /// ホットキーが二度と反応しない（アプリは生きているので気付きにくい）。
    /// 再有効化を試み、取りこぼした解放の代わりに中断を出す。
    @Test("tapDisabledByTimeout で再有効化を試み、録音中なら cancelled を出す")
    func reEnablesAfterTimeout() async {
        let monitor = makeMonitor()
        _ = monitor.handle(
            type: .flagsChanged,
            event: makeEvent(keyCode: 0x3D, flags: optionFlags(DeviceBit.rightOption))
        )
        let notice = makeEvent(keyCode: 0, flags: [])
        _ = monitor.handle(type: .tapDisabledByTimeout, event: notice)

        #expect(monitor.reEnableAttempts == 1)
        let events = await collect(monitor.events, count: 2)
        #expect(events == [.pressed, .cancelled])
    }

    /// **中断のあとは録音していない状態に戻っていること。**
    /// 印を落とし忘れると、次に PTT を押しても `pressed` が出ず、
    /// ユーザーからは「ホットキーが効かなくなった」に見える。
    @Test("tapDisabledByTimeout の中断後にもう一度押すと pressed が出る")
    func recordingResetsAfterTapDisabled() async {
        let monitor = makeMonitor()
        let down = makeEvent(keyCode: 0x3D, flags: optionFlags(DeviceBit.rightOption))
        _ = monitor.handle(type: .flagsChanged, event: down)
        _ = monitor.handle(type: .tapDisabledByTimeout, event: makeEvent(keyCode: 0, flags: []))
        _ = monitor.handle(type: .flagsChanged, event: down)

        let events = await collect(monitor.events, count: 3)
        #expect(events == [.pressed, .cancelled, .pressed])
    }

    /// 録音していないときに無効化されたら、再有効化だけ行い中断は出さない。
    /// 誰も録音していないのに cancelled を出すと、状態機械が余計な後始末を走らせる。
    @Test("録音していないときの tapDisabledByTimeout では cancelled を出さない")
    func reEnableWithoutCancelWhenIdle() async {
        let monitor = makeMonitor()
        _ = monitor.handle(type: .tapDisabledByTimeout, event: makeEvent(keyCode: 0, flags: []))

        #expect(monitor.reEnableAttempts == 1)
        monitor.stop()
        let drained = await drain(monitor.events)
        #expect(drained.finished, "stop したのにストリームが終端していない")
        #expect(drained.events.isEmpty)
    }

    /// **`.tapDisabledByUserInput` は「無効化が要求された」という意味である**
    /// （`CGEvent.h`: "or a user requests taps be disabled"）。
    /// 張り直すのは要求を無視して蘇ることなので行わない。
    @Test("tapDisabledByUserInput では再有効化しない")
    func doesNotReEnableOnUserInput() async {
        let monitor = makeMonitor()
        _ = monitor.handle(
            type: .flagsChanged,
            event: makeEvent(keyCode: 0x3D, flags: optionFlags(DeviceBit.rightOption))
        )
        _ = monitor.handle(type: .tapDisabledByUserInput, event: makeEvent(keyCode: 0, flags: []))

        #expect(monitor.reEnableAttempts == 0, "要求を無視してタップを蘇らせている")
        // 取りこぼした解放の代わりに中断は出す。出さないと録音が終わらない。
        let events = await collect(monitor.events, count: 2)
        #expect(events == [.pressed, .cancelled])
    }

    /// **無制限に張り直すと、無効化と `.cancelled` の応酬が止まらなくなる。**
    /// `events` は無制限バッファなので、際限なく積み上がる。
    @Test("再有効化には上限があり、超えたら諦める")
    func reEnableIsBounded() {
        let monitor = makeMonitor()
        let notice = makeEvent(keyCode: 0, flags: [])
        for _ in 0..<(CGEventTapHotkeyMonitor.maxReEnableAttempts + 5) {
            _ = monitor.handle(type: .tapDisabledByTimeout, event: notice)
        }
        #expect(monitor.reEnableAttempts == CGEventTapHotkeyMonitor.maxReEnableAttempts)
    }

    /// **停止したあとに再有効化してはならない。** 止めたはずのタップが蘇る。
    @Test("stop のあとの tapDisabledByTimeout では再有効化しない")
    func doesNotReEnableAfterStop() {
        let monitor = makeMonitor()
        monitor.stop()
        _ = monitor.handle(type: .tapDisabledByTimeout, event: makeEvent(keyCode: 0, flags: []))
        #expect(monitor.reEnableAttempts == 0)
    }

    /// **キー判定はキーイベントごとに走る。** ここで `CGPreflightListenEventAccess()`
    /// （実測 p50 10.7 ms）を呼ぶと、打鍵のたびに 10 ms がシステム全体に乗る。
    /// hot path が権限照会に触れていないことを回帰として固定する。
    @Test("キー判定は権限照会を一度も呼ばない")
    func handleNeverQueriesPermissions() {
        let listen = CountingProbe(returning: false)
        let ax = CountingProbe(returning: false)
        let monitor = makeMonitor(listen: listen, ax: ax)

        let down = makeEvent(keyCode: 0x3D, flags: optionFlags(DeviceBit.rightOption))
        let up = makeEvent(keyCode: 0x3D, flags: [])
        let other = makeEvent(keyCode: 0x00, flags: [])
        for _ in 0..<500 {
            _ = monitor.handle(type: .flagsChanged, event: down)
            _ = monitor.handle(type: .keyDown, event: other)
            _ = monitor.handle(type: .flagsChanged, event: up)
        }

        #expect(listen.callCount == 0)
        #expect(ax.callCount == 0)
    }
}

// MARK: - 性能

@Suite("キー判定のコスト")
struct HotkeyDecisionPerformanceTests {

    /// キーイベントは打鍵のたびに、しかも**アプリへ配送される前に**通る。
    /// ここが遅いとシステム全体の入力が遅れる。
    ///
    /// **この 1 ms は壊れ検知の線であって要件値ではない。**
    /// 詳細設計書にこの経路の要件値は無い。実測は下の出力を参照。
    @Test("1 打鍵あたりの判定が 1 ms を大きく下回る")
    func decideIsCheap() {
        let monitor = CGEventTapHotkeyMonitor(
            binding: .rightOption,
            listenAccessProbe: { false },
            accessibilityProbe: { false },
            tapController: deniedController()
        )
        let down = makeEvent(keyCode: 0x3D, flags: optionFlags(DeviceBit.rightOption))
        let up = makeEvent(keyCode: 0x3D, flags: [])

        // 暖機
        for _ in 0..<1_000 {
            _ = monitor.handle(type: .flagsChanged, event: down)
            _ = monitor.handle(type: .flagsChanged, event: up)
        }

        var samples: [Double] = []
        for _ in 0..<5_000 {
            let started = DispatchTime.now()
            _ = monitor.handle(type: .flagsChanged, event: down)
            _ = monitor.handle(type: .flagsChanged, event: up)
            samples.append(
                Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 2_000
            )
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p99 = samples[samples.count * 99 / 100]
        print("handle の 1 打鍵あたり: p50 \(p50) us / p99 \(p99) us / max \(samples.last!) us")

        #expect(p99 < 1_000, "1 打鍵に 1 ms 以上掛かっている: p99 \(p99) us")
    }
}

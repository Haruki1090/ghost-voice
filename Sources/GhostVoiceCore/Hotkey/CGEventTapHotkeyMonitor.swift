import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization

/// `CGEventTap` の生成と有効化。
///
/// **本物を直接埋め込むとテストが書けない。** 権限の無い機体では成功経路を、
/// 権限のある機体では失敗経路を、それぞれ一度も通せなくなる
/// （`PasteShortcutSending` を切り離してあるのと同じ理由）。
public protocol EventTapControlling: Sendable {
    func create(
        mask: CGEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?
    ) -> CFMachPort?
    func setEnabled(_ tap: CFMachPort, _ enabled: Bool)
    func isEnabled(_ tap: CFMachPort) -> Bool
}

/// 本番で使う実装。セッション全体を `.defaultTap` で覗く。
public struct SystemEventTapController: EventTapControlling {

    public init() {}

    public func create(
        mask: CGEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?
    ) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,  // イベントを抑止できるのはこれだけ（ESC の抑止に要る）
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        )
    }

    public func setEnabled(_ tap: CFMachPort, _ enabled: Bool) {
        CGEvent.tapEnable(tap: tap, enable: enabled)
    }

    public func isEnabled(_ tap: CFMachPort) -> Bool {
        CGEvent.tapIsEnabled(tap: tap)
    }
}

/// `CGEventTap` で PTT キーを監視する。
///
/// ## 権限について（実測: macOS 26.5.2 / M3、`AXIsProcessTrusted() == false` の機体）
///
/// **門番は事前照会ではなく `CGEvent.tapCreate` 自身である。**
/// CoreGraphics のヘッダにこうある。
///
/// > Taps placed at `kCGHIDEventTap`, `kCGSessionEventTap`, `kCGAnnotatedSessionEventTap`,
/// > or on a specific process may only receive key up and down events if access for
/// > assistive devices is enabled ... **If the tap is not permitted to monitor these
/// > events when the tap is created, then the appropriate bits in the mask are cleared.
/// > If that results in an empty mask, then NULL is returned.**
///
/// だから `AXIsProcessTrusted()` を門番にしてはならない。**Task 8 が踏んだ罠と同じ形**で、
/// `kTCCServiceAccessibility` と `kTCCServiceListenEvent` は隣り合った別レコードである。
/// 片方だけ許可された機体では、事前照会を門番にすると
/// **実際には開けるタップを開かずに諦める**（またはその逆）ことになる。
/// ここでは**まず `tapCreate` を試し、nil だったときに初めて**両方の照会を行い、
/// どちらのペインへ案内すべきかの手掛かりとして `TapPermissionSnapshot` に載せる。
///
/// 実測値:
///
/// | 呼び出し | 権限なしでの結果 | 所要 |
/// |---|---|---|
/// | `tapCreate(.cgSessionEventTap, .defaultTap)` | **nil** | 約 40 ms |
/// | `tapCreate(.cgSessionEventTap, .listenOnly)` | **非 nil。ただし恒久的に無効** | 約 26 ms |
/// | `tapCreate(.cghidEventTap, .defaultTap)` | nil | 約 47 ms |
/// | `tapCreateForPid(自プロセス, .defaultTap)` | nil | 約 0.3 ms |
/// | `CGPreflightListenEventAccess()` | false | 初回 13.9 ms / 以降 p50 **10.657 ms** |
/// | `AXIsProcessTrusted()` | false | 初回 44.7 ms / 以降 p50 0.0005 ms |
///
/// - Important: **`tapCreate` はブロックしない。** 権限が無くても約 40 ms で nil を返す
///   （Task 7 の `AVAudioEngine.inputNode` は未許可のまま 510 秒ブロックした）。
///   12 秒の期限を切って確かめた。
///
/// - Important: **`.listenOnly` へ替えてはならない。** 権限が無くても非 nil の
///   `CFMachPort` が返るが、そのタップは `CGEvent.tapEnable(enable: true)` を
///   通しても無効のままで、**イベントを 1 件も配送しない。**
///   「start に成功したのにホットキーが効かない」という、Task 8 の
///   「テキストが消えたうえに成功と記録される」と同じ形の沈黙した失敗になる。
///   `.defaultTap` は ESC の抑止にも必要である。
///   念のため `start()` で `tapIsEnabled` まで確かめている。
///
/// ## キー判定のコスト
///
/// **`handle` はキーイベントごとに、しかもアプリへ配送される前に走る。**
/// ここで `CGPreflightListenEventAccess()`（実測 p50 10.7 ms）を呼ぶと、
/// 打鍵のたびに 10 ms がシステム全体の入力に乗る。
/// **そのため hot path は権限照会に一切触れない**（キャッシュではなく不参照）。
/// `HotkeyMonitorTests` の「キー判定は権限照会を一度も呼ばない」がこれを固定している。
///
/// 実測（`handle` の 1 打鍵あたり。5,000 回、1,000 回の暖機後）:
///
/// | 条件 | p50 | p99 | 最大 |
/// |---|---|---|---|
/// | 低負荷（load average 約 3.6） | 0.75 μs | 0.96 μs | 21.75 μs |
/// | 負荷下（`yes` 16 本、load average 約 9.7） | 0.771 μs | 1.56 μs | 46.60 μs |
///
/// CPU 負荷でほぼ動かない。権限照会 1 回（10,657 μs）との差は約 14,000 倍である。
public final class CGEventTapHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {

    private enum Phase {
        case idle, starting, running, stopped
    }

    public let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    private let listenAccessProbe: @Sendable () -> Bool
    private let accessibilityProbe: @Sendable () -> Bool
    private let tapController: any EventTapControlling

    /// タップを張るランループ。**本番は必ずメインのランループである。**
    /// テストがプロセス共有のメインランループを触らずに済むよう差し替え口にしてある。
    private let runLoop: CFRunLoop

    /// 応答しないタップを張り直す上限。
    ///
    /// 無制限に張り直すと、無効化と `.interrupted` の応酬が止まらなくなる。
    static let maxReEnableAttempts = 10

    /// 下の 6 つを守る。**`binding` / `tap` / `runLoopSource` も含める。**
    /// コールバックはランループのスレッドから、`start` / `stop` / `rebind` は
    /// 別のスレッドから来る。
    private let lock = NSLock()
    /// 監視している PTT のバインド。**`rebind(to:)` で差し替わる**ので、
    /// 読むときは必ずロックの中で読むこと（`handle` は既にそうしている）。
    private var binding: HotkeyBinding
    private var phase: Phase = .idle
    private var isRecording = false
    /// セッションが確定〜整形の処理中か（`setSessionBusy`）。
    /// **`isRecording` とは別の量である。** キーを離した後も真でありうる。
    private var isSessionBusy = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// タップが無効化され、張り直さないと決めた。以後ホットキーは反応しない。
    private var tapDead = false

    private let reEnables = Atomic<Int>(0)

    /// タップの再有効化を試みた回数。テストからの観測用。
    var reEnableAttempts: Int { reEnables.load(ordering: .relaxed) }

    /// タップが張られていて、まだ生きているか。
    ///
    /// **`start()` が成功しても、あとで無効化されて false になりうる**
    /// （`handleTapDisabled`）。ホットキーが黙って効かなくなる唯一の経路なので、
    /// Task 10 / 11 はここを見てユーザーへ知らせること。
    public var isActive: Bool {
        lock.withLock { phase == .running && !tapDead }
    }

    /// いま監視している PTT のバインド（`HotkeyMonitor` の契約）。
    public var currentBinding: HotkeyBinding {
        lock.withLock { binding }
    }

    public init(
        binding: HotkeyBinding,
        listenAccessProbe: @escaping @Sendable () -> Bool = { CGPreflightListenEventAccess() },
        accessibilityProbe: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        tapController: any EventTapControlling = SystemEventTapController(),
        runLoop: CFRunLoop = CFRunLoopGetMain()
    ) {
        self.binding = binding
        self.listenAccessProbe = listenAccessProbe
        self.accessibilityProbe = accessibilityProbe
        self.tapController = tapController
        self.runLoop = runLoop
        (events, continuation) = AsyncStream<HotkeyEvent>.makeStream()
    }

    deinit {
        // タップは `self` を retain せずに保持している。**先に無効化しないと
        // 解放済みのインスタンスへコールバックが飛ぶ。**
        stop()
    }

    /// 監視するイベント種別。
    ///
    /// **`keyUp` は修飾キー以外のバインドのときだけ含める。** 修飾キーは keyUp を
    /// 出さないので既定（右 Option）では無駄になり、全打鍵の keyUp をタップで
    /// 素通しさせる分だけシステム全体の入力経路を重くする。
    /// 逆に修飾キー以外のバインドで keyUp を落とすと、**解放を永久に検出できない。**
    static func eventMask(for binding: HotkeyBinding) -> CGEventMask {
        var mask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        if !binding.isModifierOnly {
            mask |= (1 << CGEventType.keyUp.rawValue)
        }
        return CGEventMask(mask)
    }

    public func start() throws {
        lock.lock()
        switch phase {
        case .stopped:
            lock.unlock()
            throw HotkeyError.stopped
        case .starting, .running:
            lock.unlock()
            throw HotkeyError.alreadyRunning
        case .idle:
            phase = .starting
        }
        let current = binding
        lock.unlock()

        do {
            try openTap(binding: current)
        } catch {
            // **失敗しても .idle へ戻す。** 権限を与えたユーザーが
            // もう一度試せなくなるのは、権限フローとして成立しない。
            //
            // ただし**割り込んだ `stop()` が付けた `.stopped` は巻き戻さない。**
            // 巻き戻すと以後の `start()` が成功してしまい、終端済みのストリームを
            // 持つ監視器を黙って返すことになる（`startAfterStopThrows` が
            // 守ろうとしている不変条件が、まさにこの経路で破れる）。
            lock.lock()
            if phase == .starting { phase = .idle }
            lock.unlock()
            throw error
        }
    }

    /// - Parameter binding: **ロックの中で読み取った写しを渡すこと。**
    ///   `rebind(to:)` と競合しうるので、生成の最中に差し替わった値を使ってはならない。
    private func openTap(binding: HotkeyBinding) throws {
        let context = Unmanaged.passUnretained(self).toOpaque()

        let created = tapController.create(
            mask: Self.eventMask(for: binding), callback: Self.callback, userInfo: context
        )
        guard let created else {
            // ここで初めて照会する。**hot path では決して呼ばない。**
            throw HotkeyError.eventTapNotPermitted(
                TapPermissionSnapshot(
                    listenEventAccess: listenAccessProbe(),
                    accessibilityTrusted: accessibilityProbe()
                )
            )
        }

        tapController.setEnabled(created, true)
        guard tapController.isEnabled(created) else {
            // 生成できたのに無効。このまま返すと沈黙した失敗になる。
            // 破棄の手順は `stop()` と同じ順（無効化 → invalidate）に揃える。
            tapController.setEnabled(created, false)
            CFMachPortInvalidate(created)
            throw HotkeyError.tapDisabledAtStart
        }

        // **`CFRunLoopSource!` は暗黙アンラップである。** 無効な `CFMachPort` を渡すと
        // nil が返り、そのまま `CFRunLoopAddSource` へ流すと**プロセスごと落ちる。**
        // 常駐アプリのクラッシュは沈黙した失敗より悪い。エラーとして返す。
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            tapController.setEnabled(created, false)
            CFMachPortInvalidate(created)
            throw HotkeyError.tapDisabledAtStart
        }
        CFRunLoopAddSource(runLoop, source, .commonModes)

        // **`stop()` がここまでの間に走っていたかを確かめる。**
        // `create` は実測で約 40 ms 掛かる。その間 `tap` はまだ nil なので、
        // 割り込んだ `stop()` は破棄すべきタップを見つけられずに終わっている。
        // ここで `.running` へ巻き戻すと、**誰にも参照されない有効なタップが
        // run loop に残り、監視器は `.running` を名乗るのにストリームは終端済み**
        // という、`.listenOnly` と同じ形の沈黙した失敗になる。後始末はこちらの責任。
        lock.lock()
        guard phase != .stopped else {
            lock.unlock()
            tapController.setEnabled(created, false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(created)
            throw HotkeyError.stopped
        }
        tap = created
        runLoopSource = source
        phase = .running
        lock.unlock()
    }

    /// セッションが処理中かを知らせる（`HotkeyMonitor` の契約）。
    ///
    /// **hot path から見えるのはこのフラグの読み取りだけ**（`handle` は権限照会に
    /// 触れないのと同じ理由で、ここでも余計な仕事をしない）。
    public func setSessionBusy(_ busy: Bool) {
        lock.withLock { isSessionBusy = busy }
    }

    /// PTT のバインドを差し替える（`HotkeyMonitor` の契約。欠落 9 / 持ち越し項目 10）。
    ///
    /// **タップを張り替える。** 監視するイベント種別はバインドで変わる（修飾キー単独では
    /// `keyUp` を含めない。詳細設計書 §2.1）ので、`binding` を書き換えるだけでは
    /// **⌃⌘Z へ変えたときに解放を検出できず、録音が永遠に終わらない。**
    ///
    /// **ストリームは終端しない。** `stop()` して作り直す形にすると、`DictationSession` が
    /// `let` で握っている監視器を差し替える必要があり、公開 API か組み立て方の変更になる
    /// （持ち越し項目 10 の指摘）。同じインスタンスの中でタップだけを替えれば波及しない。
    ///
    /// - Important: **録音中に呼ぶと `.interrupted` を出す。** 古いキーの解放はもう
    ///   届かないので、出さないと録音が終わらない状態で固まる（項目 14 と同じ形）。
    ///   `.cancelled` ではないので、そこまでの発話は確定して挿入される。
    public func rebind(to newBinding: HotkeyBinding) throws {
        lock.lock()
        switch phase {
        case .stopped:
            lock.unlock()
            throw HotkeyError.stopped
        case .starting:
            // 起動の最中。`create` は実測で約 40 ms 掛かる。ここで割り込むと、
            // 開きかけのタップと張り替えたタップが二重になる。
            lock.unlock()
            throw HotkeyError.alreadyRunning
        case .idle:
            binding = newBinding
            let wasRecording = isRecording
            isRecording = false
            lock.unlock()
            if wasRecording { continuation.yield(.interrupted) }
            return
        case .running:
            let oldTap = tap
            let oldSource = runLoopSource
            let wasRecording = isRecording
            binding = newBinding
            tap = nil
            runLoopSource = nil
            isRecording = false
            // 新しいタップには再有効化の予算を渡し直す。古いタップの回数を持ち越すと、
            // 張り替えたのに 1 回で諦めることがある。
            tapDead = false
            reEnables.store(0, ordering: .relaxed)
            // **`.starting` を通る。** 一旦 `.idle` にすると、その隙に `start()` が
            // 成功してタップが二枚になる。
            phase = .starting
            lock.unlock()

            teardown(tap: oldTap, source: oldSource)
            if wasRecording { continuation.yield(.interrupted) }

            do {
                try openTap(binding: newBinding)
            } catch {
                // **動いているふりをしない。** 権限を直した利用者が `start()` で
                // やり直せるよう `.idle` へ戻す（`stop()` が付けた `.stopped` は巻き戻さない）。
                lock.lock()
                if phase == .starting { phase = .idle }
                lock.unlock()
                throw error
            }
        }
    }

    /// 停止する。**ストリームは終端し、以後この監視器は再起動できない**
    /// （`AsyncStream` は終端を取り消せない）。再開したい場合は作り直すこと。
    ///
    /// - Note: PTT キーを変えたいだけなら `rebind(to:)` を使うこと。こちらを通すと
    ///   ストリームが終端し、監視器を作り直すしかなくなる。
    public func stop() {
        lock.lock()
        let currentTap = tap
        let source = runLoopSource
        let wasStopped = (phase == .stopped)
        tap = nil
        runLoopSource = nil
        isRecording = false
        isSessionBusy = false
        phase = .stopped
        lock.unlock()

        teardown(tap: currentTap, source: source)
        if !wasStopped { continuation.finish() }
    }

    /// タップとランループソースを捨てる。**順序は無効化 → 取り外し → invalidate。**
    /// `stop()` と `rebind(to:)` で同じ手順を使う（片方だけ順序が違うと、
    /// 捨てたはずのタップへコールバックが飛ぶ窓ができる）。
    private func teardown(tap: CFMachPort?, source: CFRunLoopSource?) {
        if let tap {
            tapController.setEnabled(tap, false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<CGEventTapHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    /// タップのコールバック本体。
    ///
    /// - Returns: 抑止するなら nil、素通しするならイベントそのもの。
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

        // **キーイベントではない通知が来る。** ここでキーコードを読むと無意味な値になる。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return handleTapDisabled(type: type, event: event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        lock.lock()
        let decision = HotkeyDecision.decide(
            type: type, keyCode: keyCode, flags: flags,
            binding: binding, isRecording: isRecording, isSessionBusy: isSessionBusy
        )
        switch decision.event {
        case .pressed: isRecording = true
        case .released, .cancelled, .interrupted: isRecording = false
        case nil: break
        }
        lock.unlock()

        if let hotkeyEvent = decision.event { continuation.yield(hotkeyEvent) }
        return decision.suppress ? nil : Unmanaged.passUnretained(event)
    }

    /// タップが無効化されたときの通知。**2 種類あり、意味が違う。**
    ///
    /// `CGEvent.h` はこう定めている。
    ///
    /// > Taps are normally enabled when created. **If a tap becomes unresponsive or
    /// > a user requests taps be disabled**, an appropriate `kCGEventTapDisabled...`
    /// > event is passed to the registered `CGEventTapCallBack` function.
    ///
    /// | 通知 | 意味 | 扱い |
    /// |---|---|---|
    /// | `.tapDisabledByTimeout` | タップが応答しなくなった | **再有効化する**（上限あり） |
    /// | `.tapDisabledByUserInput` | **無効化が要求された** | **再有効化しない** |
    ///
    /// - `byTimeout` を放置すると**ホットキーが二度と反応しない。** アプリは
    ///   生きたままなのでユーザーからは原因が判らない。だから張り直す。
    /// - `byUserInput` を張り直すのは**要求を無視して蘇ること**なので行わない。
    ///
    /// **どちらも無制限には扱わない。** 原因不明の連続無効化に対して張り直し続けると、
    /// 無効化と `.interrupted` の応酬が止まらなくなる（`events` は無制限バッファである）。
    /// `maxReEnableAttempts` 回で諦め、`isActive` が false になる。
    ///
    /// 無効化されていた間に PTT キーの解放を取りこぼしている可能性があるため、
    /// 録音中だったなら `.interrupted` を出す。**出さないと録音が終わらない状態で固まる。**
    ///
    /// **`.cancelled` ではない。** 利用者は喋っていたのであって中断を要求していないので、
    /// セッション側はこれを確定として扱う（基本設計書 §7 の縮退表。最大録音時間の満了と
    /// 同じ裁定）。ここを `.cancelled` にしていたために、**誰も決めないまま
    /// 「取りこぼした発話は捨てる」になっていた**（フェーズ 1 の最終レビュー I-2）。
    ///
    /// - Important: 諦めた場合、**ホットキーは以後反応しない。** 監視器を作り直す以外に
    ///   復帰の手立ては無い。Task 10 / 11 は `isActive` を見てユーザーへ知らせること。
    private func handleTapDisabled(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        let currentTap = tap
        let wasRecording = isRecording
        var shouldReEnable = false

        // **停止済みなら何もしない。** 自分で止めたタップを蘇らせてはならない。
        // `stop()` はロック下で `phase = .stopped` と `isRecording = false` を先に
        // 済ませてから `setEnabled(false)` を呼ぶので、その無効化に由来する通知が
        // ここへ来ても必ずこの分岐で止まる。
        if phase != .stopped {
            isRecording = false
            if type == .tapDisabledByUserInput {
                // 無効化が要求された。蘇らせない。
                tapDead = true
            } else if reEnables.load(ordering: .relaxed) >= Self.maxReEnableAttempts {
                tapDead = true
            } else {
                shouldReEnable = true
            }
        }
        lock.unlock()

        if shouldReEnable {
            reEnables.add(1, ordering: .relaxed)
            if let currentTap { tapController.setEnabled(currentTap, true) }
        }
        if wasRecording { continuation.yield(.interrupted) }
        return Unmanaged.passUnretained(event)
    }
}

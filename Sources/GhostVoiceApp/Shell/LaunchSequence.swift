/// 画面をいつ作るかを決める唯一の場所。
///
/// **工場は `enterRunLoop` の中でしか呼ばれない。** `enterRunLoop` を呼ぶのは
/// `GhostVoiceAppDelegate` が `NSApplication.run()` の**イベントループが回り始めた後**に
/// メインキューへ積んだ 1 回だけである（`applicationDidFinishLaunching` の中で作らないのは、
/// そこがまだ `run()` の `finishLaunching` の途中であり、window があると活性化を誘発するため。
/// `core-api-and-hud.md` B-3 の実測）。
///
/// 1 度作ったら工場は捨てる。**2 度目の `enterRunLoop` では何も起きない**
/// （AppKit が `applicationDidFinishLaunching` を 2 回配ることは無いが、
/// 「作られていない window が後から現れる」経路を残さないための保険である）。
@MainActor
public final class LaunchSequence {

    public enum Phase: Sendable, Equatable {
        /// まだ `NSApplication.run()` のイベントループに入っていない。**window は 1 枚も無い。**
        case beforeRunLoop
        case running
        case tornDown
    }

    public private(set) var phase: Phase = .beforeRunLoop
    public private(set) var surfaces: [any AppSurface] = []

    private var factories: [AppSurfaceFactory]

    public init(factories: [AppSurfaceFactory]) {
        self.factories = factories
    }

    /// **`NSApplication.run()` のイベントループが回り始めた後にだけ呼ぶこと。**
    ///
    /// - Returns: 作った画面の数。
    @discardableResult
    public func enterRunLoop(services: AppServices) -> Int {
        guard phase == .beforeRunLoop else { return 0 }
        phase = .running
        let entry = RunLoopEntry()
        surfaces = factories.map { $0(entry, services) }
        // **もう作らせない。**
        factories = []
        return surfaces.count
    }

    /// 終了時。作った画面を逆順に畳む。
    public func tearDown() {
        for surface in surfaces.reversed() { surface.teardown() }
        surfaces = []
        factories = []
        phase = .tornDown
    }
}

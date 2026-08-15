import AppKit
import GhostVoiceCore
import SwiftUI

/// **利用者が能動的に開く窓**（設定・履歴）。`NSWindow` を作る唯一の場所である。
///
/// ## HUD とは要件が正反対である
///
/// | | HUD（`HUDPanel`） | この窓 |
/// |---|---|---|
/// | 活性化 | **絶対にさせない**（挿入先が壊れる） | **させてよい**（利用者が自分で開いた） |
/// | 出し方 | `orderFrontRegardless`（キーにしない） | `makeKeyAndOrderFront`（**入力を受け取る必要がある**） |
/// | level | `.statusBar + 1`（26） | 既定（0） |
/// | 閉じ方 | `orderOut` | **閉じたうえで前面を明示的に返す**（`dismissAndReturnFocus`） |
///
/// **`makeKeyAndOrderFront` を使ってよいのはここだけである。** HUD で使うと
/// その瞬間にフォーカスを奪い、`SystemAccessibility.frontmostProcessIdentifier()` が
/// Ghost Voice 自身を拾って挿入先が壊れる（`HUDWindowContractTests` がソース走査で固定）。
///
/// ## `RunLoopEntry` を要求する理由（実測に基づく禁止）
///
/// `NSApplication.run()` を呼ぶ**前**に window を出すと、AppKit が `finishLaunching` の
/// 時点でアプリを**活性化する**（`core-api-and-hud.md` B-3 の実測）。
/// **禁止を注意書きではなく構造で守る**ため、鍵が無いとこの型は作れない。
///
/// - Important: **鍵を持っていても、起動時に窓を作らないこと。**
///   `AppSurface` の doc が「起動時に非表示の window を用意しておく実装は禁止」と
///   定めている。`StatusMenuSurface` は**利用者がメニューを選んだときに初めて**作る。
@MainActor
final class AppWindow: NSObject, NSWindowDelegate {

    private let window: NSWindow
    /// 窓が閉じられたときに呼ぶ（利用者が赤いボタンを押した場合も含む）。
    private let onClose: @MainActor () -> Void

    /// - Parameter entry: `NSApplication.run()` が始まった後であることの証。
    init(
        _ entry: RunLoopEntry,
        title: String,
        size: CGSize,
        content: some View,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.onClose = onClose
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = title
        // **閉じても解放しない。** 解放すると、次に開くときに作り直すことになり、
        // `loadFailure` を握っている ViewModel と窓の寿命がずれる。
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        super.init()
        window.delegate = self
    }

    /// **利用者の操作で開く。** ここでフォーカスを奪うのは意図どおりである。
    func present() {
        // `.accessory` のアプリは、`activate()` しないと窓がキーにならない
        // （Dock にもメニューバーにも居ないので、他の手段で前面へ来られない）。
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window.isVisible }

    /// 窓を閉じ、**前面が Ghost Voice から離れるまで待つ。**
    ///
    /// ## なぜ待つのか
    ///
    /// 履歴からの再挿入は `SystemAccessibility.frontmostProcessIdentifier()` が
    /// 拾う最前面 pid へ書く。**窓が前面のまま挿入すると、挿入先が Ghost Voice 自身になる**
    /// （`HistoryViewModel.reinsert` の注記。差し替えの側では `ReplacementDecline.ownProcess`
    /// として現れる）。`HistoryView` は**閉じる口を渡されないと再挿入のボタンを出さない**
    /// 形になっており、その「閉じる口」がこれである。
    ///
    /// ## `didResignActiveNotification` では足りない（**実測 / 2026-08-15**）
    ///
    /// 最初はこれを `NSApplication.didResignActiveNotification` で待つ形にした。
    /// **測ったら足りていなかった。**
    ///
    /// | 時刻 | 何が起きたか |
    /// |---|---|
    /// | 11:58.987 | 窓を閉じて `NSApp.hide(nil)` |
    /// | 11:58.991 | **`NSApp.isActive` は既に false**（通知を待つまでもない） |
    /// | 11:59.017 | **ここでようやく** `kCGWindowLayer == 0` の最前面が相手のアプリになった |
    ///
    /// つまり `NSApp.isActive` が false になってから、**さらに約 26 ms のあいだ
    /// 最前面はまだ Ghost Voice だった。** その隙に再挿入すると、
    /// **挿入先が Ghost Voice 自身になる**（`ReplacementDecline.ownProcess`）。
    /// 通知を待つ実装は「待った気になるだけ」で、実際には 1 度も待っていなかった
    /// （常に `alreadyInactive` で即座に戻っていた）。
    ///
    /// **そこで「相手のアプリが前面に立った」ことそのものを待つ。**
    ///
    /// ## 活性の切り替えと、窓の並びの入れ替えは別である（**実測 / 2026-08-15**）
    ///
    /// `NSWorkspace.shared.frontmostApplication` に替えても**同じだった**——
    /// `NSApp.hide(nil)` の直後には既に相手のアプリを指しており（0 ms）、
    /// それでもなお `kCGWindowLayer == 0` の最前面は約 24〜32 ms のあいだ
    /// Ghost Voice のままだった（3 回の計測で 32 / 26 / 24 ms）。
    ///
    /// **遅れているのは活性の帳簿ではなく、window server の窓の並びである。**
    /// 挿入先の判定はその並びを読むので、**活性を見て待つ実装では原理的に足りない。**
    ///
    /// ## いまは「時間」ではなく「事実」で待っている
    ///
    /// かつてはここに **150 ms の整定**（`frontmostSettle`）を置いていた。
    /// **あれは決めごとであって実測の上限ではない**——観測したのは
    /// 「入れ替わりに 24〜32 ms 掛かった（n=3・低負荷）」ことだけで、
    /// 負荷下の分布は測っていなかった。外れれば再挿入が Ghost Voice 自身へ入る。
    ///
    /// `SystemAccessibility.frontmostProcessIdentifier()` が公開されたので、
    /// **挿入先を決めるのとまったく同じ規則を直接見て待てる**ようになった。
    /// 待つ条件は「最前面の pid が Ghost Voice でなくなったか」であり、
    /// **時計は上限にしか使っていない。**
    ///
    /// ## やり直した実測（**2026-08-15 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2**）
    ///
    /// `--window-check` で設定・履歴の窓を閉じてから決着するまで:
    ///
    /// | 条件 | 実測 |
    /// |---|---|
    /// | 静穏（3 回 / 6 事象） | 16 / 17 / 21 / 17 / 19 / 22 ms |
    /// | 負荷下（2 回 / 4 事象。load average 10.6〜24.5） | 17 / 15 / 16 / 12 ms |
    ///
    /// **10 事象すべて `.returned`。上限には 1 度も達していない。**
    /// **負荷下でも遅くならなかった**——事実を待つので、遅ければ待ちが伸びるだけである
    /// （150 ms の整定は、遅い側でも足りず速い側でも払いすぎる、という両損だった）。
    ///
    /// 外から同じ規則で 4 ms 間隔に観測すると、**「戻った」と判定した 1〜4 ms 後に
    /// 入れ替わりが見える**——判定が事実より早く出ていないことの裏付けである。
    ///
    /// - Returns: 前面が戻ったか。**呼び出し側は必ず見ること**——
    ///   戻っていないのに挿入すると挿入先が Ghost Voice 自身になる。
    ///   `HistoryViewModel.reinsert(_:field:focus:)` が受け取る形になっている。
    @discardableResult
    func dismissAndReturnFocus(
        timeout: Duration = AppWindow.frontmostHandbackTimeout
    ) async -> FocusHandback {
        window.orderOut(nil)
        // **`orderOut` だけでは前面は戻らない。** `.accessory` のアプリは
        // 窓を隠しても活性のままでありうるので、明示的に前面を返す。
        NSApp.hide(nil)
        let outcome = await AppWindow.waitUntilAnotherAppIsFrontmost(timeout: timeout)

        // **前面が戻ったかを毎回言う。** 戻らないまま再挿入すると、挿入先が
        // Ghost Voice 自身になる。**「戻ったつもり」を黙って通さない。**
        switch outcome {
        case .returned(let elapsed):
            AppDiagnostics.note(
                "[窓] \(window.title) を閉じて前面を返しました（\(elapsed.milliseconds) ms）。")
        case .timedOut(let elapsed):
            AppDiagnostics.note(
                "[窓] \(window.title) を閉じましたが、\(elapsed.milliseconds) ms 待っても"
                    + "最前面が Ghost Voice のままでした。**再挿入は行いません**"
                    + "（行うと Ghost Voice 自身へ入るため）。")
        }
        return outcome.handedBack ? .returned : .notReturned
    }

    func close() {
        window.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // **赤いボタンで閉じた場合もここを通る。** 通らないと、捕獲モードが
        // 開いたまま残って PTT が効かなくなる（`SettingsViewModel.cancelCapture`）。
        onClose()
        // 窓を閉じたら前面を返す。**返さないと次の発話が Ghost Voice 自身へ入る。**
        NSApp.hide(nil)
    }

    // MARK: - 前面が戻るのを待つ

    /// **最前面の判定を照会する間隔。**
    ///
    /// **決めごとだが、両側とも実測に挟まれている。**
    ///
    /// | 側 | 実測 | 効き方 |
    /// |---|---|---|
    /// | 上 | 入れ替わりは 24〜32 ms（2026-08-15 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2 / **n=3・低負荷**） | 粗いと、答えが間隔に丸められる。最小の 24 ms に対して 6 回は見たい |
    /// | 下 | 1 回の照会は p50 0.65 ms / p95 1.05 ms（同機体 / **n=1500**） | 照会より短くすると実質の busy loop になる |
    ///
    /// 4 ms は「24 ms のあいだに 6 回見る」「照会 1 回の p95 の約 4 倍」の両方を満たす。
    /// **D2 の外からの計測（4 ms 間隔でサンプルした）とも同じ刻みである。**
    ///
    /// - Note: **PTT の経路には 1 ms も乗らない。** ここを通るのは
    ///   利用者が設定・履歴の窓を閉じたときだけである。
    static let frontmostPoll: Duration = .milliseconds(4)

    /// **待ちの上限。**
    ///
    /// **事実で判定するとはいえ、永久に待ってはならない。** 何かの理由で前面が
    /// 戻らないとき（Ghost Voice 以外に `kCGWindowLayer == 0` の窓を持つアプリが
    /// 1 つも無い、window server が詰まっている等）、ここで固まると
    /// **履歴画面のボタンが返ってこない。**
    ///
    /// **これは決めごとである。** 実測した最大（22 ms / n=10 / 静穏・負荷下とも）の
    /// 約 27 倍を取った。**上限そのものは 1 度も観測できていない**（10 事象すべて戻った）
    /// ——**達したときの振る舞いは検査でのみ固定してある**（`FrontmostHandbackTests`）。
    ///
    /// **上限に達したときは再挿入を行わない**——`dismissAndReturnFocus` が
    /// `.notReturned` を返し、`HistoryViewModel.reinsert` がクリップボードへ退避する。
    /// **発話は失われない**（クリップボードと履歴の両方に残る。`ActionOutcome.reinsertAbandoned`）。
    static let frontmostHandbackTimeout: Duration = .milliseconds(600)

    /// 前面が戻るのを待った結果。
    enum FocusReturn: Sendable, Equatable {
        /// 最前面が Ghost Voice でなくなった。**掛かった時間つき。**
        case returned(elapsed: Duration)
        /// 期限までに戻らなかった。**このまま挿入すると Ghost Voice 自身へ入る。**
        case timedOut(elapsed: Duration)

        var handedBack: Bool {
            if case .returned = self { return true }
            return false
        }
    }

    /// **最前面が Ghost Voice でなくなるまで**待つ。
    ///
    /// ## 何を見て待つか
    ///
    /// **挿入先を決めるのとまったく同じ規則**（`kCGWindowLayer == 0` の最前面 pid）を
    /// 直接見る。`AccessibilityInserter.focusedElement()` は必ず
    /// `SystemAccessibility.frontmostProcessIdentifier()` を通って相手を決めるので、
    /// **これが自分を指さなくなった時点で「挿入しても自分へは入らない」が事実として成立する。**
    ///
    /// `NSApp.isActive` / `NSWorkspace.frontmostApplication` を見る実装では
    /// **原理的に足りない**（型の doc の実測。活性の帳簿は 0 ms で切り替わるが、
    /// 窓の並びは 24〜32 ms 遅れる）。
    ///
    /// - Important: **`nil` は成立とみなす。** `nil` は「`kCGWindowLayer == 0` の窓が
    ///   画面に 1 つも無い」であり、そのとき `focusedElement()` も `nil` を返す
    ///   ——**挿入先が Ghost Voice 自身になることはありえない**ので、待つ理由が無い。
    /// - Returns: どう終わったか。**`.timedOut` のとき、呼び出し側は挿入してはならない。**
    ///   かつては「期限まで待って、それでも進む」形だったが、
    ///   **進んだ先が Ghost Voice 自身では発話の出口にならない**
    ///   （AX は自プロセスを弾き、Pasteboard 経路は ⌘V がどこにも刺さらないまま
    ///   300 ms 後にクリップボードを元へ戻す＝行き先が 1 つも残らない）。
    ///   代わりにクリップボードへ退避する（`HistoryViewModel.reinsert`）。
    /// - Parameter frontmost: 最前面の判定。**差し替えは検査のためだけにある。**
    ///   本番では必ず Core の唯一の規則を通ること（`WindowWiringContractTests`）。
    static func waitUntilAnotherAppIsFrontmost(
        timeout: Duration,
        poll: Duration = AppWindow.frontmostPoll,
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        frontmost: () -> pid_t? = { SystemAccessibility.frontmostProcessIdentifier() }
    ) async -> FocusReturn {
        let started = ContinuousClock.now
        let deadline = started + timeout
        while true {
            // **眠る前に 1 度は見る。** 既に戻っている場合まで 1 周期待たされないように。
            if frontmost() != ownProcessIdentifier {
                return .returned(elapsed: .now - started)
            }
            guard ContinuousClock.now < deadline else {
                return .timedOut(elapsed: .now - started)
            }
            try? await Task.sleep(for: poll)
        }
    }
}

extension Duration {
    /// 診断の 1 行に出すためのミリ秒。
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

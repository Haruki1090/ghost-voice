import AppKit
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
/// その瞬間にフォーカスを奪い、`AccessibilityInserter.frontmostProcessIdentifier()` が
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
    /// 履歴からの再挿入は `AccessibilityInserter.frontmostProcessIdentifier()` が
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
    /// - Note: 本来は挿入先の判定と**同じ規則**（`kCGWindowLayer == 0` の最前面 pid）を
    ///   待ちたい。しかし `AccessibilityInserter.frontmostProcessIdentifier()` は
    ///   Core の internal であり、App から呼べない。**規則を 2 つに増やさない**ために
    ///   自前で `CGWindowListCopyWindowInfo` を書くことはせず、
    ///   **実測に基づく整定時間**で埋めてある（`frontmostSettle`）。
    ///   **公開してほしい旨は報告に書いた。**
    func dismissAndReturnFocus(timeout: Duration = .milliseconds(600)) async {
        window.orderOut(nil)
        // **`orderOut` だけでは前面は戻らない。** `.accessory` のアプリは
        // 窓を隠しても活性のままでありうるので、明示的に前面を返す。
        NSApp.hide(nil)
        let outcome = await AppWindow.waitUntilAnotherAppIsFrontmost(timeout: timeout)
        // **活性が切り替わってからも、窓の並びはまだ入れ替わっていない。**
        // ここを飛ばすと、再挿入が Ghost Voice 自身へ入りうる（実測 24〜32 ms）。
        try? await Task.sleep(for: AppWindow.frontmostSettle)

        // **前面が戻ったかを毎回言う。** 戻らないまま再挿入すると、挿入先が
        // Ghost Voice 自身になる。**「戻ったつもり」を黙って通さない。**
        switch outcome {
        case .returned(let elapsed):
            AppDiagnostics.note(
                "[窓] \(window.title) を閉じて前面を返しました（\(elapsed.milliseconds) ms）。")
        case .timedOut(let elapsed):
            AppDiagnostics.note(
                "[窓] \(window.title) を閉じましたが、\(elapsed.milliseconds) ms 待っても前面が戻りませんでした。"
                    + "**このまま挿入すると Ghost Voice 自身へ入る可能性があります。**")
        }
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

    /// **活性が切り替わってから、窓の並びが入れ替わるまでの整定時間。**
    ///
    /// **これは決めごとであって要件値ではない。** 実測したのは
    /// 「入れ替わりに 24〜32 ms 掛かった」ことだけである
    /// （2026-08-15 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2 / n=3）。
    /// 観測した最大の約 5 倍を取ってある。
    ///
    /// **負荷下での分布は未実測である**（正本 §13 の V-43）。
    /// 外しても失うのは再挿入 1 回ぶんの体感 0.15 秒であり、**発話は失われない**
    /// ——足りなければ再挿入が Ghost Voice 自身へ入るが、
    /// そのときは履歴からコピーで取り出せる（縮退は残っている）。
    ///
    /// - Note: **PTT の経路には 1 ms も乗らない。** ここを通るのは
    ///   利用者が履歴画面から再挿入を押したときだけである。
    static let frontmostSettle: Duration = .milliseconds(150)

    /// 前面が戻るのを待った結果。
    enum FocusReturn: Sendable, Equatable {
        /// 別のアプリが前面に立った。**掛かった時間つき。**
        case returned(elapsed: Duration)
        /// 期限までに戻らなかった。**このまま挿入すると Ghost Voice 自身へ入りうる。**
        case timedOut(elapsed: Duration)
    }

    /// **別のアプリが前面に立つまで**待つ。
    ///
    /// `NSApp.isActive == false` を待つのでは足りない（型の doc の実測）。
    /// 非活性になってから最前面が入れ替わるまでに、実測で約 26 ms の隙がある。
    ///
    /// - Returns: どう終わったか。**呼び出し側は待つのをやめない**——
    ///   戻らなかったときに再挿入をやめると、`.notInserted` の発話の唯一の出口が
    ///   消える（正本 §14.4）。**期限まで待って、それでも進む。**
    ///   返り値は「戻らなかったこと」を利用者と検証へ伝えるためにある。
    /// - Parameter poll: 照会の間隔。**5 ms は決めごとであって実測値ではない**
    ///   （実測したのは「入れ替わりに約 26 ms 掛かる」ことだけである）。
    ///   窓を閉じるときにしか通らない経路なので、細かくても費用は無視できる。
    static func waitUntilAnotherAppIsFrontmost(
        timeout: Duration, poll: Duration = .milliseconds(5)
    ) async -> FocusReturn {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let started = ContinuousClock.now
        let deadline = started + timeout
        while ContinuousClock.now < deadline {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if let frontmost, frontmost != ownProcessIdentifier {
                return .returned(elapsed: .now - started)
            }
            try? await Task.sleep(for: poll)
        }
        return .timedOut(elapsed: .now - started)
    }
}

extension Duration {
    /// 診断の 1 行に出すためのミリ秒。
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

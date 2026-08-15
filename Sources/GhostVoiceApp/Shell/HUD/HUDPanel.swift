import AppKit
import SwiftUI

/// notch へ出す window。**`RunLoopEntry` が無いと作れない。**
///
/// ## なぜ鍵を要求するか（実測に基づく禁止）
///
/// `NSApplication.run()` を呼ぶ**前**に window を `orderFrontRegardless()` すると、
/// AppKit が `finishLaunching` の時点でアプリを**活性化する**。
/// `setActivationPolicy(.accessory)` を先に呼んでいても、`.nonactivatingPanel` でも、
/// `canBecomeKey == false` でも防げない（`core-api-and-hud.md` B-3 の実測）。
/// 活性化すると `SystemAccessibility.frontmostProcessIdentifier()` が拾う最前面 pid が
/// **Ghost Voice 自身**になり、**挿入先が壊れる。**
///
/// **禁止を注意書きではなく構造で守る。** この型を作れるのは `RunLoopEntry` を
/// 受け取れる場所＝`AppSurfaceFactory` の中だけであり、工場が呼ばれるのは
/// `LaunchSequence.enterRunLoop`（`NSApp.run()` のイベントループが回り始めた後）だけである。
@MainActor
final class HUDPanel {

    private let panel: NSPanel
    private let model = HUDModel()
    private var placement: HUDPlacement
    /// 最後に設定した矩形。**変わっていなければ `setFrame` を呼ばない**
    /// （メインスレッドの仕事を暫定テキストの更新回数だけ増やさないため）。
    ///
    /// - Note: **表示が変わっても窓は動かない**（`HUDPlacement.windowFrame` は
    ///   どの表示でも収まる固定寸法である）。ここが変わるのは**画面構成が変わったときだけ**。
    private var currentFrame: CGRect

    /// - Parameter entry: `NSApplication.run()` が始まった後であることの証。
    init(_ entry: RunLoopEntry, placement: HUDPlacement) {
        self.placement = placement
        let frame = placement.windowFrame
        self.currentFrame = frame

        panel = NSPanel(
            contentRect: frame,
            styleMask: HUDWindowContract.styleMask,
            backing: .buffered,
            defer: false)
        panel.isOpaque = HUDWindowContract.isOpaque
        // **背景は透明にする。** 窓は島より大きく（`HUDIslandMetrics.maximumSize`）、
        // **島の外はメニューバーが透けて見えなければならない**（`HUDContentView`）。
        panel.backgroundColor = .clear
        panel.hasShadow = HUDWindowContract.hasShadow
        panel.ignoresMouseEvents = HUDWindowContract.ignoresMouseEvents
        panel.hidesOnDeactivate = HUDWindowContract.hidesOnDeactivate
        panel.isMovable = HUDWindowContract.isMovable
        panel.level = HUDWindowContract.level
        panel.animationBehavior = HUDWindowContract.animationBehavior
        panel.collectionBehavior = HUDWindowContract.collectionBehavior
        // **メニューバーの帯に居る間も隠れない。**
        panel.isReleasedWhenClosed = false

        model.notchBandHeight = placement.notchBandHeight
        model.isAttachedToScreenTop = placement.anchor == .notch
        model.islandSize = placement.islandSize(for: .hidden)

        let hosting = NSHostingView(rootView: HUDContentView(model: model))
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    /// **`kCGWindowLayer` が 0 でないこと**を外から確かめるための値（検査と診断のため）。
    var windowLevelRawValue: Int { panel.level.rawValue }

    /// **検査のための覗き口。** 窓が実際に order-in されているか。
    var isVisibleForTests: Bool { panel.isVisible }

    /// 表示を差し替える。**変わっていなければ何もしない。**
    ///
    /// **窓は動かさない。** 動くのは島（SwiftUI の中の矩形 1 つ）だけである。
    func render(_ display: HUDDisplay) {
        guard model.display != display else { return }
        let wasVisible = model.display.isVisible
        // **出し入れの瞬間だけアニメーションを切る。** 出す前の大きさから伸びる様子は
        // 窓が画面に無い間に起きるので誰も見ないうえ、次に出したとき前の発話の大きさから
        // 動き出して見える。
        model.animatesShape = wasVisible && display.isVisible
        model.display = display

        guard display.isVisible else {
            panel.orderOut(nil)
            if wasVisible { noteWindowState("引っ込めました") }
            return
        }

        model.islandSize = placement.islandSize(for: display)
        // **`makeKeyAndOrderFront` は使わない。** あちらはキーウィンドウにしてしまう。
        panel.orderFrontRegardless()
        if !wasVisible { noteWindowState("出しました") }
    }

    /// **出し入れの瞬間だけ、窓の実際の姿を 1 行で言う。**
    ///
    /// 2026-08-15 の実機欠陥では、**窓は作られていたのに一度も order-in されておらず、
    /// それを示す手がかりがログに 1 行も無かった。** 「出したつもり」と「本当に出た」を
    /// 外から区別できる唯一の行がこれである。
    ///
    /// **中身（暫定テキスト・発話）は 1 文字も含めない**（FR-12 / NFR-V2）。
    /// **表示の切り替わりでしか呼ばない**ので、暫定テキストの更新回数では増えない。
    private func noteWindowState(_ what: String) {
        AppDiagnostics.note(
            "[HUD] 窓を\(what): 矩形 \(Int(panel.frame.minX)),\(Int(panel.frame.minY)) "
                + "\(Int(panel.frame.width))x\(Int(panel.frame.height)) "
                + "/ 島 \(Int(model.islandSize.width))x\(Int(model.islandSize.height)) "
                + "/ level \(panel.level.rawValue) "
                + "/ 可視 \(panel.isVisible) / 画面 \(panel.screen == nil ? "なし" : "あり")")
    }

    /// ディスプレイ構成が変わったとき（抜き差し・配置変更）に呼ぶ。
    func relocate(to placement: HUDPlacement) {
        self.placement = placement
        model.notchBandHeight = placement.notchBandHeight
        model.isAttachedToScreenTop = placement.anchor == .notch
        // **移した先で形が伸び縮みして見えないようにする**（座標が変わっただけである）。
        model.animatesShape = false
        model.islandSize = placement.islandSize(for: model.display)
        let frame = placement.windowFrame
        // **変わっていなければ `setFrame` を呼ばない**（通知は座標が変わらなくても届く）。
        guard frame != currentFrame else { return }
        currentFrame = frame
        panel.setFrame(frame, display: model.display.isVisible)
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

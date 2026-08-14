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
    private var currentFrame: CGRect

    /// - Parameter entry: `NSApplication.run()` が始まった後であることの証。
    init(_ entry: RunLoopEntry, placement: HUDPlacement) {
        self.placement = placement
        let frame = placement.panelFrame(
            width: HUDMetrics.compactWidth, contentHeight: HUDMetrics.contentHeight)
        self.currentFrame = frame

        panel = NSPanel(
            contentRect: frame,
            styleMask: HUDWindowContract.styleMask,
            backing: .buffered,
            defer: false)
        panel.isOpaque = HUDWindowContract.isOpaque
        // **背景は透明にする。** 切り欠きの左右はメニューバーが透けて見えなければならない
        // （黒く塗るのは切り欠きの幅の中だけ。`HUDContentView`）。
        panel.backgroundColor = .clear
        panel.hasShadow = HUDWindowContract.hasShadow
        panel.ignoresMouseEvents = HUDWindowContract.ignoresMouseEvents
        panel.hidesOnDeactivate = HUDWindowContract.hidesOnDeactivate
        panel.isMovable = HUDWindowContract.isMovable
        panel.level = HUDWindowContract.level
        panel.collectionBehavior = HUDWindowContract.collectionBehavior
        // **メニューバーの帯に居る間も隠れない。**
        panel.isReleasedWhenClosed = false

        model.notchBandHeight = placement.notchBandHeight
        model.notchBandWidth = placement.notchBandWidth

        let hosting = NSHostingView(rootView: HUDContentView(model: model))
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    /// **`kCGWindowLayer` が 0 でないこと**を外から確かめるための値（検査と診断のため）。
    var windowLevelRawValue: Int { panel.level.rawValue }

    /// 表示を差し替える。**変わっていなければ何もしない。**
    func render(_ display: HUDDisplay) {
        guard model.display != display else { return }
        model.display = display

        guard display.isVisible else {
            panel.orderOut(nil)
            return
        }

        let frame = placement.panelFrame(
            width: HUDMetrics.width(for: display), contentHeight: HUDMetrics.contentHeight)
        if frame != currentFrame {
            currentFrame = frame
            panel.setFrame(frame, display: false)
        }
        // **`makeKeyAndOrderFront` は使わない。** あちらはキーウィンドウにしてしまう。
        panel.orderFrontRegardless()
    }

    /// ディスプレイ構成が変わったとき（抜き差し・配置変更）に呼ぶ。
    func relocate(to placement: HUDPlacement) {
        self.placement = placement
        model.notchBandHeight = placement.notchBandHeight
        model.notchBandWidth = placement.notchBandWidth
        let frame = placement.panelFrame(
            width: HUDMetrics.width(for: model.display), contentHeight: HUDMetrics.contentHeight)
        currentFrame = frame
        panel.setFrame(frame, display: model.display.isVisible)
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

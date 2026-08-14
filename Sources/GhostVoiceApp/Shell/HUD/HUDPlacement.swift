import CoreGraphics
import Foundation

/// **HUD をどの画面のどこへ置くか。** 純粋な値の変換であり、`NSScreen` を一切触らない。
///
/// FR-3（表示先は常に内蔵ディスプレイ）と、要件定義書 §4.3（notch 非搭載機では
/// フォールバック表示）の両方をここで決める。
public struct HUDPlacement: Sendable, Equatable {

    /// どこへ吸い付くか。
    public enum Anchor: Sendable, Equatable {
        /// **切り欠きの直下へ張り出す。** 上端は画面の一番上（`frame.maxY`）。
        case notch
        /// **メニューバーの直下。** 上端は `visibleFrame.maxY`。
        ///
        /// notch 非搭載機と、内蔵が見つからない構成（クラムシェル）で使う。
        /// **メニューバーより下なので、アプリのメニュー項目もステータス項目も隠さない。**
        case belowMenuBar
    }

    /// 出す先の `NSScreenNumber`。
    public let displayID: UInt32
    public let anchor: Anchor
    /// 切り欠きの矩形。`anchor == .notch` のときだけ非 nil。
    public let notchRect: CGRect?
    /// パネルの上辺の y（グローバル座標）。
    public let topEdgeY: CGFloat
    /// パネルの中心の x。notch があればその中心、無ければ可視領域の中心。
    public let centerX: CGFloat
    /// 出す先の画面の全体。**はみ出さないための箍としてだけ使う。**
    public let screenFrame: CGRect
    /// **内蔵ディスプレイへ出せているか。** 偽なら FR-3 を満たせていない（クラムシェル）。
    public let isOnBuiltInDisplay: Bool

    /// 切り欠きの帯の高さ（`anchor == .notch` のとき `safeAreaInsets.top`。それ以外は 0）。
    public var notchBandHeight: CGFloat { notchRect?.height ?? 0 }
    /// 切り欠きの幅（`anchor == .notch` のときだけ意味を持つ）。
    public var notchBandWidth: CGFloat { notchRect?.width ?? 0 }

    /// **表示先を決める。**
    ///
    /// | 問い | 使うもの |
    /// |---|---|
    /// | どの画面か（FR-3） | `isBuiltIn`（= `CGDisplayIsBuiltin`）。**無ければ主ディスプレイ、それも無ければ先頭** |
    /// | その画面に notch があるか（形の分岐） | `notchRect != nil` |
    ///
    /// - Important: **内蔵が無いとき（クラムシェル）に nil を返さない。**
    ///   FR-3 は物理的に満たせないが、**何も出さないと利用者は録音中かどうかを知る手段を失う**
    ///   （このアプリはまだメニューバー項目を持たない）。基本設計書 §8.1.1 の候補 (a) を採り、
    ///   **主ディスプレイのメニューバー直下**へ出す。`isOnBuiltInDisplay` が偽になるので、
    ///   呼び手はそれと判る。
    /// - Returns: 画面が 1 枚も無ければ nil（**そのときだけ HUD を出さない**）。
    public static func resolve(screens: [HUDScreenSnapshot]) -> HUDPlacement? {
        let builtIn = screens.first { $0.isBuiltIn }
        // **内蔵が最優先。** 外部が主でも内蔵へ出す（FR-3）。
        guard let target = builtIn ?? screens.first(where: { $0.isMain }) ?? screens.first else {
            return nil
        }

        if let notch = target.notchRect {
            return HUDPlacement(
                displayID: target.displayID,
                anchor: .notch,
                notchRect: notch,
                // **`frame.maxY` を使う**（`visibleFrame.maxY` ではない）。
                // 実測で両者は 1 pt ずれる（1169 と 1130）。切り欠きと連続させるには
                // 画面の一番上から始めるほうが正しい。
                topEdgeY: target.frame.maxY,
                centerX: notch.midX,
                screenFrame: target.frame,
                isOnBuiltInDisplay: target.isBuiltIn)
        }

        return HUDPlacement(
            displayID: target.displayID,
            anchor: .belowMenuBar,
            notchRect: nil,
            // **メニューバーの下端。** ここより上へ出すとメニュー項目を隠す。
            topEdgeY: target.visibleFrame.maxY,
            centerX: target.visibleFrame.midX,
            screenFrame: target.frame,
            isOnBuiltInDisplay: target.isBuiltIn)
    }

    /// 起動時に 1 行で言うためのもの。**発話は 1 文字も含まない**（FR-12 / NFR-V2）。
    public var diagnosticDescription: String {
        let where_ =
            anchor == .notch
            ? "切り欠きの直下（notch \(rectText(notchRect ?? .zero))）" : "メニューバーの直下"
        let display = isOnBuiltInDisplay ? "内蔵ディスプレイ" : "外部ディスプレイ"
        return "表示先: \(display)(id \(displayID)) / \(where_) / 上辺 y=\(topEdgeY) 中心 x=\(centerX)"
    }

    private func rectText(_ rect: CGRect) -> String {
        "x \(rect.minX), y \(rect.minY), w \(rect.width), h \(rect.height)"
    }

    /// パネルの矩形を作る。
    ///
    /// - Parameters:
    ///   - width: 内容が欲しがる幅。**切り欠きより狭くはしない**（`anchor == .notch` のとき）。
    ///   - contentHeight: 切り欠きの帯より**下**に置く中身の高さ。
    /// - Returns: 画面からはみ出さないように寄せた矩形。
    public func panelFrame(width: CGFloat, contentHeight: CGFloat) -> CGRect {
        let minimumWidth = max(notchBandWidth, 1)
        let maximumWidth = max(screenFrame.width, minimumWidth)
        let resolvedWidth = min(max(width, minimumWidth), maximumWidth)
        let height = notchBandHeight + max(contentHeight, 0)

        var originX = centerX - resolvedWidth / 2
        // **はみ出させない。** 外部ディスプレイが左にある構成では `frame.minX` が負になる。
        originX = min(max(originX, screenFrame.minX), screenFrame.maxX - resolvedWidth)

        return CGRect(x: originX, y: topEdgeY - height, width: resolvedWidth, height: height)
    }
}

import CoreGraphics
import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// **1 枚のディスプレイについて、HUD の配置に要る事実だけを写し取った値。**
///
/// ## なぜ `NSScreen` をそのまま使わないか
///
/// `NSScreen` は**この機体の実際のディスプレイ構成でしか作れない**。
/// つまり `NSScreen` を直接読む形で書くと、
///
/// - notch 非搭載の内蔵ディスプレイ（MacBook Air M1 等。**手元に機体が無い**）
/// - 外部ディスプレイだけの構成（クラムシェル。蓋を閉じる操作が要る）
/// - 内蔵が主ディスプレイでない構成
///
/// のいずれも**検査できない。** これらは調査 `core-api-and-hud.md` 付録の U-4 / U-5 /
/// U-6 として未実測のまま残っている項目であり、**未実測だからこそコードの側で
/// 破綻しないことを固定しておく必要がある。**
///
/// そこで「`NSScreen` から値を写す」ところだけを `current()` に閉じ込め、
/// **配置の判断（`HUDPlacement`）は純粋な値の変換にした。** 判断はすべて検査できる。
///
/// - Note: 値はすべて **AppKit のグローバル座標**（原点は主ディスプレイの左下、y は上向き）。
public struct HUDScreenSnapshot: Sendable, Equatable {

    /// `NSScreenNumber`。`CGDisplayIsBuiltin` に渡すもの。
    public let displayID: UInt32

    /// **内蔵ディスプレイか**（`CGDisplayIsBuiltin != 0`）。
    ///
    /// - Important: **`localizedName` で判定してはならない**（ローカライズされる。
    ///   実測値は `"Built-in Retina Display"` / `"DELL S2722QC"` だった）。
    ///   **`safeAreaInsets.top > 0` でも判定してはならない**——notch 非搭載の内蔵機で
    ///   偽になる（基本設計書 §8.1 の訂正）。
    public let isBuiltIn: Bool

    /// 主ディスプレイか（`CGDisplayIsMain != 0`。メニューバーが出ている側）。
    ///
    /// **内蔵の判定には使わない。** 実測で `NSScreen.main != NSScreen.screens.first` であり、
    /// 外部を主にしていれば外部が主ディスプレイになる。
    public let isMain: Bool

    /// 画面全体。メニューバーの帯を含む。
    public let frame: CGRect

    /// メニューバーと Dock を除いた領域。**フォールバック表示の上辺はここを使う。**
    public let visibleFrame: CGRect

    /// `safeAreaInsets.top`。**notch 機ではメニューバーの高さそのもの**（実測 38.0）で、
    /// `NSStatusBar.system.thickness`（22.0）ではない。notch 非搭載機では 0.0。
    public let safeAreaTop: CGFloat

    /// `auxiliaryTopLeftArea` の幅。**notch を持たない画面では nil。**
    public let auxiliaryTopLeftWidth: CGFloat?

    /// `auxiliaryTopRightArea` の幅。**notch を持たない画面では nil。**
    public let auxiliaryTopRightWidth: CGFloat?

    public init(
        displayID: UInt32,
        isBuiltIn: Bool,
        isMain: Bool,
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftWidth: CGFloat?,
        auxiliaryTopRightWidth: CGFloat?
    ) {
        self.displayID = displayID
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
    }

    /// **切り欠き（notch）の矩形。** 持たない画面では nil。
    ///
    /// 実測（2026-08-14 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2）:
    ///
    /// ```
    /// notch.width  = frame.width - auxL.width - auxR.width   // 1800 - 791 - 788 = 221
    /// notch.height = safeAreaInsets.top                       // 38
    /// notch.minX   = frame.minX + auxL.width                  // 791
    /// notch.maxY   = frame.maxY                               // 1169
    /// ```
    ///
    /// 端数なくぴったり足し合う（791 + 221 + 788 = 1800）ので「左右の可視領域の隙間 = notch」で正しい。
    ///
    /// **3 つの条件を全部要求する**（片方だけの nil / `safeAreaTop == 0` / 幅が 0 以下）。
    /// notch 非搭載機と外部ディスプレイでは `auxiliaryTop*Area` が nil を返すことを実測して
    /// いるが、**「片方だけ nil」や「足し合わない」場合の実測は無い。**
    /// 未実測の形が来たときは notch 無しへ倒す——**誤って倒しても失うのは見た目だけ**で、
    /// 逆（notch があると誤認して切り欠きへ描く）は表示が消える。
    public var notchRect: CGRect? {
        guard let left = auxiliaryTopLeftWidth, let right = auxiliaryTopRightWidth else {
            return nil
        }
        guard safeAreaTop > 0 else { return nil }
        let width = frame.width - left - right
        guard width > 0 else { return nil }
        return CGRect(
            x: frame.minX + left,
            y: frame.maxY - safeAreaTop,
            width: width,
            height: safeAreaTop)
    }
}

#if canImport(AppKit)
    extension HUDScreenSnapshot {

        /// **`NSScreen` を読む唯一の場所。** ここ以外に `NSScreen` を触るコードを増やさないこと。
        ///
        /// 増やすと、そのぶんだけ「この機体の構成でしか動かない判断」が散らばる。
        @MainActor
        public static func current() -> [HUDScreenSnapshot] {
            NSScreen.screens.map(HUDScreenSnapshot.init(_:))
        }

        @MainActor
        public init(_ screen: NSScreen) {
            let id =
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value
            self.init(
                displayID: id ?? 0,
                // **`CGDisplayIsBuiltin` が唯一の根拠である**（実測: 内蔵 1 / 外部 0）。
                // ID が取れなかったときは「内蔵ではない」へ倒す——内蔵と誤認すると
                // 外部ディスプレイへ出したまま「内蔵に出した」と思い込む。
                isBuiltIn: id.map { CGDisplayIsBuiltin($0) != 0 } ?? false,
                isMain: id.map { CGDisplayIsMain($0) != 0 } ?? false,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width,
                auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width)
        }
    }
#endif

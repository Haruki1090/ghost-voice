import AppKit
import CoreGraphics
import Foundation

/// **HUD の window に課す約束。** 値だけを持ち、window を作らない——だから検査できる。
///
/// ここに並ぶ 1 つ 1 つが、外すと**挿入先が壊れる**か**利用者の作業を妨げる**かのどちらかである。
/// 実測の出どころは調査 `core-api-and-hud.md` B-3 / B-4（2026-08-14 / MacBook Pro Mac15,3 /
/// M3 / macOS 26.5.2）。
public enum HUDWindowContract {

    /// **ウィンドウレベル = `.statusBar + 1`（実測で 26）。**
    ///
    /// 実測した z 順:
    ///
    /// | 対象 | layer |
    /// |---|---|
    /// | メニューバー本体 | 24 |
    /// | メニューバー右側の項目（コントロールセンター等） | 25（= `.statusBar`） |
    /// | マイク／カメラのプライバシーインジケータ（緑ドット） | 2147483630 |
    /// | `.maximumWindow` | 2147483631 |
    ///
    /// - Important: **0 にしてはならない。** `SystemAccessibility.frontmostProcessIdentifier()`
    ///   は `kCGWindowLayer == 0` の最前面ウィンドウの pid を見る。0 にした瞬間、
    ///   **挿入先が Ghost Voice 自身になる。**
    /// - Important: **`.maximumWindow` は採らない。** 緑ドット（2147483630）より前面に出てしまい、
    ///   **録音中にマイク使用を示す表示を隠しうる。**
    public static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    /// `.borderless` + `.nonactivatingPanel`。
    ///
    /// **この組み合わせなら `canBecomeKey` / `canBecomeMain` は既定で false である**（実測）。
    /// サブクラスで override する必要は無い。
    public static let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]

    /// 全 Space に出し、他アプリのフルスクリーンの上にも出し、⌘` の巡回には入れない。
    ///
    /// - Note: **効きは未実測**（V-21）。Space の切り替えとフルスクリーン化は
    ///   利用者の実機でしか確かめられない。README の手順に入れてある。
    public static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]

    /// **他アプリが前面でも消えない。** これを false（既定）にすると、
    /// Ghost Voice は決して活性化しないので HUD が一度も見えない。
    public static let hidesOnDeactivate = false

    /// **クリックも奪わない。**
    ///
    /// 窓は島より大きい（`HUDIslandMetrics.maximumSize`）ので、**島の外はすべて透明**である。
    /// 透明でもマウスを受けると**メニューバーが押せなくなる。**
    ///
    /// さらに**島そのものがメニューバーの帯の一部を覆う**（`HUDIslandMetrics` の
    /// 「引き換えにしたもの」）。ここが true である限り、**隠れている項目もそのまま押せる。**
    public static let ignoresMouseEvents = true

    /// 島の外を透かすので不透明にはできない。
    public static let isOpaque = false

    /// notch に固定する。
    public static let isMovable = false

    /// 影は落とさない（メニューバーの上に影が出る）。
    public static let hasShadow = false

    /// **窓の出し入れを AppKit にアニメーションさせない。**
    ///
    /// `NSPanel` の既定（`.utilityWindow`）は order-in のたびに**縮小＋淡入**を掛ける。
    /// **実測（2026-08-15 / Mac15,3 / M3 / macOS 26.5.2 / `--hud-check`）**では、
    /// その途中の窓が `CGWindowListCopyWindowInfo` に
    ///
    /// ```
    /// 641,0 521x106 alpha 1.0        ← 落ち着いた姿
    /// 646,1 511x104 alpha 0.0005     ← 淡入の途中。**y が 1 になっている**
    /// ```
    ///
    /// として現れた。**y が 1 になるのは、島が画面の一番上から 1 pt 離れるということ**である。
    /// 切り欠きと一体に見せる形では、この 1 pt の隙間が「浮いた板」として目に付く。
    ///
    /// - Note: 形が変わるときのアニメーションは**別物**である（`HUDIslandMetrics.expansionSeconds`。
    ///   SwiftUI の中で島の矩形だけが動く）。ここで止めるのは**窓そのものの出し入れ**だけ。
    public static let animationBehavior: NSWindow.AnimationBehavior = .none
}

/// 音量バーの見せ方。**純粋な変換。**
public enum HUDLevelMeter {

    /// 満振れとみなす RMS。
    ///
    /// - Important: **実測値ではない。** 肉声の RMS がどの範囲に収まるかは測っていない
    ///   （マイクが要る）。**バーが振れるかどうかは利用者が目視で確かめる**
    ///   （README の HUD 確認手順）。振れ幅が合わなければこの数だけを直せばよい。
    public static let fullScaleRMS: Float = 0.2

    /// 0.0〜1.0 に丸めた振れ幅。
    public static func normalized(_ level: Float) -> Float {
        guard level > 0, fullScaleRMS > 0 else { return 0 }
        return min(1, level / fullScaleRMS)
    }

    /// `count` 本のバーのうち、何本目までが点くか（0〜count）。
    public static func litBars(_ level: Float, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int((normalized(level) * Float(count)).rounded())
    }
}

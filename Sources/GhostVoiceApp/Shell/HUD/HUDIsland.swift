import CoreGraphics
import Foundation
import SwiftUI

/// **島（ダイナミックアイランド風の HUD）の寸法。**
///
/// ## この型が持つ値は 1 つ残らず「決めごと」である
///
/// **実測値は 1 つも入っていない。** 実測値（切り欠きの矩形・帯の高さ・画面の矩形）は
/// `HUDScreenSnapshot` が画面から取り、`HUDPlacement` が運ぶ。ここが決めるのは
/// **「その実測値に対してどれだけ食み出すか・どれだけ丸めるか・どれだけの速さで変わるか」**
/// だけである。混ぜないこと。
///
/// ## 形（なぜ「帯」ではなく「島」なのか）
///
/// 以前の形は**切り欠きと同じ幅の帯が下へ伸びる**ものだった。利用者の言葉では
/// 「部分的に何か突き出して大きくなっている感じ」であり、**1 枚の面には見えない。**
///
/// 島は**切り欠きより左右に広く、切り欠きの帯そのものも黒く塗る。**
///
/// ```
///        ┌ 画面の上辺（frame.maxY）
///        ↓
///  ─────╮                       ╭─────   ← 逆アール。メニューバーの帯へ滑らかに繋ぐ
///       │  ┌───────────┐        │        （切り欠きはこの黒の中に完全に埋まる）
///       │  │  切り欠き  │        │
///       │  └───────────┘        │
///       │      中  身           │        ← 中身はすべて帯より下
///       ╰───────────────────────╯        ← 角丸（決めごと）
/// ```
///
/// ## **切り欠きに画素があってもなくても成立する**（V-20 が未実測のままでよい理由）
///
/// 島は切り欠きの**周囲（左右と下）を黒く塗る。**
///
/// - 画素が**ある**なら、切り欠きの中も黒く塗られて周囲と繋がる。
/// - 画素が**無い**なら、切り欠きの中は物理的に黒いだけである——**周囲が黒いので同じに見える。**
///
/// どちらでも「1 枚の黒い面」になる。**したがって V-20 の結果で実装は変わらない。**
/// 中身（文字・音量バー）は帯より下にしか置かないので、画素が無くても読めなくならない。
///
/// ## 引き換えにしたもの（**承知の上の判断**）
///
/// 切り欠きの左右はメニューバーが描かれている帯そのものである（実測 §7.2）。
/// **島はその一部を覆う。** 覆う量は左右それぞれ最大で
/// `(expandedIslandWidth - 切り欠きの幅) / 2` = 実測 221 pt に対して **149.5 pt** である。
///
/// - **クリックは奪わない**（`HUDWindowContract.ignoresMouseEvents == true`）。
///   隠れている項目もそのまま押せる。
/// - **出ているのは発話のあいだだけ**である（`.idle` では `orderOut`）。
/// - 実測 1800 pt 幅の画面で、メニュー項目は左から・ステータス項目は右から並ぶ。
///   島が覆うのは画面中央の 520 pt（x 641.5..1161.5）であり、**時計もコントロールセンターも
///   アプリのメニューも通常はここに来ない。** ただし**項目が非常に多いアプリでは重なりうる。**
public enum HUDIslandMetrics {

    // MARK: - 幅（決めごと）

    /// **切り欠きの左右へ食み出す量。** ここが 0 だと「帯が突き出している」形へ戻る。
    ///
    /// - Note: 逆アール（`screenEdgeCornerRadius`）は幅の内側に食い込むので、
    ///   画面の上辺で見える食み出しはこの値、帯より下で見える食み出しは
    ///   `shoulder - screenEdgeCornerRadius` になる。
    public static let shoulder: CGFloat = 40

    /// 畳んでいるときの幅の下限。**切り欠きが細い機体でも島に見える大きさ。**
    public static let minimumCompactWidth: CGFloat = 300

    /// 広げたときの幅の下限。
    ///
    /// **520 pt は「実測 1800 pt の画面で左右にメニューバーを 640 pt ずつ残す」大きさ**である
    /// （上の「引き換えにしたもの」を参照）。
    public static let minimumExpandedWidth: CGFloat = 520

    // MARK: - 高さ（決めごと）

    /// 畳んでいるときの、**切り欠きの帯より下**の高さ。
    public static let compactContentHeight: CGFloat = 44

    /// 広げたときの、**切り欠きの帯より下**の高さ。
    ///
    /// `volatileLineLimit` 行ぶんの文字（`volatileFontSize` pt）と上下の余白が収まる。
    public static let expandedContentHeight: CGFloat = 68

    /// **暫定テキストを何行まで見せるか。**
    ///
    /// 利用者の申告は「1 行分しか見えない」であり、以前は 2 行だった。
    /// **上限を置くのは、長い発話で画面を覆わないためである**——行数を無制限にすると
    /// 高さが発話の長さで変わり、`.volatile` の更新のたびに窓の大きさが動くことになる
    /// （メインスレッドの予算に直に効く。§7.4）。
    public static let volatileLineLimit = 3

    /// 暫定テキストと告知の文字の大きさ。
    public static let volatileFontSize: CGFloat = 12

    // MARK: - 角（決めごと）

    /// **画面の上辺へ繋ぐ逆アールの半径**（切り欠きへ吸い付いているときだけ）。
    ///
    /// - Important: **切り欠きそのものの角丸半径は実測していない。**
    ///   島は切り欠きを覆うので、**見えている角はすべて島が描いたものである**——
    ///   したがって切り欠きの半径と一致させる必要が無い（一致させようがない）。
    public static let screenEdgeCornerRadius: CGFloat = 12

    /// 下側の角丸の半径。
    public static let bottomCornerRadius: CGFloat = 22

    /// 上側の角丸の半径（**切り欠きが無く、メニューバーの下に浮かべるとき**だけ使う）。
    public static let floatingTopCornerRadius: CGFloat = 18

    /// 中身を左右から逃がす量。**逆アールの内側に文字が食い込まないための余白。**
    public static func contentInset(isAttachedToScreenTop: Bool) -> CGFloat {
        isAttachedToScreenTop ? screenEdgeCornerRadius + 10 : 14
    }

    // MARK: - 変わる速さ（決めごと）

    /// **形が変わる時間（秒）。**
    ///
    /// - Important: **要件値ではない。** 上限は「メインスレッドを塞がないこと」だけで決まる
    ///   （実測: メインを塞ぐと `CGEventTap` の配送が p50 0.045 ms → 12.8 ms へ悪化する）。
    ///   ここで動くのは**矩形 1 つの大きさ**であり、**形が変わるときにしか走らない**
    ///   （暫定テキストの更新では走らない。`HUDContentView` の `animation(_:value:)` が
    ///   見るのは `islandSize` だけである）。
    public static let expansionSeconds: Double = 0.22

    // MARK: - 純粋な計算

    /// 畳んでいるときの島の幅。**必ず切り欠きより広い。**
    public static func compactWidth(notchWidth: CGFloat) -> CGFloat {
        max(minimumCompactWidth, max(notchWidth, 0) + 2 * shoulder)
    }

    /// 広げたときの島の幅。**畳んだときより狭くならない。**
    public static func expandedWidth(notchWidth: CGFloat) -> CGFloat {
        max(minimumExpandedWidth, compactWidth(notchWidth: notchWidth))
    }

    /// 表示に応じた島の幅。
    public static func width(for display: HUDDisplay, notchWidth: CGFloat) -> CGFloat {
        display.wantsWideLayout
            ? expandedWidth(notchWidth: notchWidth) : compactWidth(notchWidth: notchWidth)
    }

    /// 表示に応じた、**切り欠きの帯より下**の高さ。
    public static func contentHeight(for display: HUDDisplay) -> CGFloat {
        display.wantsWideLayout ? expandedContentHeight : compactContentHeight
    }

    /// 表示に応じた島の大きさ（帯を含む）。
    public static func size(for display: HUDDisplay, notchWidth: CGFloat, bandHeight: CGFloat)
        -> CGSize
    {
        CGSize(
            width: width(for: display, notchWidth: notchWidth),
            height: max(bandHeight, 0) + contentHeight(for: display))
    }

    /// **どの表示でも収まる大きさ。** 窓はこの大きさで作る。
    ///
    /// **窓を表示ごとに作り直さない**ことがここの目的である。窓は透明で
    /// クリックも透かすので、島より大きくても見た目にも操作にも出ない。
    /// 代わりに `setFrame` が**表示の変わり目で 1 度も走らなくなる**——
    /// 動くのは SwiftUI の中の矩形 1 つだけになる（メインスレッドの予算。§7.4）。
    public static func maximumSize(notchWidth: CGFloat, bandHeight: CGFloat) -> CGSize {
        CGSize(
            width: expandedWidth(notchWidth: notchWidth),
            height: max(bandHeight, 0) + max(compactContentHeight, expandedContentHeight))
    }
}

/// **島の輪郭。**
///
/// 切り欠きへ吸い付いているときは、上辺（画面の一番上）で左右へ最も広がり、
/// **逆アールでメニューバーの帯へ滑らかに繋がる。** 下側は普通の角丸。
///
/// 浮かべているとき（notch 非搭載機のフォールバック）は四隅とも普通の角丸にする。
struct HUDIslandShape: Shape {

    /// 画面の上辺へ繋ぐ逆アールの半径。**0 なら浮いている形**として描く。
    var screenEdgeRadius: CGFloat
    /// 浮いているときの上側の角丸。
    var floatingTopRadius: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard screenEdgeRadius > 0 else {
            return UnevenRoundedRectangle(
                topLeadingRadius: floatingTopRadius,
                bottomLeadingRadius: bottomRadius,
                bottomTrailingRadius: bottomRadius,
                topTrailingRadius: floatingTopRadius,
                style: .continuous
            ).path(in: rect)
        }

        let r = min(screenEdgeRadius, rect.width / 2)
        let b = min(bottomRadius, max(rect.width / 2 - r, 0), max(rect.height - r, 0))

        var path = Path()
        // 画面の上辺の左端 → 逆アールで島の左肩へ（**外側へ凹む**）。
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY + r),
            control: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY - b))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r + b, y: rect.maxY),
            control: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - r - b, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY - b),
            control: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY + r))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

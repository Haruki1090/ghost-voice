import CoreGraphics
import SwiftUI
import Testing

@testable import GhostVoiceApp

/// **島（ダイナミックアイランド風の HUD）の形と大きさ**（詳細設計書 §7.3）。
///
/// ## ここで検査できること・できないこと（線引き）
///
/// | 命題 | 検査できるか |
/// |---|---|
/// | **どの矩形に出るか**（窓・島） | **できる。** 純粋な計算なのでここで全部固定する |
/// | **どの level で・可視で出たか** | **できる**（`HUDWindowContractTests` / 実バンドルでの観測） |
/// | **切り欠きが島の黒の中に埋まる幅か** | **できる。** 「島の一番細いところ ＞ 切り欠きの幅」は数で言える |
/// | **形が変わる速さ・行数の上限・角丸の半径**（決めごと） | **値としては固定できる。** 妥当かどうかは目視 |
/// | **「1 枚の島に見えるか」** | **できない。** 実機の目視だけ（`--hud-check`） |
/// | **切り欠きの中に画素があるか**（V-20） | **できない。** ただし**どちらでも島に見える設計**なので結果で実装は変わらない |
@Suite("HUD の島（形・大きさ・決めごと）")
struct HUDIslandTests {

    /// **実測値そのもの**（2026-08-14 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2）。
    /// 切り欠きは x 791 / y 1131 / w 221 / h 38、画面の上辺は y 1169、中心は x 901.5。
    static let builtIn = HUDPlacementTests.builtInWithNotch
    /// **未実測の構成**（notch 非搭載の内蔵機）。
    static let noNotch = HUDPlacementTests.builtInWithoutNotch

    static let compact = HUDDisplay.recording(
        HUDRecording(level: 0.1, languageBadge: "日", volatileText: ""))
    static let expanded = HUDDisplay.recording(
        HUDRecording(level: 0.1, languageBadge: "日", volatileText: "あ"))

    // MARK: - 切り欠きを埋める（この設計の要）

    /// **島の一番細いところでも、切り欠きより左右へ食み出していること。**
    ///
    /// ここが崩れると、切り欠きの縁が黒の外へ出て「帯が突き出している」形へ戻る。
    /// 一番細いのは逆アールを過ぎたところ（幅 = 島の幅 − 逆アール × 2）である。
    @Test("島の一番細いところでも切り欠きより広い（左右に肩が残る）")
    func islandAlwaysOverhangsTheNotch() {
        for notchWidth in [CGFloat(0), 100, 221, 400, 900] {
            for width in [
                HUDIslandMetrics.compactWidth(notchWidth: notchWidth),
                HUDIslandMetrics.expandedWidth(notchWidth: notchWidth),
            ] {
                let narrowest = width - 2 * HUDIslandMetrics.screenEdgeCornerRadius
                #expect(
                    narrowest > notchWidth,
                    "切り欠き \(notchWidth) に対して島の一番細いところが \(narrowest) しかない")
            }
        }
    }

    /// 実測の切り欠き（221 pt）に対する肩の量。**決めごとがそのまま出る。**
    @Test("実測の切り欠きに対する肩は左右 28 pt（決めごと）")
    func shoulderOnTheMeasuredNotch() {
        let width = HUDIslandMetrics.compactWidth(notchWidth: 221)
        #expect(width == 301)  // max(300, 221 + 40 * 2)
        let narrowest = width - 2 * HUDIslandMetrics.screenEdgeCornerRadius
        #expect((narrowest - 221) / 2 == 28)
    }

    /// **中身は必ず切り欠きの帯より下に置ける。**
    /// ここが 0 以下になると、画素の無いかもしれない切り欠きの中へ文字が入る（V-20）。
    @Test("島の高さは切り欠きの帯より必ず高い")
    func contentAlwaysFitsBelowTheBand() {
        for display in [HUDDisplay.hidden, Self.compact, Self.expanded, .completed] {
            let size = Self.builtIn.notchRect.map { notch in
                HUDIslandMetrics.size(
                    for: display, notchWidth: notch.width, bandHeight: notch.height)
            }
            #expect(size != nil)
            #expect((size?.height ?? 0) - 38 > 0)
        }
    }

    // MARK: - 窓（表示が変わっても動かない）

    /// **窓は表示に依らず一定である。**
    ///
    /// これが崩れると `setFrame` が表示の変わり目ごとに走る。**動いてよいのは
    /// SwiftUI の中の島だけ**である（メインスレッドの予算。§7.4）。
    @Test("窓の矩形は表示が変わっても動かない")
    func windowFrameNeverMoves() throws {
        let placement = try #require(HUDPlacement.resolve(screens: [Self.builtIn]))
        let frame = placement.windowFrame
        // 実測の切り欠き（221 / 38）と決めごと（広げた幅 520 / 広げた中身 68）から。
        #expect(frame == CGRect(x: 641.5, y: 1063, width: 520, height: 106))
        // **上辺は画面の一番上**（切り欠きと連続させるため）。
        #expect(frame.maxY == 1169)
        // 中心は切り欠きの中心。
        #expect(frame.midX == 901.5)
    }

    /// **どの表示の島も窓に収まること。** はみ出すと島が切れて見える。
    @Test("どの表示の島も窓の中に収まる")
    func everyIslandFitsInsideTheWindow() throws {
        let placement = try #require(HUDPlacement.resolve(screens: [Self.builtIn]))
        let window = placement.windowFrame
        for display in [
            HUDDisplay.hidden, Self.compact, Self.expanded, .completed,
            .processing(.finalizing), .processing(.revising),
            .message(HUDMessage(text: "長い文言でも収まること", severity: .lost)),
        ] {
            let island = placement.islandSize(for: display)
            #expect(island.width <= window.width, "\(display) の島が窓より広い")
            #expect(island.height <= window.height, "\(display) の島が窓より高い")
        }
    }

    // MARK: - 形が変わる

    /// **ダイナミックアイランドの要点は形が変わることである。**
    /// 広がるのは幅だけではない（行数が増えるので高さも）。
    @Test("暫定テキストがあると幅も高さも広がり、無くなると戻る")
    func theIslandGrowsAndShrinks() throws {
        let placement = try #require(HUDPlacement.resolve(screens: [Self.builtIn]))
        let small = placement.islandSize(for: Self.compact)
        let large = placement.islandSize(for: Self.expanded)
        #expect(large.width > small.width)
        #expect(large.height > small.height)
        // 実測の切り欠き（221 / 38）＋ 決めごと。
        #expect(small == CGSize(width: 301, height: 82))
        #expect(large == CGSize(width: 520, height: 106))
        // **戻れること。** 片道だと縮まないまま居座る。
        #expect(placement.islandSize(for: Self.compact) == small)
    }

    /// **告知（エラー・終了待ち）も広げる。** 1 行では読み切れない文言がある。
    @Test("告知は広げた島で出す")
    func messagesUseTheExpandedIsland() throws {
        let placement = try #require(HUDPlacement.resolve(screens: [Self.builtIn]))
        let message = HUDDisplay.message(
            HUDMessage(text: "終了待ち: PTT キーを離してください（残り 9 秒）", severity: .info))
        #expect(placement.islandSize(for: message) == placement.islandSize(for: Self.expanded))
    }

    // MARK: - notch 非搭載機（未実測 / V-41）

    /// 帯が無い分だけ低くなるが、**幅は同じ決めごとで決まる。**
    @Test("notch 非搭載機では帯の無い島を浮かべる")
    func floatingIslandWithoutANotch() throws {
        let placement = try #require(HUDPlacement.resolve(screens: [Self.noNotch]))
        #expect(placement.anchor == .belowMenuBar)
        #expect(placement.islandSize(for: Self.compact) == CGSize(width: 300, height: 44))
        #expect(placement.islandSize(for: Self.expanded) == CGSize(width: 520, height: 68))
        // 窓はメニューバーの下端から下へ。**メニューバーへ食い込まない。**
        #expect(placement.windowFrame.maxY == 875)
        #expect(placement.windowFrame.height == 68)
    }

    /// **画面が島より狭くても、窓が画面の外へ出ないこと。**
    @Test("島より狭い画面でも窓は画面の中に収まる")
    func narrowScreenKeepsTheWindowOnScreen() throws {
        let narrow = HUDScreenSnapshot(
            displayID: 9, isBuiltIn: true, isMain: true,
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 455),
            safeAreaTop: 0, auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil)
        let placement = try #require(HUDPlacement.resolve(screens: [narrow]))
        let frame = placement.windowFrame
        #expect(frame.minX >= 0)
        #expect(frame.maxX <= 320)
        #expect(frame.width == 320)
    }

    // MARK: - 決めごと（**実測値ではない**）

    /// **決めごとを 1 箇所に集めて固定する。**
    ///
    /// ここが動いたら、動かした人が**目視でやり直す**（`--hud-check`）。
    /// **どれも実測値ではない**——実測値は切り欠きの矩形と帯の高さだけで、
    /// それは `HUDScreenSnapshot` が画面から取る。
    @Test("見た目の決めごとが動いていない")
    func theDecidedNumbersAreFixed() {
        #expect(HUDIslandMetrics.shoulder == 40)
        #expect(HUDIslandMetrics.minimumCompactWidth == 300)
        #expect(HUDIslandMetrics.minimumExpandedWidth == 520)
        #expect(HUDIslandMetrics.compactContentHeight == 44)
        #expect(HUDIslandMetrics.expandedContentHeight == 68)
        #expect(HUDIslandMetrics.volatileLineLimit == 3)
        #expect(HUDIslandMetrics.screenEdgeCornerRadius == 12)
        #expect(HUDIslandMetrics.bottomCornerRadius == 22)
        #expect(HUDIslandMetrics.floatingTopCornerRadius == 18)
        #expect(HUDIslandMetrics.expansionSeconds == 0.22)
    }

    /// **形が変わる時間は一瞬で終わること。**
    ///
    /// 上限は要件ではなく、**メインスレッドを塞がないという規律**から来ている
    /// （実測: メインを塞ぐと `CGEventTap` の配送が p50 0.045 ms → 12.8 ms へ悪化する）。
    /// 0.5 秒は**要件値ではない**——「暫定テキストの間引き（50 ms）が 10 回入るより短い」
    /// という目安である。
    @Test("形が変わる時間は 0.5 秒より短い（要件値ではない）")
    func expansionIsShort() {
        #expect(HUDIslandMetrics.expansionSeconds > 0)
        #expect(HUDIslandMetrics.expansionSeconds < 0.5)
    }

    /// **中身が逆アールの内側へ食い込まないこと。**
    @Test("中身の左右の余白は逆アールより広い")
    func contentClearsTheInverseCorner() {
        #expect(
            HUDIslandMetrics.contentInset(isAttachedToScreenTop: true)
                > HUDIslandMetrics.screenEdgeCornerRadius)
        #expect(HUDIslandMetrics.contentInset(isAttachedToScreenTop: false) > 0)
    }

    // MARK: - 輪郭

    /// **画面の上辺では左右いっぱいに広がり、そこから内側へ凹むこと**（逆アール）。
    /// 凹んでいないと、島が「画面の上辺から生えた四角い板」に見える。
    @Test("切り欠きへ吸い付く形は上辺で最も広く、そこから凹む")
    func attachedShapeHasInverseCorners() {
        let rect = CGRect(x: 0, y: 0, width: 520, height: 106)
        let path = HUDIslandShape(
            screenEdgeRadius: HUDIslandMetrics.screenEdgeCornerRadius,
            floatingTopRadius: HUDIslandMetrics.floatingTopCornerRadius,
            bottomRadius: HUDIslandMetrics.bottomCornerRadius
        ).path(in: rect)

        // 上辺の端まで届いている（＝画面の上辺で最も広い）。
        #expect(path.boundingRect.width == rect.width)
        #expect(path.boundingRect.minY == rect.minY)
        #expect(path.boundingRect.maxY == rect.maxY)
        // 上辺のすぐ下の左右の隅は**塗られていない**（凹んでいる）。
        #expect(!path.contains(CGPoint(x: 3, y: 6)))
        #expect(!path.contains(CGPoint(x: rect.maxX - 3, y: 6)))
        // 少し内側は塗られている。
        #expect(path.contains(CGPoint(x: 30, y: 6)))
        #expect(path.contains(CGPoint(x: rect.midX, y: 1)))
        // 下側の隅は角丸なので塗られていない。
        #expect(!path.contains(CGPoint(x: 14, y: rect.maxY - 1)))
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.maxY - 1)))
    }

    /// **切り欠きの帯の高さ（実測 38）の範囲すべてで、切り欠きの左右が塗られていること。**
    /// ここが空くと切り欠きの縁が見えて「突き出した帯」に戻る。
    @Test("切り欠きの帯の全高で、切り欠きの左右が黒く塗られている")
    func theBandIsPaintedOnBothSidesOfTheNotch() {
        let width = HUDIslandMetrics.compactWidth(notchWidth: 221)
        let rect = CGRect(
            x: 0, y: 0, width: width, height: 38 + HUDIslandMetrics.compactContentHeight)
        let path = HUDIslandShape(
            screenEdgeRadius: HUDIslandMetrics.screenEdgeCornerRadius,
            floatingTopRadius: HUDIslandMetrics.floatingTopCornerRadius,
            bottomRadius: HUDIslandMetrics.bottomCornerRadius
        ).path(in: rect)

        // 切り欠きは島の中央 221 pt。その 1 pt 外側を、帯の高さ全体で見る。
        let notchLeft = rect.midX - 110.5
        let notchRight = rect.midX + 110.5
        for y in stride(from: CGFloat(1), through: 38, by: 1) {
            #expect(path.contains(CGPoint(x: notchLeft - 1, y: y)), "y=\(y) で切り欠きの左が空いている")
            #expect(path.contains(CGPoint(x: notchRight + 1, y: y)), "y=\(y) で切り欠きの右が空いている")
        }
    }

    /// notch 非搭載機では**四隅とも丸い**（画面の上辺に吸い付かないので、逆アールを描かない）。
    @Test("浮かべる形は四隅とも丸い")
    func floatingShapeIsRoundedOnAllCorners() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 44)
        let path = HUDIslandShape(
            screenEdgeRadius: 0,
            floatingTopRadius: HUDIslandMetrics.floatingTopCornerRadius,
            bottomRadius: HUDIslandMetrics.bottomCornerRadius
        ).path(in: rect)

        #expect(!path.contains(CGPoint(x: 1, y: 1)))
        #expect(!path.contains(CGPoint(x: rect.maxX - 1, y: 1)))
        #expect(!path.contains(CGPoint(x: 1, y: rect.maxY - 1)))
        #expect(!path.contains(CGPoint(x: rect.maxX - 1, y: rect.maxY - 1)))
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
    }
}

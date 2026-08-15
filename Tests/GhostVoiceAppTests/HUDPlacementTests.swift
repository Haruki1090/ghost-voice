import CoreGraphics
import Testing

@testable import GhostVoiceApp

/// **HUD をどの画面のどこへ出すか**（FR-3 / 詳細設計書 §7.1）。
///
/// ## なぜ `NSScreen` を使わずに検査するのか
///
/// `NSScreen` はこの機体の実際のディスプレイ構成でしか作れない。したがって
/// **notch 非搭載の内蔵ディスプレイ**（該当機が手元に無い）、**クラムシェル**（蓋を閉じる操作）、
/// **外部を主にした構成**（配置変更）は `NSScreen` 越しには 1 つも検査できない。
/// これらは調査 `core-api-and-hud.md` 付録の U-4 / U-5 / U-6 として**未実測のまま残っている**。
///
/// **未実測だからこそ、コードが破綻しないことだけは固定しておく。**
/// ここで使う `HUDScreenSnapshot` は代役であり、**実測値（この機体の 2 画面）をそのまま
/// 写した構成も含めてある**ので、代役が現実から離れていないことも同時に見ている。
@Suite("HUD の表示先（内蔵ディスプレイ・notch の矩形・フォールバック）")
struct HUDPlacementTests {

    /// **実測値そのもの**（2026-08-14 / MacBook Pro Mac15,3 / M3 / macOS 26.5.2）。
    static let builtInWithNotch = HUDScreenSnapshot(
        displayID: 1, isBuiltIn: true, isMain: true,
        frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130),
        safeAreaTop: 38,
        auxiliaryTopLeftWidth: 791, auxiliaryTopRightWidth: 788)

    /// **実測値そのもの**（同上。DELL S2722QC）。
    static let external = HUDScreenSnapshot(
        displayID: 3, isBuiltIn: false, isMain: false,
        frame: CGRect(x: -412, y: 1169, width: 2560, height: 1440),
        visibleFrame: CGRect(x: -412, y: 1169, width: 2560, height: 1410),
        safeAreaTop: 0,
        auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil)

    /// **未実測の構成**（notch 非搭載の内蔵。MacBook Air M1 等）。
    /// 実測できないので「こう返るはず」の値を置いている——**これは推測である。**
    /// 見ているのは値の正しさではなく、**この形が来ても落ちないこと**である。
    static let builtInWithoutNotch = HUDScreenSnapshot(
        displayID: 2, isBuiltIn: true, isMain: false,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
        safeAreaTop: 0,
        auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil)

    // MARK: - notch の矩形

    /// **調査で実測した矩形（x 791 / y 1131 / w 221 / h 38）を 1 pt も違わず再現する。**
    /// 791 + 221 + 788 = 1800 と端数なく足し合うことが、この計算が正しい根拠だった。
    @Test("内蔵ディスプレイの notch 矩形が実測値と一致する")
    func notchRectMatchesMeasurement() {
        let notch = Self.builtInWithNotch.notchRect
        #expect(notch == CGRect(x: 791, y: 1131, width: 221, height: 38))
    }

    @Test("notch を持たない画面では矩形が nil になる（強制アンラップは即クラッシュする）")
    func noNotchOnScreensWithoutAuxiliaryAreas() {
        #expect(Self.external.notchRect == nil)
        #expect(Self.builtInWithoutNotch.notchRect == nil)
    }

    /// **片方だけ nil / `safeAreaTop == 0` / 足し合わない、はどれも未実測の形である。**
    /// 未実測の形が来たら notch 無しへ倒す——誤って倒しても失うのは見た目だけだが、
    /// 逆（notch があると誤認する）は表示が切り欠きへ入り込んで消える。
    @Test("条件が 1 つでも欠けたら notch 無しへ倒す")
    func notchRequiresEveryCondition() {
        var onlyLeft = Self.builtInWithNotch
        onlyLeft = HUDScreenSnapshot(
            displayID: onlyLeft.displayID, isBuiltIn: true, isMain: true,
            frame: onlyLeft.frame, visibleFrame: onlyLeft.visibleFrame, safeAreaTop: 38,
            auxiliaryTopLeftWidth: 791, auxiliaryTopRightWidth: nil)
        #expect(onlyLeft.notchRect == nil)

        let noSafeArea = HUDScreenSnapshot(
            displayID: 1, isBuiltIn: true, isMain: true,
            frame: Self.builtInWithNotch.frame, visibleFrame: Self.builtInWithNotch.visibleFrame,
            safeAreaTop: 0, auxiliaryTopLeftWidth: 791, auxiliaryTopRightWidth: 788)
        #expect(noSafeArea.notchRect == nil)

        // 左右の幅が画面の幅を食い切る（隙間が無い）。
        let noGap = HUDScreenSnapshot(
            displayID: 1, isBuiltIn: true, isMain: true,
            frame: Self.builtInWithNotch.frame, visibleFrame: Self.builtInWithNotch.visibleFrame,
            safeAreaTop: 38, auxiliaryTopLeftWidth: 900, auxiliaryTopRightWidth: 900)
        #expect(noGap.notchRect == nil)
    }

    // MARK: - どの画面へ出すか（FR-3）

    /// **FR-3 の本体。** 外部ディスプレイが主で、しかも `screens` の先頭に来ていても、
    /// 内蔵へ出さなければならない。実測で `NSScreen.main != NSScreen.screens.first` だった。
    @Test("外部が主ディスプレイで先頭にあっても内蔵へ出す")
    func alwaysPrefersBuiltIn() throws {
        var externalIsMain = Self.external
        externalIsMain = HUDScreenSnapshot(
            displayID: 3, isBuiltIn: false, isMain: true,
            frame: Self.external.frame, visibleFrame: Self.external.visibleFrame,
            safeAreaTop: 0, auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil)
        var builtInNotMain = Self.builtInWithNotch
        builtInNotMain = HUDScreenSnapshot(
            displayID: 1, isBuiltIn: true, isMain: false,
            frame: Self.builtInWithNotch.frame, visibleFrame: Self.builtInWithNotch.visibleFrame,
            safeAreaTop: 38, auxiliaryTopLeftWidth: 791, auxiliaryTopRightWidth: 788)

        let placement = try #require(
            HUDPlacement.resolve(screens: [externalIsMain, builtInNotMain]))
        #expect(placement.displayID == 1)
        #expect(placement.isOnBuiltInDisplay)
        #expect(placement.anchor == .notch)
    }

    @Test("実測の 2 画面構成では内蔵の切り欠きへ吸い付く")
    func measuredTwoScreenSetup() throws {
        let placement = try #require(
            HUDPlacement.resolve(screens: [Self.builtInWithNotch, Self.external]))
        #expect(placement.anchor == .notch)
        #expect(placement.notchRect == CGRect(x: 791, y: 1131, width: 221, height: 38))
        // **上辺は `frame.maxY`（1169）。`visibleFrame.maxY`（1130）ではない。**
        // 実測で両者は 1 pt ずれる（切り欠きの下端は 1131）。
        #expect(placement.topEdgeY == 1169)
        #expect(placement.centerX == 901.5)
    }

    /// **notch 非搭載の内蔵機**（未実測 / U-5）。
    /// 内蔵と認識できること（FR-3）と、メニューバーの下へ倒れることを見る。
    /// `safeAreaInsets.top > 0` で内蔵を判定していたら、ここで外部へ出てしまう。
    @Test("notch 非搭載の内蔵機でも内蔵を選び、メニューバーの直下へ出す")
    func builtInWithoutNotchFallsBackBelowMenuBar() throws {
        let placement = try #require(
            HUDPlacement.resolve(screens: [Self.external, Self.builtInWithoutNotch]))
        #expect(placement.displayID == 2)
        #expect(placement.isOnBuiltInDisplay)
        #expect(placement.anchor == .belowMenuBar)
        #expect(placement.notchRect == nil)
        #expect(placement.notchBandHeight == 0)
        // メニューバーを隠さない位置＝可視領域の上端。
        #expect(placement.topEdgeY == 875)
    }

    /// **クラムシェル**（未実測 / U-4 / V-22）。内蔵は `screens` から消える。
    /// FR-3 は物理的に果たせないので、主ディスプレイのメニューバー直下へ出し、
    /// **果たせていないことを `isOnBuiltInDisplay` で表に出す。**
    @Test("内蔵が無い構成では主ディスプレイへ出し、内蔵でないことを表に出す")
    func clamshellFallsBackToMainDisplay() throws {
        let mainExternal = HUDScreenSnapshot(
            displayID: 3, isBuiltIn: false, isMain: true,
            frame: Self.external.frame, visibleFrame: Self.external.visibleFrame,
            safeAreaTop: 0, auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil)
        let secondExternal = HUDScreenSnapshot(
            displayID: 4, isBuiltIn: false, isMain: false,
            frame: CGRect(x: 2148, y: 1169, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 2148, y: 1169, width: 1920, height: 1055),
            safeAreaTop: 0, auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil)

        // **主でない方を先頭にしても主を選ぶ**（`screens.first` へのフォールバックは誤り）。
        let placement = try #require(
            HUDPlacement.resolve(screens: [secondExternal, mainExternal]))
        #expect(placement.displayID == 3)
        #expect(!placement.isOnBuiltInDisplay)
        #expect(placement.anchor == .belowMenuBar)
    }

    @Test("画面が 1 枚も無ければ表示先を返さない")
    func noScreens() {
        #expect(HUDPlacement.resolve(screens: []) == nil)
    }

    /// 内蔵も主も無い（あり得ないはずだが、`CGDisplayIsMain` が 0 を返す形は未実測である）。
    /// **落ちずに 1 枚目へ倒れること**だけを固定する。
    @Test("内蔵も主も無ければ先頭の画面へ倒れる")
    func neitherBuiltInNorMain() throws {
        let placement = try #require(HUDPlacement.resolve(screens: [Self.external]))
        #expect(placement.displayID == 3)
        #expect(!placement.isOnBuiltInDisplay)
    }

    // MARK: - パネルの矩形

    @Test("畳んだ幅でも切り欠きより狭くならない")
    func compactWidthNeverNarrowerThanNotch() throws {
        let placement = try #require(HUDPlacement.resolve(screens: [Self.builtInWithNotch]))
        let frame = placement.panelFrame(width: 120, contentHeight: 40)
        #expect(frame.width == 221)
        // 高さは「切り欠きの帯 + 中身」。
        #expect(frame.height == 78)
        // 上辺は画面の一番上。
        #expect(frame.maxY == 1169)
    }

    @Test("広げても画面からはみ出さない")
    func wideFrameStaysOnScreen() throws {
        let placement = try #require(HUDPlacement.resolve(screens: [Self.builtInWithNotch]))
        let frame = placement.panelFrame(width: 5000, contentHeight: 40)
        #expect(frame.minX >= placement.screenFrame.minX)
        #expect(frame.maxX <= placement.screenFrame.maxX)
        #expect(frame.width == 1800)
    }

    /// 外部ディスプレイが左にあると `frame.minX` は負になる（実測 -412）。
    /// **原点を 0 に丸める実装だと、ここでずれる。**
    @Test("原点が負の画面でも矩形がその画面の中に収まる")
    func negativeOriginScreen() throws {
        let placement = try #require(
            HUDPlacement.resolve(
                screens: [
                    HUDScreenSnapshot(
                        displayID: 3, isBuiltIn: false, isMain: true,
                        frame: Self.external.frame, visibleFrame: Self.external.visibleFrame,
                        safeAreaTop: 0, auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil)
                ]))
        let frame = placement.panelFrame(width: 460, contentHeight: 40)
        #expect(frame.minX >= -412)
        #expect(frame.maxX <= 2148)
        // メニューバーの帯へ食い込まない。
        #expect(frame.maxY == 2579)
        #expect(frame.height == 40)
    }
}

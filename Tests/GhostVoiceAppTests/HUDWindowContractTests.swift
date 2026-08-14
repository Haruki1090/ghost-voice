import AppKit
import Foundation
import Testing

@testable import GhostVoiceApp

/// **window に課した約束を、値とソースの両方で固定する。**
///
/// ここに並ぶ 1 つ 1 つは、外すと**挿入先が壊れる**か**利用者の作業を妨げる**かのどちらかである。
/// window そのものは作らない——`swift test` には `NSApplication.run()` が無く、
/// **run() の前に window を作らないという規律を、検査自身が破ることになる**（実測 B-3）。
@Suite("HUD の window の取り決め")
struct HUDWindowContractTests {

    /// **`level == 0` にした瞬間に挿入先が Ghost Voice 自身になる。**
    /// `AccessibilityInserter.frontmostProcessIdentifier()` は
    /// `kCGWindowLayer == 0` の最前面ウィンドウの pid を見る（実測 B-3 の結果 3）。
    @Test("ウィンドウレベルが 0 ではない")
    func levelIsNeverZero() {
        #expect(HUDWindowContract.level.rawValue != 0)
    }

    /// 実測した z 順: メニューバー本体 24 / メニューバー項目 25 / 緑ドット 2147483630。
    @Test("ウィンドウレベルはメニューバー項目より 1 つ上（実測 26）")
    func levelIsStatusBarPlusOne() {
        #expect(HUDWindowContract.level.rawValue == 26)
        #expect(HUDWindowContract.level.rawValue == NSWindow.Level.statusBar.rawValue + 1)
        #expect(HUDWindowContract.level.rawValue > NSWindow.Level.mainMenu.rawValue)
    }

    /// **`.maximumWindow` は採らない。** プライバシーインジケータ（緑ドット。実測 2147483630）
    /// より前面に出てしまい、**録音中にマイク使用を示す表示を隠しうる。**
    @Test("プライバシーインジケータより前面に出ない")
    func neverAbleToCoverThePrivacyIndicator() {
        let maximumWindow = Int(CGWindowLevelForKey(.maximumWindow))
        #expect(HUDWindowContract.level.rawValue < maximumWindow)
        #expect(HUDWindowContract.level.rawValue < 2_147_483_630)
    }

    @Test("フォーカスを奪わない構成になっている")
    func styleMaskDoesNotStealFocus() {
        #expect(HUDWindowContract.styleMask.contains(.borderless))
        #expect(HUDWindowContract.styleMask.contains(.nonactivatingPanel))
        #expect(!HUDWindowContract.styleMask.contains(.titled))
    }

    /// **`hidesOnDeactivate` が真だと HUD は一度も見えない**——Ghost Voice は決して活性化しない。
    /// **`ignoresMouseEvents` が偽だと、透明な部分でもメニューバーが押せなくなる。**
    @Test("他アプリが前面でも消えず、クリックも奪わない")
    func staysVisibleAndTransparentToClicks() {
        #expect(HUDWindowContract.hidesOnDeactivate == false)
        #expect(HUDWindowContract.ignoresMouseEvents == true)
        #expect(HUDWindowContract.isMovable == false)
        #expect(HUDWindowContract.hasShadow == false)
        #expect(HUDWindowContract.isOpaque == false)
    }

    /// 効きは**未実測**（V-21。Space の切り替えとフルスクリーン化は実機の操作が要る）。
    /// 指定してあることだけを固定する。
    @Test("全 Space・フルスクリーンの上に出す指定がある")
    func collectionBehavior() {
        #expect(HUDWindowContract.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(HUDWindowContract.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(HUDWindowContract.collectionBehavior.contains(.stationary))
        #expect(HUDWindowContract.collectionBehavior.contains(.ignoresCycle))
    }

    // MARK: - 寸法

    @Test("広げるのは録音中の暫定テキストと告知だけ")
    func onlyTextNeedsTheWideLayout() {
        #expect(HUDDisplay.hidden.wantsWideLayout == false)
        #expect(HUDDisplay.completed.wantsWideLayout == false)
        #expect(HUDDisplay.processing(.refining).wantsWideLayout == false)
        #expect(
            HUDDisplay.recording(
                HUDRecording(level: 0.1, languageBadge: "日", volatileText: "")
            ).wantsWideLayout == false)
        #expect(
            HUDDisplay.recording(
                HUDRecording(level: 0.1, languageBadge: "日", volatileText: "あ")
            ).wantsWideLayout)
        #expect(HUDDisplay.message(HUDMessage(text: "x", severity: .info)).wantsWideLayout)
    }

    // MARK: - 音量バー

    @Test("音量の振れ幅は 0〜1 に収まり、単調に増える")
    func levelMeterIsClampedAndMonotonic() {
        #expect(HUDLevelMeter.normalized(-1) == 0)
        #expect(HUDLevelMeter.normalized(0) == 0)
        #expect(HUDLevelMeter.normalized(HUDLevelMeter.fullScaleRMS) == 1)
        #expect(HUDLevelMeter.normalized(10) == 1)
        #expect(HUDLevelMeter.normalized(0.05) < HUDLevelMeter.normalized(0.10))
    }

    @Test("点灯するバーの本数が範囲を出ない")
    func litBarsStayInRange() {
        for level in [Float(-1), 0, 0.001, 0.05, 0.1, 0.2, 5] {
            let lit = HUDLevelMeter.litBars(level, count: 5)
            #expect(lit >= 0 && lit <= 5)
        }
        #expect(HUDLevelMeter.litBars(0, count: 5) == 0)
        #expect(HUDLevelMeter.litBars(1, count: 5) == 5)
        #expect(HUDLevelMeter.litBars(0.1, count: 0) == 0)
    }

    // MARK: - ソース走査

    /// **振る舞いでは捕まえられない規律をソースで見る。**
    ///
    /// window を作る検査を書けない以上（run() が無い）、「どこで作っているか」は
    /// ソースを見る以外に確かめる手が無い。B2 が `exit` に対して採ったのと同じ形。
    struct SourceScan {
        static let hudDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GhostVoiceAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリの根
            .appendingPathComponent("Sources/GhostVoiceApp")

        static func swiftFiles() throws -> [(name: String, text: String)] {
            let enumerator = FileManager.default.enumerator(
                at: hudDirectory, includingPropertiesForKeys: nil)
            var files: [(String, String)] = []
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
            }
            return files
        }

        /// doc コメントの中の言及は数えない（**禁止の理由を書くために名前が出る**）。
        static func codeLines(_ text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        }
    }

    /// **`makeKeyAndOrderFront` はキーウィンドウにしてしまう。**
    /// 使った瞬間にフォーカスを奪い、挿入先が壊れる。
    @Test("makeKeyAndOrderFront をどこでも呼んでいない")
    func neverMakesKeyAndOrdersFront() throws {
        for file in try SourceScan.swiftFiles() {
            let hits = SourceScan.codeLines(file.text).filter {
                $0.contains("makeKeyAndOrderFront")
            }
            #expect(hits.isEmpty, "\(file.name) に makeKeyAndOrderFront がある: \(hits)")
        }
    }

    /// **window を作る場所を 1 箇所に閉じ込める。**
    /// 増えると「`RunLoopEntry` を経由しない window」が生まれる余地ができる。
    @Test("NSPanel / NSWindow を作るのは HUDPanel.swift だけ")
    func onlyOnePlaceCreatesWindows() throws {
        for file in try SourceScan.swiftFiles() where file.name != "HUDPanel.swift" {
            let hits = SourceScan.codeLines(file.text).filter {
                $0.contains("NSPanel(") || $0.contains("NSWindow(")
            }
            #expect(hits.isEmpty, "\(file.name) が window を作っている: \(hits)")
        }
    }

    @Test("orderFrontRegardless を呼ぶのは HUDPanel.swift だけ")
    func onlyOnePlaceShowsWindows() throws {
        for file in try SourceScan.swiftFiles() where file.name != "HUDPanel.swift" {
            let hits = SourceScan.codeLines(file.text).filter {
                $0.contains("orderFrontRegardless")
            }
            #expect(hits.isEmpty, "\(file.name) が window を表示している: \(hits)")
        }
    }

    /// **`NSScreen` を読む場所も 1 箇所に閉じ込める。**
    /// 散らばると、そのぶんだけ「この機体の構成でしか動かない判断」が増え、
    /// notch 非搭載機・クラムシェル（どちらも未実測）で破綻する箇所を数えられなくなる。
    @Test("NSScreen を読むのは HUDScreenSnapshot.swift だけ")
    func onlyOnePlaceReadsScreens() throws {
        for file in try SourceScan.swiftFiles() where file.name != "HUDScreenSnapshot.swift" {
            let hits = SourceScan.codeLines(file.text).filter { $0.contains("NSScreen") }
            #expect(hits.isEmpty, "\(file.name) が NSScreen を読んでいる: \(hits)")
        }
    }

    /// `.maximumWindow` は緑ドットを覆う（実測）。**採らないと決めた。**
    @Test("maximumWindow を使っていない")
    func neverUsesMaximumWindowLevel() throws {
        for file in try SourceScan.swiftFiles() {
            let hits = SourceScan.codeLines(file.text).filter { $0.contains(".maximumWindow") }
            #expect(hits.isEmpty, "\(file.name) が .maximumWindow を使っている: \(hits)")
        }
    }
}

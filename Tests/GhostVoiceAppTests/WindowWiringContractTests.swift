import Foundation
import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

/// **画面の提示の配線が、指示どおりであることを固定する。**
///
/// トラック D は「どの窓・どのメニューから開くか」を ViewModel の doc コメントに
/// 書き残した。**その指示どおりに配線したかは、振る舞いでは確かめられない**
/// （`NSApp.run()` を検査から回せない）。ソース走査を検査として置く。
@Suite("窓の配線が満たすべき命題")
struct WindowWiringContractTests {

    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // GhostVoiceAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // リポジトリの根
        .appendingPathComponent("Sources/GhostVoiceApp")

    private static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// doc コメントの中の言及は数えない（**禁止の理由を書くために名前が出る**）。
    private static func codeLines(_ text: String) -> [(line: Int, text: String)] {
        text.components(separatedBy: .newlines)
            .enumerated()
            .map { (line: $0.offset + 1, text: $0.element) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    @Test("走査の対象が実在する（空集合に対して緑になっていない）")
    func scanTargetsExist() throws {
        for path in [
            "Shell/Windows/AppWindow.swift", "Shell/Windows/StatusMenuSurface.swift",
            "Main/main.swift",
        ] {
            #expect(try !Self.text(path).isEmpty, "\(path) が無い")
        }
    }

    // MARK: - 命題 1: 起動時に窓を作らない

    /// `AppSurface` の doc が「**起動時に非表示の window を用意しておく実装は禁止**」と
    /// 定めている。ViewModel はストアと寿命を揃えるため `init` で作るが、
    /// **窓は利用者がメニューを選んだときに初めて作る。**
    @Test("`StatusMenuSurface.init` は窓を作らない")
    func surfaceInitDoesNotCreateWindows() throws {
        let source = try Self.text("Shell/Windows/StatusMenuSurface.swift")
        let lines = Self.codeLines(source)

        // `init` の本体（`public init(` から `configureStatusItem()` の呼び出しまで）。
        guard let start = lines.firstIndex(where: { $0.text.contains("public init(") }),
            let end = lines[start...].firstIndex(where: {
                $0.text.contains("configureStatusItem()")
            })
        else {
            Issue.record("init の範囲を特定できない")
            return
        }
        let body = lines[start...end]
        #expect(
            !body.contains { $0.text.contains("AppWindow(") },
            "init で窓を作っている: \(body.filter { $0.text.contains("AppWindow(") })")
    }

    /// **窓を作るのは `openSettings` / `openHistory` の 2 箇所だけ。**
    @Test("窓を作るのは、利用者がメニューを選んだときの 2 箇所だけである")
    func windowsAreCreatedLazily() throws {
        let lines = Self.codeLines(try Self.text("Shell/Windows/StatusMenuSurface.swift"))
        let sites = lines.filter { $0.text.contains("AppWindow(") }
        #expect(sites.count == 2, "見つかった地点: \(sites.map(\.line))")
    }

    // MARK: - 命題 2: 前面を明示的に返す

    /// **返さないと、次の発話の挿入先が Ghost Voice 自身になる**
    /// （`SettingsViewModel` / `HistoryViewModel` の doc の指示）。
    @Test("窓を閉じたら `NSApp.hide(nil)` で前面を返している")
    func focusIsReturnedOnClose() throws {
        let source = try Self.text("Shell/Windows/AppWindow.swift")
        let hits = Self.codeLines(source).filter { $0.text.contains("NSApp.hide(nil)") }
        // 閉じる経路は 2 つある（`dismissAndReturnFocus` と `windowWillClose`）。
        // **赤いボタンで閉じた場合も通らなければならない。**
        #expect(hits.count == 2, "見つかった地点: \(hits.map(\.line))")
        #expect(source.contains("func windowWillClose"))
    }

    /// **`NSApp.activate()` を呼ぶ場所も 1 つに閉じ込める。**
    /// HUD 側に紛れ込むと、録音のたびに挿入先が壊れる。
    @Test("`NSApp.activate()` を呼ぶのは AppWindow.swift だけ")
    func onlyOnePlaceActivatesTheApp() throws {
        var violations: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: Self.appRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "AppWindow.swift"
            else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in Self.codeLines(text) where line.text.contains("NSApp.activate(") {
                violations.append("\(url.lastPathComponent):\(line.line)")
            }
        }
        #expect(violations.isEmpty, "他の場所が活性化している: \(violations)")
    }

    // MARK: - 命題 3: 再挿入は窓を閉じてから

    /// `HistoryView` は**閉じる口を渡されないと再挿入のボタンを出さない**
    /// （順序の間違いを構造で防ぐ設計。正本 §14.4）。**渡すのが配線の仕事である。**
    @Test("履歴画面へ「閉じて前面を返す口」を渡している")
    func historyViewReceivesTheDismissHandle() throws {
        let source = try Self.text("Shell/Windows/StatusMenuSurface.swift")
        #expect(source.contains("dismissAndReturnFocus:"), "閉じる口を渡していない")
        #expect(source.contains("dismissHistoryAndReturnFocus"))

        // その口は、窓を閉じてから**前面が戻るのを待つ**。
        let window = try Self.text("Shell/Windows/AppWindow.swift")
        #expect(window.contains("waitUntilAnotherAppIsFrontmost"))
        // **活性の切り替えを待つだけでは足りない**（実測: window server の窓の並びが
        // 入れ替わるまで、さらに 24〜32 ms 掛かる）。整定時間を必ず置く。
        #expect(window.contains("frontmostSettle"))
    }

    /// **`didResignActiveNotification` を待つ形へ戻さない。**
    ///
    /// 実測（2026-08-15）では `NSApp.hide(nil)` の直後に `NSApp.isActive` が既に
    /// false であり、**通知は 1 度も来なかった**（＝待った気になるだけで待っていない）。
    /// その状態でも `kCGWindowLayer == 0` の最前面は約 26 ms のあいだ Ghost Voice の
    /// ままで、そこで再挿入すると**挿入先が Ghost Voice 自身になる。**
    @Test("活性の通知を前面復帰の根拠にしていない")
    func doesNotRelyOnTheActivationNotification() throws {
        let window = try Self.text("Shell/Windows/AppWindow.swift")
        let hits = Self.codeLines(window).filter {
            $0.text.contains("didResignActiveNotification")
        }
        #expect(hits.isEmpty, "活性の通知を待つ形へ戻っている: \(hits.map(\.line))")
    }

    /// **規則を 2 つに増やさない。**
    ///
    /// 挿入先の判定（`kCGWindowLayer == 0` の最前面 pid）は
    /// `AccessibilityInserter.frontmostProcessIdentifier()` が唯一の持ち主である。
    /// App 側で `CGWindowListCopyWindowInfo` を書くと、**2 つの「最前面」が生まれる。**
    @Test("App 側で最前面の判定を書き直していない")
    func frontmostRuleIsNotDuplicated() throws {
        var violations: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: Self.appRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in Self.codeLines(text)
            where line.text.contains("CGWindowListCopyWindowInfo")
                || line.text.contains("kCGWindowLayer")
            {
                violations.append("\(url.lastPathComponent):\(line.line)")
            }
        }
        #expect(violations.isEmpty, "App 側に最前面の判定がある: \(violations)")
    }

    // MARK: - 命題 4: 開く口がある

    @Test("ステータス項目のメニューに設定・履歴・終了が並んでいる")
    func theStatusMenuHasTheEntryPoints() throws {
        let source = try Self.text("Shell/Windows/StatusMenuSurface.swift")
        #expect(source.contains("NSStatusBar.system.statusItem"))
        #expect(source.contains("\"設定…\""))
        #expect(source.contains("\"履歴…\""))
        #expect(source.contains("NSApp.terminate(nil)"), "終了が段取りを通っていない")
    }

    /// **`exit` を置かない。** 終了は器の段取り（`GhostVoiceCore.Shutdown`）を通す。
    @Test("配線した画面から `exit` を呼んでいない")
    func surfacesNeverExitDirectly() throws {
        for path in ["Shell/Windows/StatusMenuSurface.swift", "Shell/Windows/AppWindow.swift"] {
            let hits = Self.codeLines(try Self.text(path)).filter {
                $0.text.contains("exit(")
            }
            #expect(hits.isEmpty, "\(path) が exit している: \(hits.map(\.line))")
        }
    }

    // MARK: - 命題 5: 工場は run() の後にしか呼ばれない場所へ足してある

    @Test("main.swift は HUD とステータスメニューの工場だけを渡している")
    func mainWiresBothSurfaces() throws {
        let source = try Self.text("Main/main.swift")
        #expect(source.contains("NotchHUDSurface(entry, services: services)"))
        #expect(source.contains("StatusMenuSurface(entry, services: services)"))
        // **トップレベルで窓を作っていない。**
        #expect(!source.contains("AppWindow("))
        #expect(!source.contains("NSWindow("))
    }

    // MARK: - 命題 6: 捕獲モードを閉じ忘れない

    /// 閉じ忘れると**窓が無いのに打鍵を待ち続け、PTT が効かなくなる。**
    @Test("窓を閉じるときとアプリを畳むときに、捕獲モードを閉じている")
    func captureModeIsAlwaysClosed() throws {
        let source = try Self.text("Shell/Windows/StatusMenuSurface.swift")
        let hits = Self.codeLines(source).filter { $0.text.contains("cancelCapture()") }
        // `teardown()` と、設定画面の `onClose`。
        #expect(hits.count == 2, "見つかった地点: \(hits.map(\.line))")
    }
}

/// `--window-check` の解釈。**製品の機能ではなく、実測のための入口である。**
@Suite("--window-check の引数解釈")
struct WindowCheckOptionTests {

    @Test("秒数を省略すると既定の秒数で走る")
    func defaultsToTheStandardDuration() {
        let options = AppLaunchOptions.parse(["--window-check"])
        #expect(options.windowRehearsalSeconds == AppLaunchOptions.defaultWindowRehearsalSeconds)
        // **セッションを作らない。** マイクにもタップにも触れない（ダイアログが出ない）。
        #expect(!options.startsSession)
        #expect(!options.requestsPermissions)
    }

    @Test("秒数を指定できる")
    func acceptsAnExplicitDuration() {
        #expect(AppLaunchOptions.parse(["--window-check=20"]).windowRehearsalSeconds == 20)
    }

    /// **読めない秒数を黙って既定へ倒さない**（`--hud-check` と同じ判断）。
    /// 「20 秒のつもりが 12 秒だった」は目視の検証では気づけない。
    @Test("読めない秒数は誤りとして報告し、既定で走る")
    func reportsUnparsableDurations() {
        let options = AppLaunchOptions.parse(["--window-check=abc"])
        #expect(options.unrecognized == ["--window-check=abc"])
        #expect(options.windowRehearsalSeconds == AppLaunchOptions.defaultWindowRehearsalSeconds)
    }

    @Test("既定では窓の素振りを行わない")
    func offByDefault() {
        #expect(AppLaunchOptions.parse([]).windowRehearsalSeconds == nil)
        #expect(AppLaunchOptions.parse(["--shell-only"]).windowRehearsalSeconds == nil)
    }
}

/// **「キー監視を開始できなかった」を誰が言うか**（統括が回収を指示した棲み分け）。
///
/// **両方が言う。ただし言うことが違う。** HUD は 1 行で「気づかせる」、
/// 設定画面は全文で「直させる」（詳細設計書 §14.6.0）。
/// HUD を落とさないのは、**設定画面は利用者が開かないと出ない**からである。
@Suite("キー監視の失敗の棲み分け")
@MainActor
struct HotkeyFailureSurfacingTests {

    /// HUD の帯（notch の幅は実測 221 pt）に載るのは 1 行だけである。
    @Test("HUD の告知は 1 行で、システム設定のパスまでは載せない")
    func hudSaysOneLine() {
        for error in HotkeyFailureSurfacingTests.allErrors {
            let summary = AppPermissionGuidance.summary(for: error)
            #expect(!summary.contains("\n"), "HUD の帯に複数行を載せている: \(error)")
        }
    }

    /// 設定画面は**直し方**を持つ。**HUD の 1 行では足りない側である。**
    @Test("設定画面の告知は、許可の相手と直し方まで言う")
    func settingsSaysHowToFix() {
        let message = AppPermissionGuidance.message(
            for: .eventTapNotPermitted(
                TapPermissionSnapshot(listenEventAccess: false, accessibilityTrusted: false)))
        #expect(message.contains(AppPermissionGuidance.appName), "許可の相手を名指ししていない")
        #expect(message.contains("入力監視"), "どのペインかを言っていない")
        #expect(message.contains("起動し直"), "許可の後に再起動が要ることを言っていない")
        // **1 行では載らない**ことが、HUD と分けている理由そのものである。
        #expect(message.contains("\n"))
    }

    /// **設定画面がその事実を握っていること。** 握っていなければ画面に出しようがない。
    @Test("設定画面は失敗の事実を受け取っている")
    func settingsModelCarriesTheFailure() throws {
        let temp = try SettingsHistoryTempDirectory()
        let failure = HotkeyError.tapDisabledAtStart
        let model = SettingsViewModel(
            settings: SettingsStore(rootURL: temp.url),
            vocabulary: VocabularyStore(rootURL: temp.url),
            history: HistoryStore(rootURL: temp.url, limit: 50),
            session: nil,
            hotkey: nil,
            hotkeyFailure: failure,
            directory: temp.url)
        #expect(model.hotkeyFailure == failure)
    }

    /// **常設の入口にも出す。** HUD の 10 秒を見逃した後でも辿り着けるように。
    @Test("ステータスメニューにも、失敗しているときだけ項目が出る")
    func statusMenuMentionsTheFailure() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/GhostVoiceApp/Shell/Windows/StatusMenuSurface.swift"), encoding: .utf8)
        #expect(source.contains("services.hotkeyFailure != nil"), "常に出す形になっている")
        #expect(source.contains("キー入力を監視できていません"))
    }

    static let allErrors: [HotkeyError] = [
        .eventTapNotPermitted(
            TapPermissionSnapshot(listenEventAccess: false, accessibilityTrusted: false)),
        .eventTapNotPermitted(
            TapPermissionSnapshot(listenEventAccess: true, accessibilityTrusted: true)),
        .tapDisabledAtStart, .alreadyRunning, .stopped,
    ]
}

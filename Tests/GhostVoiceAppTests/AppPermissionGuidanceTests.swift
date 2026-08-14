import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

@Suite("アプリ側の権限案内（FR-10）")
struct AppPermissionGuidanceTests {

    private func status(
        microphone: Bool = true, accessibility: Bool = true, listen: Bool = true,
        post: Bool = true, secureInput: Bool = false, bundleIdentifier: String? = "com.example.GhostVoice"
    ) -> PermissionStatus {
        PermissionStatus(
            microphoneStatus: microphone ? "許可" : "未確認",
            microphoneAuthorized: microphone,
            accessibilityTrusted: accessibility,
            listenEventAccess: listen,
            postEventAccess: post,
            secureInputEnabled: secureInput,
            bundleIdentifier: bundleIdentifier)
    }

    /// **これが CLI との唯一の実質的な違いである。**
    /// `.app` は `open` から起動された時点で自分自身が責任プロセスになり、
    /// ターミナルアプリの許可を 1 つも引き継がない（`app-bundle.md` §5.1 の実測）。
    @Test("案内は Ghost Voice を名指しし、ターミナルアプリを名指ししない")
    func namesTheApp() {
        let report = AppPermissionGuidance.report(status(microphone: false))
        #expect(report.contains("Ghost Voice"))
        #expect(!report.contains("ターミナル"))
    }

    @Test("4 項目すべてが常に表へ出る")
    func allFourRows() {
        let report = AppPermissionGuidance.report(status())
        for label in ["マイク", "入力監視", "アクセシビリティ", "キー送出"] {
            #expect(report.contains(label))
        }
    }

    /// **アクセシビリティとキー送出は別の TCC レコードである**（`kTCCServiceAccessibility` と
    /// `kTCCServicePostEvent`）。同じトグルで与えられるが片方だけの状態はありうるので、
    /// 別々に照会して別々に言う。
    @Test("キー送出だけが無いときも、その 1 行が出る")
    func postEventAlone() {
        let report = AppPermissionGuidance.report(status(post: false))
        #expect(report.contains("キー送出の許可がありません"))
        #expect(!report.contains("アクセシビリティの許可がありません"))
    }

    @Test("揃っているときは足りない旨の行を出さない")
    func nothingMissing() {
        let report = AppPermissionGuidance.report(status())
        #expect(!report.contains("ありません"))
        #expect(!report.contains("起動し直してください"))
    }

    /// secure input は TCC ではなく実行時の状態である。**許可を疑わせない。**
    @Test("secure input は権限の問題ではないと明記する")
    func secureInput() {
        let report = AppPermissionGuidance.report(status(secureInput: true))
        #expect(report.contains("これは権限の問題ではありません"))
    }

    /// バンドル ID が無い＝実行ファイルを直に叩いている。**許可はターミナルのものを借りている。**
    @Test("バンドルの外から起動していることを警告する")
    func warnsWhenUnbundled() {
        let report = AppPermissionGuidance.report(status(bundleIdentifier: nil))
        #expect(report.contains("バンドル ID がありません"))
        let bundled = AppPermissionGuidance.report(status())
        #expect(!bundled.contains("バンドル ID がありません"))
    }

    @Test("キー監視の失敗は Ghost Voice を許可するよう案内する")
    func hotkeyFailure() {
        let message = AppPermissionGuidance.message(
            for: .eventTapNotPermitted(
                TapPermissionSnapshot(listenEventAccess: false, accessibilityTrusted: true)))
        #expect(message.contains("入力監視 で Ghost Voice を有効にする"))
        // **付いているものを付け直させない。** 本当に足りないものが埋もれる。
        #expect(!message.contains("アクセシビリティ で Ghost Voice を有効にする"))
    }

    /// **権限の話ではない失敗に権限の案内を混ぜない**（付け直しの無駄足になる）。
    @Test("タップが有効にならなかった失敗には権限の案内を混ぜない")
    func tapDisabled() {
        let message = AppPermissionGuidance.message(for: .tapDisabledAtStart)
        #expect(!message.contains("プライバシーとセキュリティ"))
    }

    @Test("移行手順は 4 つとも付け直しになる理由を言う")
    func migration() {
        let text = AppPermissionGuidance.migrationFromPhase1()
        #expect(text.contains("1 つも引き継がれません"))
        for label in ["マイク", "入力監視", "アクセシビリティ", "キー送出"] {
            #expect(text.contains(label))
        }
        // フェーズ 1 の許可を先に外させない（外すと CLI が動かなくなる）。
        #expect(text.contains("移行が終わるまで外さないでください"))
    }
}

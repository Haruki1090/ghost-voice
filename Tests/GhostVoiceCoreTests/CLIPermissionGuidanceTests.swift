import Foundation
import Testing

@testable import GhostVoiceCLI
@testable import GhostVoiceCore

@Suite("CLI: 権限の案内")
struct CLIPermissionGuidanceTests {

    private func snapshot(listen: Bool, accessibility: Bool) -> TapPermissionSnapshot {
        TapPermissionSnapshot(listenEventAccess: listen, accessibilityTrusted: accessibility)
    }

    /// **既に許可されているペインへ案内してはならない。** 「そこは付いています」と
    /// 判っている項目を並べると、ユーザーは付け直しに時間を使う。
    @Test("入力監視だけが無いときはアクセシビリティを案内しない")
    func guidesToInputMonitoringOnly() {
        let message = PermissionGuidance.message(
            for: .eventTapNotPermitted(snapshot(listen: false, accessibility: true)))
        #expect(message.contains("入力監視"))
        #expect(!message.contains("アクセシビリティ で"))
    }

    @Test("アクセシビリティだけが無いときは入力監視を案内しない")
    func guidesToAccessibilityOnly() {
        let message = PermissionGuidance.message(
            for: .eventTapNotPermitted(snapshot(listen: true, accessibility: false)))
        #expect(message.contains("アクセシビリティ"))
        #expect(!message.contains("入力監視 で"))
    }

    @Test("どちらも無いときは両方を案内する")
    func guidesToBothPanes() {
        let message = PermissionGuidance.message(
            for: .eventTapNotPermitted(snapshot(listen: false, accessibility: false)))
        #expect(message.contains("入力監視"))
        #expect(message.contains("アクセシビリティ"))
    }

    /// 照会がどちらも真なのにタップが開けない場合がある（照会と `tapCreate` の
    /// 対応は確定していない。`CGEventTapHotkeyMonitor` の権限の項）。
    /// **「原因不明」で放り出さず、次の一手を示す。**
    @Test("照会が両方とも許可でもタップが開けなかったときは再起動を促す")
    func guidesToRestartWhenProbesDisagree() {
        let message = PermissionGuidance.message(
            for: .eventTapNotPermitted(snapshot(listen: true, accessibility: true)))
        #expect(message.contains("再起動"))
    }

    /// 権限とは別の失敗。案内を混ぜると、権限を付け直す無駄足になる。
    @Test("タップを有効化できなかった場合は権限の案内をしない")
    func tapDisabledIsNotAPermissionProblem() {
        let message = PermissionGuidance.message(for: .tapDisabledAtStart)
        #expect(!message.contains("入力監視"))
        #expect(!message.contains("プライバシーとセキュリティ"))
    }

    @Test("どの HotkeyError にも空でない案内がある")
    func everyErrorHasAMessage() {
        let errors: [HotkeyError] = [
            .eventTapNotPermitted(snapshot(listen: false, accessibility: false)),
            .tapDisabledAtStart,
            .alreadyRunning,
            .stopped,
        ]
        for error in errors {
            #expect(!PermissionGuidance.message(for: error).isEmpty)
        }
    }

    /// **許可の対象は「ghost-voice」ではなくターミナルアプリである。**
    /// 素の実行ファイルの TCC は責任プロセス（起動元のターミナル）に紐づく。
    /// バイナリを一覧へ足そうとしても、そこには現れない。
    @Test("案内は許可の対象がターミナルアプリであることを述べる")
    func guidanceNamesTheResponsibleApplication() {
        let message = PermissionGuidance.message(
            for: .eventTapNotPermitted(snapshot(listen: false, accessibility: false)))
        #expect(message.contains("ターミナル"))
    }

    // MARK: - --check の出力

    private func status(
        microphone: Bool = true, accessibility: Bool = true,
        listen: Bool = true, post: Bool = true, secureInput: Bool = false
    ) -> PermissionStatus {
        PermissionStatus(
            microphoneStatus: microphone ? "authorized" : "denied",
            microphoneAuthorized: microphone,
            accessibilityTrusted: accessibility,
            listenEventAccess: listen,
            postEventAccess: post,
            secureInputEnabled: secureInput
        )
    }

    @Test("全部揃っていれば使える見込みだと述べる")
    func reportSaysReadyWhenEverythingIsGranted() {
        let report = PermissionGuidance.report(status(), storageRoot: URL(filePath: "/tmp/gv"))
        #expect(report.contains("使える見込み: はい"))
    }

    @Test("入力監視が無ければ使えないと述べる")
    func reportSaysNotReadyWithoutListenAccess() {
        let report = PermissionGuidance.report(
            status(listen: false), storageRoot: URL(filePath: "/tmp/gv"))
        #expect(report.contains("使える見込み: いいえ"))
    }

    @Test("マイクが無ければ使えないと述べる")
    func reportSaysNotReadyWithoutMicrophone() {
        let report = PermissionGuidance.report(
            status(microphone: false), storageRoot: URL(filePath: "/tmp/gv"))
        #expect(report.contains("使える見込み: いいえ"))
    }

    /// キー送出が無くても PTT 自体は動く。**ただし挿入経路は AX 一段だけになる。**
    /// これを黙っていると、V-3 で全アプリが `.clipboardOnly` になった理由が判らない。
    @Test("キー送出が無いことは、動くが挿入が縮退することとして伝える")
    func reportExplainsMissingPostEventAccess() {
        let report = PermissionGuidance.report(
            status(post: false), storageRoot: URL(filePath: "/tmp/gv"))
        #expect(report.contains("使える見込み: はい"))
        #expect(report.contains("クリップボード"))
    }

    /// **終了コードは PTT が動くかしか見ない。** アクセシビリティが無くても 0 になるので、
    /// 報告の側で「V-3 はこの状態では意味を持たない」と言わないと、
    /// 終了コードだけを見た人が全アプリを `clipboardOnly` と記録することになる。
    @Test("アクセシビリティが無いときは V-3 が成立しないと述べる")
    func reportWarnsThatV3NeedsAccessibility() {
        let missing = PermissionGuidance.report(
            status(accessibility: false), storageRoot: URL(filePath: "/tmp/gv"))
        let granted = PermissionGuidance.report(status(), storageRoot: URL(filePath: "/tmp/gv"))
        #expect(missing.contains("使える見込み: はい"))  // PTT 自体は動く
        #expect(missing.contains("V-3"))
        #expect(!granted.contains("V-3"))
    }

    /// **I-4: フェーズ 1 の設定手段は手編集だけ。** 読めなかったことを黙ると、
    /// 「設定を書き換えたのに効かない」という症状だけが残り、原因に辿り着けない。
    @Test("読めなかったファイルがあれば、既定値で動いていることを述べる")
    func reportNamesUnreadableFiles() {
        let broken = PermissionGuidance.report(
            status(), storageRoot: URL(filePath: "/tmp/gv"), unreadable: ["settings.json"])
        let fine = PermissionGuidance.report(status(), storageRoot: URL(filePath: "/tmp/gv"))

        #expect(broken.contains("settings.json を読めませんでした"))
        #expect(broken.contains("既定値で動作しています"))
        // 「何が効いていないか」まで言う
        #expect(broken.contains("ホットキー"))
        #expect(!fine.contains("読めませんでした"), "読めているのに警告を出している")
    }

    /// **結線まで確かめる。** 文言（`report`）とストア（`loadFailure`）を別々に
    /// 検査しても、**両者を繋ぐ 3 行が間違っていれば利用者には何も出ない。**
    @Test("壊れたファイルを実際に置くと、その名前が挙がる")
    func detectsUnreadableFilesOnDisk() throws {
        try withTempRoot { root in
            try Data("{ broken".utf8).write(to: root.appendingPathComponent("settings.json"))
            try Data("[oops".utf8).write(to: root.appendingPathComponent("vocabulary.json"))

            let names = GhostVoiceRuntime.unreadableStorageFiles(root: root)
            #expect(names.contains("settings.json"))
            #expect(names.contains("vocabulary.json"))
            #expect(!names.contains("history.json"), "無いだけのファイルを失敗として数えている")
        }
    }

    @Test("すべて読めるなら何も挙がらない")
    func reportsNoUnreadableFilesWhenHealthy() throws {
        try withTempRoot { root in
            #expect(GhostVoiceRuntime.unreadableStorageFiles(root: root).isEmpty)
        }
    }

    @Test("読めなかったファイルは名前ごとに出る")
    func reportListsEachUnreadableFile() {
        let report = PermissionGuidance.report(
            status(), storageRoot: URL(filePath: "/tmp/gv"),
            unreadable: ["settings.json", "vocabulary.json"])
        #expect(report.contains("settings.json を読めませんでした"))
        #expect(report.contains("vocabulary.json を読めませんでした"))
    }

    @Test("報告には設定ファイルの置き場所が載っている")
    func reportShowsStorageRoot() {
        let report = PermissionGuidance.report(
            status(), storageRoot: URL(filePath: "/tmp/ghost-voice-test"))
        #expect(report.contains("/tmp/ghost-voice-test"))
        #expect(report.contains("settings.json"))
        #expect(report.contains("history.json"))
    }

    /// V-3 の記録は `history.json` の `insertionMethod` を見る。
    /// **どちらのペインが何に効くかを報告に書いておく**（付け直しの往復を減らす）。
    @Test("報告は各項目がどのペインに対応するかを示す")
    func reportMapsEachItemToItsPane() {
        let report = PermissionGuidance.report(
            status(microphone: false, accessibility: false, listen: false, post: false),
            storageRoot: URL(filePath: "/tmp/gv"))
        #expect(report.contains("マイク"))
        #expect(report.contains("入力監視"))
        #expect(report.contains("アクセシビリティ"))
    }

    @Test("secure input が有効なら、その間は挿入しないことを述べる")
    func reportMentionsSecureInput() {
        let enabled = PermissionGuidance.report(
            status(secureInput: true), storageRoot: URL(filePath: "/tmp/gv"))
        let disabled = PermissionGuidance.report(
            status(secureInput: false), storageRoot: URL(filePath: "/tmp/gv"))
        #expect(enabled.contains("secure input"))
        #expect(enabled.contains("挿入しません"))
        #expect(!disabled.contains("挿入しません"))
    }
}

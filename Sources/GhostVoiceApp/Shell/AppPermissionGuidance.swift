import GhostVoiceCore

/// 権限まわりの文言（アプリ側）。
///
/// **許可の相手は `Ghost Voice` である。**
/// `.app` を Finder / Dock / `open` から起動すると、そのプロセスの責任主体は自分自身になり、
/// **ターミナルアプリが持っている許可は 1 つも引き継がれない**（`app-bundle.md` §5.1 の実測。
/// 同一バンドルを `open` で起動すると 4 項目すべてが未許可で返り、`getppid()` は 1（launchd）だった）。
///
/// > **`GhostVoiceCLI.PermissionGuidance` と矛盾しない。**
/// > あちらは「素の実行ファイルを起動しているターミナルアプリ」を名指しし、
/// > こちらは「`.app` 自身」を名指しする。**どちらもその起動経路では正しい。**
/// > 相手が違うのは同じ TCC の規則（許可は責任プロセスに付く）の当然の帰結である。
/// > フェーズ 1 の利用者が付け直しになる理由も同じで、それは `migrationFromPhase1` が言う。
public enum AppPermissionGuidance {

    static let settingsPath = "システム設定 > プライバシーとセキュリティ"

    /// アプリの表示名。**システム設定の一覧にはこの名前で並ぶ**（`CFBundleName`）。
    public static let appName = "Ghost Voice"

    /// 4 項目の状態と、足りないものの直し方。
    ///
    /// - Parameter status: `AppPermissions.current()` の結果（**照会のみ**）。
    public static func report(_ status: AppPermissionStatus) -> String {
        var lines = [
            "\(appName): 権限の状態",
            "",
            row("マイク", status.microphoneAuthorized, "\(settingsPath) > マイク", status.microphoneStatus),
            row("入力監視", status.listenEventAccess, "\(settingsPath) > 入力監視", "ホットキーに必須"),
            row(
                "アクセシビリティ", status.accessibilityTrusted, "\(settingsPath) > アクセシビリティ",
                "AX 経路の挿入に使う"),
            row("キー送出", status.postEventAccess, "\(settingsPath) > アクセシビリティ", "⌘V の送出に使う"),
            "",
            "  許可の相手は **\(appName)** です（一覧にこの名前で並びます）。",
        ]

        if status.bundleIdentifier == nil {
            // 実行ファイルを直接叩いている。**許可はターミナルアプリのものを借りている。**
            lines.append(contentsOf: [
                "",
                "  ⚠️ `.app` の外から起動しています（バンドル ID がありません）。",
                "     この状態の許可は **起動元のターミナルアプリ**のもので、Finder から",
                "     起動したときとは結果が変わります。**切り分けができなくなるので、",
                "     `Ghost Voice.app` を `open` するか Finder から起動してください。**",
            ])
        }

        if !status.microphoneAuthorized {
            lines.append("  - マイクの許可がありません。押しても録音が始まりません。")
        }
        if !status.listenEventAccess {
            lines.append("  - 入力監視の許可がありません。右 Option の押下を受け取れません。")
        }
        if !status.accessibilityTrusted {
            lines.append("  - アクセシビリティの許可がありません。AX 直接挿入が使えません。")
        }
        if !status.postEventAccess {
            lines.append("  - キー送出の許可がありません。AX 経路が使えないアプリでは、テキストは")
            lines.append("    クリップボードに残るだけになります（履歴の insertionMethod は clipboardOnly）。")
        }
        if status.secureInputEnabled {
            // TCC ではなく実行時の状態である。**許可を疑わせないよう分けて言う。**
            lines.append("  - いま secure input が有効です（パスワード欄など）。この間はテキストを挿入しません。")
            lines.append("    **これは権限の問題ではありません。** 許可を付け直しても変わりません。")
        }
        if !status.microphoneAuthorized || !status.listenEventAccess || !status.accessibilityTrusted
            || !status.postEventAccess
        {
            lines.append("")
            lines.append("  許可を与えたら **\(appName) を終了して起動し直してください。**")
            lines.append("  アクセシビリティ系の許可はプロセスの起動時に読まれます。")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// キー監視を開始できなかったときの案内。
    ///
    /// **`AXIsProcessTrusted()` を門番にしない。** 権威ある答えは `tapCreate` の可否であり、
    /// 照会は「どちらのペインへ案内するか」を決める補助でしかない（詳細設計書 §2.2）。
    public static func message(for error: HotkeyError) -> String {
        switch error {
        case .eventTapNotPermitted(let snapshot):
            var lines = [
                "キーイベントを監視できないため、右 Option の押下を受け取れません。",
                "",
                "**許可するのは \(appName) です。** システム設定の一覧にこの名前で並びます。",
                "",
            ]
            if !snapshot.listenEventAccess {
                lines.append("- \(settingsPath) > 入力監視 で \(appName) を有効にする（ホットキーに必須）")
            }
            if !snapshot.accessibilityTrusted {
                lines.append("- \(settingsPath) > アクセシビリティ で \(appName) を有効にする（挿入に必要）")
            }
            if snapshot.listenEventAccess && snapshot.accessibilityTrusted {
                lines.append("照会ではどちらも許可されています。\(appName) を終了して起動し直してください。")
            } else {
                lines.append("")
                lines.append("一覧に \(appName) が無い場合は、いちど終了して起動し直すと載ります。")
                lines.append("許可した後は **\(appName) を起動し直してください**（許可は起動時に読まれます）。")
            }
            return lines.joined(separator: "\n")
        case .tapDisabledAtStart:
            // **権限の話ではない。** ここへ権限の案内を混ぜると、付け直しの無駄足になる。
            return """
                キーイベントの監視を開始できませんでした（タップが有効になりませんでした）。
                他のキー入力を監視するツールと競合している可能性があります。\(appName) を
                起動し直しても直らない場合は、常駐している入力系ツールを止めて試してください。
                """
        case .alreadyRunning:
            return "キー監視は既に動いています（内部の誤り）。"
        case .stopped:
            return "キー監視は停止済みで、再開できません。\(appName) を起動し直してください（内部の誤り）。"
        }
    }

    /// フェーズ 1（CLI）からの移行手順。
    ///
    /// **4 つとも付け直しになる。** これは避けられない（`app-bundle.md` §5.1 / §7）。
    /// 理由まで書くのは、「前は動いていたのに」という利用者の疑問に先回りするためである。
    public static func migrationFromPhase1() -> String {
        """
        フェーズ 1 からの移行（\(appName) へ権限を付け直す）

        **ターミナルアプリに与えた許可は 1 つも引き継がれません。**
        `.app` は Finder / Dock / `open` から起動された時点で自分自身が責任プロセスになり、
        起動元とは別のアプリとして扱われます（実測）。マイク・入力監視・アクセシビリティ・
        キー送出の 4 つを、\(appName) に対して付け直してください。

        1. \(appName).app を /Applications へ置く（**後から場所を変えないこと**）
        2. \(appName) を起動する。マイクのダイアログが出たら「許可」を選ぶ
        3. \(settingsPath) > 入力監視 で \(appName) をオンにする
        4. \(settingsPath) > アクセシビリティ で \(appName) をオンにする
        5. \(appName) を終了して起動し直す
        6. 4 項目すべてが許可になっていることを確認する

        フェーズ 1 のためにターミナルアプリへ与えた許可は、**移行が終わるまで外さないでください**
        （外すと CLI（`ghost-voice`）が動かなくなります）。
        """
    }

    private static func row(_ label: String, _ granted: Bool, _ pane: String, _ note: String)
        -> String
    {
        "  \(granted ? "✓" : "✗") \(label)（\(pane)）: \(note)"
    }
}

/// `Ghost Voice.app` の起動引数。
///
/// 常駐 GUI アプリなので引数はほとんど使わない。**`--shell-only` だけは製品の機能ではなく、
/// 「器が正しいか」を TCC に触れずに確かめるための入口である**（受け入れ条件 4）。
///
/// 渡し方:
/// ```
/// open "/Applications/Ghost Voice.app" --args --shell-only
/// ```
public struct AppLaunchOptions: Sendable, Equatable {

    /// セッション（マイク・キー監視・認識）を組み立てるか。
    ///
    /// `false` にすると `CGEvent.tapCreate` も `AVAudioEngine` も一切触らない。
    /// **TCC のダイアログが出る余地が無くなる**ので、フォーカスや window 配置の確認に使える。
    public let startsSession: Bool

    /// 足りない権限をアプリから要求するか（**ダイアログが出る**）。
    ///
    /// `.app` は責任プロセスが自分自身なので、**要求を出すのはこのアプリ自身でなければならない**
    /// （ターミナルから CLI で要求してもターミナルアプリに付くだけで、Ghost Voice には付かない。
    /// `app-bundle.md` §5.1）。したがって既定は `true` である。
    public let requestsPermissions: Bool

    /// HUD の素振りを何秒行うか。nil なら行わない。
    ///
    /// **製品の機能ではなく、目視で確かめるための入口である**（`--hud-check`）。
    /// 未実測項目 V-20（切り欠きに画素があるか）/ V-21（全 Space・フルスクリーン）/
    /// V-22（クラムシェル）は、**HUD が出ていないと確かめられない**が、
    /// 実際に出すには本来マイクとキー監視の許可が要る。この入口はどちらも触らずに
    /// 全種類の表示を一巡させる。**終わると自分で終了する。**
    ///
    /// - Important: **`--shell-only` と同じくセッションを作らない。** マイクも
    ///   `CGEvent.tapCreate` も触らないので、**TCC のダイアログが出る余地が無い。**
    public let hudRehearsalSeconds: Double?

    /// 窓（設定・履歴）の素振りを何秒行うか。nil なら行わない。
    ///
    /// **製品の機能ではなく、フォーカスの受け渡しを測るための入口である**（`--window-check`）。
    /// 受け入れ条件「窓を出した状態でフォーカスを奪わないことを実測して示す」と、
    /// V-43（窓を閉じてから前面が戻るまでの待ち方）/ V-44（`NSApp.hide(nil)` の効き）は、
    /// **窓が実際に開いていないと 1 つも確かめられない。**
    ///
    /// 筋書きは「開かずに待つ → 設定を開く → 閉じて前面を返す → 履歴を開く →
    /// 閉じて前面を返す（**再挿入の直前と同じ経路**）→ 終了」である。
    /// **最後に「再挿入してよいか」の決着を 1 行出す**——V-43 の実測はその行を読む。
    ///
    /// - Important: **`--shell-only` と同じくセッションを作らない。** マイクも
    ///   `CGEvent.tapCreate` も触らないので、**TCC のダイアログが出る余地が無い。**
    public let windowRehearsalSeconds: Double?

    /// 終了の素振りで「発話を抱えている」ことにする秒数。nil なら行わない。
    ///
    /// **製品の機能ではなく、終了要求が本当に効くかを測るための入口である**（`--shutdown-check`）。
    /// V-34（発話の途中の終了要求で発話が失われないか）は、これが無いと
    /// **実発話でしか通らない経路**であり、実バンドルでは一度も測られていなかった。
    /// その結果 `SIGTERM` で終わらない `.app` が利用者の手元に渡った（`bug-term`）。
    ///
    /// **`--shell-only` と同じくセッションを作らない。** マイクも `CGEvent.tapCreate` も
    /// 触らないので、TCC のダイアログが出る余地が無い。
    /// **0 を渡せる**——「発話を抱えていないときに終了要求が効くか」がまさに壊れていた形である。
    public let shutdownRehearsalSeconds: Double?

    /// 解釈できなかった引数。**黙って捨てない**（標準エラーへ出す）。
    public let unrecognized: [String]

    public init(
        startsSession: Bool, requestsPermissions: Bool, hudRehearsalSeconds: Double? = nil,
        windowRehearsalSeconds: Double? = nil,
        shutdownRehearsalSeconds: Double? = nil,
        unrecognized: [String] = []
    ) {
        self.startsSession = startsSession
        self.requestsPermissions = requestsPermissions
        self.hudRehearsalSeconds = hudRehearsalSeconds
        self.windowRehearsalSeconds = windowRehearsalSeconds
        self.shutdownRehearsalSeconds = shutdownRehearsalSeconds
        self.unrecognized = unrecognized
    }

    public static let `default` = AppLaunchOptions(startsSession: true, requestsPermissions: true)

    /// 素振りの既定の秒数。**2 つの筋書きを一巡できる長さ。**
    ///
    /// `HUDRehearsal.wiringScript`（製品と同じ経路。約 3 秒）＋
    /// `HUDRehearsal.script`（見た目の網羅。約 9 秒）＝ 約 12.1 秒。
    /// **足りないと後ろの表示を誰も見ない**ので、`HUDRehearsalTests` が総和と比べている。
    public static let defaultHUDRehearsalSeconds: Double = 16

    /// 窓の素振りの既定の秒数。**4 つの区間を 3 秒ずつ測れる長さ。**
    public static let defaultWindowRehearsalSeconds: Double = 12

    /// 終了の素振りの既定の秒数。**「抱えている」ことがログで判る長さ**
    /// （猶予 10 秒より十分に短く、待ちが効いていることは目で見て判る）。
    public static let defaultShutdownRehearsalSeconds: Double = 3

    /// - Parameter arguments: `CommandLine.arguments` の先頭（実行ファイル名）を除いたもの。
    public static func parse(_ arguments: [String]) -> AppLaunchOptions {
        var startsSession = true
        var requestsPermissions = true
        var hudRehearsalSeconds: Double?
        var windowRehearsalSeconds: Double?
        var shutdownRehearsalSeconds: Double?
        var unrecognized: [String] = []

        for argument in arguments {
            switch argument {
            case "--shell-only":
                // **器だけ。** セッションを作らないなら権限を要求する理由も無い。
                startsSession = false
                requestsPermissions = false
            case "--no-permission-prompts":
                requestsPermissions = false
            case "--hud-check":
                // **セッションを作らない。** マイクにもタップにも触れない（ダイアログが出ない）。
                startsSession = false
                requestsPermissions = false
                hudRehearsalSeconds = defaultHUDRehearsalSeconds
            case let other where other.hasPrefix("--hud-check="):
                startsSession = false
                requestsPermissions = false
                let value = Double(other.dropFirst("--hud-check=".count))
                // **読めない秒数を黙って既定へ倒さない。** 「12 秒のつもりが 1.2 秒だった」
                // のような取り違えは、目視の検証では気づけない。
                if let value, value > 0 {
                    hudRehearsalSeconds = value
                } else {
                    unrecognized.append(other)
                    hudRehearsalSeconds = defaultHUDRehearsalSeconds
                }
            case "--window-check":
                // **セッションを作らない。** マイクにもタップにも触れない（ダイアログが出ない）。
                startsSession = false
                requestsPermissions = false
                windowRehearsalSeconds = defaultWindowRehearsalSeconds
            case let other where other.hasPrefix("--window-check="):
                startsSession = false
                requestsPermissions = false
                let value = Double(other.dropFirst("--window-check=".count))
                // **読めない秒数を黙って既定へ倒さない**（`--hud-check` と同じ判断）。
                if let value, value > 0 {
                    windowRehearsalSeconds = value
                } else {
                    unrecognized.append(other)
                    windowRehearsalSeconds = defaultWindowRehearsalSeconds
                }
            case "--shutdown-check":
                // **セッションを作らない。** マイクにもタップにも触れない（ダイアログが出ない）。
                startsSession = false
                requestsPermissions = false
                shutdownRehearsalSeconds = defaultShutdownRehearsalSeconds
            case let other where other.hasPrefix("--shutdown-check="):
                startsSession = false
                requestsPermissions = false
                let value = Double(other.dropFirst("--shutdown-check=".count))
                // **0 は正しい入力である**（`--hud-check` と違う点。「抱えていないときの終了」を
                // 測るための値であり、まさにそこが壊れていた）。負の値と読めない値だけを弾く。
                if let value, value >= 0 {
                    shutdownRehearsalSeconds = value
                } else {
                    unrecognized.append(other)
                    shutdownRehearsalSeconds = defaultShutdownRehearsalSeconds
                }
            case let other where other.hasPrefix("-psn_"):
                // LaunchServices が付ける Process Serial Number。**誤りではない。**
                continue
            default:
                unrecognized.append(argument)
            }
        }

        return AppLaunchOptions(
            startsSession: startsSession,
            requestsPermissions: requestsPermissions,
            hudRehearsalSeconds: hudRehearsalSeconds,
            windowRehearsalSeconds: windowRehearsalSeconds,
            shutdownRehearsalSeconds: shutdownRehearsalSeconds,
            unrecognized: unrecognized)
    }
}

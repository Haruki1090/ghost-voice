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

    /// 解釈できなかった引数。**黙って捨てない**（標準エラーへ出す）。
    public let unrecognized: [String]

    public init(startsSession: Bool, requestsPermissions: Bool, unrecognized: [String] = []) {
        self.startsSession = startsSession
        self.requestsPermissions = requestsPermissions
        self.unrecognized = unrecognized
    }

    public static let `default` = AppLaunchOptions(startsSession: true, requestsPermissions: true)

    /// - Parameter arguments: `CommandLine.arguments` の先頭（実行ファイル名）を除いたもの。
    public static func parse(_ arguments: [String]) -> AppLaunchOptions {
        var startsSession = true
        var requestsPermissions = true
        var unrecognized: [String] = []

        for argument in arguments {
            switch argument {
            case "--shell-only":
                // **器だけ。** セッションを作らないなら権限を要求する理由も無い。
                startsSession = false
                requestsPermissions = false
            case "--no-permission-prompts":
                requestsPermissions = false
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
            unrecognized: unrecognized)
    }
}

import Foundation
import GhostVoiceCore

/// 常駐実行時の指定。
public struct RunOptions: Sendable, Equatable {

    /// ⌘V の送出からクリップボードを戻すまでの待ち。
    ///
    /// **nil は「実装の既定（`PasteboardInserter.defaultRestoreDelay`）に従う」であって、
    /// 120 ms の写しではない。** 値の出所を 1 箇所に保つ。
    ///
    /// V-3 で「`.pasteboard` と記録されたのに何も貼り付いていない」アプリが出たら、
    /// ここを延ばして再試行する（詳細設計書 §6.3 の実測は自プロセスの `NSTextView` 相手で、
    /// 相手が重いアプリなら往復が伸びうる）。
    public var pasteRestoreDelay: Duration?

    public init(pasteRestoreDelay: Duration? = nil) {
        self.pasteRestoreDelay = pasteRestoreDelay
    }
}

public enum CLICommand: Sendable, Equatable {
    case run(RunOptions)
    /// 権限の照会だけを行う。**何の許可も求めない**（ダイアログを出さない）。
    case check
    /// 許可を求める。**ダイアログが出る。**
    case requestPermissions
    /// マイクを 1 秒だけ開いて、実際にバッファが届くかを見る。**録音内容は保存しない。**
    ///
    /// `--check` が見るのは TCC の照会結果だけで、**実際に開けるかは別の問い**である
    /// （詳細設計書 §3.3 は「素の実行ファイルではマイクを使えない」と書いていた）。
    case micCheck
    case help
    /// 使い方の誤り。文面には何が悪かったかを入れる。
    case usageError(String)

    public var isUsageError: Bool {
        if case .usageError = self { return true }
        return false
    }

    public var usageErrorMessage: String? {
        if case .usageError(let message) = self { return message }
        return nil
    }
}

public enum CommandLineOptions {

    public static let usage = """
        使い方: ghost-voice [オプション]

          （なし）                         常駐して PTT ディクテーションを行う
          --check                          権限と設定の状態を表示して終了する（許可は求めない）
          --request-permissions            マイク・入力監視・アクセシビリティの許可を求める
          --mic-check                      マイクを 1 秒開いて実際に録れるか確かめる（保存しない）
          --paste-restore-delay-ms <ミリ秒>  ⌘V 送出後にクリップボードを戻すまでの待ち
          --help, -h                       この使い方を表示する
        """

    /// - Parameter arguments: 実行ファイル名を**除いた**引数列。
    public static func parse(_ arguments: [String]) -> CLICommand {
        var options = RunOptions()
        // **動作を決める旗は 1 つだけ。** 2 つ並べたときにどちらが勝つかを
        // 黙って決めると、`--check --request-permissions` が許可を求めてしまう。
        var mode: CLICommand?
        var index = arguments.startIndex

        func claim(_ command: CLICommand, _ flag: String) -> CLICommand? {
            guard mode == nil else {
                return .usageError("\(flag) は他の動作指定と同時に使えません")
            }
            mode = command
            return nil
        }

        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--check":
                if let error = claim(.check, argument) { return error }
            case "--request-permissions":
                if let error = claim(.requestPermissions, argument) { return error }
            case "--mic-check":
                if let error = claim(.micCheck, argument) { return error }
            case "--help", "-h":
                if let error = claim(.help, argument) { return error }
            case "--paste-restore-delay-ms":
                // **後勝ちで黙って上書きしない。** 同じファイルで「知らない旗は黙って
                // 無視しない」と決めている以上、値を取る旗の重複も同じ扱いにする。
                // 指定した値と違う値で動いていることに気づけないのが最も困る。
                guard options.pasteRestoreDelay == nil else {
                    return .usageError("--paste-restore-delay-ms は 1 回だけ指定できます")
                }
                index = arguments.index(after: index)
                guard index < arguments.endIndex else {
                    return .usageError("--paste-restore-delay-ms には値が要ります")
                }
                guard let value = Int(arguments[index]), value >= 0 else {
                    return .usageError(
                        "--paste-restore-delay-ms の値が不正です: \(arguments[index])")
                }
                options.pasteRestoreDelay = .milliseconds(value)
            default:
                return .usageError("知らないオプションです: \(argument)")
            }
            index = arguments.index(after: index)
        }

        if let mode {
            // 常駐実行にしか効かない指定を、他の動作へ黙って付けさせない。
            guard options == RunOptions() else {
                return .usageError("--paste-restore-delay-ms は常駐実行のときだけ使えます")
            }
            return mode
        }
        return .run(options)
    }
}

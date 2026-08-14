import Foundation
import Testing

@testable import GhostVoiceCLI
@testable import GhostVoiceCore

@Suite("CLI: 引数の解釈")
struct CLIOptionsTests {

    @Test("引数なしは常駐実行")
    func noArgumentsRuns() {
        #expect(CommandLineOptions.parse([]) == .run(RunOptions()))
    }

    @Test("--check は権限の照会だけを行う")
    func checkFlag() {
        #expect(CommandLineOptions.parse(["--check"]) == .check)
    }

    @Test("--request-permissions は許可を求める")
    func requestFlag() {
        #expect(CommandLineOptions.parse(["--request-permissions"]) == .requestPermissions)
    }

    /// 照会（`--check`）と実際に開けるか（`--mic-check`）は別の問いなので、旗も別にする。
    @Test("--mic-check はマイクを実際に開く確認")
    func micCheckFlag() {
        #expect(CommandLineOptions.parse(["--mic-check"]) == .micCheck)
    }

    @Test("--help と -h は使い方を出す")
    func helpFlags() {
        #expect(CommandLineOptions.parse(["--help"]) == .help)
        #expect(CommandLineOptions.parse(["-h"]) == .help)
    }

    /// V-3 で「貼り付く前にクリップボードが戻る」疑いが出たときに、
    /// **ビルドし直さずに** 復元待ちを延ばせるようにしてある（詳細設計書 §6.3）。
    @Test("--paste-restore-delay-ms は復元待ちを差し替える")
    func pasteRestoreDelayOption() {
        #expect(
            CommandLineOptions.parse(["--paste-restore-delay-ms", "300"])
                == .run(RunOptions(pasteRestoreDelay: .milliseconds(300))))
        // 既定は「指定なし」であって 120 ms の写しではない。値の出所を 1 箇所に保つ。
        #expect(RunOptions().pasteRestoreDelay == nil)
    }

    @Test("復元待ちの値が無い・数でない・負なら使い方の誤りとして扱う")
    func pasteRestoreDelayRejectsBadValues() {
        for arguments in [
            ["--paste-restore-delay-ms"],
            ["--paste-restore-delay-ms", "abc"],
            ["--paste-restore-delay-ms", "-1"],
        ] {
            let parsed = CommandLineOptions.parse(arguments)
            #expect(parsed.isUsageError, "\(arguments) が使い方の誤りにならなかった")
        }
        // 0 は「復元待ちなし」として通す。V-3 で境界を確かめたい場合に使う。
        #expect(
            CommandLineOptions.parse(["--paste-restore-delay-ms", "0"])
                == .run(RunOptions(pasteRestoreDelay: .zero)))
    }

    /// 値を取る旗の重複を後勝ちにすると、**指定した値と違う値で動いていることに
    /// 気づけない。** 動作を決める旗（`--check` など）の重複と同じ扱いにする。
    @Test("復元待ちを 2 回指定したら拒否する")
    func duplicatePasteRestoreDelayIsRejected() throws {
        let parsed = CommandLineOptions.parse([
            "--paste-restore-delay-ms", "300", "--paste-restore-delay-ms", "50",
        ])
        let message = try #require(parsed.usageErrorMessage)
        #expect(message.contains("--paste-restore-delay-ms"))
        #expect(message.contains("1 回"))
    }

    /// **知らない旗を黙って無視してはならない。** 綴り違いのまま
    /// 「指定したはずの設定が効いている」と信じることになる。
    @Test("知らない旗はその名前を添えて拒否する")
    func unknownFlagIsRejected() throws {
        let parsed = CommandLineOptions.parse(["--bogus"])
        let message = try #require(parsed.usageErrorMessage)
        #expect(message.contains("--bogus"))
    }

    @Test("動作を決める旗を 2 つ並べたら拒否する")
    func conflictingCommandsAreRejected() {
        #expect(CommandLineOptions.parse(["--check", "--help"]).isUsageError)
        #expect(CommandLineOptions.parse(["--check", "--request-permissions"]).isUsageError)
    }

    @Test("使い方の文面には全ての旗が載っている")
    func usageMentionsEveryFlag() {
        let usage = CommandLineOptions.usage
        for flag in [
            "--check", "--request-permissions", "--mic-check", "--paste-restore-delay-ms", "--help",
        ] {
            #expect(usage.contains(flag), "\(flag) が使い方に載っていない")
        }
    }
}

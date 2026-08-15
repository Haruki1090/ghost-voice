import Testing

@testable import GhostVoiceApp

@Suite("アプリの起動引数")
struct AppLaunchOptionsTests {

    @Test("既定ではセッションを組み立て、足りない権限を要求する")
    func defaults() {
        let options = AppLaunchOptions.parse([])
        #expect(options.startsSession)
        #expect(options.requestsPermissions)
        #expect(options.unrecognized.isEmpty)
        #expect(options == AppLaunchOptions.default)
    }

    /// **`--shell-only` は TCC に一切触れないことが要点である。**
    /// 器の確認（フォーカスを奪わないか・window の配置）を、権限ダイアログを出さずに行うための入口。
    @Test("--shell-only はセッションも権限要求も行わない")
    func shellOnly() {
        let options = AppLaunchOptions.parse(["--shell-only"])
        #expect(!options.startsSession)
        #expect(!options.requestsPermissions)
    }

    @Test("--no-permission-prompts はセッションだけ組み立てる")
    func noPrompts() {
        let options = AppLaunchOptions.parse(["--no-permission-prompts"])
        #expect(options.startsSession)
        #expect(!options.requestsPermissions)
    }

    /// LaunchServices は `-psn_0_12345` を付けて起動することがある。**誤りではない。**
    @Test("LaunchServices の -psn_ 引数を誤りとして扱わない")
    func processSerialNumber() {
        let options = AppLaunchOptions.parse(["-psn_0_1234567"])
        #expect(options.unrecognized.isEmpty)
        #expect(options.startsSession)
    }

    @Test("知らない引数は黙って捨てない")
    func unrecognized() {
        let options = AppLaunchOptions.parse(["--shell-only", "--nonsense"])
        #expect(options.unrecognized == ["--nonsense"])
        #expect(!options.startsSession)
    }

    /// **`--hud-check` も TCC に触れないことが要点である。**
    /// HUD の目視確認（V-20 / V-21 / V-22）は、権限を付ける前でも行えなければならない——
    /// 権限が要るなら「HUD が出ないのは権限のせいか実装のせいか」が切り分けられなくなる。
    @Test("--hud-check はセッションを作らず、権限も要求しない")
    func hudCheckTouchesNothing() {
        let options = AppLaunchOptions.parse(["--hud-check"])
        #expect(!options.startsSession)
        #expect(!options.requestsPermissions)
        #expect(options.hudRehearsalSeconds == AppLaunchOptions.defaultHUDRehearsalSeconds)
        #expect(options.unrecognized.isEmpty)
    }

    @Test("--hud-check=秒 で長さを指定できる")
    func hudCheckWithSeconds() {
        let options = AppLaunchOptions.parse(["--hud-check=30"])
        #expect(options.hudRehearsalSeconds == 30)
        #expect(!options.startsSession)
    }

    /// **読めない秒数を黙って既定へ倒さない。**
    /// 「30 秒のつもりが 12 秒だった」という取り違えは、目視の検証では気づけない。
    @Test("--hud-check= の値が読めなければ誤りとして報告する")
    func hudCheckWithBadSeconds() {
        let options = AppLaunchOptions.parse(["--hud-check=abc"])
        #expect(options.unrecognized == ["--hud-check=abc"])
        #expect(options.hudRehearsalSeconds == AppLaunchOptions.defaultHUDRehearsalSeconds)

        let negative = AppLaunchOptions.parse(["--hud-check=-3"])
        #expect(negative.unrecognized == ["--hud-check=-3"])
    }

    @Test("既定では素振りをしない")
    func noRehearsalByDefault() {
        #expect(AppLaunchOptions.parse([]).hudRehearsalSeconds == nil)
        #expect(AppLaunchOptions.parse(["--shell-only"]).hudRehearsalSeconds == nil)
        #expect(AppLaunchOptions.parse([]).shutdownRehearsalSeconds == nil)
        #expect(AppLaunchOptions.parse(["--shell-only"]).shutdownRehearsalSeconds == nil)
    }

    /// **`--shutdown-check` も TCC に触れない。**
    /// V-34（終了で発話が失われないか）は、これが無いと**実発話でしか通らない経路**で、
    /// 実バンドルでは一度も測られていなかった。その結果 `SIGTERM` で終わらない `.app` が
    /// 利用者の手元に渡った（`bug-term`）。
    @Test("--shutdown-check はセッションを作らず、権限も要求しない")
    func shutdownCheckTouchesNothing() {
        let options = AppLaunchOptions.parse(["--shutdown-check"])
        #expect(!options.startsSession)
        #expect(!options.requestsPermissions)
        #expect(options.shutdownRehearsalSeconds == AppLaunchOptions.defaultShutdownRehearsalSeconds)
        #expect(options.unrecognized.isEmpty)
    }

    /// **0 は正しい入力である**（`--hud-check` と違う点）。
    /// 「発話を抱えていないのに終わらない」がまさに実機で起きた形なので、
    /// **0 秒を渡せなければこの欠陥を測れない。**
    @Test("--shutdown-check=0 は誤りではない（抱えていないときの終了を測る）")
    func shutdownCheckAcceptsZero() {
        let options = AppLaunchOptions.parse(["--shutdown-check=0"])
        #expect(options.shutdownRehearsalSeconds == 0)
        #expect(options.unrecognized.isEmpty)
        #expect(!options.startsSession)
    }

    @Test("--shutdown-check=秒 で長さを指定できる")
    func shutdownCheckWithSeconds() {
        #expect(AppLaunchOptions.parse(["--shutdown-check=5"]).shutdownRehearsalSeconds == 5)
    }

    @Test("--shutdown-check= の値が読めなければ誤りとして報告する")
    func shutdownCheckWithBadSeconds() {
        let options = AppLaunchOptions.parse(["--shutdown-check=abc"])
        #expect(options.unrecognized == ["--shutdown-check=abc"])
        #expect(
            options.shutdownRehearsalSeconds == AppLaunchOptions.defaultShutdownRehearsalSeconds)

        let negative = AppLaunchOptions.parse(["--shutdown-check=-3"])
        #expect(negative.unrecognized == ["--shutdown-check=-3"])
    }
}

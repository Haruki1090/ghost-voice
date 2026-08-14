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
    }
}

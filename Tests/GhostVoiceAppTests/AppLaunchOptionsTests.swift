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
}

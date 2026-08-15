import Foundation
import GhostVoiceCore
import Synchronization
import Testing

@testable import GhostVoiceApp

/// 代役をまたいだ呼び出しの順序を記録する。
///
/// **順序は機体の速さで決まってはならない。** 「先に呼ばれたはず」を時刻の比較で
/// 検査すると、負荷が乗った回に入れ替わって断続的に落ちる。ここは実際の呼び出し順を
/// そのまま並べる。
private final class CallOrder: Sendable {
    private let entries = Mutex<[String]>([])
    var calls: [String] { entries.withLock { $0 } }
    func record(_ name: String) { entries.withLock { $0.append(name) } }
}

/// クロージャをまたいで読み書きする旗。
private final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// **`.app` の終了も、CLI と同じ 1 つの段取りを通る。**
///
/// 待ち合わせと文言の中身は `GhostVoiceCore` 側の検査
/// （`ShutdownSequenceTests`）が固定している。ここが見るのは
/// **アプリがその 1 実装に本当に繋がっているか**と、
/// アプリ固有の出口（`applicationShouldTerminate`）が途中で落とさないことである。
@Suite("終了の待ち合わせ（.app 側）")
struct AppShutdownTests {

    /// **アプリ側に別の段取りが復活していないこと。**
    /// 合流時点では `AppTermination` という 2 つ目の実装があり、
    /// `ShutdownWaitOutcome` が同名で 2 定義されていた。
    @Test("アプリの既定の猶予は Core のものと同じ 1 つの値である")
    func graceComesFromCore() {
        #expect(Shutdown.defaultGrace == .seconds(10))
    }

    /// **文言もアプリ側で持たない。** 2 箇所にあると片方だけ育ち、
    /// 「利用者が何を待たれているか判る」性質が片側で失われる。
    @Test("終了の文言は Core のものを使う")
    func announcementTextComesFromCore() {
        let text = ShutdownAnnouncement.waiting(grace: Shutdown.defaultGrace).text
        #expect(text.contains("録音中なら PTT キーを離してください"))
        #expect(ShutdownAnnouncement.utteranceInterrupted(.lost).text.contains("どこにも残せませんでした"))
    }

    /// **終了の文言をログだけに流していないこと。**
    ///
    /// 実機 2026-08-15: 文言は正しかったが `.app` では unified log にしか出ず、
    /// **利用者は「キーを離してください」を一度も見ないまま猶予 10 秒を使い切った。**
    /// `AppDiagnostics.note` を直に渡す形へ戻すと、その状態に戻る。
    @Test("終了の文言は HUD にも流す出口（AppShutdownAnnouncer）を通る")
    func announcementsGoThroughTheHUDSink() throws {
        for path in [
            "Sources/GhostVoiceApp/Shell/AppSessionRuntime.swift",
            "Sources/GhostVoiceApp/Shell/ShutdownRehearsal.swift",
        ] {
            let code = try Self.sourceWithoutComments(path)
            #expect(
                code.contains("announce: AppShutdownAnnouncer.sink"),
                "\(path) が終了の文言をログだけに流している")
            #expect(
                !code.contains("announce: { AppDiagnostics.note"),
                "\(path) がログ直行に戻っている（HUD に何も出ない）")
        }
        // 器が受け手を繋いでいること。繋がなければ出口はあっても届かない。
        let delegate = try Self.sourceWithoutComments(
            "Sources/GhostVoiceApp/Shell/GhostVoiceAppDelegate.swift")
        #expect(delegate.contains("AppShutdownAnnouncer.use("))
        #expect(delegate.contains("as? any ShutdownAnnouncingSurface"))
    }

    /// **ログには必ず残ること。** HUD が死んでいる状況でも終了待ちは起きる——
    /// 直前に直した欠陥（メインキューが詰まって `@MainActor` が全部死ぬ）がまさにそれで、
    /// そのときログだけが残る。**HUD だけに寄せてはならない。**
    @Test("終了の文言は HUD の有無にかかわらずログへ出る")
    func announcementsAlwaysReachTheLog() throws {
        let code = try Self.sourceWithoutComments(
            "Sources/GhostVoiceApp/Shell/AppShutdownAnnouncer.swift")
        let sink = try #require(code.range(of: "static let sink"))
        let body = String(code[sink.upperBound...])
        let note = try #require(body.range(of: "AppDiagnostics.note(announcement.text)"))
        let hud = try #require(body.range(of: "showShutdown(announcement)"))
        #expect(note.lowerBound < hud.lowerBound, "HUD の前にログへ出していない")
    }

    /// **HUD へ渡すのはメインを経由すること。** `Shutdown.perform` は `nonisolated` で、
    /// 一般の実行文脈から `announce` を呼ぶ。直に `@MainActor` を触ると成立しない。
    @Test("HUD へはメインへ渡してから出す")
    func hudIsTouchedOnMain() throws {
        let code = try Self.sourceWithoutComments(
            "Sources/GhostVoiceApp/Shell/AppShutdownAnnouncer.swift")
        #expect(code.contains("Task { @MainActor in"))
    }

    /// アプリは `stateUpdates` を消費しない（**HUD は分配器の `stateStream()` を使う**）ので門を持たない。
    /// **その経路でも「待つ → 止める → 見届ける」は変わらない。**
    @Test("門を持たない経路でも、待ってから止め、run() を見届ける")
    func appPathFollowsTheOrder() async throws {
        let order = CallOrder()
        let busy = MutableFlag(true)

        let release = Task {
            try? await Task.sleep(for: .milliseconds(120))
            busy.value = false
        }
        defer { release.cancel() }

        await Shutdown.perform(
            grace: .seconds(5), poll: .milliseconds(10),
            stopHotkey: {
                #expect(!busy.value, "処理中に監視を止めた（発話が失われる）")
                order.record("stop")
            },
            awaitRun: {
                order.record("awaitRun.start")
                try? await Task.sleep(for: .milliseconds(50))
                order.record("awaitRun.end")
            },
            isBusy: { busy.value },
            announce: { _ in })

        #expect(order.calls == ["stop", "awaitRun.start", "awaitRun.end"])
    }

    // MARK: - ソースそのものへの検査

    /// **終了要求を素通しさせないこと。**
    ///
    /// `NSApp.terminate(_:)` をそのまま通すと、⌘V 送出後・クリップボード復元前に
    /// 落ちて発話が失われる。`applicationShouldTerminate` は `.terminateLater` を返し、
    /// **`shutdown()` を待ってから**返事をしなければならない。
    ///
    /// **これは振る舞いでは検査できない**（実際に走らせるとテストプロセスが終了する）。
    /// だからソースの形として固定する（`BundleContractTests` と同じ形）。
    @Test("終了要求は素通ししない（.terminateLater を返し、shutdown を待ってから返事する）")
    func terminationIsNotPassedThrough() throws {
        let code = try Self.sourceWithoutComments(
            "Sources/GhostVoiceApp/Shell/GhostVoiceAppDelegate.swift")
        let shouldTerminate = try #require(code.range(of: "func applicationShouldTerminate("))
        let body = code[shouldTerminate.upperBound...]
        #expect(body.contains(".terminateLater"))

        let shutdown = try #require(
            body.range(of: "await shutdownTarget.shutdown()"), "段取りを通っていない")
        let reply = try #require(
            body.range(of: "NSApp.reply(toApplicationShouldTerminate: true)"), "返事をしていない")
        #expect(shutdown.lowerBound < reply.lowerBound, "段取りを待たずに終了を許している")
        // アプリ側に `exit()` は 1 つも無い（終了は AppKit の経路だけを通る）。
        #expect(!code.contains("exit("))
    }

    /// **終了の判断は `state` ではなく `isBusy`。**
    /// `state` は emit でしか変わらないので、押下を受けてから最初の emit までの窓を
    /// 「待機」と読み違え、そこでホットキーを止めると発話が丸ごと消える。
    @Test("アプリの終了判断は session.state ではなく isBusy を見る")
    func appJudgesOnIsBusy() throws {
        let code = try Self.sourceWithoutComments(
            "Sources/GhostVoiceApp/Shell/AppSessionRuntime.swift")
        #expect(code.contains("await session.isBusy"))
        #expect(!code.contains("await session.state"), "終了の判断に state を使っている")
        // 段取りは Core の 1 実装だけを通る。
        #expect(code.contains("await Shutdown.perform("))
    }

    // MARK: - シグナルの受け口（実機で 17 分止まった箇所）

    /// **終了要求の受け口をメインキューに置いてはならない。**
    ///
    /// 置くと、ハンドラが**メインキューのブロックとして**走り、その中で
    /// `.terminateLater` の入れ子のランループへ入る。返事を出す `Task` は
    /// メインキューへ積まれるので**二度と走らず、プロセスが終わらない**
    /// （実機で `SIGTERM` も `pkill` も効かず `kill -9` しか残らなかった）。
    /// 機序と実測は `MainRunLoopHop` の注記、届くことの検査は `MainRunLoopHopTests` にある。
    ///
    /// **これは振る舞いでは検査できない**——テストプロセスごと終了してしまう。
    /// だからソースの形として固定する（`terminationIsNotPassedThrough` と同じ形）。
    @Test("シグナルの受け口はメインキューに置かず、メインへは MainRunLoopHop で渡す")
    func signalTrapDoesNotUseTheMainQueue() throws {
        let code = try Self.sourceWithoutComments(
            "Sources/GhostVoiceApp/Shell/GhostVoiceAppDelegate.swift")
        let install = try #require(code.range(of: "func installSignalTrap()"))
        let body = String(code[install.upperBound...])
        let end = try #require(body.range(of: "\n    }"))
        let trap = String(body[..<end.lowerBound])

        #expect(!trap.contains("queue: .main"), "受け口がメインキューに戻っている（終了要求が届かない）")
        #expect(trap.contains("DispatchQueue(label:"), "専用のキューを使っていない")
        #expect(code.contains("MainRunLoopHop.perform"), "メインへの受け渡しが素の main キューに戻っている")
        #expect(!code.contains("DispatchQueue.main.async { NSApp.terminate"))
    }

    /// **ハンドラは `nonisolated` でなければならない。**
    ///
    /// `@MainActor` の文脈で `setEventHandler { … }` とクロージャを直接書くと、
    /// そのクロージャは `@MainActor` を継ぎ、入口に隔離の実行時検査が入る。
    /// **メイン以外のキューに載せた瞬間 `SIGTRAP` で即死する**
    /// （実測 2026-08-15。使い捨てプログラムで終了コード 133。`MainRunLoopHop` の表）。
    ///
    /// 即死は「終わらない」より悪い——**終了処理を 1 行も通らずに消えるので、
    /// ⌘V 送出後・クリップボード復元前なら発話がそのまま失われる。**
    ///
    /// **これも振る舞いでは検査できない**（当たればテストプロセスが落ちる）。
    @Test("シグナルのハンドラはクロージャで書かず、nonisolated な関数を渡す")
    func signalHandlerIsNotIsolated() throws {
        let code = try Self.sourceWithoutComments(
            "Sources/GhostVoiceApp/Shell/GhostVoiceAppDelegate.swift")
        #expect(
            code.contains("setEventHandler(handler: Self.requestTermination)"),
            "ハンドラをクロージャで書いている（背景キューで SIGTRAP になる）")
        #expect(code.contains("private nonisolated static func requestTermination()"))
        #expect(!code.contains("source.setEventHandler {"), "クロージャが復活している")
    }

    // MARK: - 終了の素振り（--shutdown-check）

    /// **素振りも本物と同じ順序で畳むこと。** 素振りが本物と違う順序で通ると、
    /// V-34 の手順は緑なのに製品が壊れている、という形になる。
    @Test("素振りは、待機へ戻るまで待ってからホットキーを止め、run() を見届ける")
    @MainActor
    func rehearsalWaitsForTheUtterance() async throws {
        let rehearsal = ShutdownRehearsal(busyFor: .milliseconds(200))
        #expect(!rehearsal.didDeliverUtterance)

        let started = ContinuousClock.now
        await rehearsal.shutdown(grace: .seconds(5))
        let elapsed = ContinuousClock.now - started

        // **抱えていた発話を最後まで届けてから戻ること。**
        #expect(rehearsal.didDeliverUtterance, "抱えていた発話を見届けずに終わった")
        // 合否線は要件値ではない。「待ちが効いていない」（＝即座に戻る）ことだけを弾く。
        #expect(elapsed >= .milliseconds(150), "待たずに畳んでいる")
    }

    /// **抱えていないときは待たないこと。** ここが待つと、実機で見つかった
    /// 「発話が無いのに終わらない」の再現になる。
    @Test("抱えていなければ素振りは即座に終わる")
    @MainActor
    func rehearsalWithNothingHeldFinishesAtOnce() async throws {
        let rehearsal = ShutdownRehearsal(busyFor: .zero)
        let started = ContinuousClock.now
        await rehearsal.shutdown(grace: .seconds(5))
        // 上限は「戻らない実装を黙って待たない」ための値であり、要件値ではない。
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(rehearsal.didDeliverUtterance)
    }

    /// リポジトリの根。**テストの置き場所から辿る**（作業ディレクトリに依存しない）。
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // GhostVoiceAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // リポジトリの根

    /// コメント行を落としたソース。**注記の中の `exit()` を数えないため。**
    static func sourceWithoutComments(_ relativePath: String) throws -> String {
        let text = try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        return
            text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

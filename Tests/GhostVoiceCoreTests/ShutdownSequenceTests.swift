import Foundation
import Synchronization
import Testing

@testable import GhostVoiceCore

/// 終了時の文言を溜める。**出力先ではなく、言われた事実そのものを見る。**
final class AnnouncementLog: Sendable {
    private let entries = Mutex<[ShutdownAnnouncement]>([])
    var announcements: [ShutdownAnnouncement] { entries.withLock { $0 } }
    var text: String { entries.withLock { $0.map(\.text).joined(separator: "\n") } }
    func record(_ announcement: ShutdownAnnouncement) { entries.withLock { $0.append(announcement) } }
}

/// 「いま発話を抱えているか」の身代わり。
private actor BusyStub {
    private var remaining: Int
    private(set) var calls = 0
    /// - Parameter busyTimes: 何回目までを「処理中」と答えるか。`nil` なら永久に処理中。
    init(busyTimes: Int?) { self.remaining = busyTimes ?? Int.max }
    func isBusy() -> Bool {
        calls += 1
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

/// **「発話を失わない終了順序」の本体。** CLI も `.app` もここを通る。
///
/// フェーズ 2 の合流時点では、同じ規律が CLI と `.app` に**独立に 2 実装**あった
/// （`ShutdownWaitOutcome` が同名で 2 定義、段取りも 2 実装）。
/// **2 箇所ある状態は必ずずれ、しかも両方とも自分のテストでは緑になる。**
/// ここはその 1 実装に対する検査であり、**フェーズ 1 が潰した欠陥が移設で復活していないこと**を
/// 固定するためにある。
@Suite("終了の段取り（Core・CLI と .app の共通）")
struct ShutdownSequenceTests {

    // MARK: - ShutdownGate

    @Test("待機中なら即座に戻る")
    func idleGateReturnsImmediately() async {
        let gate = ShutdownGate()
        #expect(await gate.waitUntilIdle(within: .seconds(5)) == .idle)
    }

    @Test("挿入中なら待機へ戻るまで戻らない")
    func gateWaitsForIdle() async throws {
        let gate = ShutdownGate()
        await gate.observe(.inserting)

        // **「戻っていない」ことを表明する。** ここを書かないと、常に即座に戻る実装でも
        // 検査が通ってしまう（待ち合わせの検査が空虚に真になる典型）。
        let returned = Atomic<Bool>(false)
        let waiter = Task {
            let outcome = await gate.waitUntilIdle(within: .seconds(10))
            returned.store(true, ordering: .relaxed)
            return outcome
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(returned.load(ordering: .relaxed) == false)
        await gate.observe(.idle)
        #expect(await waiter.value == .idle)
    }

    /// `.failed` の直後には必ず `.idle` が続く（`DictationSession` の契約）。
    /// **`.failed` を待機と読み違えると、その直後の後始末を待たずに終わる。**
    @Test("失敗の表示は待機ではない")
    func failedIsNotIdle() async throws {
        let gate = ShutdownGate()
        await gate.observe(.failed(.noSpeechRecognized))
        let returned = Atomic<Bool>(false)
        let waiter = Task {
            let outcome = await gate.waitUntilIdle(within: .seconds(10))
            returned.store(true, ordering: .relaxed)
            return outcome
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(returned.load(ordering: .relaxed) == false)
        await gate.observe(.idle)
        #expect(await waiter.value == .idle)
    }

    @Test("猶予を過ぎたら打ち切って、打ち切ったことを返す")
    func gateTimesOut() async {
        let gate = ShutdownGate()
        await gate.observe(.recording(volatileText: ""))
        let started = ContinuousClock.now
        let outcome = await gate.waitUntilIdle(within: .milliseconds(150))
        let elapsed = ContinuousClock.now - started
        #expect(outcome == .timedOut)
        #expect(elapsed >= .milliseconds(150))
    }

    /// 状態の列が終わった時点で、セッションは処理中の発話を見届けている
    /// （`run()` は `completionTask` を待ってから終端する）。
    @Test("状態の列が終わったら待機とみなす")
    func gateReleasesWhenStreamFinishes() async throws {
        let gate = ShutdownGate()
        await gate.observe(.inserting)
        let waiter = Task { await gate.waitUntilIdle(within: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        await gate.streamFinished()
        #expect(await waiter.value == .idle)
    }

    // MARK: - 段取り（順序）

    /// 順序に意味がある（`Shutdown` の注記）。**待つ → 止める → 見届ける** の順でなければ、
    /// 押しっぱなしのキーの解放が届かなくなったり、挿入の途中で落ちたりする。
    @Test("終了は「待つ・止める・見届ける」の順で行い、見届けを飛ばさない")
    func shutdownFollowsTheOrder() async throws {
        let order = CallOrder()
        let gate = ShutdownGate()
        let log = AnnouncementLog()

        // **門を待機以外にしておく。** 新品の門（＝最初から待機）で測ると
        // `waitUntilIdle` が即座に戻るので、**待ちを止めた後ろへ動かしても順序が変わらない**
        // （この検査だけでは「待つ→止める」を固定できない）。
        await gate.observe(.inserting)
        let release = Task {
            try? await Task.sleep(for: .milliseconds(100))
            order.record("idle")
            await gate.observe(.idle)
        }
        defer { release.cancel() }

        await Shutdown.perform(
            gate: gate, grace: .seconds(5),
            stopHotkey: { order.record("stop") },
            awaitRun: {
                order.record("awaitRun.start")
                try? await Task.sleep(for: .milliseconds(100))
                order.record("awaitRun.end")
            },
            isBusy: {
                order.record("isBusy")
                return false
            },
            announce: { log.record($0) })

        // **完全一致では固定できない。** 待ちの間に状態機械へ確認する
        // （門は 1 手遅れるため。`Shutdown` の注記）ので `isBusy` は複数回呼ばれる。
        // 固定したいのは**順序の不変条件**である。
        let calls = order.calls
        let idle = try #require(calls.firstIndex(of: "idle"), "待機を観測していない")
        let stop = try #require(calls.firstIndex(of: "stop"), "監視を止めていない")
        let runStart = try #require(calls.firstIndex(of: "awaitRun.start"), "run() を見届けていない")
        let runEnd = try #require(calls.firstIndex(of: "awaitRun.end"))

        #expect(idle < stop, "待機へ戻る前に監視を止めている（押しっぱなしの解放が届かない）")
        #expect(stop < runStart, "監視を止める前に run() を待っている")
        #expect(runStart < runEnd)
        #expect(calls.last == "isBusy", "見届けた後に最終状態を見ていない")
    }

    /// **門は状態機械より 1 手遅れる。**
    ///
    /// 押下の直後に終了要求が来ると、門はまだ「待機」を指している（`.recording` が
    /// まだ配送されていない）。そこで監視を止めると、**キー解放が二度と届かず発話が消える。**
    /// 負荷を掛けた `swift test` で `shutdownWaitsForKeyRelease` が実際に落ちて判った窓。
    ///
    /// **これが「終了は `state` ではなく `isBusy` を見る」の本体である。**
    /// 門は `stateUpdates`（＝ `state`）だけを見ており、ここではそれが「待機」を指している。
    @Test("門（＝state）が待機を指していても、isBusy が処理中なら止めない")
    func waitsWhenGateLagsBehindTheStateMachine() async {
        let gate = ShutdownGate()  // 何も観測していない＝待機を指す
        let log = AnnouncementLog()
        // `Atomic` は ~Copyable でクロージャ内の `#expect` に載せられない。参照型を使う。
        let busy = MutableFlag(true)
        let stopped = MutableFlag(false)

        // 少し遅れて発話が終わる（＝状態機械が待機へ戻る）
        let release = Task {
            try? await Task.sleep(for: .milliseconds(200))
            busy.value = false
        }
        defer { release.cancel() }

        await Shutdown.perform(
            gate: gate, grace: .seconds(5),
            stopHotkey: {
                // **止める瞬間に、状態機械はもう待機でなければならない。**
                #expect(!busy.value, "処理中に監視を止めた（発話が失われる）")
                stopped.value = true
            },
            awaitRun: {},
            isBusy: { busy.value },
            announce: { log.record($0) })

        #expect(stopped.value)
        #expect(!log.text.contains("打ち切ります"), "待てるのに打ち切っている")
    }

    // MARK: - 門を持たない経路（`.app`）

    /// `.app` は `stateUpdates` を消費しないので門を持たない。
    ///
    /// **理由は「その 1 本を HUD が使うから」ではない**（分配器ができた時点でその説明は
    /// 偽になった。HUD が読むのは `stateStream()` であり、`.app` では `stateUpdates` の
    /// 読み手が 1 人も居ない）。**終了の判定に状態の列を使わない**という判断そのものが
    /// 理由である——分配器は読み手が遅れると古いものから捨てるので `.idle` を
    /// 取りこぼしうる（`SessionBroadcast` の注記）。
    /// **門が無くても待つ根拠は同じ `isBusy` である。**
    @Test("門が無くても、待機中ならすぐ畳んでよい")
    func alreadyIdleWithoutGate() async {
        let stub = BusyStub(busyTimes: 0)
        let outcome = await Shutdown.waitUntilIdle(
            grace: .seconds(5), poll: .milliseconds(10), isBusy: { await stub.isBusy() })
        #expect(outcome == .idle)
        #expect(await stub.calls == 1)
    }

    /// **発話を抱えている間は待つ。** ここで待たずにホットキーを止めると、
    /// 押しっぱなしのキーの解放が二度と届かず、その発話がまるごと失われる。
    @Test("門が無くても、処理中のあいだは待ち、待機へ戻ったら idle を返す")
    func waitsUntilIdleWithoutGate() async {
        let stub = BusyStub(busyTimes: 3)
        let outcome = await Shutdown.waitUntilIdle(
            grace: .seconds(5), poll: .milliseconds(10), isBusy: { await stub.isBusy() })
        #expect(outcome == .idle)
        #expect(await stub.calls == 4)
    }

    /// 永久には待たない。**押しっぱなしのまま終了要求が来ても、いつかは終われる**
    /// （終われないプロセスにしない）。諦めたことは呼び出し側が表に出す。
    @Test("門が無くても、猶予が尽きたら timedOut を返す")
    func timesOutWithoutGate() async {
        let stub = BusyStub(busyTimes: nil)
        let started = ContinuousClock.now
        let outcome = await Shutdown.waitUntilIdle(
            grace: .milliseconds(200), poll: .milliseconds(20), isBusy: { await stub.isBusy() })
        let elapsed = ContinuousClock.now - started
        #expect(outcome == .timedOut)
        #expect(elapsed >= .milliseconds(200))
        // **これは要件値ではない。** 待ち続けて固まっていないことを見るだけの上限である。
        #expect(elapsed < .seconds(3))
    }

    /// 門を持たない経路でも、**止める前に発話を待つ**こと自体は変わらない。
    @Test("門が無い経路でも、isBusy が処理中のあいだは止めない")
    func doesNotStopWhileBusyWithoutGate() async {
        let log = AnnouncementLog()
        let busy = MutableFlag(true)
        let stopped = MutableFlag(false)

        let release = Task {
            try? await Task.sleep(for: .milliseconds(150))
            busy.value = false
        }
        defer { release.cancel() }

        await Shutdown.perform(
            grace: .seconds(5), poll: .milliseconds(10),
            stopHotkey: {
                #expect(!busy.value, "処理中に監視を止めた（発話が失われる）")
                stopped.value = true
            },
            awaitRun: {},
            isBusy: { busy.value },
            announce: { log.record($0) })

        #expect(stopped.value)
        #expect(!log.text.contains("打ち切ります"))
    }

    // MARK: - exit() へ落ちないための性質

    /// **`perform` は `awaitRun` が終わるまで戻らない。**
    ///
    /// 呼び出し側が `exit()` してよいのは `perform` が戻った後だけである。
    /// ここが先に戻ると、⌘V を送出した直後・クリップボードを復元する前に
    /// プロセスが消えて、テキストがどこにも残らない。
    @Test("perform は run() の見届けが終わるまで戻らない（戻る前に落とせない）")
    func performDoesNotReturnBeforeRunCompletes() async {
        let log = AnnouncementLog()
        let runFinished = MutableFlag(false)

        await Shutdown.perform(
            grace: .seconds(5),
            stopHotkey: {},
            awaitRun: {
                try? await Task.sleep(for: .milliseconds(150))
                runFinished.value = true
            },
            isBusy: { false },
            announce: { log.record($0) })

        #expect(runFinished.value, "run() の完了前に戻った（この後の exit() が挿入を切る）")
        #expect(log.announcements.last == .finished)
    }

    /// 猶予が尽きても**黙って捨てない。** 発話が失われたことを言う。
    @Test("待機へ戻らないまま終わったら、打ち切ったことと失われたことを言う")
    func announcesLostUtterance() async {
        let log = AnnouncementLog()
        await Shutdown.perform(
            grace: .milliseconds(100), poll: .milliseconds(10),
            stopHotkey: {}, awaitRun: {}, isBusy: { true },
            announce: { log.record($0) })

        #expect(log.announcements.contains(.gaveUp(grace: .milliseconds(100))))
        #expect(log.announcements.contains(.utteranceLost))
        #expect(log.announcements.last == .finished)
    }

    // MARK: - 文言

    /// **待たれている相手が人であることを言う文言は 1 つしか無い。**
    /// 実機の初回で、PTT キーを押したまま喋り続けて猶予が尽き、発話が失われた。
    /// 足りなかったのは動作ではなく**利用者が取るべき行動**だった。
    @Test("待ちの文言は、利用者が何をすべきかを言う")
    func waitingTextTellsTheUserWhatToDo() {
        let text = ShutdownAnnouncement.waiting(grace: .seconds(10)).text
        #expect(text.contains("録音中なら PTT キーを離してください"))
        #expect(text.contains("失われます"))
        // 猶予そのものを言う（何秒待たれているのか判らないと、離す判断ができない）。
        #expect(text.contains("\(Duration.seconds(10))"))
        // **前後の余白は出力先が決める。** ここが改行で始まったり終わったりしていると、
        // 端末と `.app` のどちらかで体裁が壊れる。
        #expect(!text.hasPrefix("\n"))
        #expect(!text.hasSuffix("\n"))
    }

    @Test("猶予が尽きたこと・発話が失われたことを、それぞれ別の文言で言う")
    func outcomeTexts() {
        #expect(ShutdownAnnouncement.gaveUp(grace: .seconds(3)).text.contains("打ち切ります"))
        #expect(ShutdownAnnouncement.utteranceLost.text.contains("挿入されませんでした"))
        #expect(ShutdownAnnouncement.finished.text.contains("終了しました"))
    }

    // MARK: - ソースそのものへの検査

    /// **`stopHotkey()` の後に無防備な `exit()` へ落ちないこと。**
    ///
    /// フェーズ 1 が潰した欠陥そのものである——`Shutdown.perform` の 1 手目
    /// （`stopHotkey`）は `CGEventTapHotkeyMonitor.stop()` を呼び、**自分でメインの
    /// ランループからソースを外す。** そこで `CFRunLoopRun()` が戻り、その後ろに
    /// `exit()` があると、**挿入の途中でプロセスが消える。**
    ///
    /// **これは振る舞いでは検査できない。** `exit()` はテストプロセスごと消すので、
    /// 落ちたことを報告する主体が残らない。だからソースの形として固定する
    /// （`BundleContractTests` が `Info.plist` に対してやっているのと同じ形）。
    @Test("CLI: ランループから戻った後に exit() が無い")
    func cliHasNoExitAfterRunLoop() throws {
        let code = try Self.sourceWithoutComments("Sources/GhostVoiceCLI/GhostVoiceRuntime.swift")
        let runLoop = try #require(code.range(of: "CFRunLoopRun()"), "ランループの呼び出しが見当たらない")
        let exits = Self.occurrences(of: "exit(", in: code)
        #expect(!exits.isEmpty, "この検査が対象を掴めていない")
        #expect(
            exits.allSatisfy { $0 < runLoop.lowerBound },
            "CFRunLoopRun() が戻った後に exit() がある（挿入の途中でプロセスが消える）")
        #expect(
            code[runLoop.upperBound...].contains("dispatchMain()"),
            "ランループが戻った後、主スレッドを寝かせていない")
    }

    /// **`exit()` の入口は終了の段取りの後ろに 1 つだけ。**
    @Test("CLI: 常駐経路の exit() は Shutdown.perform を待った後にある")
    func cliExitsOnlyAfterShutdown() throws {
        let code = try Self.sourceWithoutComments("Sources/GhostVoiceCLI/GhostVoiceRuntime.swift")
        let perform = try #require(code.range(of: "await Shutdown.perform("))
        let session = try #require(code.range(of: "private static func runSession("))
        // 常駐経路（`runSession`）の中の `exit(` は、引数解析の失敗（exit(1)）と
        // 終了処理（exit(0)）だけである。**最後の 1 つは段取りの後ろになければならない。**
        let inSession = Self.occurrences(of: "exit(", in: code).filter { $0 > session.lowerBound }
        let last = try #require(inSession.last)
        #expect(last > perform.lowerBound, "終了処理を待たずに exit() している")
    }

    /// **`state` を見て終了を判断しないこと。** `state` は emit でしか変わらないので、
    /// 押下を受けてから最初の emit までの窓を「待機」と読み違える。
    @Test("CLI: 終了の判断に session.state を使っていない")
    func cliJudgesOnIsBusy() throws {
        let code = try Self.sourceWithoutComments("Sources/GhostVoiceCLI/GhostVoiceRuntime.swift")
        #expect(code.contains("isBusy: { await session.isBusy }"))
        #expect(!code.contains("await session.state"), "終了の判断に state を使っている")
    }

    // MARK: - ソースを読む道具

    /// リポジトリの根。**テストの置き場所から辿る**（作業ディレクトリに依存しない）。
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // GhostVoiceCoreTests
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

    static func occurrences(of needle: String, in haystack: String) -> [String.Index] {
        var found: [String.Index] = []
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            found.append(range.lowerBound)
            searchStart = range.upperBound
        }
        return found
    }
}

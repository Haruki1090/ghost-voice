import Testing

@testable import GhostVoiceApp

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

@Suite("終了の待ち合わせ")
struct AppTerminationTests {

    @Test("待機中ならすぐ畳んでよい")
    func alreadyIdle() async {
        let stub = BusyStub(busyTimes: 0)
        let outcome = await AppTermination.waitUntilIdle(
            grace: .seconds(5), poll: .milliseconds(10), isBusy: { await stub.isBusy() })
        #expect(outcome == .idle)
        #expect(await stub.calls == 1)
    }

    /// **発話を抱えている間は待つ。** ここで待たずにホットキーを止めると、
    /// 押しっぱなしのキーの解放が二度と届かず、その発話がまるごと失われる。
    @Test("処理中のあいだは待ち、待機へ戻ったら idle を返す")
    func waitsUntilIdle() async {
        let stub = BusyStub(busyTimes: 3)
        let outcome = await AppTermination.waitUntilIdle(
            grace: .seconds(5), poll: .milliseconds(10), isBusy: { await stub.isBusy() })
        #expect(outcome == .idle)
        #expect(await stub.calls == 4)
    }

    /// 永久には待たない。**押しっぱなしのまま終了要求が来ても、いつかは終われる**
    /// （終われないプロセスにしない）。諦めたことは呼び出し側が表に出す。
    @Test("猶予が尽きたら timedOut を返す")
    func timesOut() async {
        let stub = BusyStub(busyTimes: nil)
        let started = ContinuousClock.now
        let outcome = await AppTermination.waitUntilIdle(
            grace: .milliseconds(200), poll: .milliseconds(20), isBusy: { await stub.isBusy() })
        let elapsed = ContinuousClock.now - started
        #expect(outcome == .timedOut)
        #expect(elapsed >= .milliseconds(200))
        // **これは要件値ではない。** 待ち続けて固まっていないことを見るだけの上限である。
        #expect(elapsed < .seconds(3))
    }
}

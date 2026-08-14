import Foundation
import Synchronization

/// **1 本しかない供給を、何人でも読める形に配り直す。**
///
/// ## なぜ要るか
///
/// `AsyncStream` は**単一消費者**である。**複数の `next()` を同時に待つと異常終了する**
/// （調査 `core-api-and-hud.md` の A-4）。ところがフェーズ 2 では
/// `DictationSession.stateUpdates` を **HUD・終了待ち・履歴一覧の再読込**が同時に要求し、
/// マイク音量（`AudioCapturing.level`）も HUD と設定画面の 2 口が要る。
/// **同じ分配器を UI 側で 3 つ作るのを避けるため、Core に 1 つ置く。**
///
/// ## 使い方
///
/// - `stream()` は**呼ぶたびに独立したストリームを返す。** 各購読者が自分のものを 1 本持てば、
///   単一消費者の制約は踏まない。**1 本を 2 箇所で読み回さないこと。**
/// - `for await` を抜けるか、購読側のタスクがキャンセルされると購読は自動的に解ける。
/// - `finish()` の後に `stream()` を呼ぶと、**即座に終端したストリーム**が返る
///   （終端後に購読した相手が永久に待つことを防ぐ）。
///
/// ## 並行性
///
/// - **`Sendable`。どのスレッド・どの actor からでも `yield` してよい。**
/// - **配布はロックの外で行う。** `AsyncStream.Continuation.yield` は購読側のバッファへ
///   積むだけだが、そこにロックを掛けたままにすると、購読者がハンドラの中から
///   `yield` を呼ぶ形（HUD → 状態 → HUD）で自己デッドロックしうる。
/// - **`@MainActor` から `stream()` を呼んでよい**（ロックを取るだけで I/O は無い）。
///
/// - Important: **取りこぼしの防止装置ではない。** 既定のバッファ方針は
///   `.bufferingNewest(n)` なので、読み手が遅れれば**古いものから捨てる。**
///   捨てられて困る通知（終了の合図など）をこれに載せてはならない。
public final class SessionBroadcast<Element: Sendable>: Sendable {

    private struct State {
        var subscribers: [UUID: AsyncStream<Element>.Continuation] = [:]
        var isFinished = false
    }

    private let state = Mutex(State())

    public init() {}

    /// 購読者の数。**検査と診断のためだけにある。**
    public var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    /// 終端済みか。
    public var isFinished: Bool { state.withLock { $0.isFinished } }

    /// **独立したストリームを 1 本作る。** 呼ぶたびに別のものが返る。
    ///
    /// - Parameter bufferingPolicy: 既定は「最新 32 件だけ残す」。
    ///   1 発話が出す状態は 6 件ではない（暫定テキストのたびに出るので数百件になりうる）
    ///   ので、上限はメモリのために置く。**溢れて失われるのは古い暫定表示だけである。**
    public func stream(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .bufferingNewest(32)
    ) -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()
            let finished = state.withLock { state -> Bool in
                guard !state.isFinished else { return true }
                state.subscribers[id] = continuation
                return false
            }
            guard !finished else {
                // **終端後の購読者を待たせない。** 待たせると、終了処理を
                // 「状態が `.idle` になるまで待つ」形で書いた側が永久に止まる。
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
            }
        }
    }

    /// 全購読者へ配る。**購読者が居なくても捨てるだけで、何も起きない。**
    public func yield(_ element: Element) {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for subscriber in subscribers { subscriber.yield(element) }
    }

    /// **全購読者のストリームを終端する。** 以後の `yield` は何もしない。
    public func finish() {
        let subscribers = state.withLock { state -> [AsyncStream<Element>.Continuation] in
            state.isFinished = true
            let all = Array(state.subscribers.values)
            state.subscribers.removeAll()
            return all
        }
        for subscriber in subscribers { subscriber.finish() }
    }
}

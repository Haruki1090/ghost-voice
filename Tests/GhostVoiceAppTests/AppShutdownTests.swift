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
        #expect(ShutdownAnnouncement.utteranceLost.text.contains("挿入されませんでした"))
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

        let shutdown = try #require(body.range(of: "await runtime.shutdown()"), "段取りを通っていない")
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

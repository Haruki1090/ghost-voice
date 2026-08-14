import Foundation
import Testing

@testable import GhostVoiceCLI
@testable import GhostVoiceCore

@Suite("CLI: 状態の表示")
struct CLINarrationTests {

    /// `\u{1B}[K`（行末までを消す）が入るのは、切り詰めで短くなったときに
    /// 前の文字が残らないようにするためである（下の「端末の幅に収める」の一群）。
    @Test("録音中は暫定テキストを行頭から上書きする")
    func recordingShowsVolatileText() {
        let line = SessionNarration.line(for: .recording(volatileText: "こんにち"), metrics: nil)
        #expect(line == "\r\u{1B}[K[録音中] こんにち")
    }

    @Test("確定・整形・挿入はそれぞれ別の行を出す")
    func processingStatesHaveDistinctLines() {
        let finalizing = SessionNarration.line(for: .finalizing, metrics: nil)
        let refining = SessionNarration.line(for: .refining, metrics: nil)
        let inserting = SessionNarration.line(for: .inserting, metrics: nil)
        #expect(finalizing == "\n[確定中]\n")
        #expect(refining == "[整形中]\n")
        #expect(inserting == "[挿入中]\n")
        // 録音中の行は改行で終わっていないので、次の行が改行から始まらないと連結される。
        #expect(finalizing?.hasPrefix("\n") == true)
    }

    @Test("計測値のある待機は内訳と合計を出す")
    func idleWithMetricsPrintsBreakdown() throws {
        let sample = Metrics.Sample(
            finalize: .milliseconds(70), refine: .milliseconds(400), insert: .milliseconds(5))
        let line = try #require(SessionNarration.line(for: .idle, metrics: sample))
        #expect(line == "[metrics] finalize 70ms / refine 400ms / insert 5ms / total 475ms OK\n")
    }

    /// **NFR-P6a を超えた発話が「OK」に紛れてはならない。**
    @Test("合計が 1000 ms を超えたら目標超過と出す")
    func idleMarksBudgetOverrun() throws {
        let sample = Metrics.Sample(
            finalize: .milliseconds(177), refine: .milliseconds(750), insert: .milliseconds(120))
        let line = try #require(SessionNarration.line(for: .idle, metrics: sample))
        #expect(line.contains("**目標超過**"))
        #expect(!line.contains("OK"))
        #expect(line.contains("total 1047ms"))
    }

    /// 1000 ms ちょうどは超過ではない（`meetsTarget` は `<=`）。
    @Test("合計が 1000 ms ちょうどなら目標内")
    func idleAtExactBudgetIsOK() throws {
        let sample = Metrics.Sample(
            finalize: .milliseconds(500), refine: .milliseconds(400), insert: .milliseconds(100))
        let line = try #require(SessionNarration.line(for: .idle, metrics: sample))
        #expect(line.contains("total 1000ms OK"))
    }

    /// 音が欠けたことを黙って飲み込むと、認識結果が短い理由が判らなくなる。
    @Test("取りこぼしたバッファがあれば警告を添える")
    func idleWarnsAboutDroppedBuffers() throws {
        let dropped = Metrics.Sample(
            finalize: .milliseconds(70), refine: .zero, insert: .milliseconds(5),
            droppedBuffers: 3)
        let clean = Metrics.Sample(
            finalize: .milliseconds(70), refine: .zero, insert: .milliseconds(5),
            droppedBuffers: 0)
        let droppedLine = try #require(SessionNarration.line(for: .idle, metrics: dropped))
        let cleanLine = try #require(SessionNarration.line(for: .idle, metrics: clean))
        #expect(droppedLine.contains("取りこぼし 3 バッファ"))
        #expect(droppedLine.contains("**音が欠けている**"))
        #expect(!cleanLine.contains("取りこぼし"))
    }

    /// 中断や失敗で終わった発話には計測値が無い。前の発話の値を出さないための入口。
    @Test("計測値の無い待機は何も出さない")
    func idleWithoutMetricsPrintsNothing() {
        #expect(SessionNarration.line(for: .idle, metrics: nil) == nil)
    }

    @Test("失敗はそれぞれ別の案内を出す")
    func failuresHaveDistinctGuidance() {
        let messages = [
            SessionNarration.message(for: .audioUnavailable),
            SessionNarration.message(for: .transcriptionUnavailable),
            SessionNarration.message(for: .noSpeechRecognized),
            SessionNarration.message(for: .refusedSecureInput),
            SessionNarration.message(for: .historyUnavailable(insertedElsewhere: true)),
            SessionNarration.message(for: .historyUnavailable(insertedElsewhere: false)),
        ]
        #expect(Set(messages).count == 6)
    }

    /// **中断された発話にとって、履歴は唯一の写しである。**
    /// 挿入済みかどうかで利用者にとっての意味がまったく違うので、同じ文言にしてはならない。
    @Test("履歴に書けなかったとき、発話が失われたかどうかを言い分ける")
    func historyFailureDistinguishesLoss() {
        let lost = SessionNarration.message(for: .historyUnavailable(insertedElsewhere: false))
        let kept = SessionNarration.message(for: .historyUnavailable(insertedElsewhere: true))

        #expect(lost.contains("失われました"))
        #expect(lost.contains("もう一度"))
        #expect(kept.contains("挿入は完了しています"))
        #expect(!kept.contains("失われました"), "挿入済みなのに発話が消えたと読める")
        // どちらも「どこを直せばよいか」を言う
        #expect(lost.contains("書き込み権限") && kept.contains("書き込み権限"))
    }

    /// FR-10。**権限が無いことは、押しても何も起きない現象ではなく文章で伝える。**
    @Test("マイクの失敗はマイクのペインへ案内する")
    func audioFailureGuidesToMicrophonePane() throws {
        let line = try #require(SessionNarration.line(for: .failed(.audioUnavailable), metrics: nil))
        #expect(line.hasPrefix("[エラー] "))
        #expect(line.contains("マイク"))
        #expect(line.contains("システム設定"))
        #expect(line.contains("--request-permissions"))
    }

    @Test("認識の失敗はモデルの導入へ案内する")
    func transcriptionFailureGuidesToLanguageSettings() {
        let message = SessionNarration.message(for: .transcriptionUnavailable)
        #expect(message.contains("言語"))
        #expect(message.contains("localeIdentifier"))
        // マイクの案内と取り違えていないこと
        #expect(!message.contains("プライバシーとセキュリティ > マイク"))
    }

    /// secure input の拒否は**意図した動作**であり、再試行を勧めてはならない。
    @Test("secure input の拒否は何もしなかったことを明示する")
    func secureInputMessageStatesNothingWasDone() {
        let message = SessionNarration.message(for: .refusedSecureInput)
        #expect(message.contains("secure input"))
        #expect(message.contains("挿入"))
        #expect(message.contains("履歴"))
        #expect(message.contains("クリップボード"))
        #expect(!message.contains("もう一度"))
    }

    // MARK: - 端末の幅に収める（実機で観測 / 2026-08-14）

    /// **`\r` が戻せるのは折り返した最後の 1 行の先頭だけである。**
    /// 収めずに出すと、長い発話で更新のたびに折り返しのブロックが積み上がり、
    /// 実機では「最初から出てしまう」形で観測された。
    @Test("録音中の行は端末の幅に収める")
    func recordingLineFitsWithinColumns() throws {
        let long = String(repeating: "あ", count: 200)
        let line = try #require(
            SessionNarration.line(for: .recording(volatileText: long), metrics: nil, columns: 40))
        let body = line.replacingOccurrences(of: "\r\u{1B}[K", with: "")
        #expect(SessionNarration.displayWidth(of: body) <= 40, "折り返す幅で出している")
        #expect(body.hasPrefix("[録音中] …"), "切り詰めた印が無い")
    }

    /// **末尾を残す。** 喋っている最中に見たいのは「いま認識された分」である。
    @Test("切り詰めるときは末尾を残す")
    func recordingLineKeepsTheTail() throws {
        let text = "あいうえおかきくけこさしすせそ"
        let line = try #require(
            SessionNarration.line(for: .recording(volatileText: text), metrics: nil, columns: 20))
        #expect(line.hasSuffix("そ"), "末尾が落ちている")
        #expect(!line.contains("あいうえお"), "先頭を残している")
    }

    /// 全角を 1 桁と数えると、日本語では倍の桁を使うので折り返しを防げない。
    @Test("表示幅は全角を 2 桁として数える")
    func displayWidthCountsWideCharactersAsTwo() {
        #expect(SessionNarration.displayWidth(of: "あ") == 2)
        #expect(SessionNarration.displayWidth(of: "a") == 1)
        #expect(SessionNarration.displayWidth(of: "あa") == 3)
    }

    /// 収まる長さなら切り詰めない（`…` を付けない）。
    @Test("収まる長さはそのまま出す")
    func shortRecordingLineIsNotTruncated() throws {
        let line = try #require(
            SessionNarration.line(for: .recording(volatileText: "こんにち"), metrics: nil, columns: 80))
        #expect(line == "\r\u{1B}[K[録音中] こんにち")
    }

    /// 短くなったときに前の文字が残らないよう、行末までを消す。
    @Test("録音中の行は行末までを消してから書く")
    func recordingLineClearsToEndOfLine() throws {
        let line = try #require(
            SessionNarration.line(for: .recording(volatileText: "あ"), metrics: nil, columns: 80))
        #expect(line.hasPrefix("\r\u{1B}[K"), "消去の制御が無いと前の文字が残る")
    }

}

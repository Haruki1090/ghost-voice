import Foundation
import GhostVoiceCore

/// 状態と計測値を、標準エラーへ出す 1 行へ変換する。
///
/// **純粋関数として切り出してある。** CLI の本体（`main.swift` のトップレベルコード）は
/// 検査できないので、出す内容の判断をここへ全部寄せて検査対象にする。
///
/// フェーズ 1 に HUD は無い（FR-2 / FR-3 はフェーズ 2）。ここが唯一の表示である。
public enum SessionNarration {

    /// 状態の列を読み切る。**`stateUpdates` を読んでよいのはここだけである。**
    ///
    /// Task 10 申し送り【4】: `stateUpdates` は `AsyncStream` なので、
    /// **複数の `next()` を同時に待つと異常終了する。** 「表示」と「終了の待ち合わせ」で
    /// 2 箇所から読むのが最も踏みやすい形なので、1 本のループで両方へ配る。
    ///
    /// - Parameter metrics: 計測値の取得。**待機になったときにしか呼ばない**
    ///   （暫定結果のたびに状態機械の actor を叩かないため）。
    public static func consume(
        _ states: AsyncStream<SessionState>,
        metrics: @Sendable () async -> Metrics.Sample?,
        writer: any ConsoleWriting,
        gate: ShutdownGate,
        columns: Int = SessionNarration.terminalColumns()
    ) async {
        for await state in states {
            let sample = (state == .idle) ? await metrics() : nil
            if let text = line(for: state, metrics: sample, columns: columns) {
                writer.write(text)
            }
            await gate.observe(state)
        }
        // 列が終わった＝セッションは処理中の発話を見届けた。終了処理を待たせない。
        await gate.streamFinished()
    }

    /// - Parameter metrics: `.idle` のときだけ意味がある。**それ以外では nil を渡すこと。**
    ///   `DictationSession.latestMetrics` は次の発話が始まるまで前の値を保持するので、
    ///   録音中に読むと前の発話の値を今の発話のものとして出してしまう。
    /// - Returns: 書き出す文字列。**何も出さないときは nil。**
    /// `[録音中] ` の表示幅（半角 9 桁ぶん）。
    static let recordingPrefixWidth = 9

    /// 端末の桁数。取れなければ 80 とみなす。
    ///
    /// **標準エラーを見る**（表示先がそこなので）。パイプへ繋がれている場合は
    /// `ioctl` が失敗するが、そのときも折り返しは起きないので 80 で困らない。
    public static func terminalColumns(fileDescriptor: Int32 = STDERR_FILENO) -> Int {
        var size = winsize()
        guard ioctl(fileDescriptor, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else {
            return 80
        }
        return Int(size.ws_col)
    }

    /// 表示幅。**全角は 2 桁**として数える。
    ///
    /// 文字数で切ると日本語では倍の桁を使うので、折り返しを防げない
    /// （このプロジェクトの表示はほぼ日本語である）。
    static func displayWidth(of text: some StringProtocol) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
            0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x20000...0x3FFFD:
            true
        default:
            false
        }
    }

    /// 末尾から `limit` 桁ぶんを取る。切り詰めたときは先頭に `…` を付ける。
    ///
    /// **末尾を残すのは、喋っている最中に見たいのが「いま認識された分」だから**である。
    static func tail(of text: String, within limit: Int) -> String {
        guard displayWidth(of: text) > limit else { return text }
        var kept: [Character] = []
        var width = 0
        for character in text.reversed() {
            let next = width + displayWidth(of: String(character))
            if next > limit - 1 { break }  // 先頭の `…` のぶん 1 桁空ける
            kept.append(character)
            width = next
        }
        return "…" + String(kept.reversed())
    }

    public static func line(
        for state: SessionState, metrics: Metrics.Sample?, columns: Int = 80
    ) -> String? {
        switch state {
        case .idle:
            // 中断・失敗で終わった発話には計測値が無い。**その場合は何も出さない。**
            guard let metrics else { return nil }
            return metricsLine(metrics)
        case .recording(let text):
            // 行頭へ戻して上書きする。確定へ進むときに改行を入れる（下の `.finalizing`）。
            //
            // **端末の幅に収める。** `\r` が戻せるのは**折り返した最後の 1 行の先頭だけ**で、
            // それより上の行は残る。収めずに出すと、長い発話で更新のたびに折り返しの
            // ブロックが積み上がり、**「最初から出てしまう」**（実機で観測 / 2026-08-14）。
            // `\u{1B}[K` は行末までを消す。短くなったときに前の文字が残らないようにする。
            let room = max(8, columns - Self.recordingPrefixWidth)
            return "\r\u{1B}[K[録音中] \(Self.tail(of: text, within: room))"
        case .finalizing:
            return "\n[確定中]\n"
        case .refining:
            return "[整形中]\n"
        case .inserting:
            return "[挿入中]\n"
        case .failed(let failure):
            return "[エラー] \(message(for: failure))\n"
        }
    }

    /// 1 発話ぶんの計測（詳細設計書 §10 の M2 / M3 / M4 / M5）。
    public static func metricsLine(_ metrics: Metrics.Sample) -> String {
        var line =
            "[metrics] finalize \(metrics.finalizeMs)ms / refine \(metrics.refineMs)ms"
            + " / insert \(metrics.insertMs)ms / total \(metrics.totalMs)ms "
            + (metrics.meetsTarget ? "OK" : "**目標超過**")
        // **捨てたバッファを黙って飲み込まない。** 0 でない発話は音の一部が欠けており、
        // 認識結果が短いのが「言い間違い」なのか「録れていない」のかの区別がつかなくなる。
        if metrics.droppedBuffers > 0 {
            line += " / 取りこぼし \(metrics.droppedBuffers) バッファ **音が欠けている**"
        }
        return line + "\n"
    }

    /// 縮退の理由を、**次に何をすればよいかまで含めて**日本語にする（FR-10）。
    ///
    /// **判断は Core が持つ**（`SessionFailureNotice`）。ここがやるのは端末向けの
    /// 組み立てだけである。以前は文言そのものがここにあり、`ghost-voice
    /// --request-permissions` のような**端末固有の案内が本文へ埋まっていた**ので、
    /// HUD は同じ文言を別に持つしかなかった（フェーズ 2 の欠落 12）。
    ///
    /// `SessionFailure` は型であって文言ではない（`DictationSession` の注記）。
    /// 起動時のウォームアップの失敗もこの経路で表に出る（Task 10 申し送り【3】）。
    public static func message(for failure: SessionFailure) -> String {
        let notice = SessionFailureNotice(failure)
        // **発話が失われた回だけ強調する。** 毎回強調すると、本当に失った回が埋もれる。
        // 端末では `**` で書く（HUD は同じ判断を太字や色で表す）。この分岐ができるのは、
        // 「失われたか」を文言ではなく `speechWasLost` で持っているからである。
        let headline = notice.speechWasLost ? "**\(notice.summary)**" : notice.summary
        var body = [notice.detail].filter { !$0.isEmpty }
        body.append(contentsOf: notice.remedies.map(guidance(for:)))
        guard !body.isEmpty else { return headline }
        return headline + "\n" + body.joined()
    }

    /// 次にできることを**端末の利用者向けに**言い直す。
    ///
    /// ここが媒体固有の部分である。素の実行ファイルの権限は起動元のターミナルアプリに
    /// 紐づき（`PermissionGuidance` の注記）、設定は `settings.json` の手編集で行う——
    /// **どちらも `.app` では別の言い方になる。**
    static func guidance(for remedy: SessionRemedy) -> String {
        switch remedy {
        case .grantAccess(let pane):
            return "\(pane.localizedPath) で、ghost-voice を起動しているターミナルアプリを許可してください。"
        case .requestAuthorizationFromApp:
            return "一覧に無い場合は `ghost-voice --request-permissions` を実行すると許可を求めます。"
        case .installLanguageModel(let pane):
            return "認識言語は `settings.json` の `localeIdentifier` で決まります。"
                + "\(pane.localizedPath) に当該言語を追加すると導入されます。"
        case .checkStorage(let path):
            return "ディスクの空き容量と `\(path)` の書き込み権限を確認してください"
                + "（`history.json` が壊れている場合、退避に失敗する限り以後も書けません）。"
        }
    }
}

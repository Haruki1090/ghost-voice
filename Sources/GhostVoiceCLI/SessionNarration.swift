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
        gate: ShutdownGate
    ) async {
        for await state in states {
            let sample = (state == .idle) ? await metrics() : nil
            if let text = line(for: state, metrics: sample) { writer.write(text) }
            await gate.observe(state)
        }
        // 列が終わった＝セッションは処理中の発話を見届けた。終了処理を待たせない。
        await gate.streamFinished()
    }

    /// - Parameter metrics: `.idle` のときだけ意味がある。**それ以外では nil を渡すこと。**
    ///   `DictationSession.latestMetrics` は次の発話が始まるまで前の値を保持するので、
    ///   録音中に読むと前の発話の値を今の発話のものとして出してしまう。
    /// - Returns: 書き出す文字列。**何も出さないときは nil。**
    public static func line(for state: SessionState, metrics: Metrics.Sample?) -> String? {
        switch state {
        case .idle:
            // 中断・失敗で終わった発話には計測値が無い。**その場合は何も出さない。**
            guard let metrics else { return nil }
            return metricsLine(metrics)
        case .recording(let text):
            // 行頭へ戻して上書きする。確定へ進むときに改行を入れる（下の `.finalizing`）。
            return "\r[録音中] \(text)"
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
    /// `SessionFailure` は型であって文言ではない（`DictationSession` の注記）。
    /// 起動時のウォームアップの失敗もこの経路で表に出る（Task 10 申し送り【3】）。
    public static func message(for failure: SessionFailure) -> String {
        switch failure {
        case .audioUnavailable:
            return """
                マイクを開けませんでした。
                システム設定 > プライバシーとセキュリティ > マイク で、ghost-voice を起動している\
                ターミナルアプリを許可してください。一覧に無い場合は \
                `ghost-voice --request-permissions` を実行すると許可を求めます。
                """
        case .transcriptionUnavailable:
            return """
                音声認識を開始できませんでした。
                設定の localeIdentifier（既定 ja-JP）のモデルが利用できるかを確認してください。\
                システム設定 > 一般 > 言語と地域 に当該言語を追加すると導入されます。
                """
        case .noSpeechRecognized:
            return "認識できませんでした。"
        case .historyUnavailable(let insertedElsewhere):
            // **挿入まで行ったかで、利用者にとっての意味がまったく違う。**
            // 同じ文言にすると、発話が消えた場合に「履歴が欠けただけ」と読まれる。
            if insertedElsewhere {
                return """
                    履歴に保存できませんでした（テキストの挿入は完了しています）。
                    失われるのは履歴と Undo だけです。ディスクの空き容量と \
                    `~/Library/Application Support/GhostVoice/` の書き込み権限を確認してください。
                    """
            }
            return """
                履歴に保存できませんでした。**中断したこの発話は失われました。**
                挿入もしていないため、どこにも残っていません。もう一度話してください。
                ディスクの空き容量と `~/Library/Application Support/GhostVoice/` の\
                書き込み権限を確認してください（`history.json` が壊れている場合、\
                退避に失敗する限り以後も書けません）。
                """
        case .refusedSecureInput:
            // **「失敗」ではなく意図した拒否である。** ここで「もう一度試してください」と
            // 書くと、パスワード欄へ挿入させようとする案内になる。
            return """
                パスワード入力欄（secure input）が有効だったため、整形・挿入・履歴・\
                クリップボードのいずれも行いませんでした。
                """
        }
    }
}

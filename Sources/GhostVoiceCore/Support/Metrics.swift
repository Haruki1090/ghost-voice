import Foundation

/// 詳細設計書 §10 の計測点。
public enum Metrics {

    /// NFR-P6。発話終了 → 挿入完了の合計。
    public static let totalBudget: Duration = .milliseconds(1_000)

    /// 1 発話ぶんの計測値。
    ///
    /// **`Duration` で保持し、ミリ秒は表示用の派生値として出す。** 挿入は実測で
    /// 1 ms を切ることがあり（AX 経路の往復 0.1〜5.5 ms）、整数ミリ秒で持つと
    /// 「0 ms」に潰れて内訳が読めなくなる。
    public struct Sample: Sendable, Equatable {

        /// M2: キー解放 → 確定（`.final` 受信）。実測 40〜177 ms（V-2）。
        public let finalize: Duration
        /// M3: 確定 → 整形完了。目標 500 ms（NFR-P4）／打ち切りは既定 750 ms。
        /// 整形しなかった場合はほぼ 0。
        public let refine: Duration
        /// M4: 整形完了 → 挿入完了。目標 50 ms（NFR-P5）。
        public let insert: Duration

        /// この発話の間に**変換に失敗して捨てられた**バッファの数。
        ///
        /// `AudioCapturing.droppedBufferCount` はインスタンス生涯の累計なので、
        /// ここには**録音の前後で取った差分**が入る（Task 7 申し送り）。
        /// 0 でない発話は音の一部が欠けている。
        public let droppedBuffers: Int

        /// M5: キー解放 → 挿入完了。
        public var total: Duration { finalize + refine + insert }

        public var finalizeMs: Int { Metrics.milliseconds(finalize) }
        public var refineMs: Int { Metrics.milliseconds(refine) }
        public var insertMs: Int { Metrics.milliseconds(insert) }

        /// **3 つのミリ秒の和ではなく、合計の実時間から丸める。**
        /// 各区間を切り捨ててから足すと、合計が最大 3 ms 過少に出る。
        public var totalMs: Int { Metrics.milliseconds(total) }

        /// NFR-P6（1 秒以内）を満たしたか。
        public var meetsTarget: Bool { total <= Metrics.totalBudget }

        public init(finalize: Duration, refine: Duration, insert: Duration, droppedBuffers: Int = 0) {
            self.finalize = finalize
            self.refine = refine
            self.insert = insert
            self.droppedBuffers = droppedBuffers
        }

        public init(finalizeMs: Int, refineMs: Int, insertMs: Int, droppedBuffers: Int = 0) {
            self.init(
                finalize: .milliseconds(finalizeMs), refine: .milliseconds(refineMs),
                insert: .milliseconds(insertMs), droppedBuffers: droppedBuffers
            )
        }
    }

    static func elapsed(since start: ContinuousClock.Instant) -> Duration {
        ContinuousClock.now - start
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }
}

import Foundation

/// 詳細設計書 §10 の計測点。
public enum Metrics {

    /// NFR-P6a。発話終了 → **テキストが挿入先に現れる**までの上限。
    ///
    /// - Important: **要件定義書 §2.8.6 の裁定で、この 1 秒が守る対象が変わった。**
    ///   守るのは「整形済みテキスト」ではなく「まず使えるテキスト」である。
    ///   **差し替えできる挿入先では、生テキストを先に挿入するので整形（M3）がこの予算に入らない。**
    ///   `Sample.total` はその区別を `waitedForRefinementBeforeInsert` で行う。
    public static let totalBudget: Duration = .milliseconds(1_000)

    /// NFR-P6b の**目標**。発話終了 → 整形結果が反映されるまで。
    ///
    /// - Important: **推定値である**（要件定義書 NFR-P6b）。3 秒の発話での M3 実測に
    ///   出力長への比例【推測】を当てた外挿であって、直接の実測ではない。
    ///   打ち切り（既定 3 秒）は `Settings.revisionDeadline` が持つ。
    ///   **超過の縮退は「生テキストのまま」であり、発話は失われない。**
    public static let revisionBudget: Duration = .milliseconds(2_000)

    /// 1 発話ぶんの計測値。
    ///
    /// **`Duration` で保持し、ミリ秒は表示用の派生値として出す。** 挿入は実測で
    /// 1 ms を切ることがあり（AX 経路の往復 0.1〜5.5 ms）、整数ミリ秒で持つと
    /// 「0 ms」に潰れて内訳が読めなくなる。
    public struct Sample: Sendable, Equatable {

        /// M2: キー解放 → **確定テキストが出そろう時点**（結果ストリームの終端）。
        /// 実測 中央値 75.9 ms（低負荷）／ 82.5 ms（負荷下）、最大 155.1 ms（詳細設計書 §10）。
        ///
        /// **「最初の `.final` の受信」ではない。** 解放後に届く確定は 1 件とは限らず、
        /// 最初の 1 件で先へ進むと発話の末尾が失われる（V-12。実機の肉声で再現）。
        public let finalize: Duration
        /// M3: 確定 → 整形完了。目標 500 ms（NFR-P4）。
        /// 打ち切りは**整形を待ってから挿入する分岐で既定 750 ms**、
        /// **生テキストを先に挿入する分岐では NFR-P6b**（要件定義書 §2.8.6）。
        /// 整形しなかった場合はほぼ 0。
        public let refine: Duration
        /// M4: 整形完了 → 挿入完了。目標 50 ms（NFR-P5）。
        ///
        /// - Important: **これは NFR-P5 と同じ量ではない。** ここが測るのは
        ///   `TextInserting.insert(_:)` の実時間なので、Pasteboard 経路を通った場合は
        ///   クリップボードの**復元待ち 120 ms が入る**。詳細設計書 §6.3 は
        ///   「挿入はテキストが貼り付いた時点で完了しており、復元はその後始末」として
        ///   その 120 ms を NFR-P5 に数えない。**この値を NFR-P5 と直接比べないこと**
        ///   （経緯と予算配分は詳細設計書 §10 の「M4 について」）。
        ///   一段目の AX 経路（往復 0.1〜5.5 ms）にはこの待ちが無い。
        public let insert: Duration

        /// この発話の間に**変換に失敗して捨てられた**バッファの数。
        ///
        /// `AudioCapturing.droppedBufferCount` はインスタンス生涯の累計なので、
        /// ここには**録音の前後で取った差分**が入る（Task 7 申し送り）。
        /// 0 でない発話は音の一部が欠けている。
        public let droppedBuffers: Int

        /// **整形を挿入の前に待ったか。** これが `total` の定義を決める。
        ///
        /// - `true` … (b) の分岐（`refinementApplyMode == .beforeInsert`、または
        ///   差し替えできない挿入先）。整形はクリティカルパスの上にある。
        /// - `false` … (a) の分岐（FR-5(a)）。**整形は挿入と並行に走るので、
        ///   テキストが現れるまでの時間には入らない。**
        ///
        /// 既定は `true`——フェーズ 1 の呼び出し側（と既存の計測）はすべて (b) だからである。
        public let waitedForRefinementBeforeInsert: Bool

        /// M6: キー解放 → **差し替え完了**（NFR-P6b）。差し替えを行わなかったら nil。
        ///
        /// **nil は失敗ではない。** 差し替えできない挿入先・整形が無効・整形が返らなかった・
        /// 差し替えを断念した、のいずれでも nil になる。どの場合も生テキストは欄にある。
        public let revision: Duration?

        /// M5a: キー解放 → **テキストが挿入先に現れる**まで。**NFR-P6a の判定はこれで行う。**
        ///
        /// - Important: **(a) と (b) で足す区間が違う。**
        ///   (b) は `M2 + M3 + M4`、(a) は `M2 + M4`（整形は挿入の後ろにある）。
        ///   **既存の M5 実測（398 / 411 ms）は (b) の値なので、(a) の値と並べて
        ///   比べないこと**（詳細設計書 §10）。
        public var total: Duration {
            waitedForRefinementBeforeInsert ? finalize + refine + insert : finalize + insert
        }

        public var finalizeMs: Int { Metrics.milliseconds(finalize) }
        public var refineMs: Int { Metrics.milliseconds(refine) }
        public var insertMs: Int { Metrics.milliseconds(insert) }
        /// M6 のミリ秒。差し替えを行わなかったら nil。
        public var revisionMs: Int? { revision.map(Metrics.milliseconds) }

        /// **3 つのミリ秒の和ではなく、合計の実時間から丸める。**
        /// 各区間を切り捨ててから足すと、合計が最大 3 ms 過少に出る。
        public var totalMs: Int { Metrics.milliseconds(total) }

        /// NFR-P6a（1 秒以内）を満たしたか。**`total` と同じ区別が掛かる。**
        public var meetsTarget: Bool { total <= Metrics.totalBudget }

        /// NFR-P6b（目標 2 秒）を満たしたか。**差し替えを行わなかったら nil。**
        ///
        /// **nil を「未達」と数えてはならない。** 差し替えできない挿入先では
        /// そもそもこの要件の対象外である（要件定義書 NFR-P6b は「差し替え可能経路のみ」）。
        public var meetsRevisionTarget: Bool? {
            revision.map { $0 <= Metrics.revisionBudget }
        }

        public init(
            finalize: Duration, refine: Duration, insert: Duration, droppedBuffers: Int = 0,
            waitedForRefinementBeforeInsert: Bool = true, revision: Duration? = nil
        ) {
            self.finalize = finalize
            self.refine = refine
            self.insert = insert
            self.droppedBuffers = droppedBuffers
            self.waitedForRefinementBeforeInsert = waitedForRefinementBeforeInsert
            self.revision = revision
        }

        /// 差し替えが終わった時点の値を作る。
        ///
        /// **(a) の分岐では M3（整形）が挿入より後に確定する。** 挿入の直後に作った
        /// 標本は `refine: .zero` を持っており、整形が返ってから本当の値が入る。
        /// **M2 / M4 は動かさない**——挿入までの区間は既に確定している。
        /// - Parameter revision: 差し替えが**実際に走った**場合だけ入れる。
        ///   整形が返らずに終わったときは nil のままにする——そこは NFR-P6b の
        ///   対象外であり、nil を「未達」と数えてはならない（`meetsRevisionTarget`）。
        func rewriting(refine: Duration, revision: Duration?) -> Sample {
            Sample(
                finalize: finalize, refine: refine, insert: insert,
                droppedBuffers: droppedBuffers,
                waitedForRefinementBeforeInsert: waitedForRefinementBeforeInsert,
                revision: revision)
        }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }
}

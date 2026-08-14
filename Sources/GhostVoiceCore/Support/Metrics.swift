import Foundation

/// 詳細設計書 §10 の計測点。
public enum Metrics {

    /// NFR-P6a。発話終了 → **テキストが挿入先に現れる**までの上限。
    ///
    /// - Important: **要件定義書 §2.8.6 の裁定で、この 1 秒が守る対象が変わった。**
    ///   守るのは「整形済みテキスト」ではなく「まず使えるテキスト」である。
    ///   **差し替えできる挿入先では、生テキストを先に挿入するので整形（M3）がこの予算に入らない。**
    ///   下の `Sample.total` / `meetsTarget` は現在も `M2 + M3 + M4` を返す——
    ///   これは**整形を待ってから挿入する分岐（(b)）の値**であり、
    ///   **差し替えの分岐を実装する時点で、この 2 つの定義も直す必要がある**（詳細設計書 §10）。
    public static let totalBudget: Duration = .milliseconds(1_000)

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

        /// M5a: キー解放 → 挿入完了（**整形を待ってから挿入する分岐の値**）。
        ///
        /// - Important: **生テキストを先に挿入する分岐（要件定義書 FR-5(a)）では、
        ///   この和は M5a ではない**——そこでは整形が挿入の後ろにあるので、
        ///   M5a は `finalize + insert` になり、整形の反映は別の値（M6）で測る。
        ///   **既存の M5 実測（398 / 411 ms）と並べて比べないこと**（詳細設計書 §10）。
        public var total: Duration { finalize + refine + insert }

        public var finalizeMs: Int { Metrics.milliseconds(finalize) }
        public var refineMs: Int { Metrics.milliseconds(refine) }
        public var insertMs: Int { Metrics.milliseconds(insert) }

        /// **3 つのミリ秒の和ではなく、合計の実時間から丸める。**
        /// 各区間を切り捨ててから足すと、合計が最大 3 ms 過少に出る。
        public var totalMs: Int { Metrics.milliseconds(total) }

        /// NFR-P6a（1 秒以内）を満たしたか。**`total` と同じ留保が掛かる。**
        public var meetsTarget: Bool { total <= Metrics.totalBudget }

        public init(finalize: Duration, refine: Duration, insert: Duration, droppedBuffers: Int = 0) {
            self.finalize = finalize
            self.refine = refine
            self.insert = insert
            self.droppedBuffers = droppedBuffers
        }

    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }
}

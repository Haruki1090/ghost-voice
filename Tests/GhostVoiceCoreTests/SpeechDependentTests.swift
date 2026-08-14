import Testing
import Foundation
@testable import GhostVoiceCore

/// ja-JP のモデル資産を実際に回すテストの親。
///
/// **`.serialized` はここに掛ける。** `.serialized` はそのスイート（と入れ子のスイート）の
/// 直列化しか保証せず、**別々のトップレベルスイート同士は並行して走る**。
/// 資産を回すテストは `AssetInventory` の確保・解放というプロセス全体の状態を触るため、
/// 別スイートと並行すると次が起こる。
///
/// - 確保の解放が他スイートの解析へ割り込む（フレーク）
/// - 逆に他スイートの確保が先に入ると `status` が `.installed` を返し、
///   確保順序の誤りが隠れて false pass になる（`doesNotRequestDownloadForInstalledModel` が
///   検出するために存在している当の欠陥）
///
/// 資産に依存するスイートはすべてこの下に入れ子で置くこと。
@Suite(
    "ja-JP モデル資産に依存する認識テスト",
    .serialized,
    .enabled("ja-JP のモデル資産が要る") { await SpeechFixtures.modelInstalled(locale: .jaJP) }
)
struct SpeechDependentTests {}

extension Locale {
    static let jaJP = Locale(identifier: "ja-JP")
}

/// 有意差の判定に使う相対比。
///
/// 合成音声での実測差は CER 3.02 % 対 3.21 %（比 0.94）で、529 字中 1 文字ぶんしかない。
/// この幅で既定値を決めると、OS 更新やフィクスチャ再生成のたびに結論が裏返る。
/// **20 % 以上の相対差がついたときだけ「見直すべき差」とみなす。**
enum AccuracySignificance {
    static let ratio = 0.8

    /// `alternative` が `current` より有意に良いか。
    static func isSignificantlyBetter(_ alternative: Double, than current: Double) -> Bool {
        alternative < current * ratio
    }
}

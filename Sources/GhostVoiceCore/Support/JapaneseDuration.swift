import Foundation

/// **`Duration` を利用者が読む日本語へ落とす、唯一の場所。**
///
/// ## なぜ型があるのか
///
/// `Duration` を文字列補間へそのまま置くと、標準ライブラリの記述がそのまま出る——
/// `"\(Duration.seconds(10))"` は **`10.0 seconds`** である。
/// 実機のログにこれが出た（2026-08-15）:
///
/// ```
/// [終了] 10.0 seconds 待っても待機へ戻りませんでした。打ち切ります。
/// ```
///
/// **他の文言はすべて日本語なので、ここだけが英語で出る。**
/// 「日本語にする」を注意書きで守ると片方だけ直り、しかも両方とも自分の検査では緑になる
/// （`ShutdownAnnouncement` を Core に 1 つだけ置いたのとまったく同じ理由）。
/// **`Duration` を利用者向けの文字列にするときは必ずここを通すこと。**
///
/// ## 丸め方（**決めごとであって実測ではない**）
///
/// - 小数第 1 位まで。`0.1` 秒より細かい差は、待ち時間の案内としては意味を持たない
/// - 整数になるなら小数点以下は書かない（`10 秒`。`10.0 秒` とは書かない）
/// - **負の長さは 0 として扱う。** 残り時間の計算が締め切りをまたぐと負になりうるが、
///   「残り -0.3 秒」は利用者にとって意味を持たない
public enum JapaneseDuration {

    /// 「10 秒」「1.5 秒」「0 秒」。
    public static func text(_ duration: Duration) -> String {
        "\(number(duration)) 秒"
    }

    /// 数の部分だけ。**単位を別の語（「秒以内」など）に付け替えたいときに使う。**
    public static func number(_ duration: Duration) -> String {
        let rounded = (max(0, seconds(duration)) * 10).rounded() / 10
        // **整数なら小数点以下を書かない。** `Int` へ落としてから補間しないと
        // `10.0` と出る（この型が存在する理由そのものである）。
        if rounded == rounded.rounded(.towardZero) { return "\(Int(rounded))" }
        return "\(rounded)"
    }

    /// 秒数（実数）。**丸めない。** 呼び手が自分で刻みを決めるときに使う。
    public static func seconds(_ duration: Duration) -> Double {
        let (whole, attoseconds) = duration.components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}

import Foundation
import Testing

@testable import GhostVoiceCore

/// **`Duration` を利用者向けの文字列にする唯一の場所。**
///
/// 実機のログに `[終了] 10.0 seconds 待っても待機へ戻りませんでした。` が出た
/// （2026-08-15）。**他がすべて日本語なので、ここだけが英語で浮く。**
@Suite("Duration の日本語表記")
struct JapaneseDurationTests {

    @Test(
        "秒の表記",
        arguments: [
            (Duration.seconds(10), "10 秒"),
            (.seconds(1), "1 秒"),
            (.zero, "0 秒"),
            (.milliseconds(1500), "1.5 秒"),
            (.milliseconds(100), "0.1 秒"),
            (.seconds(120), "120 秒"),
        ])
    func rendersSeconds(_ duration: Duration, _ expected: String) {
        #expect(JapaneseDuration.text(duration) == expected)
    }

    /// **整数の長さに小数点を付けない。** `10.0 秒` は「10 秒」より読みにくいだけである。
    @Test("整数の長さには小数点を付けない")
    func wholeSecondsHaveNoDecimalPoint() {
        #expect(!JapaneseDuration.text(.seconds(10)).contains("."))
        #expect(!JapaneseDuration.text(.seconds(3)).contains("."))
    }

    /// **負の長さは 0 として扱う。** 残り時間の計算は締め切りをまたぐと負になりうるが、
    /// 「残り -0.3 秒」は利用者にとって意味を持たない。
    @Test("負の長さは 0 秒と言う")
    func negativeIsZero() {
        #expect(JapaneseDuration.text(.seconds(-5)) == "0 秒")
        #expect(JapaneseDuration.text(.milliseconds(-1)) == "0 秒")
    }

    /// **英語の記述が 1 語も混ざらないこと。** これがこの型の存在理由である。
    @Test("標準ライブラリの記述が混ざらない")
    func neverLeaksTheStandardDescription() {
        for duration: Duration in [.seconds(10), .milliseconds(1500), .zero, .seconds(120)] {
            let text = JapaneseDuration.text(duration)
            #expect(!text.contains("second"), "英語の記述が混ざっている: \(text)")
            #expect(text.hasSuffix(" 秒"))
        }
    }

    @Test("秒数（実数）はそのまま返す")
    func secondsAreNotRounded() {
        #expect(JapaneseDuration.seconds(.milliseconds(1500)) == 1.5)
        #expect(JapaneseDuration.seconds(.seconds(10)) == 10)
    }
}

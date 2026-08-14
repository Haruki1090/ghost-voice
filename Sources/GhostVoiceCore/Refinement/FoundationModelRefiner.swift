import Foundation
import FoundationModels

/// Apple Intelligence のオンデバイス LLM で認識結果を整形する。
///
/// **セッションは発話ごとに作り、持ち越さない。** 使い回すと前の発話が会話履歴として
/// 残り、次の整形へ混入する（実測で、直前の発話の話題がそのまま次の出力に現れた）。
/// 作り直す代償は小さい: 実測で `init` 0.001〜0.002 秒、`prewarm()` 0.000 秒で、
/// **モデルの再ロードは起きない**。モデルの常駐はセッションではなくプロセス外の
/// デーモン側にあり、セッションの生存期間とは独立している。
///
/// セッションを保持しないので、この型は可変状態を持たない。
public final class FoundationModelRefiner: Refining {

    private let availability: @Sendable () -> SystemLanguageModel.Availability

    /// - Parameter availability: モデルの利用可否。既定はシステムの状態を読む。
    ///   Apple Intelligence が有効な機体では縮退経路を実行できないため、テストが差し替える。
    public init(
        availability: @escaping @Sendable () -> SystemLanguageModel.Availability = {
            SystemLanguageModel.default.availability
        }
    ) {
        self.availability = availability
    }

    public var isAvailable: Bool { availability() == .available }

    /// 起動時に一度呼ぶ。モデルのロードを**完了させて**から返る。
    ///
    /// `LanguageModelSession.prewarm()` を呼ぶだけでは足りない。実測では
    /// `prewarm()` が 0.013 秒で返った後も 1 回目の `respond` に 3.318 秒掛かり、
    /// 2 回目が 0.347 秒だった。ロードを実際に強いるのは `respond` の方なので、
    /// ここで捨て推論を 1 回通して、その 3 秒を起動時へ寄せる。
    ///
    /// そのぶんこの関数はコールド時に数秒掛かる。**起動時に投げっぱなしで呼び、
    /// 発話の待ち合わせには使わないこと。** 温まる対象はプロセス外のデーモンが持つ
    /// モデル本体なので、ここで使うロケールに関わらず他ロケールの整形も速くなる。
    public func prewarm() async {
        guard isAvailable else { return }
        _ = await generate(
            prompt: RefinementPrompt.prompt(rawText: Self.prewarmUtterance, terms: []),
            locale: Locale(identifier: "ja-JP"),
            timeout: .seconds(10)
        )
    }

    public func refine(
        _ raw: String, locale: Locale, terms: [VocabularyTerm], timeout: Duration
    ) async -> String? {
        guard isAvailable, RefinementGuard.isRefinable(raw) else { return nil }

        let output = await generate(
            prompt: RefinementPrompt.prompt(rawText: raw, terms: terms),
            locale: locale,
            timeout: timeout
        )

        guard let output else { return nil }
        // **辞書も渡す。** 残存率の検査は「頼んだ置換を当てた後の入力」と比べる
        // （渡さないと FR-6 の置換が逸脱と区別できない。`RefinementGuard` の表）。
        return RefinementGuard.accept(output, refinementOf: raw, terms: terms)
    }

    /// 1 リクエスト = 1 セッション。次の発話は別のセッションを使う。
    ///
    /// 打ち切った生成がこのセッションを掴んだまま残ることはありうる（`withTimeout` は
    /// 待たない）が、そのセッションは二度と参照されないので `concurrentRequests` に
    /// はならない。
    private func generate(prompt: String, locale: Locale, timeout: Duration) async -> String? {
        let session = LanguageModelSession(
            instructions: RefinementPrompt.instructions(for: locale)
        )
        session.prewarm()

        return await withTimeout(timeout) {
            try? await session.respond(
                to: prompt, options: GenerationOptions(temperature: 0.0)
            ).content
        }
    }

    /// 捨て推論に使う発話。**フィラー付きの文にすること。**
    /// 単語だけを渡すとモデルが整形と解さず暴走する。実測で「テスト」は 53.5 秒
    /// 走った末に失敗し、「えー、テストです」は 0.309 秒で「テストです。」を返した。
    private static let prewarmUtterance = "えー、テストです"
}

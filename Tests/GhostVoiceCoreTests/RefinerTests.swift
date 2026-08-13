import Testing
import Foundation
import FoundationModels
@testable import GhostVoiceCore

/// キャンセルを尊重しない作業。打ち切りに応じない生成を模す。
/// `Task.sleep` はキャンセルで即座に抜けるため、待ち合わせの検証には使えない。
private func uncancellableWork(seconds: Double, returning value: String) async -> String? {
    await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
    return value
}

@Suite("Refiner")
struct RefinerTests {

    /// 打ち切りは「nil が返る」だけでは測れない。作業の完了を待ってから nil を返す
    /// 実装でも `out == nil` は通ってしまうので、経過時間で打ち切りの有無を見る。
    @Test("タイムアウトすると作業の完了を待たずに nil を返す")
    func timesOut() async {
        let stub = StubRefiner(result: "整形結果", delay: .milliseconds(400))

        let start = ContinuousClock.now
        let out = await stub.refine("生", locale: .jaJP, terms: [], timeout: .milliseconds(50))
        let elapsed = ContinuousClock.now - start

        #expect(out == nil)
        #expect(elapsed < .milliseconds(300), "打ち切りが効いていない: \(elapsed)")
    }

    @Test("時間内なら結果を返す")
    func returnsWithinTimeout() async {
        let stub = StubRefiner(result: "整形結果", delay: .milliseconds(10))
        let out = await stub.refine("生", locale: .jaJP, terms: [], timeout: .milliseconds(500))
        #expect(out == "整形結果")
    }

    @Test("利用不可なら常に nil を返す")
    func unavailableReturnsNil() async {
        let stub = StubRefiner(result: nil, delay: .zero)
        #expect(!stub.isAvailable)
        let out = await stub.refine("生", locale: .jaJP, terms: [], timeout: .milliseconds(500))
        #expect(out == nil)
    }

    /// 空白だけの認識結果に LLM を回しても意味が無く、その時間ぶん挿入が遅れる。
    /// 「遅延を待たずに」返ることまで見ないと、素通しの実装と区別が付かない。
    @Test("空白のみの入力は整形へ回さず nil を返す")
    func blankInputShortCircuits() async {
        let stub = StubRefiner(result: "整形結果", delay: .milliseconds(400))

        for raw in ["", " ", "\n", "  \n\t "] {
            let start = ContinuousClock.now
            let out = await stub.refine(raw, locale: .jaJP, terms: [], timeout: .seconds(5))
            let elapsed = ContinuousClock.now - start

            #expect(out == nil, "入力 \(raw.debugDescription)")
            #expect(elapsed < .milliseconds(300), "整形へ回している: \(raw.debugDescription) \(elapsed)")
        }
    }

    /// **`timeout` は実時間の上限。** 打ち切った作業の完了を待つ実装だと、作業が
    /// キャンセルに応じない場合に呼び出しが `timeout` を超え、その間ユーザーへの
    /// 文字入力が止まる。実測では、待つ実装は 2.132 秒、待たない実装は 0.059 秒で返った。
    ///
    /// `Task.sleep` はキャンセルに応じてしまうので、この性質の検証には使えない
    /// （待つ実装でも速く返り、区別が付かない）。応じない作業を用意している。
    @Test("打ち切りに応じない作業でも時間内に返る")
    func doesNotWaitForUncancellableWork() async {
        let start = ContinuousClock.now
        let out = await withTimeout(.milliseconds(50)) {
            await uncancellableWork(seconds: 2, returning: "遅れて完了")
        }
        let elapsed = ContinuousClock.now - start

        #expect(out == nil)
        #expect(elapsed < .milliseconds(500), "打ち切った作業の完了を待っている: \(elapsed)")
    }

    @Test("時間内に終わった作業の値を withTimeout が返す")
    func withTimeoutReturnsWork() async {
        let out = await withTimeout(.seconds(5)) { "作業の値" }
        #expect(out == "作業の値")
    }
}

@Suite("整形結果の妥当性判定")
struct RefinementGuardTests {

    @Test("空白のみを整形対象から外す")
    func rejectsBlankInput() {
        #expect(!RefinementGuard.isRefinable(""))
        #expect(!RefinementGuard.isRefinable(" "))
        #expect(!RefinementGuard.isRefinable("\n\t "))
        #expect(RefinementGuard.isRefinable("あ"))
        #expect(RefinementGuard.isRefinable(" えー、テストです "))
    }

    /// 実測した正常な整形（12 発話）はいずれも 出力/入力 ≦ 1.00、増分 0 字だった。
    @Test("入力以下の長さに収まる整形を通す")
    func acceptsNormalRefinement() {
        let cases = [
            ("えーっと、あの、来週までに要件定義を完了させます", "来週までに要件定義を完了させます。"),
            ("あの、了解です", "了解です"),
            ("はい", "はい"),
            ("その、次のミーティングは水曜日の午後三時からでお願いします",
             "次のミーティングは水曜日の午後三時からお願いします。"),
        ]
        for (raw, output) in cases {
            #expect(RefinementGuard.isPlausible(output, refinementOf: raw), "\(raw) -> \(output)")
        }
    }

    /// 入力が命令文に読めるとモデルが整形ではなく「応答」を返す。実測で 2.6〜25.6 倍
    /// （+39〜+639 字）に膨らみ、コード片や手順書が混ざった。これを生テキストへ縮退させる。
    @Test("入力より大きく膨らんだ出力を落とす")
    func rejectsInstructionResponse() {
        let raw = "えーっと、まあ、この配列をソートする関数を作りたい"
        let hijacked = """
        ```python
        def sort_array(arr):
            arr.sort()
            return arr
        ```
        """
        #expect(!RefinementGuard.isPlausible(hijacked, refinementOf: raw))

        #expect(!RefinementGuard.isPlausible(
            String(repeating: "あ", count: 484),
            refinementOf: "えー、この関数にエラー処理を追加したいです"
        ))
    }

    /// 短い発話は句読点や正規表記の補正だけで比が跳ねる。比だけで判定すると
    /// 「はい」→「はい。」（1.5 倍）のような正常な整形まで落ちる。
    @Test("短い入力では句読点と正規表記の補正ぶんを許す")
    func allowsGrowthOnShortInput() {
        #expect(RefinementGuard.isPlausible("はい。", refinementOf: "はい"))
        #expect(RefinementGuard.isPlausible("了解です。", refinementOf: "了解"))
        // ジーエイエス(6 字) → Google Apps Script(18 字) の置換を含む整形
        #expect(RefinementGuard.isPlausible(
            "Google Apps Script で書きます。", refinementOf: "えー、ジーエイエスで書きます"
        ))
    }

    /// モデルは末尾に改行を付けて返すことがある。挿入されるのはこの文字列そのものなので、
    /// 前後の空白を落とさないとカーソル位置が 1 行ずれる。
    @Test("受け入れる出力は前後の空白を落として返す")
    func acceptTrimsSurroundingWhitespace() {
        #expect(RefinementGuard.accept("  来週までに完了させます。\n", refinementOf: "えー、来週までに完了させます")
                == "来週までに完了させます。")
        #expect(RefinementGuard.accept("\n\nはい。\n\n", refinementOf: "えー、はい") == "はい。")
    }

    /// 空白だけを返されたら整形は失敗している。生テキストへ縮退させる。
    @Test("空白だけの出力は受け入れない")
    func rejectsBlankOutput() {
        #expect(RefinementGuard.accept("", refinementOf: "えー、はい") == nil)
        #expect(RefinementGuard.accept("   \n\t ", refinementOf: "えー、はい") == nil)
    }

    /// 空白を落とした後の長さで妥当性を測る。落とす前の長さで測ると、
    /// 末尾の改行だけで上限を超えて正常な整形が捨てられる。
    @Test("妥当性は空白を落とした後の長さで測る")
    func judgesPlausibilityAfterTrimming() {
        let raw = String(repeating: "あ", count: 4)          // 上限は 4 + 16 = 20 字
        let output = String(repeating: "い", count: 20)
        #expect(RefinementGuard.accept(output + "\n\n\n", refinementOf: raw) == output)
    }

    /// 長さの検査だけでは、入力と同程度の短いコード片が素通りする。
    @Test("入力と同程度の長さでもコードフェンスを含む出力は受け入れない")
    func rejectsCodeFenceWithinLengthBudget() {
        let raw = "えーっと、まあ、この配列をソートする関数を作りたい"  // 25 字 → 上限 41 字
        let short = "```\narr.sort()\n```"                              // 19 字

        #expect(RefinementGuard.isPlausible(short, refinementOf: raw), "長さでは落ちない前提")
        #expect(RefinementGuard.accept(short, refinementOf: raw) == nil)
    }

    @Test("膨らんだ出力は受け入れない")
    func rejectsImplausibleOutput() {
        #expect(RefinementGuard.accept(
            String(repeating: "あ", count: 484),
            refinementOf: "えー、この関数にエラー処理を追加したいです"
        ) == nil)
    }

    /// 上限の位置そのものを固定する。境界がずれる変更を検出できるようにする。
    @Test("許容量は 入力の 1.5 倍 と 入力 + 16 字 の大きい方")
    func boundaryIsMaxOfRatioAndFloor() {
        // 長い入力では比が効く: 100 字 -> 150 字まで
        let long = String(repeating: "あ", count: 100)
        #expect(RefinementGuard.isPlausible(String(repeating: "い", count: 150), refinementOf: long))
        #expect(!RefinementGuard.isPlausible(String(repeating: "い", count: 151), refinementOf: long))

        // 短い入力では下駄が効く: 4 字 -> 20 字まで（4 * 1.5 = 6 ではなく 4 + 16）
        let short = String(repeating: "あ", count: 4)
        #expect(RefinementGuard.isPlausible(String(repeating: "い", count: 20), refinementOf: short))
        #expect(!RefinementGuard.isPlausible(String(repeating: "い", count: 21), refinementOf: short))
    }
}

@Suite("FoundationModelRefiner の縮退")
struct FoundationModelRefinerDegradationTests {

    /// Apple Intelligence が使えない機体でも製品は動く必要がある（生テキストへ縮退）。
    /// 開発機では `availability` が `.available` を返すため、注入して縮退経路を通す。
    @Test("Apple Intelligence が無効なら整形せず nil を返す")
    func degradesWhenUnavailable() async {
        let reasons: [SystemLanguageModel.Availability.UnavailableReason] = [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady,
        ]
        for reason in reasons {
            let refiner = FoundationModelRefiner(availability: { .unavailable(reason) })
            #expect(!refiner.isAvailable, "\(reason)")

            await refiner.prewarm()

            let start = ContinuousClock.now
            let out = await refiner.refine(
                "えー、あの、来週までに要件定義を完了させます",
                locale: .jaJP, terms: [], timeout: .seconds(5)
            )
            let elapsed = ContinuousClock.now - start

            #expect(out == nil, "\(reason)")
            #expect(elapsed < .milliseconds(100), "モデルを呼びに行っている: \(reason) \(elapsed)")
        }
    }

    @Test("availability が available なら isAvailable が true")
    func availableWhenModelIsAvailable() {
        #expect(FoundationModelRefiner(availability: { .available }).isAvailable)
    }

    @Test("既定の availability は実機の状態を映す")
    func defaultAvailabilityFollowsSystem() {
        #expect(FoundationModelRefiner().isAvailable == SystemLanguageModel.default.isAvailable)
    }
}

/// Apple Intelligence が有効な機体でのみ走る。出力は非決定的なので完全一致では固定せず、
/// 「フィラーが消えている」「内容語が残っている」といった性質で判定する。
///
/// `.serialized` を掛ける理由はレイテンシ計測。並行で走ると別テストの生成と競合して
/// `warmLatency` の実測値が跳ね、閾値判定の意味が無くなる。
@Suite(
    "実機の Apple Intelligence による整形",
    .serialized,
    .enabled(if: FoundationModelRefiner().isAvailable)
)
struct FoundationModelRefinerDeviceTests {

    /// 実機テストは毎回ウォーム済みの整形器から始める。初回の respond はモデルの
    /// ロードを含んで実測 3.3 秒掛かるため、計測にも判定にも混ぜない。
    private func warmedRefiner() async -> FoundationModelRefiner {
        let refiner = FoundationModelRefiner()
        await refiner.prewarm()
        return refiner
    }

    @Test("フィラーを落として内容語を残す")
    func removesFillers() async throws {
        let refiner = await warmedRefiner()

        let out = await refiner.refine(
            "えーっと、あの、来週までに要件定義を完了させます",
            locale: .jaJP, terms: [], timeout: .seconds(10)
        )

        let result = try #require(out)
        print("removesFillers: \(result)")
        #expect(!result.contains("えーっと"))
        #expect(!result.contains("あの"))
        #expect(result.contains("要件定義"))
        #expect(result.contains("来週"))
    }

    /// 発話が命令文に読めると、モデルは整形ではなく「その依頼への回答」を返す。
    /// 実測（新規セッション・temperature 0）で 5 発話中 4 発話が再現性 100 % で逸脱し、
    /// Python のコード片が返った。挿入されるのは整形結果だけであってはならない。
    @Test("命令文に読める発話でも回答を挿入しない")
    func doesNotAnswerInstructionLikeSpeech() async {
        let refiner = await warmedRefiner()

        let inputs = [
            "えー、この関数にエラー処理を追加したいです",
            "あの、READMEにインストール手順を書いてください",
            "えーっと、まあ、この配列をソートする関数を作りたい",
            "その、テストケースを3つ考えてほしいです",
        ]
        for raw in inputs {
            let out = await refiner.refine(raw, locale: .jaJP, terms: [], timeout: .seconds(10))
            print("instruction-like: \(raw.debugDescription) -> \(out?.debugDescription ?? "nil")")

            guard let out else { continue }  // 縮退（nil）は正しい振る舞い
            #expect(!out.contains("```"), "コード片を返している: \(out)")
            #expect(
                RefinementGuard.isPlausible(out, refinementOf: raw),
                "整形と呼べない長さの出力を通している: \(raw) -> \(out)"
            )
        }
    }

    /// 固有名詞の誤認識対策はこのプロンプト注入だけが手段（`contextualStrings` は
    /// 実測で無効）。辞書が効かなければ FR-6 は満たせない。
    @Test("辞書の誤認識表記を正規表記へ直す")
    func appliesVocabulary() async throws {
        let refiner = await warmedRefiner()

        let out = await refiner.refine(
            "えー、ネクサデータの件で連絡しました",
            locale: .jaJP,
            terms: [VocabularyTerm(canonical: "Nexadata", misheard: ["ネクサデータ"])],
            timeout: .seconds(10)
        )

        let result = try #require(out)
        print("appliesVocabulary: \(result)")
        #expect(result.contains("Nexadata"))
        #expect(!result.contains("ネクサデータ"))
    }

    /// **既知の欠陥。** 辞書の写像は語によって効かない。頭字語をカタカナで読み上げた
    /// 誤認識（シーエムエス = C-M-S、エヌピーエム = N-P-M）は、正規表記の綴りを
    /// microCMS / MicroCMS / Microcms / MICROCMS / microcms のどれに変えても
    /// 再現性 100 % で置換されなかった。一方 ネクサデータ → Nexadata、
    /// アイフォン → iPhone、ユーチューブ → YouTube は通る。
    ///
    /// 原因はプロンプトの組み立て側（Task 3 の `RefinementPrompt`）にあり、
    /// 整形器からは手が届かない。設計判断を要するため課題として残す。
    @Test(
        "頭字語のカタカナ読みも正規表記へ直す",
        .disabled("既知の欠陥: microCMS 等の頭字語は置換されない。task-6-report.md 参照")
    )
    func appliesVocabularyToSpelledOutAcronyms() async throws {
        let refiner = await warmedRefiner()

        let out = await refiner.refine(
            "えー、マイクロシーエムエスの記事を更新します",
            locale: .jaJP,
            terms: [VocabularyTerm(canonical: "microCMS", misheard: ["マイクロシーエムエス"])],
            timeout: .seconds(10)
        )

        let result = try #require(out)
        #expect(result.contains("microCMS"))
    }

    /// 空白だけの認識結果をモデルへ投げると、返るのは結局 nil なので `out == nil` だけでは
    /// ガードの有無を区別できない。往復ぶんの時間が消えていないことまで見る。
    @Test("空文字は実機でも整形へ回さない")
    func blankInputOnDevice() async {
        let refiner = await warmedRefiner()

        let start = ContinuousClock.now
        let out = await refiner.refine("   ", locale: .jaJP, terms: [], timeout: .seconds(10))
        let elapsed = ContinuousClock.now - start

        #expect(out == nil)
        #expect(elapsed < .milliseconds(100), "モデルへ投げている: \(elapsed)")
    }

    /// `prewarm()` は「ロードの開始を促す」だけでは足りず、捨て推論まで通して初めて
    /// 1 回目の整形が速くなる（実測: `LanguageModelSession.prewarm()` は 0.013 秒で
    /// 返るのに、その後の 1 回目の respond が 3.318 秒掛かった）。
    /// 捨て推論を通していれば、ウォーム済みでも生成 1 回ぶんの時間は必ず掛かる。
    @Test("prewarm がモデルのロードを完了させてから返る")
    func prewarmRunsGeneration() async {
        let refiner = FoundationModelRefiner()

        let start = ContinuousClock.now
        await refiner.prewarm()
        let elapsed = ContinuousClock.now - start

        print("prewarm: \(elapsed)")
        // ウォーム済みの生成が実測 0.28〜0.41 秒。呼び出しを促すだけの実装は 0.013 秒で返る。
        #expect(elapsed > .milliseconds(50), "捨て推論を通していない: \(elapsed)")
    }

    /// 発話ごとにセッションを作り直す設計の意味。セッションを持ち越すと前の発話が
    /// 会話履歴として残り、同じ発話でも直前に何を喋ったかで整形結果が変わる。
    /// ディクテーションは 1 発話ごとに独立していなければならない。
    ///
    /// 指示語を含む発話で差が出る。実測では、直前に「品川オフィス」の発話がある
    /// セッションは「そこに十時に集合してください。」を返し、まっさらなセッションは
    /// 「十時に集合してください。」を返した。
    @Test("前の発話が次の整形結果を変えない")
    func priorUtteranceDoesNotChangeResult() async throws {
        let followUp = "あの、そこに十時に集合してください"

        let alone = await warmedRefiner()
            .refine(followUp, locale: .jaJP, terms: [], timeout: .seconds(10))

        let refiner = await warmedRefiner()
        let first = await refiner.refine(
            "えーっと、明日の会議は品川オフィスで行います",
            locale: .jaJP, terms: [], timeout: .seconds(10)
        )
        let after = await refiner.refine(followUp, locale: .jaJP, terms: [], timeout: .seconds(10))

        print("単独        : \(alone?.debugDescription ?? "nil")")
        print("前の発話    : \(first?.debugDescription ?? "nil")")
        print("前の発話の後: \(after?.debugDescription ?? "nil")")

        #expect(after == alone, "前の発話が結果を変えている")
        let result = try #require(after)
        #expect(!result.contains("品川"))
    }

    /// ロケールごとに `instructions` を作り分けている意味。ja-JP の指示のまま英語を
    /// 渡すと、実測で「会議は明日の午前10時に開催されます。」と日本語へ訳された。
    @Test("英語ロケールでは英語のまま整形する")
    func refinesEnglish() async throws {
        let refiner = await warmedRefiner()

        let out = await refiner.refine(
            "uh, like, the meeting is at ten tomorrow morning",
            locale: Locale(identifier: "en-US"), terms: [], timeout: .seconds(10)
        )

        let result = try #require(out)
        print("refinesEnglish: \(result)")
        #expect(result.localizedCaseInsensitiveContains("meeting"))
        #expect(!result.contains("会議"), "日本語へ訳している")
        #expect(!result.contains("uh,"))
    }

    /// NFR-P6 の予算配分の根拠。既定のタイムアウト 500ms が妥当かをここで測る。
    ///
    /// 命令文に読める発話は計測に入れない。逸脱した生成は長文を吐いて実測 1.3〜3.4 秒
    /// 掛かるため、混ぜると「整形に要る時間」ではなく「逸脱の発生率」を測ってしまう。
    @Test("ウォーム後の整形が 500ms 以内")
    func warmLatency() async {
        let refiner = await warmedRefiner()

        var samples: [Duration] = []
        for raw in [
            "えーっと、あの、来週までに要件定義を完了させます",
            "あの、まあ、今日の売上は前年比で百二十パーセントでした",
            "その、資料は明日までに送りますので、確認をお願いします",
            "えーっと、次のミーティングは水曜日の午後三時からでお願いします",
            "えー、エラーハンドリングが抜けているので、そこを直します",
        ] {
            let start = ContinuousClock.now
            _ = await refiner.refine(raw, locale: .jaJP, terms: [], timeout: .seconds(10))
            samples.append(ContinuousClock.now - start)
        }

        let sorted = samples.sorted()
        print("warm refine samples: \(samples)")
        print("warm refine median : \(sorted[sorted.count / 2])")
        print("warm refine max    : \(sorted.last!)")

        #expect(sorted[sorted.count / 2] < .milliseconds(500), "中央値: \(sorted[sorted.count / 2])")
    }
}

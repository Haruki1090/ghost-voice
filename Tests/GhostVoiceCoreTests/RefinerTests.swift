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
    ///
    /// **線の決め方（規律 10）。** ここが弁別するのは「打ち切った（50 ms）」と
    /// 「作業の完了を待った（5 秒）」で、**2 秒はその間に置いた壊れ検知の線であって
    /// 要件値ではない**（要件は NFR-P4 の 500 ms で、それを見るのは実機の中央値の検査）。
    ///
    /// **遅い側を 400 ms から 5 秒へ広げた。** 実測すると `Task.sleep(50ms)` の
    /// 実所要は p50 54 ms・**最大 167 ms**（静かなプロセス / n=200）で、
    /// 同一プロセスで実時間の音声認識が走っている間は **859 ms** まで伸びた
    /// （Task 11 で実際にこの検査が落ちた値）。旧構成は「線 300 ms・遅い側 400 ms」で、
    /// **ノイズの幅が両者の隙間より大きかった。** 線を上げるだけでは弁別が消えるので、
    /// **速い側と遅い側の距離そのものを広げてある**（緑の経路の所要は変わらない）。
    @Test("タイムアウトすると作業の完了を待たずに nil を返す")
    func timesOut() async {
        let stub = StubRefiner(result: "整形結果", delay: .seconds(5))

        let start = ContinuousClock.now
        let out = await stub.refine("生", locale: .jaJP, terms: [], timeout: .milliseconds(50))
        let elapsed = ContinuousClock.now - start

        #expect(out == nil)
        #expect(elapsed < .seconds(2), "打ち切りが効いていない（線は壊れ検知。要件値ではない）: \(elapsed)")
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
    ///
    /// **線は 2 秒（壊れ検知であって要件値ではない）。** 弁別するのは
    /// 「素通しした（0 ms）」と「整形へ回した（5 秒）」。`timesOut` と同じ理由で
    /// 遅い側を広げてある（実測ノイズは最大 167 ms、飽和時 859 ms）。
    @Test("空白のみの入力は整形へ回さず nil を返す")
    func blankInputShortCircuits() async {
        let stub = StubRefiner(result: "整形結果", delay: .seconds(5))

        for raw in ["", " ", "\n", "  \n\t "] {
            let start = ContinuousClock.now
            let out = await stub.refine(raw, locale: .jaJP, terms: [], timeout: .seconds(5))
            let elapsed = ContinuousClock.now - start

            #expect(out == nil, "入力 \(raw.debugDescription)")
            #expect(
                elapsed < .seconds(2),
                "整形へ回している（線は壊れ検知。要件値ではない）: \(raw.debugDescription) \(elapsed)")
        }
    }

    /// **`timeout` は実時間の上限。** 打ち切った作業の完了を待つ実装だと、作業が
    /// キャンセルに応じない場合に呼び出しが `timeout` を超え、その間ユーザーへの
    /// 文字入力が止まる。実測では、待つ実装は 2.132 秒、待たない実装は 0.059 秒で返った。
    ///
    /// `Task.sleep` はキャンセルに応じてしまうので、この性質の検証には使えない
    /// （待つ実装でも速く返り、区別が付かない）。応じない作業を用意している。
    ///
    /// **線は 2 秒（壊れ検知であって要件値ではない）。** 弁別するのは
    /// 「打ち切った（50 ms）」と「応じない作業の完了を待った（5 秒）」。
    /// 旧構成は「線 500 ms・遅い側 2 秒」で、実測ノイズ（飽和時 859 ms）が線を越えた。
    @Test("打ち切りに応じない作業でも時間内に返る")
    func doesNotWaitForUncancellableWork() async {
        let start = ContinuousClock.now
        let out = await withTimeout(.milliseconds(50)) {
            await uncancellableWork(seconds: 5, returning: "遅れて完了")
        }
        let elapsed = ContinuousClock.now - start

        #expect(out == nil)
        #expect(
            elapsed < .seconds(2),
            "打ち切った作業の完了を待っている（線は壊れ検知。要件値ではない）: \(elapsed)")
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
        // **埋める側は句読点にする。** 別の語で埋めると「入力に無い語を足した」検査に
        // 落ちて、「空白を落としているか」を確かめられない（この検査の目的が変わる）。
        let raw = String(repeating: "あ", count: 4)          // 上限は 4 + 16 = 20 字
        let output = raw + String(repeating: "。", count: 16)  // ちょうど 20 字
        #expect(output.count == 20)
        #expect(RefinementGuard.accept(output + "\n\n\n", refinementOf: raw) == output)
    }

    /// 長さの検査だけでは、入力と同程度の短いコード片が素通りする。
    @Test("入力と同程度の長さでもコードフェンスを含む出力は受け入れない")
    func rejectsCodeFenceWithinLengthBudget() {
        let raw = "えーっと、まあ、この配列をソートする関数を作りたい"  // 25 字 → 上限 41 字
        let short = "```\narr.sort()\n```"                              // 19 字

        #expect(RefinementGuard.containsCodeFence(short), "フェンスを検出できない入力では門を弁別できない")
        #expect(RefinementGuard.isPlausible(short, refinementOf: raw), "長さでは落ちない前提")
        #expect(RefinementGuard.accept(short, refinementOf: raw) == nil)
    }

    /// **コードフェンスの門が、他の門と独立に効く唯一の場所を駆動する。**
    ///
    /// 最終レビューの変異検査で、`accept` からフェンスの条件を外しても
    /// `containsCodeFence` を常に false にしても**全件緑だった**（変異 G6 / G6b）。
    /// **他のすべての例では追加字数の検査が同じ出力を落としていた**からである
    /// ——バッククォートは Unicode 分類 Sk（記号）で `freelyInsertable` に入らず、
    /// フェンス 1 個で追加 3 字になる。
    ///
    /// **独立に効くのは「入力側にフェンスがある」場合だけ**である。そのとき
    /// フェンスは入力由来なので追加字数は 0 になり、**追加字数の検査は通してしまう。**
    /// 音声認識がバッククォートを返すことは無いが、**FR-6 の辞書は利用者が手で書く**
    /// （`applyingVocabulary` が入力へ当てるので、辞書経由で `expected` に入りうる）。
    ///
    /// **「整形結果にコードフェンスは決して現れない」は入力に依らない絶対条件**である。
    @Test("入力にコードフェンスが含まれていても、出力のフェンスは受け入れない")
    func rejectsCodeFenceEvenWhenInputContainsIt() {
        let raw = "```arr.sort()```"
        let output = "```arr.sort()```"

        #expect(
            RefinementGuard.unsupportedAdditions(output, of: raw) == 0,
            "追加字数の検査は素通りする（だからこの門が独立に要る）")
        #expect(RefinementGuard.isPlausible(output, refinementOf: raw), "長さでも落ちない")
        #expect(RefinementGuard.keepsSomeContent(output, of: raw), "内容の検査でも落ちない")
        #expect(
            RefinementGuard.accept(output, refinementOf: raw) == nil,
            "フェンスの門だけがこれを落とす")

        // 辞書経由でも同じ。頼んだ置換の結果がフェンスでも受け入れない
        let terms = [VocabularyTerm(canonical: "```sort```", misheard: ["ソート"])]
        #expect(
            RefinementGuard.accept("```sort```", refinementOf: "ソート", terms: terms) == nil)
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
            // **線は 1 秒（壊れ検知であって要件値ではない）。**
            // ここは遅い側を広げられない（相手が実モデル）。ただし利用不可のモデルへの
            // 往復は速く失敗するので、この線が実際に捕まえるのは**ハングと桁違いの回帰**である。
            // 100 ms だと実測ノイズ（最大 167 ms、飽和時 859 ms）で落ちるだけで、
            // 弁別力はほとんど増えない。
            #expect(
                elapsed < .seconds(1),
                "モデルを呼びに行っている（線は壊れ検知。要件値ではない）: \(reason) \(elapsed)")
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

    /// **「モデルが応答しなかった」を検査の失敗にしない。**
    ///
    /// 最終レビュー §9 が断続的失敗の機序を特定した: 冷えた日は `prewarm()` の 10 秒でも
    /// 温まらず、続く `refine` も 10 秒で打ち切られて nil になる（**84 回中 4 回、
    /// 静穏の 14 連発では 3/14**）。`#require(out)` はそれをそのまま失敗にしていた。
    /// **落ちるゲートは読み飛ばされるようになり、無いより悪い**（開発サイクル §5）。
    ///
    /// 応答が無い理由はタイムアウトだけではない。実測（2026-08-15）で、
    /// **`五人で行きます` `参加者は百人です` のような無害な発話が `guardrailViolation` で
    /// 拒否される**ことを確認した。`成功` の 1 語では 52.1 秒暴走した末に
    /// `exceededContextWindowSize` になった。**どれも製品としては正しい縮退**である
    /// （生テキストを挿入する）。
    ///
    /// **一方「応答はあったが検査が捨てた」は失敗にする。** そこは縮退ではなく退行で、
    /// この検査が守るべきもの（`RefinementGuard` が正当な整形を落としていないこと）そのもの。
    private func refinedOnDevice(
        _ refiner: FoundationModelRefiner, _ raw: String,
        locale: Locale = .jaJP, terms: [VocabularyTerm] = [],
        _ label: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> String? {
        let generated = await refiner.generate(
            prompt: RefinementPrompt.prompt(rawText: raw, terms: terms),
            locale: locale, timeout: .seconds(10)
        )
        guard let generated else {
            print("\(label): モデルが応答しなかった（縮退。判定は行わない）: \(raw)")
            return nil
        }
        let accepted = RefinementGuard.accept(generated, refinementOf: raw, terms: terms)
        #expect(
            accepted != nil,
            "整形は返ったのに検査が捨てた（退行）: \(raw) -> \(generated.debugDescription)",
            sourceLocation: sourceLocation)
        return accepted
    }

    @Test("フィラーを落として内容語を残す")
    func removesFillers() async {
        let refiner = await warmedRefiner()

        guard let result = await refinedOnDevice(
            refiner, "えーっと、あの、来週までに要件定義を完了させます", "removesFillers"
        ) else { return }

        print("removesFillers: \(result)")
        #expect(!result.contains("えーっと"))
        #expect(!result.contains("あの"))
        #expect(result.contains("要件定義"))
        #expect(result.contains("来週"))
    }

    /// **規則 5（数字の表記を変えない）が実機で効いていることを、既定の検査で押さえる。**
    ///
    /// これが効かなくなると、`RefinementGuard` の許容量 0 が**正当な整形を落とし始める**
    /// （実測: `十時` → `10時` で追加 2 字、`百二十パーセント` → `120％` で追加 3 字）。
    /// 症状は「整形が黙って効かなくなる」なので、検査で見ていないと気づけない。
    @Test("実機で数字の表記が変わらない（規則 5）")
    func keepsNumeralNotation() async {
        let refiner = await warmedRefiner()

        for raw in [
            "えー明日の会議は十時からですのでよろしくお願いします",
            "今日の売上は前年比で百二十パーセントでした",
            "あの、予算は一万円です",
        ] {
            guard let result = await refinedOnDevice(refiner, raw, "keepsNumeralNotation")
            else { continue }

            print("keepsNumeralNotation: \(raw) -> \(result)")
            let hasArabicNumeral = result.contains { $0.isNumber && $0.isASCII }
            #expect(
                !hasArabicNumeral,
                "漢数字を算用数字へ直している（規則 5 が効いていない）: \(raw) -> \(result)")
        }
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
    func appliesVocabulary() async {
        let refiner = await warmedRefiner()

        guard let result = await refinedOnDevice(
            refiner, "えー、ネクサデータの件で連絡しました",
            terms: [VocabularyTerm(canonical: "Nexadata", misheard: ["ネクサデータ"])],
            "appliesVocabulary"
        ) else { return }

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
    func appliesVocabularyToSpelledOutAcronyms() async {
        let refiner = await warmedRefiner()

        // 無効化されているが、有効に戻したときに §9 の断続的失敗を持ち込まないよう、
        // 他の実機検査と同じ形（応答なしは縮退として扱う）にしてある。
        guard let result = await refinedOnDevice(
            refiner, "えー、マイクロシーエムエスの記事を更新します",
            terms: [VocabularyTerm(canonical: "microCMS", misheard: ["マイクロシーエムエス"])],
            "appliesVocabularyToSpelledOutAcronyms"
        ) else { return }

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
        // **線は 1 秒（壊れ検知であって要件値ではない）。**
        //
        // 弁別の相手は実モデルの往復である。**当初はウォーム実測の 280〜410 ms を
        // 相手だと見て 250 ms に置こうとしたが、それは推測だった。** ガードを外す変異を
        // 当てて実測すると **1.771 秒と 3.603 秒**（2 回。空白のプロンプトは短い応答に
        // ならない）。**最小の観測 1.771 秒に対しても線は 1.8 倍下**にあり、実測ノイズ
        // （`Task.sleep` の遅れは静かなプロセスで最大 167 ms、飽和時 859 ms）より上にある。
        #expect(
            elapsed < .seconds(1),
            "モデルへ投げている（線は壊れ検知。要件値ではない）: \(elapsed)")
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

        // **応答が無い日は判定しない**（§9 の断続的失敗。`refinedOnDevice` の doc）。
        // ここは 2 回の応答を突き合わせるので、片方でも欠けたら比較が成立しない。
        guard let alone, let after else {
            print("priorUtteranceDoesNotChangeResult: モデルが応答しなかった（判定は行わない）")
            return
        }
        #expect(after == alone, "前の発話が結果を変えている")
        #expect(!after.contains("品川"))
    }

    /// ロケールごとに `instructions` を作り分けている意味。ja-JP の指示のまま英語を
    /// 渡すと、実測で「会議は明日の午前10時に開催されます。」と日本語へ訳された。
    @Test("英語ロケールでは英語のまま整形する")
    func refinesEnglish() async {
        let refiner = await warmedRefiner()

        guard let result = await refinedOnDevice(
            refiner, "uh, like, the meeting is at ten tomorrow morning",
            locale: Locale(identifier: "en-US"), "refinesEnglish"
        ) else { return }

        print("refinesEnglish: \(result)")
        #expect(result.localizedCaseInsensitiveContains("meeting"))
        #expect(!result.contains("会議"), "日本語へ訳している")
        #expect(!result.contains("uh,"))
    }

    /// NFR-P6a の予算配分の根拠。整形そのものの所要をここで測る
    /// （既定の打ち切りは §10 の裁定で 750 ms。要件 NFR-P4 の目標値は 500 ms のまま）。
    ///
    /// 命令文に読める発話は計測に入れない。逸脱した生成は長文を吐いて実測 1.3〜3.4 秒
    /// 掛かるため、混ぜると「整形に要る時間」ではなく「逸脱の発生率」を測ってしまう。
    ///
    /// **閾値判定は中央値に掛ける。最大値には掛けない。** レビュアーが独立に実行した際、
    /// 1 サンプルが 0.586 秒へ跳ねた（`[0.358, 0.368, 0.586, 0.400, 0.381]`）。
    /// 最大値で判定するとこの手の外れ値で落ちる不安定なテストになる。そのうえ落ちても
    /// 対処のしようが無い（500ms を超えた発話は生テキストへ縮退するのが正しい振る舞い）。
    /// 代わりに**分布を毎回出力する**。
    @Test("ウォーム後の整形が壊れ検知の線を割らない（要件は NFR-P4 500ms、検査線は 750ms）")
    func warmLatency() async {
        let refiner = await warmedRefiner()

        var samples: [Duration] = []
        for raw in [
            "えーっと、あの、来週までに要件定義を完了させます",
            "あの、まあ、今日の売上は前年比で百二十パーセントでした",
            "その、資料は明日までに送りますので、確認をお願いします",
            "えーっと、次のミーティングは水曜日の午後三時からでお願いします",
            "えー、エラーハンドリングが抜けているので、そこを直します",
            "あの、明日の打ち合わせは十時から会議室でお願いします",
            "えー、この件は田中さんに引き継ぎましたので、確認をお願いします",
            "その、まあ、先月の実績は目標を少し下回りました",
            "えーっと、契約書の草案を今週中に共有します",
            "あの、テスト環境の準備が終わったので連絡します",
        ] {
            let start = ContinuousClock.now
            _ = await refiner.refine(raw, locale: .jaJP, terms: [], timeout: .seconds(10))
            samples.append(ContinuousClock.now - start)
        }

        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        print("warm refine samples: \(samples)")
        print("warm refine median : \(median)")
        print("warm refine max    : \(sorted.last!)")
        print("warm refine 500ms 超: \(samples.filter { $0 >= .milliseconds(500) }.count)/\(samples.count)")

        // **この境界は要件値ではない。** 要件は `docs/01-requirements.md`（NFR-P4 500 ms）、
        // 実測は各タスクレポートの 2 条件計測が担う。ここが見るのは「明らかに壊れている」水準だけ。
        //
        // 750 ms の根拠: 実測の中央値は機体と負荷により 0.476〜0.505 秒に分布し、
        // **要件値 500 ms の真上に載っている**。500 ms を合否線にすると、
        // 10 標本の中央値を取ってもコイントスになる（実際に 507.6 ms で落ちている）。
        // 標本数を増やしても中央値が 0.49 前後に精確化するだけで解決しない。
        // 要件値の 1.5 倍を壊れ検知の線に取る（V-2 の検査線と同じ規約）。
        #expect(median < .milliseconds(750),
                "整形が桁で悪化している（要件 NFR-P4 は 500 ms。ここは壊れ検知の線）。中央値: \(median)")
    }
}

// MARK: - 出力に「入力に無い語」が足されていないか（実機で観測 / 2026-08-14, 2026-08-15）

/// **長さとコードフェンスだけでは、入力と同じくらいの長さの逸脱を止められない。**
/// 実機で、モデルが質問に答え、その答えが利用者の発話として挿入された。
///
/// **2026-08-15 の実測で、この指標は「入力が丸ごと残ったうえで語が足される」形に
/// 対して原理的に盲目だったことが判った**（V-37。詳細は `RefinementGuard` の doc）。
/// 指標は「入力に由来しない追加字数」へ置き換えてある。
@Suite("整形の受け入れ: 入力に無い語が足されていないか")
struct UnsupportedAdditionsTests {

    // MARK: 実機で観測した「続きの捏造」（2026-08-15 / MacBook Pro M3 / macOS 26.5.2）

    /// **発話が文の途中で終わっていると、モデルは整形ではなく続きを捏造する。**
    ///
    /// PTT は利用者が離した瞬間に確定するので、**言い終える前に離せば必ずこの形になる。**
    /// 実運用の経路であって、計測の都合ではない。
    ///
    /// 逐語で残すのは実測した出力そのものである（`say -v Kyoko` のフィクスチャを
    /// 3 / 6 / 10 秒で切り、実際の認識結果を実 LLM へ通して得た。3 回とも同一）。
    ///
    /// **旧指標はこの 3 例のうち 2 例を受け入れていた**（残存率 1.000。追加が見えない）。
    @Test("文の途中で切れた発話に続きを捏造した出力は受け入れない（実機の再現）")
    func rejectsFabricatedContinuationObservedOnDevice() {
        let cases = [
            // 6 秒スライス。**旧指標は受け入れていた**（+11 字の捏造が利用者の欄へ入る）
            ("本日はお時間をいただきありがとうございます。まず前回のミーティングの振替",
             "本日はお時間をいただきありがとうございます。まず前回のミーティングの振替についてお話しします。"),
            // 手で切った 47 字。**旧指標は受け入れていた**（+8 字）
            ("えー、現状の課題としては、外部のクラウドサービスに音声データを送信することへのセキュリティ上の",
             "現状の課題としては、外部のクラウドサービスに音声データを送信することへのセキュリティ上の懸念があります。"),
            // 10 秒スライス。A4 が観測した当の 56 字。長さの検査が偶然拾っていた
            ("本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。前回は新しい",
             "本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。前回は新しいプロジェクトの進捗を確認し、チームメンバーとのコミュニケーションを強化しました。"),
        ]
        for (raw, fabricated) in cases {
            #expect(
                RefinementGuard.accept(fabricated, refinementOf: raw) == nil,
                "「\(raw)」に対する捏造「\(fabricated)」を受け入れている")
        }
    }

    /// **入力が丸ごと残っていても、語が足されていれば逸脱である。**
    ///
    /// 旧指標（共通部分列 / 短い方の長さ）はこの形に対して常に 1.000 を返した。
    /// **上乗せが長さの上限に収まる大きさなら、長さの検査もすり抜ける。**
    /// この検査は「短い上乗せ」でそこを突く。
    @Test("入力が丸ごと残っていても、上乗せされた文は受け入れない")
    func rejectsAppendedSentenceEvenWhenInputSurvivesIntact() {
        let raw = "本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。前回は、新し"
        let appended = raw + "い体制について話し合いました。"

        #expect(
            RefinementGuard.isPlausible(appended, refinementOf: raw),
            "長さの検査は通ってしまう（だから長さだけでは足りない）")
        #expect(!RefinementGuard.containsCodeFence(appended))
        #expect(
            RefinementGuard.accept(appended, refinementOf: raw) == nil,
            "入力を丸ごと含む上乗せを受け入れている")
    }

    // MARK: 正当な整形（実機の実測をそのまま検査にした）

    /// **発話長を変えて実測した正当な整形。落としてはならない側。**
    ///
    /// V-37 は「指標が長い発話で正当な整形を落としている」という疑いから始まった。
    /// **実測ではそうではなかった**（5〜124 字の 9 例すべてで受け入れられていた）。
    /// 疑いが誤りだったことと、直した後もそれが崩れないことを、同じ検査で押さえる。
    @Test("5〜124 字のどの長さでも、実測した正当な整形を落とさない")
    func acceptsRefinementAcrossUtteranceLengths() {
        let cases = [
            ("えー、はい", "はい。"),
            ("あの、了解です", "了解です。"),
            ("えーっと、明日は十時に集合してください", "明日は十時に集合してください。"),
            ("えーっと、あの、来週までに要件定義を完了させます", "来週までに要件定義を完了させます。"),
            ("その、次のミーティングは水曜日の午後三時からでお願いします",
             "次のミーティングは水曜日の午後三時からお願いします。"),
            ("えー、この件は田中さんに引き継ぎましたので、あの、確認をお願いします",
             "この件は田中さんに引き継ぎましたので、確認をお願いします。"),
            ("えーっと、本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから、あの、始めさせてください",
             "本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。"),
            ("えー、現状の課題としては、外部のクラウドサービスに音声データを送信することへのセキュリティ上の懸念、あの、および従量課金によるコストの増大が挙げられます",
             "現状の課題としては、外部のクラウドサービスに音声データを送信することへのセキュリティ上の懸念、および従量課金によるコストの増大が挙げられます。"),
            ("その、技術的には、アップルが提供する新しい音声認識のフレームワークを利用することで、えーっと、ネットワーク接続なしに、高速かつ高精度な文字起こしが実現できる見込みです。処理速度については、一時間の会議音声を数分程度で処理できることを目標としています",
             "アップルが提供する新しい音声認識のフレームワークを利用することで、ネットワーク接続なしに高速かつ高精度な文字起こしが実現できる見込みです。処理速度については、一時間の会議音声を数分程度で処理できることを目標としています。"),
        ]
        for (raw, refined) in cases {
            #expect(
                RefinementGuard.accept(refined, refinementOf: raw) != nil,
                "\(raw.count) 字の正当な整形を落としている: \(raw) -> \(refined)")
        }
    }

    /// **句読点は何字足してもよい。** 認識結果に読点がほとんど無い発話では、
    /// 整形の仕事の大半が句読点の挿入になる（実測で 1 発話あたり最大 3 字）。
    /// 追加字数を素の絶対量で縛ると、**節の多い長い発話ほど落ちる**——
    /// V-37 が疑った「長さ依存」を、直した側で作り込むことになる。
    @Test("句読点の少ない発話へ句読点を補った出力は受け入れる")
    func acceptsPunctuationInsertion() {
        let cases = [
            ("あの先月の実績は目標を少し下回りましたが今月は挽回できる見込みですので引き続きよろしくお願いします",
             "先月の実績は目標を少し下回りましたが、今月は挽回できる見込みですので、引き続きよろしくお願いします。"),
            ("その資料は明日までに送りますので確認をお願いしますまた不明点があれば連絡してください",
             "その資料は明日までに送りますので確認をお願いします。また不明点があれば連絡してください。"),
            ("えーっと今日の売上は前年比で百二十パーセントでした", "今日の売上は前年比で百二十パーセントでした。"),
        ]
        for (raw, refined) in cases {
            #expect(
                RefinementGuard.accept(refined, refinementOf: raw) != nil,
                "句読点の補完を落としている: \(raw) -> \(refined)")
        }
    }

    /// **数量表記の正規化は「起こさせない」側で解いた。** `RefinementPrompt` の規則 5
    /// （数字の表記を変えない）を入れる前は `十時` → `10時` が実測で必ず起きており、
    /// **その追加 1〜3 字ぶんだけ許容量を開ける必要があった**（開けた量は逸脱にも開く）。
    ///
    /// 規則 5 を入れた後の実測（2026-08-15 / 各 3 回同一）:
    ///
    /// | 入力 | 規則 5 なし | 規則 5 あり |
    /// |---|---|---|
    /// | `…会議は十時から…` | `…10時から…`（追加 2） | `…十時から…`（**追加 0**） |
    /// | `予算は一万円です` | `予算は1万円です。`（追加 1） | `予算は一万円です。`（**追加 0**） |
    /// | `…前年比で百二十パーセント…` | `…120％…`（**追加 3 = 旧許容量ちょうど**） | `…百二十パーセント…`（**追加 0**） |
    ///
    /// **だからこの検査は向きが逆になっている**——数字を保った出力を受け入れ、
    /// 数字を変えた出力は落ちる。落ちても失うのは整形だけで、生テキストは挿入される。
    @Test("数字の表記を保った整形を受け入れる（正規化した出力は落ちる）")
    func acceptsNumeralsKeptAsSpoken() {
        let raw = "えー明日の会議は十時からですのでよろしくお願いします"

        // 規則 5 のもとで実際にモデルが返す形（実測 3/3）
        #expect(
            RefinementGuard.accept(
                "明日の会議は十時からですのでよろしくお願いします。", refinementOf: raw) != nil)
        // 規則 5 が外れたときに返る形。**受け入れない**（許容量 0 の帰結）
        #expect(
            RefinementGuard.accept(
                "明日の会議は10時からですのでよろしくお願いします。", refinementOf: raw) == nil,
            "数字を変えた出力を受け入れている。規則 5 と許容量 0 は一体で設計されている")

        // 算用数字で認識された発話は、算用数字のまま返るのが正しい
        #expect(RefinementGuard.accept("10時に集合してください。", refinementOf: "えー、10時に集合してください") != nil)
        #expect(RefinementGuard.accept("十時に集合してください。", refinementOf: "えー、10時に集合してください") == nil)
    }

    /// **反証役（`review-6-refute.md` §5）が構成した 4 例を、実際にモデルへ通した結果。**
    ///
    /// 実測（2026-08-15 / MacBook Pro M3 / macOS 26.5.2 / temperature 0 / 各 3 回）:
    ///
    /// | 入力 | 反証役が想定した出力 | **実際にモデルが返したもの** |
    /// |---|---|---|
    /// | `成功` | `失敗。` | **応答なし**（52.1 秒暴走して `exceededContextWindowSize`） |
    /// | `可` | `不可。` | `可`（3/3。反転しない） |
    /// | `参加者は百人です` | `参加者は100人です。` | **応答なし**（`guardrailViolation`） |
    /// | `千円です` | `1,000円です。` | `千円です。`（3/3。正規化しない） |
    ///
    /// **4 例とも、モデルはその出力を返さなかった。** 短い意味反転は 18 の短い発話でも
    /// 一度も観測されていない（`可` `不可` `承認` `却下` `中止` `続行` すべて素通し）。
    ///
    /// **それでも、構成された出力が来たらどう扱うかは決まっていなければならない。**
    /// 許容量 0 の帰結として、4 例のうち**追加のある 3 例は落ちる**。
    /// 残る 1 例（`千円です` → `1,000円です。`）も落ちるが、**これは正当な整形であり
    /// 落ちるのは正しくない**——ただし規則 5 のもとでモデルはこの出力を返さない。
    /// **「正当だが落ちる」から「そもそも起きない」へ移したのが今回の直しである。**
    @Test("反証役の 4 例（構成された出力）をどう扱うか")
    func handlesRefutersConstructedOutputs() {
        // 意味の反転・否定: 落ちる
        #expect(RefinementGuard.accept("失敗。", refinementOf: "成功") == nil)
        #expect(RefinementGuard.accept("不可。", refinementOf: "可") == nil)
        // 数量正規化: 落ちる（規則 5 のもとでは起きない出力）
        #expect(RefinementGuard.accept("参加者は100人です。", refinementOf: "参加者は百人です") == nil)
        #expect(RefinementGuard.accept("1,000円です。", refinementOf: "千円です") == nil)
        // 実際にモデルが返した形は通る
        #expect(RefinementGuard.accept("可", refinementOf: "可") != nil)
        #expect(RefinementGuard.accept("千円です。", refinementOf: "千円です") != nil)
    }

    /// **英語では文頭の大文字化が正当な整形として起きる。**
    /// 大文字小文字を畳まないと、許容量 0 の検査が**英語の整形を丸ごと落とす。**
    ///
    /// 逐語で残すのは実測した出力そのもの（2026-08-15 / en-US / 6 発話）。
    @Test("英語の大文字化は追加として数えない（実機の実測）")
    func capitalizationIsNotCountedAsAddition() {
        let cases = [
            ("so the meeting is at ten in the morning", "The meeting is at ten in the morning."),
            ("you know the build is failing because of the cache", "Build is failing because of the cache."),
            ("um so I think we should ship it tomorrow", "I think we should ship it tomorrow."),
            ("uh yeah that works for me", "uh yeah, that works for me"),
            ("well I guess we need about twenty more minutes", "well, we need about twenty more minutes"),
        ]
        for (raw, refined) in cases {
            #expect(
                RefinementGuard.unsupportedAdditions(refined, of: raw) == 0,
                "大文字化を追加として数えている: \(raw) -> \(refined)")
            #expect(RefinementGuard.accept(refined, refinementOf: raw) != nil)
        }
        // 畳んでいるのは大文字小文字だけ。**語が足されれば英語でも落ちる。**
        #expect(
            RefinementGuard.accept(
                "The meeting is at ten in the morning in room A.",
                refinementOf: "so the meeting is at ten in the morning") == nil)
    }

    /// **句読点だけの出力を落とす。** `unsupportedAdditions` は出力の内容文字を数えるので、
    /// 内容が空なら 0 を返す——許容量 0 でもこれだけは別に塞ぐ必要がある。
    @Test("内容が 1 字も残らない出力は受け入れない")
    func rejectsContentlessOutput() {
        #expect(RefinementGuard.unsupportedAdditions("。。。", of: "こんにちは") == 0,
                "追加字数の検査は素通りする（だからこの門が別に要る）")
        #expect(RefinementGuard.accept("。。。", refinementOf: "こんにちは") == nil)
        #expect(RefinementGuard.accept("...", refinementOf: "hello there") == nil)
    }

    /// **この検査が原理的に捕まえられない形を、捕まえられないまま固定する。**
    ///
    /// 見ているのは**足された文字**だけなので、**入力の文字しか使わない逸脱は通る。**
    /// 閾値をどう動かしても分けられない（文字の編集距離は意味を見ていない）。
    /// **「守っているつもり」を作らないために、通ることを検査で明示する。**
    ///
    /// 安全網は **FR-7（Undo）と、履歴が `rawText` を保持していること**である。
    /// 正本: 要件定義書 §2.8 / 詳細設計書 §5.5.1。
    @Test("削ることで意味が変わる逸脱は通る（原理的な限界。安全網は Undo と rawText）")
    func documentsUncatchableDeletionDeviations() {
        // 否定の脱落。出力は入力の部分列なので追加 0
        #expect(RefinementGuard.unsupportedAdditions("行きたいです", of: "行きたくないです") == 0)
        #expect(
            RefinementGuard.accept("行きたいです", refinementOf: "えー、行きたくないです") != nil,
            "捕まえられるようになったなら、正本 §2.8 の限界の記述を更新すること")
        // 削るだけの要約は通る（言った語しか使っていない）
        #expect(
            RefinementGuard.accept(
                "エラーハンドリングを追加したいです。",
                refinementOf: "えー、エラーハンドリングが抜けてるので、そこを追加したいです") != nil)

        // **ただし「削るだけ」でない要約は落ちる。** 実測された L-5 の例
        // （`…追加したいです` → `…追加します。`）は語尾を書き換えているので追加 1 字になり、
        // **この検査が落とす。** 正本 §2.8 L-5 の「規則 4 は効かない」は
        // プロンプトについての記述であって、`RefinementGuard` が全部素通しする意味ではない。
        #expect(
            RefinementGuard.accept(
                "エラーハンドリングを追加します。",
                refinementOf: "えー、エラーハンドリングが抜けてるので、そこを追加したいです") == nil)
    }

    /// **指標そのものを固定する。** 閾値だけを見ていると、指標の誤りに気づけない
    /// ——V-37（残存率）と V-38（間隙 3）で実際にそれが起きた。
    ///
    /// **「間隙の真ん中に線を引く」のは 2 回とも破れた。だからここは間隙を見ない。**
    /// 押さえるのは **「正当な整形の追加字数は 0 である」** ——線ではなく、
    /// 「整形は足す操作ではない」という定義そのもの。
    ///
    /// 実測（2026-08-15 / 規則 5 のもとで応答が返った 48 発話）:
    ///
    /// | 種別 | 追加字数（句読点・空白・大文字小文字を除く） |
    /// |---|---|
    /// | 正当な整形 48 例（1〜76 字・日英・数量表記を含む） | **すべて 0** |
    /// | 逸脱 9 例 | **6**〜166 |
    ///
    /// 破れていた旧標本（`十時` → `10時` = 2、`百二十パーセント` → `120％` = 3）は、
    /// **プロンプト側で起こさせないようにして消してある**（`acceptsNumeralsKeptAsSpoken`）。
    @Test("正当な整形の追加字数は 0 である（逸脱の最小は 6）")
    func legitimateRefinementAddsNothing() {
        let legitimate = [
            ("えー、こんにちは", "こんにちは。"),
            ("えー、はい", "はい。"),
            ("あの先月の実績は目標を少し下回りましたが今月は挽回できる見込みですので引き続きよろしくお願いします",
             "先月の実績は目標を少し下回りましたが、今月は挽回できる見込みですので、引き続きよろしくお願いします。"),
            // 規則 5 のもとで実際に返る形（旧標本の `10時` はもう返らない）
            ("えー明日の会議は十時からですのでよろしくお願いします",
             "明日の会議は十時からですのでよろしくお願いします。"),
            ("今日の売上は前年比で百二十パーセントでした", "今日の売上は前年比で百二十パーセントでした。"),
            ("えー、部数は千二百部です", "部数は千二百部です。"),
            ("会議は明日、あ、明後日です", "会議は明日、明後日です。"),
            ("えーっと、この関数の戻り値がオプショナルなので、あの、アンラップが必要です",
             "関数の戻り値がオプショナルなので、アンラップが必要です。"),
        ]
        // **実測した逸脱の追加字数。** 最小は 6 で、そのうち 2 例は「短い発話への言い足し」
        // という、旧標本には無かった形である（`よろしく` → `よろしくお願いします。`）。
        let deviation = [
            ("東京の天気どんな感じですか？", "東京の天気は晴れています。", 6),
            ("よろしく", "よろしくお願いします。", 6),
            ("あの、スラックの方に資料を上げておきました", "資料をスラックの方にアップしました。", 7),
            ("えー、現状の課題としては、外部のクラウドサービスに音声データを送信することへのセキュリティ上の",
             "現状の課題としては、外部のクラウドサービスに音声データを送信することへのセキュリティ上の懸念があります。", 7),
            ("本日はお時間をいただきありがとうございます。まず前回のミーティングの振替",
             "本日はお時間をいただきありがとうございます。まず前回のミーティングの振替についてお話しします。", 10),
        ]

        for (raw, refined) in legitimate {
            let added = RefinementGuard.unsupportedAdditions(refined, of: raw)
            #expect(added == 0, "正当な整形が字を足している: \(raw) -> \(refined) = \(added)")
            #expect(added <= RefinementGuard.maximumUnsupportedAdditions)
        }
        for (raw, output, expected) in deviation {
            let added = RefinementGuard.unsupportedAdditions(output, of: raw)
            #expect(added == expected, "逸脱の追加字数が実測と違う: \(raw) -> \(output) = \(added)")
            #expect(added > RefinementGuard.maximumUnsupportedAdditions)
        }
    }

    /// **許容量は句読点の数で動かない。** 節の多い長文でも短文でも同じ量で足りることを、
    /// 指標の側から固定する（`acceptsPunctuationInsertion` は結果を見るが、
    /// ここは「句読点が勘定に入っていない」ことそのものを見る）。
    @Test("句読点をいくつ足しても追加字数は増えない")
    func punctuationIsNotCountedAsAddition() {
        let raw = "明日は十時に集合してください"
        #expect(RefinementGuard.unsupportedAdditions("明日は、十時に、集合して、ください。", of: raw) == 0)
        #expect(RefinementGuard.unsupportedAdditions(" 明日は 十時に 集合して ください ", of: raw) == 0)
    }
}

/// 旧スイート名の検査群（逸脱 2 例の回帰と、頼んだ置換の扱い）。
@Suite("整形の受け入れ: 頼んでいない置換を止める")
struct RetainedRatioTests {

    /// **実機で実際に挿入されてしまった 2 例。** 退行を止めるために逐語で残す。
    @Test("質問に答えた出力は受け入れない（実機の再現）")
    func rejectsAnswersObservedOnDevice() {
        let cases = [
            ("東京の天気どんな感じですか？", "東京の天気は晴れています。"),
            ("明日の天気って何でしょうか？", "明日の天気は晴れそうです。"),
        ]
        for (raw, answer) in cases {
            // 既存の 2 つの検査は素通りする。**それがこの検査が要る理由である。**
            #expect(
                RefinementGuard.isPlausible(answer, refinementOf: raw),
                "長さの検査は通ってしまう（だから長さだけでは足りない）")
            #expect(!RefinementGuard.containsCodeFence(answer))
            #expect(
                RefinementGuard.accept(answer, refinementOf: raw) == nil,
                "「\(raw)」に対する回答「\(answer)」を受け入れている")
        }
    }

    /// フィラー削除は**入力が縮む**。出力側で割ると落ちるので、短い方で割っている。
    @Test("フィラーを削っただけの出力は受け入れる")
    func acceptsFillerRemoval() {
        #expect(RefinementGuard.accept("こんにちは。", refinementOf: "えー、こんにちは") != nil)
        #expect(RefinementGuard.accept("会議は明日です。", refinementOf: "あのー、会議は、えっと明日です") != nil)
    }

    /// **用語の正規化は、置換を当てずに測ると逸脱より悪く見える**（実測: 追加 16 字。
    /// 逸脱の最小は 6 字）。頼んだ置換を先に当てて初めて追加 0 字になる。
    /// **辞書を渡さなければ落ちる**ことも併せて固定する
    /// ——そこが崩れると FR-6 が黙って効かなくなる。
    @Test("用語を正規表記へ置き換えた出力は、辞書を渡せば受け入れる")
    func acceptsVocabularySubstitutionWhenTermsAreGiven() {
        let terms = [VocabularyTerm(canonical: "Google Apps Script", misheard: ["ジーエイエス"])]
        let output = "Google Apps Script を使いました。"
        let raw = "ジーエイエスを使いました"

        #expect(
            RefinementGuard.accept(output, refinementOf: raw, terms: terms) != nil,
            "FR-6 の置換を落としている")
        #expect(
            RefinementGuard.accept(output, refinementOf: raw) == nil,
            "辞書無しでも通るなら、追加字数の検査が効いていない")
    }

    /// 辞書を渡しても、頼んでいない置換は通らない。
    @Test("辞書に無い置換は、辞書を渡しても受け入れない")
    func rejectsUnrequestedSubstitutionEvenWithTerms() {
        let terms = [VocabularyTerm(canonical: "Google Apps Script", misheard: ["ジーエイエス"])]
        #expect(
            RefinementGuard.accept(
                "東京の天気は晴れています。", refinementOf: "東京の天気どんな感じですか？",
                terms: terms) == nil)
    }

    @Test("句読点を補っただけの出力は受け入れる")
    func acceptsPunctuationOnly() {
        #expect(RefinementGuard.accept("はい。", refinementOf: "はい") != nil)
        #expect(RefinementGuard.accept("こんにちは。", refinementOf: "こんにちは") != nil)
    }

    /// 完全に別の文は当然落とす。
    @Test("入力と無関係な出力は受け入れない")
    func rejectsUnrelatedOutput() {
        #expect(RefinementGuard.accept("承知しました。", refinementOf: "おはようございます") == nil)
    }
}

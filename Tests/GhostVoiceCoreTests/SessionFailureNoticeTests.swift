import Foundation
import Testing
@testable import GhostVoiceCore

@Suite("SessionFailureNotice")
struct SessionFailureNoticeTests {

    /// **`SessionFailure` の全ケース**（付随値のある 2 つは両方の値）。
    /// 取りこぼすと、その失敗だけ HUD が無言になる。
    ///
    /// - Important: **ここは手で並べた表なので、列挙にケースを足しても勝手には増えない。**
    ///   実際 `.insertionFailed` はこの表から漏れており、`Tests/` のどこにも
    ///   現れないまま「6 ケースすべて」と書かれていた（再レビュー A-1 / B-1）。
    ///   `coversEveryCase()` の `switch` が**コンパイラに網羅を守らせる。**
    private static let allFailures: [SessionFailure] = [
        .audioUnavailable,
        .transcriptionUnavailable,
        .noSpeechRecognized,
        .refusedSecureInput,
        .historyUnavailable(insertedElsewhere: true),
        .historyUnavailable(insertedElsewhere: false),
        .insertionFailed(retainedInHistory: true),
        .insertionFailed(retainedInHistory: false),
    ]

    /// **列挙にケースを足したら、ここがコンパイルエラーになる。**
    ///
    /// 表を手で保守する限り、足したケースが検査から漏れるのは時間の問題である
    /// （`.insertionFailed` が実際にそうなった）。`switch` を網羅で書き、
    /// **表がその `switch` の全ラベルを覆っていること**を検査する。
    private static func label(of failure: SessionFailure) -> String {
        switch failure {
        case .audioUnavailable: "audioUnavailable"
        case .transcriptionUnavailable: "transcriptionUnavailable"
        case .noSpeechRecognized: "noSpeechRecognized"
        case .refusedSecureInput: "refusedSecureInput"
        case .historyUnavailable: "historyUnavailable"
        case .insertionFailed: "insertionFailed"
        }
    }

    /// 表に載っていないケースがあれば落ちる。
    @Test("表が SessionFailure の全ケースを覆っている")
    func coversEveryCase() {
        let covered = Set(Self.allFailures.map { Self.label(of: $0) })
        #expect(
            covered == [
                "audioUnavailable", "transcriptionUnavailable", "noSpeechRecognized",
                "refusedSecureInput", "historyUnavailable", "insertionFailed",
            ],
            "SessionFailure にケースを足して allFailures を更新していない")
        // 付随値のあるケースは**両方の値**を並べる（片方だけだと嘘の文言を見逃す）。
        #expect(Self.allFailures.count == 8)
    }

    @Test("すべての失敗に空でない要約がある")
    func everyFailureHasASummary() {
        for failure in Self.allFailures {
            #expect(!SessionFailureNotice(failure).summary.isEmpty, "\(failure) の要約が空")
        }
    }

    /// **HUD の帯は 1 行しか出せない**（notch 幅の実測 221 pt）。
    /// 要約に改行が混ざると、そのまま出した媒体で崩れる。
    @Test("要約は 1 行に収まる")
    func summaryIsASingleLine() {
        for failure in Self.allFailures {
            #expect(
                !SessionFailureNotice(failure).summary.contains("\n"),
                "\(failure) の要約が複数行になっている")
        }
    }

    /// **これが欠落 12 の要。** フェーズ 1 の文言には `ghost-voice --request-permissions`
    /// のような CLI 固有の案内が本文へ埋め込まれていて、そのままでは HUD に出せなかった。
    /// **媒体ごとに違う部分は文字列ではなく `SessionRemedy` として持つ。**
    @Test("Core の文言に媒体固有の案内が混ざらない")
    func textIsFreeOfMediumSpecificGuidance() {
        let forbidden = ["ghost-voice", "--request-permissions", "ターミナル", "settings.json"]
        for failure in Self.allFailures {
            let notice = SessionFailureNotice(failure)
            for word in forbidden {
                #expect(!notice.summary.contains(word), "\(failure) の要約に「\(word)」がある")
                #expect(!notice.detail.contains(word), "\(failure) の説明に「\(word)」がある")
            }
        }
    }

    @Test("マイクの失敗はマイクのペインと、アプリからの権限要求を示す")
    func audioFailurePointsAtTheMicrophonePane() {
        let notice = SessionFailureNotice(.audioUnavailable)
        #expect(notice.remedies.contains(.grantAccess(pane: .microphone)))
        #expect(notice.remedies.contains(.requestAuthorizationFromApp))
        #expect(SystemSettingsPane.microphone.localizedPath.contains("マイク"))
    }

    @Test("認識の失敗は言語と地域のペインを示す")
    func transcriptionFailurePointsAtTheLanguagePane() {
        let notice = SessionFailureNotice(.transcriptionUnavailable)
        #expect(notice.remedies == [.installLanguageModel(pane: .languageAndRegion)])
        #expect(SystemSettingsPane.languageAndRegion.localizedPath.contains("言語"))
        // マイクの案内と取り違えていないこと。
        #expect(!notice.summary.contains("マイク"))
    }

    /// secure input は**失敗ではなく意図した拒否**である（基本設計書 §7 の唯一の例外）。
    /// 「もう一度試してください」と書くと、パスワード欄へ挿入させようとする案内になる。
    @Test("secure input は拒否として表し、やり直しを勧めない")
    func secureInputIsARefusal() {
        let notice = SessionFailureNotice(.refusedSecureInput)
        #expect(notice.isRefusal)
        #expect(notice.remedies.isEmpty)
        #expect(!notice.speechWasLost, "拒否は「発話を失った」ではない（唯一の意図的な例外）")
        #expect(!(notice.summary + notice.detail).contains("もう一度"))
        #expect((notice.summary + notice.detail).contains("secure input"))
    }

    /// **拒否以外は拒否と呼ばない。** HUD の強調度がこれで変わる。
    @Test("拒否なのは secure input だけ")
    func onlySecureInputIsARefusal() {
        for failure in Self.allFailures where failure != .refusedSecureInput {
            #expect(!SessionFailureNotice(failure).isRefusal, "\(failure) を拒否として扱っている")
        }
    }

    /// **中断された発話にとって、履歴は唯一の写しである。**
    /// 挿入済みかどうかで利用者にとっての意味がまったく違う。
    @Test("履歴の失敗は発話を失ったかを言い分ける")
    func historyFailureDistinguishesLoss() {
        let lost = SessionFailureNotice(.historyUnavailable(insertedElsewhere: false))
        let kept = SessionFailureNotice(.historyUnavailable(insertedElsewhere: true))

        #expect(lost.speechWasLost)
        #expect(!kept.speechWasLost)
        #expect(lost.summary != kept.summary)
        #expect(kept.summary.contains("挿入は完了しています"))
        #expect(!(kept.summary + kept.detail).contains("失われました"), "挿入済みなのに発話が消えたと読める")
        // どちらも「どこを直せばよいか」を言う。
        #expect(lost.remedies.contains { if case .checkStorage = $0 { true } else { false } })
        #expect(kept.remedies.contains { if case .checkStorage = $0 { true } else { false } })
    }

    /// 発話を失ったと言ってよいのは**写しが 1 つも無い 2 つ**だけ。
    /// ほかを同列に扱うと、HUD が毎回「発話が失われました」と出して本当の回が埋もれる。
    ///
    /// **逆側（言わなすぎ）も同じだけ重い。** `.insertionFailed` は
    /// 履歴が残ったかを問わず `speechWasLost = false` を返しており、
    /// **どこにも無い発話を「失われていない」と告げていた**（再レビュー B-1）。
    @Test("発話を失ったと言うのは、写しが 1 つも無い 2 つだけ")
    func onlyFailuresWithoutAnyCopyLoseSpeech() {
        let losing: Set<String> = [
            "\(SessionFailure.historyUnavailable(insertedElsewhere: false))",
            "\(SessionFailure.insertionFailed(retainedInHistory: false))",
        ]
        for failure in Self.allFailures {
            let shouldLose = losing.contains("\(failure)")
            #expect(
                SessionFailureNotice(failure).speechWasLost == shouldLose,
                "\(failure) の「発話を失ったか」が事実と食い違っている")
        }
    }

    /// **写しがどこにも無い縮退は、履歴画面へ案内してはならない。** 案内先が空である。
    @Test("写しの無い縮退は履歴画面へ案内しない")
    func doesNotPointAtAnEmptyHistory() {
        let lost = SessionFailureNotice(.insertionFailed(retainedInHistory: false))
        #expect(!(lost.summary + lost.detail).contains("履歴にだけ残っています"))
        #expect((lost.summary + lost.detail).contains("失われました"))

        let kept = SessionFailureNotice(.insertionFailed(retainedInHistory: true))
        #expect(kept.detail.contains("履歴"), "唯一の写しの在り処を案内していない")
        #expect(!(kept.summary + kept.detail).contains("失われました"))
        #expect(lost.summary != kept.summary)
    }

    /// 8 つが同じ文面になっていないこと（どの失敗か判らなくなる）。
    @Test("失敗ごとに別の文面になる")
    func noticesAreDistinct() {
        let texts = Self.allFailures.map { SessionFailureNotice($0).summary + $0.debugText }
        #expect(Set(Self.allFailures.map { SessionFailureNotice($0).summary }).count == 8)
        #expect(Set(texts).count == 8)
    }

    @Test("保存先の案内はストレージの場所を持つ")
    func storageRemedyCarriesThePath() {
        let notice = SessionFailureNotice(.historyUnavailable(insertedElsewhere: true))
        let path = notice.remedies.compactMap { remedy -> String? in
            if case .checkStorage(let path) = remedy { return path }
            return nil
        }.first
        #expect(path?.contains("GhostVoice") == true)
    }
}

extension SessionFailure {
    /// テストの識別用。**製品の表示には使わない。**
    fileprivate var debugText: String { "\(self)" }
}

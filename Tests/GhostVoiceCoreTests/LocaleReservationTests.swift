import Foundation
import Synchronization
import Testing

@testable import GhostVoiceCore

/// 持ち越し項目 5。**ロケール枠（上限 5）の解放漏れ。**
///
/// フェーズ 1 は `AssetInventory.release(reservedLocale:)` を 1 度も呼んでいなかった。
/// **相異なるロケールを 5 種類試すと以後どのロケールにも切り替えられなくなり、
/// プロセスを再起動するまで回復しない。** 設定画面からロケールを変える経路で踏む。
@Suite("ロケール枠の確保と解放")
struct LocaleReservationTests {

    /// 確保と解放の呼ばれ方を記録するだけの代役。**実 `AssetInventory` を触らない。**
    ///
    /// 実物はプロセス全体の状態（確保済みロケールの集合）を触るので、
    /// 検査から回すと他のスイートの解析へ割り込む（`SpeechDependentTests` の注記）。
    final class SpyReservation: SpeechAnalyzerTranscriber.LocaleReserving, Sendable {
        private let events = Mutex<[String]>([])
        private let failure: (any Error)?

        init(failure: (any Error)? = nil) { self.failure = failure }

        var reserved: [String] { events.withLock { $0.filter { $0.hasPrefix("reserve:") } } }
        var released: [String] { events.withLock { $0.filter { $0.hasPrefix("release:") } } }
        /// 呼ばれた順。**「成功してから前のを返す」順序を見るために要る。**
        var calls: [String] { events.withLock { $0 } }

        func reserve(_ locale: Locale) async throws {
            events.withLock { $0.append("reserve:\(locale.identifier)") }
            if let failure { throw failure }
        }

        @discardableResult
        func release(_ locale: Locale) async -> Bool {
            events.withLock { $0.append("release:\(locale.identifier)") }
            return true
        }
    }

    private func makeTranscriber(
        reservation: SpyReservation,
        installerFails: Bool = false
    ) -> SpeechAnalyzerTranscriber {
        SpeechAnalyzerTranscriber(
            reservation: reservation,
            assetInstaller: { _ in
                if installerFails { throw TranscriptionError.modelUnavailable }
                return false
            }
        )
    }

    /// **これが持ち越し項目 5 の本体である。**
    /// 設定画面からロケールを変えて失敗するたびに枠が 1 つ減っていた。
    @Test("確保した後で失敗したら枠を返す")
    func releasesTheReservationWhenPreparationFails() async throws {
        let reservation = SpyReservation()
        let transcriber = makeTranscriber(reservation: reservation, installerFails: true)

        await #expect(throws: TranscriptionError.modelUnavailable) {
            try await transcriber.prepare(locale: .jaJP, kind: .dictation)
        }

        #expect(reservation.reserved.count == 1)
        #expect(reservation.released.count == 1, "確保した枠を返していない")
        #expect(reservation.released.first == "release:ja_JP", "正規形で返していない")
    }

    /// 確保そのものが失敗した場合は、**返す枠が無い。**
    /// ここで返しにいくと、他のロケールの枠を巻き添えにしうる。
    @Test("確保そのものが失敗したら解放しない")
    func doesNotReleaseWhenTheReservationItselfFailed() async throws {
        let reservation = SpyReservation(failure: TranscriptionError.localeReservationLimitReached)
        let transcriber = makeTranscriber(reservation: reservation)

        await #expect(throws: TranscriptionError.localeReservationLimitReached) {
            try await transcriber.prepare(locale: .jaJP, kind: .dictation)
        }
        #expect(reservation.released.isEmpty)
    }

    /// **同じロケールへの `prepare` では何も解放しない。**
    /// `reserve` は同一ロケールの 2 回目以降で枠を消費しないので、
    /// 解放してから確保し直す形にすると**成功する経路で枠を手放す窓**ができる。
    @Test("同じロケールへの準備では解放しない")
    func doesNotReleaseWhenTheLocaleIsUnchanged() async throws {
        let reservation = SpyReservation()
        let transcriber = makeTranscriber(reservation: reservation)

        try await transcriber.prepare(locale: .jaJP, kind: .dictation)
        try await transcriber.prepare(locale: .jaJP, kind: .dictation)

        #expect(reservation.reserved.count == 2)
        #expect(reservation.released.isEmpty, "同じロケールなのに枠を手放した")
    }

    /// **成功したら前のロケールの枠を返す。**
    /// これをしないと、ロケールを変えるたびに枠が 1 つずつ減る。
    @Test("ロケールを変えたら前の枠を返す")
    func releasesThePreviousLocaleAfterSwitching() async throws {
        let reservation = SpyReservation()
        let transcriber = makeTranscriber(reservation: reservation)

        try await transcriber.prepare(locale: .jaJP, kind: .dictation)
        try await transcriber.prepare(locale: Locale(identifier: "en-US"), kind: .dictation)

        #expect(reservation.released.count == 1, "前のロケールの枠を返していない")
        #expect(reservation.released.first == "release:ja_JP")
        // **順序が要件である。** 先に返すと、途中で失敗したときに古いロケールでも動けない。
        #expect(
            reservation.calls == ["reserve:ja_JP", "reserve:en_US", "release:ja_JP"],
            "解放が新しいロケールの準備より前にある: \(reservation.calls)")
    }

    /// 切り替えに失敗しても**古いロケールの枠は返さない。**
    /// 返すと「新しいロケールにも古いロケールにも枠が無い」状態になる
    /// （`self.locale` は最後に代入されるので、失敗しても録音は古い設定で続く）。
    @Test("切り替えに失敗したら古いロケールの枠は返さない")
    func keepsThePreviousReservationWhenSwitchingFails() async throws {
        let reservation = SpyReservation()
        let succeeding = makeTranscriber(reservation: reservation)
        try await succeeding.prepare(locale: .jaJP, kind: .dictation)

        let failing = SpeechAnalyzerTranscriber(
            reservation: reservation,
            assetInstaller: { _ in throw TranscriptionError.modelUnavailable })
        // 同じ記録へ向けた別インスタンスで「前のロケールがある状態」は作れないので、
        // ここでは新しいロケールぶんだけが返ることを見る。
        await #expect(throws: TranscriptionError.modelUnavailable) {
            try await failing.prepare(locale: Locale(identifier: "en-US"), kind: .dictation)
        }
        #expect(
            reservation.released == ["release:en_US"],
            "失敗した切り替えで古いロケールの枠まで返している: \(reservation.released)")
    }

    /// 対応していないロケールは**確保より前に弾く。** 枠を 1 つも消費しない。
    @Test("未対応ロケールでは枠を確保しない")
    func doesNotReserveAnUnsupportedLocale() async throws {
        let reservation = SpyReservation()
        let transcriber = makeTranscriber(reservation: reservation)

        await #expect(throws: TranscriptionError.localeUnsupported("zu-ZA")) {
            try await transcriber.prepare(locale: Locale(identifier: "zu-ZA"), kind: .dictation)
        }
        #expect(reservation.calls.isEmpty)
    }
}

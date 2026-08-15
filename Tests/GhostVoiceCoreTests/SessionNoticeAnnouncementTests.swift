import Foundation
import Testing

@testable import GhostVoiceCore

/// **`SessionNotice` の文言と重さは Core が唯一の持ち主である**（統括の裁定）。
///
/// 以前は HUD（`HUDPresenter.announcement`）と Undo の UI（`UndoNarration`）の
/// **2 箇所にあり、CLI には 1 箇所も無かった**——`ghost-voice` から Undo を撃つと
/// 顛末が何も出ない、という**フェーズ 1 で潰した「無言で失敗する」と同じ形**だった。
@Suite("SessionNotice の文言（Core）")
struct SessionNoticeAnnouncementTests {

    /// **4 つの結末が 1 つの文言に潰れていないこと。**
    /// 1 つでも同じなら、利用者は次に何をすべきか判らない（詳細設計書 §14.5）。
    @Test("Undo の 4 つの結末が、それぞれ別の文言になる")
    func fourOutcomesAreDistinct() throws {
        let notices: [SessionNotice] = [
            .undone, .undoCopiedRawTextToClipboard,
            .undoDeclined(.sourceMismatch), .undoUnavailable,
        ]
        let summaries = try notices.map { try #require(SessionNoticeAnnouncement($0)).summary }
        #expect(Set(summaries).count == 4)
    }

    @Test("**クリップボードへ取り出した**ときは、⌘V で貼れることを言う")
    func clipboardFallbackTellsHowToPaste() throws {
        let announcement = try #require(
            SessionNoticeAnnouncement(.undoCopiedRawTextToClipboard))
        #expect(announcement.summary.contains("⌘V"))
        // 「戻せません」に潰すと、クリップボードに在る生テキストへ辿り着けない。
        #expect(!announcement.isFailure)
        // **挿入済みのテキストを変えていない**ことも言う。
        #expect(announcement.detail.contains("1 文字も変えていません"))
        // 読み落とすと取り返しがつかないので、**自動で消さない。**
        #expect(announcement.isPersistent)
        #expect(announcement.weight == .actionRequired)
    }

    /// **これ以外に `isPersistent` は無い。** 増えると「消えない表示」が積み上がる。
    @Test("自動で消さないのはクリップボードへの退避だけである")
    func onlyOneAnnouncementIsPersistent() {
        let persistent = SessionNoticeAnnouncementTests.allNotices
            .compactMap { SessionNoticeAnnouncement($0) }
            .filter(\.isPersistent)
        #expect(persistent.count == 1)
        #expect(persistent.first?.weight == .actionRequired)
    }

    @Test("断念したときは、**何も書き換えていない**ことを必ず言う")
    func declineSaysNothingWasChanged() throws {
        let announcement = try #require(
            SessionNoticeAnnouncement(.undoDeclined(.sourceMismatch)))
        #expect(announcement.summary.contains("何も書き換えていません"))
        #expect(announcement.detail.contains("編集"))
    }

    @Test("戻せるものが無いときは、**理由の候補（窓の秒数と経路）を必ず添える**")
    func unavailableExplainsWhy() throws {
        let announcement = try #require(SessionNoticeAnnouncement(.undoUnavailable))
        // 秒数は `HistoryStore.undoWindow` から来る。**文言に生の数字を書いていない。**
        #expect(announcement.detail.contains("\(Int(HistoryStore.undoWindow)) 秒以内"))
        #expect(announcement.detail.contains("アクセシビリティ経路"))
        #expect(announcement.detail.contains("中断した発話は対象外"))
        // 縮退の出口（履歴からコピー）まで案内する。
        #expect(announcement.detail.contains("履歴画面"))
    }

    @Test("Undo の窓の秒数は `HistoryStore.undoWindow` が唯一の出どころである")
    func undoWindowComesFromTheStore() {
        #expect(SessionNoticeAnnouncement.undoWindowSeconds == Int(HistoryStore.undoWindow))
    }

    /// **`.refinementNotApplied(nil)` を出さない理由は頻度である。**
    /// 実測では 56 字の発話が締め切りの内側で整形を終えていても 10/10 で捨てられている
    /// （V-37）。毎回出すと、本当に重い `.textMayHaveBeenLost` が埋もれる。
    @Test("黙って捨てるのは「整形の結末」の 2 つだけである")
    func silentNoticesAreExactlyTwo() {
        let silent = SessionNoticeAnnouncementTests.allNotices
            .filter { SessionNoticeAnnouncement($0) == nil }
        #expect(silent == [.refinementApplied, .refinementNotApplied(nil)])
    }

    @Test("差し替えを断念した通知には理由の文言が付く")
    func declinedRefinementCarriesItsReason() throws {
        let announcement = try #require(
            SessionNoticeAnnouncement(.refinementNotApplied(.focusChanged)))
        #expect(announcement.detail.contains("別の入力欄"))
    }

    @Test("喪失の疑いがいちばん重い")
    func lostIsTheHeaviest() throws {
        let announcement = try #require(SessionNoticeAnnouncement(.textMayHaveBeenLost))
        #expect(announcement.weight == .lost)
        #expect(announcement.isFailure)
    }

    /// **「クリップボードから貼り直せます」と言い切ってはならない。**
    ///
    /// R-9 の退避（`TextReplacer` の `.lost`）は、**次の発話が Pasteboard 経路で
    /// 挿入している最中だと 300 ms 後の復元で上書きされる**（再レビュー B-3）。
    /// `TextReplacer` は挿入が進行中かを知る手段を持たない（Core の型に印が無い）。
    /// **告知が嘘になる窓が構造として残っている以上、もう 1 つの在り処を必ず言う。**
    /// 整形前のテキストは履歴にある——(a) の分岐は履歴へ書けたときにしか
    /// 差し替えを始めないので（`insertRawThenRevise`）、ここでは必ず残っている。
    @Test("喪失の疑いは、クリップボードだけを在り処として言い切らない")
    func lostPointsAtEveryRemainingCopy() throws {
        let announcement = try #require(SessionNoticeAnnouncement(.textMayHaveBeenLost))
        let text = announcement.summary + announcement.detail
        #expect(text.contains("クリップボード"))
        #expect(
            text.contains("履歴"),
            "クリップボードの退避が上書きされた場合の在り処（履歴）を言っていない")
    }

    @Test("断念の理由をすべて文言にしてある（新しい理由が既存の文言へ吸い込まれない）")
    func everyDeclineReasonHasItsOwnText() {
        let reasons: [ReplacementDecline] = [
            .blockedProcess, .staleEpoch, .ownProcess, .nothingToChange, .emptyReplacement,
            .secureInput, .focusChanged, .processChanged, .rangeNotSettable,
            .sourceMismatch, .sourceUnreadable, .rangeWriteFailed, .textWriteFailed,
            .nothingToUndo,
        ]
        for reason in reasons {
            #expect(
                !SessionNoticeAnnouncement.declineDetail(reason).isEmpty,
                "\(reason.rawValue) の文言が無い")
        }
        // 書き込みの失敗 2 つだけは同じ文言でよい（利用者にできることが同じ）。
        let texts = reasons.map { SessionNoticeAnnouncement.declineDetail($0) }
        #expect(Set(texts).count == reasons.count - 1)
    }

    /// **要約は 1 行である。** HUD の帯（notch の幅は実測 221 pt）にそのまま出す。
    @Test("要約に改行を含まない")
    func summariesAreSingleLine() {
        for notice in SessionNoticeAnnouncementTests.allNotices {
            guard let announcement = SessionNoticeAnnouncement(notice) else { continue }
            #expect(!announcement.summary.contains("\n"), "\(notice) の要約が複数行")
        }
    }

    static let allNotices: [SessionNotice] = [
        .refinementApplied, .refinementNotApplied(nil), .refinementNotApplied(.sourceMismatch),
        .textMayHaveBeenLost, .undone, .undoUnavailable, .undoDeclined(.focusChanged),
        .undoCopiedRawTextToClipboard,
    ]
}

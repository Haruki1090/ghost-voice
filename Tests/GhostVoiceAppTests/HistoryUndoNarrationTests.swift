import Foundation
import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

/// **Undo（FR-7）の UI 側。「Undo できません」をどう伝えるか。**
///
/// 実行は Core にある（`DictationSession.performUndo`）。ここが検査するのは
/// **4 つの結末が 1 つの文言に潰れていないこと**と、
/// **見えない締め切り（10 秒）を黙って使っていないこと**である。
@Suite("Undo の UI（FR-7）")
struct HistoryUndoNarrationTests {

    @Test("4 つの結末が、それぞれ別の文言になる")
    func fourOutcomesAreDistinct() throws {
        let notices: [SessionNotice] = [
            .undone, .undoCopiedRawTextToClipboard,
            .undoDeclined(.sourceMismatch), .undoUnavailable,
        ]
        let headlines = try notices.map { try #require(UndoNarration.message(for: $0)).headline }
        #expect(Set(headlines).count == 4, "1 つでも同じなら、利用者は次に何をすべきか判らない")
    }

    @Test("**クリップボードへ取り出した**ときは、⌘V で貼れることを言う")
    func clipboardFallbackTellsHowToPaste() throws {
        let message = try #require(UndoNarration.message(for: .undoCopiedRawTextToClipboard))
        #expect(message.headline.contains("⌘V"))
        // 「戻せません」に潰すと、クリップボードに在る生テキストへ辿り着けない。
        #expect(!message.isFailure)
        // **挿入済みのテキストを変えていない**ことも言う。
        #expect(message.detail?.contains("1 文字も変えていません") == true)
        // 読み落とすと取り返しがつかないので、自動で消さない。
        #expect(message.presentation == .persistent)
    }

    @Test("断念したときは、**何も書き換えていない**ことを必ず言う")
    func declineSaysNothingWasChanged() throws {
        let message = try #require(UndoNarration.message(for: .undoDeclined(.sourceMismatch)))
        #expect(message.headline.contains("何も書き換えていません"))
        #expect(message.detail?.contains("編集") == true)
    }

    @Test("戻せるものが無いときは、**理由の候補（10 秒窓と経路）を必ず添える**")
    func unavailableExplainsWhy() throws {
        let message = try #require(UndoNarration.message(for: .undoUnavailable))
        let detail = try #require(message.detail)

        // 秒数は `HistoryStore.undoWindow` から来る。**画面に 10 と書いていない。**
        #expect(detail.contains("\(Int(HistoryStore.undoWindow)) 秒以内"))
        #expect(detail.contains("アクセシビリティ経路"))
        #expect(detail.contains("中断した発話は対象外"))
        // 縮退の出口（履歴からコピー）まで案内する。
        #expect(detail.contains("履歴画面"))
    }

    @Test("Undo の窓の秒数は Core が唯一の出どころである")
    func undoWindowComesFromCore() {
        #expect(UndoNarration.undoWindowSeconds == Int(HistoryStore.undoWindow))
    }

    @Test("整形の差し替えの通知はここで文言にしない（HUD トラックの担当）")
    func refinementNoticesAreNotNarratedHere() {
        #expect(UndoNarration.message(for: .refinementApplied) == nil)
        #expect(UndoNarration.message(for: .refinementNotApplied(nil)) == nil)
        #expect(UndoNarration.message(for: .textMayHaveBeenLost) == nil)
    }

    @Test("断念の理由をすべて文言にしてある（新しい理由が既存の文言へ吸い込まれない）")
    func everyDeclineReasonHasItsOwnText() {
        // `ReplacementDecline` は `String` の raw value を持つので全ケースを並べられる。
        let reasons: [ReplacementDecline] = [
            .blockedProcess, .staleEpoch, .ownProcess, .nothingToChange, .emptyReplacement,
            .secureInput, .focusChanged, .processChanged, .rangeNotSettable,
            .sourceMismatch, .sourceUnreadable, .rangeWriteFailed, .textWriteFailed,
            .nothingToUndo,
        ]
        for reason in reasons {
            let text = UndoNarration.declineDetail(reason)
            #expect(!text.isEmpty, "\(reason.rawValue) の文言が無い")
        }
        // 書き込みの失敗 2 つだけは同じ文言でよい（利用者にできることが同じ）。
        // それ以外に重複が無いことを見る。
        let texts = reasons.map { UndoNarration.declineDetail($0) }
        #expect(Set(texts).count == reasons.count - 1)
    }

    // MARK: - 履歴側の縮退（FR-7 の細目 3 行目）

    @Test("自動 Undo の対象は AX 経路の整形済み発話だけである（Core の述語をそのまま使う）")
    func automaticUndoCandidateIsAXOnly() {
        #expect(makeHistoryEntry(method: .ax).isAutomaticUndoCandidate)
        #expect(!makeHistoryEntry(method: .pasteboard).isAutomaticUndoCandidate)
        #expect(!makeHistoryEntry(method: .clipboardOnly).isAutomaticUndoCandidate)
        #expect(!makeHistoryEntry(method: .notInserted).isAutomaticUndoCandidate)
        #expect(!makeHistoryEntry(refinedText: nil, method: .ax).isAutomaticUndoCandidate)
    }

    @Test("自動で戻せない経路（Pasteboard / クリップボードのみ）は、手で取り出す側に回る")
    func manualFallbackIsTheComplement() {
        #expect(makeHistoryEntry(method: .pasteboard).isManualUndoFallbackCandidate)
        #expect(makeHistoryEntry(method: .clipboardOnly).isManualUndoFallbackCandidate)
        #expect(!makeHistoryEntry(method: .ax).isManualUndoFallbackCandidate)
        #expect(!makeHistoryEntry(method: .notInserted).isManualUndoFallbackCandidate)
    }
}

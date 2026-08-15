import Foundation
import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

/// **Undo（FR-7）の履歴側の縮退。**
///
/// 文言（4 つの結末を潰さない・見えない締め切りを黙って使わない）は
/// **Core へ移した**（`SessionNoticeAnnouncement`。統括の裁定「Core へ寄せる」）。
/// 検査も `Tests/GhostVoiceCoreTests/SessionNoticeAnnouncementTests.swift` にある。
/// ここに残すのは、**どの履歴が自動で戻せる側／手で取り出す側か**という
/// 履歴の述語だけである。
@Suite("Undo の履歴側の縮退（FR-7）")
struct HistoryUndoNarrationTests {

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

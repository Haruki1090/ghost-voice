import Foundation
import Testing

@testable import GhostVoiceCore

/// **本番が呼ぶ組み立て式そのものを検査する。**
///
/// ソースの走査（`InsertionWiringContractTests`）は「その式を書いているか」しか見ない。
/// ここは**その式から出来上がったものが、実際に差し替えられる形か**を見る。
/// 2 つが揃って初めて「製品では差し替えが動く」と言える。
@Suite("本番の挿入スタック")
struct ProductionInsertionStackTests {

    private func makeSession(insertion: InsertionStack, root: URL) -> DictationSession {
        DictationSession(
            settings: SettingsStore(rootURL: root),
            hotkey: StubHotkeyMonitor(),
            audio: StubAudioCapture(),
            transcriber: StubTranscriber(),
            refiner: SpyRefiner(result: nil),
            insertion: insertion,
            history: HistoryStore(rootURL: root, limit: 50),
            vocabulary: VocabularyStore(rootURL: root),
            isSecureInputEnabled: { false },
            postEventAuthorization: PostEventAuthorization(probe: { false })
        )
    }

    /// **本番の 2 箇所とまったく同じ式である。**
    ///
    /// この式が返す組から作ったセッションが「差し替えられない」と答えるなら、
    /// 製品では FR-5(a) も FR-7 も一度も動かない。
    @Test("systemStack() から組んだセッションは差し替えできる")
    func theProductionStackYieldsARevisableSession() throws {
        try withTempRoot { root in
            let session = makeSession(insertion: CompositeInserter.systemStack(), root: root)
            #expect(
                session.canReviseInPlace,
                "本番の組み立てなのに (b)（整形を待ってから挿入）へ縮退している")
        }
    }

    /// 対照。**差し替え器を持たない組では偽になる**（この性質が意味を持つことの確認）。
    @Test("差し替え器を渡さない組み立ては差し替えできないと答える")
    func aStacklessSessionSaysItCannotRevise() throws {
        try withTempRoot { root in
            let session = DictationSession.forTests(
                settings: SettingsStore(rootURL: root),
                hotkey: StubHotkeyMonitor(),
                audio: StubAudioCapture(),
                transcriber: StubTranscriber(),
                refiner: SpyRefiner(result: nil),
                inserter: RecordingInserter(),
                history: HistoryStore(rootURL: root, limit: 50),
                vocabulary: VocabularyStore(rootURL: root),
                isSecureInputEnabled: { false },
                postEventAuthorization: PostEventAuthorization(probe: { false })
            )
            #expect(!session.canReviseInPlace)
        }
    }

    /// `systemStack()` は**同じ世代と同じクリップボード**で組む
    /// （別々に作ると差し替えが常に失効し、退避先が誰にも見えない場所になる）。
    @Test("systemStack は挿入器と差し替え器へ同じ世代を渡す")
    func theStackSharesItsEpoch() {
        let stack = CompositeInserter.systemStack()
        let before = stack.inserter.epoch.current
        stack.inserter.epoch.advance()
        // 差し替え器が別の世代を握っていたら、この錨は失効しないままになる。
        #expect(stack.inserter.epoch.current == before + 1)
        #expect(stack.replacer.currentEpoch == stack.inserter.epoch.current,
                "差し替え器が挿入器と別の世代を握っている（差し替えが常に失効する）")
    }
}

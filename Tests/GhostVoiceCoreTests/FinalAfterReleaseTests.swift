import AVFAudio
import Foundation
import Synchronization
import Testing

@testable import GhostVoiceCore

/// 認識器を包んで、確定（`.final`）がいつ何件届いたかを見る。
///
/// **V-12 は「解放後の確定が 1 回とは限らない」という疑いである。**
/// **旧実装**は「キー解放以降の最初の `.final`」で先へ進んだので、2 回目が読み取りの後に
/// 届くと、その分の文字がどこにも現れなかった（実機の肉声で再現。要件定義書 §2.8.4）。
/// **現行は結果ストリームの終端まで待つ**ので、この経路では落ちない。
/// 状態機械の外からは、**挿入された文字列と認識器が出した確定の総和を比べる**しかない。
///
/// - Important: **この検査は欠陥を 1 度も捕まえていない。** 103 秒の合成音声でも
///   「解放後に 2 件目」という条件そのものが起きなかったためで、**回帰を止めているのは
///   代役による `DictationSessionTests.doesNotDropSecondFinalAfterRelease` である。**
///   ここは「実音声でも取りこぼさない」ことを実物で確かめる側の検査である。
final class FinalWatchingTranscriber: Transcribing, @unchecked Sendable {

    struct Observation: Sendable {
        var finals: [String] = []
        /// `finish()` に入った後に届いた確定の数。**ここが 2 以上なら V-12 の疑いが濃い。**
        var finalsAfterRelease = 0
        var didEnterFinish = false
    }

    private let inner: any Transcribing
    private let state = Mutex<Observation>(Observation())
    private var pump: Task<Void, Never>?

    init(_ inner: any Transcribing) { self.inner = inner }

    var observation: Observation { state.withLock { $0 } }

    /// 認識器が結果ストリームを終端しきるまで待つ。
    /// **これを待たずに数えると「まだ来ていないだけ」を「来なかった」と読む。**
    func waitForStreamEnd() async { await pump?.value }

    func prepare(locale: Locale, kind: TranscriberKind) async throws {
        try await inner.prepare(locale: locale, kind: kind)
    }

    var requiredAudioFormat: AVAudioFormat? {
        get async { await inner.requiredAudioFormat }
    }

    func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        let source = try await inner.begin()
        let (stream, continuation) = AsyncThrowingStream<TranscriptionUpdate, Error>.makeStream()
        // `Mutex` は ~Copyable でキャプチャリストに載せられない。self ごと借りる。
        pump = Task { [self] in
            do {
                for try await update in source {
                    if case .final(let text) = update {
                        state.withLock {
                            $0.finals.append(text)
                            if $0.didEnterFinish { $0.finalsAfterRelease += 1 }
                        }
                    }
                    continuation.yield(update)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    func feed(_ buffer: sending AVAudioPCMBuffer) async {
        await inner.feed(buffer)
    }

    func finish() async throws {
        state.withLock { $0.didEnterFinish = true }
        try await inner.finish()
    }
}

extension SpeechDependentTests {

    /// V-12（詳細設計書 §13）。**権限は一切要らない。**
    ///
    /// マイクもキー送出も AX も使わない。フィクスチャ音声を実時間で流し込み、
    /// キー解放に相当する操作を送って、確定の取りこぼしを見る。
    ///
    /// > **実時間で流す必要がある。** まとめて流し込むと、解放の時点で解析器に
    /// > 未処理の音声が積み上がり、解放後に確定がまとめて届く——という、
    /// > 実使用では起きない条件を作ってしまう（V-2 と同じ注意）。
    /// > そのぶん、この検査は音声の長さぶんだけ実時間を要する。
    ///
    /// Task 10 が観測した 20 発話は 3 秒の短文で、解放後の確定はいずれも 1 回だった。
    /// ここでは**区切りの多い 30 秒の発話**（会議の読み上げ）で同じことを見る。
    /// > **既定の `swift test` では走らない。`GHOST_VOICE_V12_SECONDS=103` を付けると走る。**
    /// > **値は 103（フィクスチャの全長）にすること。** 30 秒では確定が 1 件しか出ず、
    /// > 取りこぼしの経路を 1 度も通らない（下の実測表）。
    /// >
    /// > 実時間で実認識を回すので**機体を飽和させる。** 既定へ入れて全体を回したところ、
    /// > 時間の閾値を持つ既存の検査が 2 件落ちた（実測 / 2026-08-14）:
    /// > `RefinerTests` の「タイムアウトすると作業の完了を待たずに nil を返す」
    /// > （50 ms の打ち切りに 859 ms 掛かった。閾値 300 ms）と
    /// > 「打ち切りに応じない作業でも時間内に返る」（同 859 ms。閾値 500 ms）。
    /// > **どちらも実装ではなく `Task.sleep` のタイマー配送が遅れたことによる**
    /// > （Task 10 が `GHOST_VOICE_MEASURE` を opt-in にしたのと同じ理由）。
    /// >
    /// > **落ちた 2 件の閾値を緩めて既定へ入れる、という直し方はしない。**
    /// > 既存の検査が守っているものを、新しい検査の都合で弱めることになる。
    @Suite(
        "V-12: 解放後の確定が 1 回とは限らないか",
        .enabled("GHOST_VOICE_V12_SECONDS=103 を付けると実行される（30 では危険な経路を通らない）") {
            ProcessInfo.processInfo.environment["GHOST_VOICE_V12_SECONDS"] != nil
        },
        .enabled("音声フィクスチャが要る") { SpeechFixtures.audioExists }
    )
    struct FinalAfterRelease {

        /// 流す長さ。**そのまま実時間になる**ので、既定は日常の回帰検査に耐える 30 秒。
        ///
        /// **`GHOST_VOICE_V12_SECONDS` がそのまま秒数になる。** フィクスチャの全長は 103 秒で、
        /// そこまで伸ばすと解析器が録音中にも確定を出す（下の実測）。既定の 30 秒では
        /// 確定が 1 件しか出ないので、**取りこぼしの経路そのものは通らない。**
        ///
        /// 実測（2026-08-14 / M3 / macOS 26.5.2 / `DictationTranscriber` / ja-JP）:
        ///
        /// | 音声長 | 確定の総数 | うち解放後 | 挿入 | 確定の総和 |
        /// |---|---|---|---|---|
        /// | 30 秒 | 1 件 | 1 件 | 167 字 | 167 字 |
        /// | **103 秒**（`GHOST_VOICE_V12_SECONDS=103`） | **2 件** | **1 件** | 548 字 | 548 字 |
        ///
        /// 103 秒では**録音中に 1 件、解放後に 1 件**届いた。前者は `latestFinal` へ
        /// 積まれ、後者で確定待ちが解ける。**どちらの条件でも取りこぼしは無い。**
        static var utteranceSeconds: Double {
            ProcessInfo.processInfo.environment["GHOST_VOICE_V12_SECONDS"]
                .flatMap(Double.init) ?? 30.0
        }

        @Test("区切りの多い長い発話でも、解放後に届く確定を取りこぼさない")
        func doesNotDropFinalsArrivingAfterRelease() async throws {
            let inner = SpeechAnalyzerTranscriber()
            try await inner.prepare(locale: .jaJP, kind: .dictation)
            let format = try #require(await inner.requiredAudioFormat)
            let buffers = try SpeechFixtures.buffers(
                from: SpeechFixtures.audioURL, to: format,
                limitSeconds: Self.utteranceSeconds)
            let transcriber = FinalWatchingTranscriber(inner)

            try await withTempRoot { root in
                let audio = ReplayAudioCapture(buffers: buffers, interval: .milliseconds(100))
                let hotkey = StubHotkeyMonitor()
                let inserter = RecordingInserter()
                let session = DictationSession.forTests(
                    settings: SettingsStore(rootURL: root),
                    hotkey: hotkey,
                    audio: audio,
                    transcriber: transcriber,
                    // **整形は通さない。** V-12 は認識側の取りこぼしの話であり、
                    // LLM を挟むと挿入文字列と確定の総和を突き合わせられなくなる。
                    refiner: SpyRefiner(result: nil),
                    inserter: inserter,
                    history: HistoryStore(rootURL: root, limit: 50),
                    vocabulary: VocabularyStore(rootURL: root),
                    isSecureInputEnabled: { false },
                    postEventAuthorization: PostEventAuthorization(probe: { false })
                    // **締め切りは既定（2 秒）のまま。** 出荷する構成で測る。
                )

                let run = Task { await session.run() }
                defer { run.cancel() }

                hotkey.emit(.pressed)
                try await waitUntil("録音が始まる") {
                    if case .recording = await session.state { return true }
                    return false
                }
                await audio.waitForPlayback()
                hotkey.emit(.released)
                try await waitUntil("待機へ戻る", timeout: .seconds(60)) {
                    await session.state == .idle
                }
                // 認識器がストリームを閉じきるまで待ってから数える。
                await transcriber.waitForStreamEnd()

                let observed = transcriber.observation
                let everything = observed.finals.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let inserted = inserter.inserted.first ?? ""

                print("V-12 音声長: \(Self.utteranceSeconds) 秒（実時間で供給）")
                print("V-12 確定の総数: \(observed.finals.count) 件")
                print("V-12 解放後に届いた確定: \(observed.finalsAfterRelease) 件")
                print("V-12 挿入された文字数: \(inserted.count) / 確定の総和: \(everything.count)")
                if inserted != everything {
                    print("V-12 取りこぼし: \(everything.dropFirst(inserted.count))")
                }

                // **これが V-12 の本体である。** 解放後に 2 回目の確定が来て、
                // それが読み取りの後だったなら、その分の文字がここで欠ける。
                #expect(
                    inserted == everything,
                    "解放後に届いた確定を取りこぼしている（V-12）")
            }
        }
    }
}

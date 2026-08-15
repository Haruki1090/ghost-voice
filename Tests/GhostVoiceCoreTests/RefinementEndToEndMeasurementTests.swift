import AVFAudio
import Foundation
import Testing

@testable import GhostVoiceCore

/// **受け入れ条件 1 の実測: 56 字帯の発話は整形が反映されるか。**
///
/// トラック A4 は「56 字の発話で整形が 10/10 反映されなかった」と報告した。
/// その計測は**フィクスチャ音声を 10 秒で切って**流しており、**発話が文の途中で
/// 終わっていた**（`RefinementGuardMeasurement.reproducesA4Slices` で再現済み）。
///
/// ここは**同じ長さ帯の「言い終えた」発話**を、認識から差し替えまで通して測る。
/// 発話長そのものが原因なのかを切り分ける、A4 の対照実験である。
///
/// ## 何を通しているか（A4 の `RevisionBudgetMeasurement` と同じ）
///
/// | 部品 | 本物か |
/// |---|---|
/// | 認識 / 整形 / 挿入 / 差し替え | **本物** |
/// | マイク | 代役（**開かない**。`say -v Kyoko` の音声を実時間で流す） |
/// | 挿入先 | **代役の欄。実機のアプリへは 1 文字も書かない** |
///
/// `GHOST_VOICE_E_MEASURE=1` を付けたときだけ走る。
@Suite(
    "E: 56 字帯の言い終えた発話が整形されるか（A4 の対照実験）",
    .serialized,
    .enabled("GHOST_VOICE_E_MEASURE=1 を付けると実行される") {
        ProcessInfo.processInfo.environment["GHOST_VOICE_E_MEASURE"] == "1"
    },
    .enabled(if: FoundationModelRefiner().isAvailable, "Apple Intelligence が要る"),
    .enabled("ja-JP のモデル資産が要る") { await SpeechFixtures.modelInstalled(locale: .jaJP) }
)
struct RefinementEndToEndMeasurement {

    /// **言い終えた 58 字**（読点・句点まで含む）。`say -v Kyoko` でおよそ 10 秒。
    /// A4 が捨てられた 56 字と同じ帯で、**違いは「文が終わっているか」だけ**である。
    static let script = "えーっと、本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから、あの、始めさせてください。"

    static let passes = 3

    @Test("言い終えた 56 字帯の発話は (a) で整形が反映される")
    func refinesCompleteUtteranceOfSameLength() async throws {
        let audio = try synthesize(Self.script)
        defer { try? FileManager.default.removeItem(at: audio) }

        let transcriber = SpeechAnalyzerTranscriber()
        try await transcriber.prepare(locale: .jaJP, kind: Settings.default.transcriberKind)
        let format = try #require(await transcriber.requiredAudioFormat)
        let buffers = try SpeechFixtures.buffers(from: audio, to: format)

        let refiner = FoundationModelRefiner()
        await refiner.prewarm()

        var applied = 0
        var lengths: [Int] = []
        try await withTempRoot { root in
            let world = MeasurementWorld()
            let settings = SettingsStore(rootURL: root)
            try settings.update { $0.refinementApplyMode = .afterInsert }
            let hotkey = StubHotkeyMonitor()
            let capture = ReplayAudioCapture(buffers: buffers, interval: .milliseconds(100))
            let history = HistoryStore(rootURL: root, limit: 200)
            let session = DictationSession(
                settings: settings,
                hotkey: hotkey,
                audio: capture,
                transcriber: transcriber,
                refiner: refiner,
                insertion: world.stack,
                history: history,
                vocabulary: VocabularyStore(rootURL: root),
                isSecureInputEnabled: { false },
                postEventAuthorization: PostEventAuthorization(probe: { false })
            )
            let notices = NoticeLog()
            let collector = notices.follow(session)
            defer { collector.cancel() }
            let run = Task { await session.run() }
            defer { run.cancel() }

            for pass in 1...Self.passes {
                hotkey.emit(.pressed)
                try await waitUntil("\(pass) 回目の録音が始まる") {
                    if case .recording = await session.state { return true }
                    return false
                }
                await capture.waitForPlayback()
                hotkey.emit(.released)
                try await waitUntil("\(pass) 回目が待機へ戻る", timeout: .seconds(60)) {
                    await session.state == .idle
                }
                try await waitUntil("\(pass) 回目の差し替えが終わる", timeout: .seconds(60)) {
                    notices.notices.count == pass
                }

                let entry = try #require(history.entries.first)
                lengths.append(entry.rawText.count)
                print("--- \(pass) 回目 ---")
                print("  raw(\(entry.rawText.count) 字)    : \(entry.rawText)")
                print("  refined            : \(entry.refinedText ?? "**nil（整形が反映されなかった）**")")
                print("  顛末               : \(notices.notices.last.map(String.init(describing:)) ?? "-")")
                if entry.refinedText != nil { applied += 1 }
                world.reset()
            }
        }

        print("=== 言い終えた \(lengths) 字 / 整形が履歴へ入った発話: \(applied)/\(Self.passes) ===")
        #expect(
            applied == Self.passes,
            "同じ長さ帯でも言い終えた発話なら整形が反映されるはずだった: \(applied)/\(Self.passes)")
    }

    /// `say -v Kyoko` で読み上げ音声を作る。**再生はしない**（ファイルへ書き出すだけ）。
    /// 詳細設計書 §11.2 のフィクスチャ生成と同じ手順。
    private func synthesize(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghost-voice-e-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Kyoko", "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        return url
    }
}

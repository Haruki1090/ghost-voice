import AVFAudio
import AVFoundation
import Foundation
import Testing

@testable import GhostVoiceCore

// MARK: - 純粋ロジック（エンジン不要）

@Suite("AudioCapture の RMS")
struct AudioCaptureRMSTests {

    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private func buffer(_ values: [Float]) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(values.count, 1)))!
        b.frameLength = AVAudioFrameCount(values.count)
        for (i, v) in values.enumerated() { b.floatChannelData![0][i] = v }
        return b
    }

    @Test("無音は 0")
    func silence() {
        #expect(EngineAudioCapture.rms(of: buffer([Float](repeating: 0, count: 512))) == 0)
    }

    @Test("フレーム数 0 は 0")
    func empty() {
        #expect(EngineAudioCapture.rms(of: buffer([])) == 0)
    }

    @Test("振幅一定なら振幅そのもの")
    func constant() {
        #expect(abs(EngineAudioCapture.rms(of: buffer([Float](repeating: 0.5, count: 256))) - 0.5) < 1e-6)
    }

    @Test("符号は打ち消し合わない（二乗平均であること）")
    func signsDoNotCancel() {
        // 単純平均なら 0 になる列。二乗平均なら 0.5。
        let alternating = (0..<256).map { $0.isMultiple(of: 2) ? Float(0.5) : Float(-0.5) }
        #expect(abs(EngineAudioCapture.rms(of: buffer(alternating)) - 0.5) < 1e-6)
    }

    @Test("正弦波は振幅 / √2")
    func sine() {
        var phase = 0.0
        let b = makeToneBuffer(format: format, frames: 4_800, amplitude: 0.5, phase: &phase)
        let expected = Float(0.5) / Float(2).squareRoot()
        #expect(abs(EngineAudioCapture.rms(of: b) - expected) < 1e-3)
    }

    @Test("大きい信号ほど値が大きい（単調性）")
    func monotonic() {
        let quiet = EngineAudioCapture.rms(of: buffer([Float](repeating: 0.1, count: 256)))
        let loud = EngineAudioCapture.rms(of: buffer([Float](repeating: 0.9, count: 256)))
        #expect(quiet < loud)
    }

    @Test("Float32 でないバッファは 0（クラッシュしない）")
    func nonFloatBuffer() {
        let int16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let b = AVAudioPCMBuffer(pcmFormat: int16, frameCapacity: 128)!
        b.frameLength = 128
        #expect(EngineAudioCapture.rms(of: b) == 0)
    }
}

@Suite("AudioCapture の形式変換")
struct AudioCaptureConversionTests {

    private let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private func source(_ rate: Double, _ channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    }

    /// `chunks` 回に分けて変換し、最後に flush した合計フレーム数を返す。
    private func totalFrames(
        from format: AVAudioFormat, chunkFrames: AVAudioFrameCount, chunks: Int
    ) -> AVAudioFrameCount {
        let converter = AVAudioConverter(from: format, to: target)!
        var phase = 0.0
        var total: AVAudioFrameCount = 0
        for _ in 0..<chunks {
            let input = makeToneBuffer(format: format, frames: chunkFrames, phase: &phase)
            if let out = EngineAudioCapture.convert(input, using: converter, to: target) {
                total += out.frameLength
            }
        }
        if let tail = EngineAudioCapture.drain(converter, to: target) { total += tail.frameLength }
        return total
    }

    @Test("48 kHz → 16 kHz はフレーム数が 1/3 になる")
    func downsample() {
        #expect(totalFrames(from: source(48_000, 1), chunkFrames: 4_800, chunks: 10) == 16_000)
    }

    @Test("ステレオ入力もモノラルへ落とせる")
    func stereoToMono() {
        #expect(totalFrames(from: source(48_000, 2), chunkFrames: 4_800, chunks: 10) == 16_000)
    }

    @Test("44.1 kHz のような非整数倍のレートも失わない")
    func nonIntegerRatio() {
        #expect(totalFrames(from: source(44_100, 2), chunkFrames: 4_410, chunks: 10) == 16_000)
    }

    @Test("同一形式なら素通しでフレーム数が一致する")
    func sameRate() {
        #expect(totalFrames(from: source(16_000, 1), chunkFrames: 1_600, chunks: 10) == 16_000)
    }

    @Test("小さいバッファを刻んでも取りこぼさない")
    func smallChunks() {
        // 1024 フレーム × 47 回 = 48128 → 16 kHz で 16042 か 16043（端数）
        let total = totalFrames(from: source(48_000, 1), chunkFrames: 1_024, chunks: 47)
        #expect(total >= 16_042 && total <= 16_043)
    }

    @Test("出力容量 +1 は 1〜4000 フレームのどこでも不足しない")
    func capacityIsSufficient() {
        let format = source(48_000, 1)
        let converter = AVAudioConverter(from: format, to: target)!
        var phase = 0.0
        var overflow: [AVAudioFrameCount] = []
        for n in 1...4_000 {
            let input = makeToneBuffer(format: format, frames: AVAudioFrameCount(n), phase: &phase)
            guard let out = EngineAudioCapture.convert(input, using: converter, to: target) else {
                overflow.append(AVAudioFrameCount(n))
                continue
            }
            let capacity = AVAudioFrameCount(Double(n) * 16_000 / 48_000) + 1
            if out.frameLength > capacity { overflow.append(AVAudioFrameCount(n)) }
        }
        #expect(overflow.isEmpty)
    }

    @Test("正弦波の振幅が変換後も保たれる")
    func amplitudeSurvives() {
        let format = source(48_000, 1)
        let converter = AVAudioConverter(from: format, to: target)!
        var phase = 0.0
        var peak: Int16 = 0
        for _ in 0..<5 {
            let input = makeToneBuffer(format: format, frames: 4_800, amplitude: 0.5, phase: &phase)
            guard let out = EngineAudioCapture.convert(input, using: converter, to: target),
                  let samples = out.int16ChannelData?[0] else { continue }
            for i in 0..<Int(out.frameLength) { peak = max(peak, abs(samples[i])) }
        }
        // 0.5 振幅 → Int16 で約 16384。リサンプラの誤差を見て 5 % 許容。
        #expect(abs(Int(peak) - 16_384) < 820, "peak=\(peak)")
    }

    @Test("8 kHz → 16 kHz のアップサンプリングでも失わない")
    func upsample() {
        // Bluetooth の HFP は 8 kHz で入ってくる。ここはレート比が 1 を超える唯一の経路で、
        // 出力容量を「フレーム数 × レート比 + 1」で取れていないと切り詰められる。
        #expect(totalFrames(from: source(8_000, 1), chunkFrames: 800, chunks: 10) == 16_000)
    }

    @Test("入力形式がコンバータと違うバッファは nil を返す（黙って壊れた音を通さない）")
    func rejectsMismatchedInput() {
        let converter = AVAudioConverter(from: source(48_000, 1), to: target)!
        var phase = 0.0
        // 44.1 kHz のバッファを 48 kHz 用のコンバータへ渡す。
        // AVAudioConverter は error を立てつつ出力バッファを埋めて返すため、
        // error を見ないと中身の壊れたバッファをそのまま下流へ流すことになる。
        let mismatched = makeToneBuffer(format: source(44_100, 1), frames: 4_410, phase: &phase)
        #expect(EngineAudioCapture.convert(mismatched, using: converter, to: target) == nil)

        let stereo = makeToneBuffer(format: source(48_000, 2), frames: 4_800, phase: &phase)
        #expect(EngineAudioCapture.convert(stereo, using: converter, to: target) == nil)
    }

    @Test("無音を変換しても無音のまま")
    func silenceStaysSilent() {
        let format = source(48_000, 1)
        let converter = AVAudioConverter(from: format, to: target)!
        var phase = 0.0
        let input = makeToneBuffer(format: format, frames: 4_800, amplitude: 0, phase: &phase)
        let out = EngineAudioCapture.convert(input, using: converter, to: target)
        var peak: Int16 = 0
        if let samples = out?.int16ChannelData?[0] {
            for i in 0..<Int(out!.frameLength) { peak = max(peak, abs(samples[i])) }
        }
        #expect(peak == 0)
    }
}

// MARK: - エンジン・タップ（手動レンダリング / マイク不要）

@Suite("AudioCapture のタップ", .serialized)
struct AudioCaptureTapTests {

    private let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    @Test("prepare を二重に呼んでも例外を出さず、エンジンが動いている")
    func prepareIsIdempotent() throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        try capture.prepare()
        #expect(capture.isEngineRunning)
        capture.stopTap()
    }

    @Test("prepare していなければ startTap は notPrepared を投げる")
    func startTapRequiresPrepare() throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        #expect(throws: AudioCaptureError.notPrepared) { _ = try capture.startTap(format: nil) }
    }

    @Test("タップ着脱を繰り返してもエンジンが生きている")
    func tapCycling() throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        for _ in 0..<3 {
            _ = try capture.startTap(format: nil)
            capture.stopTap()
        }
        #expect(capture.isEngineRunning)
    }

    @Test("isTapping が実際の装着状態を表す")
    func isTappingReflectsState() throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        #expect(!capture.isTapping)
        _ = try capture.startTap(format: nil)
        #expect(capture.isTapping)
        capture.stopTap()
        #expect(!capture.isTapping, "stopTap した後も装着中のままになっている")
    }

    @Test("stopTap を二重に呼んでも安全")
    func stopTapIsIdempotent() throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        _ = try capture.startTap(format: nil)
        capture.stopTap()
        capture.stopTap()
        #expect(capture.isEngineRunning)
    }

    @Test("startTap しなくても stopTap は安全")
    func stopTapWithoutStart() throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        capture.stopTap()
        #expect(capture.isEngineRunning)
    }

    @Test("stopTap でストリームが終了する")
    func stopTapFinishesStream() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let stream = try capture.startTap(format: nil)
        try rig.render(frames: 9_600)
        capture.stopTap()
        let summary = await summarize(stream)
        #expect(summary.finished, "stopTap してもストリームが終わらない")
        #expect(summary.count > 0)
    }

    @Test("stopTap 無しで startTap を呼び直すと、前のストリームは終了する")
    func restartFinishesPreviousStream() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let first = try capture.startTap(format: nil)
        try rig.render(frames: 9_600)
        let second = try capture.startTap(format: nil)   // stopTap を経ずに再開
        let previous = await summarize(first)
        #expect(previous.finished, "前のストリームが終了していない")
        #expect(previous.count > 0, "前のストリームは終了した上で、供給済みのバッファを配ること")
        capture.stopTap()
        _ = await summarize(second)
    }

    @Test("素通しならレンダリングしたフレームを 1 つも失わない")
    func passthroughLosesNothing() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let stream = try capture.startTap(format: nil)
        try rig.render(frames: 48_000)
        capture.stopTap()
        let summary = await summarize(stream)
        #expect(summary.finished)
        #expect(summary.frames == 48_000, "取りこぼし \(48_000 - Int(summary.frames)) フレーム")
    }

    @Test("変換経路でもレンダリングしたぶんを失わない（末尾の flush 込み）")
    func convertedLosesNothing() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let stream = try capture.startTap(format: target)
        try rig.render(frames: 48_000)
        capture.stopTap()
        let summary = await summarize(stream)
        #expect(summary.finished)
        // 48 kHz × 48000 フレーム → 16 kHz で 16000 フレーム
        #expect(summary.frames == 16_000, "取りこぼし \(16_000 - Int(summary.frames)) フレーム")
    }

    @Test("変換したバッファは要求した形式で届く")
    func convertedFormatMatches() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let stream = try capture.startTap(format: target)
        try rig.render(frames: 14_400)
        capture.stopTap()
        let summary = await summarize(stream)
        #expect(summary.finished)
        #expect(summary.sampleRates == [16_000], "\(summary.sampleRates)")
        #expect(summary.channelCounts == [1], "\(summary.channelCounts)")
    }

    @Test("素通しなら入力ノードの形式のまま届く")
    func passthroughFormatMatches() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let stream = try capture.startTap(format: nil)
        try rig.render(frames: 14_400)
        capture.stopTap()
        let summary = await summarize(stream)
        #expect(summary.finished)
        #expect(summary.sampleRates == [48_000])
    }

    @Test("level には直近バッファの RMS が流れる")
    func levelCarriesRMS() async throws {
        let rig = try ManualRenderingRig()
        rig.amplitude = 0.5
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        _ = try capture.startTap(format: nil)
        try rig.render(frames: 9_600)
        capture.stopTap()

        let value = await firstValue(of: capture.level)
        // 振幅 0.5 の正弦波 → RMS ≈ 0.354
        #expect(value != nil, "level に値が流れてこない")
        #expect(abs((value ?? 0) - 0.354) < 0.02, "level=\(value ?? -1)")
    }

    @Test("level は最新値だけを保つ（溜め込まない）")
    func levelKeepsOnlyNewest() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        _ = try capture.startTap(format: nil)

        rig.amplitude = 0.5
        try rig.render(frames: 24_000)   // 大きい音を先に流す
        rig.amplitude = 0
        try rig.render(frames: 24_000)   // その後で無音を流す
        capture.stopTap()

        // 溜め込んでいれば最初に取り出せるのは古い「大きい音」の RMS になる。
        let value = await firstValue(of: capture.level)
        #expect((value ?? 1) < 0.01, "最新の無音ではなく古い値が残っている: \(value ?? -1)")
    }

    @Test("設定変更（デバイス切断）でストリームを終わらせず、再構成して供給を続ける")
    func configurationChangeKeepsStreamAlive() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let stream = try capture.startTap(format: nil)
        try rig.render(frames: 9_600)

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: rig.engine)
        await capture.waitForReconfiguration()

        #expect(capture.isEngineRunning, "再構成後もエンジンは動いていること")
        #expect(capture.reconfigurationCount == 1)

        try rig.render(frames: 9_600)
        capture.stopTap()

        let summary = await summarize(stream)
        #expect(summary.finished)
        #expect(summary.count > 0)
        #expect(summary.frames > 9_600, "再構成の後で供給されたバッファが無い: \(summary.frames)")
    }

    @Test("設定変更でエンジンが止まっていたら、再構成で起動し直す")
    func configurationChangeRestartsStoppedEngine() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let stream = try capture.startTap(format: nil)
        try rig.render(frames: 9_600)

        // 実機のデバイス切断では、通知が届く時点でエンジンは自ら停止している。
        // 手動レンダリングでは自動では止まらないので、その状態を作ってから通知する。
        rig.engine.stop()
        #expect(!capture.isEngineRunning)

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: rig.engine)
        await capture.waitForReconfiguration()

        #expect(capture.isEngineRunning, "停止したエンジンが再起動されていない")
        try rig.render(frames: 9_600)
        capture.stopTap()

        let summary = await summarize(stream)
        #expect(summary.finished)
        #expect(summary.frames > 9_600, "再起動後に供給されたバッファが無い: \(summary.frames)")
    }

    @Test("prepare を呼び直しても供給中のバッファを失わない")
    func repeatedPrepareDoesNotDisturbCapture() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let stream = try capture.startTap(format: nil)
        try rig.render(frames: 24_000)
        try capture.prepare()          // 発話中の再 prepare
        try rig.render(frames: 24_000)
        capture.stopTap()

        let summary = await summarize(stream)
        #expect(summary.finished)
        #expect(summary.frames == 48_000, "取りこぼし \(48_000 - Int(summary.frames)) フレーム")
    }

    @Test("startTap の武装コスト（NFR-P1 の下限値。実 HAL は回っていない）")
    func armingCostLowerBound() throws {
        // **これは NFR-P1 の実測値ではない。** 手動レンダリングではハードウェアの
        // 再構成が起きないため、ここで測れるのは installTap まわりの純粋な呼び出しコスト、
        // すなわち実機での値の「下限」だけである。実機での計測は V-9（要マイク権限）。
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()

        var samples: [Double] = []
        for _ in 0..<50 {
            let start = ContinuousClock.now
            _ = try capture.startTap(format: target)
            let elapsed = ContinuousClock.now - start
            capture.stopTap()
            samples.append(Double(elapsed.components.attoseconds) / 1e15)   // ms
        }
        let sorted = samples.sorted()
        print(String(
            format: "startTap 武装コスト（手動レンダリング / 下限値）: 中央値 %.4f ms / 最大 %.4f ms（50 回）",
            sorted[sorted.count / 2], sorted.last!))
        #expect(sorted.last! < 50, "下限値ですら NFR-P1 の予算を超えている: \(sorted.last!) ms")
    }

    @Test("タップしていないときの設定変更でもエンジンは生きたまま")
    func configurationChangeWhileIdle() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: rig.engine)
        await capture.waitForReconfiguration()
        #expect(capture.isEngineRunning)
    }
}

// MARK: - マイク権限

@Suite("AudioCapture のマイク権限")
struct AudioCapturePermissionTests {

    @Test(
        "権限が無ければ prepare は microphoneAccessNotGranted を投げる（HAL を掴んで固まらない）",
        .enabled(if: AVCaptureDevice.authorizationStatus(for: .audio) != .authorized)
    )
    func refusesWithoutPermission() {
        let capture = EngineAudioCapture()
        let expected = AudioCaptureError.microphoneAccessNotGranted(
            MicrophoneAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
        )
        #expect(throws: expected) { try capture.prepare() }
    }

    @Test("手動レンダリングではマイクを開かないので権限を要求しない")
    func manualRenderingNeedsNoPermission() throws {
        let before = AVCaptureDevice.authorizationStatus(for: .audio)
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        _ = try capture.startTap(format: nil)
        try rig.render(frames: 4_800)
        capture.stopTap()
        #expect(AVCaptureDevice.authorizationStatus(for: .audio) == before)
    }

    @Test("AVAuthorizationStatus をそのまま写し取る")
    func authorizationMapping() {
        #expect(MicrophoneAuthorization(.notDetermined) == .notDetermined)
        #expect(MicrophoneAuthorization(.restricted) == .restricted)
        #expect(MicrophoneAuthorization(.denied) == .denied)
        #expect(MicrophoneAuthorization(.authorized) == .authorized)
    }
}

// MARK: - 実マイク（権限 + 明示的な opt-in が揃ったときだけ走る）

/// 実マイクを開くテストの実行条件。
///
/// **権限があるだけでは走らせない。** 権限を一度付与すると、以後
/// `swift test` を回すたびに黙ってマイクが開くことになる。ユーザーが許可したのは
/// 「NFR-P1 の計測」であって「毎回の録音」ではないので、環境変数による明示的な
/// opt-in を併せて要求する。
///
/// ```
/// GHOST_VOICE_MIC_TESTS=1 swift test --filter "実マイク"
/// ```
enum MicrophoneTestGate {
    static let variable = "GHOST_VOICE_MIC_TESTS"

    static var isEnabled: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && ProcessInfo.processInfo.environment[variable] == "1"
    }

    static let reason: Comment = "実マイクを開く。マイク権限と GHOST_VOICE_MIC_TESTS=1 の両方が要る"
}

@Suite(
    "AudioCapture の実マイク", .serialized,
    .enabled(if: MicrophoneTestGate.isEnabled, MicrophoneTestGate.reason)
)
struct AudioCaptureMicrophoneTests {

    /// 経過時間をミリ秒で返す。
    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15
    }

    private func stats(_ samples: [Double]) -> (median: Double, min: Double, max: Double) {
        let sorted = samples.sorted()
        return (sorted[sorted.count / 2], sorted.first ?? 0, sorted.last ?? 0)
    }

    @Test("マイクからバッファが届く")
    func receivesBuffers() async throws {
        let capture = EngineAudioCapture()
        try capture.prepare()
        let stream = try capture.startTap(format: nil)

        var count = 0
        let deadline = ContinuousClock.now + .seconds(3)
        for await _ in stream {
            count += 1
            if count >= 3 || ContinuousClock.now > deadline { break }
        }
        capture.stopTap()
        #expect(count >= 3)
    }

    @Test("実機の入力形式とタップ長を記録する（§3.5 の 4800 フレーム下限の検証）")
    func actualInputFormatAndTapSize() async throws {
        let capture = EngineAudioCapture()
        try capture.prepare()
        let stream = try capture.startTap(format: nil)

        var lengths: [AVAudioFrameCount] = []
        var rate: Double = 0
        var channels: AVAudioChannelCount = 0
        let deadline = ContinuousClock.now + .seconds(3)
        for await buffer in stream {
            lengths.append(buffer.frameLength)
            rate = buffer.format.sampleRate
            channels = buffer.format.channelCount
            if lengths.count >= 5 || ContinuousClock.now > deadline { break }
        }
        capture.stopTap()

        let unique = Set(lengths).sorted()
        print("実機の入力形式: \(rate) Hz / \(channels) ch")
        print("実機のタップ長: \(unique)（要求 \(EngineAudioCapture.tapBufferSize)）"
              + " = \(unique.map { String(format: "%.1f ms", Double($0) / rate * 1000) })")
        #expect(!lengths.isEmpty)
    }

    @Test("NFR-P1 / M1a: キー押下 → タップ武装")
    func armingLatency() throws {
        let capture = EngineAudioCapture()
        try capture.prepare()

        var samples: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            _ = try capture.startTap(format: nil)
            samples.append(milliseconds(ContinuousClock.now - start))
            capture.stopTap()
        }
        let s = stats(samples)
        print(String(format: "M1a タップ武装: 中央値 %.4f ms / 最小 %.4f / 最大 %.4f（30 回・実 HAL）",
                     s.median, s.min, s.max))
        #expect(s.max < 50, "最大 \(s.max) ms")
    }

    @Test("NFR-P1 / M1b: キー押下 → 最初の実バッファ到達")
    func firstBufferLatency() async throws {
        let capture = EngineAudioCapture()
        try capture.prepare()

        var samples: [Double] = []
        var frameLengths: [AVAudioFrameCount] = []
        for _ in 0..<15 {
            let start = ContinuousClock.now
            let stream = try capture.startTap(format: nil)
            var iterator = stream.makeAsyncIterator()
            guard let first = await iterator.next() else {
                capture.stopTap()
                continue
            }
            samples.append(milliseconds(ContinuousClock.now - start))
            frameLengths.append(first.frameLength)
            capture.stopTap()
        }
        let s = stats(samples)
        print(String(format: "M1b 最初のバッファ到達: 中央値 %.2f ms / 最小 %.2f / 最大 %.2f（%d 回・実 HAL）",
                     s.median, s.min, s.max, samples.count))
        print("M1b 最初のバッファのフレーム長: \(Set(frameLengths).sorted())")
        // 到達時間はタップの粒度で決まるため、要件の 50 ms は満たせない見込み。
        // ここでは「壊れていないこと」だけを見る（1 秒以内には来る）。
        #expect(s.max < 1_000, "最大 \(s.max) ms")
    }
}

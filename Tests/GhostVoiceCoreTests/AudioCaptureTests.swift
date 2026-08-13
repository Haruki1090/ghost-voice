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

    /// 終了済みストリームを最後まで読み、フレーム数の合計と件数を返す。
    private func drain(_ stream: AsyncStream<AVAudioPCMBuffer>) async -> (count: Int, frames: AVAudioFrameCount) {
        var count = 0
        var frames: AVAudioFrameCount = 0
        for await buffer in stream {
            count += 1
            frames += buffer.frameLength
        }
        return (count, frames)
    }

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
        let (count, _) = await drain(stream)
        #expect(count > 0)
    }

    @Test("stopTap 無しで startTap を呼び直すと、前のストリームは終了する")
    func restartFinishesPreviousStream() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let first = try capture.startTap(format: nil)
        try rig.render(frames: 9_600)
        let second = try capture.startTap(format: nil)   // stopTap を経ずに再開
        // 前のストリームが終了していなければ、この drain は返ってこない。
        let (count, _) = await drain(first)
        #expect(count > 0, "前のストリームは終了した上で、供給済みのバッファを配ること")
        capture.stopTap()
        _ = await drain(second)
    }

    @Test("素通しならレンダリングしたフレームを 1 つも失わない")
    func passthroughLosesNothing() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let stream = try capture.startTap(format: nil)
        try rig.render(frames: 48_000)
        capture.stopTap()
        let (_, frames) = await drain(stream)
        #expect(frames == 48_000, "取りこぼし \(48_000 - Int(frames)) フレーム")
    }

    @Test("変換経路でもレンダリングしたぶんを失わない（末尾の flush 込み）")
    func convertedLosesNothing() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let stream = try capture.startTap(format: target)
        try rig.render(frames: 48_000)
        capture.stopTap()
        let (_, frames) = await drain(stream)
        // 48 kHz × 48000 フレーム → 16 kHz で 16000 フレーム
        #expect(frames == 16_000, "取りこぼし \(16_000 - Int(frames)) フレーム")
    }

    @Test("変換したバッファは要求した形式で届く")
    func convertedFormatMatches() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let stream = try capture.startTap(format: target)
        try rig.render(frames: 14_400)
        capture.stopTap()
        var formats: Set<String> = []
        for await buffer in stream { formats.insert("\(buffer.format)") }
        #expect(formats.count == 1)
        #expect(formats.first?.contains("16000") == true, "\(formats)")
    }

    @Test("素通しなら入力ノードの形式のまま届く")
    func passthroughFormatMatches() async throws {
        let rig = try ManualRenderingRig()
        let capture = EngineAudioCapture(engine: rig.engine)
        try capture.prepare()
        let stream = try capture.startTap(format: nil)
        try rig.render(frames: 14_400)
        capture.stopTap()
        var rates: Set<Double> = []
        for await buffer in stream { rates.insert(buffer.format.sampleRate) }
        #expect(rates == [48_000])
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

        var iterator = capture.level.makeAsyncIterator()
        let value = await iterator.next()
        // 振幅 0.5 の正弦波 → RMS ≈ 0.354
        #expect(value != nil)
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
        var iterator = capture.level.makeAsyncIterator()
        let value = await iterator.next()
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

        let (count, frames) = await drain(stream)
        #expect(count > 0)
        #expect(frames > 9_600, "再構成の後で供給されたバッファが無い: \(frames)")
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

// MARK: - 実マイク（権限がある環境でのみ走る）

@Suite(
    "AudioCapture の実マイク", .serialized,
    .enabled(if: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
)
struct AudioCaptureMicrophoneTests {

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

    @Test("NFR-P1: startTap がタップを武装するまで 50 ms 以内")
    func armingLatency() throws {
        let capture = EngineAudioCapture()
        try capture.prepare()

        var samples: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            _ = try capture.startTap(format: nil)
            let elapsed = ContinuousClock.now - start
            capture.stopTap()
            samples.append(Double(elapsed.components.attoseconds) / 1e15)   // ms
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        print(String(format: "NFR-P1 startTap 武装: 中央値 %.3f ms / 最大 %.3f ms（20 回）",
                     median, sorted.last!))
        #expect(sorted.last! < 50, "最大 \(sorted.last!) ms")
    }
}

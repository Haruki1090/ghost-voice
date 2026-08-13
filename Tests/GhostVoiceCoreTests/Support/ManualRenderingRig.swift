import AVFAudio
import Foundation

/// マイクを開かずに `AVAudioEngine` の入力ノードを本物として動かすための治具。
///
/// `enableManualRenderingMode(.offline:)` を有効にした上で
/// `inputNode.setManualRenderingInputPCMFormat(_:inputBlock:)` に合成音を供給する。
/// この経路はハードウェアを一切開かないため、**マイク権限が無い環境でも
/// タップの着脱・形式変換・ストリームの状態遷移を実物のコードパスで検証できる**。
///
/// 実測（2026-08-14 / M3 / macOS 26.5.2）:
/// エンジン生成から停止まで `AVCaptureDevice.authorizationStatus(for: .audio)` は
/// `notDetermined` のまま変化せず、権限ダイアログも出ない。
///
/// > **重要**: `enableManualRenderingMode` は `engine.inputNode` に**触れる前に**呼ぶこと。
/// > 先に `inputNode` へ触れると HAL を掴みにいき、マイク権限が `notDetermined` の
/// > プロセスでは**実測 510 秒ブロックする**（その後、権限が付かないまま返る）。
/// > 順序を逆にするとテスト全体が 8 分半止まる。
final class ManualRenderingRig: @unchecked Sendable {

    let engine = AVAudioEngine()
    let format: AVAudioFormat

    /// 入力ブロックが生成する正弦波の振幅。0 にすれば無音。
    var amplitude: Float = 0.5
    /// 入力ブロックが生成する正弦波の周波数（Hz）。
    var frequency: Double = 440

    private let scratch: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var phase: Double = 0

    init(
        sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 1,
        maximumFrameCount: AVAudioFrameCount = 4_096
    ) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
              let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrameCount)
        else { throw RigError.formatUnavailable }
        self.format = format
        self.scratch = scratch

        // inputNode に触れる前に手動レンダリングへ切り替える。順序が逆だと HAL を掴む。
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrameCount)

        guard let output = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: maximumFrameCount
        ) else { throw RigError.formatUnavailable }
        self.output = output

        let input = engine.inputNode
        guard input.setManualRenderingInputPCMFormat(format, inputBlock: { [self] frameCount in
            fill(frameCount)
        }) else { throw RigError.inputBlockRejected }

        // 手動レンダリングでは入力ノードがグラフに繋がっていないと引かれない。
        // 実機では HAL の I/O サイクルがタップを回すため、この接続は治具側だけの都合。
        engine.connect(input, to: engine.mainMixerNode, format: format)
    }

    /// `frames` フレームぶんレンダリングし、タップを回す。
    func render(frames: AVAudioFrameCount) throws {
        var remaining = frames
        while remaining > 0 {
            let chunk = min(output.frameCapacity, remaining)
            let status = try engine.renderOffline(chunk, to: output)
            guard status == .success, output.frameLength > 0 else { throw RigError.renderStalled(status) }
            remaining -= output.frameLength
        }
    }

    private func fill(_ frameCount: AVAudioFrameCount) -> UnsafePointer<AudioBufferList> {
        scratch.frameLength = frameCount
        let increment = 2 * Double.pi * frequency / format.sampleRate
        for channel in 0..<Int(format.channelCount) {
            var local = phase
            let samples = scratch.floatChannelData![channel]
            for i in 0..<Int(frameCount) {
                samples[i] = Float(sin(local)) * amplitude
                local += increment
            }
            if channel == Int(format.channelCount) - 1 { phase = local }
        }
        return UnsafePointer(scratch.mutableAudioBufferList)
    }

    enum RigError: Error {
        case formatUnavailable
        case inputBlockRejected
        case renderStalled(AVAudioEngineManualRenderingStatus)
    }
}

/// 単調増加する正弦波で満たした Float32 バッファを作る（変換テスト用）。
func makeToneBuffer(
    format: AVAudioFormat,
    frames: AVAudioFrameCount,
    amplitude: Float = 0.5,
    frequency: Double = 440,
    phase: inout Double
) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let increment = 2 * Double.pi * frequency / format.sampleRate
    for channel in 0..<Int(format.channelCount) {
        var local = phase
        let samples = buffer.floatChannelData![channel]
        for i in 0..<Int(frames) {
            samples[i] = Float(sin(local)) * amplitude
            local += increment
        }
        if channel == Int(format.channelCount) - 1 { phase = local }
    }
    return buffer
}

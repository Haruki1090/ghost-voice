import AVFAudio
import Foundation

@testable import GhostVoiceCore

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

/// バッファ列の要約。`AVAudioPCMBuffer` を持ち出さずに済むよう、必要な数値だけ抜く。
struct StreamSummary: Sendable {
    var count = 0
    var frames: AVAudioFrameCount = 0
    var sampleRates: Set<Double> = []
    var channelCounts: Set<AVAudioChannelCount> = []
    /// ストリームが期限内に終了したか。**時間切れなら false。**
    var finished = false
}

private struct UnsafeBox<T>: @unchecked Sendable { let value: T }

/// バッファ列を最後まで読んで要約する。
///
/// **必ず期限を切ること。** 期限を切らないと、ストリームを終了し忘れる不具合が
/// 「テストの失敗」ではなく「テストの停止」になる。ミューテーションテストで
/// 実際に踏んだ（`finish()` を消す変異でテスト実行ごと止まった）。
func summarize(
    _ stream: AsyncStream<AVAudioPCMBuffer>, timeout: Duration = .seconds(5)
) async -> StreamSummary {
    let box = UnsafeBox(value: stream)
    return await withTaskGroup(of: StreamSummary?.self, returning: StreamSummary.self) { group in
        group.addTask {
            var summary = StreamSummary()
            for await buffer in box.value {
                summary.count += 1
                summary.frames += buffer.frameLength
                summary.sampleRates.insert(buffer.format.sampleRate)
                summary.channelCounts.insert(buffer.format.channelCount)
            }
            summary.finished = true
            return summary
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? StreamSummary()
    }
}

/// `stream` に最初に流れてくる値を、期限付きで待つ。届かなければ nil。
func firstValue(of stream: AsyncStream<Float>, timeout: Duration = .seconds(5)) async -> Float? {
    await withTaskGroup(of: Float?.self, returning: Float?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
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


/// 手動レンダリングの治具に対する `EngineAudioCapture` を作る。
///
/// **権限判定は注入する。** 手動レンダリングはマイクを開かないので、
/// 機体の実際の TCC 状態とは無関係に `.authorized` として扱ってよい。
func makeCapture(
    on rig: ManualRenderingRig,
    authorization: @escaping @Sendable () -> MicrophoneAuthorization = { .authorized }
) -> EngineAudioCapture {
    EngineAudioCapture(engine: rig.engine, authorization: authorization)
}

/// `inputNode` に触れたかどうかを記録するエンジン。
///
/// 「権限を確かめる**前に** `inputNode` へ触れない」——実測 510 秒ブロックを防ぐ
/// 順序そのもの——を検査するために使う。
final class InputNodeSpyEngine: AVAudioEngine, @unchecked Sendable {
    private(set) var didTouchInputNode = false

    override var inputNode: AVAudioInputNode {
        didTouchInputNode = true
        return super.inputNode
    }
}


/// 実行中に権限状態を切り替えられる注入元。
/// 「準備後にユーザーがシステム設定で取り消した」状況を作るために使う。
final class MutableAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MicrophoneAuthorization

    init(_ value: MicrophoneAuthorization) { self.value = value }

    var current: MicrophoneAuthorization {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    var provider: @Sendable () -> MicrophoneAuthorization {
        { [self] in current }
    }
}

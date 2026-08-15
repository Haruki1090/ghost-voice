import AVFAudio
import AVFoundation
import Foundation
import Synchronization

/// 実時間スレッドから増やせる破棄カウンタ。
///
/// タップのブロックはロックを取ってはならないため、`Atomic` で数える。
final class DroppedBufferCounter: Sendable {
    private let value = Atomic<Int>(0)
    func increment() { value.add(1, ordering: .relaxed) }
    var count: Int { value.load(ordering: .relaxed) }
}

/// タップのブロックが通る配達経路。
///
/// ブロックは `self` を掴めない（実時間スレッドで走るため）ので、必要なものだけを
/// 値でまとめてある。**同じ経路をテストから直接叩けるようにするのが目的**でもある。
/// 実時間スレッドの中身は、そこへ入れずに検査できなければ検査されない。
struct BufferDelivery: @unchecked Sendable {
    let counter: DroppedBufferCounter
    let converter: AVAudioConverter?
    let target: AVAudioFormat?

    /// 下流へ流せる形にして返す。**変換できなければ nil を返し、捨てた数を 1 増やす。**
    func prepared(_ buffer: AVAudioPCMBuffer) -> sending AVAudioPCMBuffer? {
        guard let converter, let target else {
            return EngineAudioCapture.detached(buffer)
        }
        guard let converted = EngineAudioCapture.convert(buffer, using: converter, to: target) else {
            counter.increment()
            return nil
        }
        return converted
    }
}

/// `AVAudioEngine` を常時起動したまま、タップの着脱だけで録音を開始・停止する実装。
///
/// ## 設計の要点
///
/// - エンジンは `prepare()` で `start()` まで済ませ、以後停止しない（NFR-P1）。
///   録音のたびに起動すると数十 ms を失う。
/// - **この型は隔離されていない（`final class`）。** `installTap` のブロックは設置した
///   文脈の actor 隔離を引き継ぐため、MainActor から設置すると実時間オーディオスレッドで
///   隔離チェックに失敗し SIGTRAP で落ちる。設置は必ずこの型の中で行うこと。
/// - **タップのブロックはロックを取らない。** `removeTap` は実時間スレッドと同期するため、
///   ブロック側でも同じロックを取ると優先度逆転を招く。ブロックは値でキャプチャした
///   継続とコンバータだけを触る。
public final class EngineAudioCapture: AudioCapturing, @unchecked Sendable {

    /// タップへ要求するバッファ長。
    ///
    /// これは**要求値であって実際の長さではない**。実 HAL で 64〜16000 を掃引した結果、
    /// **4800 フレーム（100.0 ms）が下限**で、それ未満は何を指定しても 4800 になる
    /// （4800 超は指定どおり）。つまり実装は `max(要求値, 4800)` として振る舞う。
    ///
    /// この下限は**ハードウェアの制約ではない**。同じデバイスの HAL の I/O バッファは
    /// 512 フレーム（10.7 ms）であり、100 ms は `AVAudioEngine` のタップ実装が持つ下限である。
    /// より細かく受けたければ `AVAudioSinkNode`（実測 512 フレーム）があるが、
    /// 実時間スレッドでの確保を自前で捌く必要があるため採っていない（設計書 §3.6）。
    ///
    /// この下限がそのまま「キー押下 → 最初のバッファ到達」の下限になる
    /// （実測 中央値 106.5〜106.7 ms）。**遅れの主因は取りこぼしではなく配達である。**
    /// ただし「タップ設置以降の音がすべて最初のバッファに入る」ことは直接測っていない。
    /// I/O サイクル境界へ整列する実装なら最大 1 サイクル（512 フレーム ≒ 10.7 ms）の
    /// 頭欠けが残りうる（設計書 §10 の但し書き / V-11）。
    static let tapBufferSize: AVAudioFrameCount = 1_024

    private let engine: AVAudioEngine
    private let lock = NSLock()

    /// 設定変更の処理を逃がす直列キュー。
    /// 通知は CoreAudio 側のスレッドから届くため、そこで `lock` を取ると
    /// 実時間スレッドを巻き込みかねない。必ずここへ逃がす。
    private let reconfigurationQueue = DispatchQueue(label: "jp.ghostvoice.audio-capture.reconfigure")

    private var isPrepared = false
    private var isTapped = false
    /// エンジンが動いているか。**`engine.isRunning` の写しではなく、こちらの意思である。**
    /// 再構成（`reconfigure`）が「起こしてよいか」を判断するのに要る。
    private var isAwakeState = false
    private var requestedFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var configurationObserver: (any NSObjectProtocol)?
    private var reconfigurations = 0

    private let levelStream: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation

    /// マイク権限の判定。テストから差し替えられるよう注入する。
    private let authorization: @Sendable () -> MicrophoneAuthorization

    /// 変換に失敗して捨てたバッファの数。
    private let dropped = DroppedBufferCounter()

    public convenience init() {
        self.init(engine: AVAudioEngine())
    }

    /// テストから手動レンダリングのエンジンと権限判定を差し込むための入口。
    ///
    /// 権限判定を注入可能にしてあるのは、**機体の権限状態に依らず
    /// 「未許可なら `prepare()` が投げる」ことを検査できるようにするため**である。
    /// 一度権限を付与した機体では、実際の判定に頼ったテストは永久にスキップされてしまう。
    init(
        engine: AVAudioEngine,
        authorization: @escaping @Sendable () -> MicrophoneAuthorization = {
            MicrophoneAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
        }
    ) {
        self.engine = engine
        self.authorization = authorization
        (levelStream, levelContinuation) = AsyncStream<Float>.makeStream(
            // 溜め込むと、消費者が居ない構成（CLI）でメモリが際限なく増える。
            // 音量インジケータに要るのは常に最新値だけ。
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if isTapped { engine.inputNode.removeTap(onBus: 0) }
        if isPrepared { engine.stop() }
        bufferContinuation?.finish()
        levelContinuation.finish()
    }

    public var level: AsyncStream<Float> { levelStream }

    public var isEngineRunning: Bool { engine.isRunning }

    /// タップが装着されているか（＝いま録っているか）。
    /// `stopTap()` の後は必ず false になる。
    public var isTapping: Bool { lock.withLock { isTapped } }

    /// 形式変換に失敗して**捨てた**バッファの数。
    ///
    /// 「発話を失わないこと」が最優先である以上、捨てた事実は残す。
    /// 入力形式がコンバータと食い違うと `convert` は nil を返す（壊れた音を下流へ流さないため）。
    /// デバイス切り替え直後の短い窓——設定変更の通知が直列キューを経由する間に、
    /// 旧タップが新しい形式のバッファを配る——で現実に起こりうる。
    ///
    /// - Important: **このインスタンスの生涯にわたる累計であり、発話ごとにはリセットされない。**
    ///   `startTap` / `stopTap` でも 0 に戻らない。発話単位の値が要るなら、
    ///   `startTap` の前後で読んで**差分を取ること**（Task 10 の計測はこれに当たる）。
    public var droppedBufferCount: Int { dropped.count }

    /// 設定変更を処理した回数。デバイス切断の再構成が実際に走ったかの確認用。
    var reconfigurationCount: Int { lock.withLock { reconfigurations } }

    // MARK: - ライフサイクル

    public func prepare() throws {
        try lock.withLock {
            guard !isPrepared else { return }

            // **入力ノードへ触れる前に**権限を確かめる。順序を入れ替えてはならない。
            // 未許可のまま `inputNode` に触れると実測 510 秒ブロックしてから返る。
            let status = authorization()
            guard status == .authorized else {
                throw AudioCaptureError.microphoneAccessNotGranted(status)
            }

            _ = engine.inputNode
            engine.prepare()
            do {
                try engine.start()
            } catch {
                throw AudioCaptureError.engineUnavailable
            }
            // **捨て起動。** コールドの初回費用（実測 214.7 ms）をここで払い、
            // 以後の起床を 63.0 ms にする。起動したまま待機しない理由は
            // `AudioCapturing.prepare()` の doc を見ること。
            engine.stop()
            isAwakeState = false
            isPrepared = true
            observeConfigurationChanges()
        }
    }

    public func startTap(format: AVAudioFormat?) throws -> AsyncStream<AVAudioPCMBuffer> {
        lock.lock()
        defer { lock.unlock() }

        guard isPrepared else { throw AudioCaptureError.notPrepared }

        // **寝ていれば起こす。** 呼び出し側に起こす口を持たせない（契約の doc を見ること）。
        try wakeLocked()

        // 前の発話が畳まれていなければ、ここで畳む。放置すると前の消費者が永久に待つ。
        teardownTap(finishStream: true)

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        requestedFormat = format
        bufferContinuation = continuation
        installTap(target: format, continuation: continuation)
        return stream
    }

    public func stopTap() {
        lock.withLock { teardownTap(finishStream: true) }
    }

    public var isAwake: Bool { lock.withLock { isAwakeState } }

    public func sleep() {
        lock.withLock {
            // **タップが張られている間は止めない。** 止めるとその発話が丸ごと消える。
            // 方針側（`DictationSession`）でも塞いでいるが、機構の側にも帯を置く。
            guard isPrepared, isAwakeState, !isTapped else { return }
            engine.stop()
            isAwakeState = false
        }
    }

    /// エンジンを起こす。**呼び出し側は `lock` を保持していること。**
    private func wakeLocked() throws {
        guard !isAwakeState else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioCaptureError.engineUnavailable
        }
        isAwakeState = true
    }

    // MARK: - タップ

    private func installTap(
        target: AVAudioFormat?, continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    ) {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // コンバータの生成は実測 0.013 ms（中央値 / 20 回）なので、
        // 発話ごとに作り直しても NFR-P1 の予算には影響しない。
        let converter = target.flatMap { AVAudioConverter(from: inputFormat, to: $0) }
        self.converter = converter

        // ブロックは self を掴まない。値でキャプチャしたものだけを触る。
        let levelContinuation = self.levelContinuation
        let delivery = BufferDelivery(counter: dropped, converter: converter, target: target)
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat) { buffer, _ in
            levelContinuation.yield(Self.rms(of: buffer))
            guard let deliverable = delivery.prepared(buffer) else { return }
            continuation.yield(deliverable)
        }
        isTapped = true
    }

    /// タップを外し、末尾を配る。
    ///
    /// **順序が意味を持つ。** `removeTap` は保留中の端数バッファをブロックへ一度だけ
    /// 配ってから返る（実測: 48000 フレームを流して removeTap 前 43200 / 後 48000）。
    /// さらにリサンプラは内部に遅延ぶんを抱えるため、`drain` で吐き出させる
    /// （実測: 48 kHz→16 kHz で 231 フレーム＝14.4 ms）。
    /// `finish()` を先に呼ぶと、この末尾はすべて捨てられる。
    private func teardownTap(finishStream: Bool) {
        if isTapped {
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false

            if let converter, let target = requestedFormat,
               let tail = Self.drain(converter, to: target), tail.frameLength > 0 {
                bufferContinuation?.yield(tail)
            }
            converter = nil
        }
        if finishStream {
            bufferContinuation?.finish()
            bufferContinuation = nil
            requestedFormat = nil
        }
    }

    // MARK: - デバイス切断（設定変更）

    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            reconfigurationQueue.async { self.reconfigure() }
        }
    }

    /// 入力デバイスが変わったときにエンジンとタップを組み直す。
    ///
    /// **発話中のストリームは終了させない。** ここで `finish()` すると、
    /// デバイスが切り替わった瞬間に発話が丸ごと失われる。
    private func reconfigure() {
        lock.withLock {
            // **寝ている間は組み直さない。** ここで `engine.start()` すると、
            // 待機中にデバイスが変わっただけで勝手に起きてしまう（オレンジ点が点く）。
            // 入力形式の変化は、次に起きるとき `installTap` が
            // `outputFormat(forBus:)` を読み直すので自然に追従する。
            guard isPrepared, isAwakeState else { return }
            reconfigurations += 1

            let wasTapped = isTapped
            let target = requestedFormat
            // 末尾は配る。ただしストリームは終了させない。
            teardownTap(finishStream: false)

            if !engine.isRunning {
                engine.prepare()
                try? engine.start()
            }

            // 入力形式が変わっている可能性があるので、コンバータごと作り直す。
            if wasTapped, let continuation = bufferContinuation {
                requestedFormat = target
                installTap(target: target, continuation: continuation)
            }
        }
    }

    /// 保留中の設定変更処理が終わるまで待つ（テスト用）。
    /// `reconfigurationQueue` は直列なので、ここまで届けば前の処理は完了している。
    func waitForReconfiguration() async {
        await withCheckedContinuation { continuation in
            reconfigurationQueue.async { continuation.resume() }
        }
    }

    // MARK: - 変換と音量

    /// `buffer` を `format` へ変換する。
    ///
    /// 出力容量は `フレーム数 × レート比 + 1`。実測で 1〜4000 フレームのどこでも
    /// 不足しないことを確認済み（ちょうど容量に達する n は存在するため、+1 は削れない）。
    static func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat
    ) -> sending AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? Self.detached(output) : nil
    }

    /// 領域解析を通すための受け渡し。
    ///
    /// タップのブロックは `@Sendable` なので、そこで得たバッファをそのまま
    /// `continuation.yield(_:)`（`sending` を要求する）へ渡せない。
    /// **バッファの複製はしていない。** Task 5 が手動レンダリングで検証したとおり、
    /// タップは毎回別オブジェクト・別ポインタを渡してくるため、
    /// 保持したバッファが後続の呼び出しで書き換わることはない。
    @inline(__always)
    static func detached(_ buffer: AVAudioPCMBuffer) -> sending AVAudioPCMBuffer {
        nonisolated(unsafe) let detached = buffer
        return detached
    }

    /// リサンプラが内部に抱えている末尾を吐き出させる。
    ///
    /// これを呼ばないと、発話の末尾がレート比に応じたぶんだけ失われる
    /// （48 kHz→16 kHz で 231 フレーム＝14.4 ms、44.1 kHz→16 kHz で 111 フレーム）。
    static func drain(_ converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else { return nil }
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        return error == nil ? output : nil
    }

    /// 直近バッファの RMS（二乗平均平方根）。
    /// Float32 でないバッファでは 0 を返す（入力ノードは常に Float32）。
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return (sum / Float(count)).squareRoot()
    }
}

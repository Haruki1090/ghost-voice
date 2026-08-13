import Foundation
import AVFAudio
import Speech

/// 認識テストが要る資産（音声フィクスチャと ja-JP のモデル）の所在を束ねる。
enum SpeechFixtures {

    /// `Tests/Fixtures/`。テストターゲットの外に置く。中に入れると SwiftPM が
    /// 「unhandled files」を警告し、解消には `Package.swift` の変更が要るため。
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Support
            .deletingLastPathComponent()      // GhostVoiceCoreTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures")
    }

    static var audioURL: URL { directory.appendingPathComponent("jp-meeting.aiff") }

    static var audioExists: Bool {
        FileManager.default.fileExists(atPath: audioURL.path)
    }

    static func referenceText() throws -> String {
        try String(contentsOf: directory.appendingPathComponent("jp-meeting.txt"), encoding: .utf8)
    }

    // MARK: - 肉声（V-1）

    /// V-1 の本来の検証対象は肉声である。合成音声（`say -v Kyoko`）は発話が均質すぎて、
    /// 実利用の精度を代表しない。録音は個人の音声データであり、リポジトリには含めない。
    ///
    /// 手順:
    /// 1. `Tests/Fixtures/live-voice.txt` に読み上げる原稿を書く（1 分程度）
    /// 2. その原稿を読み上げて `Tests/Fixtures/live-voice.aiff` として録音する
    /// 3. `swift test --filter LiveVoice` を実行する
    static var liveVoiceAudioURL: URL { directory.appendingPathComponent("live-voice.aiff") }
    static var liveVoiceTextURL: URL { directory.appendingPathComponent("live-voice.txt") }

    static var liveVoiceExists: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: liveVoiceAudioURL.path)
            && fm.fileExists(atPath: liveVoiceTextURL.path)
    }

    static func liveVoiceReferenceText() throws -> String {
        try String(contentsOf: liveVoiceTextURL, encoding: .utf8)
    }

    static var liveVoiceIsReady: Bool {
        get async {
            guard liveVoiceExists else { return false }
            return await modelInstalled(locale: Locale(identifier: "ja-JP"))
        }
    }

    /// モデル資産のダウンロードを起こさずに導入済みかを見る。
    /// `AssetInventory.status` は reserve 前だと常に `.supported` を返すため使えない。
    static func modelInstalled(locale: Locale) async -> Bool {
        guard let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale),
              let speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return false }
        let dictation = await DictationTranscriber.installedLocales.map(\.identifier)
        let speech = await SpeechTranscriber.installedLocales.map(\.identifier)
        return dictation.contains(dictationLocale.identifier) && speech.contains(speechLocale.identifier)
    }

    /// 音声フィクスチャと ja-JP の両モデルが揃っているか。
    static var isReady: Bool {
        get async {
            guard audioExists else { return false }
            return await modelInstalled(locale: Locale(identifier: "ja-JP"))
        }
    }

    /// フィクスチャを認識器の要求形式へ変換し、`limitSeconds` 秒ぶんのバッファ列にする。
    /// マイク入力（Task 7）の代わりに、ストリーミング経路へ供給するために使う。
    static func buffers(
        from url: URL, to target: AVAudioFormat, chunkSeconds: Double = 0.1, limitSeconds: Double? = nil
    ) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let converter = AVAudioConverter(from: source, to: target) else { return [] }

        let chunk = AVAudioFrameCount(source.sampleRate * chunkSeconds)
        let limitFrames = limitSeconds.map { AVAudioFramePosition($0 * source.sampleRate) } ?? file.length
        let lastFrame = min(limitFrames, file.length)
        var out: [AVAudioPCMBuffer] = []

        // `AVAudioFile.read` は EOF で 0 フレームを返さず nilError を投げる。手前で止める。
        while file.framePosition < lastFrame {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk) else { break }
            try file.read(into: inBuf, frameCount: chunk)
            if inBuf.frameLength == 0 { break }

            let ratio = target.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }

            var conversionError: NSError?
            // 入力ブロックは `convert` の内部から同期的に呼ばれるが、宣言は `@Sendable`
            // であるため、そのままだとキャプチャが並行実行とみなされる。
            nonisolated(unsafe) let input = inBuf
            nonisolated(unsafe) var supplied = false
            let status = converter.convert(to: outBuf, error: &conversionError) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error, let conversionError { throw conversionError }
            if outBuf.frameLength > 0 { out.append(outBuf) }
        }
        return out
    }

    /// `Transcribing.feed(_:)` は `sending` を要求する。配列に保持したバッファは
    /// 一意所有ではないためそのまま渡せない。供給の直前に複製して所有権を渡す。
    /// 実運用では AudioCapture がタップごとに新しいバッファを作るため複製は要らない。
    static func detachedCopy(of source: AVAudioPCMBuffer) -> sending AVAudioPCMBuffer {
        // 先に値型（バイト列）へ写し取る。source から辿れるポインタを複製側へ
        // 触れさせると、領域解析が両者を同じ領域と見なして `sending` を拒む。
        let format = source.format
        let frameCapacity = source.frameCapacity
        let frameLength = source.frameLength
        let payload: [[UInt8]] = {
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: source.audioBufferList))
            return list.map { buffer in
                guard let data = buffer.mData else { return [] }
                return Array(UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize)))
            }
        }()

        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
        else { fatalError("バッファの確保に失敗した") }
        copy.frameLength = frameLength

        let copyList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(payload.count, copyList.count) {
            guard let destination = copyList[index].mData, !payload[index].isEmpty else { continue }
            payload[index].withUnsafeBytes { bytes -> Void in
                guard let base = bytes.baseAddress else { return }
                memcpy(destination, base, min(bytes.count, Int(copyList[index].mDataByteSize)))
            }
        }
        return copy
    }
}

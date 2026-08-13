import Foundation
import AVFAudio
import Speech

/// `SpeechAnalyzer` による認識器。
///
/// **モジュールは発話ごとに作り直す。** `SpeechModule` のインスタンスは 1 つの
/// `SpeechAnalyzer` にしか装着できず、2 つ目へ渡すと
/// `SpeechAnalyzer.setWorkers(for:reusingFrom:preservingFunctionOf:)` の内部で
/// 異常終了する（実測）。モデル本体は `modelRetention: .processLifetime` が
/// プロセス内に保持するため、作り直しの費用はモジュール生成のみで済む。
public actor SpeechAnalyzerTranscriber: Transcribing {

    /// `prepare` で確定する正規形のロケール。nil は未準備を表す。
    private var locale: Locale?
    private var kind: TranscriberKind = .dictation
    private var audioFormat: AVAudioFormat?
    private var session: Session?

    private struct Session {
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
    }

    /// NFR-P3。モデルをプロセス内に保持し、発話ごとのロードを避ける。
    private static let options = SpeechAnalyzer.Options(
        priority: .userInitiated, modelRetention: .processLifetime
    )

    public init() {}

    // MARK: - 準備

    public func prepare(locale requested: Locale, kind: TranscriberKind) async throws {
        guard let normalized = await TranscriptionModule.supportedLocale(equivalentTo: requested, kind: kind)
        else { throw TranscriptionError.localeUnsupported(requested.identifier) }

        // 確保が先。`AssetInventory.status` は未確保のロケールに対して常に `.supported` を
        // 返すため、順序を逆にすると導入済みのモデルでもダウンロードを試みてしまう（実測）。
        try await Self.reserve(normalized)

        let module = TranscriptionModule.make(locale: normalized, kind: kind)
        try await Self.installAssetsIfNeeded(for: module)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.speechModule])
        else { throw TranscriptionError.modelUnavailable }

        self.locale = normalized
        self.kind = kind
        self.audioFormat = format
    }

    public var requiredAudioFormat: AVAudioFormat? {
        get async { audioFormat }
    }

    private static func reserve(_ locale: Locale) async throws {
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch let error as NSError where error.domain == SFSpeechErrorDomain {
            switch error.code {
            case SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue:
                throw TranscriptionError.localeReservationLimitReached
            case SFSpeechError.Code.cannotAllocateUnsupportedLocale.rawValue:
                throw TranscriptionError.localeUnsupported(locale.identifier)
            default:
                throw error
            }
        }
    }

    private static func installAssetsIfNeeded(for module: TranscriptionModule) async throws {
        guard await AssetInventory.status(forModules: [module.speechModule]) != .installed else { return }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module.speechModule])
        else { throw TranscriptionError.modelUnavailable }
        try await request.downloadAndInstall()
    }

    // MARK: - ストリーミング

    public func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        guard let locale, let audioFormat else { throw TranscriptionError.notPrepared }

        // ESC による中断など `finish()` を経ない終わり方でも次の発話が始められるようにする。
        await cancelActiveSession()

        let module = TranscriptionModule.make(locale: locale, kind: kind)
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            inputSequence: input, modules: [module.speechModule], options: Self.options
        )

        do {
            try await analyzer.prepareToAnalyze(in: audioFormat)
        } catch {
            continuation.finish()
            throw error
        }

        session = Session(analyzer: analyzer, continuation: continuation)
        return module.updates()
    }

    public func feed(_ buffer: sending AVAudioPCMBuffer) async {
        session?.continuation.yield(AnalyzerInput(buffer: buffer))
    }

    public func finish() async throws {
        guard let session else { return }
        self.session = nil
        session.continuation.finish()
        try await session.analyzer.finalizeAndFinishThroughEndOfInput()
    }

    private func cancelActiveSession() async {
        guard let session else { return }
        self.session = nil
        session.continuation.finish()
        await session.analyzer.cancelAndFinishNow()
    }

    // MARK: - ファイル入力（テストと精度計測用）

    public func transcribeFile(at url: URL) async throws -> String {
        guard let locale else { throw TranscriptionError.notPrepared }

        let module = TranscriptionModule.make(locale: locale, kind: kind)
        let file = try AVAudioFile(forReading: url)

        // 結果の消費を先に立てておく必要はない（実測では取りこぼさない）が、
        // 解析の完了を待ってから消費を始めると、その間の結果を保持し続ける必要が出る。
        let collector = Task {
            var accumulated = ""
            for try await update in module.updates() {
                if case .final(let text) = update { accumulated += text }
            }
            return accumulated
        }

        do {
            let analyzer = try await SpeechAnalyzer(
                inputAudioFile: file, modules: [module.speechModule],
                options: Self.options, finishAfterFile: true
            )
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }

        return try await collector.value
    }
}

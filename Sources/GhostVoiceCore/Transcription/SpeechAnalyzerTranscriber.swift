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

    /// 直近の `prepare` がモデルのダウンロードを要求したか。
    /// 導入済みのロケールに対して要求してしまう順序の誤りを検出するために公開する
    /// （`AssetInventory.status` は確保前だと常に `.supported` を返すため、
    /// 確保より先に状態を見ると導入済みでもダウンロード経路へ入る）。
    public private(set) var didRequestAssetInstallation = false

    private struct Session {
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
    }

    /// NFR-P3。モデルをプロセス内に保持し、発話ごとのロードを避ける。
    private static let options = SpeechAnalyzer.Options(
        priority: .userInitiated, modelRetention: .processLifetime
    )

    /// モデルの導入（ダウンロード）が始まるときに呼ばれる。
    ///
    /// **導入は数分掛かることがあり、その間 `prepare` は戻らない。** 口が無いと、
    /// 利用者には「押しても何も起きない」としか見えない（詳細設計書 §4.3 は
    /// `request.progress` を HUD に出す想定だが、HUD はフェーズ 2）。
    /// フェーズ 1 は「始まったこと」だけを CLI が伝える。
    private let onAssetInstallationStart: (@Sendable () -> Void)?

    /// ロケール枠（上限 5）の確保と解放。**`AssetInventory` を直接呼ぶと検査できない。**
    ///
    /// 実 API は TCC の許可も要らないが、**プロセス全体の状態（確保済みロケールの集合）を
    /// 触るので、検査から回すと他のスイートの解析へ割り込む**（`SpeechDependentTests` の注記）。
    /// 解放の順序という**この製品の欠陥そのもの**を検査で押さえるために継ぎ目を置く。
    protocol LocaleReserving: Sendable {
        func reserve(_ locale: Locale) async throws
        /// - Returns: 実際に解放したか。**正規形でないと失敗する**（詳細設計書 §4.3 の実測）。
        @discardableResult
        func release(_ locale: Locale) async -> Bool
    }

    struct SystemLocaleReservation: LocaleReserving {
        func reserve(_ locale: Locale) async throws {
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

        @discardableResult
        func release(_ locale: Locale) async -> Bool {
            await AssetInventory.release(reservedLocale: locale)
            return true
        }
    }

    private let reservation: any LocaleReserving

    /// 導入の進み具合を配る口（調査 A-3 の欠落 5）。**単一消費者。**
    private let installationEvents: AsyncStream<AssetInstallationEvent>
    private let installationContinuation: AsyncStream<AssetInstallationEvent>.Continuation

    public nonisolated var assetInstallation: AsyncStream<AssetInstallationEvent> {
        installationEvents
    }

    public init(onAssetInstallationStart: (@Sendable () -> Void)? = nil) {
        self.init(
            onAssetInstallationStart: onAssetInstallationStart,
            reservation: SystemLocaleReservation(), assetInstaller: nil)
    }

    /// モデル資産の導入を差し替える口。**検査のためだけにある。**
    ///
    /// 実物は `AssetInventory` を叩き、**導入されていないロケールでは実際に
    /// ダウンロードを始める。** 枠の解放（下記）を検査するには「確保の後に失敗する」
    /// 状況が要るが、実物でそれを作るとネットワーク越しのダウンロードが走る。
    private let assetInstaller: (@Sendable (TranscriptionModule) async throws -> Bool)?

    init(
        onAssetInstallationStart: (@Sendable () -> Void)? = nil,
        reservation: any LocaleReserving,
        assetInstaller: (@Sendable (TranscriptionModule) async throws -> Bool)? = nil
    ) {
        self.onAssetInstallationStart = onAssetInstallationStart
        self.reservation = reservation
        self.assetInstaller = assetInstaller
        (installationEvents, installationContinuation) =
            AsyncStream<AssetInstallationEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    // MARK: - 準備

    /// **枠を返す責任はここにある**（持ち越し項目 5）。
    ///
    /// フェーズ 1 は `AssetInventory.release(reservedLocale:)` を 1 度も呼んでいなかった。
    /// 帰結は 2 つで、どちらも**プロセスを再起動するまで回復しない。**
    ///
    /// 1. **`reserve` の後に失敗した `prepare` が枠を返さない。** 設定画面から
    ///    ロケールを変えて失敗するたびに枠が 1 つ減る。
    /// 2. **成功しても前のロケールの枠を返さない。** 変えるたびに 1 つ減る。
    ///
    /// **相異なるロケールを 5 種類試すと `localeReservationLimitReached` に達し、
    /// 以後どのロケールにも切り替えられなくなる。** 利用者から見えるのは
    /// 「言語を切り替えたのにエラーが出て、元の言語のまま動き続ける」である。
    ///
    /// - Important: **同じロケールへの `prepare` では何も解放しない。**
    ///   `reserve` は同一ロケールの 2 回目以降で枠を消費しない（詳細設計書 §4.3 の実測）ので、
    ///   解放してから確保し直す形にすると**成功する経路で枠を手放す窓**ができる。
    /// - Important: **解放は「新しいロケールの準備が全部成功してから」行う。**
    ///   先に返すと、途中で失敗したときに**古いロケールでも動けない**状態になる
    ///   （`self.locale` は最後に代入されるので、失敗しても前の設定で録音は続く）。
    public func prepare(locale requested: Locale, kind: TranscriberKind) async throws {
        guard let normalized = await TranscriptionModule.supportedLocale(equivalentTo: requested, kind: kind)
        else { throw TranscriptionError.localeUnsupported(requested.identifier) }

        let previous = self.locale

        // 確保が先。`AssetInventory.status` は未確保のロケールに対して常に `.supported` を
        // 返すため、順序を逆にすると導入済みのモデルでもダウンロードを試みてしまう（実測）。
        try await reservation.reserve(normalized)

        do {
            let module = TranscriptionModule.make(locale: normalized, kind: kind)
            if let assetInstaller {
                didRequestAssetInstallation = try await assetInstaller(module)
            } else {
                didRequestAssetInstallation = try await installAssetsIfNeeded(for: module)
            }

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.speechModule])
            else { throw TranscriptionError.modelUnavailable }

            self.locale = normalized
            self.kind = kind
            self.audioFormat = format
        } catch {
            // **確保した枠を返してから投げる。** 返さないと、設定画面で
            // 失敗を繰り返した利用者が回復不能になる。
            if normalized != previous { await reservation.release(normalized) }
            throw error
        }

        // 成功した。**古いロケールの枠を返す。**
        if let previous, previous != normalized { await reservation.release(previous) }
    }

    public var requiredAudioFormat: AVAudioFormat? {
        get async { audioFormat }
    }

    /// 戻り値はダウンロードを要求したか。導入済みなら false。
    ///
    /// **導入は数分掛かることがあり、その間この関数は戻らない。** 進み具合を
    /// `assetInstallation` へ流すのはそのためである（調査 A-3 の欠落 5）。
    ///
    /// - Important: **進捗の取得に失敗しても導入は止めない。** 進捗は表示のためのもので、
    ///   取れないことは導入の失敗ではない。
    private func installAssetsIfNeeded(for module: TranscriptionModule) async throws -> Bool {
        guard await AssetInventory.status(forModules: [module.speechModule]) != .installed else { return false }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module.speechModule])
        else { throw TranscriptionError.modelUnavailable }
        // **待ちに入る前に知らせる。** 戻ってから言っても意味が無い。
        onAssetInstallationStart?()
        installationContinuation.yield(.started)

        // `Progress` は KVO で更新される。**ここは `NSApp.run()` が無い文脈でも動く必要が
        // あるので、監視ではなく定期的な読み取りにしてある**（CLI からも呼ばれる）。
        let progress = request.progress
        let continuation = installationContinuation
        let poll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                continuation.yield(.progress(progress.fractionCompleted))
            }
        }
        defer { poll.cancel() }

        do {
            try await request.downloadAndInstall()
        } catch {
            installationContinuation.yield(.failed)
            throw error
        }
        installationContinuation.yield(.completed)
        return true
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

    /// 音声バッファを供給する。
    ///
    /// **`begin()` が返る前に来たバッファは黙って捨てられる**（セッションがまだ無いため）。
    /// エラーにも記録にもならない。`begin()` の実測は 1.2〜1.4 ms なので通常は問題にならないが、
    /// 呼び出し側は `begin()` の完了を待ってからタップを装着すること。
    /// 待たずに流すと発話の頭が落ちる（PTT で最も起こりやすい失敗）。
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

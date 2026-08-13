import Foundation
import AVFAudio
import Speech

/// 認識モジュールは `DictationTranscriber` と `SpeechTranscriber` の 2 種類。
///
/// 両者は `SpeechModule` に準拠するが、書き起こし文字列を持つのは各々の `Result` 型であり、
/// プロトコル側（`SpeechModuleResult`）は `range` と `resultsFinalizationTime` しか公開しない。
/// つまり `any SpeechModule` として持つとテキストが取り出せない。
/// 列挙で持つことで、種別の取りこぼしをコンパイラに検出させる。
enum TranscriptionModule {
    case dictation(DictationTranscriber)
    case speech(SpeechTranscriber)

    /// PTT の 1 発話は数秒の短文であり、HUD のライブ表示（FR-2）に暫定結果が要る。
    static let dictationPreset: DictationTranscriber.Preset = .progressiveShortDictation
    static let speechPreset: SpeechTranscriber.Preset = .progressiveTranscription

    static func make(locale: Locale, kind: TranscriberKind) -> TranscriptionModule {
        switch kind {
        case .dictation: .dictation(DictationTranscriber(locale: locale, preset: dictationPreset))
        case .speech: .speech(SpeechTranscriber(locale: locale, preset: speechPreset))
        }
    }

    /// `SpeechAnalyzer` と `AssetInventory` へ渡すための型消去。
    var speechModule: any SpeechModule {
        switch self {
        case .dictation(let module): module
        case .speech(let module): module
        }
    }

    /// 種別ごとに対応するロケール正規形（`ja-JP` → `ja_JP`）。未対応なら nil。
    static func supportedLocale(equivalentTo locale: Locale, kind: TranscriberKind) async -> Locale? {
        switch kind {
        case .dictation: await DictationTranscriber.supportedLocale(equivalentTo: locale)
        case .speech: await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        }
    }

    /// 結果列を `TranscriptionUpdate` へ変換する。
    ///
    /// **1 つのモジュールにつき 1 度しか呼んではならない。** `module.results` は
    /// 単一消費者しか許さず、2 つ目の消費者を立てると
    /// 「attempt to await next() on more than one task」で異常終了する（実測）。
    func updates() -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        switch self {
        case .dictation(let module): Self.updates(from: module.results)
        case .speech(let module): Self.updates(from: module.results)
        }
    }

    private static func updates<S>(from results: S) -> AsyncThrowingStream<TranscriptionUpdate, Error>
    where S: AsyncSequence & Sendable, S.Element: TextBearingResult, S.Failure == any Error {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in results {
                        let text = String(result.text.characters)
                        continuation.yield(result.isFinal ? .final(text) : .volatile(text))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 2 つの `Result` 型が共通して持つが、`SpeechModuleResult` には無いもの。
/// `isFinal` は `SpeechModuleResult` の extension が供給する。
private protocol TextBearingResult {
    var text: AttributedString { get }
    var isFinal: Bool { get }
}

extension DictationTranscriber.Result: TextBearingResult {}
extension SpeechTranscriber.Result: TextBearingResult {}

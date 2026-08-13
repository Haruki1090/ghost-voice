import Foundation
import AVFAudio

public enum TranscriptionUpdate: Sendable, Equatable {
    /// 認識途中の暫定結果。後続の入力で書き換わる。HUD 表示用。
    case volatile(String)
    /// 確定結果。
    case final(String)
}

public protocol Transcribing: AnyObject, Sendable {
    /// モデルの導入確認とアナライザの事前準備を行う。起動時とロケール変更時に呼ぶ。
    func prepare(locale: Locale, kind: TranscriberKind) async throws

    /// 認識器が要求する音声形式。AudioCapture 側の変換に使う。
    var requiredAudioFormat: AVAudioFormat? { get async }

    /// 1 回の発話を開始する。
    func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error>

    /// 音声バッファを供給する。
    func feed(_ buffer: sending AVAudioPCMBuffer) async

    /// 入力終了を通知し、確定処理を待つ。
    func finish() async throws
}

public enum TranscriptionError: Error, Equatable {
    case notPrepared
    case localeUnsupported(String)
    case modelUnavailable
    /// `AssetInventory` の確保上限（5 ロケール）に達した。
    /// 確保はプロセス内で解放しない限り残るため、ロケールを繰り返し替えると起こりうる。
    case localeReservationLimitReached
}

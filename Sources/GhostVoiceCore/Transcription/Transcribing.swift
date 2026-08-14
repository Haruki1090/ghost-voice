import Foundation
import AVFAudio

public enum TranscriptionUpdate: Sendable, Equatable {
    /// 認識途中の暫定結果。後続の入力で書き換わる。HUD 表示用。
    case volatile(String)
    /// 確定結果。
    case final(String)
}

/// モデル資産の導入（ダウンロード）の進み具合（調査 A-3 の欠落 5）。
///
/// **導入は数分掛かることがあり、その間 `prepare` は戻らない。** フェーズ 1 は
/// 「始まった」の 1 回きりしか出せず、利用者には「押しても何も起きない」としか
/// 見えなかった（`SpeechAnalyzerTranscriber.onAssetInstallationStart` の注記）。
public enum AssetInstallationEvent: Sendable, Equatable {
    /// ダウンロードが始まった。**ここから `.completed` / `.failed` までは戻らない。**
    case started
    /// 進み具合（0.0〜1.0）。**等間隔にも単調にも来ると仮定しないこと。**
    /// 相手が進捗を報告しない場合は 1 件も来ない。
    case progress(Double)
    /// 導入が終わった。
    case completed
    /// 導入に失敗した。**理由は載せない**（`prepare` が投げるエラーが正である）。
    case failed
}

public protocol Transcribing: AnyObject, Sendable {
    /// モデルの導入確認とアナライザの事前準備を行う。起動時とロケール変更時に呼ぶ。
    func prepare(locale: Locale, kind: TranscriberKind) async throws

    /// モデル導入の進み具合（欠落 5）。
    ///
    /// - Important: **単一消費者である。** `DictationSession` が 1 人で読んで
    ///   `assetInstallationEvents()` へ配り直すので、**UI はそちらを見ること。**
    /// - Note: 既定は「何も報告しない」。導入を伴わない代役は実装しなくてよい。
    var assetInstallation: AsyncStream<AssetInstallationEvent> { get }

    /// 認識器が要求する音声形式。AudioCapture 側の変換に使う。
    var requiredAudioFormat: AVAudioFormat? { get async }

    /// 1 回の発話を開始する。
    func begin() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error>

    /// 音声バッファを供給する。
    func feed(_ buffer: sending AVAudioPCMBuffer) async

    /// 入力終了を通知し、確定処理を待つ。
    func finish() async throws
}

extension Transcribing {
    /// 既定は「何も報告しない」。**即座に終端したストリームを返す**——
    /// 待たせると、進捗を購読した UI が永久に止まる。
    public var assetInstallation: AsyncStream<AssetInstallationEvent> {
        AsyncStream { $0.finish() }
    }
}

public enum TranscriptionError: Error, Equatable {
    case notPrepared
    case localeUnsupported(String)
    case modelUnavailable
    /// `AssetInventory` の確保上限（5 ロケール）に達した。
    /// 確保はプロセス内で解放しない限り残るため、ロケールを繰り返し替えると起こりうる。
    case localeReservationLimitReached
}

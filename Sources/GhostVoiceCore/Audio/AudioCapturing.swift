import AVFAudio
import AVFoundation
import Foundation

/// マイク権限の状態。`AVAuthorizationStatus` を `Sendable` な値として写し取ったもの。
public enum MicrophoneAuthorization: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized

    public init(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorized: self = .authorized
        @unknown default: self = .denied
        }
    }
}

public enum AudioCaptureError: Error, Equatable {
    /// `prepare()` を経ずに `startTap(format:)` を呼んだ。
    case notPrepared
    /// `AVAudioEngine.start()` が失敗した。
    case engineUnavailable
    /// マイク権限が `.authorized` でない。
    ///
    /// **未許可のまま入力ノードへ触れてはならない。** 権限が `notDetermined` の
    /// プロセスで `AVAudioEngine.inputNode` に触れると、**実測 510 秒ブロックしてから
    /// 返る**（2026-08-14 / M3 / macOS 26.5.2。バンドルされていない CLI プロセスで計測）。
    /// 権限は付与されないまま返るので、そのまま進めても無音を録り続けることになる。
    /// `prepare()` はここで先に弾き、8 分半のフリーズを即時のエラーへ変える。
    case microphoneAccessNotGranted(MicrophoneAuthorization)
}

public protocol AudioCapturing: AnyObject, Sendable {
    /// エンジンを起動し、常時ウォーム状態にする。アプリ起動時に一度だけ呼ぶ。
    /// 録音開始のたびに起動すると NFR-P1（50 ms 以内）を満たせない。
    func prepare() throws

    /// タップを装着してバッファの供給を開始する。
    /// `format` が nil なら入力ノードの形式をそのまま流す。
    ///
    /// `stopTap()` を経ずに呼び直した場合、前のストリームは
    /// （供給済みのバッファを配り切った上で）終了する。
    func startTap(format: AVAudioFormat?) throws -> AsyncStream<AVAudioPCMBuffer>

    /// タップを外す。エンジンは止めない。
    func stopTap()

    /// 直近バッファの RMS。HUD の音量インジケータ用。
    ///
    /// - Important: **消費者は 1 つに限ること。** `AsyncStream` は複数の
    ///   `next()` を同時に待つと異常終了する。
    var level: AsyncStream<Float> { get }
}

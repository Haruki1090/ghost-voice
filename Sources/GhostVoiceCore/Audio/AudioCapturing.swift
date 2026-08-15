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
    /// 権限を確かめ、**捨て起動を 1 往復してから寝た状態で返る**。アプリ起動時に一度だけ呼ぶ。
    ///
    /// 捨て起動（`start` → 即 `stop`）を通すのは、**プロセス初回のコールド費用を
    /// 起動時に払っておくため**である。実測 コールド 214.7 ms 対 2 回目以降 63.0 ms
    /// （2026-08-15 / M3 / macOS 26.5.2 / n=20）。これを払わないと、
    /// **起動後の最初の押下だけが 214.7 ms の頭欠けを負う。**
    ///
    /// - Important: **戻った時点でエンジンは動いていない**（`isAwake == false`）。
    ///   起動したまま待機すると `coreaudiod` に常時 +15 ポイント
    ///   （19.6〜20.3% 対 4.3〜4.8%）を課し、マイクのオレンジ点が消えない。
    func prepare() throws

    /// タップを装着してバッファの供給を開始する。
    /// `format` が nil なら入力ノードの形式をそのまま流す。
    ///
    /// **寝ていれば自分で起こす**（実測 中央値 63.0 ms / 最大 129.6 ms）。
    /// 呼び出し側が起きているかを気にする必要はない——**「起こす」口を公開しないのは、
    /// 起こし忘れを型として作れなくするためである。**
    ///
    /// `stopTap()` を経ずに呼び直した場合、前のストリームは
    /// （供給済みのバッファを配り切った上で）終了する。
    func startTap(format: AVAudioFormat?) throws -> AsyncStream<AVAudioPCMBuffer>

    /// タップを外す。**エンジンは止めない。**
    ///
    /// 発話のたびに止めると、次の押下が毎回 63 ms の起床を払う。
    /// 止めるのは `sleep()` の役目であり、いつ止めるかは呼び出し側の方針である。
    func stopTap()

    /// エンジンを止める。**マイクのオレンジ点が消えるのはここだけである。**
    ///
    /// - Important: **タップが張られている間は何もしない。** 録音中に止めると
    ///   その発話が丸ごと消えるため、機構の側でも塞いでおく。
    /// - Important: **冪等。** 寝ている状態で呼んでも、`prepare()` の前に呼んでも何も起きない。
    func sleep()

    /// エンジンが動いているか。**タップの有無とは別の量である**——
    /// マイクの使用状態（オレンジ点）を決めるのはタップではなくエンジンの方である
    /// （2026-08-15 の実測。設計書 §2.1）。
    var isAwake: Bool { get }

    /// 直近バッファの RMS。HUD の音量インジケータ用。
    ///
    /// - Important: **消費者は 1 つに限ること。** `AsyncStream` は複数の
    ///   `next()` を同時に待つと異常終了する。
    /// - Note: 寝ている間は流れない。**ただし終端はしない**（畳むと配り係が死ぬ）。
    var level: AsyncStream<Float> { get }

    /// 形式変換に失敗して**捨てた**バッファの数。
    ///
    /// - Important: **インスタンス生涯の累計であり、発話ごとにはリセットされない。**
    ///   発話単位の値が要る場合は録音の前後で読んで差分を取ること
    ///   （`DictationSession` が `Metrics.Sample.droppedBuffers` でそれを行う）。
    ///   `sleep()` や起床でも 0 に戻らない。
    var droppedBufferCount: Int { get }
}

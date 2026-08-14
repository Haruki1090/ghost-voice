import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// いま照会できる権限の一式。
///
/// **実 API を呼ぶのは `PermissionProbes.system` だけ。** ここは値だけを持つ
/// （機体の権限状態に左右されずに文言を検査できるようにするため）。
///
/// **CLI と `.app` で同じ型を使う。** 案内の文言は起動経路で変わる
/// （許可の相手がターミナルアプリか `Ghost Voice` か）が、**照会する量は同じ**である。
/// 型を 2 つ持つと、片方だけに項目が増えたときに気づけない。
public struct PermissionStatus: Sendable, Equatable {
    /// `AVCaptureDevice.authorizationStatus(for: .audio)` の名前（`kTCCServiceMicrophone`）。
    public let microphoneStatus: String
    public let microphoneAuthorized: Bool
    /// `AXIsProcessTrusted()`（アクセシビリティ = `kTCCServiceAccessibility`）。
    public let accessibilityTrusted: Bool
    /// `CGPreflightListenEventAccess()`（入力監視 = `kTCCServiceListenEvent`）。
    public let listenEventAccess: Bool
    /// `CGPreflightPostEventAccess()`（⌘V の送出 = `kTCCServicePostEvent`）。
    public let postEventAccess: Bool
    /// `IsSecureEventInputEnabled()`。**TCC ではない**（いまこの瞬間の実行時の状態）。
    public let secureInputEnabled: Bool
    /// `Bundle.main.bundleIdentifier`。**`nil` なら `.app` から起動していない。**
    ///
    /// `nil` の状態は「ターミナルの許可を借りて動いている」ことを意味し、
    /// **Finder から起動したときとは別の結果になる**（`app-bundle.md` §5.1）。
    /// 切り分け不能な状態なので、案内でそのことを言う。
    public let bundleIdentifier: String?

    public init(
        microphoneStatus: String,
        microphoneAuthorized: Bool,
        accessibilityTrusted: Bool,
        listenEventAccess: Bool,
        postEventAccess: Bool,
        secureInputEnabled: Bool,
        bundleIdentifier: String? = nil
    ) {
        self.microphoneStatus = microphoneStatus
        self.microphoneAuthorized = microphoneAuthorized
        self.accessibilityTrusted = accessibilityTrusted
        self.listenEventAccess = listenEventAccess
        self.postEventAccess = postEventAccess
        self.secureInputEnabled = secureInputEnabled
        self.bundleIdentifier = bundleIdentifier
    }
}

/// 権限の照会そのもの。**実 API を名指しで呼ぶのはここだけである。**
///
/// ## なぜ 1 箇所に閉じ込めるのか
///
/// 基本設計書 §10 が明記している——
/// `AXUIElement` 系 API は `kTCCServiceAccessibility`、`CGEvent.post` は
/// `kTCCServicePostEvent`、`CGEvent.tapCreate` は `kTCCServiceListenEvent` という
/// **それぞれ別の TCC サービス**を使う。**どれか 1 つを他の判定に流用してはならない。**
/// 片方だけ許可された状態は原理的にありうるため、
/// **値が一致する機体では取り違えに気付けない。**
///
/// 照会が 2 実装あると、この規律が**片方だけ守られている状態**を作れてしまう。
/// だから対応表はここ 1 枚だけにし、検査は代役で 4 つを個別に落として確かめる。
///
/// - Note: 差し替え可能にしてあるのは検査のためである。**本番は `.system` 以外を使わない。**
public struct PermissionProbes: Sendable {
    /// `kTCCServiceMicrophone`。
    public var microphoneAuthorization: @Sendable () -> AVAuthorizationStatus
    /// `kTCCServiceAccessibility`。**入力監視やキー送出の判定に流用しない。**
    public var accessibilityTrusted: @Sendable () -> Bool
    /// `kTCCServiceListenEvent`。**アクセシビリティの値で代用しない。**
    public var listenEventAccess: @Sendable () -> Bool
    /// `kTCCServicePostEvent`。**アクセシビリティの値で代用しない。**
    public var postEventAccess: @Sendable () -> Bool
    /// TCC ではない。パスワード欄などで他プロセスが立てる実行時の旗。
    public var secureInputEnabled: @Sendable () -> Bool
    public var bundleIdentifier: @Sendable () -> String?

    public init(
        microphoneAuthorization: @escaping @Sendable () -> AVAuthorizationStatus,
        accessibilityTrusted: @escaping @Sendable () -> Bool,
        listenEventAccess: @escaping @Sendable () -> Bool,
        postEventAccess: @escaping @Sendable () -> Bool,
        secureInputEnabled: @escaping @Sendable () -> Bool,
        bundleIdentifier: @escaping @Sendable () -> String?
    ) {
        self.microphoneAuthorization = microphoneAuthorization
        self.accessibilityTrusted = accessibilityTrusted
        self.listenEventAccess = listenEventAccess
        self.postEventAccess = postEventAccess
        self.secureInputEnabled = secureInputEnabled
        self.bundleIdentifier = bundleIdentifier
    }

    /// 本物。**この 6 行が、4 つの TCC サービスと API の唯一の対応表である。**
    public static let system = PermissionProbes(
        microphoneAuthorization: { AVCaptureDevice.authorizationStatus(for: .audio) },
        accessibilityTrusted: { AXIsProcessTrusted() },
        listenEventAccess: { CGPreflightListenEventAccess() },
        postEventAccess: { CGPreflightPostEventAccess() },
        secureInputEnabled: { IsSecureEventInputEnabled() },
        bundleIdentifier: { Bundle.main.bundleIdentifier }
    )
}

/// 許可を**求める**側の原始操作。**ダイアログが出る。**
///
/// 照会（`PermissionProbes`）と分けてあるのは、
/// **`current()` が 1 つもダイアログを出さない**ことを型の上で見えるようにするためである。
///
/// - Note: **求め方の作法（待つか待たないか・何を表示するか）は呼び出し側が決める。**
///   CLI は人の応答を待って結果を印字し、`.app` は待たない（起動を人の操作に縛らないため）。
///   ここが持つのは API の名指しだけである。
public struct PermissionRequests: Sendable {
    /// マイク。**`.notDetermined` のときだけ意味がある**（拒否済みなら二度と出ない）。
    public var microphone: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    /// 入力監視。**求めるとシステム設定の一覧に載る**（載らないとトグルを見つけられない）。
    public var listenEvent: @Sendable () -> Bool
    /// アクセシビリティ。同じく、求めると一覧に載る。
    public var accessibilityPrompt: @Sendable () -> Bool

    public init(
        microphone: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void,
        listenEvent: @escaping @Sendable () -> Bool,
        accessibilityPrompt: @escaping @Sendable () -> Bool
    ) {
        self.microphone = microphone
        self.listenEvent = listenEvent
        self.accessibilityPrompt = accessibilityPrompt
    }

    public static let system = PermissionRequests(
        microphone: { completion in
            AVCaptureDevice.requestAccess(for: .audio) { completion($0) }
        },
        listenEvent: { CGRequestListenEventAccess() },
        accessibilityPrompt: {
            // `kAXTrustedCheckOptionPrompt` は `var` 宣言なので Swift 6 の並行性検査を
            // 通らない。値は `"AXTrustedCheckOptionPrompt"`（フェーズ 1 で実測済み）。
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    )
}

/// 権限の照会。**CLI と `.app` はどちらもここを通る。**
public enum PermissionInquiry {

    /// 照会だけを行う。**ダイアログは 1 つも出ない。**
    public static func current(probes: PermissionProbes = .system) -> PermissionStatus {
        let microphone = probes.microphoneAuthorization()
        return PermissionStatus(
            microphoneStatus: name(of: microphone),
            microphoneAuthorized: microphone == .authorized,
            accessibilityTrusted: probes.accessibilityTrusted(),
            listenEventAccess: probes.listenEventAccess(),
            postEventAccess: probes.postEventAccess(),
            secureInputEnabled: probes.secureInputEnabled(),
            bundleIdentifier: probes.bundleIdentifier()
        )
    }

    /// マイク権限の呼び名。**利用者に見せる文字列なので 1 箇所に持つ。**
    public static func name(of status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "未確認"
        case .restricted: "制限"
        case .denied: "拒否"
        case .authorized: "許可"
        @unknown default: "不明(\(status.rawValue))"
        }
    }
}

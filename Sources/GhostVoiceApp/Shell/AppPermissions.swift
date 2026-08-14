import AVFoundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// いま照会できる権限の一式（アプリ側）。
///
/// **実 API を呼ぶのは `AppPermissions`。** ここは値だけを持つ
/// （機体の権限状態に左右されずに文言を検査できるようにするため）。
///
/// > **`GhostVoiceCLI.PermissionStatus` と同じ形をしている。**
/// > 同じ型を 2 つ持っているのは、CLI とアプリが別モジュールで、
/// > **共有すべき置き場所（Core）にこの型がまだ無い**ためである。
/// > 統括の裁定待ち（トラック B 報告 §「Core へ移すべきもの」）。
public struct AppPermissionStatus: Sendable, Equatable {
    /// `AVCaptureDevice.authorizationStatus(for: .audio)` の名前。
    public let microphoneStatus: String
    public let microphoneAuthorized: Bool
    /// `AXIsProcessTrusted()`（アクセシビリティ = `kTCCServiceAccessibility`）。
    public let accessibilityTrusted: Bool
    /// `CGPreflightListenEventAccess()`（入力監視 = `kTCCServiceListenEvent`）。
    public let listenEventAccess: Bool
    /// `CGPreflightPostEventAccess()`（⌘V の送出 = `kTCCServicePostEvent`）。
    public let postEventAccess: Bool
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
        bundleIdentifier: String?
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

/// 権限の照会と要求。
///
/// **`current()` は 1 つもダイアログを出さない。** 出るのは `requestMissing()` だけである。
public enum AppPermissions {

    /// 照会だけを行う。**ダイアログは出ない。**
    public static func current() -> AppPermissionStatus {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        return AppPermissionStatus(
            microphoneStatus: name(of: microphone),
            microphoneAuthorized: microphone == .authorized,
            accessibilityTrusted: AXIsProcessTrusted(),
            listenEventAccess: CGPreflightListenEventAccess(),
            postEventAccess: CGPreflightPostEventAccess(),
            secureInputEnabled: IsSecureEventInputEnabled(),
            bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func name(of status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "未確認"
        case .restricted: "制限"
        case .denied: "拒否"
        case .authorized: "許可"
        @unknown default: "不明(\(status.rawValue))"
        }
    }

    /// 足りない許可を要求する。**ダイアログが出る。人が押さないと先へ進まない。**
    ///
    /// **`.app` から呼ぶことに意味がある。** 責任プロセスは自分自身なので、
    /// ここで要求した許可は `Ghost Voice` に付く（`app-bundle.md` §5.1）。
    /// フェーズ 1 のようにターミナルから CLI で要求しても、付くのはターミナルアプリである。
    ///
    /// - マイク: `.notDetermined` のときだけ要求する。**拒否済みなら二度と出ない**ので、
    ///   その場合はシステム設定を開いてもらうしかない（案内は `AppPermissionGuidance`）。
    /// - 入力監視 / アクセシビリティ: 要求すると**システム設定の一覧に載る。**
    ///   載らないと利用者はトグルを見つけられない。**これが要求を出す本当の理由である**
    ///   （その場で許可されることは期待していない）。
    public static func requestMissing() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            // 応答は待たない。**待つと起動が人の操作に縛られる。**
            // 許可されたかは次の照会で判る。
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        if !AXIsProcessTrusted() {
            // `kAXTrustedCheckOptionPrompt` は `var` 宣言なので Swift 6 の並行性検査を通らない。
            // 値は `"AXTrustedCheckOptionPrompt"`（フェーズ 1 で実測済み）。
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    /// システム設定の該当ペインを開く。
    ///
    /// **URL は Apple が公開しているものではない**（`x-apple.systempreferences:` は
    /// 慣例的に使われている経路）。開けなかったときに黙らないよう `Bool` を返す。
    @discardableResult
    public static func openSettings(_ pane: SettingsPane) -> Bool {
        guard let url = URL(string: pane.urlString) else { return false }
        return NSWorkspace.shared.open(url)
    }

    public enum SettingsPane: Sendable, CaseIterable {
        case microphone, accessibility, inputMonitoring

        var urlString: String {
            switch self {
            case .microphone:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .accessibility:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .inputMonitoring:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
        }
    }
}

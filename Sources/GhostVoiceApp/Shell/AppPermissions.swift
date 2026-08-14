import AppKit
import Foundation
import GhostVoiceCore

/// 権限の要求と、システム設定の案内。
///
/// **照会（`PermissionStatus` / `PermissionInquiry.current()`）は `GhostVoiceCore` にある。**
/// 4 つの API と TCC サービスの対応表を 2 つ持つと、
/// 「どれか 1 つを他の判定に流用してはならない」という規律が
/// **片側だけ守られている状態**を作れてしまう（基本設計書 §10）。
/// ここが持つのは**アプリ固有の作法**——応答を待たないこと、設定ペインを開くこと——だけである。
public enum AppPermissions {

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
    public static func requestMissing(
        probes: PermissionProbes = .system, requests: PermissionRequests = .system
    ) {
        if probes.microphoneAuthorization() == .notDetermined {
            // 応答は待たない。**待つと起動が人の操作に縛られる。**
            // 許可されたかは次の照会で判る（CLI はここで人を待つ。作法が違うだけである）。
            requests.microphone { _ in }
        }
        if !probes.listenEventAccess() {
            _ = requests.listenEvent()
        }
        if !probes.accessibilityTrusted() {
            _ = requests.accessibilityPrompt()
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

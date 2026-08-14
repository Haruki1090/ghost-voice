import Foundation
import GhostVoiceCore

/// いま照会できる権限の一式。
///
/// **実 API を呼ぶのは `GhostVoiceRuntime` 側。** ここは値だけを受け取って文章にする
/// （機体の権限状態に左右されずに検査できるようにするため）。
public struct PermissionStatus: Sendable, Equatable {
    /// `AVCaptureDevice.authorizationStatus(for: .audio)` の名前。
    public let microphoneStatus: String
    public let microphoneAuthorized: Bool
    /// `AXIsProcessTrusted()`（アクセシビリティ）。
    public let accessibilityTrusted: Bool
    /// `CGPreflightListenEventAccess()`（入力監視）。
    public let listenEventAccess: Bool
    /// `CGPreflightPostEventAccess()`（⌘V の送出。アクセシビリティで与えられる）。
    public let postEventAccess: Bool
    public let secureInputEnabled: Bool

    public init(
        microphoneStatus: String,
        microphoneAuthorized: Bool,
        accessibilityTrusted: Bool,
        listenEventAccess: Bool,
        postEventAccess: Bool,
        secureInputEnabled: Bool
    ) {
        self.microphoneStatus = microphoneStatus
        self.microphoneAuthorized = microphoneAuthorized
        self.accessibilityTrusted = accessibilityTrusted
        self.listenEventAccess = listenEventAccess
        self.postEventAccess = postEventAccess
        self.secureInputEnabled = secureInputEnabled
    }
}

/// 権限まわりの文言。
///
/// **許可の対象は `ghost-voice` のバイナリではない。**
/// 素の実行ファイルの TCC は責任プロセス（起動元のターミナルアプリ）に紐づく。
/// 一覧へバイナリを足そうとしても現れないので、案内は必ずターミナルアプリを名指しする。
public enum PermissionGuidance {

    static let settingsPath = "システム設定 > プライバシーとセキュリティ"

    public static func message(for error: HotkeyError) -> String {
        switch error {
        case .eventTapNotPermitted(let snapshot):
            return notPermittedMessage(snapshot)
        case .tapDisabledAtStart:
            // **権限の話ではない。** ここへ権限の案内を混ぜると、付け直しの無駄足になる。
            return """
                キーイベントの監視を開始できませんでした（タップが有効になりませんでした）。
                他のキー入力を監視するツールと競合している可能性があります。ghost-voice を
                起動し直しても直らない場合は、常駐している入力系ツールを止めて試してください。
                """
        case .alreadyRunning:
            return "キー監視は既に動いています（内部の誤り）。"
        case .stopped:
            return "キー監視は停止済みで、再開できません。ghost-voice を起動し直してください（内部の誤り）。"
        }
    }

    private static func notPermittedMessage(_ snapshot: TapPermissionSnapshot) -> String {
        var lines = [
            "キーイベントを監視できないため、右 Option の押下を受け取れません。",
            "",
            "**許可するのは ghost-voice ではなく、これを起動しているターミナルアプリです。**",
            "素の実行ファイルの権限は起動元のアプリに紐づくため、一覧に ghost-voice は現れません。",
            "",
        ]

        // **既に許可されている項目を並べない。** 付いているものを付け直させると、
        // 本当に足りないものが埋もれる。
        if !snapshot.listenEventAccess {
            lines.append("- \(settingsPath) > 入力監視 で、ターミナルアプリを許可する（ホットキーに必須）")
        }
        if !snapshot.accessibilityTrusted {
            lines.append("- \(settingsPath) > アクセシビリティ で、ターミナルアプリを許可する（挿入に必要）")
        }
        if snapshot.listenEventAccess && snapshot.accessibilityTrusted {
            // 照会はどちらも許可を示しているのにタップが開けない。
            // 許可の反映にはプロセスの起動し直しが要る（TCC の判断は起動時に固まる）。
            lines.append("照会ではどちらも許可されています。ターミナルアプリを再起動してから試してください。")
        } else {
            lines.append("")
            lines.append("許可を求めるダイアログを出すには `ghost-voice --request-permissions` を実行します。")
            lines.append("許可した後は、ターミナルアプリを再起動してから ghost-voice を起動し直してください。")
        }
        return lines.joined(separator: "\n")
    }

    /// `--check` の出力。
    public static func report(_ status: PermissionStatus, storageRoot: URL) -> String {
        let ready = status.microphoneAuthorized && status.listenEventAccess

        var lines = [
            "Ghost Voice: 権限の状態",
            "",
            row("マイク", status.microphoneAuthorized, "\(settingsPath) > マイク", status.microphoneStatus),
            row("入力監視", status.listenEventAccess, "\(settingsPath) > 入力監視", "ホットキーに必須"),
            row(
                "アクセシビリティ", status.accessibilityTrusted, "\(settingsPath) > アクセシビリティ",
                "AX 経路の挿入に使う"),
            row("キー送出", status.postEventAccess, "\(settingsPath) > アクセシビリティ", "⌘V の送出に使う"),
            "",
            "  使える見込み: \(ready ? "はい" : "いいえ")",
        ]

        if !status.microphoneAuthorized {
            lines.append("  - マイクの許可がありません。押しても録音が始まりません。")
        }
        if !status.listenEventAccess {
            lines.append("  - 入力監視の許可がありません。右 Option の押下を受け取れません。")
        }
        if !status.postEventAccess {
            lines.append("  - キー送出の許可がありません。AX 経路が使えないアプリでは、テキストは")
            lines.append("    クリップボードに残るだけになります（履歴の insertionMethod は clipboardOnly）。")
        }
        if status.secureInputEnabled {
            // 今この瞬間の値である。パスワード欄から離れれば戻る。
            lines.append("  - いま secure input が有効です。この間はテキストを挿入しません")
            lines.append("    （整形も履歴もクリップボードへの残置も行いません）。")
        }

        lines.append(contentsOf: [
            "",
            "  設定ファイル: \(storageRoot.appendingPathComponent("settings.json").path)",
            "  履歴ファイル: \(storageRoot.appendingPathComponent("history.json").path)",
            "  用語辞書    : \(storageRoot.appendingPathComponent("vocabulary.json").path)",
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    private static func row(_ label: String, _ granted: Bool, _ pane: String, _ note: String)
        -> String
    {
        "  \(granted ? "✓" : "✗") \(label)（\(pane)）: \(note)"
    }
}

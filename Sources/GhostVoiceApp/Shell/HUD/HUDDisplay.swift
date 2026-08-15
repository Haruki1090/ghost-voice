import Foundation
import GhostVoiceCore

/// **HUD がいま何を出しているか。** 描画の唯一の入力である。
///
/// `SessionState` をそのまま描かないのは、次の 2 つが `SessionState` に無いからである。
///
/// 1. **`.failed` の直後には必ず `.idle` が続く**（`fail()` が同期で両方 emit する）。
///    そのまま描くとエラーが 1 フレームも見えない。**表示の保持時間は HUD が自分で持つ。**
/// 2. **完了のチェックマーク**は状態ではない（`.inserting` → `.idle` の間に挟む見せ方である）。
///
/// - Note: `Equatable` にしてあるのは、**変わっていないときに再描画しない**ためである。
///   暫定テキストは `.volatile` 更新のたびに届くので、素通しすると描画が更新の回数だけ走る。
public enum HUDDisplay: Sendable, Equatable {

    /// 何も出さない。**パネルは `orderOut` する**（透明な窓を残さない）。
    case hidden

    /// 録音中。音量バー＋言語バッジ＋暫定テキスト。
    case recording(HUDRecording)

    /// 処理中。
    case processing(HUDProcessing)

    /// 完了。チェックマークを短時間出して畳む。
    case completed

    /// 一言だけ告げる（失敗・拒否・喪失の疑い・Undo の顛末）。
    case message(HUDMessage)

    /// パネルを出すべきか。
    public var isVisible: Bool { self != .hidden }

    /// 幅を広げる表示か。
    ///
    /// **広げてよいのは切り欠きより下だけである**（左右の帯にはメニューバーが居る。
    /// 詳細設計書 §7.2）。ここが真でも切り欠きの帯そのものは広がらない。
    public var wantsWideLayout: Bool {
        switch self {
        case .recording(let recording): !recording.volatileText.isEmpty
        case .message: true
        case .hidden, .processing, .completed: false
        }
    }
}

/// 録音中の表示。
public struct HUDRecording: Sendable, Equatable {
    /// マイク音量（RMS）。`levelStream()` の値をそのまま入れる。
    public let level: Float
    /// 認識言語のバッジ（「日」/「EN」）。
    public let languageBadge: String
    /// 暫定テキスト。**末尾を見せる**（先頭を省略する）。
    public let volatileText: String

    public init(level: Float, languageBadge: String, volatileText: String) {
        self.level = level
        self.languageBadge = languageBadge
        self.volatileText = volatileText
    }
}

/// 処理中の内訳。
public enum HUDProcessing: Sendable, Equatable {
    case finalizing
    case refining
    case inserting
    /// **挿入済みの生テキストを整形結果へ差し替えている**（FR-5(a)）。
    case revising

    /// **控えめに出すか**（基本設計書 §8.2 の `revising` の行）。
    ///
    /// 差し替えの時点で挿入は既に終わっており、**利用者は次の作業へ移っている。**
    /// 断念しても生テキストは欄に残るので、ここで強く出すと「終わったのに何か起きている」
    /// という不安だけを作る。
    public var isSubdued: Bool { self == .revising }

    public var label: String {
        switch self {
        case .finalizing: "確定中"
        case .refining: "整形中"
        case .inserting: "挿入中"
        case .revising: "整形を反映中"
        }
    }
}

/// 一言。
public struct HUDMessage: Sendable, Equatable {
    public let text: String
    public let severity: HUDSeverity

    public init(text: String, severity: HUDSeverity) {
        self.text = text
        self.severity = severity
    }
}

/// どれだけ強く出すか。
public enum HUDSeverity: Sendable, Equatable {
    /// 事実の報告。**失敗ではない**（Undo が効いた、など）。
    case info
    /// 意図した拒否（secure input）。**「エラー」として赤く出さない**
    /// （`SessionFailureNotice.isRefusal`）。
    case refusal
    /// 失敗。ただし発話は残っている。
    case warning
    /// **発話が失われた（かもしれない）。** ここだけ強く、長く出す。
    case lost
}

/// 認識言語のバッジ。**ロケール識別子から作る純粋な変換。**
public enum HUDLanguageBadge {

    /// - Parameter identifier: `Settings.localeIdentifier`（例 `"ja-JP"`）。
    /// - Returns: 「日」/「EN」/ それ以外は言語コードの大文字（例 `"FR"`）。
    ///   識別子から言語コードを取れなければ `"?"`。
    public static func text(forLocaleIdentifier identifier: String) -> String {
        let code = Locale(identifier: identifier).language.languageCode?.identifier
            ?? identifier.split(separator: "-").first.map(String.init)
            ?? ""
        switch code.lowercased() {
        case "ja": return "日"
        case "en": return "EN"
        case "": return "?"
        default: return code.uppercased()
        }
    }
}

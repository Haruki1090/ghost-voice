import Foundation

/// システム設定の行き先。
///
/// **URL（`x-apple.systempreferences:`）は持たない。** この機体で開けることを
/// 実測していないためで、確かめていないことを Core の事実として置かない
/// （`docs/00-development-cycle.md` §3）。開くボタンを作る画面が、実測のうえで足すこと。
public enum SystemSettingsPane: Sendable, Equatable {
    /// プライバシーとセキュリティ > マイク（`kTCCServiceMicrophone`）。
    case microphone
    /// 一般 > 言語と地域（認識モデルはここへ言語を追加すると導入される）。
    case languageAndRegion

    /// 利用者に読ませるパス。**「どこを開くか」は媒体に依らない。**
    public var localizedPath: String {
        switch self {
        case .microphone: "システム設定 > プライバシーとセキュリティ > マイク"
        case .languageAndRegion: "システム設定 > 一般 > 言語と地域"
        }
    }
}

/// 縮退したあと、利用者が次にできること。
///
/// **文字列ではなく型で持つ。** 同じ「権限を許可する」でも、CLI は
/// 「起動しているターミナルアプリを許可してください」、`.app` は「Ghost Voice を
/// 許可してください」と言うことになり、**本文が媒体で変わる。**
/// 変わらないところ（どのペインか・何を確かめるか）だけを Core が持つ。
public enum SessionRemedy: Sendable, Equatable {
    /// システム設定の当該ペインで許可する。
    case grantAccess(pane: SystemSettingsPane)
    /// アプリから権限ダイアログを出す。
    ///
    /// **入口は媒体ごとに違う**（CLI は `--request-permissions`、アプリは権限フローの
    /// 画面）。Core は「その手がある」ことだけを言う。
    case requestAuthorizationFromApp
    /// 認識モデルを導入する（当該ペインへ言語を追加する）。
    case installLanguageModel(pane: SystemSettingsPane)
    /// 保存先の空き容量と書き込み権限を確かめる。
    case checkStorage(path: String)
}

/// 縮退の理由を、**表示媒体に依存しない形**で持つ（欠落 12）。
///
/// `SessionFailure` は型であって文言ではない（`DictationSession` の注記）。一方で
/// 文言を CLI と HUD の 2 箇所で保守すると必ず食い違う。**判断（何が起きたか・
/// 発話を失ったか・次に何ができるか）を Core に置き、組み立てだけを媒体に任せる。**
///
/// ## 使い分け
///
/// | 項目 | 誰が使うか |
/// |---|---|
/// | `summary` | HUD の帯（1 行。notch の幅は実測 221 pt）。CLI の 1 行目 |
/// | `detail` | 設定画面・権限フロー・CLI。**HUD の狭い帯には載らない** |
/// | `remedies` | ボタン（HUD / 設定画面）や案内文（CLI）。**媒体ごとに言い方が変わる** |
/// | `isRefusal` | 「失敗」として赤く出さないための印 |
/// | `speechWasLost` | **発話が失われたときだけ強く出す**ための印 |
///
/// - Note: 値型で `Sendable`。MainActor から自由に扱ってよい。
public struct SessionFailureNotice: Sendable, Equatable {

    /// 1 行の要約。**改行を含まない。** HUD の帯にそのまま出せる。
    public let summary: String

    /// 補足。空のこともある。**HUD の狭い帯には載せないこと。**
    public let detail: String

    /// 次にできること。**空のこともある**（`noSpeechRecognized` と `refusedSecureInput`）。
    public let remedies: [SessionRemedy]

    /// **失敗ではなく、意図した拒否か。**
    ///
    /// secure input のときだけ真。基本設計書 §7 の唯一の例外であり、
    /// **「発話を失った」と見て残置を足してはならない。** 表示も「エラー」ではなく
    /// 「行いませんでした」として出すこと。
    public let isRefusal: Bool

    /// **その発話がどこにも残らなかったか。**
    ///
    /// 真になるのは「挿入もしていない発話を履歴へ書けなかった」場合だけ。
    /// 音声は再現できないので、ここが真のときだけ HUD は強く出す
    /// （毎回強く出すと、本当に失った回が埋もれる）。
    public let speechWasLost: Bool

    /// 縮退の理由から表示材料を作る。**純粋な変換で、副作用も I/O も無い。**
    /// MainActor から直接呼んでよい（`SwiftUI` の `body` の中でも構わない）。
    public init(_ failure: SessionFailure) {
        switch failure {
        case .audioUnavailable:
            summary = "マイクを開けませんでした。"
            detail = ""
            remedies = [.grantAccess(pane: .microphone), .requestAuthorizationFromApp]
            isRefusal = false
            speechWasLost = false

        case .transcriptionUnavailable:
            summary = "音声認識を開始できませんでした。"
            detail = "設定した認識言語（既定 ja-JP）のモデルが利用できるかを確認してください。"
            remedies = [.installLanguageModel(pane: .languageAndRegion)]
            isRefusal = false
            speechWasLost = false

        case .noSpeechRecognized:
            summary = "認識できませんでした。"
            detail = ""
            remedies = []
            isRefusal = false
            speechWasLost = false

        case .refusedSecureInput:
            // **「失敗」ではなく意図した拒否である。** ここで「もう一度試してください」と
            // 書くと、パスワード欄へ挿入させようとする案内になる。
            summary = "パスワード入力欄（secure input）が有効でした。"
            detail = "整形・挿入・履歴・クリップボードのいずれも行いませんでした。"
            remedies = []
            isRefusal = true
            speechWasLost = false

        case .historyUnavailable(let insertedElsewhere):
            // **挿入まで行ったかで、利用者にとっての意味がまったく違う。**
            // 同じ文言にすると、発話が消えた場合に「履歴が欠けただけ」と読まれる。
            if insertedElsewhere {
                summary = "履歴に保存できませんでした（テキストの挿入は完了しています）。"
                detail = "失われるのは履歴と Undo だけです。"
            } else {
                summary = "履歴に保存できませんでした。中断したこの発話は失われました。"
                detail = "挿入もしていないため、どこにも残っていません。もう一度話してください。"
            }
            remedies = [.checkStorage(path: Self.storageDisplayPath)]
            isRefusal = false
            speechWasLost = !insertedElsewhere
        }
    }

    /// 保存先の表示用パス。
    ///
    /// `StorageRoot.default` の実体（`~/Library/Application Support/GhostVoice/`）を
    /// 利用者が読める形で書く。案内に絶対パスを出すと、ホームディレクトリ名が
    /// 混ざって読みにくい。
    public static let storageDisplayPath = "~/Library/Application Support/GhostVoice/"
}

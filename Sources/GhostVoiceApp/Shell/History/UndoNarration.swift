import Foundation
import GhostVoiceCore

/// **Undo（FR-7）の顛末を、利用者に読ませる形へ翻訳する。**
///
/// 実行そのものは Core にある（`DictationSession.performUndo`。Undo キーの監視も同じ）。
/// ここが決めているのは**「Undo できません」をどう伝えるか**だけである。
///
/// ## 決めたこと（未決だったので、ここで決める）
///
/// ### 1. 出口は HUD の 1 行にする。窓は開かない。通知センターも使わない。
///
/// **Undo はホットキーで撃たれる。** そのとき利用者は Slack なり Notion なりで作業して
/// いて、Ghost Voice の窓を見ていない。ここで窓を開くと `NSApp.activate()` が要り、
/// **最前面が Ghost Voice になる。** すると次の発話の挿入先が Ghost Voice 自身になる
/// （`AccessibilityInserter.frontmostProcessIdentifier()`）——
/// **「戻せない」と告げるために次の発話を壊す**ことになり、割に合わない。
///
/// 通知センターを使わない理由は別にある。`SessionNotice` は
/// 「**文言も発話も持たせない。通知に発話やその一部を載せると、通知センターやログへ
/// 発話が漏れる経路が生まれる**」と定めている。ここの文言も発話を 1 文字も含まないので
/// 通知センターでも規律は破れないが、**常駐の HUD が既に画面上にあるのに出口を 2 つ
/// 作る理由が無い。** 出口が 2 つあると、どちらに出たかで見落としが起きる。
///
/// ### 2. 音は鳴らさない。
///
/// 主用途が会議中の発話なので、Undo のたびに鳴ると使えない。
///
/// ### 3. **4 つの結末を 1 つの文言に潰さない。**
///
/// | 結末 | 利用者が次にすること | 潰すと何が起きるか |
/// |---|---|---|
/// | 戻した | 無し | — |
/// | **クリップボードへ取り出した** | **⌘V を押す** | ここを「戻せません」に潰すと、**クリップボードに在る生テキストへ辿り着けない**（UC-3 の縮退が死ぬ） |
/// | 断念した（編集された・別アプリへ移った） | もう一度やるなら手で | 「戻せません」に潰すと、**何か書き換えられたのではないか**と疑う理由が残る。**何も書き換えていない**ことは言う価値がある |
/// | 戻せるものが無い | 待たずに次へ | 理由（10 秒窓／経路）を出さないと、**Undo が壊れていると思われる** |
///
/// ### 4. 「戻せるものが無い」では**理由の候補を必ず添える。**
///
/// 10 秒という窓は画面のどこにも出ていない。**見えない締め切りで黙って断られるのが
/// いちばん悪い。** 秒数は `HistoryStore.undoWindow` から取る——**ここに 10 と書かない。**
/// 書くと Core と画面で別々に持つことになり、片方だけ変えたときに嘘になる。
public enum UndoNarration {

    /// 出す先。**`SessionNotice` の重さがそのまま出方を決める。**
    public enum Presentation: Sendable, Equatable {
        /// HUD の帯に短く出して自動で消す。
        case transient
        /// **消さない。** 利用者が読むまで残す（発話が失われたかもしれない場合）。
        case persistent
    }

    public struct Message: Sendable, Equatable {
        /// HUD の帯に載る 1 行。**notch の幅は実測 221 pt しかない**ので短く保つ。
        public let headline: String
        /// 補足。**帯には載らない。** 履歴画面や、帯を広げたときに出す。
        public let detail: String?
        public let presentation: Presentation
        /// 失敗として（赤く）出すか。
        public let isFailure: Bool

        public init(
            headline: String, detail: String?, presentation: Presentation, isFailure: Bool
        ) {
            self.headline = headline
            self.detail = detail
            self.presentation = presentation
            self.isFailure = isFailure
        }
    }

    /// Undo の窓（秒）。**`HistoryStore.undoWindow` が唯一の出どころである。**
    static var undoWindowSeconds: Int { Int(HistoryStore.undoWindow) }

    /// `SessionNotice` を文言へ。
    ///
    /// - Returns: Undo に関係しない通知（整形の差し替えの顛末）では `nil`。
    ///   **そちらは HUD トラックの担当である**（`.refinementApplied` /
    ///   `.refinementNotApplied` / `.textMayHaveBeenLost`）。
    ///   ここで文言を作ると、同じ通知の文言が 2 箇所に生まれる。
    public static func message(for notice: SessionNotice) -> Message? {
        switch notice {
        case .undone:
            return Message(
                headline: "整形前のテキストに戻しました",
                detail: nil,
                presentation: .transient,
                isFailure: false)

        case .undoCopiedRawTextToClipboard:
            // **ここが 4 つのうちいちばん言葉が要る。**
            // 「戻せません」で終えると、クリップボードに在る生テキストへ辿り着けない。
            return Message(
                headline: "自動では戻せないので、整形前のテキストをコピーしました（⌘V で貼れます）",
                detail: """
                    この発話はクリップボード経由で挿入されていて、書いた範囲を持っていません。\
                    そのため同じ場所を書き換える手段がありません（要件定義書 FR-7 の細目）。\
                    **挿入済みのテキストは 1 文字も変えていません。** 手で消して貼り直してください。
                    """,
                presentation: .persistent,
                isFailure: false)

        case .undoDeclined(let reason):
            return Message(
                headline: "戻せませんでした。**何も書き換えていません**",
                detail: declineDetail(reason),
                presentation: .transient,
                isFailure: true)

        case .undoUnavailable:
            // **見えない締め切りで黙って断らない。** 秒数は Core から取る。
            return Message(
                headline: "戻せるものがありません",
                detail: """
                    戻せるのは、**挿入から \(undoWindowSeconds) 秒以内**の、\
                    **アクセシビリティ経路で挿入して整形結果へ差し替えた**発話だけです。\
                    クリップボード経由で挿入した発話・整形が反映されなかった発話・\
                    中断した発話は対象外です（要件定義書 FR-7 の細目）。\
                    履歴画面から整形前のテキストをコピーできます。
                    """,
                presentation: .transient,
                isFailure: true)

        case .refinementApplied, .refinementNotApplied, .textMayHaveBeenLost:
            return nil
        }
    }

    /// 断念の理由。**「なぜ」まで言う。** 言わないと利用者は同じ操作を繰り返す。
    ///
    /// - Important: **`switch` を網羅で書く。** `default` を置くと、Core が
    ///   `ReplacementDecline` にケースを足したときに、新しい理由が黙って
    ///   既存の文言へ吸い込まれる。**ここが赤くなることが、文言を足す合図である。**
    static func declineDetail(_ reason: ReplacementDecline) -> String {
        switch reason {
        case .secureInput:
            "パスワード入力中（secure input）なので書き換えません。"
        case .focusChanged:
            "挿入したときと別の入力欄が選ばれています。"
        case .processChanged:
            "挿入したときと別のアプリが前面にあります。"
        case .rangeNotSettable:
            "その入力欄は範囲を選び直せません（書き換えの手段がありません）。"
        case .sourceMismatch:
            "挿入したテキストが編集されています。**書き換えると編集内容が消える**ので、何もしませんでした。"
        case .sourceUnreadable:
            "挿入した場所の内容を読み戻せませんでした（相手のアプリが応えません）。"
        case .rangeWriteFailed, .textWriteFailed:
            "書き換えを試みましたが、相手のアプリが受け付けませんでした。"
        case .staleEpoch:
            "この発話より後に別の挿入が起きています（戻せるのは直前の 1 件だけです）。"
        case .nothingToUndo:
            "この発話はまだ整形結果へ差し替えられていません（戻す先がありません）。"
        case .nothingToChange:
            "既に整形前のテキストになっています。"
        case .emptyReplacement:
            "戻す先が空文字なので、書き換えると消すだけになります。"
        case .ownProcess:
            "挿入先が Ghost Voice 自身になっています（設定や履歴の窓が前面のままです）。"
        case .blockedProcess:
            "このアプリでは以前に書き換えの失敗を検知しているため、以後試しません（R-9）。"
        }
    }
}

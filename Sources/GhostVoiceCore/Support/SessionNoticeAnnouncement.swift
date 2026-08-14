import Foundation

/// **`SessionNotice` を、表示媒体に依存しない形の材料へ翻訳する。**
///
/// `SessionFailureNotice` を Core へ置いたのと**まったく同じ理由**である
/// （詳細設計書 §8.5 / 統括の裁定）。以前はこの判断が
///
/// - `GhostVoiceApp/Shell/HUD/HUDPresenter.announcement(for:)`（HUD 用）
/// - `GhostVoiceApp/Shell/History/UndoNarration.message(for:)`（Undo の顛末用）
///
/// の **2 箇所にあり、しかも CLI には 1 箇所も無かった**——`ghost-voice` から Undo を
/// 撃つと顛末が何も出ない、という**フェーズ 1 で潰した「無言で失敗する」と同じ形**である。
/// 判断（出すか出さないか・何を言うか・どれだけ重いか）を Core に置き、
/// **組み立てだけを媒体に任せる。**
///
/// ## 使い分け
///
/// | 項目 | 誰が使うか |
/// |---|---|
/// | `summary` | HUD の帯（1 行。notch の幅は実測 221 pt）。CLI の 1 行目 |
/// | `detail` | CLI の続き・履歴画面。**HUD の狭い帯には載らない** |
/// | `weight` | 表示の強さと長さ。**長さそのものは媒体が決める**（HUD は `HUDPresenter.Timing`） |
/// | `isFailure` | 赤く出すか |
/// | `isPersistent` | **自動で消してはならないか**（読み落とすと取り返しがつかないもの） |
///
/// - Note: 値型で `Sendable`。MainActor から自由に扱ってよい。
public struct SessionNoticeAnnouncement: Sendable, Equatable {

    /// 表示の強さ。**具体的な秒数や色は媒体が決める。**
    public enum Weight: Sendable, Equatable {
        /// 短く出して消える。失敗ではない。
        case info
        /// 失敗として出す。
        case warning
        /// **発話が失われた疑い**（R-9）。他のどんな表示よりも優先する。
        case lost
        /// **利用者が次に何かしないと取り返せない**（クリップボードから ⌘V する）。
        case actionRequired
    }

    /// 1 行の要約。**改行を含まない。** HUD の帯にそのまま出せる。
    public let summary: String

    /// 補足。空のこともある。**HUD の狭い帯には載せないこと。**
    public let detail: String

    public let weight: Weight

    /// 赤く（失敗として）出すか。
    ///
    /// - Note: **`.actionRequired` は失敗ではない。** クリップボードへの退避は
    ///   縮退が正しく働いた結果であり、赤く出すと「発話を失った」と読まれる
    ///   （`SessionFailureNotice.isRefusal` と同じ扱い）。
    public let isFailure: Bool

    /// **自動で消してはならないか。**
    ///
    /// 真になるのは `.undoCopiedRawTextToClipboard` だけである。読み落とすと
    /// **クリップボードに在る生テキストへ辿り着けない**（UC-3 の縮退が死ぬ）。
    ///
    /// - Note: **次の発話が始まれば消えてよい。** 利用者が話し始めているのに
    ///   前の告知を出し続けるのは嘘である（HUD の `.recording` は保持中のどんな
    ///   表示にも勝つ）。ここが言っているのは「時間で勝手に畳むな」だけである。
    public let isPersistent: Bool

    init(
        summary: String, detail: String = "", weight: Weight,
        isFailure: Bool, isPersistent: Bool = false
    ) {
        self.summary = summary
        self.detail = detail
        self.weight = weight
        self.isFailure = isFailure
        self.isPersistent = isPersistent
    }

    /// Undo の窓（秒）。**`HistoryStore.undoWindow` が唯一の出どころである。**
    ///
    /// 文言の中に生の数字を書かない（片方だけ変えたときに嘘になる）。
    static var undoWindowSeconds: Int { Int(HistoryStore.undoWindow) }

    /// 通知から表示材料を作る。**純粋な変換で、副作用も I/O も無い。**
    ///
    /// - Returns: **告げないものは nil。** どれを黙って捨てるかも判断であり、
    ///   媒体ごとに変えてはならない（片方だけ賑やかになる）。
    ///   - `.refinementApplied` は出さない。**欄の文字が整ったこと自体が結果**であり、
    ///     毎回「反映しました」と言うのは通知のためだけの通知になる。
    ///   - **`.refinementNotApplied(nil)` も出さない。** nil は「整形そのものが返らなかった」
    ///     （打ち切り・利用不可・逸脱の検査に落ちた）であり、**これは珍しくない**——
    ///     実測で 56 字の発話は整形が締め切りの内側で完了していても 10/10 で捨てられている
    ///     （V-37）。毎回出すと、本当に重い `.textMayHaveBeenLost` が埋もれる。
    public init?(_ notice: SessionNotice) {
        switch notice {
        case .refinementApplied:
            return nil

        case .refinementNotApplied(let reason):
            guard let reason else { return nil }
            self.init(
                summary: "整形を反映できませんでした（入力済みの文はそのままです）。",
                detail: Self.declineDetail(reason),
                weight: .warning, isFailure: true)

        case .textMayHaveBeenLost:
            // **「クリップボードから貼り直せます」と言い切ってはならない**（再レビュー B-3）。
            // 退避（`TextReplacer` の `.lost`）は、次の発話が Pasteboard 経路で
            // 挿入している最中だと**300 ms 後の復元で上書きされる。**
            // `TextReplacer` は挿入が進行中かを知る手段を持たない（Core の型に印が無い）ので、
            // **窓は構造として残る。** 告げる側で嘘にならない言い方にする——
            // 整形前のテキストは履歴にある（(a) の分岐は履歴へ書けたときにしか
            // 差し替えを始めない。`insertRawThenRevise`）。
            self.init(
                summary: "入力欄のテキストが失われた可能性があります。クリップボードか履歴から取り出せます。",
                detail: """
                    差し替えの途中で欄の内容が判らなくなりました（R-9）。\
                    整形後のテキストはクリップボードへ退避しましたが、\
                    **次の発話の挿入と重なると上書きされることがあります**——\
                    その場合も整形前のテキストは履歴に残っています。\
                    以後このアプリでは差し替えを試みません。
                    """,
                weight: .lost, isFailure: true)

        case .undone:
            self.init(summary: "整形前のテキストに戻しました。", weight: .info, isFailure: false)

        case .undoUnavailable:
            // **見えない締め切りで黙って断らない。** 秒数は Core の 1 箇所から取る。
            self.init(
                summary: "戻せるものがありません。",
                detail: """
                    戻せるのは、**挿入から \(Self.undoWindowSeconds) 秒以内**の、\
                    **アクセシビリティ経路で挿入して整形結果へ差し替えた**発話だけです。\
                    クリップボード経由で挿入した発話・整形が反映されなかった発話・\
                    中断した発話は対象外です（要件定義書 FR-7 の細目）。\
                    履歴画面から整形前のテキストをコピーできます。
                    """,
                weight: .info, isFailure: true)

        case .undoDeclined(let reason):
            self.init(
                summary: "戻せませんでした。**何も書き換えていません。**",
                detail: Self.declineDetail(reason),
                weight: .warning, isFailure: true)

        case .undoCopiedRawTextToClipboard:
            // **4 つのうちいちばん言葉が要る。**
            // 「戻せません」で終えると、クリップボードに在る生テキストへ辿り着けない。
            self.init(
                summary: "自動では戻せないので、整形前のテキストをコピーしました（⌘V で貼れます）。",
                detail: """
                    この発話はクリップボード経由で挿入されていて、書いた範囲を持っていません。\
                    そのため同じ場所を書き換える手段がありません（要件定義書 FR-7 の細目）。\
                    **挿入済みのテキストは 1 文字も変えていません。** 手で消して貼り直してください。
                    """,
                weight: .actionRequired, isFailure: false,
                // **これだけ自動で消さない。** 読み落とすと取り返しがつかない。
                isPersistent: true)
        }
    }

    /// 断念の理由。**「なぜ」まで言う。** 言わないと利用者は同じ操作を繰り返す。
    ///
    /// - Important: **`switch` を網羅で書く。** `default` を置くと、
    ///   `ReplacementDecline` にケースを足したときに新しい理由が黙って既存の文言へ
    ///   吸い込まれる。**ここが赤くなることが、文言を足す合図である。**
    public static func declineDetail(_ reason: ReplacementDecline) -> String {
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

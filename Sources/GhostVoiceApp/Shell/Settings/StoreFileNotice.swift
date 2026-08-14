import Foundation
import GhostVoiceCore

/// **「読めなかった」という事実を、利用者の目に見える形へ翻訳する。**
///
/// ## なぜこれが要るか（統括の裁定の条件）
///
/// 不正なホットキーを 1 つでも含む `settings.json` は**丸ごと「読めなかった」扱いになり、
/// 全設定が既定値へ戻る**（`Settings.init(from:)` / `HotkeyBinding.init(from:)`）。
/// この設計を採る条件として、統括は次を課している:
///
/// > `Ruling:（統括）採用の条件は「設定画面がこの事実を利用者へ見える形にすること」。
/// >  無言で既定へ戻ると、フェーズ1で潰した「成功と記録されるのに中身が違う」と同じ形になる`
///
/// **利用者から見える症状は「`en-US` にしたのに日本語で認識される」だけである。**
/// 原因へ辿り着く手掛かりが 1 つも無い。だから画面が言う。
///
/// ## 退避のタイミングを間違えないこと（実装を読んで確かめた事実）
///
/// `.corrupt` への退避は**読み込みの時点では起きない。** `AtomicJSONFile` は
/// 「復元できなかった」ことを覚えておき、**次の `save` の直前に一度だけ**逃がす
/// （`AtomicJSONFile.save` / `quarantineWithoutLocking`）。
///
/// したがって画面が出す文言は、**まだ退避されていない間と、退避された後とで違う。**
/// 「退避しました」と先に言うと、利用者は `.corrupt` を探して見つけられない。
/// 逆に「保存すると退避されます」と言い続けると、既に退避済みのときに嘘になる。
/// **どちらかを状態として持つ**（`Quarantine`）。
public struct StoreFileNotice: Identifiable, Sendable, Equatable {

    /// どのファイルの話か。
    public enum File: String, Sendable, Equatable, CaseIterable {
        case settings
        case vocabulary
        case history

        /// 実ファイル名。**`AtomicJSONFile` へ渡している名前と同じであること。**
        public var fileName: String {
            switch self {
            case .settings: "settings.json"
            case .vocabulary: "vocabulary.json"
            case .history: "history.json"
            }
        }

        /// 退避先の名前。`AtomicJSONFile` は拡張子を足すだけである
        /// （`url.appendingPathExtension("corrupt")`）。
        public var quarantineFileName: String { fileName + ".corrupt" }

        /// 読めなかったときに何が既定へ戻るか。**「読めませんでした」だけでは足りない。**
        public var lostDescription: String {
            switch self {
            case .settings:
                "ホットキー・言語・整形の設定が **すべて既定値に戻っています**"
            case .vocabulary:
                "登録した固有名詞が **1 件も読み込まれていません**（整形の誤認識修正が効きません）"
            case .history:
                "これまでの履歴が **1 件も読み込まれていません**"
            }
        }
    }

    /// 元のファイルが今どこにあるか。
    public enum Quarantine: Sendable, Equatable {
        /// **まだ元の場所にある。** 次にこの画面から保存した時点で `.corrupt` へ移る。
        case pending
        /// **既に `.corrupt` へ移った。** 手で直して戻せる。
        case moved
    }

    public let file: File
    public let quarantine: Quarantine
    /// 保存先ディレクトリ。**利用者に見せるのは絶対パスである**（`~` へ畳まない。
    /// Finder の「フォルダへ移動」に貼れる形が要る）。
    public let directory: URL
    /// 復元できなかった理由（`Codable` が投げたもの）。**そのまま出す。**
    /// 要約すると「どのキーが悪いのか」が落ちる。
    public let reason: String

    /// 読み込みに失敗した時点の、そのファイルの中身。
    ///
    /// **退避が起きたかどうかを、推測ではなく突き合わせで決めるために持つ。**
    /// 「`.corrupt` が在るか」では決められない——前回の起動で退避された `.corrupt` が
    /// 残っている状態で新しく壊れたファイルを置けるし、**保存した後は元の場所に
    /// 健全なファイルが書き直されているので「元の場所に在るか」でも決められない。**
    /// 控えた中身がどちらの場所に在るかを見れば、どちらの疑いも残らない。
    let originalContents: Data?

    public var id: File { file }

    public init(
        file: File, quarantine: Quarantine, directory: URL, reason: String,
        originalContents: Data? = nil
    ) {
        self.file = file
        self.quarantine = quarantine
        self.directory = directory
        self.reason = reason
        self.originalContents = originalContents
    }

    /// 1 行の見出し。**「読めなかった」と「何が失われたか」を必ず同じ行に置く。**
    public var headline: String {
        "\(file.fileName) を読み込めませんでした。\(file.lostDescription)。"
    }

    /// 利用者が次にできること。**退避の状態で言うことが変わる。**
    public var remedy: String {
        switch quarantine {
        case .pending:
            """
            元のファイルは、まだ \(directory.appendingPathComponent(file.fileName).path) にそのまま残っています。
            **この画面から保存すると \(file.quarantineFileName) へ退避され、上書きされます。**
            手で書き直したい場合は、保存する前に開いて内容を控えてください。
            """
        case .moved:
            """
            元のファイルは \(directory.appendingPathComponent(file.quarantineFileName).path) へ退避してあります。
            開いて直し、\(file.fileName) へ戻せば元の設定に復帰できます。
            """
        }
    }

    /// 心当たりの案内。**設定ファイルにだけ出す。**
    ///
    /// ホットキーの規則はファイルを手で書いた人には見えないので、
    /// 「読めなかった」で終わらせると原因に辿り着けない。
    /// **規則そのものは Core が持っている**（`HotkeyBindingError` /
    /// `Settings.validateHotkeys()`）。ここに書いてあるのは説明文であって検査ではない。
    public var hint: String? {
        guard file == .settings else { return nil }
        return """
            ホットキーの組み合わせが規則に反していると、**そのファイル全体が読めなくなります**（一部だけ既定へ戻す縮退は採っていません）。
            ・PTT キーの修飾キーを含む Undo キー（既定の PTT は右 Option なので、⌥ を含む Undo キーは登録できません）
            ・修飾キー単独のキーに、別の修飾キーを足した組（設定どおりに動かないため）
            ・仮想キーコードが 0〜127 の外
            """
    }

    // MARK: - 組み立て

    /// ストアが抱えた読み込み失敗を、画面に出せる形へ集める。
    ///
    /// - Important: **`loadFailure` は `init` の時点の事実である。** ストアを作った後に
    ///   ファイルを差し替えても変わらない。画面はストアと寿命を共にすること。
    /// - Parameter directory: ストアを作るときに渡した保存先。既定は `StorageRoot.default`。
    public static func collect(
        settings: SettingsStore,
        vocabulary: VocabularyStore,
        history: HistoryStore,
        directory: URL,
        fileManager: FileManager = .default
    ) -> [StoreFileNotice] {
        let failures: [(File, (any Error)?)] = [
            (.settings, settings.loadFailure),
            (.vocabulary, vocabulary.loadFailure),
            (.history, history.loadFailure),
        ]
        return failures.compactMap { file, error in
            guard let error else { return nil }
            // **読めなかった中身をここで控える。** これより後に保存が走ると
            // 元の場所が上書きされるので、控えられるのはこの瞬間だけである。
            let contents = try? Data(
                contentsOf: directory.appendingPathComponent(file.fileName))
            return StoreFileNotice(
                file: file,
                quarantine: quarantineState(
                    of: file, in: directory, originalContents: contents,
                    fileManager: fileManager),
                directory: directory,
                reason: String(describing: error),
                originalContents: contents)
        }
    }

    /// 退避が済んでいるかを、**控えた中身がどちらの場所に在るか**で決める。
    ///
    /// 場所の有無では決められない。
    /// - 前回の起動で退避された `.corrupt` が残っている状態で、新しく壊れたファイルを置ける
    ///   （＝「`.corrupt` が在る」は退避済みを意味しない）。
    /// - **保存すると元の場所に健全なファイルが書き直される**ので、
    ///   「元の場所に在る」も退避前を意味しない。
    ///
    /// 判らないときは `.pending` へ倒す。**「保存する前に控えてください」と言い続ける方が、
    /// 「退避しました」と嘘を言うより害が小さい。**
    static func quarantineState(
        of file: File, in directory: URL, originalContents: Data?, fileManager: FileManager
    ) -> Quarantine {
        let original = directory.appendingPathComponent(file.fileName)
        guard let originalContents else {
            // 中身を控えられなかったときだけ、場所の有無に頼る。
            return fileManager.fileExists(atPath: original.path) ? .pending : .moved
        }
        // 控えたものが元の場所にまだ在るなら、それはこれから退避される側。
        if let current = try? Data(contentsOf: original), current == originalContents {
            return .pending
        }
        let quarantined = directory.appendingPathComponent(file.quarantineFileName)
        if let moved = try? Data(contentsOf: quarantined), moved == originalContents {
            return .moved
        }
        return .pending
    }
}

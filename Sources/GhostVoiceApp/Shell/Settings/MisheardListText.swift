import Foundation

/// **誤認識表記の並びを、1 つの入力欄で編集するための翻訳**（FR-11 / FR-6）。
///
/// `VocabularyTerm.misheard` は配列だが、**1 項目に対して入力欄を可変個並べると、
/// 追加・削除のボタンが項目ごとに増えて画面が読めなくなる。** 区切り文字 1 つで
/// 並べるほうが、100 件の辞書を上から見て直すという実際の使い方に合う。
///
/// - Note: **これは表示の都合であって、保存形式ではない。** `vocabulary.json` は
///   従来どおり配列である（手編集も従来どおり効く）。
public enum MisheardListText {

    /// 見せるときの区切り。**`SettingsView` の一覧表示と同じもの。**
    public static let separator = " / "

    /// 受け付ける区切り。**`/` と改行と読点。**
    ///
    /// 読点を入れているのは、日本語の表記を並べる利用者が自然に `、` を打つためである。
    /// **`/` が誤認識表記そのものに含まれることはまず無い**が、含めたい場合は
    /// `vocabulary.json` を手で編集すれば通る（保存形式は配列のままなので失われない）。
    static let acceptedSeparators = CharacterSet(charactersIn: "/\n、,")

    /// 配列 → 入力欄の文字列。
    public static func text(_ misheard: [String]) -> String {
        misheard.joined(separator: separator)
    }

    /// 入力欄の文字列 → 配列。
    ///
    /// **空白だけの項目を落とし、重複を先勝ちで畳む。**
    /// `VocabularyStore.normalize` は `canonical` しか見ない（誤認識表記はそのまま
    /// 保存される）ので、**掃除をするのはここが唯一の場所である。**
    /// 掃除しないと、空文字が整形プロンプトへ注入され、
    /// **`RefinementGuard` が「頼んだ置換」を数える根拠が濁る**（正本 §5.5.1）。
    public static func list(_ text: String) -> [String] {
        var seen = Set<String>()
        return
            text
            .components(separatedBy: acceptedSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

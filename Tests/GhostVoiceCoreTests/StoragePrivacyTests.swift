import Foundation
import Testing

@testable import GhostVoiceCore

/// **ディスクに残る発話テキストについての約束。**
///
/// `history.json` には認識テキストが平文で入る（要件どおり）。
/// したがって「利用者が消したつもりのものが残っていないか」「置き場所に依らず
/// 他人から読めない形になっているか」は、この製品の存在理由に触れる
/// （最終レビュー 視点5 の P-2 / P-3）。
@Suite("保存ファイルのプライバシー")
struct StoragePrivacyTests {

    /// **履歴を全部消しても `.corrupt` に過去の発話が残っていた。**
    ///
    /// `history.json` が壊れて読めなかった場合、次の保存の直前に
    /// `history.json.corrupt` へ**中身ごと**退避される（設計どおり）。
    /// ところが `removeAll()` は `history.json` を空配列で書き直すだけで、
    /// **退避先には触れなかった。** 利用者が履歴画面で「全部削除」を押しても、
    /// `~/Library/Application Support/GhostVoice/history.json.corrupt` に
    /// 過去の発話が残り続ける（最終レビュー 視点5 の P-2）。
    @Test("履歴を全部消すと、退避された .corrupt も消える")
    func removingAllHistoryAlsoRemovesTheQuarantinedCopy() async throws {
        try await withTempRoot { root in
            let file = root.appendingPathComponent("history.json")
            let quarantined = root.appendingPathComponent("history.json.corrupt")

            // 壊れた履歴を置く。**中身は「利用者が消したい発話」である。**
            try "壊れた JSON: 昨日の発話がここに入っている".write(
                to: file, atomically: true, encoding: .utf8)

            let store = HistoryStore(rootURL: root, limit: 50)
            // 1 件書くと、その直前に退避が走る。
            try store.append(
                HistoryEntry(
                    rawText: "新しい発話", refinedText: nil,
                    localeIdentifier: "ja-JP", insertionMethod: .ax))
            #expect(
                FileManager.default.fileExists(atPath: quarantined.path),
                "退避が起きていない（この検査が空回りしている）")

            try await store.removeAll()

            #expect(store.entries.isEmpty)
            #expect(
                !FileManager.default.fileExists(atPath: quarantined.path),
                "全部消したのに、退避された発話がディスクに残っている")
        }
    }

    /// 退避が無いときに `removeAll` が落ちないこと（普通の経路）。
    @Test("退避が無くても全部削除は成功する")
    func removingAllSucceedsWithoutAQuarantinedCopy() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            try store.append(
                HistoryEntry(
                    rawText: "発話", refinedText: nil,
                    localeIdentifier: "ja-JP", insertionMethod: .ax))
            try await store.removeAll()
            #expect(store.entries.isEmpty)
        }
    }

    /// **権限は umask 任せだった。**
    ///
    /// いま安全なのは親ディレクトリ（`~/Library/Application Support`）が 700 だから
    /// であって、このコードが守っているからではない。保存先は `init(rootURL:)` で
    /// 差し替えられる形になっており、**将来 `~/Library` の外へ置いた瞬間に保護が消える**
    /// （最終レビュー 視点5 の P-3）。
    @Test("保存したファイルとディレクトリは本人だけが読み書きできる")
    func storedFilesAreOnlyReadableByTheOwner() throws {
        try withTempRoot { root in
            // **ルートの下にさらにディレクトリを作らせる**（`createDirectory` の側を見るため）。
            let nested = root.appendingPathComponent("nested", isDirectory: true)
            let file = AtomicJSONFile<[String]>(
                url: nested.appendingPathComponent("data.json"), fallback: [])
            _ = file.load()
            try file.save(["発話がここに平文で入る"])

            let fileMode = try #require(
                FileManager.default.attributesOfItem(atPath: nested
                    .appendingPathComponent("data.json").path)[.posixPermissions] as? NSNumber)
            let directoryMode = try #require(
                FileManager.default.attributesOfItem(
                    atPath: nested.path)[.posixPermissions] as? NSNumber)

            #expect(
                fileMode.int16Value & 0o077 == 0,
                "保存ファイルを本人以外が読める（\(String(fileMode.int16Value, radix: 8))）")
            #expect(
                directoryMode.int16Value & 0o077 == 0,
                "保存先ディレクトリを本人以外が辿れる（\(String(directoryMode.int16Value, radix: 8))）")
        }
    }

    /// 退避したファイルも同じであること（**中身は発話そのものである**）。
    @Test("退避した .corrupt も本人だけが読める")
    func theQuarantinedCopyIsAlsoPrivate() throws {
        try withTempRoot { root in
            let url = root.appendingPathComponent("data.json")
            try "壊れた JSON: 発話がここに入っている".write(
                to: url, atomically: true, encoding: .utf8)
            // **わざと緩い権限にしておく。** 退避が権限を直さないなら、ここが残る。
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)

            let file = AtomicJSONFile<[String]>(url: url, fallback: [])
            _ = file.load()
            try file.save(["新しい中身"])

            let quarantined = root.appendingPathComponent("data.json.corrupt")
            let mode = try #require(
                FileManager.default.attributesOfItem(
                    atPath: quarantined.path)[.posixPermissions] as? NSNumber)
            #expect(
                mode.int16Value & 0o077 == 0,
                "退避した発話を本人以外が読める（\(String(mode.int16Value, radix: 8))）")
        }
    }
}

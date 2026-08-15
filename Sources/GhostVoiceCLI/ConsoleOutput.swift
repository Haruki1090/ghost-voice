import Foundation
import GhostVoiceCore

/// 出力先。**差し替え口にしてあるのは検査のため。**
/// 実体は標準出力・標準エラーだが、テストからは溜め込むものを挿す。
public protocol ConsoleWriting: Sendable {
    func write(_ text: String)
}

extension ConsoleWriting {

    /// 終了時の文言を端末へ流す。
    ///
    /// **文言そのものはここには無い**（`GhostVoiceCore.ShutdownAnnouncement` が持つ）。
    /// ここが決めるのは前後の余白だけである——CLI と `.app` で文言が別々に育たないよう、
    /// 端末向けの体裁と文言を分けてある。
    public func announce(_ announcement: ShutdownAnnouncement) {
        switch announcement {
        case .waiting:
            // 進行表示（`SessionNarration` が `\r` で行を上書きする）の途中に割り込む。
            // **必ず行を改めてから出す。**
            write("\n" + announcement.text + "\n")
        case .stillWaiting:
            // **待っている間も 1 秒ごとに出す。** 端末では HUD が無いので、
            // ここが「まだ生きている」を示す唯一の手がかりになる。
            // 録音は続いているので進行表示が `\r` で走っている——行を改めてから出す。
            write("\n" + announcement.text + "\n")
        case .gaveUp, .utteranceInterrupted, .finished:
            write(announcement.text + "\n")
        }
    }
}

/// 進行状況の出力先。
///
/// **標準エラーへ出す。** 標準出力は将来の「認識結果を他のコマンドへ渡す」用途のために
/// 空けておく。フェーズ 1 には HUD が無いので（FR-2 / FR-3 はフェーズ 2）、
/// 録音中・整形中の表示はここが唯一の窓である。
public struct StandardErrorWriter: ConsoleWriting {
    public init() {}
    public func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

public struct StandardOutputWriter: ConsoleWriting {
    public init() {}
    public func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}

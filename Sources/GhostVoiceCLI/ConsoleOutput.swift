import Foundation

/// 出力先。**差し替え口にしてあるのは検査のため。**
/// 実体は標準出力・標準エラーだが、テストからは溜め込むものを挿す。
public protocol ConsoleWriting: Sendable {
    func write(_ text: String)
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

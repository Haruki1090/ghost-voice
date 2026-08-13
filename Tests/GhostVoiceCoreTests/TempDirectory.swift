import Foundation

/// 一時ディレクトリを作り、`body` の実行後に必ず削除する。
///
/// ストアはすべてルート URL を受け取る設計なので、テストはここで作った
/// 一時ディレクトリを渡す。作りっぱなしにしないよう、生成は必ずこの関数を通すこと。
func withTempRoot<R>(_ body: (URL) throws -> R) throws -> R {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gv-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

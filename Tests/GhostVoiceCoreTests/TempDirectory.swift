import Foundation

/// 一時ディレクトリを作り、`body` の実行後に必ず削除する。
///
/// ストアはすべてルート URL を受け取る設計なので、テストはここで作った
/// 一時ディレクトリを渡す。作りっぱなしにしないよう、生成は必ずこの関数を通すこと。
func withTempRoot<R>(_ body: (URL) throws -> R) throws -> R {
    let url = try makeTempRootURL()
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

/// 非同期版。`DictationSession` のように待ち合わせが要るテストのために置く。
///
/// **同じ名前にしてあるのは意図的。** 一時ディレクトリの生成をこの 2 つに絞り、
/// 「非同期だから」という理由で各テストが自前で `NSTemporaryDirectory()` を
/// 触りはじめる（＝後片付けが漏れる）のを防ぐ。
func withTempRoot<R>(_ body: (URL) async throws -> R) async throws -> R {
    let url = try makeTempRootURL()
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

private func makeTempRootURL() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gv-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

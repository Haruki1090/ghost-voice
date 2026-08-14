import AppKit
import Foundation

/// テスト専用の名前付きクリップボードを作り、`body` の後に必ず解放する。
///
/// **テストが `NSPasteboard.general` に触れてはならない。** 開発機で `swift test` を
/// 回した瞬間にユーザーのクリップボードが消えることになる。クリップボードを扱う
/// テストは必ずここを通し、独立した名前付きクリップボードの上でだけ動かすこと。
func withNamedPasteboard<R>(_ body: (NSPasteboard) async throws -> R) async rethrows -> R {
    let pasteboard = NSPasteboard(name: .init("gv-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    return try await body(pasteboard)
}

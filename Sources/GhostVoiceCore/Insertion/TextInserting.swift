import Foundation
import Synchronization

/// 確定したテキストを、フォーカス中のアプリのカーソル位置へ入れる出口。
///
/// **ここは発話が外へ出る唯一の口である。** 認識も整形も成功した発話が、
/// ここで失敗すればどこにも届かない。音声は再現できないので、実装は
/// 「入らなかった」場合でも**テキストをクリップボードには残す**こと（基本設計書 §230）。
public protocol TextInserting: Sendable {
    /// テキストを挿入し、実際に使われた経路を返す。
    ///
    /// 戻り値は履歴に記録し、どのアプリでどの経路が使われたかの実地データとする（V-3）。
    /// **`.clipboardOnly` を返すときは、テキストが実際にクリップボードへ残っていること。**
    func insert(_ text: String) async -> InsertionMethod
}

/// 二段構えの各段。
public protocol PrimaryInserting: Sendable {
    /// この経路が適用できる状況か。
    ///
    /// **判定は安価でなければならない。** 適用外だった場合、この判定のコストは
    /// 次の段のコストへ丸ごと上乗せされる。挿入の予算は NFR-P5 の 50 ms しかない。
    func canInsert() -> Bool

    /// 挿入を試みる。成功したら true。
    ///
    /// - Important: `canInsert()` が false を返した段でこれを呼んではならない。
    ///   AX 経路では対象外の要素への書き込みを意味する。
    func tryInsert(_ text: String) async -> Bool
}

/// 最後の砦。挿入が全滅したときに、発話をクリップボードへ残す。
///
/// **`PrimaryInserting` と分けてあるのには理由がある。** 両段が `canInsert()` で
/// 「適用外」を返した場合、`tryInsert` は一度も走らないので、Pasteboard 経路が
/// クリップボードへ書く機会そのものが無い。残置を挿入経路の副作用として扱うと、
/// そこで発話が消える。
public protocol ClipboardLeaving: Sendable {
    /// テキストをクリップボードへ置く。置けたら true。
    @discardableResult
    func leave(_ text: String) -> Bool
}

// MARK: - テスト用

/// テスト用。指定した適用可否と成否をそのまま返し、呼ばれ方を記録する。
public struct StubInserter: PrimaryInserting {

    /// 呼ばれ方の記録。**戻り値だけを見るテストでは短絡の有無が検査できない**ため、
    /// 呼び出しの回数と渡された文字列を残す。
    public final class Calls: Sendable {
        private let canInserts = Atomic<Int>(0)
        private let tryInserts = Atomic<Int>(0)
        private let texts = Mutex<[String]>([])

        public var canInsertCount: Int { canInserts.load(ordering: .relaxed) }
        public var tryInsertCount: Int { tryInserts.load(ordering: .relaxed) }
        public var insertedTexts: [String] { texts.withLock { $0 } }

        fileprivate func recordCanInsert() { canInserts.add(1, ordering: .relaxed) }
        fileprivate func recordTryInsert(_ text: String) {
            tryInserts.add(1, ordering: .relaxed)
            texts.withLock { $0.append(text) }
        }
    }

    public let calls = Calls()
    private let canInsertValue: Bool
    private let succeeds: Bool

    public init(canInsert: Bool, succeeds: Bool) {
        self.canInsertValue = canInsert
        self.succeeds = succeeds
    }

    public func canInsert() -> Bool {
        calls.recordCanInsert()
        return canInsertValue
    }

    public func tryInsert(_ text: String) async -> Bool {
        calls.recordTryInsert(text)
        return succeeds
    }
}

/// テスト用。クリップボードへ残したテキストを覚えておくだけの最後の砦。
///
/// **値型にしてはならない。** 合成器へ渡した時点で複製され、テストが手元で見る記録と
/// 合成器が書き込む記録が別物になる（`#expect(clipboard.left == [...])` が常に空を見る）。
public final class StubClipboard: ClipboardLeaving {
    private let texts = Mutex<[String]>([])

    public init() {}

    /// 残されたテキスト。
    public var left: [String] { texts.withLock { $0 } }

    @discardableResult
    public func leave(_ text: String) -> Bool {
        texts.withLock { $0.append(text) }
        return true
    }
}

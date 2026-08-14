import Foundation
import Synchronization

/// 確定したテキストを、フォーカス中のアプリのカーソル位置へ入れる出口。
///
/// **ここは発話が外へ出る唯一の口である。** 認識も整形も成功した発話が、
/// ここで失敗すればどこにも届かない。音声は再現できないので、実装は
/// 「入らなかった」場合でも**テキストをクリップボードには残す**こと（基本設計書 §7）。
///
/// - Important: **唯一の例外は secure input が有効な場合。** そのときは挿入も残置も
///   行わず `.refusedSecureInput` を返す。ユーザーがパスワードを入力しているため、
///   残す方が害が大きい（`CompositeInserter.insert(_:)` に理由を書いた）。
///   **「発話を失っている」と見て残置を足してはならない。**
public protocol TextInserting: Sendable {
    /// テキストを挿入し、実際に使われた経路を返す。
    ///
    /// 戻り値は履歴に記録し、どのアプリでどの経路が使われたかの実地データとする（V-3）。
    /// **`.inserted(.clipboardOnly)` を返すときは、テキストが実際にクリップボードへ
    /// 残っていること。**
    ///
    /// **`.refusedSecureInput` は履歴に記録してはならない**（`InsertionOutcome` を参照）。
    func insert(_ text: String) async -> InsertionOutcome
}

/// 二段構えの各段。
public protocol PrimaryInserting: Sendable {
    /// この経路が適用できる状況か。
    ///
    /// **判定は安価でなければならない。** 適用外だった場合、この判定のコストは
    /// 次の段のコストへ丸ごと上乗せされる。挿入の予算は NFR-P5 の 50 ms しかない。
    func canInsert() -> Bool

    /// 挿入を試みる。
    ///
    /// **戻り値が `Bool` ではないのは、差し替え（FR-5(a) / FR-7）に「どのプロセスの・
    /// どの要素の・どの範囲へ書いたか」が要るためである**（設計 codex §2.2 の表:
    /// `Bool` では配送確認・pid・範囲・後から置換できるかを 1 つも表せない）。
    /// 錨を返せない段は `.inserted(anchor: nil)` を返す。**挿入は成功している。**
    ///
    /// - Important: `canInsert()` が false を返した段でこれを呼んではならない。
    ///   AX 経路では対象外の要素への書き込みを意味する。
    func tryInsert(_ text: String) async -> InsertionAttempt

    /// **挿入する前に、「後から差し替えられる見込みか」を答える**（FR-5(a) の分岐判定）。
    ///
    /// **見込みであって保証ではない。** 真を返しても錨が取れないことはある
    /// （キャレットが読めない相手など）。その場合の縮退は「整形が反映されないまま
    /// 生テキストが残る」で、(b) の分岐で整形が打ち切られたときと同じ結末になる。
    ///
    /// **偽を返す側は正確でなければならない。** 偽なのに真を返すと、(a) を選んだ
    /// 発話が整形をまったく受け取れなくなる（挿入済みなので (b) へは戻れない）。
    ///
    /// 既定は false。**錨を返せない段は何も実装しなくてよい。**
    func canCaptureAnchor() -> Bool
}

extension PrimaryInserting {
    /// 既定は「差し替えられない」。Pasteboard 経路のように範囲を持てない段はこのまま。
    public func canCaptureAnchor() -> Bool { false }
}

/// 差し替えの錨まで返せる挿入の口。
///
/// **`TextInserting.insert(_:)` はここから導出する**（下の既定実装）。
/// 2 つの経路を別々に実装すると、片方だけ直したときに挙動が割れる。
public protocol AnchoringTextInserting: TextInserting {
    /// テキストを挿入し、経路と**差し替えの錨**を返す。
    func insertCapturingAnchor(_ text: String) async -> AnchoredInsertion

    /// **挿入の前に、この発話を (a) の分岐へ載せてよいかを答える**（FR-5 の細目）。
    ///
    /// **この判定は挿入より前に要る。** 挿入してしまってから「錨が取れなかった」と
    /// 判っても、(b)（整形を待ってから挿入する）へは戻れない——生テキストが既に
    /// 欄にあるので、整形結果を入れる手段が差し替えしか無いためである。
    ///
    /// - Important: **AX の往復を伴う**（実測 0.1〜5.5 ms / 往復）。
    ///   (a) の分岐ではこの費用が NFR-P6a の予算に乗る（合計は未実測。検証項目 V-28）。
    /// - Note: 真を返しても錨が取れないことはある（`PrimaryInserting.canCaptureAnchor()`）。
    func canCaptureAnchor() -> Bool
}

extension AnchoringTextInserting {
    /// **錨を捨てるだけの薄い包み。** 挿入の手順は 1 つしかない。
    public func insert(_ text: String) async -> InsertionOutcome {
        await insertCapturingAnchor(text).outcome
    }
}

/// 最後の砦。挿入が全滅したときに、発話をクリップボードへ残す。
///
/// **secure input 中は呼ばれない**（合成器が入口で拒否する）。
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
    private let anchor: ReplacementAnchor?
    private let canCaptureAnchorValue: Bool?

    /// - Parameter anchor: 成功時に返す差し替えの錨。既定は nil（＝差し替えられない段）。
    /// - Parameter canCaptureAnchor: 事前判定の答え。省略すると `anchor != nil` に従う
    ///   （**判定と実際が食い違う相手**を作りたいときだけ明示する）。
    public init(
        canInsert: Bool, succeeds: Bool, anchor: ReplacementAnchor? = nil,
        canCaptureAnchor: Bool? = nil
    ) {
        self.canInsertValue = canInsert
        self.succeeds = succeeds
        self.anchor = anchor
        self.canCaptureAnchorValue = canCaptureAnchor
    }

    public func canInsert() -> Bool {
        calls.recordCanInsert()
        return canInsertValue
    }

    public func canCaptureAnchor() -> Bool {
        canCaptureAnchorValue ?? (anchor != nil)
    }

    public func tryInsert(_ text: String) async -> InsertionAttempt {
        calls.recordTryInsert(text)
        return succeeds ? .inserted(anchor: anchor) : .failed
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

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Synchronization

/// ⌘V の送出。`PasteboardInserter` から切り離してある。
///
/// **本物を直接埋め込むとテストが書けない。** `swift test` を回した瞬間に
/// 開発機のフォアグラウンドのアプリへ ⌘V が飛ぶことになる。
public protocol PasteShortcutSending: Sendable {
    /// この経路でキーイベントを届けられる状況か。
    var canSend: Bool { get }
    /// ⌘V を送る。送れたら true。
    func send() -> Bool
}

/// キーイベント送出の許可（`kTCCServicePostEvent`）を保持する箱。
///
/// **照会をキャッシュするために存在する。** `CGPreflightPostEventAccess()` は
/// 実測で**毎回 10.6 ms**（初回 16.7 ms / 最大 24.7 ms、50 回計測）掛かる。
/// 挿入のたびに呼ぶと NFR-P5 の 50 ms 予算の 2 割をここで使う。
///
/// 比較のため同条件で測った他の照会:
///
/// | API | 初回 | 2 回目以降の p50 |
/// |---|---|---|
/// | `AXIsProcessTrusted()` | 42.7 ms | 0.001 ms（プロセス内でキャッシュされている） |
/// | `CGPreflightPostEventAccess()` | 16.7 ms | **10.586 ms** |
/// | `IsSecureEventInputEnabled()` | 23.8 ms | 0.000 ms |
///
/// 権限は実行中に変わりうるので、**アプリ起動時と権限フローを通過した直後に
/// `refresh()` を呼ぶこと。**
///
/// - Important: **外部で権限を変えられたときに追随しない。** ユーザーがシステム設定で
///   許可しても、次の `refresh()` まで古い値を使う。発話は失われない
///   （`.inserted(.clipboardOnly)` へ落ちてクリップボードには残る）が、
///   **ユーザーから見ると「システム設定で許可したのに直らない」**という、
///   原因の特定が難しい状態になる。権限フローの画面から戻った時点で必ず呼ぶこと。
///   設定変更の監視までは行わない（詳細設計書 §9）。
public final class PostEventAuthorization: Sendable {

    /// 本番で使う共有インスタンス。生成時に一度だけ照会する。
    public static let shared = PostEventAuthorization()

    private let probe: @Sendable () -> Bool
    private let granted = Atomic<Bool>(false)

    /// - Parameter probe: 実際の照会。テストは偽物を挿して呼ばれ方を数える。
    public init(probe: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() }) {
        self.probe = probe
        refresh()
    }

    /// 保持している許可状態。**照会は行わない**ので安価。
    public var isGranted: Bool { granted.load(ordering: .relaxed) }

    /// 照会し直して保持し直す。起動時と権限フロー通過時に呼ぶ。
    @discardableResult
    public func refresh() -> Bool {
        let value = probe()
        granted.store(value, ordering: .relaxed)
        return value
    }
}

/// `CGEvent` で ⌘V を送る実装。
public struct SystemPasteShortcutSender: PasteShortcutSending {

    private static let vKeyCode: CGKeyCode = 0x09

    private let authorization: PostEventAuthorization
    private let isSecureInputEnabled: @Sendable () -> Bool

    public init(
        authorization: PostEventAuthorization = .shared,
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.authorization = authorization
        self.isSecureInputEnabled = isSecureInputEnabled
    }

    /// **キーイベントの送出は専用の許可を要し、さらに secure input に阻まれる。**
    ///
    /// 実測（macOS 26.5.2 / M3、許可の無いプロセスが自分の最前面ウィンドウへ ⌘V を送る。
    /// `Edit > Paste` を持つメインメニューを用意して「⌘V の結び先が無い」交絡は除いてある）:
    ///
    /// | 送出方法 | 貼り付いた回数 |
    /// |---|---|
    /// | `CGEvent.post(tap: .cgAnnotatedSessionEventTap)` | **0 / 3** |
    /// | `CGEvent.post(tap: .cghidEventTap)` | **0 / 3** |
    /// | `NSApp.postEvent(_:atStart:)`（TCC を通らない） | 3 / 3 |
    /// | `textView.paste(nil)`（直接呼び出し） | 3 / 3 |
    ///
    /// **`CGEvent.post` は `Void` を返す。** 捨てられたことを後から知る術が無い。
    /// 送出したつもりで成功を報告すると、履歴には `.pasteboard` と記録されるのに
    /// テキストはどこにも入っておらず、しかもクリップボードは復元済み——
    /// つまり**発話が消えたうえに成功として残る**。だから送る前にここで弾く。
    ///
    /// 門は 2 つある。**どちらが欠けても同じ結末になる。**
    ///
    /// 1. **`CGPreflightPostEventAccess()`**（`kTCCServicePostEvent`）。
    ///    `AXIsProcessTrusted()`（`kTCCServiceAccessibility`）**ではない。**
    ///    両者は別のレコードなので、片方だけ true の状態は原理的にありうる。
    ///    この機体では両方 false で一致したが、それは値の一致であって同一性ではない。
    ///    照会が高くつくので `PostEventAuthorization` でキャッシュしている。
    /// 2. **secure input が無効であること。** 他プロセスがパスワード欄などで
    ///    secure input を有効にしている間、合成キーイベントは配送されない。
    ///    TCC とは無関係なので、許可があっても届かない。
    ///    `IsSecureEventInputEnabled()` は実測 0.000 ms なので**毎回見る**
    ///    （状態が刻々と変わるため、キャッシュしてはならない）。
    ///
    /// - Note: `canSend` を見てから `send()` するまでの隙に secure input が
    ///   有効化される可能性は残る。窓は数 ms で、ここでは閉じられない。
    public var canSend: Bool {
        authorization.isGranted && !isSecureInputEnabled()
    }

    public func send() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let up = CGEvent(
                keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}

/// `NSPasteboard` を `Sendable` な文脈で持ち回すための箱。
///
/// `NSPasteboard` はスレッドセーフだが `Sendable` の注釈が無い。挿入は非同期文脈
/// ＝協調スレッドプールで走るので、不検査の合意をここへ一度だけ置き、
/// `@unchecked` を各所へ撒かないようにする。
struct PasteboardBox: @unchecked Sendable {
    let pasteboard: NSPasteboard
}

/// クリップボードへテキストを載せ、⌘V を送って貼り付けさせる経路。
///
/// AX 経路が使えないアプリ（Electron 製など）でも通ることが多い代わりに、
/// **ユーザーのクリップボードを一時的に奪う。** 退避と復元を必ず伴う。
public struct PasteboardInserter: PrimaryInserting, ClipboardLeaving {

    /// ⌘V 送出から復元までの待ち時間。
    ///
    /// 短すぎると貼り付く前にクリップボードが元へ戻り、**挿入が空振りする。**
    /// 長すぎるとその間ユーザーのクリップボードが奪われたままになる。
    ///
    /// 実測（macOS 26.5.2 / M3。⌘V の送出から実際に貼り付く＝
    /// `NSTextViewDelegate.textDidChange` が呼ばれるまで。各条件 50 回）:
    ///
    /// | 条件 | p50 | p90 | 最大 |
    /// |---|---|---|---|
    /// | 低負荷（load average 約 2.5） | 33.3 ms | 35.4 ms | 36.0 ms |
    /// | 負荷下（`yes` 16 本、load average 約 13.5） | 31.4 ms | 34.8 ms | 35.3 ms |
    ///
    /// CPU 負荷では動かない（約 33 ms は 60 Hz の 2 フレームにあたる固定の間隔で、
    /// 計算資源ではなくイベント配送の周期で決まっている）。
    ///
    /// **この実測には上限として扱えない留保が 2 つある。**
    /// 1. 計測は `NSApp.postEvent` で行った。この機体に送出の許可
    ///    （`kTCCServicePostEvent`）が無く `CGEvent.post` が黙って捨てられるため
    ///    （`SystemPasteShortcutSender.canSend` 参照）、
    ///    **WindowServer を経由する分の遅延が入っていない。**
    /// 2. 貼り付け先は自プロセスの `NSTextView` である。相手が重いアプリなら
    ///    相手のランループ待ちが上乗せされる。
    ///
    /// つまり実測 35 ms は**下限**であり、120 ms はそれに対する約 3.4 倍の余裕である。
    /// 実アプリでの妥当性は V-3（Task 11）で確かめる。
    ///
    /// なお、この待ち時間は NFR-P5（テキスト挿入 50 ms 以内）には数えない。
    /// 挿入はテキストが貼り付いた時点で完了しており、復元はその後始末である。
    public static let defaultRestoreDelay: Duration = .milliseconds(120)

    private let pasteboard: PasteboardBox
    private let sender: any PasteShortcutSending
    private let restoreDelay: Duration

    public init(
        pasteboard: NSPasteboard = .general,
        sender: any PasteShortcutSending = SystemPasteShortcutSender(),
        restoreDelay: Duration = PasteboardInserter.defaultRestoreDelay
    ) {
        self.pasteboard = PasteboardBox(pasteboard: pasteboard)
        self.sender = sender
        self.restoreDelay = restoreDelay
    }

    /// **常に true ではない。** ⌘V を届けられなければ、この経路は何も達成しない
    /// （`SystemPasteShortcutSender.canSend` に実測を書いた）。
    public func canInsert() -> Bool { sender.canSend }

    public func tryInsert(_ text: String) async -> Bool {
        let board = pasteboard.pasteboard
        let saved = Self.snapshot(of: board)

        board.clearContents()
        guard board.setString(text, forType: .string) else {
            // テキストを載せられていない。ユーザーの内容だけ消して終わるのは損なので戻す。
            Self.restore(saved, to: board)
            return false
        }

        guard sender.send() else {
            // **ここで復元してはならない。** 貼り付いてもいないのにクリップボードを
            // 元へ戻すと、発話がどこにも残らない。ユーザーの元の内容を失う代償を
            // 払ってでもテキストを残す。
            //
            // **これは Task 8 で新設した判断であり、既存規定の適用ではない。**
            // 詳細設計書 §6.3 に元からあったのは「**復元**失敗時」の規定で、
            // 「**送出**失敗時」については何も定めていなかった。
            // 「クリップボードを壊さない」を捨てて「発話を失わない」を取っている。
            //
            // 本番でここへ来るのは `CGEvent` の**生成**に失敗した場合だけである。
            // TCC と secure input に由来する失敗は `canInsert()` が先に弾く。
            return false
        }

        try? await Task.sleep(for: restoreDelay)
        Self.restore(saved, to: board)
        return true
    }

    /// 最後の砦。挿入が全滅したとき、発話をクリップボードへ残す。
    @discardableResult
    public func leave(_ text: String) -> Bool {
        let board = pasteboard.pasteboard
        board.clearContents()
        return board.setString(text, forType: .string)
    }

    // MARK: - クリップボードの退避と復元

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    /// 画像やリッチテキストを壊さないよう、全タイプを退避する。
    ///
    /// 文字列だけを退避する実装だと、貼るつもりで溜めていた画像がディクテーション
    /// 1 回で消える。
    ///
    /// - Note: **AppKit の警告が出る場合がある。** 一部の型は「約束」として載っており、
    ///   `data(forType:)` がその場で実体化を要求する。これを主スレッド以外から行うと
    ///   AppKit が
    ///   `NSPasteboard: synchronous promise fulfillment requested from a background thread!`
    ///   を出す。挿入は非同期文脈で走るので、必ず主スレッド以外から呼ばれる。
    ///
    ///   実測（macOS 26.5.2 / M3。新しいクリップボードへ内容を載せ、**最初の読み取りを**
    ///   協調スレッドプールから行う。主スレッドで先に読むと約束が実体化済みになり
    ///   警告が出なくなるため、その順序を避けている）:
    ///
    ///   | クリップボードの内容 | 警告 | 退避に要した時間 |
    ///   |---|---|---|
    ///   | 平文のみ | 出ない | 0.88 ms |
    ///   | 画像 + 平文 | 出ない | 0.09 ms |
    ///   | 平文の複数項目 | 出ない | 0.07 ms |
    ///   | `NSAttributedString`（ブラウザ等からのコピー） | **出る** | 0.50 ms |
    ///
    ///   **リッチテキストは日常的にコピーされる**ので、警告は普通に出ると考えてよい。
    ///   ただし実測では**ハングせず（10 回で最大 1.43 ms）、データも欠けなかった。**
    ///   約束の提供元がプロセス内の AppKit だからである。
    ///
    ///   **提供元が別プロセスの場合（他アプリのファイル約束など）は未検証。**
    ///   そこでは実体化が相手プロセスとの往復になり、遅延や失敗がありうる。
    ///   主スレッドで退避する形へ移すことも考えられるが、主スレッドが塞がっていると
    ///   今度は挿入そのものが止まる。実アプリでの挙動を見てから決める（V-3 / Task 11）。
    private static func snapshot(of pasteboard: NSPasteboard) -> Snapshot {
        pasteboard.pasteboardItems?.map { item in
            var stored: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { stored[type] = data }
            }
            return stored
        } ?? []
    }

    /// 退避した内容を書き戻す。
    ///
    /// **空の退避では何もしない。** 元が空だったクリップボードを空で上書きすると、
    /// 挿入したテキストが消えるだけで誰も得をしない。残す方を選ぶ。
    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        guard !snapshot.isEmpty else { return }
        pasteboard.clearContents()
        let items = snapshot.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

// MARK: - テスト用

/// テスト用。⌘V を実際には送らず、送出の瞬間のクリップボードを記録する。
public struct StubPasteShortcutSender: PasteShortcutSending {

    /// 送出のされ方の記録。「復元後に元へ戻っている」だけを見ても、送出の時点で
    /// テキストが載っていたかは判らない。その瞬間を残す。
    public final class Calls: Sendable {
        private let sends = Atomic<Int>(0)
        private let strings = Mutex<[String?]>([])

        public var sendCount: Int { sends.load(ordering: .relaxed) }
        /// 送出の瞬間にクリップボードへ載っていた文字列。
        public var observed: [String?] { strings.withLock { $0 } }

        fileprivate func record(_ string: String?) {
            sends.add(1, ordering: .relaxed)
            strings.withLock { $0.append(string) }
        }
    }

    public let calls = Calls()
    private let canSendValue: Bool
    private let succeeds: Bool
    private let observing: PasteboardBox?

    public init(canSend: Bool, succeeds: Bool = true, observing: NSPasteboard? = nil) {
        self.canSendValue = canSend
        self.succeeds = succeeds
        self.observing = observing.map(PasteboardBox.init)
    }

    public var canSend: Bool { canSendValue }

    public func send() -> Bool {
        calls.record(observing?.pasteboard.string(forType: .string))
        return succeeds
    }
}

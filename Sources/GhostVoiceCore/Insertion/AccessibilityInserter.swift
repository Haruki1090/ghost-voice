import ApplicationServices
import Foundation
import Synchronization

/// フォーカス中の要素への参照。中身は実装ごとに違うので不透明にしてある。
public protocol FocusedElement: Sendable {}

/// AX の要素を触る部分。`AccessibilityInserter` の判断と、AX API の呼び出しを分ける継ぎ目。
///
/// **この継ぎ目が無いと `AccessibilityInserter` は一行も検査できない。** AX API は
/// TCC の許可を要し、許可のある機体でも結果は「その瞬間に何にフォーカスしているか」に
/// 依存する。判断の側だけでも決定的に検査できるようにしてある。
public protocol AccessibilityProbing: Sendable {
    /// 現在フォーカスされている要素。取れなければ nil。
    func focusedElement() -> (any FocusedElement)?
    /// 要素の役割（`AXTextField` 等）。読めなければ nil。
    func role(of element: any FocusedElement) -> String?
    /// 選択テキスト属性へ書き込めるか。
    func isSelectedTextSettable(_ element: any FocusedElement) -> Bool
    /// 要素を持つプロセスの ID。判らなければ nil。
    func processIdentifier(of element: any FocusedElement) -> pid_t?
    /// 選択テキストを置き換える。成功したら true。
    func setSelectedText(_ text: String, on element: any FocusedElement) -> Bool
}

/// Accessibility API でフォーカス中の入力欄へ直接書き込む経路。
///
/// 一段目に置く。Pasteboard 経路と違ってユーザーのクリップボードを触らず、
/// キーイベントの送出も要らないぶん副作用が小さい。ただし Electron 製アプリなど
/// 一部で無言失敗するため、経路を一本に絞ることはできない（リスク R-4）。
///
/// - Important: **無言失敗そのものは検出できない。** 成否は事前判定（`canInsert()` の
///   4 条件）と `AXUIElementSetAttributeValue` のステータスだけで判断しており、
///   **書き込み後の読み戻しは行わない。** 読み戻して「入っていない」と判定しても、
///   それが失敗なのかアプリがテキストを変換しただけなのかを区別できず、
///   誤ってフォールバックへ落とすと**二重に挿入する**（入らないことより悪い場合がある）。
///
///   したがって **AX が `.success` を返しながら何も入らなかった場合、`.ax` が返り
///   フォールバックは走らず、発話は失われる。** これは既知の残余リスクで、
///   発生の有無は V-3 で確かめる（詳細設計書 §6.2 / 要件定義書 R-4）。
public struct AccessibilityInserter: PrimaryInserting {

    /// 書き込みを試してよい役割。詳細設計書 §6.2 の判定 2。
    static let insertableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    private let accessibility: any AccessibilityProbing
    private let ownProcessIdentifier: pid_t

    public init(
        accessibility: any AccessibilityProbing = SystemAccessibility(),
        ownProcessIdentifier: pid_t = getpid()
    ) {
        self.accessibility = accessibility
        self.ownProcessIdentifier = ownProcessIdentifier
    }

    /// 4 条件をすべて満たす場合のみ AX 経路を使う。
    ///
    /// 1. フォーカス要素が取れる
    /// 2. **その要素が自分自身のものでない**（下記の理由で必須）
    /// 3. 役割がテキスト入力である
    /// 4. 選択テキスト属性が書き込み可能である
    ///
    /// 詳細設計書 §6.2 は 1 / 3 / 4 の 3 条件を挙げている。2 は実測で足したもので、
    /// 理由は `isSafeTarget(_:)` に書いた。
    ///
    /// 判定の順序は**安いものから**。2 は AX の往復を伴わない局所的な検査なので、
    /// 3 と 4 の問い合わせより先に済ませる。
    public func canInsert() -> Bool {
        guard let element = accessibility.focusedElement(), isSafeTarget(element) else {
            return false
        }
        guard let role = accessibility.role(of: element),
              Self.insertableRoles.contains(role)
        else { return false }

        return accessibility.isSelectedTextSettable(element)
    }

    public func tryInsert(_ text: String) async -> Bool {
        // `canInsert()` とは別にフォーカスを取り直す。その隙にフォーカスが動きうるので、
        // 自プロセス判定はここでも掛ける。
        guard let element = accessibility.focusedElement(), isSafeTarget(element) else {
            return false
        }
        return accessibility.setSelectedText(text, on: element)
    }

    /// 書き込んでも安全な相手か。**自分自身のプロセスは除外する。**
    ///
    /// 自プロセスの要素へ `AXUIElementSetAttributeValue` をメインスレッド以外から
    /// 投げると**永久にブロックする**。実測（macOS 26.5.2 / M3、AppKit を起動した
    /// プロセスが自分の `NSTextView` を狙う）:
    ///
    /// | 呼び出し元 | 属性 | 結果 |
    /// |---|---|---|
    /// | 背景スレッド | `kAXSelectedText` | 12 秒で戻らず打ち切り |
    /// | 背景スレッド | `kAXValue` | 12 秒で戻らず打ち切り |
    /// | 背景スレッド | 同上 + `AXUIElementSetMessagingTimeout(2.0)` | **タイムアウトが効かない。**12 秒で戻らず打ち切り |
    /// | メインスレッド | `kAXSelectedText` | 52.9 ms で成功 |
    ///
    /// 読み取り（役割・可書き込み性）は背景スレッドからでも 0.1〜5.5 ms で返る。
    /// 詰まるのは書き込みだけである。
    ///
    /// 挿入は非同期文脈＝協調スレッドプールで走るため、フォーカスが自分の HUD や
    /// 設定画面にある瞬間に挿入が走ると、そのタスクが二度と返らない。
    /// メッセージングのタイムアウトでは救えないので、**狙わないことで避ける。**
    /// 自分自身へディクテーションする必要はそもそも無い。
    ///
    /// プロセスが判らない要素も除外する。「自分ではない」と断言できないため。
    private func isSafeTarget(_ element: any FocusedElement) -> Bool {
        guard let pid = accessibility.processIdentifier(of: element) else { return false }
        return pid != ownProcessIdentifier
    }
}

/// 実際の Accessibility API を叩く実装。
public struct SystemAccessibility: AccessibilityProbing {

    /// 実 AX 要素の包み。
    ///
    /// `AXUIElement` は CoreFoundation の型で `Sendable` の注釈が無い。要素は
    /// スレッドをまたいで持ち回るので、ここで一度だけ不検査の合意を置く。
    struct Element: FocusedElement, @unchecked Sendable {
        let ax: AXUIElement
    }

    /// AX の往復に掛ける上限（秒）。
    ///
    /// 既定を使うと上限は 6 秒である。フォアグラウンドのアプリが固まっていると、
    /// **適用可否の判定だけで 6 秒ユーザーを待たせる。** 挿入の予算は NFR-P5 の
    /// 50 ms しかないので、そこまで待つ意味は無い。
    ///
    /// 0.5 秒は「まともなアプリなら確実に返る」側に大きく振った値である
    /// （正常な往復は実測 0.1〜5.5 ms）。性能目標ではなく、固まった相手に
    /// 引きずられないための上限として置いている。
    ///
    /// - Note: この上限は**自プロセスを狙った書き込みには効かない**（実測。
    ///   `AccessibilityInserter.isSafeTarget(_:)` 参照）。そちらは狙わないことで避ける。
    ///
    /// - Note: **この値が実際に効くことは検査できていない。** 効果が現れるのは
    ///   「AX 権限があり、かつ相手のアプリが固まっている」場合だけで、その状況を
    ///   自動テストから作れない。値そのものは固定してある（`messagingTimeoutIsPinned`）。
    let messagingTimeout: Float

    public init(messagingTimeout: Duration = .milliseconds(500)) {
        self.messagingTimeout = Self.inSeconds(messagingTimeout)
    }

    /// AX API は `Float` 秒を要求する。
    private static func inSeconds(_ duration: Duration) -> Float {
        let (seconds, attoseconds) = duration.components
        return Float(Double(seconds) + Double(attoseconds) / 1e18)
    }

    /// 最前面のアプリを名指しして、その中のフォーカス要素を引く。
    ///
    /// **システムワイド要素は使わない（V-3 の実測 / 2026-08-14）。**
    /// `AXUIElementCreateSystemWide()` から `kAXFocusedUIElementAttribute` を引くと、
    /// **この機体では全アプリで即座に `cannotComplete`（-25204）を返した。**
    /// メッセージングのタイムアウトを 0.5 秒から 5 秒へ伸ばしても **0 ms で落ちる**ので、
    /// 相手の応答待ちではなく、システムワイド要素そのものが使えない。
    /// **一方、`AXUIElementCreateApplication(pid)` で名指しすれば同じ属性が取れる。**
    ///
    /// この誤りのせいで、AX 経路は実機で一度も使われていなかった。30 回以上の挿入が
    /// すべて Pasteboard へ落ち、そのぶん復元待ちをクリティカルパスで払っていた
    /// （メモは `AXTextArea` / 書き込み可、Chrome のアドレスバーは `AXTextField` または
    /// `AXComboBox` / 書き込み可で、**どちらも AX 経路が使えるはずだった**）。
    ///
    /// **最前面の pid は `CGWindowListCopyWindowInfo` から取る。**
    /// `NSWorkspace.frontmostApplication` は通知で更新されるため、
    /// **ランループを回さない文脈（この挿入器は actor 上で動く）では古い値を返し続ける**
    /// （実測: 12 回中 10 回、切り替えたはずの最前面を追随できなかった）。
    /// ウィンドウ名は読まないので、画面収録の許可は要らない。
    public func focusedElement() -> (any FocusedElement)? {
        guard let pid = Self.frontmostProcessIdentifier() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            application, kAXFocusedUIElementAttribute as CFString, &value
        )
        guard status == .success else { return nil }
        return Self.element(from: value)
    }

    /// 画面上のいちばん手前のウィンドウの持ち主。
    ///
    /// `kCGWindowLayer == 0` は通常のアプリケーションウィンドウを指す。メニューバーや
    /// カーソルなどは別のレイヤに載るので、それらを飛ばして最初に見つかったものを返す。
    static func frontmostProcessIdentifier() -> pid_t? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }
        return frontmostProcessIdentifier(in: windows)
    }

    /// 絞り込みの規則だけを取り出したもの。**実際のウィンドウ一覧に依存せず検査できる。**
    ///
    /// 一覧は前面から順に並ぶので、条件に合う最初のものが最前面である。
    static func frontmostProcessIdentifier(in windows: [[String: Any]]) -> pid_t? {
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            return pid
        }
        return nil
    }

    /// AX の属性値を要素として包む。**型を確かめてから包むこと。**
    ///
    /// 属性が `AXUIElement` 以外を返した場合、強制キャスト（`value as! AXUIElement`）は
    /// プロセスを落とす。ここは発話の出口であり、落ちれば発話は失われる。
    ///
    /// 関数として切り出してあるのは検査のため。`focusedElement()` は AX 権限が無いと
    /// 何も返さないので、権限の無い機体では型検査の分岐を通せない。
    static func element(from value: CFTypeRef?) -> Element? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return Element(ax: unsafeDowncast(value, to: AXUIElement.self))
    }

    public func role(of element: any FocusedElement) -> String? {
        guard let element = element as? Element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element.ax, kAXRoleAttribute as CFString, &value
        ) == .success else { return nil }
        return value as? String
    }

    public func isSelectedTextSettable(_ element: any FocusedElement) -> Bool {
        guard let element = element as? Element else { return false }
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(
            element.ax, kAXSelectedTextAttribute as CFString, &settable
        )
        return status == .success && settable.boolValue
    }

    public func processIdentifier(of element: any FocusedElement) -> pid_t? {
        guard let element = element as? Element else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element.ax, &pid) == .success else { return nil }
        return pid
    }

    public func setSelectedText(_ text: String, on element: any FocusedElement) -> Bool {
        guard let element = element as? Element else { return false }
        return AXUIElementSetAttributeValue(
            element.ax, kAXSelectedTextAttribute as CFString, text as CFString
        ) == .success
    }
}

// MARK: - テスト用

/// テスト用。AX の応答を指定した値で返し、問い合わせられ方を記録する。
public struct FakeAccessibility: AccessibilityProbing {

    /// 偽の要素。AX から読み取れる事実をそのまま持つ。
    public struct Element: FocusedElement {
        public let role: String?
        public let isSelectedTextSettable: Bool
        public let processIdentifier: pid_t?
        /// 書き込みを受け入れるか。AX が成功を返すかどうかを模す。
        public let acceptsWrite: Bool

        public init(
            role: String?, isSelectedTextSettable: Bool,
            processIdentifier: pid_t?, acceptsWrite: Bool
        ) {
            self.role = role
            self.isSelectedTextSettable = isSelectedTextSettable
            self.processIdentifier = processIdentifier
            self.acceptsWrite = acceptsWrite
        }
    }

    /// 問い合わせられ方の記録。判定の順序と、無駄な往復の有無を検査するために要る。
    public final class Calls: Sendable {
        private let roles = Atomic<Int>(0)
        private let settables = Atomic<Int>(0)
        private let texts = Mutex<[String]>([])

        public var roleCount: Int { roles.load(ordering: .relaxed) }
        public var settableCount: Int { settables.load(ordering: .relaxed) }
        public var writtenTexts: [String] { texts.withLock { $0 } }

        fileprivate func recordRole() { roles.add(1, ordering: .relaxed) }
        fileprivate func recordSettable() { settables.add(1, ordering: .relaxed) }
        fileprivate func recordWrite(_ text: String) { texts.withLock { $0.append(text) } }
    }

    public let calls = Calls()
    private let focused: Element?

    public init(focused: Element?) {
        self.focused = focused
    }

    public func focusedElement() -> (any FocusedElement)? { focused }

    public func role(of element: any FocusedElement) -> String? {
        calls.recordRole()
        return (element as? Element)?.role
    }

    public func isSelectedTextSettable(_ element: any FocusedElement) -> Bool {
        calls.recordSettable()
        return (element as? Element)?.isSelectedTextSettable ?? false
    }

    public func processIdentifier(of element: any FocusedElement) -> pid_t? {
        (element as? Element)?.processIdentifier
    }

    public func setSelectedText(_ text: String, on element: any FocusedElement) -> Bool {
        guard let element = element as? Element, element.acceptsWrite else { return false }
        calls.recordWrite(text)
        return true
    }
}

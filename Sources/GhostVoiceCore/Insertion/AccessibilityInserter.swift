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

/// **差し替え（FR-5(a) / FR-7）のためだけの継ぎ目。**
///
/// `AccessibilityProbing` と分けてあるのは規約ではなく**線引きのため**である。
/// 承認された NFR-V3 の最小例外——「自分が直前に書き込んだ範囲の文字列だけを読む」——は
/// **この protocol の中にしか存在しない。** 主たる挿入経路（`AccessibilityInserter.tryInsert`
/// の書き込みと `CompositeInserter`）は読み戻しを一切行わない（詳細設計書 §6.2 の裁定は
/// そのまま）。どこまで読んでいるかを問われたら、見るのはこの protocol の実装だけでよい。
///
/// - Important: **`kAXValue`（欄の全文）・`kAXNumberOfCharacters`（全長）・
///   `kAXVisibleCharacterRange`（画面に見えている範囲）は、この継ぎ目に置かない。**
///   置いた時点で「周辺テキストを読み取らない」が守れなくなる（設計 opus §2.3 の表）。
public protocol AccessibilityRangeProbing: Sendable {
    /// 選択範囲属性へ書き込めるか（設計 opus §2.2 の C-5）。
    ///
    /// **SDK ヘッダの `Writable? Yes` は根拠にならない。** 唯一の根拠は
    /// `AXUIElementIsAttributeSettable` の実行時の答えである（同 §2.3 の注記）。
    func isSelectedTextRangeSettable(_ element: any FocusedElement) -> Bool

    /// 現在の選択範囲。**返るのは位置と長さの整数 2 つで、文字を含まない。**
    func selectedRange(of element: any FocusedElement) -> AXTextRange?

    /// 選択範囲を設定する。成功したら true。
    func setSelectedRange(_ range: AXTextRange, on element: any FocusedElement) -> Bool

    /// **指定した範囲の文字列が `expected` と完全に一致するかだけを返す。**
    ///
    /// **文字列そのものは返さない。** これが NFR-V3 の最小例外を型で閉じ込めている
    /// 箇所である（承認された 4 条件のうち 2・3・4）。実装は読み取った値を
    /// 比較に使い終えたらその場で捨てること。ログにも出さない。
    ///
    /// 呼び出し側は**自分が書いた範囲以外を渡してはならない**（条件 1）。
    /// この約束は `TextReplacer` の単体検査で固定してある
    /// （`ReplacementPrivacyTests`）。
    func matches(_ expected: String, in range: AXTextRange, of element: any FocusedElement)
        -> RangeMatch

    /// 2 つの要素が同じ入力欄を指すか（設計 opus §2.2 の C-4）。
    ///
    /// - Note: **時間を跨いだ要素の同一性が期待どおりかは未実測**（検証項目 V-26）。
    ///   外しても「別の欄だ」と判定して中止に倒れる。
    func isSameElement(_ lhs: any FocusedElement, _ rhs: any FocusedElement) -> Bool
}

/// 挿入と差し替えの両方を行える AX の継ぎ目。
public typealias ReplacementCapableAccessibility = AccessibilityProbing & AccessibilityRangeProbing

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

    private let accessibility: any ReplacementCapableAccessibility
    private let ownProcessIdentifier: pid_t
    private let epoch: InsertionEpoch
    private let capturesReplacementAnchor: Bool

    /// - Parameters:
    ///   - epoch: 挿入の世代。**差し替え器と同じものを渡すこと**（`CompositeInserter.systemStack`
    ///     が本番の組み立てを行う）。別物を渡すと差し替えが常に「失効した」と判定される。
    ///   - capturesReplacementAnchor: 差し替えの錨を取るか。取ると挿入の後に
    ///     **AX の読みが 3 往復**増える（実測 0.1〜5.5 ms / 往復。合計は未実測 = V-27）。
    ///     false にすると差し替えも Undo も効かなくなるが、挿入そのものは変わらない。
    public init(
        accessibility: any ReplacementCapableAccessibility = SystemAccessibility(),
        ownProcessIdentifier: pid_t = getpid(),
        epoch: InsertionEpoch = InsertionEpoch(),
        capturesReplacementAnchor: Bool = true
    ) {
        self.accessibility = accessibility
        self.ownProcessIdentifier = ownProcessIdentifier
        self.epoch = epoch
        self.capturesReplacementAnchor = capturesReplacementAnchor
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

    public func tryInsert(_ text: String) async -> InsertionAttempt {
        // `canInsert()` とは別にフォーカスを取り直す。その隙にフォーカスが動きうるので、
        // 自プロセス判定はここでも掛ける。
        guard let element = accessibility.focusedElement(),
              let pid = safeTargetProcessIdentifier(element)
        else { return .failed }

        // **書き込みの前に選択位置を読む。** 書いた後では「どこから書いたか」が判らない
        // （下記）。読むのは整数 2 つで、文字は含まない。
        let before = capturesReplacementAnchor ? accessibility.selectedRange(of: element) : nil

        guard accessibility.setSelectedText(text, on: element) else { return .failed }

        // **ここから先で何が起きても、テキストは既に入っている。**
        // 錨が取れなければ差し替えを諦めるだけで、挿入は成功のまま返す。
        return .inserted(anchor: anchor(for: text, on: element, pid: pid, before: before))
    }

    /// 書き込んだ場所の錨を作る。取れなければ nil（＝後から差し替えない）。
    ///
    /// **長さを自分で数えない。** `text.count` も `text.utf16.count` も使わない。
    /// AX の範囲の単位は未実測で、3 通りに割れうる（`AXTextRange` の注記）。
    /// **書き込みの前後で選択位置を読み、その差だけを長さとして使う。**
    /// これなら単位が何であっても、相手が数えた値をそのまま使うことになる。
    ///
    /// 最後に**読み戻して一致を確かめる**（設計 opus §2.2 の C-6）。ここで一致しない
    /// 相手は、そもそも差し替えても検証できないので錨を作らない。
    private func anchor(
        for text: String, on element: any FocusedElement, pid: pid_t, before: AXTextRange?
    ) -> ReplacementAnchor? {
        guard capturesReplacementAnchor, let before else { return nil }
        // 書いた直後はキャレットが挿入文字列の直後にあるはず。**そうでない相手は諦める**
        // （V-25。前提が外れても「錨を作らない」に倒れるだけ）。
        guard let after = accessibility.selectedRange(of: element),
              after.length == 0,
              after.location > before.location
        else { return nil }

        let range = AXTextRange(
            location: before.location, length: after.location - before.location)
        guard accessibility.matches(text, in: range, of: element) == .matched else { return nil }

        return ReplacementAnchor(
            element: element, processIdentifier: pid, range: range, text: text,
            previousText: nil, epoch: epoch.current
        )
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
        safeTargetProcessIdentifier(element) != nil
    }

    /// 安全な相手ならそのプロセス ID。錨に載せるので `Bool` ではなく pid を返す形にしてある。
    private func safeTargetProcessIdentifier(_ element: any FocusedElement) -> pid_t? {
        guard let pid = accessibility.processIdentifier(of: element),
              pid != ownProcessIdentifier
        else { return nil }
        return pid
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

// MARK: - 差し替えのための読み書き（NFR-V3 の最小例外はここだけ）

extension SystemAccessibility: AccessibilityRangeProbing {

    public func isSelectedTextRangeSettable(_ element: any FocusedElement) -> Bool {
        guard let element = element as? Element else { return false }
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(
            element.ax, kAXSelectedTextRangeAttribute as CFString, &settable
        )
        return status == .success && settable.boolValue
    }

    public func selectedRange(of element: any FocusedElement) -> AXTextRange? {
        guard let element = element as? Element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element.ax, kAXSelectedTextRangeAttribute as CFString, &value
        ) == .success else { return nil }
        return Self.range(from: value)
    }

    /// `AXValue` から `CFRange` を取り出す。**強制キャストしてはならない**
    /// （`element(from:)` と同じ理由。落ちれば発話が失われる）。
    ///
    /// 関数として切り出してあるのは検査のため。実要素からは AX 権限が無いと何も返らない。
    static func range(from value: CFTypeRef?) -> AXTextRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return AXTextRange(location: range.location, length: range.length)
    }

    /// `AXTextRange` を AX の値へ包む。包めなければ nil。
    static func axValue(for range: AXTextRange) -> AXValue? {
        var cfRange = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &cfRange)
    }

    public func setSelectedRange(_ range: AXTextRange, on element: any FocusedElement) -> Bool {
        guard let element = element as? Element, let value = Self.axValue(for: range) else {
            return false
        }
        return AXUIElementSetAttributeValue(
            element.ax, kAXSelectedTextRangeAttribute as CFString, value
        ) == .success
    }

    /// **承認された NFR-V3 の最小例外の全部がこの関数である。**
    ///
    /// 読み取った文字列はこの関数を出ない。呼び出し側へ返るのは `RangeMatch` の
    /// 3 値だけで、**一致しなかった場合にその内容を知る手段は無い**（条件 2・3・4）。
    /// 範囲を自分が書いた場所に限る責任は呼び出し側にある（条件 1。`TextReplacer`）。
    ///
    /// - Note: **実アプリが `AXStringForRange` に応えるかは未実測**（検証項目 V-24）。
    ///   応えなければ `.unreadable` が返り、差し替えは中止される（＝生テキストが残る）。
    public func matches(
        _ expected: String, in range: AXTextRange, of element: any FocusedElement
    ) -> RangeMatch {
        guard let element = element as? Element, let parameter = Self.axValue(for: range) else {
            return .unreadable
        }
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element.ax, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
        )
        guard status == .success, let string = value as? String else { return .unreadable }
        // ここで真偽値 1 つへ落とす。**`string` はこの行より先へ出ない。**
        return string == expected ? .matched : .differed
    }

    public func isSameElement(_ lhs: any FocusedElement, _ rhs: any FocusedElement) -> Bool {
        guard let lhs = lhs as? Element, let rhs = rhs as? Element else { return false }
        return CFEqual(lhs.ax, rhs.ax)
    }
}

// MARK: - テスト用

/// テスト用の入力欄。**差し替えの全経路を決定的に駆動するために要る。**
///
/// 実機のアプリへ書き込む検査は行えない（安全制約）。R-4 の無言失敗も「消えるだけ」も
/// 実機では未観測なので、**代役でしか再現できない。**
///
/// - Important: **この欄の範囲の単位は `Character` である。** 実機の AX が何を単位に
///   するかは未実測（V-23）。`TextReplacer` は長さを自分で数えず、この欄が返した
///   位置の差だけを使うので、単位が違っても通る作りになっている。
public final class FakeTextField: Sendable {

    /// `kAXSelectedText` への書き込みが実際に何を起こすか。
    public enum WriteBehavior: Sendable, Equatable {
        /// 素直に置き換える。
        case normal
        /// AX がエラーを返す（何も起きない）。
        case rejected
        /// **成功を返しながら何も入らない（R-4 の無言失敗）。**
        case silentNoOp
        /// 成功を返すが、書いたのとは別の内容になる。**喪失の疑い。**
        case replaces(with: String)
        /// 選択範囲を消すだけで、新しい文字列を書かない。**喪失そのもの。**
        case erases
    }

    /// 書き込みの後にキャレットがどこへ行くか。
    public enum CaretAfterWrite: Sendable, Equatable {
        /// 実際に置かれた文字列の直後（ふつうの挙動）。
        case endOfWrittenText
        /// 書き込んだ範囲の先頭。
        case startOfRange
        /// 動かない（選択したままになる）。
        case unchanged
        /// 選択範囲が読めなくなる。
        case unreadable
    }

    private struct State {
        var content: [Character]
        var selection: AXTextRange
    }

    private let state: Mutex<State>
    private let behavior: WriteBehavior
    private let caret: CaretAfterWrite
    /// `AXStringForRange` に応えるか。false の相手は差し替えられない。
    private let respondsToStringForRange: Bool
    /// 「書き込み可能」と答えるのに、選択範囲の設定が実際には失敗する相手。
    private let selectionWriteFails: Bool

    public init(
        content: String = "",
        selection: AXTextRange? = nil,
        behavior: WriteBehavior = .normal,
        caret: CaretAfterWrite = .endOfWrittenText,
        respondsToStringForRange: Bool = true,
        selectionWriteFails: Bool = false
    ) {
        let characters = Array(content)
        self.state = Mutex(
            State(
                content: characters,
                selection: selection ?? AXTextRange(location: characters.count, length: 0)
            ))
        self.behavior = behavior
        self.caret = caret
        self.respondsToStringForRange = respondsToStringForRange
        self.selectionWriteFails = selectionWriteFails
    }

    /// 欄の中身。**検査からのみ見る。** 製品コードはここを読まない（NFR-V3）。
    public var content: String { state.withLock { String($0.content) } }

    /// **利用者が手で編集した状況を作る。** 検査からのみ呼ぶ。
    public func userEdits(to content: String) {
        state.withLock {
            $0.content = Array(content)
            $0.selection = AXTextRange(location: $0.content.count, length: 0)
        }
    }

    fileprivate var currentSelection: AXTextRange? {
        caret == .unreadable ? nil : state.withLock { $0.selection }
    }

    fileprivate func select(_ range: AXTextRange) -> Bool {
        guard !selectionWriteFails else { return false }
        return state.withLock {
            guard range.location >= 0, range.length >= 0, range.end <= $0.content.count else {
                return false
            }
            $0.selection = range
            return true
        }
    }

    fileprivate func write(_ text: String) -> Bool {
        guard behavior != .rejected else { return false }
        return state.withLock { state in
            let range = state.selection
            guard range.location >= 0, range.length >= 0, range.end <= state.content.count else {
                return false
            }
            let written: [Character]
            switch behavior {
            case .normal: written = Array(text)
            case .replaces(let other): written = Array(other)
            case .erases: written = []
            case .silentNoOp: written = Array(state.content[range.location..<range.end])
            case .rejected: return false
            }
            state.content.replaceSubrange(range.location..<range.end, with: written)

            switch caret {
            case .endOfWrittenText, .unreadable:
                state.selection = AXTextRange(
                    location: range.location + written.count, length: 0)
            case .startOfRange:
                state.selection = AXTextRange(location: range.location, length: 0)
            case .unchanged:
                state.selection = AXTextRange(location: range.location, length: written.count)
            }
            return true
        }
    }

    fileprivate func matches(_ expected: String, in range: AXTextRange) -> RangeMatch {
        guard respondsToStringForRange else { return .unreadable }
        return state.withLock { state in
            guard range.location >= 0, range.length >= 0, range.end <= state.content.count else {
                return .unreadable
            }
            return String(state.content[range.location..<range.end]) == expected
                ? .matched : .differed
        }
    }
}

/// テスト用。AX の応答を指定した値で返し、問い合わせられ方を記録する。
public struct FakeAccessibility: ReplacementCapableAccessibility {

    /// 偽の要素。AX から読み取れる事実をそのまま持つ。
    public struct Element: FocusedElement {
        public let role: String?
        public let isSelectedTextSettable: Bool
        public let processIdentifier: pid_t?
        /// 書き込みを受け入れるか。AX が成功を返すかどうかを模す。
        /// **`field` を渡した場合はそちらの `WriteBehavior` が優先する。**
        public let acceptsWrite: Bool
        /// 選択範囲属性へ書き込めるか（C-5）。
        public let isSelectedTextRangeSettable: Bool
        /// 要素の同一性（C-4）。**同じ欄を指す要素には同じ値を使うこと。**
        public let identity: UUID

        public init(
            role: String?, isSelectedTextSettable: Bool,
            processIdentifier: pid_t?, acceptsWrite: Bool,
            isSelectedTextRangeSettable: Bool = true,
            identity: UUID = UUID()
        ) {
            self.role = role
            self.isSelectedTextSettable = isSelectedTextSettable
            self.processIdentifier = processIdentifier
            self.acceptsWrite = acceptsWrite
            self.isSelectedTextRangeSettable = isSelectedTextRangeSettable
            self.identity = identity
        }
    }

    /// 問い合わせられ方の記録。判定の順序と、無駄な往復の有無を検査するために要る。
    public final class Calls: Sendable {
        private let roles = Atomic<Int>(0)
        private let settables = Atomic<Int>(0)
        private let texts = Mutex<[String]>([])
        private let ranges = Mutex<[AXTextRange]>([])
        private let reads = Mutex<[AXTextRange]>([])

        public var roleCount: Int { roles.load(ordering: .relaxed) }
        public var settableCount: Int { settables.load(ordering: .relaxed) }
        /// `kAXSelectedText` へ書き込んだ文字列。**これが欄の内容を変える唯一の操作。**
        public var writtenTexts: [String] { texts.withLock { $0 } }
        /// `kAXSelectedTextRange` へ書き込んだ範囲。**内容は変えない**（選択の移動だけ）。
        public var writtenRanges: [AXTextRange] { ranges.withLock { $0 } }
        /// **読み戻しを行った範囲。** NFR-V3 の条件 1（自分が書いた場所に限る）を
        /// 検査で押さえるために記録する。
        public var readRanges: [AXTextRange] { reads.withLock { $0 } }

        fileprivate func recordRole() { roles.add(1, ordering: .relaxed) }
        fileprivate func recordSettable() { settables.add(1, ordering: .relaxed) }
        fileprivate func recordWrite(_ text: String) { texts.withLock { $0.append(text) } }
        fileprivate func recordRangeWrite(_ range: AXTextRange) {
            ranges.withLock { $0.append(range) }
        }
        fileprivate func recordRead(_ range: AXTextRange) { reads.withLock { $0.append(range) } }
    }

    public let calls = Calls()
    private let focused: Element?
    private let field: FakeTextField?

    /// - Parameter field: 差し替えを駆動する場合に渡す。省略すると範囲の読み書きは
    ///   すべて「使えない」相手として振る舞う（＝差し替えは常に中止される）。
    public init(focused: Element?, field: FakeTextField? = nil) {
        self.focused = focused
        self.field = field
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
        guard let field else {
            calls.recordWrite(text)
            return true
        }
        guard field.write(text) else { return false }
        calls.recordWrite(text)
        return true
    }

    public func isSelectedTextRangeSettable(_ element: any FocusedElement) -> Bool {
        guard let element = element as? Element else { return false }
        return field != nil && element.isSelectedTextRangeSettable
    }

    public func selectedRange(of element: any FocusedElement) -> AXTextRange? {
        guard element is Element else { return nil }
        return field?.currentSelection
    }

    public func setSelectedRange(_ range: AXTextRange, on element: any FocusedElement) -> Bool {
        guard let element = element as? Element, element.isSelectedTextRangeSettable,
              let field
        else { return false }
        guard field.select(range) else { return false }
        calls.recordRangeWrite(range)
        return true
    }

    public func matches(
        _ expected: String, in range: AXTextRange, of element: any FocusedElement
    ) -> RangeMatch {
        calls.recordRead(range)
        guard element is Element, let field else { return .unreadable }
        return field.matches(expected, in: range)
    }

    public func isSameElement(_ lhs: any FocusedElement, _ rhs: any FocusedElement) -> Bool {
        guard let lhs = lhs as? Element, let rhs = rhs as? Element else { return false }
        return lhs.identity == rhs.identity
    }
}

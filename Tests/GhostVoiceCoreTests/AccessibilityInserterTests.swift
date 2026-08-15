import Testing
import ApplicationServices
import Foundation
@testable import GhostVoiceCore

@Suite("AccessibilityInserter の適用可否")
struct AccessibilityInserterTests {

    /// テストのプロセス ID とは別物であることが明らかな値。「自分自身を狙っていない」
    /// 側の要素を作るために使う。
    private static let otherProcess: pid_t = 424_242

    private func element(
        role: String? = kAXTextFieldRole as String,
        isSettable: Bool = true,
        pid: pid_t? = otherProcess,
        acceptsWrite: Bool = true
    ) -> FakeAccessibility.Element {
        FakeAccessibility.Element(
            role: role, isSelectedTextSettable: isSettable,
            processIdentifier: pid, acceptsWrite: acceptsWrite
        )
    }

    private func inserter(_ fake: FakeAccessibility) -> AccessibilityInserter {
        AccessibilityInserter(accessibility: fake, ownProcessIdentifier: getpid())
    }

    @Test("3 条件がそろえば適用できる")
    func applicableWhenAllConditionsHold() {
        for role in [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole] {
            let fake = FakeAccessibility(focused: element(role: role as String))
            #expect(inserter(fake).canInsert(), "役割 \(role) が通らない")
        }
    }

    @Test("フォーカス要素が取れなければ適用外")
    func notApplicableWithoutFocus() {
        let fake = FakeAccessibility(focused: nil)
        #expect(!inserter(fake).canInsert())
    }

    /// フォーカスが取れないなら役割も可書き込み性も訊く意味が無い。適用可否の判定は
    /// 安価でなければならない（詳細設計書 §6.2）ので、無駄な往復を残さない。
    @Test("フォーカス要素が取れなければ役割も可書き込み性も問い合わせない")
    func stopsProbingWithoutFocus() {
        let fake = FakeAccessibility(focused: nil)
        _ = inserter(fake).canInsert()

        #expect(fake.calls.roleCount == 0)
        #expect(fake.calls.settableCount == 0)
    }

    @Test("テキスト入力でない役割は適用外")
    func notApplicableForNonTextRole() {
        for role in [kAXButtonRole, kAXWindowRole, kAXStaticTextRole, kAXImageRole] {
            let fake = FakeAccessibility(focused: element(role: role as String))
            #expect(!inserter(fake).canInsert(), "役割 \(role) を通している")
        }
    }

    @Test("役割が読めなければ適用外")
    func notApplicableWhenRoleIsUnreadable() {
        let fake = FakeAccessibility(focused: element(role: nil))
        #expect(!inserter(fake).canInsert())
    }

    /// `AXUIElementSetAttributeValue` は書き込めない要素にも成功を返すことがある
    /// （詳細設計書 §6.2）。事前に可書き込み性を確かめる意味はそこにある。
    @Test("選択テキストが書き込めない要素は適用外")
    func notApplicableWhenNotSettable() {
        let fake = FakeAccessibility(focused: element(isSettable: false))
        #expect(!inserter(fake).canInsert())
    }

    /// **実測に基づく安全装置。** 自プロセスの要素へ `AXUIElementSetAttributeValue` を
    /// メインスレッド以外から投げると**永久にブロックする**（実測: macOS 26.5.2 / M3、
    /// `AXUIElementSetMessagingTimeout(2.0)` を設定しても 12 秒で戻らず打ち切り。
    /// メインスレッドからは 52.9 ms で成功）。挿入は非同期文脈＝協調スレッドプールで
    /// 走るので、自分自身を狙った瞬間にそのタスクが二度と返らなくなる。
    ///
    /// 自分の HUD や設定画面へ書き込む必要はそもそも無いので、判定の段階で外す。
    @Test("自プロセスの要素は適用外にする")
    func excludesOwnProcess() {
        let fake = FakeAccessibility(focused: element(pid: getpid()))
        #expect(!inserter(fake).canInsert(), "自プロセスへ書き込むと永久にブロックする")
    }

    /// プロセスが判らない要素は「自分ではない」と断言できない。断言できない側へ倒す。
    @Test("プロセスが判らない要素は適用外にする")
    func excludesElementWithUnknownProcess() {
        let fake = FakeAccessibility(focused: element(pid: nil))
        #expect(!inserter(fake).canInsert())
    }

    /// プロセスの判定は AX の往復を伴わない局所的な検査なので、役割や可書き込み性より
    /// 先に済ませる。順序が逆だと、永久ブロックの危険がある相手に余計な問い合わせを投げる。
    @Test("自プロセス判定は役割の問い合わせより先に行う")
    func checksProcessBeforeProbingRole() {
        let fake = FakeAccessibility(focused: element(pid: getpid()))
        _ = inserter(fake).canInsert()

        #expect(fake.calls.roleCount == 0, "自プロセスと判ってから役割を訊いている")
        #expect(fake.calls.settableCount == 0)
    }
}

@Suite("AccessibilityInserter の挿入")
struct AccessibilityInserterInsertionTests {

    private func inserter(_ fake: FakeAccessibility) -> AccessibilityInserter {
        AccessibilityInserter(accessibility: fake, ownProcessIdentifier: getpid())
    }

    @Test("挿入は選択テキストへの書き込みで行い、文字列をそのまま渡す")
    func writesTextToSelectedText() async {
        let fake = FakeAccessibility(focused: FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: true,
            processIdentifier: 424_242, acceptsWrite: true
        ))

        #expect(await inserter(fake).tryInsert("来週までに要件定義を完了させます。").didInsert)
        #expect(fake.calls.writtenTexts == ["来週までに要件定義を完了させます。"])
    }

    /// **錨が取れなくても挿入は成功である。** 差し替えを諦めるだけで、テキストは入っている。
    /// ここを `.failed` にすると、入ったテキストの上に Pasteboard 経路が二重に貼る。
    @Test("範囲を読めない相手でも挿入そのものは成功する（錨だけが nil になる）")
    func insertionSucceedsWithoutAnchor() async {
        let fake = FakeAccessibility(focused: FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: true,
            processIdentifier: 424_242, acceptsWrite: true
        ))

        let attempt = await inserter(fake).tryInsert("テキスト")
        #expect(attempt.didInsert)
        #expect(attempt.anchor == nil, "範囲が読めないのに錨を作っている")
    }

    @Test("書き込みが拒否されたら失敗を返す")
    func reportsFailureWhenWriteRejected() async {
        let fake = FakeAccessibility(focused: FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: true,
            processIdentifier: 424_242, acceptsWrite: false
        ))
        #expect(await inserter(fake).tryInsert("テキスト").didInsert == false)
    }

    @Test("フォーカス要素が取れなければ書き込まずに失敗を返す")
    func failsWithoutFocus() async {
        let fake = FakeAccessibility(focused: nil)
        #expect(await inserter(fake).tryInsert("テキスト").didInsert == false)
        #expect(fake.calls.writtenTexts.isEmpty)
    }

    /// `canInsert()` と `tryInsert()` はフォーカスを別々に取り直す。その隙にフォーカスが
    /// 自分自身の窓（HUD 等）へ移っていた場合、書き込みに進むと永久にブロックする。
    /// **判定側だけでなく書き込み側にも同じ防壁が要る。**
    @Test("書き込み時点で自プロセスへフォーカスが移っていたら書き込まない")
    func refusesOwnProcessAtWriteTime() async {
        let fake = FakeAccessibility(focused: FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: true,
            processIdentifier: getpid(), acceptsWrite: true
        ))

        #expect(await inserter(fake).tryInsert("テキスト").didInsert == false)
        #expect(fake.calls.writtenTexts.isEmpty, "自プロセスへ書き込んでいる")
    }
}

/// 実機の AX に対して走らせる検査。**権限の有無で結果が変わる項目を含むので、
/// どちらの機体でも正しく動くように書くこと。**
///
/// `canInsert()` は読み取りしか行わないため、権限のある機体で実行しても
/// 副作用は無い。`tryInsert()` は**フォアグラウンドのアプリへ書き込む**ので、
/// ここから呼んではならない。
@Suite("SystemAccessibility の実機挙動")
struct SystemAccessibilityTests {

    /// 適用可否の判定が重いと、AX が使えない場合のコストが二重になる（判定 + Pasteboard）。
    ///
    /// **この境界は要件値ではない。** 要件は NFR-P5（テキスト挿入 50 ms 以内）で、
    /// ここが見るのは「判定だけで挿入の予算を食い潰していないか」という壊れ検知。
    /// 権限の無い機体では AX の往復自体が起きず実測 0.5 ms 前後、権限のある機体では
    /// フォアグラウンドのアプリとの往復が入る。`SystemAccessibility` は
    /// `AXUIElementSetMessagingTimeout` で往復に上限を掛けているので、相手が固まっていても
    /// 既定 6 秒ではなくその上限で戻る。
    @Test("適用可否の判定が安価に返る")
    func canInsertIsCheap() {
        let inserter = AccessibilityInserter()

        let start = ContinuousClock.now
        let applicable = inserter.canInsert()
        let elapsed = ContinuousClock.now - start

        print("AXIsProcessTrusted=\(AXIsProcessTrusted()) canInsert=\(applicable) elapsed=\(elapsed)")
        #expect(elapsed < .milliseconds(750), "適用可否の判定が重すぎる: \(elapsed)")
    }

    /// AX 権限が無ければフォーカス要素が取れないので、必ず適用外になる。
    ///
    /// **権限のある機体ではこの前提が成り立たない**（フォーカス次第で true にも false にも
    /// なる）ため、権限が無いときだけ走らせる。実測では権限の無いプロセスからの
    /// `AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElement)` は
    /// `kAXErrorCannotComplete`(-25204) を 0.565 ms で返す（ブロックはしない）。
    @Test(
        "AX 権限が無ければ適用外と判定する",
        .enabled(if: !AXIsProcessTrusted(), "AX 権限のある機体ではフォーカス次第で変わる")
    )
    func notApplicableWithoutTrust() {
        #expect(!AccessibilityInserter().canInsert())
    }

    /// 自プロセス判定はここが要。実 AX 要素からプロセス ID を取り出せることを確かめる。
    /// これは局所的な問い合わせなので AX 権限を要しない。
    @Test("実 AX 要素から自プロセスのプロセス ID を取り出せる")
    func readsProcessIdentifierFromRealElement() {
        let element = SystemAccessibility.Element(ax: AXUIElementCreateApplication(getpid()))
        #expect(SystemAccessibility().processIdentifier(of: element) == getpid())
    }

    /// **失敗を握り潰すと、判らないものが「プロセス 0」として通る。**
    /// `AXUIElementGetPid` が失敗しても出力引数は初期値のまま残るので、戻り値を見ずに
    /// 使うと `pid = 0` を「自分ではない正当な相手」と誤認し、自プロセス防壁をすり抜ける。
    ///
    /// システムワイド要素は持ち主のプロセスを持たないため、実測で
    /// `kAXErrorInvalidUIElement` を返す。失敗の経路をこれで通す。
    @Test("プロセスを持たない要素では nil を返す")
    func returnsNilWhenProcessIdentifierIsUnavailable() {
        let systemWide = SystemAccessibility.Element(ax: AXUIElementCreateSystemWide())
        #expect(SystemAccessibility().processIdentifier(of: systemWide) == nil)
    }

    /// AX の往復に掛ける上限。既定の 6 秒のままだと、固まったアプリが前面にいる間
    /// 適用可否の判定だけでその時間ユーザーを待たせる。
    ///
    /// **この値が実際に効くことは検査できていない**（AX 権限があり、かつ相手が
    /// 固まっている状況を自動テストから作れない）。せめて値が黙って変わらないよう固定する。
    @Test("AX のメッセージング上限は 0.5 秒")
    func messagingTimeoutIsPinned() {
        #expect(SystemAccessibility().messagingTimeout == 0.5)
        #expect(SystemAccessibility(messagingTimeout: .milliseconds(250)).messagingTimeout == 0.25)
    }

    /// フォーカス属性が `AXUIElement` 以外を返した場合、強制キャストはプロセスを落とす。
    /// **挿入は発話の出口なので、落ちれば発話は失われる。** 型を確かめてから包む。
    @Test("AX 要素でない属性値は要素として包まない")
    func rejectsNonElementAttributeValue() {
        #expect(SystemAccessibility.element(from: "ただの文字列" as CFString) == nil)
        #expect(SystemAccessibility.element(from: 42 as CFNumber) == nil)
        #expect(SystemAccessibility.element(from: nil) == nil)

        let valid = SystemAccessibility.element(from: AXUIElementCreateApplication(getpid()))
        #expect(valid != nil)
        #expect(SystemAccessibility().processIdentifier(of: valid!) == getpid())
    }
}

// MARK: - 最前面アプリの特定（V-3 の実測で入れ替えた経路 / 2026-08-14）

/// **システムワイド要素は使えない。** `AXUIElementCreateSystemWide()` から
/// `kAXFocusedUIElementAttribute` を引くと、実機では全アプリで即座に
/// `cannotComplete` を返した（タイムアウトを 10 倍にしても 0 ms で落ちる）。
/// 最前面アプリを pid で名指しすれば取れる。その pid をどう取るかの規則を固定する。
@Suite("最前面アプリの特定")
struct FrontmostWindowTests {

    private func window(layer: Int, pid: pid_t) -> [String: Any] {
        [kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: pid]
    }

    @Test("いちばん手前の通常ウィンドウの持ち主を返す")
    func picksTheFrontmostNormalWindow() {
        let windows = [window(layer: 0, pid: 111), window(layer: 0, pid: 222)]
        #expect(SystemAccessibility.frontmostProcessIdentifier(in: windows) == 111)
    }

    /// **メニューバー・カーソル・通知などは別のレイヤに載る。**
    /// 層を見ずに先頭を取ると、それらの持ち主（多くは `WindowServer` や自分自身）を
    /// 最前面と誤認し、AX 経路が永久に使えなくなる。
    @Test("通常のウィンドウ以外の層は飛ばす")
    func skipsNonZeroLayers() {
        let windows = [
            window(layer: 25, pid: 999),
            window(layer: 3, pid: 888),
            window(layer: 0, pid: 111),
        ]
        #expect(SystemAccessibility.frontmostProcessIdentifier(in: windows) == 111)
    }

    @Test("該当が無ければ nil を返す")
    func returnsNilWhenNoNormalWindow() {
        #expect(SystemAccessibility.frontmostProcessIdentifier(in: []) == nil)
        #expect(SystemAccessibility.frontmostProcessIdentifier(in: [window(layer: 25, pid: 9)]) == nil)
    }

    /// 欠けた項目で落ちない。CGWindowList の要素は項目が揃っているとは限らない。
    @Test("項目が欠けたウィンドウは飛ばす")
    func skipsMalformedEntries() {
        let windows: [[String: Any]] = [
            [:],
            [kCGWindowLayer as String: 0],
            [kCGWindowOwnerPID as String: pid_t(77)],
            window(layer: 0, pid: 111),
        ]
        #expect(SystemAccessibility.frontmostProcessIdentifier(in: windows) == 111)
    }
}

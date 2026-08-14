import ApplicationServices
import Foundation
import Synchronization
import Testing

@testable import GhostVoiceCore

// MARK: - 検査用の道具

/// **差し替えの途中で世界が変わる状況を作るための AX の継ぎ目。**
///
/// `FakeAccessibility` は値型で、フォーカス要素も欄も構築時に固定される。
/// ところが差し替えの中止点の大半は**「挿入した後に何かが変わった」**ことで起きる
/// （利用者が編集した／別のアプリへ移った／欄が書き込みを拒むようになった）。
/// **固定された代役では、そのどれ 1 つも `DictationSession` を通して駆動できない。**
///
/// ここは中身を丸ごと差し替えられるようにしただけの薄い包みである。
/// 挿入器と差し替え器は**同じインスタンス**を握るので、差し替えると両方から見える。
final class SwitchingAccessibility: ReplacementCapableAccessibility, @unchecked Sendable {

    private let inner: Mutex<FakeAccessibility>
    /// **経路判定（`canCaptureAnchor`）の直後に 1 度だけ走る仕掛け。**
    ///
    /// 「(a) を選んだ後・挿入する前に世界が変わった」という並びは、時計でも読み回数でも
    /// 狙えない（読みの回数は実装の都合で変わる）。`isSelectedTextRangeSettable` は
    /// **`canCaptureAnchor` でしか呼ばれない**ので、そこを目印にする。
    private let onCaptureProbe: Mutex<(@Sendable () -> Void)?> = Mutex(nil)

    init(_ initial: FakeAccessibility) {
        self.inner = Mutex(initial)
    }

    /// 経路判定の直後に 1 度だけ呼ぶ。
    func armAfterCaptureProbe(_ action: @escaping @Sendable () -> Void) {
        onCaptureProbe.withLock { $0 = action }
    }

    /// **挿入が終わった後に世界を差し替える。**
    func swap(to next: FakeAccessibility) {
        inner.withLock { $0 = next }
    }

    /// いまの読み取り記録（NFR-V3 の条件 1 を見るため）。
    var readRanges: [AXTextRange] { inner.withLock { $0.calls.readRanges } }
    var writtenTexts: [String] { inner.withLock { $0.calls.writtenTexts } }

    func focusedElement() -> (any FocusedElement)? { inner.withLock { $0.focusedElement() } }
    func role(of element: any FocusedElement) -> String? { inner.withLock { $0.role(of: element) } }
    func isSelectedTextSettable(_ element: any FocusedElement) -> Bool {
        inner.withLock { $0.isSelectedTextSettable(element) }
    }
    func processIdentifier(of element: any FocusedElement) -> pid_t? {
        inner.withLock { $0.processIdentifier(of: element) }
    }
    func setSelectedText(_ text: String, on element: any FocusedElement) -> Bool {
        inner.withLock { $0.setSelectedText(text, on: element) }
    }
    func isSelectedTextRangeSettable(_ element: any FocusedElement) -> Bool {
        let answer = inner.withLock { $0.isSelectedTextRangeSettable(element) }
        if let action = onCaptureProbe.withLock({ current -> (@Sendable () -> Void)? in
            defer { current = nil }
            return current
        }) { action() }
        return answer
    }
    func selectedRange(of element: any FocusedElement) -> AXTextRange? {
        inner.withLock { $0.selectedRange(of: element) }
    }
    func setSelectedRange(_ range: AXTextRange, on element: any FocusedElement) -> Bool {
        inner.withLock { $0.setSelectedRange(range, on: element) }
    }
    func matches(_ expected: String, in range: AXTextRange, of element: any FocusedElement)
        -> RangeMatch
    {
        inner.withLock { $0.matches(expected, in: range, of: element) }
    }
    func isSameElement(_ lhs: any FocusedElement, _ rhs: any FocusedElement) -> Bool {
        inner.withLock { $0.isSameElement(lhs, rhs) }
    }
}

/// secure input の状態を後から立てられるようにした旗。
///
/// **挿入の時点では無効で、整形を待つ間に有効になる**——利用者がパスワード欄へ
/// 移ったときに実際に起きる並びである。値型の閉包では作れない。
final class SecureInputFlag: Sendable {
    private let value = Mutex(false)
    var isEnabled: Bool { value.withLock { $0 } }
    func enable() { value.withLock { $0 = true } }
}

/// 挿入した後に世界へ加える変化。**各中止点をここから 1 つずつ作る。**
enum WorldMutation: Sendable {
    case none
    /// 利用者が欄を編集した（C-6 不一致）。
    case userEdits(String)
    /// フォーカスが失われた（C-4）。
    case losesFocus
    /// 別のアプリが最前面になった（C-3）。
    case anotherProcess
    /// 同じアプリの別の入力欄へ移った（C-4）。
    case anotherField
    /// 選択範囲が settable でなくなった（C-5）。
    case rangeNotSettable
    /// 欄が `AXStringForRange` に応えなくなった（C-6 読めない）。
    case unreadable
    /// 選択範囲の設定が失敗する（手順 3）。
    case rangeWriteFails
    /// 上書きが `AXError`（手順 4）。
    case writeRejected
    /// AX が成功を返すのに何も入らない（R-4 の無言失敗。手順 5）。
    case silentNoOp
    /// 書いたのとは別の内容になる（喪失の疑い。手順 5）。
    case losesText
    /// secure input が有効になった。
    case secureInput
    /// 素直に書ける欄へ戻す（2 発話目を普通に通すため）。
    case restored
}

/// **`DictationSession` を通して差し替えを駆動する一式。**
///
/// 挿入器も差し替え器も**本物**（`AccessibilityInserter` / `TextReplacer`）で、
/// 代役は AX の継ぎ目・欄・クリップボード・マイク・認識・整形だけである。
/// **実機のアプリへは 1 文字も書かない**（安全制約）。
final class RevisionRig: Sendable {

    static let targetProcess: pid_t = 424_242
    static let ownProcess: pid_t = 4_242
    static let prefix = "前置きの文。"
    static let suffix = "その後の本文。"
    static let raw = "えー、生テキストです"
    static let refined = "生テキストです。"

    /// 挿入された生テキストが占める範囲。
    static var anchorRange: AXTextRange {
        AXTextRange(location: prefix.count, length: raw.count)
    }
    /// 生テキストが挿入された直後の欄の中身。**差し替えを断念したときはこれが残る。**
    static var contentWithRaw: String { prefix + raw + suffix }
    static var contentWithRefined: String { prefix + refined + suffix }

    let session: DictationSession
    let hotkey: StubHotkeyMonitor
    let audio: StubAudioCapture
    let history: HistoryStore
    let accessibility: SwitchingAccessibility
    let clipboard: StubClipboard
    let notices: NoticeLog
    let field: Mutex<FakeTextField>
    let isSecureInput: SecureInputFlag
    let identity: UUID

    init(
        session: DictationSession, hotkey: StubHotkeyMonitor, audio: StubAudioCapture,
        history: HistoryStore, accessibility: SwitchingAccessibility, clipboard: StubClipboard,
        notices: NoticeLog, field: FakeTextField, isSecureInput: SecureInputFlag, identity: UUID
    ) {
        self.session = session
        self.hotkey = hotkey
        self.audio = audio
        self.history = history
        self.accessibility = accessibility
        self.clipboard = clipboard
        self.notices = notices
        self.field = Mutex(field)
        self.isSecureInput = isSecureInput
        self.identity = identity
    }

    /// いまの欄の中身。**検査からのみ見る。**
    var content: String { field.withLock { $0.content } }

    /// 1 発話ぶんを流し、**差し替えの顛末が出るまで**待つ。
    ///
    /// **`.idle` を待つだけでは足りない。** (a) の分岐では挿入の直後に `.idle` へ戻り、
    /// 差し替えはその後に走る（それが設計の要点である）。
    ///
    /// - Parameter waitingForNotice: 顛末（`SessionNotice`）を待つか。
    ///   (b) の分岐では差し替えが無いので何も流れない。
    func speakAndSettle(waitingForNotice: Bool = true) async throws {
        let collector = notices.follow(session)
        defer { collector.cancel() }
        let run = Task { [session] in await session.run() }
        defer { run.cancel() }

        try await speakOnce(on: run)
        if waitingForNotice {
            try await waitUntil("差し替えの顛末が出る") { !self.notices.notices.isEmpty }
        }
    }

    /// 1 発話ぶんを流し、待機へ戻るまで待つ。**`run()` は呼び出し側が持つ。**
    ///
    /// (a) の分岐では、挿入が終わって履歴に載った時点で `.idle` へ戻る
    /// （差し替えはその後ろ）。**履歴が増えたことを目印にする**——
    /// `.idle` は 1 発話につき 2 回来るので目印にならない。
    func speakOnce(on run: Task<Void, Never>) async throws {
        let baseline = history.entries.count
        hotkey.emit(.pressed)
        try await waitUntil("録音が始まる") {
            if case .recording = await self.session.state { return true }
            return false
        }
        audio.emit(frames: 1_600)
        hotkey.emit(.released)
        try await waitUntil("挿入が終わる") { self.history.entries.count > baseline }
    }

    /// 挿入器と差し替え器を、**同じ世代・同じクリップボード**で組む。
    static func make(
        root: URL,
        refined: String? = RevisionRig.refined,
        refineDelay: Duration = .zero,
        applyMode: RefinementApplyMode = .afterInsert,
        focusedProcess: pid_t = RevisionRig.targetProcess,
        rangeSettable: Bool = true,
        selectionWriteFails: Bool = false,
        revisionDeadline: Duration = .seconds(5),
        historyLimit: Int = 50,
        caret: FakeTextField.CaretAfterWrite = .endOfWrittenText,
        secureInputAtInsertion: Bool = false,
        refiner: SpyRefiner? = nil,
        clipboardSucceeds: Bool = true
    ) -> RevisionRig {
        let identity = UUID()
        let field = FakeTextField(
            content: prefix + suffix,
            selection: AXTextRange(location: prefix.count, length: 0),
            caret: caret,
            selectionWriteFails: selectionWriteFails
        )
        let element = FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: true,
            processIdentifier: focusedProcess, acceptsWrite: true,
            isSelectedTextRangeSettable: rangeSettable, identity: identity
        )
        let accessibility = SwitchingAccessibility(
            FakeAccessibility(focused: element, field: field))

        let secure = SecureInputFlag()
        if secureInputAtInsertion {
            // **経路判定を通した後・挿入する前**に有効化する（利用者がパスワード欄へ移った）。
            accessibility.armAfterCaptureProbe { secure.enable() }
        }
        let isSecureInputEnabled: @Sendable () -> Bool = { secure.isEnabled }

        let epoch = InsertionEpoch()
        let clipboard = StubClipboard(succeeds: clipboardSucceeds)
        let inserter = CompositeInserter(
            primary: AccessibilityInserter(
                accessibility: accessibility, ownProcessIdentifier: ownProcess, epoch: epoch),
            // **二段目は使えない相手にしておく。** ⌘V を送出しないため。
            fallback: StubInserter(canInsert: false, succeeds: false),
            lastResort: clipboard,
            epoch: epoch,
            isSecureInputEnabled: isSecureInputEnabled
        )
        let replacer = TextReplacer(
            accessibility: accessibility, clipboard: clipboard, epoch: epoch,
            ownProcessIdentifier: ownProcess, isSecureInputEnabled: isSecureInputEnabled
        )

        let settingsStore = SettingsStore(rootURL: root)
        do {
            // **`try?` にしてはならない**（視点4 §5.1）。書けなかった場合、rig は
            // 既定値（`.afterInsert` / 3000 ms）のまま**静かに**動く——
            // 短い `revisionDeadline` を指定した検査が黙って 3 秒で走ることになる。
            // **setup の失敗を成功として通す形**なので、失敗として記録する。
            try settingsStore.update {
                $0.refinementApplyMode = applyMode
                $0.revisionDeadlineMs = Int(revisionDeadline.components.seconds * 1_000)
            }
        } catch {
            Issue.record("rig の設定を書けなかった（既定値のまま走ると別のものを検査する）: \(error)")
        }

        let hotkey = StubHotkeyMonitor()
        let audio = StubAudioCapture()
        let history = HistoryStore(rootURL: root, limit: historyLimit)
        let session = DictationSession(
            settings: settingsStore,
            hotkey: hotkey,
            audio: audio,
            transcriber: StubTranscriber(finalText: raw),
            refiner: refiner ?? SpyRefiner(result: refined, delay: refineDelay),
            insertion: InsertionStack(
                inserter: inserter, replacer: replacer, clipboard: clipboard),
            history: history,
            vocabulary: VocabularyStore(rootURL: root),
            isSecureInputEnabled: isSecureInputEnabled,
            postEventAuthorization: PostEventAuthorization(probe: { false }),
            finalizeDeadline: .seconds(5)
        )
        return RevisionRig(
            session: session, hotkey: hotkey, audio: audio, history: history,
            accessibility: accessibility, clipboard: clipboard, notices: NoticeLog(),
            field: field, isSecureInput: secure, identity: identity
        )
    }

    /// 挿入が終わった後に世界を変える。
    func apply(_ mutation: WorldMutation) {
        let current = field.withLock { $0 }
        func rebuild(
            field newField: FakeTextField? = nil,
            rangeSettable: Bool = true,
            process: pid_t = RevisionRig.targetProcess,
            identity newIdentity: UUID? = nil,
            focused: Bool = true
        ) {
            let used = newField ?? current
            field.withLock { $0 = used }
            let element = FakeAccessibility.Element(
                role: kAXTextAreaRole as String, isSelectedTextSettable: true,
                processIdentifier: process, acceptsWrite: true,
                isSelectedTextRangeSettable: rangeSettable,
                identity: newIdentity ?? identity
            )
            accessibility.swap(
                FakeAccessibility(focused: focused ? element : nil, field: used))
        }

        switch mutation {
        case .none: break
        case .userEdits(let text): current.userEdits(to: text)
        case .losesFocus: rebuild(focused: false)
        case .anotherProcess: rebuild(process: RevisionRig.targetProcess + 1)
        case .anotherField: rebuild(identity: UUID())
        case .rangeNotSettable: rebuild(rangeSettable: false)
        case .unreadable:
            rebuild(field: Self.copy(of: current, respondsToStringForRange: false))
        case .rangeWriteFails:
            rebuild(field: Self.copy(of: current, selectionWriteFails: true))
        case .writeRejected: rebuild(field: Self.copy(of: current, behavior: .rejected))
        case .silentNoOp: rebuild(field: Self.copy(of: current, behavior: .silentNoOp))
        case .losesText:
            rebuild(field: Self.copy(of: current, behavior: .replaces(with: "×")))
        case .secureInput: isSecureInput.enable()
        case .restored: rebuild(field: Self.copy(of: current))
        }
    }

    /// いまの中身と選択を保ったまま、振る舞いだけ違う欄を作る。
    private static func copy(
        of field: FakeTextField,
        behavior: FakeTextField.WriteBehavior = .normal,
        respondsToStringForRange: Bool = true,
        selectionWriteFails: Bool = false
    ) -> FakeTextField {
        FakeTextField(
            content: field.content,
            selection: AXTextRange(location: field.content.count, length: 0),
            behavior: behavior, caret: .endOfWrittenText,
            respondsToStringForRange: respondsToStringForRange,
            selectionWriteFails: selectionWriteFails
        )
    }
}

/// 告げられたことを順に集める。**差し替えの顛末はここにしか出ない。**
final class NoticeLog: Sendable {
    private let entries = Mutex<[SessionNotice]>([])
    var notices: [SessionNotice] { entries.withLock { $0 } }
    func record(_ notice: SessionNotice) { entries.withLock { $0.append(notice) } }

    func follow(_ session: DictationSession) -> Task<Void, Never> {
        Task { [self] in
            for await notice in session.notices() { record(notice) }
        }
    }
}

extension SwitchingAccessibility {
    func swap(_ next: FakeAccessibility) { swap(to: next) }
}

// MARK: - 検査

@Suite("FR-5(a): 生テキストを先に挿入し、整形は後から差し替える")
struct RawTextFirstInsertionTests {

    /// 利用者が欄を書き直した後の中身。
    ///
    /// **錨の範囲が読める長さにしてある。** 短くすると範囲が欄からはみ出して
    /// `.sourceUnreadable` になり、見たかった `.sourceMismatch`（C-6 の不一致）を通らない。
    static let userRewrite = "利用者がここを全部書き直しました。これは自分で打った文章です。"

    /// 1 発話ぶんを流し、**差し替えの顛末が出るまで**待つ。
    ///
    /// **`.idle` を待つだけでは足りない。** (a) の分岐では挿入の直後に `.idle` へ戻り、
    /// 差し替えはその後に走る（それが設計の要点である）。
    private func speakAndSettle(_ rig: RevisionRig) async throws {
        let collector = rig.notices.follow(rig.session)
        defer { collector.cancel() }
        let run = Task { await rig.session.run() }
        defer { run.cancel() }

        rig.hotkey.emit(.pressed)
        try await waitUntil("録音が始まる") {
            if case .recording = await rig.session.state { return true }
            return false
        }
        rig.audio.emit(frames: 1_600)
        rig.hotkey.emit(.released)
        try await waitUntil("差し替えの顛末が出る") { !rig.notices.notices.isEmpty }
    }

    /// 挿入が終わった時点（＝差し替えの前）で止め、世界を変えてから続きを流す。
    ///
    /// - Important: **整形に遅延を持たせた `rig` を渡すこと。** 遅延が無いと
    ///   変化を当てる前に差し替えが終わってしまい、検査が機体の速さ次第になる。
    private func speakThenMutate(_ rig: RevisionRig, _ mutation: WorldMutation) async throws {
        let collector = rig.notices.follow(rig.session)
        defer { collector.cancel() }
        let run = Task { await rig.session.run() }
        defer { run.cancel() }

        rig.hotkey.emit(.pressed)
        try await waitUntil("録音が始まる") {
            if case .recording = await rig.session.state { return true }
            return false
        }
        rig.audio.emit(frames: 1_600)
        rig.hotkey.emit(.released)
        // **挿入が終わるまで待つ。** 履歴に載った時点で生テキストは欄にある。
        try await waitUntil("生テキストが挿入される") { !rig.history.entries.isEmpty }
        rig.apply(mutation)
        try await waitUntil("差し替えの顛末が出る") { !rig.notices.notices.isEmpty }
    }

    // MARK: - 正常系

    @Test("生テキストが先に入り、そのあとで整形結果へ差し替わる")
    func insertsRawThenRevises() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(80))
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)

            // **整形が返る前に、生テキストが欄にある。** これが FR-5(a) の要点である。
            try await waitUntil("生テキストが先に入る") {
                rig.content == RevisionRig.contentWithRaw
            }
            // **しかも待機へ戻っている**（差し替えは「忙しい」に数えない）。
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            try await waitUntil("差し替えが終わる") { !rig.notices.notices.isEmpty }
            #expect(rig.content == RevisionRig.contentWithRefined)
            #expect(rig.notices.notices == [.refinementApplied])
        }
    }

    @Test("差し替えが成功したら履歴の同じ項目に整形結果が入る")
    func updatesTheSameHistoryEntry() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root)
            try await speakAndSettle(rig)

            #expect(rig.history.entries.count == 1, "1 発話で 2 件書いてはならない")
            let entry = try #require(rig.history.entries.first)
            #expect(entry.rawText == RevisionRig.raw)
            #expect(entry.refinedText == RevisionRig.refined)
            #expect(entry.insertionMethod == .ax)
        }
    }

    /// **履歴は欄を触るより先に確保する**（詳細設計書 §8.3）。
    /// 差し替えの途中で発話が判らなくなったとき、履歴が 1 番目の受けである。
    @Test("整形結果は欄を書き換える前に履歴へ入る")
    func writesHistoryBeforeTouchingTheField() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(150))
            // 書き込みを拒む欄にしておくと、**履歴だけが進んだ状態**を観測できる。
            try await speakThenMutate(rig, .writeRejected)

            #expect(rig.content == RevisionRig.contentWithRaw, "欄は変えていない")
            #expect(
                rig.history.entries.first?.refinedText == RevisionRig.refined,
                "欄を触る前に履歴へ書けていない")
        }
    }

    @Test("差し替えが成功すると Undo の窓が開く")
    func opensTheUndoWindow() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root)
            try await speakAndSettle(rig)

            #expect(await rig.session.canUndo)
            #expect(rig.hotkey.isUndoAvailable, "監視器へ「戻せる」を知らせていない")
        }
    }

    // MARK: - 中止点（**すべての結末で「生テキストが欄にある」**）

    /// **A3 が `TextReplacer` 単体で示した 17 行の表が、`DictationSession` を通しても
    /// 成り立つことをここで示す**（受け入れ条件 2）。
    ///
    /// 見るのは 1 つだけ——**そのとき発話はどこにあるか。**
    /// 差し替えが成立しなければ、欄には挿入済みの生テキストがある。
    /// これは**現行実装の正常系そのもの**であり、差し替えを丸ごと外しても同じ状態になる。
    @Test(
        "差し替えを断念しても生テキストは欄にある",
        arguments: [
            (WorldMutation.userEdits(Self.userRewrite), ReplacementDecline.sourceMismatch),
            (.losesFocus, .focusChanged),
            (.anotherProcess, .processChanged),
            (.anotherField, .focusChanged),
            (.rangeNotSettable, .rangeNotSettable),
            (.unreadable, .sourceUnreadable),
            (.rangeWriteFails, .rangeWriteFailed),
            (.writeRejected, .textWriteFailed),
            (.secureInput, .secureInput),
        ] as [(WorldMutation, ReplacementDecline)]
    )
    func declinedRevisionLeavesRawTextInPlace(
        mutation: WorldMutation, expected: ReplacementDecline
    ) async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(150))
            try await speakThenMutate(rig, mutation)

            #expect(rig.notices.notices == [.refinementNotApplied(expected)])
            // **利用者が書き直した場合を除き、欄には生テキストがある。**
            if case .userEdits(let text) = mutation {
                #expect(rig.content == text, "利用者が書いたものを壊している")
            } else {
                #expect(rig.content == RevisionRig.contentWithRaw)
            }
            // **整形結果は履歴にある。** 反映できなくても失われてはいない。
            #expect(rig.history.entries.first?.rawText == RevisionRig.raw)
            #expect(rig.clipboard.left.isEmpty, "断念でクリップボードを奪ってはならない")
        }
    }

    /// 手順 5 が「元の文字列」だった場合（R-4 の無言失敗）。**害は無い。**
    @Test("無言失敗を成功として扱わない")
    func doesNotTreatSilentFailureAsSuccess() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(150))
            try await speakThenMutate(rig, .silentNoOp)

            #expect(rig.content == RevisionRig.contentWithRaw)
            #expect(rig.notices.notices == [.refinementNotApplied(nil)])
            #expect(await rig.session.canUndo == false, "戻す先が無いのに窓が開いている")
        }
    }

    /// 手順 5 がどちらでもなかった場合（R-9。**この設計で唯一発話が欄から消えうる行**）。
    @Test("喪失の疑いは 4 重に受ける")
    func reportsLoss() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(150))
            try await speakThenMutate(rig, .losesText)

            #expect(rig.notices.notices == [.textMayHaveBeenLost], "利用者へ告げていない")
            #expect(rig.clipboard.left == [RevisionRig.refined], "退避していない")
            let entry = try #require(rig.history.entries.first)
            #expect(entry.rawText == RevisionRig.raw)
            #expect(entry.refinedText == RevisionRig.refined, "履歴に写しが無い")
        }
    }

    /// C-7。**一度でも喪失を出した相手には、以後 AX を 1 度も叩かない。**
    ///
    /// - Important: **2 発話を 1 本の `run()` の中で通す。** ホットキーのイベント列は
    ///   単一消費者なので、`run()` を畳んでから張り直すと 2 発話目が届かない。
    @Test("喪失を出したアプリでは以後差し替えを試さない")
    func neverRevisesABlockedProcessAgain() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(150))
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            for pass in 1...2 {
                rig.hotkey.emit(.pressed)
                try await waitUntil("\(pass) 回目の録音が始まる") {
                    if case .recording = await rig.session.state { return true }
                    return false
                }
                rig.audio.emit(frames: 1_600)
                rig.hotkey.emit(.released)
                try await waitUntil("\(pass) 回目の挿入が終わる") {
                    rig.history.entries.count == pass
                }
                // **1 発話目だけ喪失を起こす。** 2 発話目は素直に書ける欄で通す。
                if pass == 1 { rig.apply(.losesText) }
                try await waitUntil("\(pass) 回目の顛末が出る") {
                    rig.notices.notices.count == pass
                }
                // 次の発話の挿入が普通に通るよう、欄を戻してから抜ける。
                if pass == 1 { rig.apply(.restored) }
            }

            #expect(rig.notices.notices.first == .textMayHaveBeenLost)
            #expect(
                rig.notices.notices.last == .refinementNotApplied(.blockedProcess),
                "締め出したはずのアプリへ差し替えを撃っている")
        }
    }

    /// 次の発話の**挿入が始まった**時点で、前の発話の差し替えは失効する。
    @Test("次の発話が始まったら前の差し替えは失効する")
    func staleAnchorIsDeclined() async throws {
        try await withTempRoot { root in
            // 整形を長く掛からせて、その間に次の発話を通す。
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(400))
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            for pass in 1...2 {
                rig.hotkey.emit(.pressed)
                try await waitUntil("\(pass) 回目の録音が始まる") {
                    if case .recording = await rig.session.state { return true }
                    return false
                }
                rig.audio.emit(frames: 1_600)
                rig.hotkey.emit(.released)
                try await waitUntil("\(pass) 回目の挿入が終わる") {
                    rig.history.entries.count == pass
                }
            }
            try await waitUntil("2 件の顛末が出る") { rig.notices.notices.count >= 2 }

            #expect(
                rig.notices.notices.first == .refinementNotApplied(.staleEpoch),
                "失効したはずの錨で差し替えを撃っている")
        }
    }

    /// **錨が自プロセスを指す経路は、そもそも作られない。**
    ///
    /// `AccessibilityInserter` は自プロセスの要素を挿入対象から外す（背景スレッドからの
    /// 書き込みが永久にブロックするため）。したがって (a) の分岐へも載らず、
    /// 整形を待ってから挿入する (b) へ落ちる。**型ではなく構造による保証である。**
    @Test("自分自身の入力欄へは差し替えの錨を作らない")
    func neverAnchorsIntoItsOwnProcess() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, focusedProcess: RevisionRig.ownProcess)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            // AX 経路が使えないので最後の砦へ落ちる。**整形結果が入っている**
            // ＝ (b) の分岐（整形を待ってから挿入する）を通った証拠。
            #expect(rig.clipboard.left == [RevisionRig.refined])
            #expect(rig.history.entries.first?.insertionMethod == .clipboardOnly)
            #expect(await rig.session.canUndo == false)
        }
    }

    // MARK: - 経路判定

    /// **差し替えできない相手では (b) の分岐へ落ちる**（フェーズ 1 と同じ挙動）。
    @Test("範囲を選べない相手では整形を待ってから挿入する")
    func fallsBackToWaitingWhenRangeIsNotSettable() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, rangeSettable: false)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            // **最初から整形結果が入る。** 生テキストは一度も欄に現れない。
            #expect(rig.content == RevisionRig.contentWithRefined)
            let metrics = try #require(await rig.session.latestMetrics)
            #expect(metrics.waitedForRefinementBeforeInsert, "(b) の分岐なのに (a) と記録している")
        }
    }

    /// **設定 1 つでフェーズ 1 の挙動へ戻せる**（リスク R-10 の逃げ道）。
    @Test("beforeInsert では差し替えを一度も使わない")
    func beforeInsertModeNeverRevises() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, applyMode: .beforeInsert)
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            #expect(rig.content == RevisionRig.contentWithRefined)
            #expect(rig.accessibility.writtenTexts == [RevisionRig.refined], "2 回書いている")
            #expect(await rig.session.canUndo == false)
        }
    }

    /// 整形が返らなかった（打ち切り・利用不可）。**生テキストのまま終わる。**
    @Test("整形が返らなければ生テキストのまま終わる")
    func keepsRawTextWhenRefinementNeverReturns() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refined: nil)
            try await speakAndSettle(rig)

            #expect(rig.content == RevisionRig.contentWithRaw)
            #expect(rig.notices.notices == [.refinementNotApplied(nil)])
            #expect(rig.history.entries.first?.refinedText == nil)
        }
    }

    // MARK: - 中断（ESC）

    /// **保留中の差し替えに対する ESC は「取りやめるだけ」である。**
    /// 書き込みが 1 回も起きていないので、これは完全に安全な取消しである。
    @Test("保留中の差し替えは ESC で取りやめられる")
    func escapeCancelsAPendingRevision() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(300))
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("生テキストが挿入される") { !rig.history.entries.isEmpty }

            rig.hotkey.emit(.cancelled)
            try await waitUntil("顛末が出る") { !rig.notices.notices.isEmpty }

            #expect(rig.content == RevisionRig.contentWithRaw, "取りやめたのに書き換えている")
            #expect(rig.notices.notices == [.refinementNotApplied(nil)])
        }
    }

    /// **ESC を届かせるために、保留中は「処理中」を降ろさない。**
    /// 降ろすと `HotkeyDecision` が ESC を下流アプリのものとして扱い、
    /// 上の取消しが実機で到達不能になる（フェーズ 1 の最終レビュー I-1 と同じ形）。
    @Test("差し替えが片付くまで処理中を降ろさない")
    func keepsSessionBusyWhileARevisionIsPending() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(200))
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("生テキストが挿入される") { !rig.history.entries.isEmpty }
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            #expect(rig.hotkey.isSessionBusy, "保留中なのに処理中を降ろしている")

            try await waitUntil("差し替えが終わる") { !rig.notices.notices.isEmpty }
            try await waitUntil("処理中が降りる") { !rig.hotkey.isSessionBusy }
        }
    }

    // MARK: - 計測（NFR-P6a / NFR-P6b）

    /// **(a) では整形が NFR-P6a の予算に入らない。** それがこの設計の目的である。
    @Test("(a) の合計に整形は入らない")
    func totalExcludesRefinementInTheRawFirstBranch() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(120))
            try await speakAndSettle(rig)

            let metrics = try #require(await rig.session.latestMetrics)
            #expect(metrics.waitedForRefinementBeforeInsert == false)
            #expect(metrics.refine >= .milliseconds(100), "整形の所要が記録されていない")
            #expect(metrics.total == metrics.finalize + metrics.insert)
            #expect(metrics.total < metrics.refine + metrics.finalize + metrics.insert)
            #expect(metrics.revision != nil, "M6 が記録されていない")
            #expect(metrics.revision! >= metrics.refine)
        }
    }

    // MARK: - NFR-V3（読み戻しの範囲）

    /// **配線した後も、読み戻す範囲は「自分が書いた場所」を出ない**（承認された条件 1）。
    ///
    /// A3 は `TextReplacer` 単体でこれを固定した。ここで見るのは
    /// **`DictationSession` を通したときに、挿入器と差し替え器が合わせて
    /// どこを読むか**である。
    @Test("読み戻しは自分が書いた範囲だけに限られる")
    func readsOnlyItsOwnRanges() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root)
            try await speakAndSettle(rig)

            let allowed: Set<AXTextRange> = [
                // 挿入時に錨を作るための読み戻し（生テキストの範囲）
                RevisionRig.anchorRange,
                // 差し替えの事前検査（同じ範囲）と事後検査（整形結果の範囲）
                AXTextRange(
                    location: RevisionRig.prefix.count, length: RevisionRig.refined.count),
            ]
            let read = Set(rig.accessibility.readRanges)
            #expect(read == allowed, "自分が書いた場所の外を読んでいる: \(read)")
        }
    }
}

@Suite("FR-5(a): 反映できなかったときの計測")
struct RawTextFirstMetricsTests {

    /// **整形が返らなかった場合も M3 は記録する。**
    ///
    /// 成功時だけ記録すると、「打ち切りに掛かった」のか「逸脱の検査に落ちた」のかが
    /// 計測から消え、**(b) の打ち切りを引き直すときに見るべき分布が片側だけ欠ける**
    /// （(b) では M3 が常に記録されるため、比べられなくなる）。
    @Test("整形が返らなくても M3 は残る")
    func recordsRefinementDurationEvenWhenItReturnsNothing() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refined: nil, refineDelay: .milliseconds(120))
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("顛末が出る") { !rig.notices.notices.isEmpty }

            let metrics = try #require(await rig.session.latestMetrics)
            #expect(metrics.refine > .zero, "整形の所要が記録されていない")
            // **差し替えは走っていないので M6 は無い。** nil を未達と数えてはならない。
            #expect(metrics.revision == nil)
            #expect(metrics.meetsRevisionTarget == nil)
        }
    }
}

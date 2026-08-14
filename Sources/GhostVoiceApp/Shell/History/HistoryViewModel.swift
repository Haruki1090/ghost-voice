import Foundation
import GhostVoiceCore
import Observation
import Synchronization

/// 履歴の 1 件が持つ 2 つの文字列のどちらを扱うか（FR-9）。
public enum HistoryTextField: Sendable, Equatable, CaseIterable {
    /// 整形前の書き起こし。**Undo が戻す先と同じもの。**
    case raw
    /// 実際に挿入された文字列（整形されていれば整形後、されていなければ生）。
    case inserted

    public func text(of entry: HistoryEntry) -> String {
        switch self {
        case .raw: entry.rawText
        case .inserted: entry.insertedText
        }
    }
}

/// **窓を閉じたあと、前面が Ghost Voice から離れたか**（FR-9 の再挿入の前提）。
///
/// 再挿入は「そのとき最前面にある窓」へ書く。**まだ Ghost Voice が最前面なら、
/// 挿入先は Ghost Voice 自身になる。** 提示側（`AppWindow.dismissAndReturnFocus`）が
/// 挿入先の判定（`SystemAccessibility.frontmostProcessIdentifier()`）そのものを見て
/// 待ち、その決着をこの値で渡す。
///
/// - Important: **`reinsert` の引数に既定値を置いていない。** 置くと
///   「待ったかどうか」を言わずに挿入できてしまい、順序の間違いが型で防げなくなる。
public enum FocusHandback: Sendable, Equatable {
    /// 最前面が Ghost Voice でなくなった。**挿入してよい。**
    case returned
    /// 上限まで待っても最前面が Ghost Voice のままだった。**挿入してはならない。**
    case notReturned
}

/// 挿入経路の集計（検証項目 V-3 の実地データ）。
///
/// - Important: **`.notInserted` は分母に入れない。** ESC で中断された発話は
///   `.ax` / `.pasteboard` / `.clipboardOnly` のどれも通っていないので、
///   経路の割合に混ぜると分母が嘘になる（正本 §9.3 が「経路の集計からは除くこと」と
///   明記している）。**除いた件数は別に持って表に出す**——黙って落とすと、
///   一覧の件数と集計の件数が合わない理由が判らなくなる。
/// - Important: **secure input で拒否された発話はここにも履歴にも現れない**
///   （履歴そのものを作らないため。正本 §9.3）。したがって
///   **「挿入できなかった割合」をこの集計から出してはならない。**
public struct InsertionMethodTally: Sendable, Equatable {
    public var ax = 0
    public var pasteboard = 0
    public var clipboardOnly = 0
    /// **集計から除いた、挿入経路を 1 つも通っていない発話の件数。分母ではない。**
    public var notInsertedExcluded = 0

    /// 経路を通った発話の件数（＝分母）。
    public var insertedTotal: Int { ax + pasteboard + clipboardOnly }

    public init() {}

    public init(_ entries: [HistoryEntry]) {
        for entry in entries {
            switch entry.insertionMethod {
            case .ax: ax += 1
            case .pasteboard: pasteboard += 1
            case .clipboardOnly: clipboardOnly += 1
            case .notInserted: notInsertedExcluded += 1
            }
        }
    }
}

/// **履歴画面（FR-9）の状態と操作。**
///
/// ## 提示の仕方（**配線は統合時に行う。ここではやらない**）
///
/// | 何を | どう |
/// |---|---|
/// | 開く口 | **ステータス項目（`NSStatusItem`）のメニューの「履歴…」。** 設定画面と同じ場所に並べる |
/// | 窓 | `NSWindow` + `NSHostingView(rootView: HistoryView(model:))`。**`AppSurface` が `RunLoopEntry` を受け取ってから作る**（`AppSurface.swift`。run() 前に窓を作るとアプリが活性化し、挿入先が壊れる） |
/// | 前面 | 開くときは `NSApp.activate()` してよい。**閉じたら `NSApp.hide(nil)`** |
/// | **再挿入だけは順序が要る** | **窓を閉じて前面が戻ってから挿入すること。** 窓が前面のまま `reinsert` を呼ぶと、挿入先は Ghost Voice 自身の窓になる（`SystemAccessibility.frontmostProcessIdentifier()`）。`reinsert` は自分で窓を閉じない——窓を持っているのは提示側だからである。**提示側が「閉じる → 前面が戻るのを待つ → `reinsert`」の順で呼ぶこと。** 待ち方は**実測して決着した**（正本 §13 の V-43）——`didResignActiveNotification` では足りず、**挿入先の判定そのものが自分を指さなくなるまで待つ**。その決着は `focus:` で渡す |
/// | 購読 | **`start()` を 1 回だけ呼ぶ。** `HistoryStore.changes()` は呼ぶたびに独立したストリームを返すが、**1 本を 2 箇所で読んではならない**（`AsyncStream` の単一消費者制約）。ここは 1 本を 1 つのタスクで読む |
/// | 寿命 | ストアと同じ寿命の場所へ。`deinit` で購読が解ける |
///
/// ## 並行性の約束（Core の罠を踏まないための形）
///
/// - **`HistoryStore.append` を呼ばない。** あれは同期の I/O を行い、
///   **MainActor から呼んではならない**口である（doc コメント）。書くのは
///   `DictationSession` だけで、画面は読むだけである。
/// - **削除と上限の変更は `@concurrent` なので `await` してよい**（Core 側で
///   背景へ逃がしている）。**MainActor は塞がらない。**
/// - **`entries` / `limit` の読みは同期でよい**（ロックを取るだけで I/O をしない）。
/// - **通知は MainActor で来ない。** `changes()` を 1 つのタスクで `for await` して
///   いるので、この型の中では常に MainActor 側に居る（`Task` が隔離を継ぐ）。
///   `observe(_:)` のコールバックを直に使うと**書き込みスレッドで呼ばれる**ので、
///   そちらは使っていない。
/// - **順序を壊さない。** `observe` を使い、通知ごとに `Task { @MainActor in … }` で
///   持ち上げる書き方は、**タスクの実行順が保証されないので古い一覧が後から届きうる。**
///   1 本のストリームを 1 つのタスクで順に読むこの形なら、その窓が無い。
@MainActor
@Observable
public final class HistoryViewModel {

    /// 新しい順。
    public private(set) var entries: [HistoryEntry]

    /// いま効いている保存件数の上限。
    public private(set) var limit: Int

    /// 直近の操作の顛末。**表示したら `clearOutcome()` で畳む。**
    public private(set) var lastOutcome: ActionOutcome?

    /// **`history.json` を読めなかったこと**（`StoreFileNotice`）。
    /// 履歴が空なのが「まだ喋っていない」からなのか「読めなかった」からなのかは、
    /// **一覧を見ただけでは区別が付かない。**
    public private(set) var fileNotice: StoreFileNotice?

    /// 挿入経路の集計（V-3）。**`.notInserted` を分母から除いてある。**
    public var tally: InsertionMethodTally { InsertionMethodTally(entries) }

    private let store: HistoryStore
    private let output: any HistoryTextOutput

    /// **`nonisolated` にしてある。** `deinit` は MainActor の外から呼ばれうるので、
    /// そこからも取り消せる必要がある（放置すると、画面が消えた後も購読タスクが残り、
    /// 解放されない画面のモデルへ通知が届き続ける）。`SessionMirror` と同じ形。
    private nonisolated let subscription = Mutex<Task<Void, Never>?>(nil)

    public init(
        store: HistoryStore,
        output: any HistoryTextOutput,
        fileNotice: StoreFileNotice? = nil
    ) {
        self.store = store
        self.output = output
        self.entries = store.entries
        self.limit = store.limit
        self.fileNotice = fileNotice
    }

    deinit {
        subscription.withLock { $0 }?.cancel()
    }

    // MARK: - 購読

    /// 履歴の変化を追い始める。**2 回呼んでも 2 本にならない。**
    ///
    /// - Important: `HistoryStore.changes()` の各要素は**その時点の全件**である。
    ///   差分ではないので、取りこぼしても表示は正しい（最新が届けば追いつく）。
    public func start() {
        guard subscription.withLock({ $0 == nil }) else { return }
        // **1 本のストリームを 1 つのタスクで読む。** これが単一消費者制約への答え。
        let stream = store.changes()
        let task = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                self.entries = snapshot
                self.limit = self.store.limit
            }
        }
        subscription.withLock { $0 = task }
    }

    /// 購読をやめる。**二度呼んでも安全。**
    public func stop() {
        let task = subscription.withLock { current -> Task<Void, Never>? in
            let running = current
            current = nil
            return running
        }
        task?.cancel()
    }

    // MARK: - 操作

    /// 操作の顛末。
    public enum ActionOutcome: Sendable, Equatable {
        case copied(HistoryTextField)
        case copyFailed
        /// 挿入できた経路。
        case reinserted(InsertionMethod)
        /// **secure input が有効だったので何もしなかった。** テキストはどこにも残していない。
        case reinsertRefusedSecureInput
        /// **前面が Ghost Voice から戻らなかったので、挿入をやめた。**
        ///
        /// 挿入していれば Ghost Voice 自身へ入り、**行き先が 1 つも残らなかった**
        /// （AX は自プロセスを弾き、Pasteboard 経路は ⌘V がどこにも刺さらないまま
        /// 300 ms 後にクリップボードを元へ戻す）。
        ///
        /// - Parameter copied: クリップボードへ退避できたか。
        ///   **できなくても発話は履歴に残っている**（この一覧のコピーで取り出せる）。
        case reinsertAbandoned(copied: Bool)
        /// **どの経路でも挿入できず、クリップボードへも残せなかった**
        /// （`InsertionOutcome.failedEverywhere`）。
        ///
        /// `.reinserted(.clipboardOnly)` と混ぜてはならない。あちらは
        /// 「⌘V で貼れます」という主張である。**テキストは履歴にだけ残っている。**
        case reinsertFailedEverywhere
        case deleted(count: Int)
        case deleteFailed(String)

        public var message: String {
            switch self {
            case .copied(.raw): "整形前のテキストをコピーしました"
            case .copied(.inserted): "挿入したテキストをコピーしました"
            case .copyFailed: "コピーできませんでした"
            case .reinserted(.ax), .reinserted(.pasteboard): "前面のアプリへ挿入しました"
            case .reinserted(.clipboardOnly):
                "挿入できなかったので、クリップボードへ残しました（⌘V で貼れます）"
            case .reinserted(.notInserted):
                // **本来ここへ来ない。** `insert` は `.notInserted` を返さない
                // （あれは中断された発話を履歴へ記録するための値である）。
                // それでも文言を置くのは、来たときに黙って成功に見えないようにするため。
                "挿入の結果を判定できませんでした"
            case .reinsertRefusedSecureInput:
                "パスワード入力中（secure input）なので挿入しませんでした。**クリップボードにも残していません。**"
            // **どこにあるかを必ず言う。**「挿入しませんでした」だけだと消えたと読まれる。
            case .reinsertAbandoned(copied: true):
                "前面のアプリへ戻らなかったので挿入しませんでした（Ghost Voice 自身へ入るため）。"
                    + "テキストはクリップボードにあります（⌘V で貼れます）。履歴にも残っています。"
            case .reinsertAbandoned(copied: false):
                "前面のアプリへ戻らなかったので挿入しませんでした。**クリップボードへも置けませんでした。**"
                    + "テキストは履歴に残っています（この一覧のコピーで取り出せます）。"
            case .reinsertFailedEverywhere:
                "どこにも挿入できず、**クリップボードへも置けませんでした。**"
                    + "テキストは履歴に残っています（この一覧のコピーで取り出せます）。"
            case .deleted(let count): "\(count) 件削除しました"
            case .deleteFailed(let reason): "削除できませんでした（\(reason)）"
            }
        }

        public var isFailure: Bool {
            switch self {
            case .copied, .reinserted, .deleted: false
            case .copyFailed, .deleteFailed: true
            // **拒否は失敗ではない**（要件定義書 FR-4 の例外。`SessionFailureNotice.isRefusal`
            // と同じ扱いにする。赤く出すと「発話を失った」と読まれる）。
            case .reinsertRefusedSecureInput: false
            // クリップボードへ退避できたなら、`.clipboardOnly` と同じ縮退である
            // （出口はある）。**できなければ残る出口が履歴だけになるので、赤く出す。**
            case .reinsertAbandoned(let copied): !copied
            // 残る出口が履歴だけになる。**赤く出す。**
            case .reinsertFailedEverywhere: true
            }
        }
    }

    /// クリップボードへコピーする（FR-9）。
    @discardableResult
    public func copy(_ entry: HistoryEntry, field: HistoryTextField) -> ActionOutcome {
        let outcome: ActionOutcome =
            output.copy(field.text(of: entry)) ? .copied(field) : .copyFailed
        lastOutcome = outcome
        return outcome
    }

    /// 前面のアプリへ挿入し直す（FR-9）。
    ///
    /// - Important: **この画面の窓が前面のまま呼んではならない。** 挿入先が
    ///   Ghost Voice 自身になる。提示側が「窓を閉じる → 前面が戻る → これを呼ぶ」の
    ///   順で使うこと（型の上の注記）。**その決着を `focus` で渡す。**
    /// - Important: **`.notInserted` の履歴も再挿入できる。** 中断された発話は
    ///   一度も挿入されていないので、**再挿入こそがその発話の唯一の出口である**
    ///   （`InsertionMethod.notInserted` の doc コメントが「効くのは FR-9 の再挿入だけ」
    ///   と定めている）。
    ///
    /// ## `focus == .notReturned` のときに挿入しない理由
    ///
    /// 最前面がまだ Ghost Voice なら、挿入先は Ghost Voice 自身である。
    /// **そこへ進めても発話の出口にはならない**——
    ///
    /// - AX 経路は自プロセスを弾く（`AccessibilityInserter.isSafeTarget`）。
    /// - Pasteboard 経路は ⌘V を送るが、窓を隠した後なのでどこにも刺さらず、
    ///   **300 ms 後に元のクリップボードへ戻す**（`PasteboardInserter.defaultRestoreDelay`）。
    ///   つまり**テキストの行き先が 1 つも残らないまま「挿入しました」と出る。**
    ///
    /// **だから挿入をやめ、クリップボードへ置く。** 発話は失われない
    /// ——クリップボードと履歴の両方にある。置けなかった場合も履歴には残る。
    ///
    /// - Parameter focus: 窓を閉じたあと、前面が Ghost Voice から離れたか。
    ///   **既定値を置いていない**（置くと待たずに挿入できてしまう）。
    @discardableResult
    public func reinsert(
        _ entry: HistoryEntry, field: HistoryTextField, focus: FocusHandback
    ) async -> ActionOutcome {
        let text = field.text(of: entry)
        guard focus == .returned else {
            let outcome = ActionOutcome.reinsertAbandoned(copied: output.copy(text))
            lastOutcome = outcome
            return outcome
        }
        let result = await output.insert(text)
        let outcome: ActionOutcome
        switch result {
        case .inserted(let method): outcome = .reinserted(method)
        case .refusedSecureInput: outcome = .reinsertRefusedSecureInput
        case .failedEverywhere: outcome = .reinsertFailedEverywhere
        }
        lastOutcome = outcome
        return outcome
    }

    /// 1 件消す。
    @discardableResult
    public func delete(_ entry: HistoryEntry) async -> ActionOutcome {
        do {
            // **`@concurrent` なので MainActor は塞がらない**（`HistoryStore.remove`）。
            let removed = try await store.remove(id: entry.id)
            let outcome = ActionOutcome.deleted(count: removed ? 1 : 0)
            lastOutcome = outcome
            return outcome
        } catch {
            let outcome = ActionOutcome.deleteFailed(String(describing: error))
            lastOutcome = outcome
            return outcome
        }
    }

    /// 選んだぶんをまとめて消す。
    @discardableResult
    public func delete(ids: Set<HistoryEntry.ID>) async -> ActionOutcome {
        do {
            let removed = try await store.remove(ids: ids)
            let outcome = ActionOutcome.deleted(count: removed)
            lastOutcome = outcome
            return outcome
        } catch {
            let outcome = ActionOutcome.deleteFailed(String(describing: error))
            lastOutcome = outcome
            return outcome
        }
    }

    /// 全部消す。
    ///
    /// - Important: **これを呼ぶと Undo の候補も消える**（`HistoryStore.removeAll` の注記）。
    ///   画面は確認を挟むこと。
    @discardableResult
    public func deleteAll() async -> ActionOutcome {
        let before = entries.count
        do {
            try await store.removeAll()
            let outcome = ActionOutcome.deleted(count: before)
            lastOutcome = outcome
            return outcome
        } catch {
            let outcome = ActionOutcome.deleteFailed(String(describing: error))
            lastOutcome = outcome
            return outcome
        }
    }

    public func clearOutcome() { lastOutcome = nil }
}

import Foundation
import GhostVoiceCore
import Observation

/// **設定画面（FR-11）の状態と操作。** `SettingsView` はこれを描くだけである。
///
/// ## 提示の仕方（**配線は統合時に行う。ここではやらない**）
///
/// | 何を | どう |
/// |---|---|
/// | 開く口 | **ステータス項目（`NSStatusItem`）のメニューの「設定…」。** `LSUIElement = true` なので Dock も標準のアプリメニューも無い（正本 §10）。⌘, は窓が前面のときだけ効く |
/// | 窓 | `NSWindow` + `NSHostingView(rootView: SettingsView(model:))`。**`AppSurface` の実装が `RunLoopEntry` を受け取ってから作ること**（`AppSurface.swift`。`NSApp.run()` の前に窓を作るとアプリが活性化し、`AccessibilityInserter.frontmostProcessIdentifier()` が Ghost Voice 自身を拾って**挿入先が壊れる**） |
/// | 前面 | **開くときは `NSApp.activate()` してよい**（利用者が能動的に開く画面なので）。**閉じたら `NSApp.hide(nil)` で前面を明示的に返すこと。** 返さないと、次の発話が Ghost Voice 自身へ挿入される |
/// | HUD との関係 | **窓を共有しない。** HUD は `.nonactivatingPanel` で活性化を避ける設計であり、活性化してよいこの窓と要件が正反対である |
/// | 寿命 | **ストアと同じ寿命の場所に置く**（`AppServices` を握る `AppSurface`）。作り直すと `loadFailure` の事実が消える（`StoreFileNotice.collect` の注記） |
///
/// ## 並行性の約束（Core の罠を踏まないための形）
///
/// - **`SettingsStore.update` の `mutate` クロージャは、ロックを保持したまま走る。**
///   `NSLock` は非再帰なので、**クロージャの中から同じ store の `settings` を読むと
///   自己デッドロックする。** ここでは `draft` を丸ごと代入する形（`$0 = next`）しか
///   書かない。**構造として読みようが無い。**
/// - **同じ `update` は同期のファイル I/O を行う。** `@MainActor` から直に呼ぶと
///   メインスレッドが止まり、`CGEventTap` の配送が悪化する（実測 p50 0.045 → 12.8 ms）。
///   書き込みは必ず `BackgroundWrite` を通す。
/// - **1 項目ごとに保存しない。** `update` の doc コメントが「まとめて 1 回にすること」と
///   定めている。画面は `draft` を編集し、`save()` で 1 回だけ書く。
/// - **`AsyncStream` は 1 本につき 1 人。** この画面はストリームを 1 本も持たない
///   （設定は購読するものではない）。履歴の購読は `HistoryViewModel` が 1 本だけ持つ。
///
/// ## ホットキーの妥当性検査はここに無い
///
/// **検査は Core に 1 つだけある。**
/// 単体の不変条件は `HotkeyBinding.init(keyCode:modifiers:)`、PTT と Undo の関係は
/// `Settings.validateHotkeys()` である。**画面はそれを呼ぶだけで、条件を書き直さない。**
/// 2 箇所に分かれると必ずずれる（フェーズ 1 の持ち越し項目 4 / 12 がまさにそれで、
/// 保存経路にしか検査が無く手編集が素通りしていた）。
@MainActor
@Observable
public final class SettingsViewModel {

    // MARK: - 表に出す状態

    /// 編集中の設定。**保存するまでディスクへは行かない。**
    ///
    /// `Settings` を丸ごと持つのは、項目ごとの複製を作らないためである。
    /// 項目を並べ直すと、Core に項目が増えたとき画面だけ古いままになる。
    public var draft: Settings

    /// 編集中のユーザー辞書（FR-6 / 正本 §9.2）。
    public var vocabularyTerms: [VocabularyTerm]

    /// **読めなかったファイルの告知**（統括の裁定の条件）。`StoreFileNotice` を参照。
    public private(set) var fileNotices: [StoreFileNotice]

    /// 直近の保存の顛末。**成功も出す**（黙って終わると保存されたか判らない）。
    public private(set) var lastSave: SaveOutcome?

    /// 保存中か。**この間はボタンを塞ぐ。** モデル導入を伴うと数分戻らない。
    public private(set) var isSaving = false

    /// いま `draft` が保存できる形か。**`Settings.validateHotkeys()` の答えそのもの。**
    ///
    /// 保存を押す前に赤字を出すために使う。**ここで条件を書き直していない**ことに注意。
    public var hotkeyConflict: SettingsError? {
        do {
            try draft.validateHotkeys()
            return nil
        } catch let error as SettingsError {
            return error
        } catch {
            return nil
        }
    }

    /// ディスクの内容から変わっているか（「保存」の活性）。
    public var hasUnsavedChanges: Bool {
        draft != settings.settings || vocabularyTerms != vocabulary.terms
    }

    /// 選ばせるロケール（FR-8）。**自由入力も許す**ので、これは近道であって制限ではない。
    ///
    /// `ja-JP` / `en-US` の 2 つだけ並べるのは、実測があるのがこの 2 つだからである
    /// （正本 §2.5）。**増やすときはロケール枠（上限 5）に注意すること**——
    /// 相異なるロケールを 5 種類試すと `localeReservationLimitReached` に達する
    /// （`DictationSession.warmUp` の注記）。
    public static let suggestedLocaleIdentifiers = ["ja-JP", "en-US"]

    // MARK: - 依存

    private let settings: SettingsStore
    private let vocabulary: VocabularyStore
    private let history: HistoryStore
    private let session: (any SettingsSessionControlling)?
    private let directory: URL
    private let backgroundWrite: BackgroundWrite
    private let fileManager: FileManager

    /// **書き込みが走った実行文脈を、検査から見るための穴。既定は nil（何もしない）。**
    ///
    /// これが production のコードにあるのは、「MainActor を塞がない」という性質を
    /// **実際の書き込み地点で**検査するためである。書き手（`BackgroundWrite`）の側で
    /// 測ると、書き手が自分で選んだ文脈を自分で報告することになり、
    /// **この ViewModel がその書き手を本当に使っているか**は何も示せない。
    ///
    /// 引数は「いまメインスレッドか」。**本番では常に false でなければならない。**
    public var writeContextProbe: (@Sendable (_ isMainThread: Bool) -> Void)?

    /// - Parameter session: `nil` を許す（`--shell-only` 起動・キー監視を開始できなかった場合。
    ///   `AppServices.session` と同じ約束）。**nil のときロケールの切り替えは
    ///   ファイルへ書くだけになる**ので、その旨を保存の顛末に載せる。
    /// - Parameter directory: ストアを作るときに渡した保存先。**ストアと同じものを渡すこと。**
    ///   ここが食い違うと `.corrupt` の在り処を嘘の場所で案内する。
    public init(
        settings: SettingsStore,
        vocabulary: VocabularyStore,
        history: HistoryStore,
        session: (any SettingsSessionControlling)?,
        directory: URL = StorageRoot.default,
        backgroundWrite: BackgroundWrite = .offCallerActor,
        fileManager: FileManager = .default
    ) {
        self.settings = settings
        self.vocabulary = vocabulary
        self.history = history
        self.session = session
        self.directory = directory
        self.backgroundWrite = backgroundWrite
        self.fileManager = fileManager
        self.draft = settings.settings
        self.vocabularyTerms = vocabulary.terms
        self.fileNotices = StoreFileNotice.collect(
            settings: settings, vocabulary: vocabulary, history: history,
            directory: directory, fileManager: fileManager)
    }

    // MARK: - ホットキーの編集

    /// 捕まえた打鍵からバインドを組み立てる。
    ///
    /// **規則はここに無い。** 修飾キー単独かどうかの表も、キーコードの範囲も
    /// `HotkeyBinding` が持っている。ここがしているのは
    /// **「修飾キー単独なら、そのキー自身の修飾キーが唯一の正解」という Core の案内に
    /// 従って `modifiers` を決める**ことだけで、それ以外は素通しである
    /// （`HotkeyBinding.ownModifier(forKeyCode:)` の doc コメントが
    /// 「設定画面はこれを使って、捕まえたキーから必ず妥当なバインドを組み立てられる」
    /// と定めている）。
    ///
    /// 押されている修飾キーをそのまま渡してよい。右 Option を押した瞬間は
    /// `modifiers` に `.option` が立っているが、そこへ ⇧ が混ざっていても
    /// **足された修飾キーは無視されて単独で発火する**（実測。§2.3）ので、
    /// **足させない**のが正しい。
    ///
    /// - Throws: `HotkeyBindingError` — **利用者への説明にそのまま使う。**
    ///   どの規則に触れたかを型で持っている。
    public func makeBinding(
        keyCode: Int64, modifiers: HotkeyBinding.Modifiers
    ) throws -> HotkeyBinding {
        let resolved = HotkeyBinding.ownModifier(forKeyCode: keyCode) ?? modifiers
        return try HotkeyBinding(keyCode: keyCode, modifiers: resolved)
    }

    /// PTT キーを差し替える。**保存はしない**（`save()` を呼ぶまでディスクは変わらない）。
    public func setHotkey(keyCode: Int64, modifiers: HotkeyBinding.Modifiers) throws {
        draft.hotkey = try makeBinding(keyCode: keyCode, modifiers: modifiers)
    }

    /// Undo キーを差し替える。**保存はしない。**
    ///
    /// - Note: **PTT との衝突はここでは投げない。** 投げると、PTT を先に変えて
    ///   Undo を後から直す、という順序が踏めなくなる（途中の状態が常に不正になる）。
    ///   衝突は `hotkeyConflict` が編集中ずっと見えており、`save()` が門になる。
    public func setUndoHotkey(keyCode: Int64, modifiers: HotkeyBinding.Modifiers) throws {
        draft.undoHotkey = try makeBinding(keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: - 保存

    /// 保存の顛末。**「保存した」だけでなく「何が起きたか」を持つ。**
    public enum SaveOutcome: Sendable, Equatable {
        /// 書けた。
        /// - Parameter transcriberReloaded: ロケール／認識種別を切り替え直したか。
        /// - Parameter undoHotkeyRebound: Undo キーを監視器へ反映したか。
        /// - Parameter quarantined: この保存で `.corrupt` へ退避したファイル。
        case saved(
            transcriberReloaded: Bool, undoHotkeyRebound: Bool, quarantined: [StoreFileNotice.File])
        /// **1 バイトも書いていない。** PTT キーと Undo キーの修飾キーが衝突している。
        case rejectedHotkeyConflict
        /// **1 バイトも書いていない。** 発話の処理中だったのでロケールを切り替えられない。
        case rejectedSessionBusy
        /// **1 バイトも書いていない。** 認識器の準備に失敗した。
        case rejectedTranscriberUnavailable(String)
        /// **1 バイトも書いていない。** 辞書の件数が上限を超えている。
        case rejectedTooManyTerms(limit: Int)
        /// 書き込みそのものが失敗した。**どこまで書けたかは下の `partiallyApplied` を見る。**
        case writeFailed(String, partiallyApplied: Bool)

        /// 利用者へ出す 1 行。
        public var message: String {
            switch self {
            case .saved(let reloaded, let rebound, let quarantined):
                var text = "設定を保存しました。"
                if reloaded { text += "認識の言語／種別を切り替えました。" }
                if rebound { text += "Undo キーを反映しました。" }
                if !quarantined.isEmpty {
                    text +=
                        "読めなかった "
                        + quarantined.map(\.fileName).joined(separator: " / ")
                        + " は、上書きする前に .corrupt へ退避しました。"
                }
                return text
            case .rejectedHotkeyConflict:
                return
                    "PTT キーの修飾キーを Undo キーが含んでいます（押すと録音が始まります）。**保存していません。**"
            case .rejectedSessionBusy:
                return
                    "発話の処理中でした。言語と認識種別は録音中に切り替えられません。少し待ってもう一度保存してください。**保存していません。**"
            case .rejectedTranscriberUnavailable(let reason):
                return
                    "その言語／認識種別で認識器を準備できませんでした（\(reason)）。**保存していません。** モデルが未導入の場合は システム設定 > 一般 > 言語と地域 に言語を追加してください。"
            case .rejectedTooManyTerms(let limit):
                return "ユーザー辞書は \(limit) 件までです。**保存していません。**"
            case .writeFailed(let reason, let partial):
                return partial
                    ? "保存の途中で失敗しました（\(reason)）。**一部だけ反映されています。** もう一度保存してください。"
                    : "保存できませんでした（\(reason)）。**1 バイトも書いていません。**"
            }
        }

        /// 赤く出すか。
        public var isFailure: Bool {
            if case .saved = self { return false }
            return true
        }
    }

    /// **編集した内容をまとめて 1 回で書く。**
    ///
    /// ## 順序に意味がある
    ///
    /// 1. **ホットキーの検査**（ディスクへ触らない）。落ちたら 1 バイトも書かない。
    /// 2. **辞書の件数の検査**（同上）。
    /// 3. **認識器の切り替え。** ロケールか認識種別が変わったときだけ。
    ///    **ここを保存より先に置くのが要点である**——後ろに置くと
    ///    「画面には `en-US` と出ているのに認識は `ja-JP`」という状態がディスクに焼き付く。
    ///    これはフェーズ 1 で潰した**「成功と記録されるのに中身が違う」と同じ形**である。
    ///    失敗したらファイルは一切変えない。
    /// 4. **ファイルへ書く**（設定と辞書。`BackgroundWrite` 経由でメインスレッドを離れて）。
    /// 5. **履歴の上限を実行時へ反映**（`HistoryStore.setLimit`。下げたらその場で切り詰まる）。
    /// 6. **Undo キーを監視器へ反映**（保存しただけでは効かない）。
    ///
    /// 4 以降で失敗した場合は「一部だけ反映された」と告げる。**黙らない。**
    public func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let next = draft
        let terms = vocabularyTerms

        // 1. **画面側で条件を書き直さない。** 復元経路と同じ入口を呼ぶだけ。
        do {
            try next.validateHotkeys()
        } catch {
            lastSave = .rejectedHotkeyConflict
            return
        }

        // 2. 辞書の件数。**正規化してから数えるのは Core の仕事**なので、ここでは
        //    上限だけを先に見る。厳密な判定は `VocabularyStore.replace` が行い、
        //    そこで落ちたら `.rejectedTooManyTerms` に落ちる（下の catch）。
        //    先に見るのは、ファイル I/O を 1 往復ぶん節約するためである。
        if terms.count > VocabularyStore.maxTerms {
            lastSave = .rejectedTooManyTerms(limit: VocabularyStore.maxTerms)
            return
        }

        // 3. 認識器の切り替え。**保存より先。**
        let stored = settings.settings
        let transcriberChanged =
            next.localeIdentifier != stored.localeIdentifier
            || next.transcriberKind != stored.transcriberKind
        var transcriberReloaded = false
        if transcriberChanged, let session {
            do {
                try await session.prepareTranscriber(
                    locale: next.locale, kind: next.transcriberKind)
                transcriberReloaded = true
            } catch DictationSessionError.busy {
                lastSave = .rejectedSessionBusy
                return
            } catch {
                lastSave = .rejectedTranscriberUnavailable(String(describing: error))
                return
            }
        }

        // 4. ファイルへ書く。**退避が起きるのはこの瞬間である。**
        //
        //    どのファイルが退避されるかは**予告しない。観測する。** 退避は
        //    `AtomicJSONFile.save` が実際に走った分にしか起きず、たとえば
        //    `HistoryStore.setLimit` は内容が変わらなければ 1 バイトも書かない
        //    （＝ history.json は退避されない）。予告すると、起きていない退避を
        //    「退避しました」と告げることになる。**それはこの画面が潰しにきた形そのものである。**
        let pendingBefore = Set(fileNotices.filter { $0.quarantine == .pending }.map(\.file))
        let settingsStore = self.settings
        let vocabularyStore = self.vocabulary
        let probe = self.writeContextProbe
        do {
            try await backgroundWrite {
                probe?(Thread.isMainThread)
                // **クロージャの中から `settingsStore.settings` を読まない。**
                // `update` はロックを保持したままこれを走らせるので、読むと自己デッドロックする。
                // 丸ごと代入する形にしてあるので、読む余地が構造として無い。
                try settingsStore.update { $0 = next }
                try vocabularyStore.replace(terms)
            }
        } catch VocabularyError.tooManyTerms {
            lastSave = .rejectedTooManyTerms(limit: VocabularyStore.maxTerms)
            return
        } catch {
            lastSave = .writeFailed(String(describing: error), partiallyApplied: transcriberReloaded)
            return
        }

        // ここから先の失敗は「ファイルは書けたが実行中の状態へ反映しきれなかった」である。
        var partialFailure: String?

        // 5. 履歴の上限。**`@concurrent` なので MainActor から `await` してよい**
        //    （`HistoryStore.setLimit` の doc コメント）。
        do {
            try await history.setLimit(next.historyLimit)
        } catch {
            partialFailure = String(describing: error)
        }

        // 6. Undo キー。**保存しただけでは監視器は古いキーを見ている。**
        var undoRebound = false
        if next.undoHotkey != stored.undoHotkey, let session {
            do {
                try await session.rebindUndoHotkey(to: next.undoHotkey)
                undoRebound = true
            } catch {
                partialFailure = partialFailure ?? String(describing: error)
            }
        }

        // 退避の状態を測り直す。**保存を境に `.pending` は `.moved` へ変わる。**
        refreshFileNotices()
        let quarantined = fileNotices
            .filter { pendingBefore.contains($0.file) && $0.quarantine == .moved }
            .map(\.file)

        if let partialFailure {
            lastSave = .writeFailed(partialFailure, partiallyApplied: true)
        } else {
            lastSave = .saved(
                transcriberReloaded: transcriberReloaded,
                undoHotkeyRebound: undoRebound,
                quarantined: quarantined)
        }
    }

    /// 編集を捨ててディスクの内容へ戻す。
    public func discard() {
        draft = settings.settings
        vocabularyTerms = vocabulary.terms
        lastSave = nil
    }

    /// 告知を出し終えたら畳む。
    public func clearLastSave() { lastSave = nil }

    /// 退避の状態だけを測り直す。
    ///
    /// **`loadFailure` は測り直さない**（ストアの `init` の時点の事実であり、
    /// 後から変わらない）。変わるのは「元のファイルがまだ在るか」だけである。
    private func refreshFileNotices() {
        fileNotices = fileNotices.map { notice in
            StoreFileNotice(
                file: notice.file,
                quarantine: StoreFileNotice.quarantineState(
                    of: notice.file, in: directory,
                    originalContents: notice.originalContents, fileManager: fileManager),
                directory: notice.directory,
                reason: notice.reason,
                originalContents: notice.originalContents)
        }
    }
}

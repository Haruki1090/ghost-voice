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
/// | 窓 | `NSWindow` + `NSHostingView(rootView: SettingsView(model:))`。**`AppSurface` の実装が `RunLoopEntry` を受け取ってから作ること**（`AppSurface.swift`。`NSApp.run()` の前に窓を作るとアプリが活性化し、`SystemAccessibility.frontmostProcessIdentifier()` が Ghost Voice 自身を拾って**挿入先が壊れる**） |
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

    /// **キー監視を開始できなかったこと。** `nil` なら開始できている。
    ///
    /// ## HUD との棲み分け（統括が回収を指示した論点）
    ///
    /// **HUD は 1 行、設定画面は全文と直し方**である。HUD 側は起動時に 10 秒だけ
    /// `AppPermissionGuidance.summary(for:)`（1 行）を出す——`.app` を Finder から
    /// 起動すると標準エラーはどこにも出ないので、**そこでしか気づけない。**
    /// しかしそれは**気づくための入口**であって、直すための情報ではない
    /// （notch の帯は実測 221 pt しかなく、システム設定のパスも載らない）。
    ///
    /// **HUD を落とさないのは、設定画面は利用者が開かないと出ないからである。**
    /// 「押しても何も起きない」に気づいた利用者が設定画面へ辿り着く保証は無い。
    /// **重ねてよいのは、片方が「気づく」でもう片方が「直す」のときだけ**である。
    public let hotkeyFailure: HotkeyError?

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
    /// キー監視器。**`nil` なら打鍵の捕獲も PTT キーの反映もできない**
    /// （`--shell-only` 起動・監視を開始できなかった場合）。
    private let hotkey: (any HotkeyControlling)?
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
        hotkey: (any HotkeyControlling)? = nil,
        hotkeyFailure: HotkeyError? = nil,
        directory: URL = StorageRoot.default,
        backgroundWrite: BackgroundWrite = .offCallerActor,
        fileManager: FileManager = .default
    ) {
        self.settings = settings
        self.vocabulary = vocabulary
        self.history = history
        self.session = session
        self.hotkey = hotkey
        self.hotkeyFailure = hotkeyFailure
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

    // MARK: - 打鍵の捕獲（FR-11「ホットキーを設定画面から変更できる」）

    /// どちらのキーを捕まえているか。
    public enum HotkeyField: Sendable, Equatable {
        case pushToTalk
        case undo
    }

    /// いま捕獲中のキー。`nil` なら捕獲していない。
    ///
    /// **画面の「キーを押してください」と一致させること。** ずれると、
    /// 利用者は捕獲中と気づかずに打鍵し（PTT は発火しないので）**何も起きないように見える。**
    public private(set) var capturingField: HotkeyField?

    /// 捕獲の顛末（取り消した・その組は使えない）。**表示したら畳む。**
    public private(set) var captureMessage: String?

    /// 打鍵を捕まえて `draft` へ入れる。**保存はしない。**
    ///
    /// ## 何がどこで決まるか
    ///
    /// | 決めること | 誰が |
    /// |---|---|
    /// | どの打鍵を 1 つの組とみなすか（修飾キーは離した瞬間・文字キーは押した瞬間） | `HotkeyCaptureState`（Core） |
    /// | その組が `HotkeyBinding` として成り立つか | `HotkeyBinding.init`（Core） |
    /// | 捕獲中に PTT を発火させないこと | `CGEventTapHotkeyMonitor.handle`（Core） |
    /// | 「いま捕獲中」を画面に出すこと | ここ |
    ///
    /// **画面は規則を 1 つも持たない。** 2 箇所に分かれると必ずずれる。
    public func beginCapture(_ field: HotkeyField) {
        guard let hotkey else {
            // **黙って何も起きない形にしない。** 捕獲できない理由を言う。
            captureMessage =
                "キー監視が動いていないので、打鍵を捕まえられません。"
                + "権限を与えて Ghost Voice を起動し直すか、`settings.json` を直接編集してください。"
            return
        }
        // 押しっぱなしの捕獲を残さない（2 度目を押したときに前の捕獲が生きていると、
        // 決着が古い欄へ入る）。
        hotkey.endCapture()
        capturingField = field
        captureMessage = nil
        hotkey.beginCapture { [weak self] outcome in
            // **タップのコールバックのスレッドから来る。** MainActor へ持ち上げる。
            // 決着は 1 件しか来ないので、`Task` の実行順が問題になる余地は無い。
            Task { @MainActor [weak self] in
                self?.finishCapture(outcome, field: field)
            }
        }
    }

    /// 捕獲をやめる。**窓を閉じるときは必ず呼ぶこと**（閉じるまで PTT が効かない）。
    public func cancelCapture() {
        hotkey?.endCapture()
        capturingField = nil
    }

    public func clearCaptureMessage() { captureMessage = nil }

    private func finishCapture(_ outcome: HotkeyCaptureOutcome, field: HotkeyField) {
        // 別の欄の捕獲が先に始まっていたら、古い決着は捨てる。
        guard capturingField == field else { return }
        capturingField = nil

        switch outcome {
        case .pending:
            // 監視器は決着しか配らない。来たら内部の誤りである。**黙って成功に見せない。**
            captureMessage = "打鍵を判定できませんでした（内部の誤り）。"

        case .cancelled:
            captureMessage = "取りやめました。キーは変えていません。"

        case .captured(let captured):
            do {
                let binding = try makeBinding(
                    keyCode: captured.keyCode, modifiers: captured.modifiers)
                switch field {
                case .pushToTalk: draft.hotkey = binding
                case .undo: draft.undoHotkey = binding
                }
                captureMessage = nil
            } catch let error as HotkeyBindingError {
                // **どの規則に触れたかは Core が型で持っている。** 画面は言い直さない。
                captureMessage = error.explanation
            } catch {
                captureMessage = "そのキーは使えません（\(error)）。"
            }
        }
    }

    // MARK: - ユーザー辞書の編集（FR-11 / FR-6）

    /// 誤認識表記を 1 つの入力欄で見せるための文字列。
    ///
    /// **辞書は FR-6（誤認識の修正）の入力であり、`RefinementGuard` が
    /// 「頼んだ置換」と「逸脱」を区別する根拠でもある**（正本 §5.5.1）。
    /// ここを編集できないと、整形が誤認識を直せないまま逸脱として捨てられる側に回る。
    public func misheardText(at index: Int) -> String {
        guard vocabularyTerms.indices.contains(index) else { return "" }
        return MisheardListText.text(vocabularyTerms[index].misheard)
    }

    /// 正しい表記を差し替える。**保存はしない。**
    public func setCanonical(_ text: String, at index: Int) {
        guard vocabularyTerms.indices.contains(index) else { return }
        let term = vocabularyTerms[index]
        vocabularyTerms[index] = VocabularyTerm(canonical: text, misheard: term.misheard)
    }

    /// 誤認識表記を差し替える。**保存はしない。**
    ///
    /// - Parameter text: 区切り文字で並べた表記（`MisheardListText`）。
    ///   **空白だけの項目と重複はここで落とす**——`VocabularyStore.normalize` は
    ///   `canonical` しか正規化しないので、誤認識表記の掃除はここが唯一の場所である。
    public func setMisheard(_ text: String, at index: Int) {
        guard vocabularyTerms.indices.contains(index) else { return }
        let term = vocabularyTerms[index]
        vocabularyTerms[index] = VocabularyTerm(
            canonical: term.canonical, misheard: MisheardListText.list(text))
    }

    /// 空の項目を足す。
    public func addTerm() {
        vocabularyTerms.append(VocabularyTerm(canonical: ""))
    }

    public func removeTerm(at index: Int) {
        guard vocabularyTerms.indices.contains(index) else { return }
        vocabularyTerms.remove(at: index)
    }

    // MARK: - 保存

    /// **保存しただけでは効かないものを、実際に効かせたか。**
    ///
    /// PTT / Undo のどちらも、`SettingsStore` へ書いただけでは監視器は古いキーを見ている
    /// （`HotkeyMonitor.currentBinding` / `currentUndoBinding` の注記）。
    /// フェーズ 1 の持ち越し項目 10 が名指ししたのはこの穴である。
    public struct ReboundHotkeys: Sendable, Equatable {
        public var pushToTalk = false
        public var undo = false
        public var isEmpty: Bool { !pushToTalk && !undo }
        public init() {}
    }

    /// 保存の顛末。**「保存した」だけでなく「何が起きたか」を持つ。**
    public enum SaveOutcome: Sendable, Equatable {
        /// 書けた。
        /// - Parameter transcriberReloaded: ロケール／認識種別を切り替え直したか。
        /// - Parameter hotkeysRebound: PTT / Undo のキーを監視器へ反映したか。
        /// - Parameter quarantined: この保存で `.corrupt` へ退避したファイル。
        case saved(
            transcriberReloaded: Bool, hotkeysRebound: ReboundHotkeys,
            quarantined: [StoreFileNotice.File])
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
                if rebound.pushToTalk { text += "PTT キーを反映しました。" }
                if rebound.undo { text += "Undo キーを反映しました。" }
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
    /// 6. **PTT / Undo のキーを監視器へ反映**（保存しただけでは効かない）。
    ///
    /// 4 以降で失敗した場合は「一部だけ反映された」と告げる。**黙らない。**
    ///
    /// - Note: **6 を 4 より後に置くのは 3 と逆である。** 認識器は「切り替えに失敗したら
    ///   ディスクを変えない」（画面と認識がずれるのを防ぐ）が、キーの反映は
    ///   **失敗しても次回の起動で必ず効く**（監視器は起動時に `settings.hotkey` を読む）。
    ///   先に置くと、書き込みに失敗したときだけ「今回だけ新しいキー・次回から古いキー」
    ///   という**どの起動とも一致しない状態**が残る。
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

        // 6. PTT / Undo のキー。**保存しただけでは監視器は古いキーを見ている。**
        //    フェーズ 1 では PTT キーを変えてもプロセスを再起動するまで効かなかった
        //    （持ち越し項目 10）。**ここが FR-11 の「変更できる」の実体である。**
        var rebound = ReboundHotkeys()
        if next.hotkey != stored.hotkey, let hotkey {
            do {
                // **タップを張り替える**（実測 約 40 ms）。録音中なら `.interrupted` が
                // 流れ、そこまでの発話は確定して挿入される（`HotkeyMonitor.rebind`）。
                try hotkey.rebindPushToTalk(to: next.hotkey)
                rebound.pushToTalk = true
            } catch {
                partialFailure = partialFailure ?? String(describing: error)
            }
        }
        if next.undoHotkey != stored.undoHotkey, let session {
            do {
                try await session.rebindUndoHotkey(to: next.undoHotkey)
                rebound.undo = true
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
                hotkeysRebound: rebound,
                quarantined: quarantined)
        }
    }

    /// 編集を捨ててディスクの内容へ戻す。
    public func discard() {
        // **捕獲中なら畳む。** 残すと、戻したはずの欄へ後から決着が入る。
        cancelCapture()
        draft = settings.settings
        vocabularyTerms = vocabulary.terms
        lastSave = nil
        captureMessage = nil
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

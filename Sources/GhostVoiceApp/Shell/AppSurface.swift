import GhostVoiceCore

/// **`NSApplication.run()` が始まった後にしか作れない値。**
///
/// この型の初期化子は `GhostVoiceApp` の内部にしか無い。外から作れないので、
/// **これを引数に取る関数は「run() の後」でしか呼ばれない**ことが型で保証される。
///
/// ## なぜこんな鍵を置くのか（実測に基づく制約）
///
/// `NSApplication.run()` を呼ぶ**前**に window を `orderFrontRegardless()` すると、
/// AppKit が `finishLaunching` の時点でアプリを**活性化する**。
/// `setActivationPolicy(.accessory)` を先に呼んでいても、`.nonactivatingPanel` でも、
/// `canBecomeKey == false` でも防げない（フェーズ 2 事前調査 `core-api-and-hud.md` B-3 の実測）。
///
/// 活性化すると `AccessibilityInserter.frontmostProcessIdentifier()` が拾う最前面 pid が
/// **Ghost Voice 自身**になり、**挿入先が壊れる。**
///
/// したがって「起動時に非表示の window を用意しておく」実装は禁止である。
/// **禁止を注意書きではなく構造で守るために、window を持つ型は
/// `AppSurfaceFactory` の中でしか生まれない**（工場はこの鍵を受け取ってから呼ばれる）。
public struct RunLoopEntry: Sendable {
    /// 外から作れない。**`internal` のままにしておくこと。**
    init() {}
}

/// アプリが持つ画面（HUD・設定・履歴…）の口。**別トラックがここへ実装を足す。**
///
/// ## 足しかた
///
/// ```swift
/// // 別トラックの HUD 側
/// final class NotchHUDSurface: AppSurface {
///     init(_ entry: RunLoopEntry, services: AppServices) {
///         // ここは run() が回り始めた後。**window の生成と表示はここから行う。**
///     }
///     func teardown() { /* window を閉じる */ }
/// }
///
/// // 器の側（`GhostVoiceAppMain.main` の呼び出し）
/// GhostVoiceAppMain.main(surfaces: [ { entry, services in NotchHUDSurface(entry, services: services) } ])
/// ```
///
/// **`init` の外（プロパティ初期値や `static let`）で window を作らないこと。**
/// それをすると鍵の意味が無くなる。
@MainActor
public protocol AppSurface: AnyObject {
    /// 終了時に呼ばれる。**発話の処理はここでは待たない**（それは `AppTermination` の仕事）。
    func teardown()
}

/// 画面が Core へ触るための一式。
///
/// **`session` は `nil` になりうる**（`--shell-only` で起動したとき、および
/// キー監視を開始できずセッションを組み立てなかったとき）。
/// 画面は `nil` を「まだ喋れない」状態として描くこと。
public struct AppServices: Sendable {
    public let session: DictationSession?
    public let settings: SettingsStore
    public let history: HistoryStore
    public let vocabulary: VocabularyStore
    /// 起動時に照会した権限（**ダイアログは出していない**）。
    public let permissions: AppPermissionStatus
    /// キー監視を開始できなかった理由。`nil` なら開始できている。
    public let hotkeyFailure: HotkeyError?

    public init(
        session: DictationSession?,
        settings: SettingsStore,
        history: HistoryStore,
        vocabulary: VocabularyStore,
        permissions: AppPermissionStatus,
        hotkeyFailure: HotkeyError?
    ) {
        self.session = session
        self.settings = settings
        self.history = history
        self.vocabulary = vocabulary
        self.permissions = permissions
        self.hotkeyFailure = hotkeyFailure
    }
}

/// 画面を作る工場。**`RunLoopEntry` を受け取って初めて呼べる。**
public typealias AppSurfaceFactory = @MainActor (RunLoopEntry, AppServices) -> any AppSurface

import GhostVoiceCore

/// **設定画面がキー監視器へ触る面。これだけである。**
///
/// `SettingsSessionControlling` と同じ形——画面が `CGEventTapHotkeyMonitor` を直に
/// 握ると、検査のたびに本物のタップを開こうとすることになる。**触る 3 口だけを切り出す。**
///
/// ## なぜ `DictationSession` 経由にしないか
///
/// `DictationSession` は Undo のバインドしか差し替え口を持っていない
/// （`rebindUndoHotkey`）。**PTT のバインドと捕獲モードは監視器の口である。**
/// セッションを経由させるには Core の `Session/` を広げることになるが、
/// **これは監視器の関心であってセッションの関心ではない**——セッションは
/// 「どのキーか」を知らないまま `HotkeyEvent` だけを受け取る設計である。
///
/// - Important: **PTT のバインドは、保存しただけでは効かない。**
///   `SettingsStore` に書いても監視器は自分が持っているバインドを見ている
///   （`HotkeyMonitor.currentBinding` の注記）。フェーズ 1 で「設定画面で PTT キーを
///   変えてもプロセスを再起動するまで効かなかった」のはこれである（持ち越し項目 10）。
public protocol HotkeyControlling: Sendable {

    /// いま監視している PTT のバインド。**`Settings.hotkey` の写しではない。**
    /// 画面はこれと `draft.hotkey` が食い違っていないかを確かめられる。
    var currentPushToTalkBinding: HotkeyBinding { get }

    /// 打鍵の捕獲を始める（FR-11）。
    ///
    /// - Important: **捕獲モードの間、PTT も Undo も ESC の中断も発火しない**
    ///   （`HotkeyMonitor.beginHotkeyCapture`）。キーを設定しようとして録音が
    ///   始まると設定画面は使えない。
    /// - Important: **`onEvent` はタップのコールバックのスレッドから呼ばれる。**
    ///   受け手が MainActor へ持ち上げること。
    func beginCapture(_ onEvent: @escaping @Sendable (HotkeyCaptureOutcome) -> Void)

    /// 捕獲モードを閉じる。**二度呼んでも安全。**
    ///
    /// 決着すると監視器の側が自動的に閉じるが、**窓を閉じた・利用者が取りやめた
    /// ときは画面から閉じること**（閉じるまで PTT が効かない）。
    func endCapture()

    /// PTT のバインドを監視器へ反映する（FR-11）。
    ///
    /// - Important: **録音していないときに呼ぶこと。** 録音中に呼ぶと
    ///   `.interrupted` が流れる（そこまでの発話は確定して挿入される）。
    /// - Important: **タップを張り替えるので実測で約 40 ms 掛かる。**
    ///   設定を変えた瞬間だけに限ること。
    func rebindPushToTalk(to binding: HotkeyBinding) throws
}

/// 本物の `HotkeyMonitor` を上の面へはめる薄い覆い。
///
/// **`extension HotkeyMonitor: HotkeyControlling` にしない。**
/// Core の型へ App 側の protocol を後付けすると、Core を触れないトラックが
/// Core の公開面を実質的に広げることになる（`DictationSessionSettingsControl` と同じ判断）。
public struct MonitorHotkeyControl: HotkeyControlling {
    private let monitor: any HotkeyMonitor

    public init(_ monitor: any HotkeyMonitor) {
        self.monitor = monitor
    }

    public var currentPushToTalkBinding: HotkeyBinding { monitor.currentBinding }

    public func beginCapture(_ onEvent: @escaping @Sendable (HotkeyCaptureOutcome) -> Void) {
        monitor.beginHotkeyCapture(onEvent)
    }

    public func endCapture() {
        monitor.endHotkeyCapture()
    }

    public func rebindPushToTalk(to binding: HotkeyBinding) throws {
        try monitor.rebind(to: binding)
    }
}

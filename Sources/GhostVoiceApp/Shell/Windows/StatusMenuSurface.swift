import AppKit
import GhostVoiceCore
import SwiftUI

/// **設定画面（FR-11）と履歴画面（FR-9）を、利用者が開ける場所へ繋ぐ。**
///
/// トラック D は View と ViewModel だけを作り、「どの窓・どのメニューから開くか」を
/// 各 ViewModel の doc コメントに書き残した。**ここがその指示どおりの配線である。**
///
/// | 指示（`SettingsViewModel` / `HistoryViewModel` の doc） | ここでの実装 |
/// |---|---|
/// | 開く口は `NSStatusItem` のメニュー | `statusItem.menu`（設定… / 履歴… / 終了） |
/// | 窓は `NSWindow` + `NSHostingView` | `AppWindow`（`NSWindow` を作る唯一の場所） |
/// | `RunLoopEntry` を受け取ってから作る | 鍵を持ち回り、**利用者がメニューを選んだときに初めて作る** |
/// | 開くときは `NSApp.activate()` してよい | `AppWindow.present()` |
/// | 閉じたら `NSApp.hide(nil)` | `AppWindow.windowWillClose` / `dismissAndReturnFocus` |
/// | 再挿入は窓を閉じて前面が戻ってから | `HistoryView(dismissAndReturnFocus:)` へ閉じる口を渡す |
/// | 購読（`start()`）は 1 回だけ | `HistoryView.task` が呼ぶ（`start()` は 2 回呼んでも 2 本にならない） |
/// | ストアと同じ寿命 | ViewModel は `init` で作り、この画面が握り続ける |
///
/// ## 窓を起動時に作らない
///
/// `AppSurface` の doc が「**起動時に非表示の window を用意しておく実装は禁止**」と
/// 定めている（`run()` の前でなくても、窓があるだけで活性化の経路が増える）。
/// ViewModel は `init` で作る（ストアと寿命を揃える必要がある）が、
/// **窓は利用者がメニューを選んだ瞬間に作る。**
///
/// ## `NSStatusItem` は窓ではない
///
/// メニューバーの項目を作ってもアプリは活性化しない（実測: 受け入れ条件 5 の計測で、
/// 起動から終了まで最前面 pid は 1 度も Ghost Voice にならなかった）。
/// **`LSUIElement = true` なので Dock にもアプリメニューにも居らず、
/// ここが唯一の入口である**——落とすと、設定画面へ辿り着く手段が無くなる。
@MainActor
public final class StatusMenuSurface: NSObject, AppSurface {

    /// **`NSApplication.run()` が始まった後であることの証。**
    /// 窓を後から作るために持ち回る（鍵の意味を壊さない——外からは作れないままである）。
    private let entry: RunLoopEntry
    private let services: AppServices
    private let statusItem: NSStatusItem

    private let settingsModel: SettingsViewModel
    private let historyModel: HistoryViewModel

    private var settingsWindow: AppWindow?
    private var historyWindow: AppWindow?

    /// - Parameter entry: `NSApplication.run()` が始まった後であることの証。
    ///   **この引数がある限り、起動時に窓を用意しておく実装は書けない。**
    public init(_ entry: RunLoopEntry, services: AppServices) {
        self.entry = entry
        self.services = services

        // **ストアと同じ寿命の場所に置く**（`SettingsViewModel` の doc）。
        // 作り直すと `loadFailure` の事実が消える（`StoreFileNotice.collect` の注記）。
        settingsModel = SettingsViewModel(
            settings: services.settings,
            vocabulary: services.vocabulary,
            history: services.history,
            session: services.session.map(DictationSessionSettingsControl.init),
            hotkey: services.hotkey,
            hotkeyFailure: services.hotkeyFailure,
            directory: services.storageRoot)
        historyModel = HistoryViewModel(
            store: services.history,
            output: SystemHistoryTextOutput.system(),
            fileNotice: StoreFileNotice.collect(
                settings: services.settings, vocabulary: services.vocabulary,
                history: services.history, directory: services.storageRoot
            ).first { $0.file == .history })

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
    }

    public func teardown() {
        // **捕獲モードを必ず畳む。** 残すと、終了処理の途中で打鍵を食い続ける。
        settingsModel.cancelCapture()
        historyModel.stop()
        settingsWindow?.close()
        historyWindow?.close()
        settingsWindow = nil
        historyWindow = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - メニュー

    private func configureStatusItem() {
        // **テンプレート画像にする。** メニューバーの明暗に追従しないと、
        // ダークモードで見えなくなる。
        let image = NSImage(
            systemSymbolName: "mic.fill", accessibilityDescription: "Ghost Voice")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Ghost Voice"

        let menu = NSMenu()
        menu.addItem(makeItem("設定…", #selector(openSettings), key: ","))
        menu.addItem(makeItem("履歴…", #selector(openHistory), key: "y"))
        if services.hotkeyFailure != nil {
            // **黙って「効かないアプリ」にしない。** 押しても何も起きない理由を、
            // 唯一の常設の入口に出す（詳しい直し方は設定画面が持つ）。
            menu.addItem(.separator())
            let warning = NSMenuItem(
                title: "キー入力を監視できていません（設定を開く）",
                action: #selector(openSettings), keyEquivalent: "")
            warning.target = self
            menu.addItem(warning)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Ghost Voice を終了", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func makeItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - 設定画面（FR-11）

    @objc private func openSettings() {
        let window =
            settingsWindow
            ?? AppWindow(
                entry, title: "Ghost Voice の設定", size: CGSize(width: 560, height: 620),
                content: SettingsView(model: settingsModel),
                onClose: { [weak self] in
                    // **捕獲モードを閉じる。** 閉じないと、窓が無いのに打鍵を待ち続け、
                    // **PTT が効かなくなる**（`HotkeyMonitor.beginHotkeyCapture` の注記）。
                    self?.settingsModel.cancelCapture()
                })
        settingsWindow = window
        window.present()
    }

    // MARK: - 履歴画面（FR-9）

    @objc private func openHistory() {
        let window =
            historyWindow
            ?? AppWindow(
                entry, title: "Ghost Voice の履歴", size: CGSize(width: 640, height: 480),
                content: HistoryView(
                    model: historyModel,
                    // **これが「閉じる口」である。** 渡さないと `HistoryView` は
                    // 再挿入のボタンを出さない（順序の間違いを構造で防ぐ設計。§14.4）。
                    dismissAndReturnFocus: { [weak self] in
                        await self?.dismissHistoryAndReturnFocus()
                    }),
                onClose: {})
        historyWindow = window
        window.present()
    }

    /// **再挿入の直前に呼ばれる。** 窓を閉じ、前面が戻るまで待つ。
    ///
    /// 待たずに挿入すると、挿入先が Ghost Voice 自身になる
    /// （`AccessibilityInserter.frontmostProcessIdentifier()`）。
    /// **待ち方そのものは未実測項目である**（正本 §13 の V-43 / V-44）。
    private func dismissHistoryAndReturnFocus() async {
        await historyWindow?.dismissAndReturnFocus()
    }

    @objc private func quit() {
        // **`exit` しない。** 終了は器の段取り（`applicationShouldTerminate` →
        // `GhostVoiceCore.Shutdown`）を通す。通さないと、⌘V の送出後・
        // クリップボードの復元前に落ちて発話が失われる。
        NSApp.terminate(nil)
    }
}

// MARK: - 目視確認のための素振り

/// `--window-check` が呼ぶ口。**製品の経路ではない。**
///
/// 受け入れ条件「窓を出した状態でフォーカスを奪わないことを実測して示す」を、
/// **人が居なくても再現できる形**にするために置いてある（`--hud-check` と同じ性格）。
@MainActor
public protocol WindowRehearsing: AnyObject {
    /// 設定 → 履歴 の順に開いて閉じる。**マイクもキー監視も認識も使わない。**
    func startWindowRehearsal(seconds: Double, onFinish: @escaping @MainActor () -> Void)
}

extension StatusMenuSurface: WindowRehearsing {

    public func startWindowRehearsal(seconds: Double, onFinish: @escaping @MainActor () -> Void) {
        Task { @MainActor [weak self] in
            let step = Duration.seconds(max(1, seconds / 4))
            AppDiagnostics.note("[--window-check] 窓を出さずに待ちます（この間の最前面を測ってください）。")
            try? await Task.sleep(for: step)

            AppDiagnostics.note("[--window-check] 設定画面を開きます。")
            self?.openSettings()
            try? await Task.sleep(for: step)
            AppDiagnostics.note("[--window-check] 設定画面を閉じて前面を返します。")
            await self?.settingsWindow?.dismissAndReturnFocus()

            AppDiagnostics.note("[--window-check] 履歴画面を開きます。")
            self?.openHistory()
            try? await Task.sleep(for: step)
            AppDiagnostics.note("[--window-check] 履歴画面を閉じて前面を返します（再挿入の直前と同じ経路）。")
            await self?.dismissHistoryAndReturnFocus()

            try? await Task.sleep(for: step)
            AppDiagnostics.note("[--window-check] 終了します。")
            onFinish()
        }
    }
}

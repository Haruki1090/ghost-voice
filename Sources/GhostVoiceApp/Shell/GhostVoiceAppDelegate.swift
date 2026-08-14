import AppKit
import Foundation
import GhostVoiceCore

/// 常駐アプリの器。**window は 1 枚も持たない。**
///
/// ## 起動の順序（この順序に意味がある）
///
/// | いつ | 何をするか | なぜそこか |
/// |---|---|---|
/// | `applicationWillFinishLaunching` | `setActivationPolicy(.accessory)` | Dock に出さない。`Info.plist` の `LSUIElement` で既に `.accessory` になるが、**`.app` の外から実行されたときの保険**（バンドル外では `.prohibited` になり UI が成立しない） |
/// | `applicationDidFinishLaunching` | ストアを読む・権限を照会する・セッションを起こす | **window は作らない。** ここはまだ `run()` の `finishLaunching` の途中である |
/// | メインキューの次の回 | `LaunchSequence.enterRunLoop`（＝画面を作る） | **`NSApplication.run()` のイベントループが回り始めた後**。ここより前に window を出すとアプリが活性化し、挿入先が壊れる（`core-api-and-hud.md` B-3 の実測） |
@MainActor
public final class GhostVoiceAppDelegate: NSObject, NSApplicationDelegate {

    private let options: AppLaunchOptions
    private let launchSequence: LaunchSequence

    /// **ストアを生かしておくのは器の責任である。**
    /// `--shell-only` ではセッションが無く、誰も参照しないと解放されてしまう。
    private var services: AppServices?
    private var runtime: AppSessionRuntime?
    private var isTerminating = false
    /// シグナル源は**保持しないと即座に解放されて効かない。**
    private var signalSources: [any DispatchSourceSignal] = []

    public init(options: AppLaunchOptions, surfaces: [AppSurfaceFactory]) {
        self.options = options
        self.launchSequence = LaunchSequence(factories: surfaces)
        super.init()
    }

    // MARK: - 起動

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        for argument in options.unrecognized {
            AppDiagnostics.note("[誤り] 知らない引数です: \(argument)")
        }

        let settings = SettingsStore()
        let vocabulary = VocabularyStore()
        let history = HistoryStore(limit: settings.settings.historyLimit)

        // **読めなかったファイルは、起動時に必ず言う。**
        // 黙ると「書き換えたのに効かない」だけが症状として残る。
        let unreadable = [
            settings.loadFailure.map { _ in "settings.json" },
            vocabulary.loadFailure.map { _ in "vocabulary.json" },
            history.loadFailure.map { _ in "history.json" },
        ].compactMap { $0 }
        if !unreadable.isEmpty {
            AppDiagnostics.note(
                "[警告] \(unreadable.joined(separator: " / ")) を読めませんでした。既定値で動作しています。")
        }

        // **照会だけ。ここではダイアログを出さない。**
        let permissions = PermissionInquiry.current()
        AppDiagnostics.note(AppPermissionGuidance.report(permissions))
        if options.requestsPermissions {
            // 一覧に載せるために要求を出す。**載らないと利用者はトグルを見つけられない。**
            AppPermissions.requestMissing()
        }

        var hotkeyFailure: HotkeyError?
        if options.startsSession {
            do {
                runtime = try AppSessionRuntime.start(
                    settings: settings, history: history, vocabulary: vocabulary)
                AppDiagnostics.note("Ghost Voice を起動しました。右 Option を押している間だけ録音します。")
            } catch let error as HotkeyError {
                hotkeyFailure = error
                AppDiagnostics.note(AppPermissionGuidance.message(for: error))
            } catch {
                AppDiagnostics.note("キー監視を開始できませんでした: \(error)")
            }
        } else {
            AppDiagnostics.note("[--shell-only] セッションを作らずに器だけを起動しました。")
        }

        installSignalTrap()

        let services = AppServices(
            session: runtime?.session,
            settings: settings,
            history: history,
            vocabulary: vocabulary,
            permissions: permissions,
            hotkeyFailure: hotkeyFailure)
        self.services = services

        // **ここが唯一の「画面を作ってよい」合図である。**
        // `applicationDidFinishLaunching` の中で作らないのは、そこがまだ
        // `NSApplication.run()` の `finishLaunching` の途中だからである。
        // メインキューへ積んだこのブロックは、イベントループが回り始めてから走る。
        DispatchQueue.main.async { [launchSequence, options] in
            launchSequence.enterRunLoop(services: services)
            guard let seconds = options.hudRehearsalSeconds else { return }
            guard
                let rehearsing = launchSequence.surfaces.compactMap({ $0 as? any HUDRehearsing })
                    .first
            else {
                AppDiagnostics.note("[--hud-check] 素振りできる画面がありません。")
                NSApp.terminate(nil)
                return
            }
            AppDiagnostics.note("[--hud-check] HUD の素振りを \(seconds) 秒行います。")
            rehearsing.startRehearsal(seconds: seconds) {
                // **`exit` しない。** 終了は器の段取り（`applicationShouldTerminate`）を通す。
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - 終了

    /// **素通しさせない。** ⌘V 送出後・クリップボード復元前に落ちると発話が失われる。
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else {
            launchSequence.tearDown()
            return .terminateNow
        }
        guard !isTerminating else {
            // 2 度目の要求。**強制終了しない**（1 本目が畳んでいる最中である）。
            AppDiagnostics.note("[終了] 終了処理中です。どうしても止まらない場合は kill -9 してください。")
            return .terminateLater
        }
        isTerminating = true
        Task {
            await runtime.shutdown()
            launchSequence.tearDown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Ctrl-C（SIGINT）と `kill`（SIGTERM）を捕まえる。
    ///
    /// **既定の動作を殺してから**シグナル源を張る。既定のままだと、
    /// ハンドラが走る前にプロセスが消える（＝挿入の途中で落ちる）。
    private func installSignalTrap() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                // `terminate` は `applicationShouldTerminate` を通る＝終了処理を必ず経由する。
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

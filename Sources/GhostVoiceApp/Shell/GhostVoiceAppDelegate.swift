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
    /// 終了のときに段取りを通す相手。**本物のセッション、または素振り**（`--shutdown-check`）。
    ///
    /// **本物を名指ししない。** 名指しすると `.terminateLater` を返す経路が
    /// 実発話でしか通らなくなり、実バンドルで一度も測れない（それがこの欠陥の温床だった）。
    private var shutdownTarget: (any AppShutdownPerforming)?
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
                let started = try AppSessionRuntime.start(
                    settings: settings, history: history, vocabulary: vocabulary)
                runtime = started
                shutdownTarget = started
                AppDiagnostics.note("Ghost Voice を起動しました。右 Option を押している間だけ録音します。")
            } catch let error as HotkeyError {
                hotkeyFailure = error
                AppDiagnostics.note(AppPermissionGuidance.message(for: error))
            } catch {
                AppDiagnostics.note("キー監視を開始できませんでした: \(error)")
            }
        } else if let seconds = options.shutdownRehearsalSeconds {
            // **セッションは作らない。** 終了の段取りだけを本物と同じ形で通す。
            shutdownTarget = ShutdownRehearsal(busyFor: .milliseconds(Int(seconds * 1000)))
            AppDiagnostics.note(
                "[--shutdown-check] 終了の素振りです。\(JapaneseDuration.text(.seconds(seconds))) のあいだ「発話を抱えている」ことにします。"
                    + "終了要求（SIGTERM / ⌘Q / osascript の quit）を送ってください。")
        } else {
            AppDiagnostics.note("[--shell-only] セッションを作らずに器だけを起動しました。")
        }

        installSignalTrap()

        let services = AppServices(
            session: runtime?.session,
            // **履歴画面の再挿入へ、セッションと同じ組を渡す**（再レビュー B-2）。
            insertion: runtime?.insertion,
            settings: settings,
            history: history,
            vocabulary: vocabulary,
            permissions: permissions,
            hotkeyFailure: hotkeyFailure,
            // **セッションが無ければ監視器も無い。** 設定画面は打鍵を捕まえられない旨を
            // 利用者へ言う（黙って何も起きない形にしない）。
            hotkey: runtime?.hotkeyControl)
        self.services = services

        // **ここが唯一の「画面を作ってよい」合図である。**
        // `applicationDidFinishLaunching` の中で作らないのは、そこがまだ
        // `NSApplication.run()` の `finishLaunching` の途中だからである。
        // メインキューへ積んだこのブロックは、イベントループが回り始めてから走る。
        DispatchQueue.main.async { [launchSequence, options] in
            launchSequence.enterRunLoop(services: services)

            // **終了待ちの案内を出せる画面をここで繋ぐ。**
            // 繋がなければ文言はログにしか出ず、**正しく待っているのに壊れて見える**
            // （2026-08-15 の実機。利用者は案内を一度も見ないまま猶予を使い切った）。
            AppShutdownAnnouncer.use(
                launchSequence.surfaces.compactMap { $0 as? any ShutdownAnnouncingSurface }.first)

            if let seconds = options.hudRehearsalSeconds {
                guard
                    let rehearsing = launchSequence.surfaces
                        .compactMap({ $0 as? any HUDRehearsing }).first
                else {
                    AppDiagnostics.note("[--hud-check] 素振りできる画面がありません。")
                    NSApp.terminate(nil)
                    return
                }
                AppDiagnostics.note("[--hud-check] HUD の素振りを \(JapaneseDuration.text(.seconds(seconds))) 行います。")
                rehearsing.startRehearsal(seconds: seconds) {
                    // **`exit` しない。** 終了は器の段取り（`applicationShouldTerminate`）を通す。
                    NSApp.terminate(nil)
                }
                return
            }

            if let seconds = options.windowRehearsalSeconds {
                guard
                    let rehearsing = launchSequence.surfaces
                        .compactMap({ $0 as? any WindowRehearsing }).first
                else {
                    AppDiagnostics.note("[--window-check] 素振りできる画面がありません。")
                    NSApp.terminate(nil)
                    return
                }
                AppDiagnostics.note("[--window-check] 窓の素振りを \(JapaneseDuration.text(.seconds(seconds))) 行います。")
                rehearsing.startWindowRehearsal(seconds: seconds) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - 終了

    /// **素通しさせない。** ⌘V 送出後・クリップボード復元前に落ちると発話が失われる。
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdownTarget else {
            launchSequence.tearDown()
            return .terminateNow
        }
        guard !isTerminating else {
            // 2 度目の要求。**強制終了しない**（1 本目が畳んでいる最中である）。
            AppDiagnostics.note("[終了] 終了処理中です。どうしても止まらない場合は kill -9 してください。")
            return .terminateLater
        }
        isTerminating = true
        // **この `Task` はメインキューへ積まれる。**
        // したがって、ここへ来るまでの経路がメインキューのブロックであってはならない
        // （排出中のメインキューは入れ子のランループでは進まず、`.terminateLater` の
        // 返事が永久に来ない）。受け口は `MainRunLoopHop` を通ること。
        Task {
            await shutdownTarget.shutdown()
            launchSequence.tearDown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Ctrl-C（SIGINT）と `kill`（SIGTERM）を捕まえる。
    ///
    /// **既定の動作を殺してから**シグナル源を張る。既定のままだと、
    /// ハンドラが走る前にプロセスが消える（＝挿入の途中で落ちる）。
    ///
    /// ## 受け口をメインキューに置いてはならない（実機で 17 分止まった）
    ///
    /// 以前はここが `queue: .main` で、ハンドラから直に `NSApp.terminate(nil)` を
    /// 呼んでいた。すると**メインキューのブロックの中で** `.terminateLater` の
    /// 入れ子のランループへ入ることになり、**返事を出す `Task`（＝メインキュー）が
    /// 二度と走らない。** `SIGTERM` も `pkill` も効かず、`kill -9` しか残らなかった。
    /// 機序と実測は `MainRunLoopHop` の注記にある。
    ///
    /// 対策は 2 つ重ねてある。
    ///
    /// 1. **受け口を専用のキューに置く**（CLI と同じ形）。メインが何かで塞がっていても
    ///    シグナル自体は必ず拾える
    /// 2. **メインへは `MainRunLoopHop` で渡す。** ランループのブロックはメインキューの
    ///    排出とは別経路なので、渡した先で入れ子のランループへ入っても詰まらない
    private func installSignalTrap() {
        // **`.main` を使わないこと。** 上の注記の 1〜2 が理由である。
        let queue = DispatchQueue(label: "ghost-voice.app.signals")
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            // **ここにクロージャを書いてはならない**（`requestTermination` の注記）。
            source.setEventHandler(handler: Self.requestTermination)
            source.resume()
            signalSources.append(source)
        }
    }

    /// シグナルを終了要求へ変える。**`nonisolated` でなければならない。**
    ///
    /// `@MainActor` の文脈で `source.setEventHandler { … }` とクロージャを直接書くと、
    /// **そのクロージャは `@MainActor` を継ぎ、入口に隔離の実行時検査が入る。**
    /// キューがメイン以外なら `dispatch_assert_queue` が失敗して **`SIGTRAP` で即死する。**
    ///
    /// 即死は「終わらない」より悪い。**終了処理を 1 行も通らずにプロセスが消えるので、
    /// ⌘V 送出後・クリップボード復元前なら発話がそのまま失われる。**
    ///
    /// 実測（2026-08-15 / M3 / macOS 26.5.2。使い捨てプログラム `scratchpad/probe/probe3.swift`）:
    ///
    /// | ハンドラの書き方 | 背景キューでの結果 |
    /// |---|---|
    /// | `@MainActor` のメソッド内のクロージャ | **`SIGTRAP`（終了コード 133）** |
    /// | `nonisolated static func` を渡す | 正常に走る |
    ///
    /// **メインへ渡すのは `MainRunLoopHop` の仕事である**（この関数はメインに触れない）。
    /// `terminate` は `applicationShouldTerminate` を通る＝終了処理を必ず経由する。
    private nonisolated static func requestTermination() {
        MainRunLoopHop.perform { NSApp.terminate(nil) }
    }
}

import Foundation
import GhostVoiceCore

/// 常駐セッションの持ち主。**`run()` はプロセスに 1 本だけ**（`core-api-and-hud.md` A-4）。
///
/// ## `stateUpdates` をここでは読まない
///
/// `DictationSession.stateUpdates` は `AsyncStream` であり、**消費者は 1 つに限る**
/// （複数の `next()` を同時に待つと異常終了する）。**器はこれを読まない。**
/// 終了の待ち合わせも `isBusy` の照会だけで済ませてある（`GhostVoiceCore.Shutdown`）。
///
/// - Note: **HUD もこれを読まない。** HUD が使うのは分配器の側（`stateStream()`）で、
///   そちらは呼ぶたびに独立したストリームを返すので何人が読んでもよい。
///   したがって `.app` では `stateUpdates` の読み手が 1 人も居ない
///   （バッファは最新 32 件で頭打ちになるだけで、溜まり続けることは無い）。
@MainActor
public final class AppSessionRuntime {

    public let session: DictationSession
    private let monitor: CGEventTapHotkeyMonitor

    /// 設定画面がキー監視器へ触る面（打鍵の捕獲と PTT キーの反映。FR-11）。
    ///
    /// **監視器そのものを渡さない。** 画面が `stop()` を呼べる形にすると、
    /// 設定を触っただけでホットキーが二度と復活しなくなる
    /// （`AsyncStream` は終端を取り消せない）。
    public var hotkeyControl: any HotkeyControlling { MonitorHotkeyControl(monitor) }
    private var runTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var isShuttingDown = false

    private init(session: DictationSession, monitor: CGEventTapHotkeyMonitor) {
        self.session = session
        self.monitor = monitor
    }

    /// 本物の依存を繋いで組み立てる。
    ///
    /// **キー監視を先に開始する。** `AXIsProcessTrusted()` を門番にはしない——
    /// 権威ある答えは `CGEvent.tapCreate` の可否である（詳細設計書 §2.2）。
    /// 開始できなければ `HotkeyError` を投げる。**アプリは終了しない**
    /// （常駐 GUI なので、権限を付けてから起動し直してもらう案内を出して待つ）。
    ///
    /// - Note: **監視器は 1 つだけ作ること。** 2 つ作ると、`DictationSession` が読むものと
    ///   実際にタップを張っているものが別になり、押しても何も起きない。
    static func start(
        settings: SettingsStore, history: HistoryStore, vocabulary: VocabularyStore
    ) throws -> AppSessionRuntime {
        let monitor = CGEventTapHotkeyMonitor(binding: settings.settings.hotkey)
        try monitor.start()

        let session = DictationSession(
            settings: settings,
            hotkey: monitor,
            audio: EngineAudioCapture(),
            transcriber: SpeechAnalyzerTranscriber(onAssetInstallationStart: {
                // **初回起動でモデルが未導入だと、ここで数分待つ。**
                // 黙って待つと「押しても何も起きない」だけが見える。
                AppDiagnostics.note("[準備中] 音声認識モデルを導入しています。完了するまで押しても反応しません…")
            }),
            refiner: FoundationModelRefiner(),
            inserter: CompositeInserter.system(),
            history: history,
            vocabulary: vocabulary)

        let runtime = AppSessionRuntime(session: session, monitor: monitor)
        runtime.runTask = Task { await session.run() }
        // タップは後から OS に無効化されうる。**黙って効かなくなる唯一の経路**なので見張る。
        // この `Task` は `@MainActor` の文脈で作るので MainActor を継いでいる。
        // したがって `runtime` の中身へは `await` 無しで触れる。
        runtime.watchdog = Task { [weak runtime] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let runtime, !runtime.isShuttingDown else { return }
                if !runtime.monitor.isActive {
                    AppDiagnostics.note(
                        "[警告] キーイベントの監視が停止しました（OS がタップを無効化しました）。"
                            + "以後ホットキーは反応しません。Ghost Voice を起動し直してください。")
                    return
                }
            }
        }
        return runtime
    }

    /// 終了の段取り。**段取りは Core に 1 つだけある**（`GhostVoiceCore.Shutdown`）。
    ///
    /// ここが渡すのは本物の依存と出力先だけである。順序（待つ → 止める → 見届ける）も
    /// 文言も CLI と共有する——**2 箇所にあると必ずずれ、両方とも自分のテストでは緑になる。**
    ///
    /// - Note: **門（`ShutdownGate`）は渡さない。** 門は `stateUpdates` を消費している
    ///   経路だけが持てる。ここは `isBusy` の照会だけで待つ。
    ///
    ///   **`.app` では `stateUpdates` を誰も読んでいない。** HUD が使うのは分配器の側
    ///   （`stateStream()`。呼ぶたびに独立したストリームを返す）である——
    ///   **「その 1 本は HUD が使う」という以前の説明は、分配器ができる前のものであり誤りになった。**
    ///   門を持てる経路が空いていることになるが、**ここでは持たない**：終了の判定に
    ///   分配器を使ってはならない（読み手が遅れると古いものから捨てるので、
    ///   `.idle` を取りこぼしうる。`SessionBroadcast` の注記）。
    public func shutdown(grace: Duration = Shutdown.defaultGrace) async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        watchdog?.cancel()

        // `@MainActor` の外へ渡すものを先に取り出す（`Task` と actor はそのまま渡せる）。
        let runTask = self.runTask
        await Shutdown.perform(
            grace: grace,
            stopHotkey: { [monitor] in monitor.stop() },
            awaitRun: { await runTask?.value },
            isBusy: { [session] in await session.isBusy },
            announce: { AppDiagnostics.note($0.text) })
    }
}

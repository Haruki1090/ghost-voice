import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import GhostVoiceCore
import Synchronization

/// CLI の組み立てと起動。
///
/// **ここに判断を書かない。** 文言・引数解釈・終了の待ち合わせは別ファイルの
/// 検査対象へ寄せてあり、ここは本物の依存を繋いで回すだけにしてある。
public enum GhostVoiceRuntime {

    /// シグナル源は**保持しないと即座に解放されて効かない。**
    private nonisolated(unsafe) static var signalSources: [any DispatchSourceSignal] = []

    public static func main() -> Never {
        let out = StandardOutputWriter()
        let err = StandardErrorWriter()

        switch CommandLineOptions.parse(Array(CommandLine.arguments.dropFirst())) {
        case .help:
            out.write(CommandLineOptions.usage + "\n")
            exit(0)
        case .usageError(let message):
            err.write("[誤り] \(message)\n\n" + CommandLineOptions.usage + "\n")
            exit(2)
        case .check:
            let status = currentPermissions()
            out.write(
                PermissionGuidance.report(
                    status, storageRoot: StorageRoot.default,
                    unreadable: unreadableStorageFiles()))
            // **見るのは「PTT が動くか」＝マイクと入力監視だけ。**
            // アクセシビリティが無くても 0 を返す（PTT は動くため）。V-3 はその状態では
            // 意味を持たないので、**そのことは報告の本文が言う**（`report` の該当行）。
            // スクリプトから判定できるように非 0 を返す。
            exit(status.microphoneAuthorized && status.listenEventAccess ? 0 : 1)
        case .requestPermissions:
            requestPermissions(out: out, err: err)
            exit(0)
        case .micCheck:
            exit(micCheck(out: out, err: err))
        case .run(let options):
            runSession(options, out: out, err: err)
        }
    }

    // MARK: - 権限

    static func currentPermissions() -> PermissionStatus {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        return PermissionStatus(
            microphoneStatus: name(of: microphone),
            microphoneAuthorized: microphone == .authorized,
            accessibilityTrusted: AXIsProcessTrusted(),
            listenEventAccess: CGPreflightListenEventAccess(),
            postEventAccess: CGPreflightPostEventAccess(),
            secureInputEnabled: IsSecureEventInputEnabled()
        )
    }

    private static func name(of status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "未確認"
        case .restricted: "制限"
        case .denied: "拒否"
        case .authorized: "許可"
        @unknown default: "不明(\(status.rawValue))"
        }
    }

    /// 許可を求める。**ダイアログが出る。人が押さないと先へ進まない。**
    ///
    /// マイクだけは「一覧に載っていないものは許可できない」ため、ここで求める意味がある。
    /// 入力監視とアクセシビリティは、求めた時点で一覧に載り、あとは人が入れる。
    private static func requestPermissions(out: any ConsoleWriting, err: any ConsoleWriting) {
        out.write("許可を求めます。ダイアログが出たら「許可」または「システム設定を開く」を選んでください。\n\n")

        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphone == .notDetermined {
            out.write("マイク: 許可を求めています…\n")
            // **待ちに上限を置く。** 応答が返らない環境で黙って止まらないようにする。
            let semaphore = DispatchSemaphore(value: 0)
            let granted = Mutex<Bool>(false)
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                granted.withLock { $0 = allowed }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 60) == .timedOut {
                err.write("マイク: 60 秒待っても応答がありませんでした。\n")
            } else {
                out.write("マイク: \(granted.withLock { $0 } ? "許可されました" : "拒否されました")\n")
            }
        } else {
            out.write("マイク: \(name(of: microphone))（求め直しは不要）\n")
        }

        if !CGPreflightListenEventAccess() {
            out.write("入力監視: 許可を求めています（一覧に載ります）…\n")
            _ = CGRequestListenEventAccess()
        }
        if !AXIsProcessTrusted() {
            out.write("アクセシビリティ: 許可を求めています（一覧に載ります）…\n")
            // `kAXTrustedCheckOptionPrompt` は `var` 宣言なので Swift 6 の並行性検査を
            // 通らない（計画書のコードはここで固まる）。値は `"AXTrustedCheckOptionPrompt"`。
            let options = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }

        out.write(
            """

            許可の対象は ghost-voice ではなく、**これを起動しているターミナルアプリ**です。
            許可した後はターミナルアプリを再起動し、`ghost-voice --check` で確認してください。

            """)
    }

    /// 読み込みに失敗したファイルの名前。
    ///
    /// **3 つのストアを実際に開いて確かめる。** `--check` は常駐と別プロセスなので、
    /// ここで開くこと自体が「いま読めるか」の検査になっている。
    /// - Parameter root: 既定は実際の置き場所。**検査からは一時ルートを渡す**
    ///   （利用者の実ファイルを壊さずに、結線ごと確かめられるようにするため）。
    static func unreadableStorageFiles(root: URL = StorageRoot.default) -> [String] {
        var names: [String] = []
        if SettingsStore(rootURL: root).loadFailure != nil { names.append("settings.json") }
        if VocabularyStore(rootURL: root).loadFailure != nil { names.append("vocabulary.json") }
        if HistoryStore(rootURL: root, limit: Settings.default.historyLimit).loadFailure != nil {
            names.append("history.json")
        }
        return names
    }

    // MARK: - マイクの実地確認

    /// マイクを 1 秒だけ開き、実際にバッファが届くかを見る。
    ///
    /// **`--check` の照会とは別の問いである。**
    /// 詳細設計書 §3.3 は「バンドルされていない実行ファイルからはマイクを使えない」と
    /// 書いていた。照会が `.authorized` を返す機体で本当に開けるのかは、
    /// **開いてみないと判らない。** ここはその 1 回を人の操作に紐づける。
    ///
    /// **音声はどこへも保存しない**（FR-12 / NFR-V2）。数えるのはバッファ数とフレーム数だけ。
    private static func micCheck(out: any ConsoleWriting, err: any ConsoleWriting) -> Int32 {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        out.write("マイクの許可: \(name(of: status))\n")
        out.write("バンドル: \(Bundle.main.bundleIdentifier ?? "無し（素の実行ファイル）")\n")

        let capture = EngineAudioCapture()
        do {
            // `prepare()` は権限を先に確かめてから入力ノードへ触る。
            // 未許可でも 510 秒ブロックせず即座に投げる（詳細設計書 §3.3）。
            try capture.prepare()
        } catch {
            err.write("マイクを開けませんでした: \(error)\n")
            return 1
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<(buffers: Int, frames: Int, rate: Double, channels: UInt32)>(
            (0, 0, 0, 0))
        Task {
            do {
                let stream = try capture.startTap(format: nil)
                let stopper = Task {
                    try? await Task.sleep(for: .seconds(1))
                    capture.stopTap()
                }
                for await buffer in stream {
                    result.withLock {
                        $0.buffers += 1
                        $0.frames += Int(buffer.frameLength)
                        $0.rate = buffer.format.sampleRate
                        $0.channels = buffer.format.channelCount
                    }
                }
                await stopper.value
            } catch {
                err.write("タップを装着できませんでした: \(error)\n")
            }
            semaphore.signal()
        }
        // 1 秒の収録に対して十分な上限。**戻らない実装を黙って待ち続けない。**
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            err.write("マイクの読み出しが 15 秒以内に終わりませんでした。\n")
            return 1
        }

        let (buffers, frames, rate, channels) = result.withLock { $0 }
        out.write(
            "1 秒で \(buffers) バッファ / \(frames) フレーム"
                + (rate > 0 ? "（\(Int(rate)) Hz / \(channels) ch）" : "") + "\n")
        out.write("変換に失敗して捨てたバッファ: \(capture.droppedBufferCount) 件\n")

        guard frames > 0 else {
            err.write("音声が 1 フレームも届きませんでした。マイクの許可を確認してください。\n")
            return 1
        }
        out.write("マイクは開けています。\n")
        return 0
    }

    // MARK: - 常駐実行

    private static func runSession(
        _ options: RunOptions, out: any ConsoleWriting, err: any ConsoleWriting
    ) -> Never {
        let settingsStore = SettingsStore()
        let settings = settingsStore.settings

        // **読めなかったファイルは、起動時に必ず言う。**
        // 黙ると「書き換えたのに効かない」だけが症状として残る（最終レビュー I-4）。
        //
        // **3 つとも見る。** `settings.json` だけを見ていた頃は、`vocabulary.json` が
        // 壊れていると**無言でユーザー辞書が空になり**（FR-6 が効かなくなる）、
        // 症状は「固有名詞が直らない」だけだった。
        let vocabulary = VocabularyStore()
        let history = HistoryStore(limit: settings.historyLimit)
        let unreadable =
            [
                settingsStore.loadFailure.map { _ in "settings.json" },
                vocabulary.loadFailure.map { _ in "vocabulary.json" },
                history.loadFailure.map { _ in "history.json" },
            ].compactMap { $0 }
        if !unreadable.isEmpty {
            err.write(
                """
                [警告] \(unreadable.joined(separator: " / ")) を読めませんでした。\
                **既定値で動作しています。**
                JSON の書式を確認してください。書き換えた内容は 1 つも効いていません。

                """)
        }

        // **監視器は 1 つだけ作る。** 2 つ作ると、`DictationSession` が読むのと
        // 実際にタップを張っているものが別になり、押しても何も起きない。
        let monitor = CGEventTapHotkeyMonitor(binding: settings.hotkey)
        do {
            // **`AXIsProcessTrusted()` を門番にしない**（`CGEventTapHotkeyMonitor` の権限の項）。
            // 権威ある答えは `tapCreate` の可否なので、まず試してから照会する。
            try monitor.start()
        } catch let error as HotkeyError {
            err.write(PermissionGuidance.message(for: error) + "\n")
            exit(1)
        } catch {
            err.write("キー監視を開始できませんでした: \(error)\n")
            exit(1)
        }

        let session = DictationSession(
            settings: settingsStore,
            hotkey: monitor,
            audio: EngineAudioCapture(),
            transcriber: SpeechAnalyzerTranscriber(onAssetInstallationStart: {
                // **初回起動でモデルが未導入だと、ここで数分待つ。**
                // 黙って待つと「押しても何も起きない」だけが見える（最終レビュー M-6）。
                err.write("[準備中] 音声認識モデルを導入しています。完了するまで押しても反応しません…\n")
            }),
            refiner: FoundationModelRefiner(),
            inserter: CompositeInserter.system(
                restoreDelay: options.pasteRestoreDelay ?? PasteboardInserter.defaultRestoreDelay),
            history: history,
            vocabulary: vocabulary
        )

        let gate = ShutdownGate()
        // **`stateUpdates` を読むのはこの 1 本だけ**（Task 10 申し送り【4】）。
        let narration = Task {
            await SessionNarration.consume(
                session.stateUpdates, metrics: { await session.latestMetrics },
                writer: err, gate: gate)
        }
        let run = Task { await session.run() }

        let isShuttingDown = Atomic<Bool>(false)

        // タップは後から OS に無効化されうる。**黙って効かなくなる唯一の経路**なので見張る。
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !isShuttingDown.load(ordering: .relaxed) else { return }
                if !monitor.isActive {
                    err.write(
                        """
                        [警告] キーイベントの監視が停止しました（OS がタップを無効化しました）。
                        以後ホットキーは反応しません。ghost-voice を起動し直してください。

                        """)
                    return
                }
            }
        }

        installSignalTrap {
            let exchanged = isShuttingDown.compareExchange(
                expected: false, desired: true, ordering: .relaxed
            ).exchanged
            guard exchanged else {
                err.write(
                    "\n[終了] 終了処理中です。どうしても止まらない場合は別の端末から "
                        + "kill -9 \(ProcessInfo.processInfo.processIdentifier) を実行してください。\n")
                return
            }
            Task {
                watchdog.cancel()
                // **ここが `exit()` の唯一の入口である**（Task 10 申し送り【1】）。
                // 挿入の途中で落とすと、⌘V の後・クリップボード復元の前で消えて
                // テキストがどこにも残らない。
                //
                // **`CFRunLoopRun()` の後にも `exit()` を置いてはならない。**
                // 下の while ループがその理由（`stopHotkey` は自分でランループの
                // ソースを外すので、そこが 2 つ目の出口になりかける）。
                await Shutdown.perform(
                    gate: gate,
                    stopHotkey: { monitor.stop() },
                    awaitRun: { await run.value },
                    // **`state` ではなく `isBusy`**（押下から最初の emit までの窓を含めるため）
                    isBusy: { await session.isBusy },
                    writer: err)
                await narration.value
                exit(0)
            }
        }

        out.write(
            """
            Ghost Voice を起動しました。
            右 Option を押している間だけ録音し、離すと整形して挿入します。
            ESC で中断します（録音中と、離した後の確定・整形中まで）。Ctrl-C で終了します。
            起動直後は準備（モデルの読み込み）に数秒かかることがあります。

            """)

        // `CGEventTap` は `CFRunLoopGetMain()` に載る（Task 9 申し送り）。
        // **メインのランループを回し続けないとキーイベントが届かない。**
        //
        // **`CFRunLoopRun()` が戻っても `exit()` してはならない。**
        //
        // 終了処理の 1 手目（`Shutdown.perform` の `stopHotkey`）は
        // `CGEventTapHotkeyMonitor.stop()` を呼び、**自分でメインのランループから
        // ソースを外す。** そこでランループが空になって戻るなら、その瞬間は
        // 挿入の途中でありうる。ここで落とすと、⌘V の送出後・クリップボードの復元前に
        // プロセスが消えて発話が失われる（申し送り【1】が名指しした失敗）。
        //
        // 実測（2026-08-14 / M3 / macOS 26.5.2。TCC 不要の使い捨てプログラム）:
        // **この機体では戻らない。** メインのランループには常に他のソース
        // （メインキューのポート）が載っており、`CFMachPort` 由来のソースを
        // 最後の 1 本として外しても `CFRunLoopRunInMode` は復帰しなかった。
        // ソースを 1 本も張らない対照実験でも `kCFRunLoopRunFinished` は返らず、
        // 2 秒後に `kCFRunLoopRunTimedOut` だった。**つまり到達しない。**
        // しかしこれは CoreFoundation の実装の性質であって契約ではないので、
        // 「戻らないから安全」に寄りかからず、戻った場合の分岐をここに書く。
        while !isShuttingDown.load(ordering: .relaxed) {
            CFRunLoopRun()
            // 戻った＝ソースが尽きた。終了要求が無いなら張り直す。
            // 空のまま即座に戻り続ける状態（＝タップが死んでいる）では 10 Hz で回るが、
            // その状態は watchdog が利用者へ知らせる。**黙って終わるよりはよい。**
            Thread.sleep(forTimeInterval: 0.1)
        }

        // 終了処理が走っている。**`exit()` はそちらが行う**（唯一の入口）。
        // 主スレッドはここで寝かせる。`dispatchMain()` は戻らない。
        dispatchMain()
    }

    /// Ctrl-C（SIGINT）と `kill`（SIGTERM）を捕まえる。
    ///
    /// **既定の動作を殺してから**シグナル源を張る。既定のままだと、
    /// ハンドラが走る前にプロセスが消える（＝挿入の途中で落ちる）。
    private static func installSignalTrap(_ handler: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "ghost-voice.signals")
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler(handler: handler)
            source.resume()
            signalSources.append(source)
        }
    }
}

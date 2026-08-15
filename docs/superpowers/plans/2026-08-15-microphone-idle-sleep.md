# マイクをアイドルで寝かせる 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 最後の発話から 30 秒でマイク（`AVAudioEngine`）を停止し、待機中のオレンジ点と `coreaudiod` の常時 +15 ポイントを消す。

**Architecture:** 機構（起こす・寝る）を `EngineAudioCapture` に、方針（いつ寝るか）を `DictationSession` に置く。「起こす」口は公開せず、`startTap` が寝ていれば自分で起こす——呼び出し側に起こし忘れを作らせないため。起動時は捨て起動（`start` → 即 `stop`）でコールドぶんを先に払う。

**Tech Stack:** Swift 6.3 / swift-testing / macOS 26 / `AVFAudio`（`AVAudioEngine`）

**Spec:** [docs/superpowers/specs/2026-08-15-microphone-idle-sleep-design.md](../specs/2026-08-15-microphone-idle-sleep-design.md)

## Global Constraints

- **swift-tools-version: 6.3**、`swiftLanguageModes: [.v6]`、`platforms: [.macOS(.v26)]`
- **外部依存パッケージはゼロ。** `Package.swift` の `dependencies` は空のまま
- **音声データをディスクへ書き出さない**（FR-12 / NFR-V2）
- コミットメッセージは `feat:` / `test:` / `docs:` / `chore:` の接頭辞を付ける
- **テストは手動レンダリング（`ManualRenderingRig`）で書く。** 実マイクを開くテストは
  `MicrophoneTestGate`（`GHOST_VOICE_MIC_TESTS=1` ＋ 権限）の内側にだけ置く
- **タップのブロックはロックを取らない**（優先度逆転を招く）。本計画で触る範囲は
  すべてブロックの外側だが、`installTap` の中身を動かすときはこの規律を守ること
- 実測値を書くときは**日付・機体・OS・試行回数を必ず添える**（例: 2026-08-15 / M3 / macOS 26.5.2 / n=20）

---

## ファイル構成

| ファイル | 責務 | 担当タスク |
|---|---|---|
| `Sources/GhostVoiceCore/Audio/AudioCapturing.swift` | 契約に `sleep()` / `isAwake` を足し、`prepare()` の意味を書き直す | 1 |
| `Sources/GhostVoiceCore/Audio/EngineAudioCapture.swift` | 捨て起動・起床・停止の機構 | 1, 2 |
| `Tests/GhostVoiceCoreTests/Support/SessionDoubles.swift` | 代役 `StubAudioCapture` の追随（`sleepCount` を数える） | 1, 3 |
| `Tests/GhostVoiceCoreTests/SessionSurfaceTests.swift` | 代役 `LevelEmittingCapture` の追随 | 1 |
| `Tests/GhostVoiceCoreTests/DictationSessionMeasurementTests.swift` | 代役 `ReplayAudioCapture` の追随 | 1 |
| `Tests/GhostVoiceAppTests/HUDWiringTests.swift` | 代役 `StubAudio` の追随（**別ターゲット**） | 1 |
| `Tests/GhostVoiceCoreTests/AudioCaptureTests.swift` | 機構の検査。既存 3 件の更新と実マイク計測 | 1, 2, 4 |
| `Sources/GhostVoiceCore/Session/DictationSession.swift` | 方針（30 秒タイマー） | 3 |
| `Tests/GhostVoiceCoreTests/DictationSessionTests.swift` | 方針の検査 | 3 |
| `docs/01-requirements.md` / `docs/02-architecture.md` / `docs/03-detailed-design.md` / `docs/04-handover-verification.md` | 正本の改訂 | 5 |

---

### Task 1: エンジンを寝かせられるようにする（機構と契約）

**Files:**
- Modify: `Sources/GhostVoiceCore/Audio/AudioCapturing.swift`
- Modify: `Sources/GhostVoiceCore/Audio/EngineAudioCapture.swift`
- Modify: `Tests/GhostVoiceCoreTests/Support/SessionDoubles.swift:184`（`StubAudioCapture`）
- Modify: `Tests/GhostVoiceCoreTests/SessionSurfaceTests.swift:243`（`LevelEmittingCapture`）
- Modify: `Tests/GhostVoiceCoreTests/DictationSessionMeasurementTests.swift:14`（`ReplayAudioCapture`）
- Modify: `Tests/GhostVoiceAppTests/HUDWiringTests.swift:41`（`StubAudio`）
- Test: `Tests/GhostVoiceCoreTests/AudioCaptureTests.swift`

**Interfaces:**
- Consumes: `ManualRenderingRig`, `makeCapture(on:authorization:)`, `MutableAuthorization`（すべて `Tests/GhostVoiceCoreTests/Support/ManualRenderingRig.swift` に既にある）
- Produces:
  - `AudioCapturing.sleep()` — 引数なし・返り値なし・`throws` しない
  - `AudioCapturing.isAwake: Bool { get }`
  - `EngineAudioCapture.prepare()` は**寝た状態で返る**（`isAwake == false`）
  - `EngineAudioCapture.startTap(format:)` は寝ていれば起こしてから張る

- [ ] **Step 1: 既存テスト 2 件が新しい契約と食い違うことを確認する**

`Tests/GhostVoiceCoreTests/AudioCaptureTests.swift` の以下 2 件は、
`prepare()` の直後に `isEngineRunning` が真であることを表明している。
**新しい契約ではここは偽になる。** Step 6 で書き換えるので、まず場所を押さえる。

```bash
grep -n "prepareIsIdempotent\|repeatedPrepareIgnoresLaterRevocation" -A 12 \
  Tests/GhostVoiceCoreTests/AudioCaptureTests.swift
```

期待: 2 件とも `#expect(capture.isEngineRunning)` を含んでいる。

- [ ] **Step 2: 失敗するテストを書く**

`Tests/GhostVoiceCoreTests/AudioCaptureTests.swift` の `AudioCaptureTapTests` の
末尾（`isTappingReflectsState` の後）に追加する。

```swift
    // MARK: - アイドルで寝る（設計書 2026-08-15）

    @Test("prepare は捨て起動を通した上で寝た状態で返る")
    func prepareLeavesEngineAsleep() throws {
        let rig = try ManualRenderingRig()
        let capture = makeCapture(on: rig)
        try capture.prepare()
        #expect(!capture.isAwake, "prepare がエンジンを起動したまま返っている（点が消えない）")
        #expect(!capture.isEngineRunning)
    }

    @Test("寝ていても startTap が自分で起こす")
    func startTapWakesFromSleep() throws {
        let rig = try ManualRenderingRig()
        let capture = makeCapture(on: rig)
        try capture.prepare()
        #expect(!capture.isAwake)

        _ = try capture.startTap(format: nil)
        #expect(capture.isAwake, "寝たまま張ろうとしている。音が一切届かない")
        #expect(capture.isTapping)
        capture.stopTap()
    }

    @Test("stopTap ではエンジンを止めない（連続発話のため）")
    func stopTapKeepsEngineAwake() throws {
        let rig = try ManualRenderingRig()
        let capture = makeCapture(on: rig)
        try capture.prepare()
        _ = try capture.startTap(format: nil)
        capture.stopTap()
        #expect(capture.isAwake, "発話のたびに寝ると、次の押下が毎回 63 ms を払う")
    }

    @Test("sleep でエンジンが止まる")
    func sleepStopsEngine() throws {
        let rig = try ManualRenderingRig()
        let capture = makeCapture(on: rig)
        try capture.prepare()
        _ = try capture.startTap(format: nil)
        capture.stopTap()

        capture.sleep()
        #expect(!capture.isAwake)
        #expect(!capture.isEngineRunning)
    }

    @Test("タップが張られている間の sleep は無視される")
    func sleepIsIgnoredWhileTapping() throws {
        let rig = try ManualRenderingRig()
        let capture = makeCapture(on: rig)
        try capture.prepare()
        _ = try capture.startTap(format: nil)

        capture.sleep()
        #expect(capture.isAwake, "録音中にエンジンを止めた。その発話が丸ごと消える")
        #expect(capture.isTapping)
        capture.stopTap()
    }

    @Test("sleep は冪等（二度呼んでも落ちない）")
    func sleepIsIdempotent() throws {
        let rig = try ManualRenderingRig()
        let capture = makeCapture(on: rig)
        try capture.prepare()
        capture.sleep()
        capture.sleep()
        #expect(!capture.isAwake)
    }

    @Test("寝て起きてを繰り返しても音が流れる")
    func sleepWakeCycling() async throws {
        let rig = try ManualRenderingRig()
        let capture = makeCapture(on: rig)
        try capture.prepare()

        for _ in 0..<3 {
            let stream = try capture.startTap(format: target)
            try rig.render(frames: 4_800)
            capture.stopTap()
            let summary = await summarize(stream)
            #expect(summary.frames > 0, "寝起きの後にバッファが 1 つも来ていない")
            capture.sleep()
            #expect(!capture.isAwake)
        }
    }

    @Test("prepare していなければ sleep は何もしない")
    func sleepBeforePrepareIsHarmless() throws {
        let rig = try ManualRenderingRig()
        let capture = makeCapture(on: rig)
        capture.sleep()
        #expect(!capture.isAwake)
    }
```

- [ ] **Step 3: テストを走らせて落ちることを確かめる**

Run: `swift test --filter "AudioCapture のタップ"`
Expected: **コンパイルエラー** — `value of type 'EngineAudioCapture' has no member 'isAwake'` および `'sleep'`

- [ ] **Step 4: 契約を書き換える**

`Sources/GhostVoiceCore/Audio/AudioCapturing.swift` の `AudioCapturing` プロトコルを
以下で置き換える（`prepare()` の doc が変わる点に注意）。

```swift
public protocol AudioCapturing: AnyObject, Sendable {
    /// 権限を確かめ、**捨て起動を 1 往復してから寝た状態で返る**。アプリ起動時に一度だけ呼ぶ。
    ///
    /// 捨て起動（`start` → 即 `stop`）を通すのは、**プロセス初回のコールド費用を
    /// 起動時に払っておくため**である。実測 コールド 214.7 ms 対 2 回目以降 63.0 ms
    /// （2026-08-15 / M3 / macOS 26.5.2 / n=20）。これを払わないと、
    /// **起動後の最初の押下だけが 214.7 ms の頭欠けを負う。**
    ///
    /// - Important: **戻った時点でエンジンは動いていない**（`isAwake == false`）。
    ///   起動したまま待機すると `coreaudiod` に常時 +15 ポイント
    ///   （19.6〜20.3% 対 4.3〜4.8%）を課し、マイクのオレンジ点が消えない。
    func prepare() throws

    /// タップを装着してバッファの供給を開始する。
    /// `format` が nil なら入力ノードの形式をそのまま流す。
    ///
    /// **寝ていれば自分で起こす**（実測 中央値 63.0 ms / 最大 129.6 ms）。
    /// 呼び出し側が起きているかを気にする必要はない——**「起こす」口を公開しないのは、
    /// 起こし忘れを型として作れなくするためである。**
    ///
    /// `stopTap()` を経ずに呼び直した場合、前のストリームは
    /// （供給済みのバッファを配り切った上で）終了する。
    func startTap(format: AVAudioFormat?) throws -> AsyncStream<AVAudioPCMBuffer>

    /// タップを外す。**エンジンは止めない。**
    ///
    /// 発話のたびに止めると、次の押下が毎回 63 ms の起床を払う。
    /// 止めるのは `sleep()` の役目であり、いつ止めるかは呼び出し側の方針である。
    func stopTap()

    /// エンジンを止める。**マイクのオレンジ点が消えるのはここだけである。**
    ///
    /// - Important: **タップが張られている間は何もしない。** 録音中に止めると
    ///   その発話が丸ごと消えるため、機構の側でも塞いでおく。
    /// - Important: **冪等。** 寝ている状態で呼んでも、`prepare()` の前に呼んでも何も起きない。
    func sleep()

    /// エンジンが動いているか。**タップの有無とは別の量である**——
    /// マイクの使用状態（オレンジ点）を決めるのはタップではなくエンジンの方である
    /// （2026-08-15 の実測。設計書 §2.1）。
    var isAwake: Bool { get }

    /// 直近バッファの RMS。HUD の音量インジケータ用。
    ///
    /// - Important: **消費者は 1 つに限ること。** `AsyncStream` は複数の
    ///   `next()` を同時に待つと異常終了する。
    /// - Note: 寝ている間は流れない。**ただし終端はしない**（畳むと配り係が死ぬ）。
    var level: AsyncStream<Float> { get }

    /// 形式変換に失敗して**捨てた**バッファの数。
    ///
    /// - Important: **インスタンス生涯の累計であり、発話ごとにはリセットされない。**
    ///   発話単位の値が要る場合は録音の前後で読んで差分を取ること
    ///   （`DictationSession` が `Metrics.Sample.droppedBuffers` でそれを行う）。
    ///   `sleep()` や起床でも 0 に戻らない。
    var droppedBufferCount: Int { get }
}
```

- [ ] **Step 5: 機構を実装する**

`Sources/GhostVoiceCore/Audio/EngineAudioCapture.swift` を 4 箇所いじる。

**(1) 状態を 1 つ足す。** `private var isTapped = false` の下に置く。

```swift
    /// エンジンが動いているか。**`engine.isRunning` の写しではなく、こちらの意思である。**
    /// 再構成（`reconfigure`）が「起こしてよいか」を判断するのに要る。
    private var isAwakeState = false
```

**(2) `prepare()` を捨て起動にする。** `try engine.start()` の後ろ、`isPrepared = true` の手前に
停止を挟む。置き換え後の全体は次のとおり。

```swift
    public func prepare() throws {
        try lock.withLock {
            guard !isPrepared else { return }

            // **入力ノードへ触れる前に**権限を確かめる。順序を入れ替えてはならない。
            // 未許可のまま `inputNode` に触れると実測 510 秒ブロックしてから返る。
            let status = authorization()
            guard status == .authorized else {
                throw AudioCaptureError.microphoneAccessNotGranted(status)
            }

            _ = engine.inputNode
            engine.prepare()
            do {
                try engine.start()
            } catch {
                throw AudioCaptureError.engineUnavailable
            }
            // **捨て起動。** コールドの初回費用（実測 214.7 ms）をここで払い、
            // 以後の起床を 63.0 ms にする。起動したまま待機しない理由は
            // `AudioCapturing.prepare()` の doc を見ること。
            engine.stop()
            isAwakeState = false
            isPrepared = true
            observeConfigurationChanges()
        }
    }
```

**(3) 起床と `sleep()` を足す。** `stopTap()` の直後に置く。

```swift
    public var isAwake: Bool { lock.withLock { isAwakeState } }

    public func sleep() {
        lock.withLock {
            // **タップが張られている間は止めない。** 止めるとその発話が丸ごと消える。
            // 方針側（`DictationSession`）でも塞いでいるが、機構の側にも帯を置く。
            guard isPrepared, isAwakeState, !isTapped else { return }
            engine.stop()
            isAwakeState = false
        }
    }

    /// エンジンを起こす。**呼び出し側は `lock` を保持していること。**
    private func wakeLocked() throws {
        guard !isAwakeState else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioCaptureError.engineUnavailable
        }
        isAwakeState = true
    }
```

**(4) `startTap` が起こすようにする。** `guard isPrepared` の直後に `try wakeLocked()` を挟む。

```swift
    public func startTap(format: AVAudioFormat?) throws -> AsyncStream<AVAudioPCMBuffer> {
        lock.lock()
        defer { lock.unlock() }

        guard isPrepared else { throw AudioCaptureError.notPrepared }

        // **寝ていれば起こす。** 呼び出し側に起こす口を持たせない（契約の doc を見ること）。
        try wakeLocked()

        // 前の発話が畳まれていなければ、ここで畳む。放置すると前の消費者が永久に待つ。
        teardownTap(finishStream: true)

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        requestedFormat = format
        bufferContinuation = continuation
        installTap(target: format, continuation: continuation)
        return stream
    }
```

- [ ] **Step 6: 契約が変わった既存テスト 2 件を書き換える**

`prepareIsIdempotent`（`prepare` の直後にエンジンが動いていることを見ていた）:

```swift
    @Test("prepare を二重に呼んでも例外を出さず、寝たままである")
    func prepareIsIdempotent() throws {
        let rig = try ManualRenderingRig()
        let capture = makeCapture(on: rig)
        try capture.prepare()
        try capture.prepare()
        #expect(!capture.isAwake, "prepare が起こしたまま返っている")
        capture.stopTap()
    }
```

`repeatedPrepareIgnoresLaterRevocation`（同じ理由）:

```swift
    @Test("prepare 済みなら、後から権限が取り消されても prepare は投げない")
    func repeatedPrepareIgnoresLaterRevocation() throws {
        let rig = try ManualRenderingRig()
        let authorization = MutableAuthorization(.authorized)
        let capture = EngineAudioCapture(engine: rig.engine, authorization: authorization.provider)
        try capture.prepare()

        authorization.current = .denied      // ユーザーがシステム設定で取り消した
        // 門番があれば 2 回目は何もせず返る。無ければ microphoneAccessNotGranted を投げる。
        #expect(throws: Never.self) { try capture.prepare() }
        #expect(!capture.isAwake)
    }
```

- [ ] **Step 7: 代役 4 つを追随させる**

**`Tests/GhostVoiceCoreTests/Support/SessionDoubles.swift`** の `StubAudioCapture`。
`State` に 2 つ足し、口を 2 つ生やす。`prepare()` は寝たまま返る（本物と同じ）。

`private struct State { ... }` に追加:

```swift
        var sleepCount = 0
        var awake = false
```

`var stopCount: Int { ... }` の下に追加:

```swift
    /// `sleep()` が呼ばれた回数。**方針（30 秒で寝る）の検査はこれを見る。**
    var sleepCount: Int { state.withLock(\.sleepCount) }
```

`func stopTap()` の後ろに追加:

```swift
    var isAwake: Bool { state.withLock(\.awake) }

    func sleep() {
        state.withLock {
            $0.sleepCount += 1
            $0.awake = false
        }
    }
```

`func startTap` の中、`state.withLock { $0.startCount += 1 }` を次へ置き換える
（本物と同じく「張れば起きている」を写す）:

```swift
        state.withLock {
            $0.startCount += 1
            $0.awake = true
        }
```

**`Tests/GhostVoiceCoreTests/SessionSurfaceTests.swift`** の `LevelEmittingCapture`。
`func stopTap()` の後ろに追加:

```swift
    var isAwake: Bool { true }
    func sleep() {}
```

**`Tests/GhostVoiceCoreTests/DictationSessionMeasurementTests.swift`** の `ReplayAudioCapture`。
同じく `stopTap()` の後ろに追加:

```swift
    var isAwake: Bool { true }
    func sleep() {}
```

**`Tests/GhostVoiceAppTests/HUDWiringTests.swift`** の `StubAudio`（**別ターゲット。忘れやすい**）。
同じく:

```swift
        var isAwake: Bool { true }
        func sleep() {}
```

- [ ] **Step 8: テストを走らせて通ることを確かめる**

Run: `swift test --filter "AudioCapture"`
Expected: PASS（新規 8 件 + 既存の書き換え 2 件を含む）

- [ ] **Step 9: 全体を走らせて巻き添えが無いことを確かめる**

Run: `swift test`
Expected: PASS。**落ちるなら代役の追随漏れを疑う**（4 つ目は別ターゲットにある）

- [ ] **Step 10: コミット**

```bash
git add Sources/GhostVoiceCore/Audio Tests/GhostVoiceCoreTests Tests/GhostVoiceAppTests
git commit -m "feat: エンジンを寝かせられるようにする（起こすのは startTap の仕事にする）

prepare は捨て起動を 1 往復して寝た状態で返る。起こす口は公開せず、
startTap が寝ていれば自分で起こす——呼び出し側に起こし忘れを作らせないため。
sleep はタップが張られている間は何もしない（録音中に止めると発話が消える）。

まだ誰も sleep を呼ばない。方針は次のタスクで DictationSession に置く。"
```

---

### Task 2: 寝ている間にデバイスが変わっても勝手に起きないようにする

**Files:**
- Modify: `Sources/GhostVoiceCore/Audio/EngineAudioCapture.swift`（`reconfigure()`）
- Test: `Tests/GhostVoiceCoreTests/AudioCaptureTests.swift`

**Interfaces:**
- Consumes: Task 1 の `sleep()` / `isAwake`、既存の `waitForReconfiguration()` と `reconfigurationCount`
- Produces: なし（内部の穴を塞ぐだけ）

現行の `reconfigure()` は `isPrepared` だけを見て `engine.start()` する。
**このままだと、寝ている最中に入力デバイスが変わると勝手に起きる**（点が点く）。

- [ ] **Step 1: 失敗するテストを書く**

`AudioCaptureTapTests` の末尾（Task 1 で足したテスト群の後ろ）に追加する。

```swift
    @Test("寝ている間に設定変更が来ても勝手に起きない")
    func reconfigurationDoesNotWakeSleepingEngine() async throws {
        let rig = try ManualRenderingRig()
        let capture = makeCapture(on: rig)
        try capture.prepare()
        capture.sleep()
        #expect(!capture.isAwake)

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: rig.engine)
        await capture.waitForReconfiguration()

        #expect(!capture.isAwake, "寝ている最中にデバイスが変わって勝手に起きた（点が点く）")
    }

    @Test("起きている間の設定変更は今までどおり組み直す")
    func reconfigurationStillRunsWhileAwake() async throws {
        let rig = try ManualRenderingRig()
        let capture = makeCapture(on: rig)
        try capture.prepare()
        _ = try capture.startTap(format: nil)

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: rig.engine)
        await capture.waitForReconfiguration()

        #expect(capture.reconfigurationCount >= 1, "起きている間の再構成まで止めてしまった")
        #expect(capture.isTapping)
        capture.stopTap()
    }
```

- [ ] **Step 2: テストを走らせて落ちることを確かめる**

Run: `swift test --filter "寝ている間に設定変更"`
Expected: FAIL — `寝ている最中にデバイスが変わって勝手に起きた（点が点く）`

- [ ] **Step 3: 門を足す**

`Sources/GhostVoiceCore/Audio/EngineAudioCapture.swift` の `reconfigure()` の
`guard isPrepared else { return }` を次へ置き換える。

```swift
            // **寝ている間は組み直さない。** ここで `engine.start()` すると、
            // 待機中にデバイスが変わっただけで勝手に起きてしまう（オレンジ点が点く）。
            // 入力形式の変化は、次に起きるとき `installTap` が
            // `outputFormat(forBus:)` を読み直すので自然に追従する。
            guard isPrepared, isAwakeState else { return }
```

- [ ] **Step 4: テストを走らせて通ることを確かめる**

Run: `swift test --filter "AudioCapture"`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/GhostVoiceCore/Audio/EngineAudioCapture.swift Tests/GhostVoiceCoreTests/AudioCaptureTests.swift
git commit -m "fix: 寝ている間のデバイス切り替えで勝手に起きないようにする

reconfigure は isPrepared だけを見て engine.start() していたので、
待機中に入力デバイスが変わるとエンジンが起きてオレンジ点が点いた。
入力形式の変化は次に起きるとき installTap が読み直すので取りこぼさない。"
```

---

### Task 3: 最後の発話から 30 秒で寝かせる（方針）

**Files:**
- Modify: `Sources/GhostVoiceCore/Session/DictationSession.swift`
- Test: `Tests/GhostVoiceCoreTests/DictationSessionTests.swift`

**Interfaces:**
- Consumes: Task 1 の `AudioCapturing.sleep()`、`StubAudioCapture.sleepCount`
- Produces:
  - `DictationSession.defaultAudioIdleSleepDelay: Duration`（`.seconds(30)`）
  - 公開初期化子と `forTests` の `audioIdleSleepDelay: Duration = ...` 引数

- [ ] **Step 1: 治具に遅延の注入口を足す**

`Tests/GhostVoiceCoreTests/DictationSessionTests.swift` の `makeRig`（44 行付近）へ
引数を 1 つ足し、`DictationSession.forTests` へ素通しする。**新しい治具は作らない。**

引数リストの `refinerWarmthWindow:` の後ろへ:

```swift
        refinerWarmthWindow: Duration = DictationSession.defaultRefinerWarmthWindow,
        audioIdleSleepDelay: Duration = DictationSession.defaultAudioIdleSleepDelay
```

`forTests(...)` の呼び出しの `refinerWarmthWindow: refinerWarmthWindow` の後ろへ:

```swift
            refinerWarmthWindow: refinerWarmthWindow,
            audioIdleSleepDelay: audioIdleSleepDelay
```

- [ ] **Step 2: 失敗するテストを書く**

同ファイルの `DictationSessionTests` スイート**の中**（末尾、閉じ括弧の手前）に追加する。
`makeRig` / `speak` / `Rig` が `private` なので、**別スイートには出せない。**

> **固定 sleep を安易に使わないこと**（ファイル冒頭 `waitUntil` の注記）。
> 「起きること」は `waitUntil` で待つ。**「起きないこと」だけは有界の待ちが要る**——
> 下の 2 件はそれに当たるので、なぜ必要かをコメントに残してある。

```swift
    // MARK: - マイクをアイドルで寝かせる（設計書 2026-08-15）

    @Test("既定は 30 秒")
    func audioIdleSleepDefaultIs30Seconds() {
        #expect(DictationSession.defaultAudioIdleSleepDelay == .seconds(30))
    }

    @Test("発話が終わって猶予を過ぎるとマイクが寝る")
    func sleepsAfterIdleDelay() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, audioIdleSleepDelay: .milliseconds(50))
            try await speak(rig)
            try await waitUntil("マイクが寝る") { rig.audio.sleepCount == 1 }
            #expect(!rig.audio.isAwake)
        }
    }

    @Test("録音中は寝ない")
    func doesNotSleepWhileRecording() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, audioIdleSleepDelay: .milliseconds(50))
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") { await Self.label(rig.session.state) == "recording" }

            // **「起きない」ことの検査なので、有界で待つしかない。**
            // 猶予（50 ms）の 6 倍待って、それでも呼ばれていなければ良い。
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.audio.sleepCount == 0, "録音中にマイクを止めた。その発話が丸ごと消える")

            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }
        }
    }

    @Test("次の発話が始まると前の予約は取り消される")
    func nextUtteranceCancelsPendingSleep() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, audioIdleSleepDelay: .milliseconds(200))
            try await speak(rig)   // ここで 1 本目の予約が入る
            try await speak(rig)   // 押下で取り消され、終わって 2 本目が入る

            try await waitUntil("マイクが寝る") { rig.audio.sleepCount >= 1 }

            // **取り消しに失敗していれば 1 本目も別に発火して 2 回になる。**
            // その差はここで有界に待たないと観測できない。
            try await Task.sleep(for: .milliseconds(400))
            #expect(rig.audio.sleepCount == 1, "前の発話の予約が取り消されていない（二重に寝ている）")
        }
    }

    @Test("失敗で終わった発話でも予約される")
    func schedulesAfterFailedUtterance() async throws {
        try await withTempRoot { root in
            let audio = StubAudioCapture()
            audio.startError = AudioCaptureError.engineUnavailable
            let rig = makeRig(root: root, audio: audio, audioIdleSleepDelay: .milliseconds(50))
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)

            // 失敗経路も `finishIdle()` を通る。通っていなければ永久に寝ない。
            try await waitUntil("マイクが寝る") { rig.audio.sleepCount == 1 }
        }
    }
```

- [ ] **Step 3: テストを走らせて落ちることを確かめる**

Run: `swift test --filter "マイクをアイドルで寝かせる"`
Expected: **コンパイルエラー** — `defaultAudioIdleSleepDelay` が無い

- [ ] **Step 4: 既定値と保持を足す**

`Sources/GhostVoiceCore/Session/DictationSession.swift`。

`public static let defaultFinalizeDeadline: Duration = .seconds(2)`（162 行付近）の近くに:

```swift
    /// 最後の発話から、マイク（`AVAudioEngine`）を止めるまでの猶予。**既定 30 秒。**
    ///
    /// 常時起動したままだと `coreaudiod` に +15 ポイント（実測 19.6〜20.3% 対 4.3〜4.8%。
    /// 2026-08-15 / M3 / macOS 26.5.2）を課し、マイクのオレンジ点が消えない。
    /// 逆に発話ごとに止めると、**毎回** 起床の 63.0 ms（最大 129.6 ms）を払う。
    /// 30 秒は「文を続けて喋る間は起きたまま、考え込んだら消える」ところに置いた裁定である
    /// （設計書 2026-08-15 §3）。**要件値ではない。**
    public static let defaultAudioIdleSleepDelay: Duration = .seconds(30)
```

`private let finalizeDeadline: Duration`（201 行付近）の下に:

```swift
    private let audioIdleSleepDelay: Duration
    /// 待機が続いたらマイクを止める係。**押下のたびに取り消す。**
    private var audioSleepTask: Task<Void, Never>?
```

- [ ] **Step 5: 3 つの初期化子へ引数を通す**

`public init`（395 行付近）の `finalizeDeadline:` の後ろに引数を足し、`self.init` へ渡す。

```swift
        maxRecordingDuration: Duration = DictationSession.defaultMaxRecordingDuration,
        finalizeDeadline: Duration = DictationSession.defaultFinalizeDeadline,
        audioIdleSleepDelay: Duration = DictationSession.defaultAudioIdleSleepDelay
    ) {
        self.init(
            settings: settings, hotkey: hotkey, audio: audio, transcriber: transcriber,
            refiner: refiner, inserter: insertion.inserter, replacer: insertion.replacer,
            clipboard: insertion.clipboard, history: history, vocabulary: vocabulary,
            isSecureInputEnabled: isSecureInputEnabled,
            postEventAuthorization: postEventAuthorization,
            maxRecordingDuration: maxRecordingDuration, finalizeDeadline: finalizeDeadline,
            audioIdleSleepDelay: audioIdleSleepDelay)
    }
```

`static func forTests`（433 行付近）にも同じ引数を足し、`DictationSession(...)` へ渡す
（`refinerWarmthWindow:` の隣に `audioIdleSleepDelay: audioIdleSleepDelay` を並べる）。

```swift
        finalizeDeadline: Duration = DictationSession.defaultFinalizeDeadline,
        refinerWarmthWindow: Duration = DictationSession.defaultRefinerWarmthWindow,
        audioIdleSleepDelay: Duration = DictationSession.defaultAudioIdleSleepDelay
```

`private init`（459 行付近）にも引数を足し、保持する。

```swift
        finalizeDeadline: Duration,
        refinerWarmthWindow: Duration = DictationSession.defaultRefinerWarmthWindow,
        audioIdleSleepDelay: Duration = DictationSession.defaultAudioIdleSleepDelay
```

`self.refinerWarmthWindow = refinerWarmthWindow` の下に:

```swift
        self.audioIdleSleepDelay = audioIdleSleepDelay
```

- [ ] **Step 6: 予約・取り消し・発火を書く**

`// MARK: - 待ち合わせ` の直前（`salvageAbandonedRecording()` の後ろあたり）に足す。

```swift
    // MARK: - マイクをアイドルで寝かせる（設計書 2026-08-15）

    /// 待機へ戻ったので、猶予を過ぎたらマイクを止める予約を入れる。
    ///
    /// **掛け金を `finishIdle()` に置いているのは、そこが待機へ戻る唯一の合流点だから**
    /// である（正常終了・失敗・中断のすべてが通る）。押下側に対応する掛け金を
    /// 置かなくて済む。
    private func scheduleAudioSleep() {
        audioSleepTask?.cancel()
        audioSleepTask = Task { [weak self, audioIdleSleepDelay] in
            try? await Task.sleep(for: audioIdleSleepDelay)
            guard !Task.isCancelled else { return }
            await self?.sleepAudioIfIdle()
        }
    }

    /// 猶予が過ぎた。**まだ待機のままなら**止める。
    ///
    /// 取り消し（`cancelAudioSleep`）と二重の帯にしてある。取り消しが効かなかった場合でも、
    /// **録音中にマイクを止めて発話を丸ごと失う**ことだけは起こらないようにする。
    private func sleepAudioIfIdle() {
        audioSleepTask = nil
        guard phase == .idle else { return }
        audio.sleep()
    }

    private func cancelAudioSleep() {
        audioSleepTask?.cancel()
        audioSleepTask = nil
    }
```

- [ ] **Step 7: 掛け金を 2 箇所に繋ぐ**

`startRecording()`（805 行付近）の**先頭**——`await completionTask?.value` の手前——に:

```swift
        // 押された。マイクを止める予約が入っていれば取り消す。
        // **`await` の手前で取り消す。** 後ろに置くと、待っている間に予約が発火しうる。
        cancelAudioSleep()
```

`finishIdle(keepingSessionBusy:)`（1878 行付近）の `emit(.idle)` の**後ろ**に:

```swift
        // 待機へ戻った。猶予を過ぎたらマイクを止める（設計書 2026-08-15）。
        // **`keepingSessionBusy` でも予約してよい**——保留中の差し替えはマイクを使わない。
        scheduleAudioSleep()
```

- [ ] **Step 8: テストを走らせて通ることを確かめる**

Run: `swift test --filter "マイクをアイドルで寝かせる"`
Expected: PASS（5 件）

- [ ] **Step 9: 全体を走らせる**

Run: `swift test`
Expected: PASS

- [ ] **Step 10: コミット**

```bash
git add Sources/GhostVoiceCore/Session/DictationSession.swift Tests/GhostVoiceCoreTests/DictationSessionTests.swift
git commit -m "feat: 最後の発話から 30 秒でマイクを止める

掛け金は finishIdle に置いた。そこが待機へ戻る唯一の合流点なので、
正常終了・失敗・中断のどれで終わっても予約が入る。
発火時に phase == .idle を見直して、取り消しが効かなかった場合でも
録音中に止めてしまわないようにしてある。"
```

---

### Task 4: 実マイクで起床費用を測る（V-9 の形）

**Files:**
- Modify: `Tests/GhostVoiceCoreTests/AudioCaptureTests.swift`（`AudioCaptureMicrophoneTests`）

**Interfaces:**
- Consumes: Task 1 の `sleep()` / `isAwake`、既存の `MicrophoneTestGate` / `stats(_:)` / `milliseconds(_:)`
- Produces: なし（計測）

**このタスクには、既存テスト `armingLatency` の修正が含まれる。**
`prepare()` が寝て返るようになったため、あのテストの 30 回ループの**1 回目だけが起床
（実測 中央値 63.0 ms / 最大 129.6 ms）を払う。** 壊れ検知の線は 75 ms なので、
そのままだと不定期に落ちる。改訂後の NFR-P1 が 50 ms を要求するのは
「連続する発話」——つまりエンジンが起きている状態——なので、**測る前に 1 回起こす。**

- [ ] **Step 1: `armingLatency` を、起こしてから測る形へ直す**

`try capture.prepare()` と `var samples: [Double] = []` の間に足す。

```swift
        // **測る前に起こす。** 改訂後の NFR-P1 が 50 ms を要求するのは連続する発話
        // （＝エンジンが起きている状態）であり、スリープからの初回は別枠である
        // （下の `wakeLatency` がそちらを測る）。ここで起こしておかないと、
        // 30 回のうち 1 回目だけが起床ぶんを含んで壊れ検知の線を割る。
        _ = try capture.startTap(format: nil)
        capture.stopTap()
```

- [ ] **Step 2: 起床費用の計測を足す**

`armingLatency` の後ろに置く。

```swift
    /// **スリープからの起床費用**（設計書 2026-08-15 / V-46）。
    ///
    /// 改訂後の NFR-P1 は、アイドル 30 秒を超えて眠った後の最初の 1 回について
    /// この量を許容している。**合否線ではなく計測である**——印字された中央値と最大を
    /// 読んで判断すること。線は壊れ検知として 300 ms に置く（設計時の実測は
    /// 中央値 63.0 ms / 最大 129.6 ms。2026-08-15 / M3 / macOS 26.5.2 / n=20）。
    @Test("スリープからの起床 → タップ武装")
    func wakeLatency() throws {
        let capture = EngineAudioCapture()
        try capture.prepare()

        var samples: [Double] = []
        for _ in 0..<20 {
            capture.sleep()
            #expect(!capture.isAwake)
            let start = ContinuousClock.now
            _ = try capture.startTap(format: nil)
            samples.append(milliseconds(ContinuousClock.now - start))
            capture.stopTap()
        }
        let s = stats(samples)
        print(String(format: "起床 → タップ武装: 中央値 %.1f ms / 最小 %.1f / 最大 %.1f（20 回・実 HAL）",
                     s.median, s.min, s.max))
        #expect(
            s.max < 300,
            "壊れ検知の線を割った（線は要件値ではない。設計時の実測は最大 129.6 ms）: 最大 \(s.max) ms")
    }

    /// **オレンジ点を点けているのはタップではなくエンジンである**（設計書 §2.1）。
    /// この対応が崩れると、寝かせても点が消えなくなる。
    @Test("エンジンの起動状態が入力デバイスの使用状態に一致する")
    func engineStateMatchesDeviceUsage() throws {
        let capture = EngineAudioCapture()
        try capture.prepare()
        capture.sleep()
        #expect(!capture.isAwake)

        _ = try capture.startTap(format: nil)
        #expect(capture.isAwake)
        capture.stopTap()
        #expect(capture.isAwake, "stopTap でエンジンまで止まっている")

        capture.sleep()
        #expect(!capture.isAwake)
    }
```

- [ ] **Step 3: 門の内側を走らせる**

Run: `GHOST_VOICE_MIC_TESTS=1 swift test --filter "AudioCapture の実マイク"`
Expected: PASS。**印字された起床の中央値・最大を控えること**（Task 5 で正本へ書く）

> マイク権限が無い環境ではスイートごとスキップされる。その場合は
> Task 5 の実測値として設計時の値（中央値 63.0 ms / 最大 129.6 ms）を使い、
> **「本タスクでは再測していない」と正本に明記すること。**

- [ ] **Step 4: コミット**

```bash
git add Tests/GhostVoiceCoreTests/AudioCaptureTests.swift
git commit -m "test: 起床費用を実マイクで測る（V-46）

armingLatency は prepare が寝て返るようになったぶん、30 回の 1 回目だけが
起床を含んで壊れ検知の線を割るようになっていた。測る前に 1 回起こす。
改訂後の NFR-P1 が 50 ms を要求するのは連続する発話の側である。"
```

---

### Task 5: 正本を改訂する

**Files:**
- Modify: `docs/01-requirements.md`（NFR-P1 の行）
- Modify: `docs/02-architecture.md`（§6 ウォームアップ設計の表）
- Modify: `docs/03-detailed-design.md`（§3.5 付近の契約、§10 の計測、§13 の検証項目一覧）
- Modify: `docs/04-handover-verification.md`（V-46 / V-47）

**Interfaces:**
- Consumes: Task 4 で印字された実測値（取れていなければ設計時の値）
- Produces: なし

- [ ] **Step 1: NFR-P1 を改訂する**

`docs/01-requirements.md` の NFR-P1 の行（857 行付近）。**既存の実測記録は消さない**——
「常時ウォームだった頃の値」として残し、例外条項を足す形にする。行末に追記する:

```
**【2026-08-15 改訂】アイドル 30 秒を超えて眠った後の最初の 1 回は、起床ぶんを許容する**
（実測 中央値 63.0 ms / 最大 129.6 ms。2026-08-15 / M3 / macOS 26.5.2 / n=20）。
連続する発話ではエンジンが起きたままなので従来どおり 50 ms 以内である。
**この例外は電力と引き換えに受け入れたものである**——常時ウォームは `coreaudiod` に
常時 +15 ポイント（19.6〜20.3% 対 4.3〜4.8%）を課し、マイクのオレンジ点も消えなかった
（設計書 `docs/superpowers/specs/2026-08-15-microphone-idle-sleep-design.md`）。
```

- [ ] **Step 2: 基本設計書 §6 を直す**

`docs/02-architecture.md` の §6（331 行付近）のウォームアップ表に `AVAudioEngine` の
行があれば「常時起動」の記述を次へ直す。無ければ表へ 1 行足す。

```
| `AVAudioEngine` | 初回 `start()` 実測 214.7 ms | 起床 実測 63.0 ms（中央値） | 起動時に**捨て起動を 1 往復**してコールドぶんを払い、以後は寝かせる。**待機中は止める**——起動したままだと `coreaudiod` に常時 +15 ポイント。最後の発話から 30 秒で停止（`DictationSession.defaultAudioIdleSleepDelay`） |
```

同 §6 の冒頭方針「常時起動しておくべきものは起動時に温めておく」（18 行付近）にも
但し書きを足す:

```
**ただし `AVAudioEngine` は例外である**（2026-08-15 改訂）。温めたまま保つ費用が
`coreaudiod` の +15 ポイントとして常時かかるため、アイドル 30 秒で止める。
温めるのは「起動時に捨て起動でコールドぶんを払う」ところまでとする。
```

- [ ] **Step 3: 詳細設計書を直す**

`docs/03-detailed-design.md`:

1. 488 行付近の「`AVAudioEngine` は `prepare()` で `start()` まで済ませ、以後停止しない（NFR-P1）」を
   次へ置き換える。

```
- `AVAudioEngine` は `prepare()` で**捨て起動を 1 往復してから停止する**（2026-08-15 改訂）。
  以後、`startTap` が寝ていれば自分で起こし、`sleep()` で止める。
  **「起こす」口は公開しない**——起こし忘れを型として作れなくするため。
  いつ止めるかは `DictationSession` の方針（既定 30 秒）。
```

2. §10（2765 行付近）の計測表に起床の行を足す。

```
| `M1c` | **スリープからの起床 → タップ武装** | **実測 中央値 63.0 ms / 最小 54.0 / 最大 129.6**（2026-08-15 / M3 / macOS 26.5.2 / n=20）。コールドの初回 `start()` 214.7 ms とは別の量で、`prepare()` の 327〜456 ms とも別物。改訂後の NFR-P1 はこれを例外として許容する |
```

3. §13（3578 行付近）の検証項目一覧へ V-46 / V-47 を足す。

```
| V-46 | **アイドル 30 秒でオレンジ点が消え、押下で戻ること** | 実装 §12-3 | 常駐させて 30 秒待ち、メニューバーを目視。押して戻ることも見る |
| V-47 | **待機中の `coreaudiod` の CPU が停止時の水準へ落ちること** | 実装 §12-3 | 常駐させて 30 秒待ち、`ps -Ao time,comm` で `coreaudiod` を 20 秒窓で 2 回読む。常時ウォーム時 19.6〜20.3% に対し 4.3〜4.8% まで落ちれば良い |
```

- [ ] **Step 4: 引き継ぎ文書へ V-46 / V-47 を足す**

`docs/04-handover-verification.md` の V 項目表（1232 行付近の V-7 / V-11 と同じ形）へ:

```
| **V-46** | アイドル 30 秒でオレンジ点が消え、押下で戻ること | 【実機でしか判らない】 | 常駐させて 30 秒待ち、メニューバーを目視。その後 PTT を押して点が戻ることも見る | 設計書 2026-08-15 §9 |
| **V-47** | 待機中の `coreaudiod` の CPU（電力） | 【実機でしか判らない】 | 30 秒待った後、`ps -Ao time,comm \| awk '$2 ~ /coreaudiod$/ {print $1}'` を 20 秒あけて 2 回読み、差分から % を出す。4.3〜4.8% 水準なら良い（常時ウォーム時は 19.6〜20.3%） | 設計書 2026-08-15 §2.3 |
```

- [ ] **Step 5: 正本どうしが食い違っていないか確かめる**

```bash
grep -rn "常時起動\|以後停止しない" docs/01-requirements.md docs/02-architecture.md docs/03-detailed-design.md
```

期待: 残っている「常時起動」の記述が、すべて**改訂前の経緯としての言及**になっていること
（現在の振る舞いの説明として残っていたら直す）。

- [ ] **Step 6: コミット**

```bash
git add docs/
git commit -m "docs: マイクをアイドルで寝かせる裁定を正本へ入れる（NFR-P1 に例外条項）

常時ウォームは coreaudiod に常時 +15 ポイントを課していた。
NFR-P1 の 50 ms は連続する発話に対する要求として残し、
スリープからの初回だけ起床ぶん（中央値 63.0 ms / 最大 129.6 ms）を許容する。
V-46 / V-47 は実機でしか判らないので引き継ぎへ回す。"
```

---

## 完了の確認

- [ ] `swift test` が緑
- [ ] `GHOST_VOICE_MIC_TESTS=1 swift test --filter "AudioCapture の実マイク"` が緑（権限のある機体で）
- [ ] `Scripts/make-app.sh` でビルドし、`/Applications` の `Ghost Voice.app` を差し替えて起動
- [ ] **V-46 を目視**: 30 秒待ってオレンジ点が消える。押すと戻る
- [ ] **V-47 を実測**: 待機 30 秒後の `coreaudiod` が 4〜5% 水準
- [ ] 発話 → 挿入が今までどおり動く（頭欠けが増えていないこと。特にスリープ明けの 1 回目）

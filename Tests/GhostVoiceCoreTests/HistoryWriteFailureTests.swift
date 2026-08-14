import Foundation
import Testing

@testable import GhostVoiceCore

/// **「履歴へ書けない世界」を作る。**
///
/// 変異解析（視点 4 の §4.3 / §4.4）で判ったのは、この世界がテストに 1 つも無かった
/// ことである。そのせいで
///
/// - `applyRevision` で**履歴より先に欄を書き換える**変異（E1）
/// - 履歴書き込みの失敗を**握り潰す**変異（E10）
/// - (a) 分岐で**履歴に書けなくても差し替えへ進む**変異（A3）
///
/// の 3 つが揃って生き残った。**個別に表明を足すのではなく、世界を 1 つ用意して
/// 全経路から駆動できるようにする。**
///
/// 保存先ディレクトリを書き込み不可（`0o500`）にすると、`AtomicJSONFile.save` の
/// `Data.write(to:options:.atomic)` が失敗する（同じディレクトリへ一時ファイルを
/// 作れないため）。**製品コードに検査用の穴を開けずに済む。**
struct HistoryWriteBarrier {
    let url: URL

    /// 以後の保存を失敗させる。
    func close() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
    }

    /// 元へ戻す。**後片付けが漏れると一時ディレクトリを消せなくなる。**
    func open() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

/// バリアを必ず開けてから抜ける。
func withHistoryWriteBarrier<R>(
    at url: URL, _ body: (HistoryWriteBarrier) async throws -> R
) async throws -> R {
    let barrier = HistoryWriteBarrier(url: url)
    defer { barrier.open() }
    return try await body(barrier)
}

@Suite("履歴へ書けない世界")
struct HistoryWriteFailureTests {

    // MARK: - 上限 0（設定画面のステッパーで到達できる構成）

    /// **`append` は「例外が出なかったか」ではなく「実際に残ったか」を返す。**
    ///
    /// 上限 0 では挿入した項目をその場で捨てるので、書き込みは成功しても
    /// **履歴には 1 件も残らない。** 呼び出し側から見た `true` の意味が
    /// 「保存された」ではなく「例外が出なかった」になっていると、
    /// **中断された発話がどこにも残らないまま成功として扱われる。**
    @Test("上限 0 の履歴は append が「残らなかった」と答える")
    func appendReportsThatNothingWasRetained() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 0)
            let retained = try store.append(
                HistoryEntry(
                    rawText: "消える発話", refinedText: nil,
                    localeIdentifier: "ja-JP", insertionMethod: .notInserted))
            #expect(!retained, "上限 0 なのに『残った』と答えている")
            #expect(store.entries.isEmpty)
        }
    }

    @Test("上限が正なら append は「残った」と答える")
    func appendReportsRetentionWhenTheLimitIsPositive() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let retained = try store.append(
                HistoryEntry(
                    rawText: "残る発話", refinedText: nil,
                    localeIdentifier: "ja-JP", insertionMethod: .notInserted))
            #expect(retained)
            #expect(store.entries.count == 1)
        }
    }

    /// **これが指摘 A-1 そのものである。**
    ///
    /// 履歴の上限を 0 にすると、ESC で中断した発話は
    /// 欄にもクリップボードにも履歴にも残らない。**それでも失敗が 1 つも出ない。**
    /// `SessionFailure.historyUnavailable(insertedElsewhere: false)` は
    /// 「発話そのものが失われた」と言うために用意された唯一の分岐なのに、到達しなかった。
    @Test("上限 0 で中断した発話は、失われたことを知らせる")
    func reportsLossWhenTheHistoryKeepsNothing() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, historyLimit: 0)
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.cancelled)
            try await waitUntil("失敗が記録される") {
                await log.states.contains {
                    if case .failed = $0 { return true } else { return false }
                }
            }

            let states = await log.states
            #expect(
                states.contains(.failed(.historyUnavailable(insertedElsewhere: false))),
                "発話が欄にもクリップボードにも履歴にも無いのに、失敗が 1 つも出ていない")
            #expect(rig.history.entries.isEmpty)
            #expect(rig.content == RevisionRig.prefix + RevisionRig.suffix, "欄は触っていない")
        }
    }

    /// 上限 0 でも**挿入まで届いた発話**は失われていない。
    /// **同じ扱いにしてはならない**（利用者にとって意味がまったく違う）。
    @Test("上限 0 でも挿入できた発話は「失われた」と言わない")
    func doesNotClaimLossWhenTheTextReachedTheField() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, historyLimit: 0)
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("生テキストが入る") { rig.content == RevisionRig.contentWithRaw }
            try await waitUntil("待機へ戻る") { await log.states.last == .idle }

            let states = await log.states
            #expect(
                !states.contains(.failed(.historyUnavailable(insertedElsewhere: false))),
                "欄にテキストがあるのに『失われた』と言っている")
        }
    }

    // MARK: - 書き込みそのものが失敗する世界（変異 A3 / E1 / E10）

    /// **変異 A3**: (a) 分岐で `guard record(entry)` を無効化しても検査は緑だった。
    ///
    /// 履歴に書けないまま差し替えへ進むと、**整形結果の写しがどこにも無い状態で
    /// 欄を書き換える。** 差し替えの 4 重の受けのうち 1 番目が抜ける。
    @Test("(a) 分岐は、生テキストを履歴へ書けなければ差し替えへ進まない")
    func doesNotStartARevisionWhenTheInitialRecordFails() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(50))
            try await withHistoryWriteBarrier(at: root) { barrier in
                try barrier.close()

                let log = StateLog()
                let collector = await log.collect(from: rig.session.stateUpdates)
                defer { collector.cancel() }
                let notices = rig.notices.follow(rig.session)
                defer { notices.cancel() }
                let run = Task { await rig.session.run() }
                defer { run.cancel() }

                rig.hotkey.emit(.pressed)
                try await waitUntil("録音が始まる") {
                    if case .recording = await rig.session.state { return true }
                    return false
                }
                rig.audio.emit(frames: 1_600)
                rig.hotkey.emit(.released)
                try await waitUntil("失敗が記録される") {
                    await log.states.contains {
                        if case .failed = $0 { return true } else { return false }
                    }
                }
                // 差し替えが走らないことを見るので、走る余地のある時間だけ待つ。
                try await Task.sleep(for: .milliseconds(300))

                #expect(
                    await log.states.contains(
                        .failed(.historyUnavailable(insertedElsewhere: true))),
                    "履歴へ書けなかったことを黙って飲み込んでいる")
                #expect(
                    rig.content == RevisionRig.contentWithRaw,
                    "履歴に写しが無いのに欄を書き換えている（差し替えへ進んでいる）")
                #expect(rig.notices.notices.isEmpty || rig.notices.notices == [.refinementNotApplied(nil)])
            }
        }
    }

    /// **変異 E1 / E10**: 履歴と欄の**順序**を入れ替えても、
    /// 履歴書き込みの失敗を握り潰しても、検査は緑だった。
    ///
    /// 順序を弁別できる観測は 1 つしかない——
    /// **「履歴の更新が失敗する世界で、欄が 1 文字も変わっていないこと」**である。
    @Test("整形結果を履歴へ書けなければ、欄は 1 文字も変えない")
    func doesNotTouchTheFieldWhenTheHistoryUpdateFails() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(150))
            try await withHistoryWriteBarrier(at: root) { barrier in
                let log = StateLog()
                let collector = await log.collect(from: rig.session.stateUpdates)
                defer { collector.cancel() }
                let notices = rig.notices.follow(rig.session)
                defer { notices.cancel() }
                let run = Task { await rig.session.run() }
                defer { run.cancel() }

                rig.hotkey.emit(.pressed)
                try await waitUntil("録音が始まる") {
                    if case .recording = await rig.session.state { return true }
                    return false
                }
                rig.audio.emit(frames: 1_600)
                rig.hotkey.emit(.released)
                // **生テキストの記録までは通す。** 塞ぐのは整形結果の更新だけである。
                try await waitUntil("生テキストが履歴へ入る") { !rig.history.entries.isEmpty }
                try barrier.close()

                try await waitUntil("差し替えの顛末が出る") { !rig.notices.notices.isEmpty }

                #expect(
                    rig.content == RevisionRig.contentWithRaw,
                    "履歴へ書けていないのに欄を書き換えた（順序が逆になっている）")
                #expect(
                    await log.states.contains(
                        .failed(.historyUnavailable(insertedElsewhere: true))),
                    "履歴の更新に失敗したことを握り潰している")
                #expect(rig.notices.notices == [.refinementNotApplied(nil)])
            }
        }
    }

    /// 押し出し・削除で項目が消えていた場合も同じである
    /// （`HistoryStore.update` は例外を投げず `false` を返す）。
    @Test("差し替え先の履歴項目が消えていたら、欄は 1 文字も変えない")
    func doesNotTouchTheFieldWhenTheHistoryEntryIsGone() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(150))
            let notices = rig.notices.follow(rig.session)
            defer { notices.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("生テキストが履歴へ入る") { !rig.history.entries.isEmpty }
            // 利用者が履歴画面から全部消した。
            try await rig.history.removeAll()

            try await waitUntil("差し替えの顛末が出る") { !rig.notices.notices.isEmpty }
            #expect(
                rig.content == RevisionRig.contentWithRaw,
                "履歴に写しが無いのに欄を書き換えている")
            #expect(rig.notices.notices == [.refinementNotApplied(nil)])
        }
    }
}

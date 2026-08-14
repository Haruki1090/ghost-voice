import Foundation

/// **同期のファイル I/O を、呼び出し元の実行文脈から必ず外す係。**
///
/// ## なぜ型にするのか
///
/// `SettingsStore.update` と `VocabularyStore.replace` は **ロックを保持したまま同期の
/// ファイル I/O を行う**（それぞれの doc コメント）。設定画面は `@MainActor` なので、
/// そのまま呼ぶと**メインスレッドが止まる。** メインスレッドが止まると、
/// ランループ検証の実測どおり **`CGEventTap` の配送が悪化する**（p50 0.045 → 12.8 ms。
/// `.superpowers/sdd/2026-08-14-ghost-voice-phase2/progress.md`「ランループ検証」）——
/// つまり**設定を保存した瞬間だけ PTT の反応が鈍る。**
///
/// `Task.detached` を書き散らすとこの規律は守られたかどうか確かめられない。
/// **1 つの型に閉じて、その型を通ったことを検査で示せる形にする。**
///
/// ## 検査
///
/// - `.offCallerActor` が本当にメインスレッドを離れることは `BackgroundWriteTests` が測る。
/// - **ViewModel がそれを使っていること**は、`SettingsViewModel.writeContextProbe` が
///   書き込み地点そのもので測る。書き手の側で測ると、書き手が自分で選んだ文脈を
///   自分で報告することになり、**ViewModel がその書き手を使っているか**は何も示せない。
public struct BackgroundWrite: Sendable {

    /// 背景で走らせる仕事。**同期であること**（ここへ渡ってくるのは Core の同期 I/O）。
    public typealias Work = @Sendable () throws -> Void

    private let run: @Sendable (@escaping Work) async throws -> Void

    /// - Parameter run: 仕事をどの文脈で走らせるか。**検査は MainActor へ釘付けにした
    ///   ものを差し込み、「塞がない」の検査が空振りでないことを示す。**
    public init(_ run: @escaping @Sendable (@escaping Work) async throws -> Void) {
        self.run = run
    }

    public func callAsFunction(_ work: @escaping Work) async throws {
        try await run(work)
    }

    /// **本番の書き手。呼び出し元のアクターを必ず離れる。**
    ///
    /// `@concurrent` を付けた関数は、呼び出し元が `@MainActor` でも
    /// **並行実行プールへ移ってから本体を走らせる**（`HistoryStore.remove` 等が
    /// Core 側で採っているのと同じ手）。
    public static let offCallerActor = BackgroundWrite { work in
        try await runOffCallerActor(work)
    }
}

/// **`@concurrent` はここにしか無い。** 呼び出し元のアクターを離れる唯一の地点である。
@concurrent
private func runOffCallerActor(_ work: @escaping BackgroundWrite.Work) async throws {
    try work()
}

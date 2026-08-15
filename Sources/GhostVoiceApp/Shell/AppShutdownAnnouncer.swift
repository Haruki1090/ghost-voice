import Foundation
import GhostVoiceCore

/// 終了の文言を受け取って画面へ出せる面。**いまは HUD だけが名乗る。**
@MainActor
public protocol ShutdownAnnouncingSurface: AnyObject {
    /// - Parameter announcement: 何を告げるか。**文言は `ShutdownAnnouncement` が持つ。**
    ///   `hudText` が nil のものは出さないこと。
    func showShutdown(_ announcement: ShutdownAnnouncement)
}

/// **終了の文言の出口。`.app` に 1 つだけ置く。**
///
/// ## なぜ要るのか（実機 2026-08-15）
///
/// 終了の段取りは正しく動き、正しい文言を出していた:
///
/// ```
/// [終了] 進行中の発話を待っています…
///        **録音中なら PTT キーを離してください。** 離せば確定・整形・挿入まで走ります。
/// ```
///
/// **しかし `.app` では unified log にしか出ない。画面には何も出なかった。**
/// 利用者は PTT キーを押したまま「全然反応しません」と言い、案内を一度も見ないまま
/// 猶予 10 秒を使い切った。**正しく待っているのに、壊れて見えていた。**
///
/// ## ログと HUD の両方へ流す（**片方に寄せない**）
///
/// - **ログは必ず出す。** HUD が死んでいる状況でも終了待ちは起きる——
///   実際、直前の欠陥は「メインキューが詰まって `@MainActor` が全部死ぬ」形だった。
///   そのときログだけが残る
/// - **HUD へはメインへ渡してから出す。** `Shutdown.perform` の `announce` は
///   一般の実行文脈から呼ばれる（`perform` は `nonisolated`）
public enum AppShutdownAnnouncer {

    /// 画面側の受け手。**弱参照。** 終了処理より先に画面が畳まれても、ログは出続ける。
    @MainActor private static weak var surface: (any ShutdownAnnouncingSurface)?

    /// 受け手を差し替える。`LaunchSequence` が画面を作った直後に 1 度だけ呼ぶ。
    @MainActor
    public static func use(_ surface: (any ShutdownAnnouncingSurface)?) {
        Self.surface = surface
        AppDiagnostics.note(
            surface == nil
                ? "[終了] 終了待ちを出せる画面がありません。ログにだけ出します。"
                : "[終了] 終了待ちの案内を HUD にも出します。")
    }

    /// **`Shutdown.perform(announce:)` へ渡すもの。** どの実行文脈から呼ばれてもよい。
    public static let sink: @Sendable (ShutdownAnnouncement) -> Void = { announcement in
        AppDiagnostics.note(announcement.text)
        guard announcement.hudText != nil else { return }
        Task { @MainActor in surface?.showShutdown(announcement) }
    }
}

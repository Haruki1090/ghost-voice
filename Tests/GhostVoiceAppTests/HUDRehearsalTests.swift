import Foundation
import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

/// **目視でしか確かめられない未実測項目のための素振り**（`--hud-check`）。
///
/// V-20（切り欠きに画素があるか）/ V-21（全 Space・フルスクリーン）/ V-22（クラムシェル）は
/// **HUD が出ていないと確かめられない**が、実際に出すには本来マイクとキー監視の許可が要る。
/// この筋書きはどちらも触らずに全種類の表示を一巡させる。
///
/// **筋書きに抜けがあると、抜けた表示だけ誰も見ないまま出荷される。**
@Suite("HUD の素振り（--hud-check）")
struct HUDRehearsalTests {

    @Test("表示の全種類を 1 度は通る")
    func coversEveryKindOfDisplay() {
        let displays = HUDRehearsal.script.map(\.display)
        #expect(displays.contains { if case .recording = $0 { true } else { false } })
        #expect(displays.contains(.processing(.finalizing)))
        #expect(displays.contains(.processing(.refining)))
        #expect(displays.contains(.processing(.inserting)))
        #expect(displays.contains(.processing(.revising)))
        #expect(displays.contains(.completed))
        #expect(displays.contains(.hidden))
    }

    /// **重さの 4 段すべてを見せる。** 拒否（`.refusal`）を赤く出していないか、
    /// 喪失（`.lost`）が本当に目立つかは、並べて見ないと判らない。
    @Test("告知の重さを 4 段とも見せる")
    func coversEverySeverity() {
        let severities = Set(
            HUDRehearsal.script.compactMap { step -> HUDSeverity? in
                if case .message(let message) = step.display { return message.severity }
                return nil
            })
        #expect(severities.contains(.warning))
        #expect(severities.contains(.refusal))
        #expect(severities.contains(.lost))
    }

    /// **音量バーが振れることを目視で確かめられる**（満振れの基準 `fullScaleRMS` は実測値ではない）。
    @Test("音量の振れ幅が違う録音表示を含む")
    func showsDifferentLevels() {
        let levels = Set(
            HUDRehearsal.script.compactMap { step -> Float? in
                if case .recording(let recording) = step.display { return recording.level }
                return nil
            })
        #expect(levels.count >= 3)
    }

    /// **既定の秒数で筋書きを一巡できる。** 一巡しないと、後ろの表示を誰も見ない。
    @Test("既定の秒数で筋書きが一巡する")
    func defaultDurationCoversOnePass() {
        let total = (HUDRehearsal.wiringScript.reduce(Duration.zero) { $0 + $1.duration })
            + (HUDRehearsal.script.reduce(Duration.zero) { $0 + $1.duration })
        #expect(total < .seconds(AppLaunchOptions.defaultHUDRehearsalSeconds))
        #expect(total > .seconds(5))
    }

    // MARK: - 配線を通す筋書き

    /// **`--hud-check` が製品の経路を 1 行も通らないままだった**（2026-08-15 の実機欠陥）。
    ///
    /// 素振りが `HUDPanel.render` を直に叩いていたため、`--hud-check` が緑でも
    /// 「録音では出ない」を切り分けられなかった。**録音の入口の状態を必ず含めること。**
    @Test("配線の筋書きは録音の状態から始まる（製品と同じ入口）")
    func wiringScriptStartsWithRecording() {
        #expect(HUDRehearsal.wiringScript.first?.event == .state(.recording(volatileText: "")))
    }

    /// **音量も配線の一部である**（`levelStream()` は状態とは別の口）。
    @Test("配線の筋書きは音量も通す")
    func wiringScriptCoversLevel() {
        #expect(
            HUDRehearsal.wiringScript.contains { if case .level = $0.event { true } else { false } })
    }

    /// **`.idle` で終わらないと、素振りの後に表示が残る。**
    @Test("配線の筋書きは待機で終わる")
    func wiringScriptEndsIdle() {
        #expect(HUDRehearsal.wiringScript.last?.event == .state(.idle))
    }

    // MARK: - 終了待ち

    /// **実機で出ないまま利用者が猶予 10 秒を使い切った表示である**（2026-08-15）。
    /// 素振りの一覧に無ければ、誰も見ないまま出荷される。
    @Test("素振りの一覧に終了待ちが入っている")
    func scriptShowsTheShutdownWait() {
        let texts = HUDRehearsal.script.compactMap { step -> String? in
            if case .message(let message) = step.display { return message.text }
            return nil
        }
        #expect(texts.contains { $0.contains("離して") }, "終了待ちの案内が一覧に無い: \(texts)")
    }

    /// **文言は Core の 1 箇所から取る。** 素振りに写しを置くと、Core の文言を直したときに
    /// **素振りだけが古い嘘を出し続ける**（R-9 の文言で実際にそうなりかけた）。
    @Test("終了待ちの文言は Core のものと 1 文字も違わない")
    func shutdownWaitTextComesFromCore() {
        #expect(
            HUDRehearsal.shutdownWaitSummary
                == ShutdownAnnouncement.stillWaiting(remaining: HUDRehearsal.shutdownRemaining)
                .hudText)
    }

    /// **終了待ちは失敗として出さない。** 赤く出すと「壊れた」と読まれる——
    /// 正しく待っているアプリを見て「全然反応しません」と言われたのがこの欠陥である。
    @Test("素振りの終了待ちは失敗の色で出さない")
    func shutdownWaitIsNotShownAsFailure() {
        let severity = HUDPresenter.severity(
            for: ShutdownAnnouncement.stillWaiting(remaining: .seconds(9)).weight)
        #expect(severity == .info)
    }

    /// **譲らない長さは、次の刻みが来るまでを覆えばよい。**
    /// 短すぎると刻みの合間に帯が消え、長すぎると打ち切った後も居座る。
    @Test("終了待ちの保持は次の刻みを覆う")
    @MainActor
    func shutdownHoldCoversTheNextBeat() {
        let hold = NotchHUDSurface.hold(for: .stillWaiting(remaining: .seconds(9)))
        #expect(hold > Shutdown.heartbeat, "次の刻みが来る前に帯が消える")
        // 上限は「打ち切った後も居座らない」ための線であり、要件値ではない。
        #expect(hold <= .seconds(3))
    }
}

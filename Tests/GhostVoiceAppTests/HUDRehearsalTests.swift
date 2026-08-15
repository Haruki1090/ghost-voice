import Foundation
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
        let first = try? #require(HUDRehearsal.wiringScript.first)
        #expect(first?.event == .state(.recording(volatileText: "")))
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
}

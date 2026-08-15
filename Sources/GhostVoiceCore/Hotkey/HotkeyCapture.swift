import CoreGraphics
import Foundation

/// 捕獲した打鍵（FR-11）。**まだ `HotkeyBinding` ではない。**
///
/// **ここで妥当性を判定しない。** 不変条件（キーコードの範囲・修飾キー単独の表）は
/// `HotkeyBinding.init(keyCode:modifiers:)` が唯一の持ち主である
/// （`HotkeyBinding` の doc / 詳細設計書 §14）。**2 箇所に分かれると必ずずれる。**
/// 設定画面はこの値を `HotkeyBinding` へ通し、投げられた `HotkeyBindingError` を
/// そのまま利用者への説明に使うこと。
public struct CapturedHotkey: Sendable, Equatable {
    public let keyCode: Int64
    public let modifiers: HotkeyBinding.Modifiers

    public init(keyCode: Int64, modifiers: HotkeyBinding.Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// 捕獲モードが 1 件のイベントを見た結果。
public enum HotkeyCaptureOutcome: Sendable, Equatable {
    /// まだ決まらない（修飾キーを押している最中など）。**捕獲モードは続く。**
    case pending
    /// 捕まえた。**捕獲モードはここで終わる。**
    case captured(CapturedHotkey)
    /// 利用者が ESC で取り消した。**捕獲モードはここで終わる。**
    ///
    /// - Note: **したがって ESC は捕獲では割り当てられない。**
    ///   規則としては ESC を PTT に割り当てられる（`HotkeyDecision.decide` は
    ///   バインドを ESC より先に見る）ので、`settings.json` の手編集では可能である。
    ///   捕獲の側で取り消しに使うのは、**押した瞬間に取り消せる口が他に無い**ためで、
    ///   「ESC を割り当てられない」より「捕獲から抜けられない」ほうが害が大きい。
    case cancelled
}

/// **打鍵の捕獲（FR-11「ホットキーを設定画面から変更できる」）の判定。**
///
/// ## なぜ 2 本目の `CGEventTap` を立てないか（統括の裁定）
///
/// 判定は 1 打鍵あたり実測 p50 0.75 μs で、**これはシステム全体の打鍵に乗る**
/// （詳細設計書 §2.5）。2 本目を立てると単純に 2 倍になり、それは
/// **設定画面を開いていない間もずっと払い続ける代償**である。
/// したがって捕獲は**既存の `HotkeyMonitor` を「捕獲モード」へ入れる**形で行う。
///
/// `NSEvent.addLocalMonitorForEvents` も採らない。ローカルモニタは
/// **自分のアプリがキーウィンドウのときにしか届かない**——それ自体は設定画面の
/// 条件を満たすが、**同じ打鍵を `CGEventTap` と 2 箇所で見る**ことに変わりはなく、
/// 捕獲中に PTT が同時に発火する経路が残る（統括の裁定が禁じたのはこの形である）。
///
/// ## 捕獲中は PTT も Undo も ESC の中断も発火しない
///
/// 判定は `HotkeyDecision.decide` を**一度も通らない**（`CGEventTapHotkeyMonitor.handle`
/// が捕獲モードを先に見て、そこで戻る）。キーを設定しようとして録音が始まると
/// 設定画面は使えないので、これは要件である。
///
/// ## 押下ではなく「離した瞬間」で決める理由（修飾キーのとき）
///
/// PTT の既定は**修飾キー単独**（右 Option）であり、修飾キーは `keyDown` を出さない
/// ので `flagsChanged` を見るしかない。ところが押下で確定すると、
/// **⌃⌘Z のような組を入力できない**——⌃ を押した時点で「左 Control」として
/// 確定してしまう。そこで:
///
/// | 入力 | どう決まるか |
/// |---|---|
/// | 修飾キーを 1 つだけ押して離す | **離した瞬間**に「修飾キー単独」として確定 |
/// | 修飾キー + 文字キー | **文字キーの押下**で確定（そのとき立っている修飾キーを添える） |
/// | 修飾キーを 2 つ以上押して離す | **確定しない**（`HotkeyBinding` が認めない組なので、捕獲の側で作らせない） |
///
/// - Important: **`.flagsChanged` は決して抑止しない。** 抑止すると下流アプリが
///   修飾状態を見失い、⌥+矢印などが壊れる（`HotkeyDecision.pushToTalk` と同じ判断）。
///   抑止するのは確定させた `keyDown` と ESC の `keyDown` だけである。
/// - Note: **抑止した押下に対応する `keyUp` は下流へ届きうる**（バインドが修飾キー単独の
///   ときタップのマスクに `keyUp` が入っていないため）。文字キーの単独の `keyUp` を
///   意味づけるアプリは稀なので、配送量を倍にしてまで塞ぐ価値は無い
///   ——`HotkeyDecision.undo` が同じ理由で同じ判断をしている。
public struct HotkeyCaptureState: Sendable, Equatable {

    /// いま単独で押されている修飾キーの仮想キーコード。
    /// **「離したら確定してよい」候補**であり、2 つ目の修飾キーが来ると消える。
    private var heldModifierKeyCode: Int64?
    /// この押下の連なりの中で、修飾キー以外の打鍵を見たか。
    private var sawOtherKey = false

    public init() {}

    /// 1 件のイベントを見る。**純粋な状態遷移で、時計も I/O も持たない。**
    ///
    /// - Returns: 決着と、そのイベントを抑止するか。
    public mutating func consume(
        type: CGEventType, keyCode: Int64, flags: CGEventFlags
    ) -> (outcome: HotkeyCaptureOutcome, suppress: Bool) {
        switch type {
        case .flagsChanged:
            return (consumeFlagsChanged(keyCode: keyCode, flags: flags), false)

        case .keyDown:
            if keyCode == HotkeyDecision.escapeKeyCode {
                reset()
                // **取り消しの ESC は下流へ渡さない。** 設定画面が前面に居るので、
                // 渡すと窓が閉じるなどの二重の反応になる。
                return (.cancelled, true)
            }
            sawOtherKey = true
            heldModifierKeyCode = nil
            let captured = CapturedHotkey(
                keyCode: keyCode, modifiers: HotkeyBinding.Modifiers(cgEventFlags: flags))
            reset()
            // **確定させた打鍵は下流へ渡さない。** 渡すと、設定画面の入力欄へ
            // その文字が入る（＝キーを設定しようとして文字を打ったことになる）。
            return (.captured(captured), true)

        default:
            // `.keyUp` と、タップの無効化通知。**捕獲は何も決めない。**
            return (.pending, false)
        }
    }

    private mutating func consumeFlagsChanged(
        keyCode: Int64, flags: CGEventFlags
    ) -> HotkeyCaptureOutcome {
        guard let own = HotkeyBinding.ownModifier(forKeyCode: keyCode) else {
            // 修飾キーの表に無いキーコードの `flagsChanged`（Caps Lock / Fn など）。
            // **候補にしない。** `HotkeyBinding` が認めないので、捕まえても保存できない。
            heldModifierKeyCode = nil
            return .pending
        }

        let isDown = HotkeyDecision.isModifierDown(
            keyCode: keyCode, flags: flags, fallback: own.cgEventFlags)
        let now = HotkeyBinding.Modifiers(cgEventFlags: flags)

        if isDown {
            // **単独で押されているときだけ候補にする。**
            // ⌃ を押した後に ⌘ を押すと、ここで候補が消えて `keyDown` 待ちになる。
            heldModifierKeyCode = (now == own) ? keyCode : nil
            return .pending
        }

        let wasCandidate = (heldModifierKeyCode == keyCode)
        heldModifierKeyCode = nil
        if now.isEmpty {
            // 修飾キーがすべて離れた。次の連なりのために忘れる。
            defer { sawOtherKey = false }
            guard wasCandidate, !sawOtherKey else { return .pending }
            reset()
            return .captured(CapturedHotkey(keyCode: keyCode, modifiers: own))
        }
        return .pending
    }

    private mutating func reset() {
        heldModifierKeyCode = nil
        sawOtherKey = false
    }
}

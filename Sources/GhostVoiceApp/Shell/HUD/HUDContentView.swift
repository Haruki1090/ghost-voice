import Observation
import SwiftUI

/// 描画の入力。**`HUDPanel` だけが書き換える。**
///
/// `SessionMirror` を直接見ないのは、**暫定テキストの更新のたびにミラーが変わる**ためである。
/// ミラーを `body` から読むと、間引き（`HUDPresenter`）を通す前の更新でも再描画が走る。
/// ここへ入るのは既に間引かれた結果だけで、しかも `HUDDisplay` は `Equatable` なので、
/// **本当に変わったときにしか再描画されない。**
@MainActor
@Observable
final class HUDModel {
    var display: HUDDisplay = .hidden
    /// 切り欠きの帯の高さ（フォールバック表示では 0）。**中身はここより下にしか置かない。**
    var notchBandHeight: CGFloat = 0
    /// 画面の上辺（＝切り欠き）へ吸い付いているか。偽ならメニューバーの下に浮かべる。
    var isAttachedToScreenTop = false
    /// **いまの島の大きさ。** 窓の大きさではない（窓は最大の島が収まる固定寸法）。
    var islandSize: CGSize = .zero
    /// **形が変わるときにアニメーションするか。**
    ///
    /// 偽にするのは**出し入れの瞬間だけ**である。出しっぱなしのときは真のまま——
    /// 出す前の大きさから伸びていく様子は、窓が画面に無い間に起きるので誰も見ない。
    var animatesShape = false
}

/// **ダイナミックアイランド風の HUD。**
///
/// ## 形
///
/// ```
///        ┌ 画面の上辺（frame.maxY = 実測 1169）
///        ↓
///  ─────╮                       ╭─────   ← 逆アール（メニューバーの帯へ繋ぐ）
///       │  ┌───────────┐        │
///       │  │  切り欠き  │        │        ← **切り欠きは島の黒の中に埋まる**
///       │  └───────────┘        │
///       │   音量 言語 暫定文字   │        ← 中身はすべて帯より下（最大 3 行）
///       ╰───────────────────────╯
/// ```
///
/// **切り欠きに画素があるかは未実測のまま**でよい（V-20）。島は切り欠きの
/// **周囲を黒く塗る**ので、中に画素があれば繋がって塗られ、無ければ物理的に黒い——
/// **どちらでも 1 枚の黒い面に見える。** 中身は帯より下にしか置かないので読めなくならない。
///
/// ## メインスレッドの予算（§7.4）
///
/// **アニメーションは `islandSize` が変わったときにしか走らない。**
/// 暫定テキストは 50 ms ごとに届くが、**幅も高さも 2 通りしか取らない**ので、
/// 1 発話あたり形が変わるのは数回である。**継続アニメーション（回り続ける印など）は 1 つも無い。**
struct HUDContentView: View {

    let model: HUDModel

    var body: some View {
        ZStack(alignment: .top) {
            // **窓は島より大きい。** 島の外は塗らない（メニューバーを透かす）。
            Color.clear
            island
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // **見るのは `islandSize` だけ。** 暫定テキストが変わっただけでは何も動かない。
        .animation(
            model.animatesShape ? .smooth(duration: HUDIslandMetrics.expansionSeconds) : nil,
            value: model.islandSize)
    }

    @ViewBuilder
    private var island: some View {
        ZStack(alignment: .top) {
            HUDIslandShape(
                screenEdgeRadius: model.isAttachedToScreenTop
                    ? HUDIslandMetrics.screenEdgeCornerRadius : 0,
                floatingTopRadius: HUDIslandMetrics.floatingTopCornerRadius,
                bottomRadius: HUDIslandMetrics.bottomCornerRadius
            )
            .fill(Color.black)

            VStack(spacing: 0) {
                // **切り欠きの帯には何も描かない**（画素が無いかもしれない）。
                Color.clear.frame(height: model.notchBandHeight)
                content
                    .padding(
                        .horizontal,
                        HUDIslandMetrics.contentInset(
                            isAttachedToScreenTop: model.isAttachedToScreenTop)
                    )
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: model.islandSize.width, height: model.islandSize.height)
    }

    @ViewBuilder
    private var content: some View {
        switch model.display {
        case .hidden:
            EmptyView()
        case .recording(let recording):
            HStack(spacing: 8) {
                HUDLevelBar(level: recording.level)
                Text(recording.languageBadge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                if recording.volatileText.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    Text(recording.volatileText)
                        .font(.system(size: HUDIslandMetrics.volatileFontSize))
                        .foregroundStyle(Color.white.opacity(0.85))
                        // **複数行見せる**（利用者の「1 行分しか見えない」への対応）。
                        // 上限を置くのは、長い発話で高さが伸び続けないためである。
                        .lineLimit(HUDIslandMetrics.volatileLineLimit)
                        .multilineTextAlignment(.leading)
                        // **末尾を見せる。** 暫定テキストは伸びていくので、
                        // 先頭を残すと「いま何を喋っているか」が見えない。
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .processing(let processing):
            HStack(spacing: 6) {
                HUDDots()
                Text(processing.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .opacity(processing.isSubdued ? 0.55 : 1)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.green)
        case .message(let message):
            HStack(spacing: 6) {
                Image(systemName: message.severity.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(message.text)
                    .font(.system(size: HUDIslandMetrics.volatileFontSize))
                    .lineLimit(HUDIslandMetrics.volatileLineLimit)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(message.severity.tint)
        }
    }
}

extension HUDSeverity {
    var symbolName: String {
        switch self {
        case .info: "info.circle"
        case .refusal: "lock.fill"
        case .warning: "exclamationmark.triangle"
        case .lost: "exclamationmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        // **拒否は「エラー」として赤く出さない**（`SessionFailureNotice.isRefusal`）。
        // secure input で挿入しなかったのは意図した動作である。
        case .info, .refusal: Color.white.opacity(0.85)
        case .warning: Color.yellow
        case .lost: Color.orange
        }
    }
}

/// 音量バー。**5 本の固定した棒の点灯数だけが変わる。**
/// 高さを連続に変えないのは、`.volatile` の更新ごとにレイアウトを走らせないためである。
struct HUDLevelBar: View {
    let level: Float
    private static let barCount = 5

    var body: some View {
        let lit = HUDLevelMeter.litBars(level, count: Self.barCount)
        HStack(spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.white.opacity(index < lit ? 0.95 : 0.22))
                    .frame(width: 3, height: 6 + CGFloat(index) * 3)
            }
        }
        .frame(height: 18, alignment: .bottom)
    }
}

/// 処理中の印。**動かさない**（継続アニメーションを 1 つも置かないという規律。§7.4）。
struct HUDDots: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(0.9 - Double(index) * 0.25))
                    .frame(width: 4, height: 4)
            }
        }
    }
}

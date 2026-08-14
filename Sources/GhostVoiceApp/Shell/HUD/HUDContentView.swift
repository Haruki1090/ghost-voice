import Observation
import SwiftUI

/// 描画の入力。**1 つの値しか持たない。**
///
/// `SessionMirror` を直接見ないのは、**暫定テキストの更新のたびにミラーが変わる**ためである。
/// ミラーを `body` から読むと、間引き（`HUDPresenter`）を通す前の更新でも再描画が走る。
/// ここへ入るのは既に間引かれた結果だけで、しかも `HUDDisplay` は `Equatable` なので、
/// **本当に変わったときにしか再描画されない。**
@MainActor
@Observable
final class HUDModel {
    var display: HUDDisplay = .hidden
    /// 切り欠きの帯の高さ（フォールバック表示では 0）。
    var notchBandHeight: CGFloat = 0
    /// 切り欠きの幅。**帯のうち黒く塗ってよいのはここだけ**（左右にはメニューバーが居る）。
    var notchBandWidth: CGFloat = 0
}

/// notch の直下に出す帯。
///
/// ## 形（実測に基づく決めごと）
///
/// ```
///  ┌────────┬─────┬────────┐   ← 画面の一番上（frame.maxY）
///  │ 透明   │ 黒  │ 透明   │   ← 切り欠きの帯（高さ = safeAreaInsets.top = 実測 38）
///  ├────────┴─────┴────────┤      左右は**メニューバーが居る**ので塗らない
///  │        中  身         │   ← 切り欠きより下。ここは横へ広げてよい
///  └───────────────────────┘
/// ```
///
/// **切り欠きそのものに画素があるかは未実測である**（V-20）。
/// 中身をすべて帯より下に置いてあるので、**画素が無くても表示は成立する。**
/// 帯の黒は「切り欠きと連続して見せる」ためだけのもので、見えなくても失うものは無い。
struct HUDContentView: View {

    let model: HUDModel

    var body: some View {
        VStack(spacing: 0) {
            if model.notchBandHeight > 0 {
                HStack(spacing: 0) {
                    Color.clear
                    Color.black.frame(width: model.notchBandWidth)
                    Color.clear
                }
                .frame(height: model.notchBandHeight)
            }
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // **アニメーションを掛けない。** メインスレッドを塞ぐと `CGEventTap` の配送が
        // 悪化する（実測 p50 0.045 ms → 12.8 ms）。PTT の押下・解放の検知が鈍るほうが、
        // 見た目が素っ気ないことより重い。
        .animation(nil, value: model.display)
    }

    @ViewBuilder
    private var card: some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 12,
                bottomTrailingRadius: 12, topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
            content
                .padding(.horizontal, 10)
        }
        .frame(height: HUDMetrics.contentHeight)
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
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(2)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.green)
        case .message(let message):
            HStack(spacing: 6) {
                Image(systemName: message.severity.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(message.text)
                    .font(.system(size: 11))
                    .lineLimit(2)
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

/// 処理中の印。**動かさない**（`HUDContentView` の `animation(nil)` と同じ理由）。
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

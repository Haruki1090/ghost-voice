import GhostVoiceCore
import SwiftUI

/// 履歴画面（FR-9）。
///
/// **提示（どの窓・どのメニューから開くか、再挿入の前に窓を閉じること）は
/// `HistoryViewModel` の doc コメントに書いてある。配線は統合時に行う。**
public struct HistoryView: View {

    private let model: HistoryViewModel
    /// 再挿入を押されたとき、**この画面を閉じて前面を返す**ための口。
    ///
    /// **`nil` なら再挿入のボタンを出さない。** 窓を閉じられない文脈で挿入すると、
    /// 挿入先が Ghost Voice 自身になる（`HistoryViewModel.reinsert` の注記）。
    /// **押せてしまう形にしないことで、順序の間違いを構造で防ぐ。**
    private let dismissAndReturnFocus: (@MainActor () async -> Void)?

    @State private var confirmingDeleteAll = false

    public init(
        model: HistoryViewModel,
        dismissAndReturnFocus: (@MainActor () async -> Void)? = nil
    ) {
        self.model = model
        self.dismissAndReturnFocus = dismissAndReturnFocus
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.entries.isEmpty {
                emptyState
            } else {
                List(model.entries) { entry in
                    row(entry)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .task { model.start() }
        .confirmationDialog(
            "履歴をすべて削除しますか？", isPresented: $confirmingDeleteAll
        ) {
            Button("すべて削除", role: .destructive) {
                Task { await model.deleteAll() }
            }
        } message: {
            Text("戻せなくなります。Undo の対象も無くなります。")
        }
    }

    // MARK: - 部品

    @ViewBuilder
    private var header: some View {
        if let notice = model.fileNotice {
            VStack(alignment: .leading, spacing: 4) {
                Label(notice.headline, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(notice.remedy).font(.caption).textSelection(.enabled)
            }
            .padding()
        }
    }

    /// **「まだ喋っていない」と「読めなかった」を同じ画面で区別する。**
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(model.fileNotice == nil ? "履歴はまだありません" : "履歴を読み込めませんでした")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.timestamp, format: .dateTime.month().day().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.localeIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(methodLabel(entry.insertionMethod))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }
            if let refined = entry.refinedText {
                Text(refined).textSelection(.enabled)
                Text(entry.rawText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text(entry.rawText).textSelection(.enabled)
            }
            HStack {
                Button("整形前をコピー") { model.copy(entry, field: .raw) }
                Button("挿入したものをコピー") { model.copy(entry, field: .inserted) }
                    .disabled(entry.refinedText == nil)
                if let dismissAndReturnFocus {
                    Button("再挿入") {
                        Task {
                            // **窓を閉じて前面が戻ってから挿入する。** 順序が逆だと
                            // 挿入先が Ghost Voice 自身になる。
                            await dismissAndReturnFocus()
                            await model.reinsert(entry, field: .inserted)
                        }
                    }
                }
                Spacer()
                Button("削除", role: .destructive) {
                    Task { await model.delete(entry) }
                }
                .buttonStyle(.borderless)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Text(tallyText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("すべて削除", role: .destructive) { confirmingDeleteAll = true }
                .disabled(model.entries.isEmpty)
        }
        .padding()
    }

    /// **`.notInserted` を分母から外していることを、画面にも書く。**
    /// 数字だけ出すと、一覧の件数と合わない理由が判らない。
    private var tallyText: String {
        let tally = model.tally
        var text =
            "上限 \(model.limit) 件 / 挿入経路 \(tally.insertedTotal) 件"
            + "（AX \(tally.ax) / Pasteboard \(tally.pasteboard) / クリップボードのみ \(tally.clipboardOnly)）"
        if tally.notInsertedExcluded > 0 {
            text += " ・中断した \(tally.notInsertedExcluded) 件は挿入経路を通っていないので集計から除いています"
        }
        return text
    }

    private func methodLabel(_ method: InsertionMethod) -> String {
        switch method {
        case .ax: "AX"
        case .pasteboard: "Pasteboard"
        case .clipboardOnly: "クリップボードのみ"
        case .notInserted: "中断（未挿入）"
        }
    }
}

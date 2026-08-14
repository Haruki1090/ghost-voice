import GhostVoiceCore
import SwiftUI

/// 設定画面（FR-11）。
///
/// **提示（どの窓・どのメニューから開くか）は `SettingsViewModel` の doc コメントに
/// 書いてある。配線は統合時に行う。** この型は「描くこと」しか知らない。
///
/// ## 打鍵の捕まえ方について
///
/// **ここには打鍵を捕まえる仕掛けを入れていない。** `NSEvent` のローカルモニタで
/// 捕まえる形になるが、**PTT の既定が修飾キー単独（右 Option）なので `keyDown` では
/// 捕まらず、`flagsChanged` を見る必要がある**（`HotkeyBinding.isModifierOnly` の注記）。
/// これは `CGEventTap` を張っている `HotkeyMonitor` と**同じイベントを 2 箇所で
/// 見ることになる**ため、実機で干渉しないことを確かめてから足すべきである
/// （報告書に検証項目として起こしてある）。
///
/// それまでの間、キーの変更は次の 2 つで行える:
/// - `settings.json` を手で編集する（**不正な組は読めなくなり、この画面が理由を出す**）
/// - `SettingsViewModel.setHotkey(keyCode:modifiers:)` を呼ぶ配線を足す
public struct SettingsView: View {

    @Bindable private var model: SettingsViewModel

    public init(model: SettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            fileNoticeSection
            hotkeySection
            recognitionSection
            refinementSection
            historySection
            vocabularySection
            saveSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
    }

    // MARK: - 読めなかったファイルの告知（統括の裁定の条件）

    /// **いちばん上に置く。** 全設定が既定へ戻っている状態で、下の項目を先に
    /// 読ませてはならない（利用者は「自分が設定した値」だと思って読む）。
    @ViewBuilder
    private var fileNoticeSection: some View {
        if !model.fileNotices.isEmpty {
            Section {
                ForEach(model.fileNotices) { notice in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(notice.headline, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.headline)
                        Text(notice.remedy)
                            .font(.callout)
                            .textSelection(.enabled)
                        if let hint = notice.hint {
                            Text(hint).font(.callout).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("読み込みが失敗した理由") {
                            Text(notice.reason)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("設定ファイルを読み込めませんでした")
            }
        }
    }

    // MARK: - ホットキー

    private var hotkeySection: some View {
        Section("ホットキー") {
            LabeledContent("PTT（押している間だけ録音）") {
                Text(HotkeyLabel.text(for: model.draft.hotkey)).monospaced()
            }
            LabeledContent("Undo（整形前へ戻す）") {
                Text(HotkeyLabel.text(for: model.draft.undoHotkey)).monospaced()
            }
            // **衝突の判定は `Settings.validateHotkeys()` の答えそのもの。**
            // 画面はここで条件を書き直していない。
            if model.hotkeyConflict != nil {
                Label(
                    "Undo キーが PTT キーの修飾キーを含んでいます。このままでは押すと録音が始まるため、保存できません。",
                    systemImage: "xmark.octagon.fill"
                )
                .foregroundStyle(.red)
            }
        }
    }

    // MARK: - 認識

    private var recognitionSection: some View {
        Section("認識") {
            Picker("言語", selection: $model.draft.localeIdentifier) {
                ForEach(SettingsViewModel.suggestedLocaleIdentifiers, id: \.self) { identifier in
                    Text(identifier).tag(identifier)
                }
                // 手編集で別のロケールが入っている場合も選択を失わないようにする。
                if !SettingsViewModel.suggestedLocaleIdentifiers.contains(
                    model.draft.localeIdentifier)
                {
                    Text(model.draft.localeIdentifier).tag(model.draft.localeIdentifier)
                }
            }
            Picker("認識モジュール", selection: $model.draft.transcriberKind) {
                ForEach(TranscriberKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            Text("言語と認識モジュールの切り替えは、**保存したときに**認識器を作り直します。発話の処理中は切り替えられません。モデルが未導入の言語では導入に数分かかります。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 整形

    private var refinementSection: some View {
        Section("整形") {
            Toggle("LLM で整形する", isOn: $model.draft.refinementEnabled)
            Picker("反映のしかた", selection: $model.draft.refinementApplyMode) {
                Text("先に生テキストを挿入して後から差し替える").tag(RefinementApplyMode.afterInsert)
                Text("整形を待ってから挿入する").tag(RefinementApplyMode.beforeInsert)
            }
            .pickerStyle(.inline)
            Stepper(
                "整形の打ち切り: \(model.draft.refinementTimeoutMs) ms",
                value: $model.draft.refinementTimeoutMs, in: 100...3000, step: 50)
            Text("打ち切りが効くのは「整形を待ってから挿入する」経路だけです。長くすると、発話終了からテキストが出るまでの時間がそのぶん延びます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 履歴

    private var historySection: some View {
        Section("履歴") {
            Stepper(
                "保存件数: \(model.draft.historyLimit) 件",
                value: $model.draft.historyLimit, in: 0...500, step: 10)
            Text("0 にすると履歴を残しません。**Undo と、挿入に失敗したときの退避先も無くなります。**")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - ユーザー辞書

    private var vocabularySection: some View {
        Section("ユーザー辞書（\(model.vocabularyTerms.count) / \(VocabularyStore.maxTerms) 件）") {
            ForEach(Array(model.vocabularyTerms.enumerated()), id: \.offset) { index, term in
                HStack {
                    Text(term.canonical)
                    if !term.misheard.isEmpty {
                        Text("← " + term.misheard.joined(separator: " / "))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("削除", role: .destructive) {
                        model.vocabularyTerms.remove(at: index)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("項目を追加") {
                model.vocabularyTerms.append(VocabularyTerm(canonical: ""))
            }
        }
    }

    // MARK: - 保存

    private var saveSection: some View {
        Section {
            if let outcome = model.lastSave {
                Label(
                    outcome.message,
                    systemImage: outcome.isFailure
                        ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                )
                .foregroundStyle(outcome.isFailure ? .red : .green)
            }
            HStack {
                Button("元に戻す") { model.discard() }
                    .disabled(!model.hasUnsavedChanges || model.isSaving)
                Spacer()
                Button("保存") {
                    Task { await model.save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSaving || model.hotkeyConflict != nil)
            }
            if model.isSaving {
                ProgressView("保存しています（言語を変えた場合、モデルの導入に数分かかることがあります）")
            }
        }
    }
}

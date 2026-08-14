import GhostVoiceCore
import SwiftUI

/// 設定画面（FR-11）。
///
/// **提示（どの窓・どのメニューから開くか）は `SettingsViewModel` の doc コメントに
/// 書いてある。配線は `StatusMenuSurface` が行う。** この型は「描くこと」しか知らない。
///
/// ## 打鍵の捕まえ方（**2 本目の `CGEventTap` を立てない**）
///
/// PTT の既定は修飾キー単独（右 Option）なので `keyDown` では捕まらず、
/// `flagsChanged` を見る必要がある。**`NSEvent` のローカルモニタは採らない**——
/// それでは `CGEventTap` と同じ打鍵を 2 箇所で見ることになり、
/// **捕獲中に PTT が同時に発火する経路が残る。**
///
/// 代わりに、**既存の `HotkeyMonitor` を「捕獲モード」へ入れる**
/// （`HotkeyMonitor.beginHotkeyCapture` / `HotkeyCaptureState`。統括の裁定）。
/// 判定は 1 打鍵あたり実測 p50 0.75 μs で**全システムの打鍵に乗る**ので、
/// 2 本目を立てると設定画面を開いていない間もずっと 2 倍を払うことになる。
///
/// **捕獲中は PTT も Undo も ESC の中断も発火しない。**
/// キーの変更は `settings.json` の手編集でも従来どおり行える
/// （**不正な組は読めなくなり、この画面が理由を出す**）。
public struct SettingsView: View {

    @Bindable private var model: SettingsViewModel

    public init(model: SettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            fileNoticeSection
            hotkeyFailureSection
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

    // MARK: - キー監視が動いていないことの告知（HUD との棲み分け）

    /// **HUD は 1 行で「気づかせる」、ここは全文で「直させる」**
    /// （`SettingsViewModel.hotkeyFailure` の doc）。
    @ViewBuilder
    private var hotkeyFailureSection: some View {
        if let failure = model.hotkeyFailure {
            Section {
                Text(AppPermissionGuidance.message(for: failure))
                    .font(.callout)
                    .textSelection(.enabled)
                Text("この状態では、下のホットキーを変えても押しても反応しません。**打鍵の捕獲もできません。**")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("キー入力を監視できていません", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - ホットキー

    private var hotkeySection: some View {
        Section("ホットキー") {
            hotkeyRow("PTT（押している間だけ録音）", binding: model.draft.hotkey, field: .pushToTalk)
            hotkeyRow("Undo（整形前へ戻す）", binding: model.draft.undoHotkey, field: .undo)

            if let message = model.captureMessage {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.capturingField != nil {
                // **捕獲中であることを必ず出す。** 出さないと、PTT が発火しないぶん
                // 利用者には「壊れた」としか見えない。
                Text("いま打鍵を待っています。**この間は録音も Undo も起きません。** ESC で取りやめます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func hotkeyRow(
        _ title: String, binding: HotkeyBinding, field: SettingsViewModel.HotkeyField
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Text(HotkeyLabel.text(for: binding)).monospaced()
                if model.capturingField == field {
                    Button("取りやめる") { model.cancelCapture() }
                } else {
                    Button("変更…") { model.beginCapture(field) }
                        .disabled(model.capturingField != nil)
                }
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
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField(
                            "正しい表記",
                            text: Binding(
                                get: { term.canonical },
                                set: { model.setCanonical($0, at: index) })
                        )
                        Spacer()
                        Button("削除", role: .destructive) { model.removeTerm(at: index) }
                            .buttonStyle(.borderless)
                    }
                    // **誤認識表記を編集できることが FR-11 の要件である。**
                    // ここが編集できないと、FR-6（誤認識の修正）に何も入力できない。
                    TextField(
                        "誤認識されやすい表記（\(MisheardListText.separator.trimmingCharacters(in: .whitespaces)) で区切る）",
                        text: Binding(
                            get: { model.misheardText(at: index) },
                            set: { model.setMisheard($0, at: index) })
                    )
                    .font(.callout)
                }
                .padding(.vertical, 2)
            }
            Button("項目を追加") { model.addTerm() }
            Text("正しい表記は整形プロンプトへ毎回注入されます。**誤認識表記は「この語をこう直せ」の手掛かり**であり、整形が頼まれた置換かどうかを判定する根拠にもなります（FR-6）。")
                .font(.caption)
                .foregroundStyle(.secondary)
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

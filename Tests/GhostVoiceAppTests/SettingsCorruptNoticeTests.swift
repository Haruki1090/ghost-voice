import Foundation
import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

/// **統括の裁定の条件を、検査で固定する。**
///
/// > `Ruling: 採用する。…**条件: 設定画面（トラックD）が、この事実を利用者へ見える形にすること。**
/// >  無言で既定へ戻ると、フェーズ1で潰した「成功と記録されるのに中身が違う」と同じ形になる`
///
/// 不正なホットキーを 1 つ含むだけで `settings.json` は**丸ごと**読めなくなり、
/// **全設定が既定値へ戻る。** その事実が画面に出ることと、`.corrupt` への退避が
/// **いつ**起きるかが正しく告げられることを見る。
@Suite("設定画面: 読めなかった設定ファイルの告知と .corrupt 退避")
@MainActor
struct SettingsCorruptNoticeTests {

    /// PTT（右 Option）と修飾キーが衝突する Undo キーを持つ、**構文としては正しい** JSON。
    ///
    /// **壊れた JSON ではないことが要点である。** カンマの打ち間違いではなく、
    /// 「規則に反する組み合わせ」でも同じ扱いになることを確かめる。
    private static let conflictingSettingsJSON = """
        {
          "historyLimit" : 50,
          "hotkey" : { "keyCode" : 61, "modifiers" : ["option"] },
          "localeIdentifier" : "en-US",
          "refinementEnabled" : true,
          "refinementTimeoutMs" : 750,
          "transcriberKind" : "dictation",
          "undoHotkey" : { "keyCode" : 6, "modifiers" : ["option", "command"] }
        }
        """

    @Test("不正なホットキーを含む settings.json は、読めなかったこととして画面に出る")
    func conflictingHotkeySurfacesAsNotice() throws {
        let temp = try SettingsHistoryTempDirectory()
        try temp.write(Self.conflictingSettingsJSON, to: "settings.json")

        let model = try makeModel(in: temp)

        let notice = try #require(model.fileNotices.first { $0.file == .settings })
        #expect(model.fileNotices.count == 1)
        // **「読めなかった」だけでは足りない。何が失われたかを同じ行に置く。**
        #expect(notice.headline.contains("settings.json"))
        #expect(notice.headline.contains("すべて既定値に戻っています"))
        // 心当たりの案内（ホットキーの規則）が付いている。
        #expect(notice.hint?.contains("Undo") == true)
        // 復元できなかった理由がそのまま読める。
        #expect(!notice.reason.isEmpty)

        // **実際に既定へ戻っている**ことも見る（告知だけあって中身が違う、を防ぐ）。
        #expect(model.draft.localeIdentifier == "ja-JP", "ファイルの en-US は生きていない")
    }

    @Test("退避はまだ起きていない（読み込みでは移らない）。画面はそれを正しく告げる")
    func quarantineIsPendingBeforeSave() throws {
        let temp = try SettingsHistoryTempDirectory()
        try temp.write(Self.conflictingSettingsJSON, to: "settings.json")

        let model = try makeModel(in: temp)
        let notice = try #require(model.fileNotices.first)

        #expect(notice.quarantine == .pending)
        #expect(temp.exists("settings.json"), "元のファイルはまだそこにある")
        #expect(!temp.exists("settings.json.corrupt"), "読み込みでは退避しない")
        // **「退避しました」と先に言わない。** 言うと利用者は .corrupt を探して見つけられない。
        #expect(notice.remedy.contains("まだ"))
        #expect(notice.remedy.contains("保存する前に開いて内容を控えて"))
    }

    @Test("保存すると .corrupt へ退避され、**その事実が画面に出る**")
    func saveQuarantinesAndReportsIt() async throws {
        let temp = try SettingsHistoryTempDirectory()
        try temp.write(Self.conflictingSettingsJSON, to: "settings.json")
        let model = try makeModel(in: temp)

        model.draft.historyLimit = 12
        await model.save()

        // 1. 顛末に載っている。
        #expect(model.lastSave == .saved(
            transcriberReloaded: false, undoHotkeyRebound: false, quarantined: [.settings]))
        #expect(model.lastSave?.message.contains(".corrupt へ退避") == true)

        // 2. 告知の状態が `.moved` へ変わり、案内文も変わる。
        let notice = try #require(model.fileNotices.first)
        #expect(notice.quarantine == .moved)
        #expect(notice.remedy.contains("退避してあります"))
        #expect(notice.remedy.contains("settings.json.corrupt"))

        // 3. **ディスクの実物がそうなっている。** 元の記述は失われていない。
        #expect(temp.exists("settings.json.corrupt"))
        let quarantined = try temp.text(of: "settings.json.corrupt")
        #expect(quarantined.contains("\"localeIdentifier\" : \"en-US\""))
        #expect(SettingsStore(rootURL: temp.url).settings.historyLimit == 12)
    }

    @Test("読めた設定では告知を出さない")
    func healthySettingsProduceNoNotice() throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)
        #expect(model.fileNotices.isEmpty)
    }

    @Test("辞書と履歴が読めなかったことも、それぞれ何が失われたかと共に出る")
    func vocabularyAndHistoryNoticesAreDistinct() throws {
        let temp = try SettingsHistoryTempDirectory()
        try temp.write("{ これは JSON ではない", to: "vocabulary.json")
        try temp.write("[ 壊れている", to: "history.json")

        let model = try makeModel(in: temp)
        let files = model.fileNotices.map(\.file)
        #expect(Set(files) == [.vocabulary, .history])

        let vocabulary = try #require(model.fileNotices.first { $0.file == .vocabulary })
        #expect(vocabulary.headline.contains("固有名詞"))
        #expect(vocabulary.hint == nil, "ホットキーの案内は設定ファイルにだけ出す")

        let history = try #require(model.fileNotices.first { $0.file == .history })
        #expect(history.headline.contains("履歴"))
    }

    @Test("**起きていない退避を「退避しました」と告げない**")
    func doesNotClaimQuarantineThatDidNotHappen() async throws {
        let temp = try SettingsHistoryTempDirectory()
        // 履歴だけが読めない。設定は健全。
        try temp.write("[ 壊れている", to: "history.json")
        let history = HistoryStore(rootURL: temp.url, limit: 50)
        let model = try makeModel(in: temp, history: history)

        // 上限を下げない保存（`setLimit` は内容が変わらないと 1 バイトも書かない）。
        model.draft.refinementTimeoutMs = 700
        await model.save()

        // history.json は書かれていないので退避もされていない。**告げてはならない。**
        #expect(model.lastSave == .saved(
            transcriberReloaded: false, undoHotkeyRebound: false, quarantined: []))
        #expect(model.fileNotices.first?.quarantine == .pending)
    }

    // MARK: - 道具

    private func makeModel(
        in temp: SettingsHistoryTempDirectory,
        history: HistoryStore? = nil
    ) throws -> SettingsViewModel {
        SettingsViewModel(
            settings: SettingsStore(rootURL: temp.url),
            vocabulary: VocabularyStore(rootURL: temp.url),
            history: history ?? HistoryStore(rootURL: temp.url, limit: 50),
            session: nil,
            directory: temp.url)
    }
}

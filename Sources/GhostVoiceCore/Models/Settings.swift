import Foundation

public enum SettingsError: Error, Equatable {
    /// Undo ホットキーが PTT キーの修飾キーと衝突している。
    ///
    /// 既定（PTT = 右 Option）では **⌥ を含む Undo キー**がこれに当たる。押すと
    /// 録音が始まってしまう（詳細設計書 §8.3）。
    case hotkeyConflict
}

public struct Settings: Codable, Sendable, Equatable {
    public var hotkey: HotkeyBinding
    public var undoHotkey: HotkeyBinding
    public var localeIdentifier: String
    public var transcriberKind: TranscriberKind
    public var refinementEnabled: Bool
    public var refinementTimeoutMs: Int
    public var historyLimit: Int

    public init(
        hotkey: HotkeyBinding = .rightOption,
        undoHotkey: HotkeyBinding = .controlCommandZ,
        localeIdentifier: String = "ja-JP",
        transcriberKind: TranscriberKind = .dictation,
        refinementEnabled: Bool = true,
        refinementTimeoutMs: Int = 750,
        historyLimit: Int = 50
    ) {
        self.hotkey = hotkey
        self.undoHotkey = undoHotkey
        self.localeIdentifier = localeIdentifier
        self.transcriberKind = transcriberKind
        self.refinementEnabled = refinementEnabled
        self.refinementTimeoutMs = refinementTimeoutMs
        self.historyLimit = historyLimit
    }

    public static let `default` = Settings()

    private enum CodingKeys: String, CodingKey {
        case hotkey, undoHotkey, localeIdentifier, transcriberKind
        case refinementEnabled, refinementTimeoutMs, historyLimit
    }

    /// **手編集した `settings.json` もここを通る。**
    ///
    /// 1 つのバインド単体の不変条件は `HotkeyBinding.init(from:)` が見る。ここでは
    /// **PTT と Undo の関係**（`validateHotkeys()`）を見る。どちらかに反する設定ファイルは
    /// **復元できない**——`SettingsStore` は「読めなかった」として既定値で起動し、
    /// 元のファイルは `.corrupt` へ退避されるので、利用者は手で直せる。
    ///
    /// 黙って一部だけ既定へ倒す縮退は採らない。「PTT だけ既定に戻っている」状態は、
    /// 利用者から見て**壊れ方が読めない**（フェーズ 1 の I-4 と同じ形の事故になる）。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hotkey = try container.decode(HotkeyBinding.self, forKey: .hotkey)
        self.undoHotkey = try container.decode(HotkeyBinding.self, forKey: .undoHotkey)
        self.localeIdentifier = try container.decode(String.self, forKey: .localeIdentifier)
        self.transcriberKind = try container.decode(TranscriberKind.self, forKey: .transcriberKind)
        self.refinementEnabled = try container.decode(Bool.self, forKey: .refinementEnabled)
        self.refinementTimeoutMs = try container.decode(Int.self, forKey: .refinementTimeoutMs)
        self.historyLimit = try container.decode(Int.self, forKey: .historyLimit)
        try validateHotkeys()
    }

    /// ホットキーの妥当性を**一括で**検証する（詳細設計書 §12-9 の受け入れ条件）。
    ///
    /// 検査は 2 段ある。**単体の不変条件は `HotkeyBinding` が構築時に保証済み**なので、
    /// ここに残るのは PTT と Undo の関係だけである。
    ///
    /// - **保存の経路**（`SettingsStore.update`）と**復元の経路**（`Settings.init(from:)`）の
    ///   両方がここを呼ぶ。片方にしか無かったのが持ち越し項目 12 である。
    /// - 設定画面は保存の前にこれを呼んでよい（副作用は無い。純粋な検査）。
    ///
    /// - Throws: `SettingsError.hotkeyConflict` — Undo キーが PTT キーの修飾キーを含む。
    ///   既定（PTT = 右 Option）では **⌥ を含む Undo キーがこれに当たる**（§8.3）。
    public func validateHotkeys() throws {
        guard !hotkey.conflicts(with: undoHotkey) else {
            throw SettingsError.hotkeyConflict
        }
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    /// 整形の打ち切り時間。
    ///
    /// **既定は 750 ms で、NFR-P4 の目標値 500 ms とは別の数である。** 500 ms は
    /// 「整形にこれくらいで終わってほしい」という目標で、こちらは「これを超えたら
    /// 待つより生テキストを出す方がましになる」境界である。両者を同じ数にしていた
    /// 当初の既定では、**実運用に近い負荷の下で 3〜5 割の発話が整形されずに終わった**
    /// （Task 10 の M5 実測。超過分は 501〜527 ms とわずかに超えるものが大半だった）。
    ///
    /// 上限は NFR-P6a（発話終了 → テキストが出るまで 1000 ms）が決める。実測の最悪値で
    /// M2 が 177 ms、M4 の予算が NFR-P5 の 50 ms なので、
    /// 177 + 750 + 50 = 977 ms で収まる（詳細設計書 §10）。
    ///
    /// **750 ms は実用の発話長では足りない（2026-08-14 / 実機の肉声）。**
    /// 上記の実測はすべて**3 秒の発話**で行っており、**入力が長ければ生成も長くかかる**
    /// という依存を条件に含めていなかった。実機の履歴 11 件では **40 字以上の 8 件が
    /// すべて打ち切られ**、整形が効いたのは 18 字以下の 3 件だけだった
    /// （要件定義書 §2.8.4）。**延ばすだけでは解けない**——NFR-P6a の予算が先に尽きる。
    ///
    /// **フェーズ 2 の裁定（要件定義書 §2.8.6）で、この値が効く範囲が狭まった。**
    /// 整形は挿入の前提ではなくなり、**差し替えできる挿入先では生テキストを先に挿入して
    /// 後から整形結果へ差し替える**（FR-5(a)）。この値が使われるのは
    /// **差し替えできない挿入先（(b) の分岐）だけ**で、差し替えできる側は
    /// NFR-P6b（目標 2 秒 / 打ち切り 3 秒。**どちらも推定値。V-25 / V-29 で実測して置き換える**）
    /// の下で走る。
    ///
    /// **既定値 750 ms は変えない。** (b) の分岐の予算計算（177 + 750 + 50 = 977 ms）は
    /// 裁定の前後で変わらないためである。**この値を上げてよいのは、上げたぶんだけ
    /// (b) の分岐で NFR-P6a を破ると判ったうえでのときだけ**である。
    public var refinementTimeout: Duration { .milliseconds(refinementTimeoutMs) }
}

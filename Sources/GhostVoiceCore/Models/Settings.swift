import Foundation

public enum SettingsError: Error, Equatable {
    /// Undo ホットキーが PTT キーの修飾キーと衝突している。
    ///
    /// 既定（PTT = 右 Option）では **⌥ を含む Undo キー**がこれに当たる。押すと
    /// 録音が始まってしまう（詳細設計書 §8.3）。
    case hotkeyConflict
}

/// 整形結果をいつ反映するか（要件定義書 §2.8.6 / FR-5 の細目）。
///
/// **`beforeInsert` は「フェーズ 1 の挙動」そのものである。** 差し替えの体感が
/// 悪かった場合（リスク R-10）、この 1 つを戻せば製品はフェーズ 1 と同じに動く。
public enum RefinementApplyMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// **生テキストを先に挿入し、整形が返ってから同じ範囲を差し替える**（FR-5(a)）。
    ///
    /// 差し替えが成立しない挿入先では自動的に `beforeInsert` と同じ経路へ落ちる
    /// （`AnchoringTextInserting.canCaptureAnchor()` が挿入の前に判定する）。
    case afterInsert
    /// **常に整形を待ってから挿入する**（FR-5(b) / フェーズ 1 の挙動）。
    ///
    /// 打ち切りは `refinementTimeoutMs`。超えたら生テキストを挿入する。
    case beforeInsert
}

public struct Settings: Codable, Sendable, Equatable {
    public var hotkey: HotkeyBinding
    public var undoHotkey: HotkeyBinding
    public var localeIdentifier: String
    public var transcriberKind: TranscriberKind
    public var refinementEnabled: Bool
    public var refinementTimeoutMs: Int
    public var historyLimit: Int
    /// 整形結果の反映方式（フェーズ 2 / 要件定義書 §2.8.6）。
    public var refinementApplyMode: RefinementApplyMode
    /// 差し替えの打ち切り（NFR-P6b）。詳細は `revisionDeadline`。
    public var revisionDeadlineMs: Int

    public init(
        hotkey: HotkeyBinding = .rightOption,
        undoHotkey: HotkeyBinding = .controlCommandZ,
        localeIdentifier: String = "ja-JP",
        transcriberKind: TranscriberKind = .dictation,
        refinementEnabled: Bool = true,
        refinementTimeoutMs: Int = 750,
        historyLimit: Int = 50,
        refinementApplyMode: RefinementApplyMode = .afterInsert,
        revisionDeadlineMs: Int = 3_000
    ) {
        self.hotkey = hotkey
        self.undoHotkey = undoHotkey
        self.localeIdentifier = localeIdentifier
        self.transcriberKind = transcriberKind
        self.refinementEnabled = refinementEnabled
        self.refinementTimeoutMs = refinementTimeoutMs
        self.historyLimit = historyLimit
        self.refinementApplyMode = refinementApplyMode
        self.revisionDeadlineMs = revisionDeadlineMs
    }

    public static let `default` = Settings()

    private enum CodingKeys: String, CodingKey {
        case hotkey, undoHotkey, localeIdentifier, transcriberKind
        case refinementEnabled, refinementTimeoutMs, historyLimit
        case refinementApplyMode, revisionDeadlineMs
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
        // **この 2 つだけ `decodeIfPresent` である。理由は「部分的に読めた」を許すためではない。**
        //
        // フェーズ 1 が書いた `settings.json` には、この 2 キーが構造上存在しない。
        // 上の 7 つと同じく `decode` にすると、**フェーズ 1 から更新した利用者の
        // 設定ファイルが丸ごと「読めなかった」になり、PTT キーもロケールも既定へ戻る。**
        // 欠けているのは「壊れているから」ではなく「そのスキーマには無かったから」であり、
        // フェーズ 1 の最終レビュー I-4 が退けた `decodeIfPresent` 化（**既にある**キーを
        // 任意にして部分復元を許すこと）とは別の話である。
        //
        // **新しいキーを足すたびにここへ足してよいわけではない。** 足してよいのは
        // 「省略時の意味が既定値と一致し、省略が利用者の意図と読める」キーだけである。
        self.refinementApplyMode =
            try container.decodeIfPresent(RefinementApplyMode.self, forKey: .refinementApplyMode)
            ?? .afterInsert
        self.revisionDeadlineMs =
            try container.decodeIfPresent(Int.self, forKey: .revisionDeadlineMs) ?? 3_000
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
    /// 上限は NFR-P6a（発話終了 → テキストが出るまで 1000 ms）が決める。M2 の保守的な
    /// 上限（**約 199 ms**。V-12 の修正で定義が「結果ストリームの終端」へ移り、177 ms から
    /// 上がった）と、M4 の予算 NFR-P5 の 50 ms を置くと、
    /// **199 + 750 + 50 = 999 ms** で収まる（詳細設計書 §10）。**余裕は 1 ms しかない。**
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
    /// **既定値 750 ms は変えない。** (b) の分岐の予算計算（199 + 750 + 50 = 999 ms）は
    /// 裁定の前後で変わらないためである（M2 の測り直しで 977 → 999 ms になったが、
    /// **予算の引き直しは配線トラックで (a)/(b) の実分布を見てから行う**）。**この値を上げてよいのは、上げたぶんだけ
    /// (b) の分岐で NFR-P6a を破ると判ったうえでのときだけ**である。
    public var refinementTimeout: Duration { .milliseconds(refinementTimeoutMs) }

    /// 差し替え（FR-5(a)）の打ち切り。**NFR-P6b の「打ち切り 3 秒」がこれである。**
    ///
    /// **`refinementTimeout` とは効く場所が違う。** あちらは (b) の分岐——整形を待って
    /// から挿入する経路——の打ち切りで、**そこでは超過が NFR-P6a（テキストが出るまで
    /// 1 秒）を直接食う。** こちらは (a) の分岐の打ち切りで、**生テキストは既に欄にある。**
    /// 超えたときの縮退は「整形が反映されないまま終わる」であり、発話は失われない。
    /// だから (b) より大きい値を置ける。
    ///
    /// **既定 3000 ms は推定値である**（要件定義書 NFR-P6b）。由来は
    /// 「3 秒の発話で M3 中央値 355〜364 ms」という実測に**出力長への比例という
    /// LLM 一般の性質【推測】**を当てた外挿（121 字 ≒ 2.4 秒）＋ 約 25 % の余裕であり、
    /// **直接の実測ではない。** 上限の本来の決め手は「利用者が続きを打ち始めるまでの
    /// 時間」で、それは未実測である（検証項目 V-25 / V-29）。
    public var revisionDeadline: Duration { .milliseconds(revisionDeadlineMs) }
}

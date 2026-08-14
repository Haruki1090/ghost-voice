import Foundation
import GhostVoiceCore

/// **設定画面が `DictationSession` へ触る面。これだけである。**
///
/// 画面が actor を直に握ると、検査のたびに本物のマイクと認識器を組み立てることになる
/// （`DictationSession` の初期化子は依存を 8 つ要求する）。**触る 2 口だけを切り出す。**
///
/// - Important: **どちらも `async` である。** actor 隔離を跨ぐので `await` が要る。
///   `SessionMirror` のような同期の写しは作らない——この 2 つは**問い合わせではなく
///   指示**であり、返事を待たずに投げると「切り替えたつもりで切り替わっていない」が生まれる。
public protocol SettingsSessionControlling: Sendable {

    /// ロケール／認識種別を切り替える（FR-8 / FR-11）。
    ///
    /// - Important: **録音中に呼んではならない。** ガードは Core 側にあり、
    ///   発話を抱えている間は `DictationSessionError.busy` を投げる
    ///   （`DictationSession.prepareTranscriber`）。**画面側で `state` を見て
    ///   自前に判定しないこと**——見てから呼ぶまでの間に PTT が押されうるので、
    ///   呼び出し側には原理的に守れない。
    /// - Important: **モデルの導入を伴うと数分戻らない。** 進捗は
    ///   `SessionMirror.installation` に出る。
    func prepareTranscriber(locale: Locale, kind: TranscriberKind) async throws

    /// Undo のバインドを監視器へ反映する（FR-11）。
    ///
    /// - Important: **`SettingsStore` へ保存しただけでは効かない。** 監視器は
    ///   自分が持っているバインドを見ている（`HotkeyMonitor.currentUndoBinding`）。
    func rebindUndoHotkey(to binding: HotkeyBinding) async throws
}

/// 本物の `DictationSession` を上の面へはめる薄い覆い。
///
/// **`extension DictationSession: SettingsSessionControlling` にしない。**
/// Core の型へ App 側の protocol を後付けすると、Core を触れないトラックが
/// Core の公開面を実質的に広げることになる（統合時に「これは Core の API か」が
/// 判らなくなる）。**覆いは App の持ち物として App に置く。**
public struct DictationSessionSettingsControl: SettingsSessionControlling {
    private let session: DictationSession

    public init(_ session: DictationSession) {
        self.session = session
    }

    public func prepareTranscriber(locale: Locale, kind: TranscriberKind) async throws {
        try await session.prepareTranscriber(locale: locale, kind: kind)
    }

    public func rebindUndoHotkey(to binding: HotkeyBinding) async throws {
        try await session.rebindUndoHotkey(to: binding)
    }
}

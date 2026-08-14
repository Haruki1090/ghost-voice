import Testing
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Synchronization
@testable import GhostVoiceCore

@Suite("PasteboardInserter")
struct PasteboardInserterTests {

    /// PNG の先頭 8 バイト（シグネチャ）に続けて雑多なバイト列を足したもの。
    /// 「文字列に変換できないデータ」であることが要点で、画像として妥当である必要は無い。
    private var pngLikeData: Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + (0...255).map(UInt8.init))
    }

    /// ⌘V を送る時点でテキストが載っていなければ、貼り付くのは前の内容である。
    /// 「最後にクリップボードが元へ戻っている」だけを見るテストではここが検査されない
    /// （何も載せずに復元しただけの実装でも通ってしまう）。送出の瞬間を覗く。
    @Test("⌘V を送る時点でテキストがクリップボードに載っている")
    func textIsOnClipboardWhenShortcutIsSent() async {
        await withNamedPasteboard { pasteboard in
            pasteboard.clearContents()
            _ = pasteboard.setString("元の内容", forType: .string)

            let sender = StubPasteShortcutSender(canSend: true, observing: pasteboard)
            let inserter = PasteboardInserter(
                pasteboard: pasteboard, sender: sender, restoreDelay: .milliseconds(1)
            )

            #expect(await inserter.tryInsert("挿入するテキスト"))
            #expect(sender.calls.sendCount == 1)
            #expect(sender.calls.observed == ["挿入するテキスト"])
        }
    }

    /// 復元が早すぎると、貼り付く前にクリップボードが元へ戻って**挿入が空振りする**。
    /// 待ち時間そのものを検査しないと `.zero` へ縮めた実装が素通りする。
    @Test("復元は待ち時間が経ってから行う")
    func restoresAfterDelay() async {
        await withNamedPasteboard { pasteboard in
            pasteboard.clearContents()
            _ = pasteboard.setString("元の内容", forType: .string)

            let sender = StubPasteShortcutSender(canSend: true, observing: pasteboard)
            let inserter = PasteboardInserter(
                pasteboard: pasteboard, sender: sender, restoreDelay: .milliseconds(300)
            )

            let start = ContinuousClock.now
            #expect(await inserter.tryInsert("挿入するテキスト"))
            let elapsed = ContinuousClock.now - start

            #expect(sender.calls.observed == ["挿入するテキスト"], "送出時点で載っていない")
            #expect(pasteboard.string(forType: .string) == "元の内容", "復元されていない")
            #expect(elapsed >= .milliseconds(300), "待たずに復元している: \(elapsed)")
        }
    }

    /// 退避を文字列だけで行うと、画像を貼るつもりで溜めていた内容が
    /// ディクテーション 1 回で消える。全 `PasteboardType` を退避する設計の検査。
    @Test("画像を含むクリップボードが往復で壊れない")
    func preservesImageContent() async {
        await withNamedPasteboard { pasteboard in
            let png = pngLikeData

            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            item.setString("画像に添えた説明", forType: .string)
            pasteboard.writeObjects([item])

            let inserter = PasteboardInserter(
                pasteboard: pasteboard,
                sender: StubPasteShortcutSender(canSend: true),
                restoreDelay: .milliseconds(1)
            )
            #expect(await inserter.tryInsert("挿入するテキスト"))

            #expect(pasteboard.data(forType: .png) == png, "画像が失われた")
            #expect(pasteboard.string(forType: .string) == "画像に添えた説明")
        }
    }

    /// ブラウザやワープロからのコピーはこの形（`NSAttributedString`）で載る。
    /// 書式が落ちて平文になると、ユーザーは貼り付けてから初めて気付く。
    ///
    /// バイト列の一致ではなく**書式が残っていること**で判定する。RTF のバイト列は
    /// 生成のたびに変わりうるので、一致を要求すると意味の無い失敗を招く。
    @Test("リッチテキストが書式ごと往復する")
    func preservesRichText() async {
        await withNamedPasteboard { pasteboard in
            let original = NSAttributedString(
                string: "太字の文章",
                attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]
            )
            pasteboard.clearContents()
            pasteboard.writeObjects([original])

            let inserter = PasteboardInserter(
                pasteboard: pasteboard,
                sender: StubPasteShortcutSender(canSend: true),
                restoreDelay: .milliseconds(1)
            )
            #expect(await inserter.tryInsert("挿入するテキスト"))

            let restored = (pasteboard.readObjects(forClasses: [NSAttributedString.self])
                as? [NSAttributedString])?.first
            #expect(restored?.string == "太字の文章", "リッチテキストが失われた")

            let font = restored?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true, "書式が落ちて平文になった")
        }
    }

    /// 項目が複数あるクリップボード（複数ファイルのコピー等）で、数と順序が保たれること。
    @Test("複数項目の数と順序が保たれる")
    func preservesMultipleItemsInOrder() async {
        await withNamedPasteboard { pasteboard in
            pasteboard.clearContents()
            let items = ["一番目", "二番目", "三番目"].map { text -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                return item
            }
            pasteboard.writeObjects(items)

            let inserter = PasteboardInserter(
                pasteboard: pasteboard,
                sender: StubPasteShortcutSender(canSend: true),
                restoreDelay: .milliseconds(1)
            )
            #expect(await inserter.tryInsert("挿入するテキスト"))

            let restored = pasteboard.pasteboardItems?.map { $0.string(forType: .string) }
            #expect(restored == ["一番目", "二番目", "三番目"])
        }
    }

    /// **実測に基づく設計。** 送出の許可（`kTCCServicePostEvent`）が無いプロセスでは
    /// `CGEvent.post` が黙って捨てられる（実測: `.cgAnnotatedSessionEventTap` /
    /// `.cghidEventTap` の双方へ ⌘V を送り、いずれも 3/3 で貼り付かなかった）。
    /// `post` は `Void` を返すので送出の失敗を後から知る術が無い。**送る前に判定する。**
    @Test("キーイベントを送れない環境では適用外と判定する")
    func notApplicableWhenEventsCannotBeSent() async {
        await withNamedPasteboard { pasteboard in
            let denied = PasteboardInserter(
                pasteboard: pasteboard, sender: StubPasteShortcutSender(canSend: false)
            )
            #expect(!denied.canInsert())

            let allowed = PasteboardInserter(
                pasteboard: pasteboard, sender: StubPasteShortcutSender(canSend: true)
            )
            #expect(allowed.canInsert())
        }
    }

    /// **発話を失わないことが最優先（基本設計書 §7）。** 送出できなかったのに復元すると、
    /// 貼り付いてもいないテキストがクリップボードからも消えて、発話がどこにも残らない。
    /// ユーザーの元の内容を失う代償を払ってでもテキストを残す。
    /// **この判断は Task 8 で新設したもの**で、詳細設計書 §6.3 に元からあった
    /// 「**復元**失敗時」の規定とは別物である（そちらは復元処理が失敗した場合を指す）。
    @Test("⌘V を送れなかったらテキストをクリップボードに残す")
    func keepsTextWhenSendFails() async {
        await withNamedPasteboard { pasteboard in
            pasteboard.clearContents()
            _ = pasteboard.setString("元の内容", forType: .string)

            let inserter = PasteboardInserter(
                pasteboard: pasteboard,
                sender: StubPasteShortcutSender(canSend: true, succeeds: false),
                restoreDelay: .milliseconds(1)
            )

            #expect(await inserter.tryInsert("失われては困る発話") == false)
            #expect(
                pasteboard.string(forType: .string) == "失われては困る発話",
                "復元してテキストを消している"
            )
        }
    }

    /// 元が空なら「戻すべきもの」が無い。空で上書きするとテキストが消えるだけなので、
    /// 挿入したテキストを残す方を選ぶ。
    @Test("元のクリップボードが空ならテキストを残す")
    func keepsTextWhenNothingToRestore() async {
        await withNamedPasteboard { pasteboard in
            let inserter = PasteboardInserter(
                pasteboard: pasteboard,
                sender: StubPasteShortcutSender(canSend: true),
                restoreDelay: .milliseconds(1)
            )

            #expect(await inserter.tryInsert("挿入したテキスト"))
            #expect(pasteboard.string(forType: .string) == "挿入したテキスト")
        }
    }

    /// 最後の砦。合成器が挿入の全滅時に呼ぶ。
    @Test("leave はテキストをクリップボードへ置く")
    func leavePutsTextOnClipboard() async {
        await withNamedPasteboard { pasteboard in
            pasteboard.clearContents()
            _ = pasteboard.setString("元の内容", forType: .string)

            let inserter = PasteboardInserter(
                pasteboard: pasteboard, sender: StubPasteShortcutSender(canSend: false)
            )

            #expect(inserter.leave("残すべき発話"))
            #expect(pasteboard.string(forType: .string) == "残すべき発話")
        }
    }

    /// **残置は「上書き」でなければならない。** 前の内容を消さずに文字列だけ差し替えると、
    /// 直前にコピーしていた画像が残ったままになる。画像を優先して読むアプリでは
    /// ⌘V が画像を貼り、発話はどこにも出てこない。
    @Test("leave は前の内容を消してからテキストを置く")
    func leaveClearsPreviousContent() async {
        await withNamedPasteboard { pasteboard in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(pngLikeData, forType: .png)
            item.setString("前の説明", forType: .string)
            pasteboard.writeObjects([item])

            let inserter = PasteboardInserter(
                pasteboard: pasteboard, sender: StubPasteShortcutSender(canSend: false)
            )

            #expect(inserter.leave("残すべき発話"))
            #expect(pasteboard.string(forType: .string) == "残すべき発話")
            #expect(pasteboard.data(forType: .png) == nil, "前の画像が残っている")
        }
    }

    /// 既定値そのものを固定する。実測に基づいて選んだ値なので、黙って変わってはいけない。
    ///
    /// **120 ms から 300 ms へ引き上げた（V-3 / 2026-08-14 の実機）。**
    /// 120 ms では Electron 製アプリが ⌘V を処理する前に復元が走り、
    /// **前のクリップボードの内容が貼られた**（履歴には成功として記録される）。
    @Test("既定の復元待ち時間は 300 ms")
    func defaultRestoreDelayIsPinned() {
        #expect(PasteboardInserter.defaultRestoreDelay == .milliseconds(300))
    }
}

/// 送出できる状況かの判定。**ここが緩むと「発話が消えたうえに成功として履歴に残る」**
/// という、このタスクで塞いだはずの経路が再発する。
///
/// `.serialized` にしてあるのは `secureInputBlocksDefaultSender` が
/// **システム全体の secure input 状態を一時的に変える**ため。同じスイート内の
/// 他のテストと重ならないようにしている。
@Suite("SystemPasteShortcutSender の送出可否", .serialized)
struct SystemPasteShortcutSenderTests {

    /// 呼ばれた回数を数える偽の照会。
    private final class Probe: Sendable {
        private let calls = Atomic<Int>(0)
        private let value: Atomic<Bool>

        init(_ initial: Bool) { value = Atomic<Bool>(initial) }

        var callCount: Int { calls.load(ordering: .relaxed) }
        func set(_ new: Bool) { value.store(new, ordering: .relaxed) }

        func probe() -> Bool {
            calls.add(1, ordering: .relaxed)
            return value.load(ordering: .relaxed)
        }
    }

    private func sender(
        granted: Bool, secureInput: @escaping @Sendable () -> Bool = { false }
    ) -> SystemPasteShortcutSender {
        SystemPasteShortcutSender(
            authorization: PostEventAuthorization(probe: { granted }),
            isSecureInputEnabled: secureInput
        )
    }

    @Test("許可があり secure input が無効なら送出できる")
    func canSendWhenGrantedAndNotSecure() {
        #expect(sender(granted: true).canSend)
    }

    /// `AXIsProcessTrusted()`（`kTCCServiceAccessibility`）ではなく
    /// `CGPreflightPostEventAccess()`（`kTCCServicePostEvent`）が門番である。
    /// 別レコードなので、片方だけ true の状態は原理的にありうる。
    @Test("送出の許可が無ければ適用外")
    func cannotSendWithoutPostEventAccess() {
        #expect(!sender(granted: false).canSend)
    }

    /// **TCC とは別の失敗要因。** 他プロセスがパスワード欄などで secure input を
    /// 有効にしている間、許可があっても合成キーイベントは配送されない。
    /// ここを見ないと「退避 → 送出（届かない）→ 復元 → true」を通り、
    /// 発話が消えたうえで `.pasteboard` として履歴に残る。
    @Test("secure input が有効なら許可があっても適用外")
    func cannotSendWhileSecureInputIsEnabled() {
        #expect(!sender(granted: true, secureInput: { true }).canSend)
        #expect(!sender(granted: false, secureInput: { true }).canSend)
    }

    /// secure input は刻々と変わる（ユーザーがパスワード欄へ移った瞬間に有効になる）。
    /// **キャッシュしてはならない。** 毎回見ていることを呼び出し回数で確かめる。
    @Test("secure input は判定のたびに見に行く")
    func secureInputIsCheckedEveryTime() {
        let checks = Atomic<Int>(0)
        let enabled = Atomic<Bool>(false)
        let sender = SystemPasteShortcutSender(
            authorization: PostEventAuthorization(probe: { true }),
            isSecureInputEnabled: {
                checks.add(1, ordering: .relaxed)
                return enabled.load(ordering: .relaxed)
            }
        )

        #expect(sender.canSend)
        #expect(sender.canSend)
        #expect(checks.load(ordering: .relaxed) == 2, "secure input をキャッシュしている")

        // 途中で有効化されたら、次の判定から反映されること。
        enabled.store(true, ordering: .relaxed)
        #expect(!sender.canSend, "secure input の変化を拾えていない")
        #expect(checks.load(ordering: .relaxed) == 3)
    }

    /// **照会のキャッシュ。** `CGPreflightPostEventAccess()` は実測 p50 10.6 ms
    /// （最大 24.7 ms）掛かる。挿入のたびに呼ぶと NFR-P5 の 50 ms 予算の 2 割を失う。
    @Test("送出の許可は判定のたびには照会しない")
    func postEventAccessIsCached() {
        let probe = Probe(true)
        let authorization = PostEventAuthorization(probe: probe.probe)
        #expect(probe.callCount == 1, "生成時に一度だけ照会する")

        let sender = SystemPasteShortcutSender(
            authorization: authorization, isSecureInputEnabled: { false }
        )
        for _ in 0..<10 { #expect(sender.canSend) }

        #expect(probe.callCount == 1, "判定のたびに照会している（実測 10.6 ms/回）")
    }

    /// 権限は実行中に変わる。**キャッシュするからには更新の口が要る。**
    /// アプリ起動時と権限フロー通過時に呼ぶ。
    @Test("refresh すると許可の変化を取り込む")
    func refreshPicksUpChanges() {
        let probe = Probe(false)
        let authorization = PostEventAuthorization(probe: probe.probe)
        let sender = SystemPasteShortcutSender(
            authorization: authorization, isSecureInputEnabled: { false }
        )

        #expect(!sender.canSend)

        probe.set(true)
        #expect(!sender.canSend, "refresh していないのに変化が見えている")

        #expect(authorization.refresh())
        #expect(sender.canSend)
        #expect(probe.callCount == 2, "生成時 1 回 + refresh 1 回")
    }
}

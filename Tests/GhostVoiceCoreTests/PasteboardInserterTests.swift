import Testing
import AppKit
import Foundation
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

    /// **実測に基づく設計。** AX 権限の無いプロセスでは `CGEvent.post` が黙って捨てられる
    /// （実測: `AXIsProcessTrusted() == false` の状態で `.cgAnnotatedSessionEventTap` /
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

    /// **発話を失わないことが最優先（基本設計書 §230）。** 送出できなかったのに復元すると、
    /// 貼り付いてもいないテキストがクリップボードからも消えて、発話がどこにも残らない。
    /// ユーザーの元の内容を失う代償を払ってでもテキストを残す（詳細設計書 §6.3）。
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
    @Test("既定の復元待ち時間は 120 ms")
    func defaultRestoreDelayIsPinned() {
        #expect(PasteboardInserter.defaultRestoreDelay == .milliseconds(120))
    }
}

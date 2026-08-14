import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import GhostVoiceCore

/// 権限の照会。**4 つは別の TCC サービスであり、取り違えてはならない。**
///
/// 基本設計書 §10:
/// > `AXUIElement` 系 API は `kTCCServiceAccessibility`、`CGEvent.post` は
/// > `kTCCServicePostEvent`、`CGEvent.tapCreate` は `kTCCServiceListenEvent` という
/// > それぞれ別の TCC サービスを使う。**どれか 1 つを他の判定に流用してはならない。**
/// > 片方だけ許可された状態は原理的にありうるため、
/// > **値が一致する機体では取り違えに気付けない。**
///
/// だからこの組の検査は、**代役で 4 つを 1 つずつ落として**行う。
/// 実機の値に頼ると、4 つとも許可された機体でも 4 つとも未許可の機体でも、
/// 取り違えた実装が緑になる。
@Suite("権限の照会（4 つの TCC サービスの取り違え）")
struct PermissionInquiryTests {

    /// 4 つとも許可された代役。ここから 1 つずつ落とす。
    static func probes(
        microphone: AVAuthorizationStatus = .authorized,
        accessibility: Bool = true,
        listenEvent: Bool = true,
        postEvent: Bool = true,
        secureInput: Bool = false,
        bundleIdentifier: String? = "com.haruki1090.GhostVoice"
    ) -> PermissionProbes {
        PermissionProbes(
            microphoneAuthorization: { microphone },
            accessibilityTrusted: { accessibility },
            listenEventAccess: { listenEvent },
            postEventAccess: { postEvent },
            secureInputEnabled: { secureInput },
            bundleIdentifier: { bundleIdentifier })
    }

    @Test("4 つとも許可なら 4 つとも許可として出る")
    func allGranted() {
        let status = PermissionInquiry.current(probes: Self.probes())
        #expect(status.microphoneAuthorized)
        #expect(status.accessibilityTrusted)
        #expect(status.listenEventAccess)
        #expect(status.postEventAccess)
        #expect(!status.secureInputEnabled)
        #expect(status.bundleIdentifier == "com.haruki1090.GhostVoice")
    }

    /// **`kTCCServiceMicrophone` だけを落とす。** 他の 3 つは許可のまま出なければならない。
    @Test("マイクだけ未許可のとき、落ちるのはマイクだけ")
    func onlyMicrophoneDenied() {
        let status = PermissionInquiry.current(probes: Self.probes(microphone: .denied))
        #expect(!status.microphoneAuthorized)
        #expect(status.microphoneStatus == "拒否")
        #expect(status.accessibilityTrusted, "マイクの答えをアクセシビリティに流用している")
        #expect(status.listenEventAccess, "マイクの答えを入力監視に流用している")
        #expect(status.postEventAccess, "マイクの答えをキー送出に流用している")
    }

    /// **`kTCCServiceAccessibility` だけを落とす。**
    ///
    /// ここを `kTCCServicePostEvent` と混ぜると、AX 直接挿入が使えないのに
    /// 「使える」と案内する（またはその逆）ことになる。
    @Test("アクセシビリティだけ未許可のとき、落ちるのはアクセシビリティだけ")
    func onlyAccessibilityDenied() {
        let status = PermissionInquiry.current(probes: Self.probes(accessibility: false))
        #expect(!status.accessibilityTrusted)
        #expect(status.microphoneAuthorized)
        #expect(status.listenEventAccess, "アクセシビリティの答えを入力監視に流用している")
        #expect(status.postEventAccess, "アクセシビリティの答えをキー送出に流用している")
    }

    /// **`kTCCServiceListenEvent` だけを落とす。**
    ///
    /// 入力監視が無ければ PTT がまったく動かない。ここを他の値で代用すると、
    /// **「押しても何も起きない」の原因を案内できなくなる。**
    @Test("入力監視だけ未許可のとき、落ちるのは入力監視だけ")
    func onlyListenEventDenied() {
        let status = PermissionInquiry.current(probes: Self.probes(listenEvent: false))
        #expect(!status.listenEventAccess)
        #expect(status.microphoneAuthorized)
        #expect(status.accessibilityTrusted, "入力監視の答えをアクセシビリティに流用している")
        #expect(status.postEventAccess, "入力監視の答えをキー送出に流用している")
    }

    /// **`kTCCServicePostEvent` だけを落とす。**
    ///
    /// ⌘V の送出の門番はこれであって `AXIsProcessTrusted()` ではない
    /// （`PasteboardInserter` の注記。フェーズ 1 が踏んだ罠と同じ形）。
    @Test("キー送出だけ未許可のとき、落ちるのはキー送出だけ")
    func onlyPostEventDenied() {
        let status = PermissionInquiry.current(probes: Self.probes(postEvent: false))
        #expect(!status.postEventAccess)
        #expect(status.microphoneAuthorized)
        #expect(status.accessibilityTrusted, "キー送出の答えをアクセシビリティに流用している")
        #expect(status.listenEventAccess, "キー送出の答えを入力監視に流用している")
    }

    /// **secure input は TCC ではない。** 許可の話と混ぜると、
    /// パスワード欄に居るだけの利用者に権限を付け直させることになる。
    @Test("secure input は 4 つのどれにも影響しない")
    func secureInputIsSeparate() {
        let status = PermissionInquiry.current(probes: Self.probes(secureInput: true))
        #expect(status.secureInputEnabled)
        #expect(status.microphoneAuthorized)
        #expect(status.accessibilityTrusted)
        #expect(status.listenEventAccess)
        #expect(status.postEventAccess)
    }

    /// **照会は 1 項目につき 1 回だけ呼ぶ。**
    /// `CGPreflightPostEventAccess()` は実測 p50 10.6 ms 掛かる（`PasteboardInserter` の表）。
    /// 取りこぼしを恐れて何度も呼ぶ実装は、起動と `--check` を目に見えて遅くする。
    @Test("照会は 1 項目につき 1 回だけ")
    func probesAreCalledOnce() {
        let counts = Mutex<[String: Int]>([:])
        let count: @Sendable (String) -> Void = { key in
            counts.withLock { $0[key, default: 0] += 1 }
        }
        let probes = PermissionProbes(
            microphoneAuthorization: {
                count("microphone")
                return .authorized
            },
            accessibilityTrusted: {
                count("accessibility")
                return true
            },
            listenEventAccess: {
                count("listen")
                return true
            },
            postEventAccess: {
                count("post")
                return true
            },
            secureInputEnabled: {
                count("secure")
                return false
            },
            bundleIdentifier: {
                count("bundle")
                return nil
            })

        _ = PermissionInquiry.current(probes: probes)
        #expect(counts.withLock { $0 } == [
            "microphone": 1, "accessibility": 1, "listen": 1, "post": 1, "secure": 1, "bundle": 1,
        ])
    }

    /// **`nil` は「`.app` から起動していない」を意味する。**
    /// この状態の許可はターミナルアプリのもので、Finder から起動したときとは結果が変わる。
    @Test("バンドル ID が無い状態を、そのまま値として持つ")
    func unbundled() {
        let status = PermissionInquiry.current(probes: Self.probes(bundleIdentifier: nil))
        #expect(status.bundleIdentifier == nil)
    }

    @Test(
        "マイクの呼び名は 4 つとも別の文字列",
        arguments: [
            (AVAuthorizationStatus.notDetermined, "未確認"),
            (.restricted, "制限"),
            (.denied, "拒否"),
            (.authorized, "許可"),
        ])
    func microphoneNames(status: AVAuthorizationStatus, expected: String) {
        #expect(PermissionInquiry.name(of: status) == expected)
        #expect(PermissionInquiry.current(probes: Self.probes(microphone: status))
            .microphoneStatus == expected)
    }

    /// **許可されたと言えるのは `.authorized` のときだけ。**
    /// `.restricted`（管理下で禁止）を「許可」と読むと、録音が始まらない理由を見失う。
    @Test("authorized 以外は許可済みとしない")
    func onlyAuthorizedCounts() {
        for status in [AVAuthorizationStatus.notDetermined, .restricted, .denied] {
            #expect(!PermissionInquiry.current(probes: Self.probes(microphone: status))
                .microphoneAuthorized)
        }
        #expect(PermissionInquiry.current(probes: Self.probes(microphone: .authorized))
            .microphoneAuthorized)
    }

    // MARK: - 照会が 1 箇所であることの検査

    /// **実 API を名指しするのはこのファイルだけである。**
    ///
    /// 合流時点では `GhostVoiceRuntime` と `AppPermissions` が独立に 4 つを呼んでいた。
    /// 2 実装あると、「1 つを他の判定に流用してはならない」という規律が
    /// **片方だけ守られている状態**を作れてしまう——そして値が一致する機体では気付けない。
    ///
    /// **これは振る舞いでは検査できない**（もう 1 つの実装が正しく振る舞う限り緑になる）。
    /// だからソースの形として固定する。
    @Test("4 つの TCC API を名指しで呼ぶのは Core の 1 ファイルだけ")
    func inquiryLivesInOnePlace() throws {
        let apis = [
            "AVCaptureDevice.authorizationStatus",
            "AXIsProcessTrusted()",
            "CGPreflightListenEventAccess()",
            "CGPreflightPostEventAccess()",
        ]
        // 照会を組み立てる側（CLI と `.app`）に、実 API が 1 つも残っていないこと。
        for path in [
            "Sources/GhostVoiceCLI/GhostVoiceRuntime.swift",
            "Sources/GhostVoiceCLI/PermissionGuidance.swift",
            "Sources/GhostVoiceApp/Shell/AppPermissions.swift",
            "Sources/GhostVoiceApp/Shell/AppPermissionGuidance.swift",
            "Sources/GhostVoiceApp/Shell/GhostVoiceAppDelegate.swift",
        ] {
            let code = try ShutdownSequenceTests.sourceWithoutComments(path)
            for api in apis {
                #expect(!code.contains(api), "\(path) が \(api) を直接呼んでいる")
            }
        }

        // 対応表は 1 枚だけ。**この検査自身が対象を掴めていることも確かめる。**
        let core = try ShutdownSequenceTests.sourceWithoutComments(
            "Sources/GhostVoiceCore/Support/PermissionInquiry.swift")
        for api in apis {
            #expect(core.contains(api), "対応表に \(api) が無い（検査が空振りしている）")
        }
    }
}

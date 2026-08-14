import Foundation
import Testing

@testable import GhostVoiceApp

/// `.app` の中身の取り決めを、**ファイルそのものに対して**確かめる。
///
/// ここで見ているのは「実装がどう振る舞うか」ではなく「バンドルに何が書いてあるか」である。
/// `Info.plist` の 1 キーの過不足が、**利用者に権限を付け直させる**ところまで直結するので、
/// 実測（`app-bundle.md` §4 / §6）で決まった内容を検査で固定する。
@Suite("バンドルの取り決め（Info.plist / entitlements / 組み立てスクリプト）")
struct BundleContractTests {

    /// リポジトリの根。**テストの置き場所から辿る**（作業ディレクトリに依存しない）。
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // GhostVoiceAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // リポジトリの根

    private func plist(_ relativePath: String) throws -> [String: Any] {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Info.plist

    @Test("常駐に要るキーが揃っている")
    func requiredKeys() throws {
        let info = try plist("Resources/Info.plist")
        // Dock に出さない常駐。**コードを書かずにこれだけで `.accessory` になる**（実測 §3.2）。
        #expect(info["LSUIElement"] as? Bool == true)
        #expect(info["CFBundlePackageType"] as? String == "APPL")
        #expect(info["LSMinimumSystemVersion"] as? String == "26.0")
        #expect(info["CFBundleName"] as? String == "Ghost Voice")
        #expect((info["CFBundleShortVersionString"] as? String)?.isEmpty == false)
        // マイクだけは usage description が要る。**無いと `requestAccess` でクラッシュする。**
        let microphone = try #require(info["NSMicrophoneUsageDescription"] as? String)
        #expect(microphone.count > 10)
    }

    /// **バンドル ID は DR に焼き込まれる。** 変えると TCC の許可がすべて失われる（§4.7）。
    /// この検査は「うっかり変えた」を落とすためにある。
    @Test("バンドル ID は com.haruki1090.GhostVoice で固定")
    func bundleIdentifierIsPinned() throws {
        let info = try plist("Resources/Info.plist")
        #expect(info["CFBundleIdentifier"] as? String == "com.haruki1090.GhostVoice")
    }

    /// 書く必要が無いキーを書かないことも取り決めである。
    /// とくに `NSSpeechRecognitionUsageDescription` は**実測で不要と判っている**（V-14）。
    /// `NSAppleEventsUsageDescription` は、書くと無関係なダイアログの余地を作るだけである。
    @Test("要らない usage description キーを書かない")
    func forbiddenKeys() throws {
        let info = try plist("Resources/Info.plist")
        for key in [
            "NSSpeechRecognitionUsageDescription",
            "NSAppleEventsUsageDescription",
            "NSCameraUsageDescription",
            "NSAudioCaptureUsageDescription",
            "NSMicrophoneInjectionUsageDescription",
            "NSLocalNetworkUsageDescription",
            // そもそも存在しないキー（tccd は参照しない。§6.1 で列挙して確認済み）。
            "NSAccessibilityUsageDescription",
            "NSInputMonitoringUsageDescription",
        ] {
            #expect(info[key] == nil, "\(key) は要らない")
        }
    }

    // MARK: - entitlements

    @Test("App Sandbox は無効、マイクの entitlement は有効")
    func entitlements() throws {
        let entitlements = try plist("Resources/GhostVoice.entitlements")
        // AX API とサンドボックスは両立しない（基本設計書 §10）。
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == false)
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
        // Apple Events は使わない。
        #expect(entitlements["com.apple.security.automation.apple-events"] == nil)
    }

    // MARK: - 組み立てスクリプト

    @Test("実行ファイル名は Package.swift の実行ファイル製品と一致する")
    func executableMatchesProduct() throws {
        let info = try plist("Resources/Info.plist")
        let executable = try #require(info["CFBundleExecutable"] as? String)
        let package = try text("Package.swift")
        #expect(package.contains("\"\(executable)\", targets: [\"\(executable)\"]"))
    }

    /// **スクリプトはバンドル ID を二重に持たない。** Info.plist から読む。
    /// 2 箇所に書くと、食い違ったときに権限が黙って無効になる。
    @Test("スクリプトはバンドル ID を Info.plist から読む")
    func scriptReadsIdentifierFromPlist() throws {
        let script = try text("Scripts/make-app.sh")
        #expect(script.contains("Print :CFBundleIdentifier"))
        #expect(!script.contains("com.haruki1090.GhostVoice"))
    }

    @Test("スクリプトは Hardened Runtime と entitlements を付けて署名する")
    func scriptSignsWithHardenedRuntime() throws {
        let script = try text("Scripts/make-app.sh")
        #expect(script.contains("--options runtime"))
        #expect(script.contains("--entitlements"))
        // SwiftPM の出す実行ファイルは既に ad-hoc 署名済み。**上書きが要る。**
        #expect(script.contains("--force"))
    }

    /// ad-hoc 分岐は**用意する**（証明書を持たない第三者がビルドできるように。NFR-M3）。
    /// ただし**再ビルドで権限が無効になることを必ず警告する。**
    @Test("ad-hoc 署名は既定にせず、選んだときは警告する")
    func adhocIsOptInAndWarns() throws {
        let script = try text("Scripts/make-app.sh")
        #expect(script.contains("--allow-adhoc"))
        #expect(script.contains("付け直す"))
        // ad-hoc でも DR は identifier で固定する（既定の DR は cdhash 単体であるため）。
        #expect(script.contains("designated => identifier"))
    }

    @Test("スクリプトは前提が欠けたら理由を出して止まる")
    func scriptChecksPrerequisites() throws {
        let script = try text("Scripts/make-app.sh")
        #expect(script.contains("set -euo pipefail"))
        #expect(script.contains("--show-sdk-path"))
        #expect(script.contains("find-identity"))
    }
}

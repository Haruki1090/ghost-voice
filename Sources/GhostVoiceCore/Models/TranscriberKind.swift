import Foundation

/// 使用する音声認識モジュールの種別。
///
/// 実測（要件定義書 §2.5）では日本語で `.dictation` が優位だったが、
/// 合成音声での比較のため、肉声で再検証できるよう差し替え可能にしている。
public enum TranscriberKind: String, Codable, Sendable, CaseIterable {
    case dictation
    case speech
}

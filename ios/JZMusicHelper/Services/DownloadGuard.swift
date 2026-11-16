import Foundation

// MARK: - 下载校验（纯函数）
//
// 为什么单独拆一个文件：这台开发机没有 Swift 工具链，"下载得对不对"只能靠 CI 里
// `ios/SelfTest/main.swift` 的断言（.github/workflows/ios-ipa.yml 的 logic-tests）。
// 所以凡是能判定成 true/false 的口径（95% 体积、仅 Wi-Fi 拒下、档位顺序、
// 体积文案）都不写在 View 里，集中在这里由 CI 钉住。
enum DownloadGuard {

    /// 体积容差：实际文件不得小于预期的 95%（与 Android `DownloadVerifier` 同口径）。
    /// 为什么不卡 100%：服务端 Content-Length 与实际写入总有几 KB 出入，
    /// 卡死会把好文件判成坏的；而 5% 以上的缺口基本都是被截断的流。
    static let sizeTolerance: Double = 0.95

    /// 文件是否完整。
    /// `expected <= 0` 表示取流阶段没探到体积（服务端既没回 Content-Range 也没回
    /// Content-Length），这时**不做判定**——宁可信其完整，也不要凭 0 把好文件删掉。
    static func isComplete(actual: Int64, expected: Int64) -> Bool {
        guard expected > 0 else { return true }
        return actual > 0 && Double(actual) >= Double(expected) * sizeTolerance
    }

    /// 体积缺口比例（0…1），用于"文件不完整（6.2 / 22.7 MB）"这类文案
    static func shortfall(actual: Int64, expected: Int64) -> Double {
        guard expected > 0 else { return 0 }
        return max(0, 1 - Double(max(actual, 0)) / Double(expected))
    }

    /// 仅 Wi-Fi 开关的拒下理由；允许下载时返回 nil
    static func refusalReason(wifiOnly: Bool, onWiFi: Bool) -> String? {
        guard wifiOnly, !onWiFi else { return nil }
        return "已开启「仅 Wi-Fi 下载」，当前不是 Wi-Fi。可在设置里关掉它，或连上 Wi-Fi 再下。"
    }

    /// 音质选项：从高到低（无损 → 高品 → 标准）
    static func qualityOptions() -> [QualityLevel] {
        QualityLevel.allCases.sorted { $0.sortOrder > $1.sortOrder }
    }

    /// 体积文案：未探到体积时给"待核对"，不要显示 0 MB 假装知道
    static func sizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "待核对" }
        let mb = Double(bytes) / 1_000_000
        return mb >= 1 ? String(format: "%.1f MB", mb) : String(format: "%.0f KB", mb * 1000)
    }
}

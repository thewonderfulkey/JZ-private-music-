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

    // MARK: 落盘后的实测档位（老板反馈 ⑥：标着无损、下下来是 320k）

    /// 文件实测结果：容器、真实码率、据此判定的档位、正确后缀
    struct Verdict: Equatable {
        let container: String
        let kbps: Int64
        let quality: QualityLevel
        let extensionName: String
    }

    /// 拿「文件头 16 字节 + 实际体积 + 时长」反推真实档位。
    ///
    /// 为什么必须在落盘后再验一次：取流阶段验的是**那个 URL** 返回的头与长度，而下载可能是
    /// 另一个 CDN 节点、另一种编码，甚至同一 URL 第二次返回 320k 转码流。只有文件本身不说谎。
    static func verdict(prefix: [UInt8], size: Int64, durationSec: Int) -> Verdict {
        let container = StreamVerifier.sniffHead(prefix)
        let facts = StreamVerifier.AudioFacts(container: container, totalBytes: size)
        let (quality, ext) = QualityFacts.of(facts, durationSec: durationSec)
        return Verdict(container: container,
                       kbps: QualityFacts.kbps(size, durationSec),
                       quality: quality,
                       extensionName: ext)
    }

    /// 实测档位低于用户想要的档位时，给一句人话（不弹窗，就写在下载行里）
    static func downgradeNote(_ verdict: Verdict, requested: QualityLevel) -> String? {
        guard verdict.quality.sortOrder < requested.sortOrder else { return nil }
        return "实测 \(verdict.container.uppercased()) · \(verdict.kbps) kbps（\(verdict.quality.displayName)），没达到 \(requested.displayName)"
    }
}

import Foundation

// MARK: - 可用的流地址（一个后端解析出的结果）
/// directId=true：按歌曲平台 ID 直连解析（QQ mid / 网易 id），身份可靠；
/// false：搜索式取流（按歌名+歌手重新搜索），需配合身份校验。
/// kbps / totalBytes 是取流阶段 Range 探测到的**真实**值，下载前就能按「容器 + 体积」预校验档位。
struct StreamSource: Identifiable, Codable, Hashable, Sendable {
    let url: String
    let backendName: String
    let platform: MusicPlatform
    let quality: QualityLevel
    let format: String
    let note: String
    var directId: Bool = false
    var kbps: Int64 = 0
    var totalBytes: Int64 = 0
    /// 取流探测时服务端是否支持 Range（206 或带 Content-Range）。
    /// nil = 老数据/没探测（解码兼容：Optional 缺键不报错）。
    var rangeOK: Bool? = nil

    var id: String { "\(platform.rawValue)_\(backendName)_\(quality.rawValue)" }

    /// 码率（kbps）：总字节 × 8 ÷ 时长；任一为 0 时回 0（表示算不出）
    static func kbps(totalBytes: Int64, durationSec: Int) -> Int64 {
        guard durationSec > 0, totalBytes > 0 else { return 0 }
        return totalBytes * 8 / Int64(durationSec) / 1000
    }
}

// MARK: - 下载状态
enum DownloadStatus: String, Codable {
    case pending
    case downloading
    case completed
    case failed
    case cancelled
}

// MARK: - 下载条目
struct DownloadItem: Identifiable, Codable, Hashable {
    let id: UUID
    let song: Song
    let streamURL: String
    let backendName: String
    /// 标注档位。落盘后会按实测结果改写（例：接口说有损，文件其实是 320k mp3），所以是 var。
    var quality: QualityLevel
    var fileName: String
    var localPath: String?
    var status: DownloadStatus
    var progress: Double
    var receivedBytes: Int64
    var totalBytes: Int64
    /// 取流阶段用 Range 探到的**预期**体积；落盘后拿它做 95% 完整性校验。
    /// 可选类型是为了兼容旧记录（downloads.json 里没有这个键，解码不能失败）。
    var expectedBytes: Int64?
    var createdAt: Date
    var finishedAt: Date?
    var errorMessage: String?
    /// 落盘实测与标注档位不一致时的说明（例：标着无损，文件其实是 320k mp3）。
    /// 可选类型：旧记录没有这个键，解码不能失败。
    var actualNote: String?
    /// 歌词/封面补料结果（例："已内嵌歌词+封面" / "歌词封面已存旁车"）。
    /// 下载完成后的异步补料会回填它，下载列表据此能看出"词和图到底有没有跟着歌走"。
    /// 可选类型：旧 downloads.json 没有这个键，解码不能失败。
    var companionsNote: String?
    /// 来源：nil/"download" = 联网下载；"import" = 用户导入的本地文件。
    /// 可选类型：旧 downloads.json 没有这个键，解码不能失败。
    var origin: String?
    /// 导入文件的 SHA-256（同文件判重用；下载记录暂时为 nil）
    var contentHash: String?

    init(id: UUID = UUID(),
         song: Song,
         streamURL: String,
         backendName: String,
         quality: QualityLevel,
         fileName: String = "",
         localPath: String? = nil,
         status: DownloadStatus = .pending,
         progress: Double = 0,
         receivedBytes: Int64 = 0,
         totalBytes: Int64 = 0,
         expectedBytes: Int64? = nil,
         createdAt: Date = Date(),
         finishedAt: Date? = nil,
         errorMessage: String? = nil,
         actualNote: String? = nil,
         companionsNote: String? = nil,
         origin: String? = nil,
         contentHash: String? = nil) {
        self.id = id
        self.song = song
        self.streamURL = streamURL
        self.backendName = backendName
        self.quality = quality
        self.fileName = fileName
        self.localPath = localPath
        self.status = status
        self.progress = progress
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.expectedBytes = expectedBytes
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.actualNote = actualNote
        self.companionsNote = companionsNote
        self.origin = origin
        self.contentHash = contentHash
    }

    var progressText: String {
        guard totalBytes > 0 else { return "--%" }
        return String(format: "%.0f%%", progress * 100)
    }

    var sizeText: String {
        ByteText.human(totalBytes)
    }
}

// MARK: - 体积文案（2026-11-21 老板：> 1GB 用 GB，< 1GB 用 MB，< 1MB 再降级，升级同理）

/// 一处统一的"人看的体积"：自动选档位，不再到处写 `%.1f MB`。
///
/// 老板原话："把下载那里的内存显示改为 GB 单位，一旦大于 1GB 就用 GB 单位，小于的话用 MB，
/// 小于 1MB 再降级用更小的单位，升级同理。"
/// 用 1000 进制（和 iOS「设置 › 通用 › iPhone 储存空间」一致，也和以前下载页的 MB 口径一致）。
enum ByteText {

    /// 档位：≥1GB → GB；≥1MB → MB；≥1KB → KB；否则 B。
    /// 小数位：GB 两位（1.25 GB）、MB 一位（8.2 MB）、KB 与 B 取整 —— 一眼能读，不拖一串 0。
    static func human(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let value = Double(bytes)
        if value >= 1_000_000_000 { return trim(String(format: "%.2f", value / 1_000_000_000)) + " GB" }
        if value >= 1_000_000 { return trim(String(format: "%.1f", value / 1_000_000)) + " MB" }
        if value >= 1_000 { return String(format: "%.0f", value / 1_000) + " KB" }
        return "\(bytes) B"
    }

    /// 去掉 `1.00` 这种多余的 0（GB 档只有一位小数时不显示两位）
    private static func trim(_ s: String) -> String {
        var out = s
        while out.contains("."), out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }
}

// MARK: - 搜索历史条目
struct SearchHistoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let keyword: String
    let createdAt: Date

    init(id: UUID = UUID(), keyword: String, createdAt: Date = Date()) {
        self.id = id
        self.keyword = keyword
        self.createdAt = createdAt
    }
}

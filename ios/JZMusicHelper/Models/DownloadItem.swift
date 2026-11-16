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
    let quality: QualityLevel
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
         errorMessage: String? = nil) {
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
    }

    var progressText: String {
        guard totalBytes > 0 else { return "--%" }
        return String(format: "%.0f%%", progress * 100)
    }

    var sizeText: String {
        let mb = Double(totalBytes) / 1_000_000.0
        return mb >= 1 ? String(format: "%.1f MB", mb) : ""
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

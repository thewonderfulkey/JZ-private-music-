import Foundation

// MARK: - 可用的流地址（一个后端解析出的结果）
struct StreamSource: Identifiable, Codable, Hashable {
    let url: String
    let backendName: String
    let platform: MusicPlatform
    let quality: QualityLevel
    let format: String
    let note: String

    var id: String { "\(platform.rawValue)_\(backendName)_\(quality.rawValue)" }
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

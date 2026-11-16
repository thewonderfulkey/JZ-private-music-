import Foundation

// MARK: - 平台枚举
enum MusicPlatform: String, Codable, CaseIterable, Identifiable, Hashable {
    case kuwo = "kuwo"
    case qq = "qq"
    case netease = "netease"
    case kugou = "kugou"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kuwo: return "酷我音乐"
        case .qq: return "QQ音乐"
        case .netease: return "网易云音乐"
        case .kugou: return "酷狗音乐"
        }
    }

    var shortName: String {
        switch self {
        case .kuwo: return "酷我"
        case .qq: return "QQ"
        case .netease: return "网易"
        case .kugou: return "酷狗"
        }
    }
}

// MARK: - 音质档位
enum QualityLevel: String, Codable, CaseIterable, Identifiable, Hashable {
    case standard = "128k"
    case high = "320k"
    case lossless = "lossless"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "标准 128k"
        case .high: return "高品 320k"
        case .lossless: return "无损 FLAC"
        }
    }
}

// MARK: - 歌曲模型
/// 一个搜索结果条目，platformID 为对应平台的歌曲 ID：
/// 酷我 rid（去掉 MUSIC_ 前缀）、QQ songmid、网易 songid、酷狗 hash。
struct Song: Identifiable, Codable, Hashable, Sendable {
    let platform: MusicPlatform
    let platformID: String
    let name: String
    let singer: String
    let album: String
    let duration: TimeInterval
    let picURL: String?

    var id: String { "\(platform.rawValue)_\(platformID)" }

    /// 秒数（整数口径，与 Android `Song.durationSec` 对齐：时长判定、码率换算都用它）
    var durationSec: Int { Int(duration.rounded()) }

    /// 搜索关键词（歌名 + 空格 + 歌手，供搜索式取流源使用）
    var searchKeyword: String {
        let kw = "\(name) \(singer)".trimmingCharacters(in: .whitespacesAndNewlines)
        return kw.isEmpty ? name : kw
    }

    /// 无空格拼接「歌名+歌手」——妖狐酷我通道必须这么传（带空格会被服务端转成 "&" 返回错歌）
    var searchKeywordCompact: String {
        (name + singer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 时长格式化 mm:ss
    var durationText: String {
        guard duration > 0 else { return "--:--" }
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

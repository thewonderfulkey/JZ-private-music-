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

// MARK: - 文本清洗（接口脏字符）
//
// 四家接口都会往文本字段里塞"看起来像转义、其实已经死了"的字符串，实测两类：
//   · QQ 的合唱歌手返回**字面量** `\u0026`（JSON 里被双重转义，解出来就是反斜杠+u0026）：
//     `周杰伦\u0026Lara梁心颐`——直接进 UI 就是这个鬼样子（真机录屏里能看见）；
//   · 网易/酷我偶发 `&nbsp;`、`&amp;`、全角空格、零宽字符/BOM。
// 在模型层洗一次，搜索页、收藏、下载列表、锁屏/灵动岛就都干净了。
enum TextClean {

    static func text(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw.contains("\\u") ? decodeEscapes(raw) : raw
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"),
            ("&lt;", "<"), ("&gt;", ">"),
            ("\u{00A0}", " "), ("\u{200B}", ""), ("\u{FEFF}", ""),
        ]
        for (from, to) in entities {
            if s.contains(from) { s = s.replacingOccurrences(of: from, with: to) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把字面量 `\uXXXX` 还原成字符（接口把中文也这样转过义）。
    /// 逐段重建而不是就地替换：就地改长度会让后面 match 的 NSRange 失效。
    static func decodeEscapes(_ raw: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\\\u([0-9a-fA-F]{4})") else { return raw }
        let ns = raw as NSString
        let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return raw }
        var out = ""
        var cursor = 0
        for m in matches where m.numberOfRanges == 2 {
            let start = m.range.location
            if start > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: start - cursor))
            }
            let hex = ns.substring(with: m.range(at: 1))
            if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                out.unicodeScalars.append(scalar)
            } else {
                out += ns.substring(with: m.range)
            }
            cursor = start + m.range.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
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

    // MARK: 构造（统一清洗文本）

    /// 解析层唯一入口：文本字段先过 `TextClean`，避免脏字符漏进任何一处 UI。
    static func make(platform: MusicPlatform, platformID: String, name: String,
                     singer: String, album: String, duration: TimeInterval,
                     picURL: String?) -> Song {
        Song(platform: platform,
             platformID: platformID,
             name: TextClean.text(name),
             singer: TextClean.text(singer),
             album: TextClean.text(album),
             duration: duration,
             picURL: picURL)
    }
}

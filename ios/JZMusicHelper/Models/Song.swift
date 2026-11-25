import Foundation

// MARK: - 平台枚举
enum MusicPlatform: String, Codable, CaseIterable, Identifiable, Hashable {
    case kuwo = "kuwo"
    case qq = "qq"
    case netease = "netease"
    case kugou = "kugou"
    /// 本地导入的文件（离线资料库）。platformID = 导入条目的稳定 id
    case local = "local"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kuwo: return "酷我音乐"
        case .qq: return "QQ音乐"
        case .netease: return "网易云音乐"
        case .kugou: return "酷狗音乐"
        case .local: return "本地文件"
        }
    }

    var shortName: String {
        switch self {
        case .kuwo: return "酷我"
        case .qq: return "QQ"
        case .netease: return "网易"
        case .kugou: return "酷狗"
        case .local: return "本地"
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

    /// 档位名 + **实测码率**（2026-11-26 老板 ⑧：档位虚标）。
    ///
    /// 背景：`standard` 这一档的定义是 48–255kbps（见 `QualityFacts.standardBandKbps`），
    /// 所以一条 96kbps 的源会被标成「标准 128k」，下载列表里就写着「标准 128k · 2.6 MB」——
    /// 老板看到的就是"虚标"。实话是把实测值并排写出来。
    var nominalKbps: Int64 {
        switch self {
        case .standard: return 128
        case .high: return 320
        case .lossless: return 0
        }
    }

    /// 列表行用：「标准 128k（实测 96k）」；实测等于标称就只写档位名
    func labeled(kbps: Int64) -> String {
        guard kbps > 0 else { return displayName }
        let nominal = nominalKbps
        if nominal > 0, abs(kbps - nominal) <= 24 { return displayName }
        return "\(displayName)（实测 \(kbps)k）"
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
    /// 元数据出处（标签 / 文件名推测 / 联网匹配 / 手动编辑）+ 字段锁（第 44 轮）
    ///
    /// 为什么挂在 `Song` 上而不是只挂 `DownloadItem`：这份 `Song` 会被**四处快照各存一份**
    /// （downloads.json / 收藏 / 导入歌单 / 播放队列），挂在 Song 上等于让出处跟着值走，
    /// 不会出现"下载页已经手改了、收藏里还是旧的、也不知道哪个是手填的"。
    /// 可选类型：旧 JSON 没有这个键，解码不能失败。
    let meta: MetaProvenance?

    var id: String { "\(platform.rawValue)_\(platformID)" }

    /// 全参构造（`meta` 有默认值，老调用点一行都不用改）
    init(platform: MusicPlatform, platformID: String, name: String, singer: String,
         album: String, duration: TimeInterval, picURL: String?,
         meta: MetaProvenance? = nil) {
        self.platform = platform
        self.platformID = platformID
        self.name = name
        self.singer = singer
        self.album = album
        self.duration = duration
        self.picURL = picURL
        self.meta = meta
    }

    /// 造一份只改了元数据的副本：**`platformID` 永远不变**（它是收藏/队列/去重的主键），
    /// 音频文件名与旁车基名也不受影响（旁车靠磁盘文件名推导，不靠这些字段）。
    func with(name: String? = nil, singer: String? = nil, album: String? = nil,
              picURL: String?? = nil, meta: MetaProvenance? = nil) -> Song {
        Song(platform: platform,
             platformID: platformID,
             name: name ?? self.name,
             singer: singer ?? self.singer,
             album: album ?? self.album,
             duration: duration,
             picURL: picURL ?? self.picURL,
             meta: meta ?? self.meta)
    }

    /// 封面代次（没 meta 就是 0）：列表行与锁屏判重都要带它，否则"图换了但界面还是旧的"
    var coverRevision: Int { meta?.coverRevision ?? 0 }

    /// 元数据出处（老数据没有 meta → 按"未匹配"处理，不冒充标签）
    var metaSource: MetaSource { meta?.source ?? .unmatched }

    var metaSourceLabel: String { meta?.source.label ?? MetaSource.unmatched.label }

    // 相等/哈希**不看 meta**：同一首歌换个封面不该变成"另一首歌"（收藏去重、Set 都靠这个）
    static func == (lhs: Song, rhs: Song) -> Bool {
        lhs.platform == rhs.platform && lhs.platformID == rhs.platformID
            && lhs.name == rhs.name && lhs.singer == rhs.singer
            && lhs.album == rhs.album && lhs.duration == rhs.duration
            && lhs.picURL == rhs.picURL
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(platform.rawValue)
        hasher.combine(platformID)
        hasher.combine(name)
        hasher.combine(singer)
        hasher.combine(album)
    }

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
    ///
    /// `meta`：元数据出处（第 44 轮）。网络搜索出来的歌不需要它（nil = 不是本地导入），
    /// 只有本地导入才标 `tag` / `filenameGuess`。
    static func make(platform: MusicPlatform, platformID: String, name: String,
                     singer: String, album: String, duration: TimeInterval,
                     picURL: String?, meta: MetaProvenance? = nil) -> Song {
        Song(platform: platform,
             platformID: platformID,
             name: TextClean.text(name),
             singer: TextClean.text(singer),
             album: TextClean.text(album),
             duration: duration,
             picURL: picURL,
             meta: meta)
    }
}

// MARK: - 收藏的「文件级」身份（2026-11-21 老板需求）
//
// 老板："比对多项维度，但最重要的是歌曲文件是否一样；一样就合并、换专辑原封面；
//        两首不同平台的歌再次搜索依旧都显示已收藏。"
//
// "文件一样"不需要下载整首：解析出真实流后，**总字节数 + 时长**就够。
// 实测（2026-11-21）同一首 320k《晴天》在 ikun / 酷狗 zddyr / 落月 vkeys 都是
// **10,792,943 B**，一个字节不差；不同码率的同一首则字节不同（那种只在元数据级合并）。
struct FavoriteFingerprint: Codable, Equatable {
    let bytes: Int64
    let durationSec: Int
    let kbps: Int64
    let capturedAt: Date
}

enum FavoriteIdentity {

    /// 低于这个体积的一律不参与文件级去重。
    ///
    /// **这是硬闸门**：酷我对所有受限歌回的是同一段 181,521 B 的提示音（md5 43fe5f64…），
    /// 要是拿它当指纹，周杰伦十几首会被并成一首——比"留重复"严重得多。
    static let minContentBytes: Int64 = 300_000

    /// 两个指纹是不是同一个文件（纯函数，CI 断言）
    ///
    /// 判据：字节数**完全相等** + 时长差 ≤1s（同一文件跨平台翻录会有 0–1s 的容器差）。
    /// 码率只用来展示，不参与判定（同一文件算出来的码率本来一样）。
    static func isSameFile(_ a: FavoriteFingerprint, _ b: FavoriteFingerprint) -> Bool {
        guard a.bytes >= minContentBytes, b.bytes >= minContentBytes else { return false }
        guard a.bytes == b.bytes else { return false }
        return abs(a.durationSec - b.durationSec) <= 1
    }

    /// 这个指纹值不值得收（占位/残片直接丢）
    static func isUsable(bytes: Int64, durationSec: Int) -> Bool {
        guard bytes >= minContentBytes else { return false }
        // 181,521 B 的窗口再挡一次（万一将来门槛被调小）
        let placeholderWindow: ClosedRange<Int64> = 150_000...210_000
        if placeholderWindow.contains(bytes) { return false }
        return durationSec > 0
    }
}

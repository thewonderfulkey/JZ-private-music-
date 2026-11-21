import Foundation

// MARK: - 歌曲元数据的「出处 / 字段锁」（第 44 轮）
//
// ⚠️ **这个文件同时编进两个 target**：`JZMusicHelper`（app）和 `JZWidgets`（锁屏/桌面小组件）。
// 原因：`Song.swift` 本来就两边都编（widget 共享模型），而 `Song.meta` 的类型必须跟着它走。
// 匹配逻辑（`MetadataMatcher`，400 多行、还带网络调用）**只进 app**，别搬进 widget。
//
// 所以分工是：
//   · `SongMeta.swift`（本文件）：纯数据 —— 出处枚举、字段枚举、`MetaProvenance` 值类型；
//   · `MetadataMatcher.swift`（只进 app）：解释 A/B、打分、阈值、写回、联网搜索。
//
// 踩过的坑：v2.4.54 第一次构建失败（run 44878120251）就是 `MetaProvenance` 定义在
// `MetadataMatcher.swift` 里、而 widget 也编 `Song.swift` → `cannot find type 'MetaProvenance' in scope`。

// MARK: - 出处

enum MetaSource: String, Codable, Hashable, Sendable {
    /// 文件标签（AVFoundation commonMetadata）
    case tag
    /// 标签缺 → 用文件名推的（可能拆反）
    case filenameGuess
    /// 联网匹配写回的
    case matched
    /// 用户手动编辑的
    case manual
    /// 都没有（留空，可重试）
    case unmatched

    var label: String {
        switch self {
        case .tag: return "标签"
        case .filenameGuess: return "文件名推测"
        case .matched: return "联网匹配"
        case .manual: return "手动编辑"
        case .unmatched: return "未匹配"
        }
    }
}

enum MetaField: String, Codable, Hashable, CaseIterable, Sendable {
    case name, singer, album, cover

    var label: String {
        switch self {
        case .name: return "歌名"
        case .singer: return "歌手"
        case .album: return "专辑"
        case .cover: return "封面"
        }
    }
}

/// 一个 Song 的元数据出处。**整体随 Song 走**（四处快照各自持有一份 Song，就不用额外同步这张表）。
struct MetaProvenance: Codable, Hashable, Sendable {

    var source: MetaSource = .unmatched
    /// 用户手填过的字段：自动匹配/再匹配**永不覆盖**，直到用户点「恢复自动」
    var locked: [MetaField] = []
    /// 命中平台（"qq" / "netease" / "kuwo"），没有就是 nil
    var matchedPlatform: String?
    /// 命中曲目在该平台的 id（QQ 就是 songmid，可直接拿去取官方词）
    var matchedID: String?
    /// 置信分 0…1（阈值见 `MetadataMatcher.autoThreshold`）
    var score: Double = 0
    /// 改过歌名/歌手之后，旧封面可能已经不是这首歌的图
    var coverStale: Bool = false
    /// 封面代次：每换一次封面 +1。列表行/锁屏判重都带它，否则"图换了但界面还是旧的"
    var coverRevision: Int = 0

    init(source: MetaSource = .unmatched,
         locked: [MetaField] = [],
         matchedPlatform: String? = nil,
         matchedID: String? = nil,
         score: Double = 0,
         coverStale: Bool = false,
         coverRevision: Int = 0) {
        self.source = source
        self.locked = locked
        self.matchedPlatform = matchedPlatform
        self.matchedID = matchedID
        self.score = score
        self.coverStale = coverStale
        self.coverRevision = coverRevision
    }

    func isLocked(_ field: MetaField) -> Bool { locked.contains(field) }

    mutating func lock(_ field: MetaField) {
        if !locked.contains(field) { locked.append(field) }
    }

    mutating func unlock(_ field: MetaField) {
        locked.removeAll { $0 == field }
    }

    /// 日志口径：`tag` / `filenameGuess` / `matched:qq` / `manual` / `unmatched`
    var logTag: String {
        if let p = matchedPlatform, !p.isEmpty, source == .matched { return "matched:\(p)" }
        return source.rawValue
    }

    /// 有没有"还是空着、可以再试一次"的字段（给批量补全算缺口）
    static func needsFill(_ song: Song) -> Bool {
        let meta = song.meta
        if song.name.isEmpty || song.singer.isEmpty || song.album.isEmpty { return true }
        return meta == nil || meta?.source == .unmatched || meta?.source == .tag
            || meta?.matchedID == nil
    }
}

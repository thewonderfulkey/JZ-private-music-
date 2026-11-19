import Foundation

// MARK: - 心动模式：判定口径与排序算法（纯函数）
//
// 为什么单独抽一个文件：这套东西改错了界面不会崩，只会表现为"推的歌越来越不对"
// （或者同一个人连着听三首）。

// 而它全是可判定的算术，CI 的 logic-tests 用 `swiftc` 直接把本文件和 `Song.swift` 一起编译断言。
//
// 口径（老板 2026-11-19 拍板）：
//   · 画像四通道权重：**下载 > 收藏 > 搜索 > 播放**
//   · 新旧比例用户可在设置里调（滑杆 → `oldShare`），默认 1/3 旧、2/3 新
//   · 「不感兴趣」是硬负反馈：这首歌不再出现，同歌手降权
//
// 与 Android / 桌面版的关系：那边用 `GuessEngine` + `SongProfile`，
// 本文件是同一套特征的 iOS 实现（歌手 2.0 / 风格 1.5 / 语种 1.0 / 歌名词元 1.0，数值一致），
// 但多了「时间衰减 + 通道饱和 + MMR + 新旧调度」——那几样是流式连播才需要的。

// MARK: - 播放事件

/// 一次播放（心动模式的画像原料）。
///
/// 与 `LibraryStore.recentSongs` 的区别：那边是"最近 50 首"的去重列表（给 UI 的），
/// 这里带**开始时间 / 已听秒数 / 是否播完**——画像要用时长判质量，跳过要用秒数判负反馈。
struct HeartbeatPlayEvent: Codable, Hashable {
    var key: String
    var song: Song
    var startedAt: Date
    var listenedSec: Double
    var completed: Bool

    init(song: Song,
         startedAt: Date = Date(),
         listenedSec: Double = 0,
         completed: Bool = false) {
        self.key = song.id
        self.song = song
        self.startedAt = startedAt
        self.listenedSec = listenedSec
        self.completed = completed
    }
}

// MARK: - 画像

struct HeartbeatSearchHint: Hashable {
    let keyword: String
    let weight: Double
}

struct HeartbeatProfile {
    /// 稀疏内容向量（歌手 / 风格 / 语种 / 歌名词元），cosine 用
    var vec: [String: Double] = [:]
    /// 歌手亲和度（键 = 主歌手）
    var artist: [String: Double] = [:]
    /// 风格亲和度
    var tag: [String: Double] = [:]
    /// 最近一次播放时间（"多久没听"用）
    var lastPlayed: [String: Date] = [:]
    var playCount: [String: Int] = [:]
    /// 近 7 天听过的歌：新歌通道硬排除
    var seen7d: Set<String> = []
    /// 搜索历史（带衰减后的权重，直接命中歌名/歌手时加分并作为推荐理由）
    var searchHints: [HeartbeatSearchHint] = []
    var topArtists: [String] = []
    var topTags: [String] = []

    var isEmpty: Bool { vec.isEmpty && artist.isEmpty }
}

enum HeartbeatReason: String, Sendable {
    case download
    case favorite
    case search
    case seed
    case artist
    case explore
    /// 冷启动 / 兜底：平台官方热歌榜（"大家都在听"，定义见 `HeartbeatEngine.hotCandidates`）
    case hot
}

struct HeartbeatScored {
    let song: Song
    let score: Double
    let reason: HeartbeatReason
    /// 文案里要用的名字（歌手 / 关键词 / 种子歌名）
    let detail: String
}

// MARK: - 规则

enum HeartbeatRules {

    // MARK: 四通道权重（下载 > 收藏 > 搜索 > 播放）

    static let wDownload: Double = 1.00
    static let wFavorite: Double = 0.80
    static let wSearch: Double = 0.60
    static let wPlay: Double = 0.40

    /// 软饱和的"膝点"：各通道的自然密度不同（播放远多于下载），用不同的 K 让贡献上限都等于自己的权重。
    static let kneeDownload: Double = 5
    static let kneeFavorite: Double = 8
    static let kneeSearch: Double = 10
    static let kneePlay: Double = 30

    /// 时间衰减半衰期（天）：下载/收藏是长期口味，播放/搜索是当下口味
    static let halfLifeDownload: Double = 60
    static let halfLifeFavorite: Double = 45
    static let halfLifePlay: Double = 14
    static let halfLifeSearch: Double = 10

    /// 新旧比例默认值（旧 = 收藏/下载过的歌）与可调范围
    static let defaultOldShare: Double = 1.0 / 3.0
    static let minOldShare: Double = 0
    static let maxOldShare: Double = 0.6

    /// 同一首歌在 48 小时内不再进"旧爱"位（刚听过的不算怀旧）
    static let oldChannelFreshnessHours: Double = 48

    /// 热歌榜兜底（冷启动 / 两个池子都空）：
    /// 取榜单前 `hotSourceSize` 首筛原版，最终池子保留 `hotPoolLimit` 首。
    static let hotSourceSize = 60
    static let hotPoolLimit = 20

    // MARK: 画像

    static func buildProfile(downloads: [(song: Song, at: Date)],
                             favorites: [(song: Song, at: Date)],
                             searches: [(keyword: String, at: Date)],
                             plays: [HeartbeatPlayEvent],
                             now: Date = Date()) -> HeartbeatProfile {
        var p = HeartbeatProfile()

        for e in plays {
            if let prev = p.lastPlayed[e.key] {
                if e.startedAt > prev { p.lastPlayed[e.key] = e.startedAt }
            } else {
                p.lastPlayed[e.key] = e.startedAt
            }
            p.playCount[e.key, default: 0] += 1
            if now.timeIntervalSince(e.startedAt) <= 7 * 86_400 {
                p.seen7d.insert(e.key)
            }
        }

        addSongChannel(&p,
                       events: downloads.map { ChannelEvent(song: $0.song, at: $0.at, quality: 1.0) },
                       weight: wDownload, knee: kneeDownload,
                       halfLife: halfLifeDownload, now: now)
        addSongChannel(&p,
                       events: favorites.map { ChannelEvent(song: $0.song, at: $0.at, quality: 1.0) },
                       weight: wFavorite, knee: kneeFavorite,
                       halfLife: halfLifeFavorite, now: now)
        addSongChannel(&p,
                       events: plays.map {
                           ChannelEvent(song: $0.song,
                                        at: $0.startedAt,
                                        quality: playQuality($0))
                       },
                       weight: wPlay, knee: kneePlay,
                       halfLife: halfLifePlay, now: now)
        addSearchChannel(&p, searches: searches, plays: plays, now: now)

        // 归一化到 0~1：歌手/风格亲和度要能比较"更亲"和"一般亲"。
        // 不归一化的话前几名都会 >1，进 `score` 又被 clamp 到 1，排序就退化成"全都一样"。
        if let maxArtist = p.artist.values.max(), maxArtist > 0 {
            p.artist = p.artist.mapValues { $0 / maxArtist }
        }
        if let maxTag = p.tag.values.max(), maxTag > 0 {
            p.tag = p.tag.mapValues { $0 / maxTag }
        }

        p.topArtists = p.artist.sorted { $0.value > $1.value }.prefix(4).map { $0.key }
        p.topTags = p.tag.sorted { $0.value > $1.value }.prefix(3).map { $0.key }
        return p
    }

    /// 一次播放的"质量"：听完了 ≈ 1，听一半 ≈ 0.5，30 秒内切掉 ≈ 0.3（下限）
    static func playQuality(_ e: HeartbeatPlayEvent) -> Double {
        let total = e.song.duration
        guard total > 1 else { return e.completed ? 1.0 : 0.6 }
        let ratio = e.listenedSec / total
        return min(1.0, max(0.3, ratio))
    }

    private struct ChannelEvent {
        let song: Song
        let at: Date
        let quality: Double
    }

    /// 把一条通道的贡献压到 `weight` 以内，再按事件权重分配到内容向量上。
    ///
    /// 为什么必须饱和：直接按条数加权，500 条播放记录一定压死 3 条下载，
    /// "下载 > 收藏 > 搜索 > 播放"就名存实亡了。
    private static func addSongChannel(_ p: inout HeartbeatProfile,
                                       events: [ChannelEvent],
                                       weight: Double,
                                       knee: Double,
                                       halfLife: Double,
                                       now: Date) {
        guard !events.isEmpty else { return }
        let distinct = Set(events.map { $0.song.id }).count
        let mass = weight * (1 - exp(-Double(distinct) / max(0.5, knee)))

        var total = 0.0
        var weighted: [(ChannelEvent, Double)] = []
        for e in events {
            let days = max(0, now.timeIntervalSince(e.at) / 86_400)
            let w = decay(ageDays: days, halfLife: halfLife) * e.quality
            weighted.append((e, w))
            total += w
        }
        guard total > 0 else { return }

        for (e, w) in weighted {
            let share = mass * w / total
            for (k, v) in features(e.song) {
                p.vec[k, default: 0] += v * share
            }
            let singer = primarySinger(e.song)
            if !singer.isEmpty {
                p.artist[singer, default: 0] += share
            }
            for t in tags(e.song) {
                p.tag[t, default: 0] += share * 0.8
            }
        }
    }

    /// 搜索通道：关键词不是歌，只能做两件事——直接命中歌名/歌手时加权，或作为推荐理由。
    ///
    /// 转化过（搜完真的听了一首能对上的歌）权重高，只搜没听权重低。
    private static func addSearchChannel(_ p: inout HeartbeatProfile,
                                         searches: [(keyword: String, at: Date)],
                                         plays: [HeartbeatPlayEvent],
                                         now: Date) {
        guard !searches.isEmpty else { return }
        let distinct = Set(searches.map { $0.keyword.lowercased() }).count
        let mass = wSearch * (1 - exp(-Double(distinct) / max(0.5, kneeSearch)))

        var total = 0.0
        var weighted: [(String, Double)] = []
        for s in searches {
            let days = max(0, now.timeIntervalSince(s.at) / 86_400)
            let converted = plays.contains { playMatches($0.song, keyword: s.keyword) }
            let quality = converted ? 1.0 : 0.5
            let w = decay(ageDays: days, halfLife: halfLifeSearch) * quality
            weighted.append((s.keyword, w))
            total += w
        }
        guard total > 0 else { return }

        for (kw, w) in weighted {
            p.searchHints.append(HeartbeatSearchHint(keyword: kw, weight: mass * w / total))
            // 关键词恰好就是某位歌手时，直接算进歌手亲和度（"搜周杰伦" = 想听周杰伦）
            let singer = kw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !singer.isEmpty {
                p.artist[singer, default: 0] += mass * w / total * 0.6
            }
        }
    }

    static func playMatches(_ song: Song, keyword: String) -> Bool {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return false }
        return song.name.lowercased().contains(kw) || song.singer.lowercased().contains(kw)
    }

    // MARK: 时间衰减

    static func decay(ageDays: Double, halfLife: Double) -> Double {
        guard halfLife > 0 else { return 1 }
        return pow(0.5, max(0, ageDays) / halfLife)
    }

    // MARK: 特征（与桌面版 `SongProfile` 同权重）

    static func primarySinger(_ song: Song) -> String {
        DiscoverRules.singerKey(song.singer)
    }

    static func languageTag(_ song: Song) -> String {
        let singer = song.singer
        let letters = singer.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if !letters.isEmpty, letters.allSatisfy({ $0.value < 0x0250 }) {
            return "欧美"
        }
        return "华语"
    }

    static func features(_ song: Song) -> [String: Double] {
        var f: [String: Double] = [:]
        let singer = primarySinger(song)
        if !singer.isEmpty { f["singer:" + singer] = 2.0 }
        f["lang:" + languageTag(song)] = 1.0
        for t in tags(song) { f["tag:" + t] = 1.5 }
        let name = song.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(name)
        if chars.count >= 2 {
            for i in 0..<(chars.count - 1) {
                f["ng:" + String(chars[i...i + 1]), default: 0] += 1.0
            }
        }
        return f
    }

    static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        var dot = 0.0
        for (k, v) in small {
            if let other = large[k] { dot += v * other }
        }
        let na = sqrt(a.values.reduce(0) { $0 + $1 * $1 })
        let nb = sqrt(b.values.reduce(0) { $0 + $1 * $1 })
        guard na > 0, nb > 0 else { return 0 }
        return min(1.0, dot / (na * nb))
    }

    /// 歌手 → 风格标签。没收录的歌手用「语种」兜底（至少能挡住"华语 ↔ 欧美"的跳变）。
    static let styleTags: [String: Set<String>] = [
        "周杰伦": ["华语流行", "R&B", "中国风"],
        "林俊杰": ["华语流行"],
        "陈奕迅": ["华语流行", "粤语流行", "情歌"],
        "王菲": ["华语流行", "粤语流行", "影视OST"],
        "孙燕姿": ["华语流行"],
        "梁静茹": ["华语流行", "情歌"],
        "张惠妹": ["华语流行"],
        "李荣浩": ["华语流行"],
        "薛之谦": ["华语流行", "情歌"],
        "毛不易": ["民谣", "华语流行"],
        "赵雷": ["民谣"],
        "朴树": ["民谣", "摇滚"],
        "李健": ["民谣", "影视OST"],
        "邓紫棋": ["华语流行", "摇滚"],
        "田馥甄": ["华语流行", "情歌"],
        "刘若英": ["华语流行", "情歌"],
        "张信哲": ["情歌", "华语流行"],
        "张学友": ["粤语流行", "华语流行"],
        "张国荣": ["粤语流行", "影视OST"],
        "李克勤": ["粤语流行"],
        "陈慧娴": ["粤语流行"],
        "杨千嬅": ["粤语流行"],
        "Beyond": ["粤语摇滚", "摇滚"],
        "周深": ["华语流行", "影视OST"],
        "张碧晨": ["华语流行", "影视OST"],
        "张杰": ["华语流行", "影视OST"],
        "张靓颖": ["华语流行", "影视OST"],
        "那英": ["华语流行", "影视OST"],
        "于文文": ["华语流行", "影视OST"],
        "霍尊": ["国风"],
        "袁娅维": ["R&B", "影视OST"],
        "Adele": ["欧美流行", "灵魂乐"],
        "Ed Sheeran": ["欧美流行"],
        "Taylor Swift": ["欧美流行"],
        "Coldplay": ["英伦摇滚", "欧美"],
        "OneRepublic": ["欧美流行", "摇滚"],
        "Maroon 5": ["欧美流行"],
        "Imagine Dragons": ["摇滚", "欧美"],
        "Linkin Park": ["摇滚", "欧美"],
        "Billie Eilish": ["欧美流行"],
        "Bruno Mars": ["欧美流行", "放克"],
        "The Weeknd": ["R&B", "欧美"],
        "Lady Gaga": ["欧美流行"],
        "Alan Walker": ["电音"],
        "Marshmello": ["电音"],
    ]

    static func tags(_ song: Song) -> Set<String> {
        let singer = primarySinger(song)
        if let t = styleTags[singer], !t.isEmpty { return t }
        return [languageTag(song)]
    }

    // MARK: 打分

    static func bestSearchHint(_ song: Song, hints: [HeartbeatSearchHint]) -> HeartbeatSearchHint? {
        var best: HeartbeatSearchHint?
        for h in hints where playMatches(song, keyword: h.keyword) {
            if best == nil || h.weight > best!.weight { best = h }
        }
        return best
    }

    /// 候选打分（0~100）。`priorIndex` = 该候选在本轮搜索结果里的名次。
    static func score(song: Song,
                      profile: HeartbeatProfile,
                      seed: Song?,
                      downloaded: Bool,
                      favorited: Bool,
                      priorIndex: Int,
                      now: Date = Date()) -> HeartbeatScored {
        let content = cosine(profile.vec, features(song)) * 100
        let seedSim = seed.map { cosine(features($0), features(song)) * 100 } ?? 0
        let artistAff = min(1.0, profile.artist[primarySinger(song)] ?? 0) * 100
        let known = downloaded ? 100.0 : (favorited ? 85.0 : 0.0)
        let prior = max(0.0, 60.0 - Double(max(0, priorIndex)) * 6.0)
        let fresh = profile.lastPlayed[song.id] == nil ? 100.0 : 0.0
        let hint = bestSearchHint(song, hints: profile.searchHints)
        let searchHit = min(1.0, (hint?.weight ?? 0) * 2.5) * 100

        let total = 0.30 * content + 0.22 * seedSim + 0.18 * artistAff
            + 0.12 * known + 0.06 * prior + 0.06 * fresh + 0.06 * searchHit

        let singer = primarySinger(song)
        let reason: HeartbeatReason
        let detail: String
        if downloaded {
            reason = .download
            detail = singer
        } else if favorited {
            reason = .favorite
            detail = singer
        } else if let hint, hint.weight >= 0.12 {
            reason = .search
            detail = hint.keyword
        } else if seedSim >= 55 {
            reason = .seed
            detail = seed?.name ?? ""
        } else if artistAff >= 35 {
            reason = .artist
            detail = singer
        } else {
            reason = .explore
            detail = ""
        }
        return HeartbeatScored(song: song, score: total, reason: reason, detail: detail)
    }

    /// 乘性惩罚（在打分之后、挑选之前）。
    ///
    /// 硬过滤（返回 0）：本会话已播、不感兴趣、队列里已有、同歌手在最近窗口里出现 ≥3 次。
    static func penalty(song: Song,
                        sessionKeys: Set<String>,
                        seen7d: Set<String>,
                        recentSongs: [Song],
                        recentArtists: [String],
                        recentTags: Set<String>,
                        dislikedKeys: Set<String>,
                        dislikedArtists: Set<String>) -> Double {
        if sessionKeys.contains(song.id) { return 0 }
        if dislikedKeys.contains(song.id) { return 0 }
        if recentSongs.contains(where: { $0.id == song.id }) { return 0 }

        var p = 1.0
        let singer = primarySinger(song)
        if !singer.isEmpty, dislikedArtists.contains(singer) { p *= 0.15 }
        if !singer.isEmpty {
            if recentArtists.suffix(2).contains(singer) { p *= 0.30 }
            if recentArtists.filter({ $0 == singer }).count >= 3 { return 0 }
        }
        if seen7d.contains(song.id) { p *= 0.15 }
        if !recentTags.isEmpty, tags(song).isDisjoint(with: recentTags) { p *= 0.55 }
        return p
    }

    /// 「多久没听」加分：收藏很久没听的最值得翻出来（最多 +18）
    static func stalenessBonus(lastPlayed: Date?, now: Date = Date()) -> Double {
        guard let lastPlayed else { return 18 }
        let days = max(0, now.timeIntervalSince(lastPlayed) / 86_400)
        return min(18, days * 0.6)
    }

    // MARK: 多样性挑选（MMR）

    /// 贪心 MMR：在"分数高"和"跟最近几首不像"之间折中，避免连着三首同款。
    static func diversify(_ scored: [HeartbeatScored],
                          limit: Int,
                          recent: [Song],
                          penaltyPerSim: Double = 22) -> [HeartbeatScored] {
        guard limit > 0 else { return [] }
        let recentFeatures = recent.suffix(5).map { features($0) }
        var pool = scored.sorted { $0.score > $1.score }
        var picked: [HeartbeatScored] = []
        while picked.count < limit, !pool.isEmpty {
            var bestIndex = 0
            var bestValue = -Double.greatestFiniteMagnitude
            for (i, c) in pool.enumerated() {
                let f = features(c.song)
                let sim = recentFeatures.map { cosine(f, $0) }.max() ?? 0
                let v = c.score - sim * penaltyPerSim
                if v > bestValue {
                    bestValue = v
                    bestIndex = i
                }
            }
            picked.append(pool.remove(at: bestIndex))
        }
        return picked
    }

    // MARK: 新旧混合

    static func clampOldShare(_ v: Double) -> Double {
        min(maxOldShare, max(minOldShare, v))
    }

    /// 第 `position` 首要不要放"旧爱"（1 起算，position=1 是下一首）。
    ///
    /// 用 Bresenham 式累加而不是抛硬币：`oldShare = 1/3` 得到「新 新 旧」循环，
    /// `0.5` 得到「新 旧 新 旧」，比例精确、不会出现连续 4 首旧歌。第 1 首永远是新歌。
    static func wantsOld(position: Int, oldShare: Double) -> Bool {
        guard position > 0 else { return false }
        let share = clampOldShare(oldShare)
        guard share > 0 else { return false }
        let before = Int((Double(position - 1) * share).rounded(.down))
        let after = Int((Double(position) * share).rounded(.down))
        return after > before
    }

    // MARK: 文案

    /// 文案。`detail` 的含义随理由不同：歌手名 / 关键词 / 种子歌名。
    static func reasonText(_ reason: HeartbeatReason, detail: String) -> String {
        switch reason {
        case .download:
            return detail.isEmpty ? "你下载过的歌" : "你下载过 \(detail) 的歌"
        case .favorite:
            return detail.isEmpty ? "你收藏过的歌" : "你收藏过 \(detail)"
        case .search:
            return "搜过「\(detail)」"
        case .seed:
            return detail.isEmpty ? "和刚才那首同风格" : "和《\(detail)》同风格"
        case .artist:
            return detail.isEmpty ? "你常听的歌手" : "因为你常听 \(detail)"
        case .explore:
            return "为你探索"
        case .hot:
            // detail 是榜上名次（字符串）：让"为什么放这首"可解释，不是凭空一句"热门"
            return detail.isEmpty ? "大家都在听" : "热歌榜第 \(detail) 名"
        }
    }

    /// 候选的基本可用性（挡掉广告、片段、无歌手条目）
    static func isPlayableCandidate(_ song: Song) -> Bool {
        let name = song.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let singer = song.singer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !singer.isEmpty else { return false }
        guard song.duration >= 45, song.duration <= 1200 else { return false }
        return true
    }
}

import Foundation

// MARK: - 歌名 / 歌手归一化匹配
//
// 与 Android `NameMatch`（SourceAdapters.kt 末尾）同口径。解析链路的身份校验统一走这里，
// 解决两类"明明能解析却被跳过"的误杀：
//   ① 多歌手串顺序/分隔符不一致（"谭晶/陈奕迅" vs "陈奕迅、谭晶" vs "谭晶 陈奕迅"）
//   ② 歌名带版本后缀（"富士山下（Live）""龙文 - Live"）与搜索结果裸歌名不同
// 口径：歌名去括号版本说明与标点后相等，或长度差 ≤6 字且互相包含；歌手拆 token 后取交集。
enum NameMatch {

    private static let bracket = Pattern.make("（[^）]*）|\\([^)]*\\)|\\[[^\\]]*\\]|【[^】]*】")

    private static let punct = Pattern.make("[\\s·・\\-—_.,，、'\"“”‘’!！?？:：/\\\\&*+]")

    private static let singerSep = Pattern.make("[/&、,，\\s]+")

    /// 纯歌名归一化：去版本括号 + 去标点空白
    static func normTitle(_ raw: String) -> String {
        // r125：统一 Unicode 规范化再比。韩文/日文歌名在两端可能一边 NFC 一边 NFD
        // （"연애의 조건" 的 NFD 是 ᄋᆢᆫ애…），字节不同但人看着一样——不归一化就会把同曲判成不同曲。
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        s = bracket.stringByReplacingMatches(in: s, range: full(s), withTemplate: "")
        s = punct.stringByReplacingMatches(in: s, range: full(s), withTemplate: "")
        return s
    }

    static func titleMatches(_ a: String, _ b: String) -> Bool {
        let x = normTitle(a)
        let y = normTitle(b)
        if x.isEmpty || y.isEmpty { return false }
        if x == y { return true }
        return abs(x.count - y.count) <= 6 && (x.contains(y) || y.contains(x))
    }

    /// 歌手拆分为单人 token（去括号说明，按 / & 、 ， 空格 拆）
    static func singerTokens(_ raw: String) -> Set<String> {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        s = bracket.stringByReplacingMatches(in: s, range: full(s), withTemplate: "")
        let parts = singerSep.stringByReplacingMatches(in: s, range: full(s), withTemplate: "\u{1}")
            .split(separator: "\u{1}", omittingEmptySubsequences: true)
            .map(String.init)
        var out = Set<String>()
        for p in parts {
            let cleaned = punct.stringByReplacingMatches(in: p, range: full(p), withTemplate: "")
            if !cleaned.isEmpty { out.insert(cleaned) }
        }
        return out
    }

    /// 歌手匹配：只要有一名共同歌手即视为同一曲（合唱/独唱差异交给时长校验兜底）
    static func singerMatches(_ a: String, _ b: String) -> Bool {
        let ta = singerTokens(a)
        let tb = singerTokens(b)
        if ta.isEmpty || tb.isEmpty { return true }   // 任一方无歌手信息时不拦
        if !ta.isDisjoint(with: tb) { return true }
        // 组合名整体包含（"凤凰传奇" vs "凤凰传奇/曾毅"）
        let sa = ta.joined()
        let sb = tb.joined()
        return sa.contains(sb) || sb.contains(sa)
    }

    // MARK: - 同曲判定（2026-11-19 老板口径重写）
    //
    // 旧口径「歌名归一化相等（或差 ≤6 字且互相包含）」把《恋爱的条件》和
    // 《연애의 조건 (Love Options)》判成两首歌——它们是同一首，只是译名不同。
    // 老板明确：**歌手第一优先，时长是硬闸门，歌名只做辅助，不做否决**。
    //
    // 现在的口径：
    //   ① 版本闸门：候选比源多出任何版本标记（live / 伴奏 / inst / remix / 翻唱 / 纯音乐 / dj /
    //      演唱会 / 粤语版 …）→ 不是同一条录音，直接拒。
    //      `(LOVE OPTIONS)`、`(恋爱的条件)` 这类**译名/副标题不属于版本**，不在标记表里，必须放行。
    //   ② 歌手：候选有歌手信息时必须与源有交集；候选没歌手信息才放给歌名判。
    //   ③ 时长：双方都有值时 |差| ≤ 4s（跨平台翻录通常 ≤2s），>4s 一律不收。
    //   ④ 歌名：归一化相等 → 通过；不等但「歌手 + 时长」都对上 → **也通过**（译名/副标题不同）。
    //      只有时长未知（gdstudio 搜索不返回时长）时才退回「歌名归一化必须相等」。

    /// 同一条录音允许的最大时长差（秒）。跨平台翻录通常 ≤2s；留 4s 余量。
    static let maxDurationDiffSec = 4

    /// 会改变录音身份的版本标记（ASCII 侧，词边界匹配，避免 "Deliver" 命中 "live"）
    private static let variantASCII = Pattern.make(
        "(?<![a-z0-9])(live|inst|instrumental|remix|dj|cover|ktv|karaoke|acoustic|unplugged)(?![a-z0-9])",
        options: [.caseInsensitive])

    /// CJK 侧版本标记 → 归一到「版本类」。同一类里互换不算新版本（如 (Inst.) vs (伴奏) 都归 inst）
    private static let variantCJK: [(cls: String, words: [String])] = [
        ("live", ["现场", "演唱会", "音乐会", "春晚", "晚会", "颁奖", "综艺"]),
        ("inst", ["伴奏", "消音", "纯音乐", "钢琴", "吉他", "古筝", "童声", "八音盒", "学唱"]),
        ("remix", ["电音", "咚鼓", "混音", "重制", "串烧"]),
        ("dj", ["dj版"]),
        ("cover", ["翻唱"]),
        ("clip", ["片段", "剪辑", "加速", "降速", "慢速"]),
        ("lang", ["粤语版", "国语版", "日语版", "韩语版", "英语版",
                  "男声版", "女声版", "男版", "女版"]),
        ("duet", ["合唱版", "对唱"]),
    ]

    /// 歌名里命中的「版本类」集合。空集 = 裸名原唱。
    static func versionClass(_ title: String) -> Set<String> {
        let s = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        guard !s.isEmpty else { return [] }
        var out = Set<String>()
        let range = full(s)
        for m in variantASCII.matches(in: s, range: range) {
            guard let r = Range(m.range, in: s) else { continue }
            let word = String(s[r])
            out.insert(word == "instrumental" ? "inst" : word)
        }
        for group in variantCJK where group.words.contains(where: { s.contains($0) }) {
            out.insert(group.cls)
        }
        return out
    }

    /// 同一条录音？（跨平台换源 / 网易专用检索 / 播放补源 全部走这里，只允许有一个口径）
    static func sameRecording(src: Song, cand: Song) -> Bool {
        if src.platform == cand.platform && src.platformID == cand.platformID { return false }

        // ① 版本闸门：候选多出来的版本类 = 这不是同一条录音
        let srcVer = versionClass(src.name)
        let candVer = versionClass(cand.name)
        if !candVer.isSubset(of: srcVer) { return false }

        // ② 歌手：候选有歌手信息就必须有交集（"发如雪(粤语版)/常颖杰"在这里被拒）
        let srcSingers = singerTokens(src.singer)
        let candSingers = singerTokens(cand.singer)
        if !candSingers.isEmpty {
            guard singerMatches(src.singer, cand.singer) else { return false }
        } else if srcSingers.isEmpty {
            // 两边都没有歌手信息：只能靠歌名
            return titleMatches(src.name, cand.name)
        }

        // ③ 时长硬闸门
        let sd = src.durationSec
        let cd = cand.durationSec
        if sd > 0 && cd > 0 {
            guard abs(sd - cd) <= maxDurationDiffSec else { return false }
            return true          // 歌手 + 时长都对上 → 歌名只做辅助（译名/副标题不同也放行）
        }

        // ④ 时长未知（gdstudio 搜索不返回时长）→ 歌名归一化必须相同
        return titleMatches(src.name, cand.name)
    }

    /// 主歌手（按分隔符取第一个，去掉括号说明）。
    /// 妖狐这类"搜索式"通道只要一个主歌手，别把「谭晶/陈奕迅」整串塞进去。
    static func primarySinger(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        s = bracket.stringByReplacingMatches(in: s, range: full(s), withTemplate: "")
        let head = s.split(whereSeparator: { "/&、,，;； ".contains($0) }).first.map(String.init) ?? ""
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 妖狐酷我通道的搜索串：**核心歌名 + 主歌手**（无空格，接口要求）。
    ///
    /// 2026-11-19 实测：原样拼「연애의 조건 (恋爱的条件) (LOVE OPTIONS)BESTie (베스티)」
    /// 妖狐先命中 `(INST)` 伴奏版（23,473,944 B）；只留「연애의 조건BESTie」时返回的是
    /// **原唱无损**（26,251,814 B，与 QQ 搜索里的 sizeFlac 一字节不差）。
    static func yaohuSearchKey(name: String, singer: String) -> String {
        let core = StudioPick.coreName(name)
        let artist = primarySinger(singer)
        let key = (core + artist).trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return key }
        return (name + singer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 妖狐酷我返回的 songtitle 形如 "歌名 — 歌手 * 专辑"，取短横线/星号前的歌名段
    static func yaohuTitle(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
        let head = normalized.split(whereSeparator: { $0 == "-" || $0 == "*" }).first.map(String.init)
        return (head ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 工具

    private static func full(_ s: String) -> NSRange {
        NSRange(s.startIndex..<s.endIndex, in: s)
    }
}

// MARK: - 收藏去重口径（2026-11-21 老板需求）
//
// 老板："收藏多了会忘掉已经收过这一首，又收一遍；封面不一样，但音乐文件是同一段。"
// 根因：`Song.id = 平台_ID`，同一首《晴天》在酷我/酷狗/QQ 各有一条 → 天然算三条。
// 所以去重不能用 id、不能用封面、也不能用 URL，只能用**同一条录音**这个口径
// （跨平台同曲靠 歌名核心 + 歌手 + 时长 ±4s + 版本类 判定）。
//
// 纯逻辑放在这里（而不是新建文件）是刻意的：新增 .swift 要同时改 pbxproj、CI 编译清单、
// 本地 run-selftest.sh 三处，漏一处就是"本地过了 CI 挂"。
enum FavoriteRules {

    /// 同一条录音？（**对称**口径，专用于收藏）
    ///
    /// 与 `NameMatch.sameRecording` 的区别：那个是"找源"用的（src 是目标、cand 是候选，
    /// 版本闸门是单向的 `candVer ⊆ srcVer`）。收藏去重要求两边平等，所以版本类必须**完全相等**——
    /// `晴天 (Live)` 绝不能被并进 `晴天`（老板要的是"同一段录音"，不是"同一首歌"）。
    static func isSameRecording(_ a: Song, _ b: Song) -> Bool {
        if a.id == b.id { return true }

        // ① 版本类必须一致（studio / live / 伴奏 / remix / 纯音乐 …）
        if NameMatch.versionClass(a.name) != NameMatch.versionClass(b.name) { return false }

        // ② 歌手：两边都有就必须有交集；都没有才退回歌名
        let sa = NameMatch.singerTokens(a.singer)
        let sb = NameMatch.singerTokens(b.singer)
        if !sa.isEmpty && !sb.isEmpty {
            guard NameMatch.singerMatches(a.singer, b.singer) else { return false }
        }

        // ③ 歌名：**分级判定**（老板 2026-11-21 补的口径：不同平台同原唱、标题带括号或差几个字，
        //    也算同一首）。分级顺序 = 完全等值 → 繁简归一后等值 → 高相似度；
        //    但仍然不能放过"同歌手的两首不同歌"（《夜曲》226s vs《稻香》223s 就是被这条挡住的反例）。
        let titleVerdict = titlesLookSame(a, b)
        guard titleVerdict.same else { return false }

        // ④ 时长：两边都有才判。
        //    标题完全相同 → ±4s（跨平台翻录通常 ≤2s）；标题只是"高度相似" → 收紧到 ±2s。
        let da = a.durationSec
        let db = b.durationSec
        if da > 0 && db > 0 {
            let diff = abs(da - db)
            return diff <= (titleVerdict.exact ? NameMatch.maxDurationDiffSec : 2)
        }
        // 有一边时长未知（gdstudio 搜索不返回时长）：标题完全等值就认；
        // 只是相似的话要求非常像（≥0.9），否则宁可不合并。
        return titleVerdict.exact || titleVerdict.similarity >= 0.9
    }

    /// 收藏去重用的歌名键：繁转简 + 剥括号说明 + 去掉标点/空白/大小写。
    ///
    /// `后来` 与 `後來`、`晴天` 与 `晴天 (原唱 周杰伦)`、`晴天` 与 `晴 天` 都归到同一个键。
    static func titleKey(_ name: String) -> String {
        let simplified = TradToSimpMap.toSimplified(name)
        let core = NameMatch.normTitle(simplified).lowercased()
        return String(core.filter { $0.isLetter || $0.isNumber })
    }

    /// 两个歌名键的相似度（最长公共子序列 / 较长者长度），0…1。
    ///
    /// 用 LCS 而不是编辑距离：中文歌名"差几个字"通常是中途少/多一个字，
    /// LCS 对"这世界那么多人 / 这世界这么多人"给 0.857，对"夜曲 / 稻香"给 0。
    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        let x = Array(a)
        let y = Array(b)
        var prev = [Int](repeating: 0, count: y.count + 1)
        var cur = prev
        for i in 1...x.count {
            cur[0] = 0
            for j in 1...y.count {
                cur[j] = (x[i - 1] == y[j - 1]) ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// 相似度门槛：0.75 能吃掉"差一两个字"（7 字名差 1 字 ≈ 0.857），
    /// 又放不过"爱情 / 爱情转移"（0.5）、"晴天 / 雨过天晴"（0.6）这种不同歌。
    static let titleSimilarityFloor = 0.75

    /// 收藏去重的歌名判定（纯函数，CI 断言）
    static func titlesLookSame(_ a: Song, _ b: Song) -> (same: Bool, exact: Bool, similarity: Double) {
        let ka = titleKey(a.name)
        let kb = titleKey(b.name)
        if !ka.isEmpty && ka == kb { return (true, true, 1) }
        // 太短的歌名（≤2 字）不做模糊：「晴天 / 情天」「爱 / 爱情」这种差一个字就是另一首
        let short = min(ka.count, kb.count)
        guard short >= 3 else { return (false, false, 0) }
        let sim = titleSimilarity(ka, kb)
        return (sim >= titleSimilarityFloor, false, sim)
    }

    /// 在收藏里找"同一条录音"的下标（交互入口用；一次操作 O(n)，收藏几千条也是毫秒级）
    static func duplicateIndex(of song: Song, in list: [Song]) -> Int? {
        list.firstIndex { isSameRecording($0, song) }
    }

    /// 合并两条：**保留已有那条的身份**（platform / platformID / 歌名 / 歌手不动），只补空字段。
    ///
    /// 为什么不换成新来的那条：收藏行的播放/下载都靠 platformID 取流，换身份会静默改变音源，
    /// 而用户这次点的可能正是"能出声的那条"。所以宁可只补封面/时长/专辑。
    static func merge(existing: Song, incoming: Song) -> Song {
        let pic: String? = {
            let old = (existing.picURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !old.isEmpty { return existing.picURL }
            let new = (incoming.picURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return new.isEmpty ? existing.picURL : incoming.picURL
        }()
        let dur = existing.duration > 0 ? existing.duration : incoming.duration
        let album = existing.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? incoming.album : existing.album
        return Song(platform: existing.platform,
                    platformID: existing.platformID,
                    name: existing.name,
                    singer: existing.singer,
                    album: album,
                    duration: dur,
                    picURL: pic)
    }

    /// 列表去重（首次升级时清理历史重复用）。
    ///
    /// 性能：先按**判断键**分桶（繁简/括号/标点已归一），只在桶内比；桶外再按"首字相同"扫一轮，
    /// 吃掉「差一个字」那类。不这么做就是 n² 次正则归一化，几千条收藏会卡住启动。
    static func dedupe(_ list: [Song]) -> (songs: [Song], merged: Int) {
        var out: [Song] = []
        var buckets: [String: [Int]] = [:]
        var merged = 0

        func firstHit(_ song: Song, keys: [String]) -> Int? {
            for key in keys {
                for idx in buckets[key] ?? [] where isSameRecording(out[idx], song) { return idx }
            }
            return nil
        }

        for song in list {
            let key = titleKey(song.name)
            var hit = firstHit(song, keys: [key])
            if hit == nil, let first = key.first, !key.isEmpty {
                // 首字相同的其它桶（差一两个字、译名主干相同之类）
                let siblings = buckets.keys.filter { $0.first == first && $0 != key }
                hit = firstHit(song, keys: siblings)
            }
            if let idx = hit {
                out[idx] = merge(existing: out[idx], incoming: song)
                merged += 1
            } else {
                buckets[key, default: []].append(out.count)
                out.append(song)
            }
        }
        return (out, merged)
    }
}

// MARK: - 收藏「灰区」复核（2026-11-21 老板拍板）
//
// 一级（同一条录音）与二级（同一文件）都是自动的。但有一类机械判不了、又确实可能是同一首的：
//   · 歌名一样、歌手一样，但**时长差得多**（269s vs 258s，不同母版/剪辑）
//   · 歌名只差一点（相似度 0.6–0.75，够不上自动合并的 0.75）
//   · 一边没有时长/没有歌手，证据不足
//
// 处理原则（老板原话）：**不在收藏时询问**，只在收藏页给一个不主动弹的「整理重复 · N 组」入口，
// 用户点进去逐组决定。这里只放纯逻辑：什么算灰区、合并时保留哪条。
enum FavoriteReview {

    /// 灰区歌名相似度下限（自动合并是 `FavoriteRules.titleSimilarityFloor` = 0.75）
    static let minTitleSimilarity = 0.6

    /// 灰区允许的最大时长差（超过这个基本是两首不同的歌，不值得打扰用户）
    static let maxDurationGapSec = 12

    /// 这一对是不是"值得让用户看一眼"的疑似重复（纯函数，CI 断言）
    ///
    /// 注意：**已经被一级合并掉的（isSameRecording）不算灰区**——那些根本不会同时出现在收藏里。
    /// `keyA` / `keyB` 是调用方预先算好的歌名键（收藏上千条时避免每条都跑正则 + 繁简映射）。
    static func isGreyPair(_ a: Song, _ b: Song,
                           keyA: String? = nil, keyB: String? = nil) -> Bool {
        if a.id == b.id { return false }
        if FavoriteRules.isSameRecording(a, b) { return false }

        // 版本类不同（Live / 伴奏 / 翻唱 / 粤语版）不算灰区：那是一听就知道的两首
        guard NameMatch.versionClass(a.name) == NameMatch.versionClass(b.name) else { return false }

        // 歌手：两边都有就必须有交集（"周杰伦 vs Jay Chou"这种别名映射不在本期，先不打扰）
        let sa = NameMatch.singerTokens(a.singer)
        let sb = NameMatch.singerTokens(b.singer)
        if !sa.isEmpty && !sb.isEmpty, !NameMatch.singerMatches(a.singer, b.singer) {
            return false
        }

        // 歌名：等值（说明是时长把一级挡住了）或相似度落在灰区
        let ka = keyA ?? FavoriteRules.titleKey(a.name)
        let kb = keyB ?? FavoriteRules.titleKey(b.name)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        let sim = (ka == kb) ? 1 : FavoriteRules.titleSimilarity(ka, kb)
        guard sim >= minTitleSimilarity else { return false }

        // 时长：两边都有时不能差太远
        let da = a.durationSec
        let db = b.durationSec
        if da > 0 && db > 0, abs(da - db) > maxDurationGapSec { return false }
        return true
    }

    /// 合并这一组时**保留哪条**：老板定"保留码率更高/体积更大的那条"。
    ///
    /// 排序键 (码率, 体积)：码率能反映档位（320k > 128k），体积在码率相同/缺失时兜底。
    /// 两条都没指纹时保留先出现的那条（`a`）。
    static func preferred(_ a: Song, _ b: Song,
                          fingerprints: [String: FavoriteFingerprint]) -> Song {
        let fa = fingerprints[a.id]
        let fb = fingerprints[b.id]
        if let fa, let fb {
            if fa.kbps != fb.kbps { return fa.kbps > fb.kbps ? a : b }
            if fa.bytes != fb.bytes { return fa.bytes > fb.bytes ? a : b }
            return a
        }
        if let fa { return fa.bytes > 0 ? a : b }
        if let fb { return fb.bytes > 0 ? b : a }
        return a
    }

    /// 否定缓存的键（顺序无关）
    static func pairKey(_ a: Song, _ b: Song) -> String {
        let ids = [a.id, b.id].sorted()
        return ids.joined(separator: "|")
    }
}

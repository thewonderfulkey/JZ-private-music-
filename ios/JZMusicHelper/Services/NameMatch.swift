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

    private static let punct = Pattern.make("[\\s·・\\-—_.,，、'\"“”‘’!！?？:：/\\\\&*+|]")

    private static let singerSep = Pattern.make("[/&、,，|\\\\\\s]+")

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

    // MARK: - 「歌手」其实是频道号 / 上传者（2026-11-22《下一个天亮》串歌）

    /// 这个「歌手」是不是**频道号 / 上传者**，而不是"这首歌的歌手"？
    ///
    /// 判据（两条同时成立才算，缺一不可）：
    ///   ① 池子里挂着 ≥`minDistinctTitles` 首**互不相同**的歌（按归一化歌名去重）；
    ///   ② 这些歌里**一首都没有**和源歌名对得上——也就是这个"歌手"根本没这首。
    ///
    /// 为什么必须有②（这是不误伤真人歌手的关键）：真人歌手的搜索页里也会带出他别的歌
    /// （搜「晴天 周杰伦」会回来 晴天/夜曲/七里香…），但**他自己那首一定在池子里**，
    /// ②不成立，于是照旧走老口径（歌手优先 + 时长 ≤4s + 歌名只做辅助）。
    /// 只有"名下挂着一堆对不上的歌、却没有这一首"的频道号才会命中——
    /// 实测《下一个天亮》的歌手 `我的音乐调频` 名下挂着 简单爱/心锁/我们的歌/最长的电影/
    /// 怎么会狠心伤害我 …（互不相同、时长都在 4 分钟上下），而它并没有这首。
    ///
    /// 命中之后由调用方（`SameSongCrossResolver.sameSong`）收紧成"歌名必须一致"，
    /// 因为这种"歌手"名下的别的歌，用「歌手 + 时长」是分不开的。
    static func looksLikeUploader(_ src: Song, among pool: [Song],
                                  minDistinctTitles: Int = 3) -> Bool {
        var titles = Set<String>()
        for c in pool where c.id != src.id {
            guard singerMatches(src.singer, c.singer) else { continue }
            // 人家真有这首 → 这是歌手本人，不是频道号（老口径照旧）
            if titleMatches(src.name, c.name) { return false }
            let key = normTitle(c.name)
            if key.isEmpty { continue }
            titles.insert(key)
            if titles.count >= minDistinctTitles { return true }
        }
        return false
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
//
// MARK: - 收藏判定的「观测契约」（v2.4.86）
//
// 老板 2026-11-23："点爱心只是抖一下，不会真的标记，但收藏确实成功了。"
// 真因不是收藏逻辑，是**视图丢了对 `favorites` 的订阅**：`@Observable` 的订阅粒度是
// 「这次 body 求值里到底读过哪些属性」。`LibraryStore.isFavorite` 为了性能挂了一张
// 非观察的判定缓存，命中时一个属性都不读就直接 return —— 于是那些**只靠 `isFavorite`
// 拿爱心状态**的行（榜单查看全部 / 搜索 / 艺人页 / 歌单详情 / 最新单曲 / 我的歌单）
// 悄悄丢了订阅：数据变了，界面不重画。收藏页因为直接读 `favorites`，所以一直是好的。
//
// 修法：把「读到的收藏数量」做成**参数**传进来。读取因此是结构性的（不是靠注释提醒），
// 也顺手挡住"`_ = favorites` 被编译器优化掉"这条路。
enum FavoriteObservation {

    /// 命中缓存时可以采用的答案；没命中（或收藏是空的）返回 nil，交给调用方现算。
    ///
    /// `favoritesCount` **必须**来自 `favorites.count` 的真实读取 —— 它的唯一作用就是
    /// 让"判定收藏"这件事在 SwiftUI 眼里算"读过收藏"（`ios/SelfTest` 有断言钉住这条语义）。
    static func cached(_ answer: Bool?, favoritesCount: Int) -> Bool? {
        guard favoritesCount > 0 else { return nil }
        return answer
    }
}

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

        // ④ 包含关系（长副标题）比"完全相同"弱一档，多一道专辑闸：
        //    两边专辑都有时必须一致（录屏那两首都是「哎呦，不错哦」，通过）。
        if titleVerdict.containment {
            let albA = titleKey(a.album)
            let albB = titleKey(b.album)
            if !albA.isEmpty && !albB.isEmpty && albA != albB { return false }
        }

        // ⑤ 时长
        let da = a.durationSec
        let db = b.durationSec
        if da > 0 && db > 0 {
            let diff = abs(da - db)
            if titleVerdict.exact || titleVerdict.containment {
                return diff <= NameMatch.maxDurationDiffSec
            }
            return diff <= 2          // 只是"高度相似"→ 收紧到 ±2s
        }
        // 有一边时长未知：完全等值或包含关系就认；只是相似的要 ≥0.9
        return titleVerdict.exact || titleVerdict.containment
            || titleVerdict.similarity >= 0.9
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

    /// 包含关系生效的最短标题（4 字）：`爱情 / 爱情转移`、`晴天 / 晴天娃娃` 这类两三个字的，
    /// 差一个字就是另一首，绝不做包含判定。
    static let containmentMinLength = 4

    /// 长标题至少要多出这么多字才算"副标题"（防止「我的天空」vs「我的天空啊呀」这种只多两字的被并掉）
    static let containmentMinExtra = 3

    /// 收藏去重的歌名判定（纯函数，CI 断言）
    ///
    /// 三种命中：
    ///   ① 完全等值（繁简/括号/标点已归一）
    ///   ② 包含关系：短标题（≥4 字）是长标题的子串
    ///      —— 录屏实证：「手写的从前」vs「手写的从前-优酸乳为爱告白广告曲」，
    ///      整体相似度只有 5/17≈0.29，靠 ①③ 都判不出来，但短名确实被长名包含
    ///   ③ 高相似度（≥0.75）
    static func titlesLookSame(_ a: Song, _ b: Song)
    -> (same: Bool, exact: Bool, similarity: Double, containment: Bool) {
        let ka = titleKey(a.name)
        let kb = titleKey(b.name)
        if !ka.isEmpty && ka == kb { return (true, true, 1, false) }
        let short = min(ka.count, kb.count)
        guard short >= 3 else { return (false, false, 0, false) }
        let sim = titleSimilarity(ka, kb)

        if short >= containmentMinLength {
            let pair = ka.count >= kb.count ? (long: ka, short: kb) : (long: kb, short: ka)
            let extra = pair.long.count - pair.short.count
            if extra >= containmentMinExtra,
               pair.long.hasPrefix(pair.short) || pair.long.contains(pair.short) {
                return (true, false, sim, true)
            }
        }
        return (sim >= titleSimilarityFloor, false, sim, false)
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

    /// 人工审核用的**宽口径**（自动合并是 0.75；这里放到 0.3 —— 老板 2026-11-21：
    /// "实在难写出来的，就用宽规则 + 人工去重"）
    static let minTitleSimilarity = 0.3

    /// 宽口径的时长窗口：同一首跨平台翻录通常 ≤2s；超过 3s 就不进人工列表了（太吵）
    static let reviewDurationGapSec = 3

    /// 灰区允许的最大时长差（超过这个基本是两首不同的歌，不值得打扰用户）
    static let maxDurationGapSec = 3

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

        // 歌曲名：等值 / 包含 / 相似度 ≥0.3（宽口径，交给用户判断）
        let ka = keyA ?? FavoriteRules.titleKey(a.name)
        let kb = keyB ?? FavoriteRules.titleKey(b.name)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        let sim = (ka == kb) ? 1 : FavoriteRules.titleSimilarity(ka, kb)
        let containment = {
            let short = min(ka.count, kb.count)
            guard short >= FavoriteRules.containmentMinLength else { return false }
            let pair = ka.count >= kb.count ? (long: ka, short: kb) : (long: kb, short: ka)
            guard pair.long.count - pair.short.count >= FavoriteRules.containmentMinExtra
            else { return false }
            return pair.long.contains(pair.short)
        }()
        guard sim >= minTitleSimilarity || containment else { return false }

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

// MARK: - 本地导入的纯逻辑（2026-11-21 老板需求：批量导入已下载的歌曲文件）
//
// 导入和下载共用同一套目录（Music / Lyrics / Cover）与**基名**约定，所以这里只负责三件事：
//   · 哪些扩展名能播（iOS AVFoundation 能吃哪些）
//   · 文件名 → (歌手, 歌名) 的兜底解析（标签缺失时才用）
//   · 基名清洗与去重（撞基名会让歌词/封面串到别的歌上，这是最危险的静默错误）
enum ImportRules {

    /// AVFoundation 能播的（其余导入了也放不出来，导入时直接标"不支持"）
    static let playableExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif", "caf", "alac"
    ]

    /// 常见但 iOS 放不了的（导入时给明确提示，别让人导完才发现）
    static let knownUnsupported: Set<String> = [
        "ape", "wma", "dsf", "dff", "ogg", "opus", "wv", "tta", "tak"
    ]

    static func isPlayable(extension ext: String) -> Bool {
        playableExtensions.contains(ext.lowercased())
    }

    /// 导入时的字段取舍：**文件里的标签 > 文件名解析**（纯函数，CI 钉口径）。
    ///
    /// 2026-11-22（老板："所有歌曲信息内置到音乐文件后，再次导入没有自动识别文件里内嵌的信息，
    /// 还要我手动加载文件中的内容"）：真机整批无损是 FLAC，而 AVFoundation **读不了 Vorbis Comment**
    /// （`commonMetadata` 对 flac 基本是空的），于是全被当成"没标签" → 歌名/歌手退回文件名
    /// （`蔡健雅 - 红色高跟鞋 [网易_妖狐酷我]`），封面也没有，只能手动进「歌曲信息 → 以文件为准」。
    /// 现在 AVFoundation 给不出的字段由 `AudioTagEmbedder.readFields`（mp3 ID3 / flac Vorbis+PICTURE /
    /// m4a）再补一次，然后走这条纯规则：**标签优先，文件名只在标签也没有时兜底**。
    ///
    /// `guessed` = 用到了文件名兜底（调用方据此允许"歌名/歌手对调再搜一次"，也据此标记来源）。
    static func pickImportedFields(tagTitle: String, tagArtist: String, tagAlbum: String,
                                   fileTitle: String, fileArtist: String)
        -> (title: String, artist: String, album: String, guessed: Bool) {
        let t = tagTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = tagArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let al = tagAlbum.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = t
        var artist = a
        var guessed = false
        if title.isEmpty {
            title = fileTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guessed = true
        }
        if artist.isEmpty {
            artist = fileArtist.trimmingCharacters(in: .whitespacesAndNewlines)
            guessed = true
        }
        return (title, artist, al, guessed)
    }

    /// 去掉音轨号前缀：`01 - `、`01.`、`01_`、`01、`
    static func strippingTrackNumber(_ s: String) -> String {
        var out = s
        var i = out.startIndex
        var digits = 0
        while i < out.endIndex, out[i].isNumber { digits += 1; i = out.index(after: i) }
        guard digits > 0, digits <= 3, i < out.endIndex else { return s }
        // 音轨号后面必须紧跟分隔符，否则 "2002年的第一场雪" 会被当成音轨号
        var j = i
        var seps = 0
        while j < out.endIndex, " -_.、．·".contains(out[j]) { seps += 1; j = out.index(after: j) }
        guard seps >= 1 else { return s }
        out = String(out[j...])
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// 文件名 → (歌名, 歌手, 是否可靠)
    ///
    /// 约定俗成的两种：`歌手 - 歌名`（中文合集最常见）与 `01 - 歌手 - 歌名`。
    /// 单段文件名只当歌名，歌手留空（等联网匹配/手动纠正）——**绝不瞎猜**。
    static func parseFileName(_ rawName: String) -> (title: String, artist: String, confident: Bool) {
        var s = (rawName as NSString).deletingPathExtension
        s = strippingTrackNumber(s)
        s = s.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
        let separators = [" - ", " – ", " — ", " _ ", "－", "—", "–"]
        for sep in separators {
            if s.contains(sep) {
                let parts = s.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if parts.count >= 2 {
                    // 两段：歌手 - 歌名（最常见）；三段以上：取第 2 段当歌手，其余合并当歌名
                    let artist = parts[0]
                    let title = parts.dropFirst().joined(separator: " ")
                    return (title, artist, true)
                }
            }
        }
        return (s.trimmingCharacters(in: .whitespaces), "", false)
    }

    /// 基名清洗：去掉路径分隔与非法字符，限长（太长会让 Files 里很难看，也可能撞文件系统上限）
    static func sanitizeBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\0", "\n", "\r", "\\"] {
            s = s.replacingOccurrences(of: bad, with: "-")
        }
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        if s.count > 90 { s = String(s.prefix(90)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? "未命名" : s
    }

    /// 基名去重：撞了就加 ` (2)`、` (3)`……
    ///
    /// **为什么必须唯一**：歌词/封面是靠"音频基名"推导的（`DownloadCompanion`），
    /// 两个文件同基名 → 后写的旁车会把前一首的词图顶掉，而且完全静默。
    static func uniqueBaseName(_ wanted: String, taken: Set<String>) -> String {
        let base = sanitizeBase(wanted)
        guard taken.contains(base) else { return base }
        var n = 2
        while n < 1000 {
            let candidate = "\(base) (\(n))"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
        return "\(base) (\(UUID().uuidString.prefix(6)))"
    }

    // MARK: 内置导入浏览器（2026-11-21 第三次修导入：不再把系统选择器当唯一入口）
    //
    // 背景：老板这台机器上系统文件选择器的「打开」**不回调**——2026-11-19 的「保存位置」
    // （SwiftUI `.fileImporter`）和 2026-11-21 的导入（UIKit 模态 `UIDocumentPickerViewController`）
    // 是两条完全不同的呈现路径，死在同一个按钮上，所以问题在系统那层。
    // 于是导入改成"先在 App 自己的文件夹里挑"（`文件 › JZ 音乐` = 本 App 的 Documents）。
    //
    // 这一段只放**纯逻辑**：哪些条目该出现在列表里、怎么排序——好让 CI 能钉断言。

    /// 浏览器里条目的类型（决定能不能点、能不能导入）
    enum BrowserKind: Equatable {
        case folder
        case audio
        /// 能看见但选不了：iOS 的 AVFoundation 放不出来（ape / wma / ogg …），
        /// 与其导完"哑火"，不如在列表里就说清楚
        case unsupported
        /// 不显示（诊断日志、旁车目录）
        case other
    }

    /// 浏览器里要隐藏的目录名：`诊断`（崩溃取证日志，不是歌）、`ImportStaging`
    /// （导入时抢进来的暂存副本，抢完就删）与所有隐藏文件。
    /// `Inbox` 故意**不隐藏**——别的 App「用 JZ 音乐打开」送来的文件会落在那里，
    /// 万一自动导入没跑起来，用户还能在这一页看见它们手动导入。
    static let browserHiddenNames: Set<String> = ["诊断", "ImportStaging"]

    static func browserHides(name: String) -> Bool {
        if name.isEmpty { return true }
        if name.hasPrefix(".") { return true }
        return browserHiddenNames.contains(name)
    }

    /// 这个名字在导入浏览器里算哪一类
    static func browserKind(name: String, isDirectory: Bool) -> BrowserKind {
        if browserHides(name: name) { return .other }
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        if isPlayable(extension: ext) { return .audio }
        if knownUnsupported.contains(ext) { return .unsupported }
        return .other
    }

    /// 排序：文件夹在前，同类按「本地化标准比较」
    /// （`01 - …`、`10 - …` 与中文都能排成人看得懂的顺序；纯 `String <` 会把 10 排在 2 前面）
    static func browserComesBefore(_ aName: String, _ aIsFolder: Bool,
                                   _ bName: String, _ bIsFolder: Bool) -> Bool {
        if aIsFolder != bIsFolder { return aIsFolder }
        let r = aName.localizedStandardCompare(bName)
        if r == .orderedSame { return aName < bName }
        return r == .orderedAscending
    }

    /// 文件大小文案（列表里给一眼能看的体积；档位规则见 `ByteText`）
    static func browserSizeText(_ bytes: Int64) -> String {
        if bytes <= 0 { return "" }
        return ByteText.human(bytes)
    }

    // MARK: 导入结果文案（2026-11-21：老板问"为什么有些歌导不进去"）

    /// 一批文件名里的扩展名汇总：`["a.ape","b.APE","c.wma"]` → `"ape/wma"`（小写、去重、排序）
    static func extensionSummary(_ names: [String]) -> String {
        let exts = Set(names.map { ($0 as NSString).pathExtension.lowercased() })
            .filter { !$0.isEmpty }
            .sorted()
        return exts.isEmpty ? "未知" : exts.joined(separator: "/")
    }

    /// 这批被拒的文件是不是**全都是 iOS 没有解码器**的格式（ape / wma / dsf / ogg …）：
    /// 只有这种情况才能理直气壮地说"导进来也是无声"，否则要说"认不出容器/可能是加密包"。
    static func hasOnlyUndecodableExtensions(_ names: [String]) -> Bool {
        guard !names.isEmpty else { return false }
        return names.allSatisfy { name in
            let ext = (name as NSString).pathExtension.lowercased()
            return !ext.isEmpty && knownUnsupported.contains(ext)
        }
    }
}

// MARK: - 导入「抢取阶段」的纯逻辑（2026-11-21 晚 v2.4.51）
//
// 事故实证（`诊断/import.log`，别再靠猜）：老板全选 Light Player 的 664 首（27 GB）导入，
// 崩点固定在**第 59 秒**——崩点前 444/419 首 0 失败，崩点后 219/244 首全失败，
// 系统原话「未能打开文件…因为它不存在」，而当时设备**还剩 303 GB**。
// 根因：系统选择器 `asCopy: true` 的副本放在 App 的 tmp 里，iOS 约 1 分钟后会清掉它
// （前台也清，社区实测），清掉后手里那批 URL 全指向空气。
// 现在的做法：回调一进来先把文件抄进自己的 `Documents/ImportStaging`，再从容解析。
// 下面这几条是那一步的纯逻辑，交给 CI 钉住。
enum ImportGrabRules {

    /// 抢取阶段的时间预算（秒）。
    ///
    /// 系统清理是"约 1 分钟"（实测崩点 59 秒）。40 秒既够把 27 GB 的克隆跑完，
    /// 又给后面的解析留了余量——宁可在预算内抢到 95%，也不要踩线抢到 100% 然后全丢。
    static let grabBudget: TimeInterval = 40

    /// 连续多少个「源文件不存在」就认定 tmp 已被系统清掉，停止空转
    static let consecutiveMissingAbort = 5

    /// `NSCocoaErrorDomain` 里"没有这个文件"的两个码：
    /// `NSFileNoSuchFileError`(4) 与 `NSFileReadNoSuchFileError`(260)。
    ///
    /// 为什么按码判而不是按文案：`localizedDescription` 跟着系统语言走
    /// （中文机"未能打开文件…因为它不存在"，英文机 "couldn't be opened … no such file"），
    /// 按文案判早晚判错。
    static let cocoaDomain = "NSCocoaErrorDomain"
    static let noSuchFileCodes: Set<Int> = [4, 260]

    static func isMissingFile(domain: String, code: Int) -> Bool {
        domain == cocoaDomain && noSuchFileCodes.contains(code)
    }

    /// 现在该不该停下"抢"
    static func shouldStopGrabbing(elapsed: TimeInterval, consecutiveMissing: Int) -> Bool {
        if elapsed >= grabBudget { return true }
        return consecutiveMissing >= consecutiveMissingAbort
    }

    /// 报告摘要里那一小段
    static func missedSummary(_ count: Int) -> String {
        "没赶上 \(count) 个（系统清理了临时副本）"
    }

    /// 报告正文里"没拿到"那句：**说人话 + 给下一步**，别只丢一个数字
    static func missedReason(count: Int, abortedEarly: Bool) -> String {
        if abortedEarly {
            return "\(count) 首没能在系统清理临时副本前取到：iOS 只保证选择器的临时副本约 1 分钟可用。"
                + "请一次选 150 首以内分批导入，已经进来的那一批会自动跳过。"
        }
        return "\(count) 首没赶上：导入跑到一半，系统清掉了选择器的临时副本（约 1 分钟）。"
            + "已取到的都进来了，剩下的请一次选 150 首以内再导一次。"
    }
}

// MARK: - 写回/检测的**范围规则**（2026-11-22 老板："新歌写回会把以前写过的再写一遍"）
//
// 为什么单独抽出来：这条判定要被 CI 直接喂（`SelfTest` 只编纯逻辑那一批文件）。
// 口径只有一句：**上次已经确认对齐的，这次不再碰**（`fileTruth.isAligned == true`）。
//   · 这样"新下一首 → 写回"只会真的写那一首，不会把 664 首 FLAC 全部重读重写一遍；
//   · 想让某首歌重写：先用「检查文件对齐」扫一遍（会把状态刷新），或者改它的信息（会把状态清掉）；
//   · 没有状态记录（nil，比如刚导入、刚改过信息）→ 当作"需要写"，如实写并回读校验。
enum SongInfoWriteRules {

    static func needsWrite(_ item: DownloadItem) -> Bool {
        // 2026-11-22：文件已经不在的（合并重复/手动删掉留下的死记录）永远不再写 ——
        // 以前每次点写回都要重新报一遍"本地文件不在了"。
        if item.fileMissing == true { return false }
        guard let truth = item.fileTruth else { return true }
        return !truth.isAligned
    }

    /// 过滤出真正要写的那批，并返回被跳过的条数（报告里要说清楚"跳过了 N 首"，别让人以为漏了）
    static func pending(_ items: [DownloadItem]) -> (targets: [DownloadItem], skipped: Int) {
        var targets: [DownloadItem] = []
        var skipped = 0
        for item in items where item.status == .completed && item.localPath != nil {
            if needsWrite(item) {
                targets.append(item)
            } else {
                skipped += 1
            }
        }
        return (targets, skipped)
    }
}

// MARK: - 整理重复的**纯计算**（2026-11-22 老板："点一下整理重复卡死 10 秒"）
//
// 为什么要单独抽一层：判定口径必须还是 `FavoriteRules.isSameRecording`（一个字都不能改），
// 但**算法**可以从 O(n²) 降到 O(n × 桶内个数)，而且能挪到后台跑、并被 CI 直接断言。
//
// 提速靠两点：
//   ① 按「时长 4 秒一桶」切分：同一条录音时长差必然 ≤4s（或有一边时长未知），
//      所以只需要和「同桶 + 前后各一桶 + 时长未知」里**已经保留**的条目比；
//   ② 整个比对只读内存里的 `Song`，不碰磁盘、不碰 UI。
//
// 结果与旧实现**逐条等价**：仍按 `items` 原顺序扫，仍取第一个命中（候选按保留顺序排序后再比），
// 仍是"留 kbps 更高的一条"。
enum DuplicateSweep {

    struct Plan {
        /// 要删掉的条目（`DownloadItem.id`）
        var losers: [UUID] = []
        /// 合并了多少组
        var merged: Int = 0
        /// 预计释放的字节（各 loser 的 totalBytes 之和）
        var freedBytes: Int64 = 0
        /// 被并走的条目 → 留下来的那条（2026-11-22：收藏/最近播放/队列里还留着被删那条的
        /// `Song.id`，播放时按 id 找不到本地文件 → 每次都重新联网取流，就是"《英雄》要等 1-2 秒"）
        var winnerOf: [UUID: UUID] = [:]
        var isEmpty: Bool { losers.isEmpty }
    }

    static func kbps(_ item: DownloadItem) -> Int64 {
        let dur = item.song.duration
        guard dur > 0, item.totalBytes > 0 else { return 0 }
        return Int64((Double(item.totalBytes) * 8 / dur / 1000).rounded())
    }

    /// 4 秒一桶；时长未知（≤0）不进桶
    static func bucketKey(_ seconds: Double) -> Int? {
        seconds > 0 ? Int(seconds) / 4 : nil
    }

    static func plan(_ items: [DownloadItem]) -> Plan {
        var plan = Plan()
        var kept: [Int] = []                        // 保留条目的下标（按原顺序增长）
        var buckets: [Int: [Int]] = [:]             // 桶 → kept 里位置
        var unknownKept: [Int] = []                 // 时长未知的 kept 位置

        func remember(_ pos: Int) {
            if let key = bucketKey(items[kept[pos]].song.duration) {
                buckets[key, default: []].append(pos)
            } else {
                unknownKept.append(pos)
            }
        }
        func forget(_ pos: Int, key: Int?) {
            if let key {
                buckets[key]?.removeAll { $0 == pos }
            } else {
                unknownKept.removeAll { $0 == pos }
            }
        }

        for idx in items.indices where items[idx].status == .completed {
            let item = items[idx]
            var candidates: [Int] = []
            if let key = bucketKey(item.song.duration) {
                for k in (key - 1)...(key + 1) {
                    if let list = buckets[k] { candidates.append(contentsOf: list) }
                }
            }
            candidates.append(contentsOf: unknownKept)
            candidates.sort()                       // 与旧实现"按保留顺序取第一个"一致

            var hit: Int?
            for pos in candidates
            where FavoriteRules.isSameRecording(items[kept[pos]].song, item.song) {
                hit = pos
                break
            }

            guard let pos = hit else {
                kept.append(idx)
                remember(kept.count - 1)
                continue
            }
            plan.merged += 1
            let existing = items[kept[pos]]
            if kbps(existing) >= kbps(item) {
                plan.losers.append(item.id)
                plan.winnerOf[item.id] = existing.id
                plan.freedBytes += item.totalBytes
            } else {
                // 新的更好：旧的进 losers，保留位置换成新的（桶归属跟着改）
                plan.losers.append(existing.id)
                plan.winnerOf[existing.id] = item.id
                plan.freedBytes += existing.totalBytes
                let oldKey = bucketKey(existing.song.duration)
                let newKey = bucketKey(item.song.duration)
                kept[pos] = idx
                if oldKey != newKey {
                    forget(pos, key: oldKey)
                    if let newKey { buckets[newKey, default: []].append(pos) } else { unknownKept.append(pos) }
                }
            }
        }
        // 链式归并：A 被 B 并、B 后来又被 C 并 → A 与 B 都算到 C 头上
        let loserSet = Set(plan.losers)
        for loser in plan.losers {
            var target = plan.winnerOf[loser]
            var guardCount = 0
            while let t = target, loserSet.contains(t), let next = plan.winnerOf[t], guardCount < 8 {
                target = next
                guardCount += 1
            }
            if let t = target { plan.winnerOf[loser] = t }
        }
        return plan
    }
}

// MARK: - 下载页 tab 内本地搜索（下载 / 收藏）
//
// 纯本地、不联网：老板要"根据每个 tab 中的内容返回结果"。
// 匹配字段：歌名、歌手、专辑，以及**文件名**（导入的文件常是 "01 - 歌手 - 歌名"）。
// 归一化复用收藏那套（繁转简 + 去标点/空白），所以「後來」能搜出「后来」。
enum LibrarySearch {

    /// 归一化（繁转简 + 去括号/标点/空白 + 小写）。
    ///
    /// **对外公开**：搜索每敲一个字母只需要归一化一次**查询词**，
    /// 而每首歌的四个字段只需要归一化一次（见 `blob`）。
    static func key(_ s: String) -> String {
        FavoriteRules.titleKey(s)
    }

    /// 一首歌的"可搜索串"：歌名 / 歌手 / 专辑 / 文件名各归一化一次，用 U+0001 分隔。
    ///
    /// 为什么要有这一层（2026-11-22 老板：663 首时下载页搜索"每输入一个字母就开始卡"）：
    /// `rank()` 是"每首歌 × 每个字段 × 每次求值"各归一化一次——663 首 4 个字段 ≈ 2650 次
    /// 繁简映射 + 两次正则，而同一帧里这几个列表还要被求值好几遍。
    /// 现在每首歌只算一次（调用方缓存），之后每敲一个字母只是 N 次 `contains`。
    /// 用 U+0001 分隔是为了不让"歌手末尾 + 专辑开头"拼出一个查询词（误命中）。
    static func blob(song: Song, fileName: String?) -> String {
        var parts = [key(song.name), key(song.singer), key(song.album)]
        if let fileName {
            parts.append(key((fileName as NSString).deletingPathExtension))
        }
        return parts.joined(separator: "\u{1}")
    }

    /// 用**已经归一化**的串和查询词做匹配（`q` 必须是 `key(_:)` 的结果）。
    static func matches(blob: String, key q: String) -> Bool {
        !q.isEmpty && blob.contains(q)
    }

    /// 是否命中（空查询由调用方当作"全部"，这里返回 false）
    static func matches(song: Song, fileName: String?, query: String) -> Bool {
        rank(song: song, fileName: fileName, query: query) > 0
    }

    /// 命中强度：0 = 不命中；数字越大越靠前（精确 > 前缀 > 包含 > 只在歌手/专辑/文件名里出现）
    static func rank(song: Song, fileName: String?, query: String) -> Int {
        let q = key(query)
        guard !q.isEmpty else { return 0 }

        let title = key(song.name)
        if title == q { return 4 }
        if title.hasPrefix(q) { return 3 }
        if title.contains(q) { return 2 }

        let singer = key(song.singer)
        let album = key(song.album)
        if singer.contains(q) || album.contains(q) { return 1 }

        if let fileName {
            let base = key((fileName as NSString).deletingPathExtension)
            if base.contains(q) { return 1 }
        }
        return 0
    }
}

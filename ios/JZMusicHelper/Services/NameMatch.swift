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

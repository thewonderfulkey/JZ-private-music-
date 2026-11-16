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
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

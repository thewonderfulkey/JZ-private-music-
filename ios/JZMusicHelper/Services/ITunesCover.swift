import Foundation

// MARK: - iTunes 封面兜底（最后一级）
//
// 老板 r90："有些封面没加载出来，都是些很火的热歌，不应该加载不出来；加载不出来是不是应该有兜底？"
//
// 实测：酷我搜索对一部分歌**不返回 MVPIC**，只能走 `rid_pic`；而 `rid_pic` 会给出地址，
// 其中有些地址本身就是 404（例如凉凉 rid=36960604 → `img4.kuwo.cn/pic_music/.../300821514.jpg` 404）。
// 于是封面链走到 QQ 严格匹配就断了。这里加一级公共兜底：iTunes Search API（无需 key、https）。
//
// ⚠️ **必须做严格匹配**：iTunes 的相关性对华语歌很差——实测搜「青花瓷 周杰伦」第一条是《屋顶》。
// 只按"第一条"取图会把别人的专辑封面贴上来，比没有封面更糟（老板原话：宁可没有也别贴错）。
// 所以这里要求：**歌名核心名相等（或包含）+ 歌手至少一个片段相等**，否则返回 nil 落占位图。
enum ITunesCover {

    /// 搜索 URL（纯函数，CI 可断言）。不指定 `country=cn`——中国区曲库对华语老歌反而更少，
    /// 实测默认（美国区）能搜到 凉凉/Shape of You 这类。
    static func searchURL(title: String, artist: String, limit: Int = 10) -> String {
        let term = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = term.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?/"))) ?? ""
        return "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=\(limit)"
    }

    /// 把 `artworkUrl100` 换成更大尺寸（纯函数）
    static func largeArtwork(_ url: String) -> String? {
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
        var out = url
        if out.contains("100x100bb") {
            out = out.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        } else if out.contains("100x100") {
            out = out.replacingOccurrences(of: "100x100", with: "600x600")
        }
        if out.hasPrefix("http://") { out = "https://" + out.dropFirst("http://".count) }
        return out
    }

    /// 歌名是否对得上：核心名相等（剥掉 (Live)/- Remix 这类版本后缀），或互相包含
    static func titleMatches(_ trackName: String, _ title: String) -> Bool {
        let a = loose(StudioPick.coreName(trackName))
        let b = loose(StudioPick.coreName(title))
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// 歌手是否对得上：查询里的名字片段，至少有一个出现在候选歌手里
    static func artistMatches(_ candidate: String, _ query: String) -> Bool {
        let tokens = splitTokens(query)
        guard !tokens.isEmpty else { return true }
        let cand = loose(candidate)
        return tokens.contains { cand.contains($0) }
    }

    /// 从 `search` 响应里挑封面（纯函数）：**只收歌名和歌手都对得上的**，宁缺毋滥
    static func parse(_ json: [String: Any], title: String, artist: String) -> String? {
        let results = (json["results"] as? [[String: Any]]) ?? []
        for item in results {
            guard let track = item["trackName"] as? String,
                  let singer = item["artistName"] as? String,
                  let art = item["artworkUrl100"] as? String else { continue }
            guard titleMatches(track, title), artistMatches(singer, artist) else { continue }
            if let large = largeArtwork(art) { return large }
        }
        return nil
    }

    /// 网络取（失败静默返回 nil，由调用方落占位图）
    static func fetch(song: Song, timeout: TimeInterval = 6) async -> String? {
        guard !song.name.isEmpty else { return nil }
        let url = searchURL(title: song.name, artist: song.singer)
        guard let json = try? await APIClient.shared.getJSON(url, timeout: timeout) else { return nil }
        return parse(json, title: song.name, artist: song.singer)
    }

    // MARK: 归一

    private static func loose(_ s: String) -> String {
        let punctuation = CharacterSet(charactersIn: " \t\n-_·、,，.。()（）[]【】《》'\"!?！？~&/+")
        return String(s.lowercased().unicodeScalars.filter { !punctuation.contains($0) }
            .map(Character.init))
    }

    /// 歌手串拆名字：中文取 ≥2 字片段，英文取 ≥3 字母词
    private static func splitTokens(_ s: String) -> [String] {
        let cjk = matches(s, pattern: "[\\u4e00-\\u9fff]{2,}")
        let latin = matches(s, pattern: "[A-Za-z]{3,}")
        return (cjk + latin).map(loose)
    }

    private static func matches(_ s: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }
}

import Foundation

// MARK: - 酷我歌手（发现页「歌手大全」的数据源）
//
// 端点（2026-11-18 实测：匿名、https、无签名、无 cookie）：
//   · 歌手列表  GET https://wapi.kuwo.cn/api/www/artist/artistInfo?pn=1&rn=30&category=<id>&prefix=<A-Z>
//                total 8849（全部）；分类 id 见 `categories`；prefix 可与 category 叠加
//                （prefix=A → 446 位；prefix=Z&category=11 → 336 位华语 Z 开头）
//   · 歌手歌曲  GET https://wapi.kuwo.cn/api/www/artist/artistMusic?artistid=<id>&pn=1&rn=50
//                周杰伦 total 1707；字段 rid / name / artist / album / duration / releasedate / pic
//
// 两条接口都**没有** `pub` 之类的服务端刷新日期（只有热榜 `ksong.s` 有），所以"当天只拉一次"的
// 锚点用本地日，并跟热门那一趟一起刷新（见 `docs/ios/IOS-SQUARE-ARTIST-PLAN.md` §5.1）。
//
// 排序：不传 prefix 时接口按粉丝数倒序（周杰伦 166.4 万第一）；传 prefix 时是该字母下的粉丝序。
// 所以界面上的 meta 写"按粉丝排序"，不冒充字母序全表。
enum KuwoArtist {

    /// 一位歌手。字段是接口原样（`artistFans` 等）折算过来的。
    struct Artist: Identifiable, Codable, Hashable {
        let id: String
        let name: String
        /// 外文名 / 拼音（接口 `aartist`），没有就是空串
        let alias: String
        let picURL: String
        let fans: Int
        let songCount: Int
        let albumCount: Int

        /// 缺图时的圆形占位字：取名字首字（"周杰伦"→"周"，"G.E.M."→"G"）
        var initial: String {
            let first = name.trimmingCharacters(in: .whitespaces).prefix(1)
            return String(first).uppercased()
        }
    }

    struct Page: Codable, Hashable {
        let total: Int
        let items: [Artist]
    }

    /// 分类。id 是酷我自己的分类号（实测 total 见注释），不是我们编的。
    struct Category: Identifiable, Hashable {
        let id: Int
        let title: String
    }

    static let categories: [Category] = [
        Category(id: 0, title: "全部"),       // 8849
        Category(id: 11, title: "华语"),      // 3603
        Category(id: 13, title: "欧美"),      // 3614
        Category(id: 12, title: "组合"),      // 1632
        Category(id: 4, title: "日韩男"),     // 591
        Category(id: 5, title: "日韩女"),     // 517
        Category(id: 6, title: "日韩组合"),   // 524
    ]

    /// 一页 30 位（三列 × 10 行）
    static let pageSize = 30

    static let headers = ["Referer": "https://www.kuwo.cn/"]

    static var today: Int { DiscoverRules.today }

    /// A–Z 字母条：`nil` = 热门（不按字母）
    static let letters: [String] = ["热门"] + (65...90).map { String(UnicodeScalar($0)!) }

    // MARK: URL

    static func directoryURL(category: Int, prefix: String, page: Int = 1, rn: Int = pageSize) -> String {
        var url = "https://wapi.kuwo.cn/api/www/artist/artistInfo"
            + "?pn=\(page)&rn=\(rn)&category=\(category)"
        if !prefix.isEmpty {
            url += "&prefix=\(prefix.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? prefix)"
        }
        return url
    }

    static func songsURL(artistID: String, page: Int = 1, rn: Int = 50) -> String {
        "https://wapi.kuwo.cn/api/www/artist/artistMusic"
            + "?artistid=\(artistID)&pn=\(page)&rn=\(rn)"
    }

    // MARK: 拉取

    static func fetchDirectory(category: Int,
                               prefix: String = "",
                               page: Int = 1,
                               rn: Int = pageSize,
                               day: Int = KuwoArtist.today) async throws -> Page {
        let json = try await APIClient.shared.getJSON(
            directoryURL(category: category, prefix: prefix, page: page, rn: rn),
            headers: headers,
            timeout: 20
        )
        guard let result = parseDirectory(json) else {
            throw APIError.parse("歌手列表解析失败")
        }
        // 只缓存"热门"第一页（每分类一份）；字母页与翻页只在内存
        if page == 1 && prefix.isEmpty {
            save(result, category: category, day: day)
        }
        return result
    }

    /// 歌手的热门歌曲（接口按热度排，不做二次排序）
    static func fetchSongs(artistID: String, page: Int = 1, rn: Int = 50) async throws -> [KuwoPlaylist.Release] {
        let json = try await APIClient.shared.getJSON(
            songsURL(artistID: artistID, page: page, rn: rn),
            headers: headers,
            timeout: 20
        )
        guard let songs = parseSongs(json), !songs.isEmpty else {
            throw APIError.parse("歌手歌曲解析失败")
        }
        return songs
    }

    // MARK: 解析（纯函数，CI 断言直接喂字典进来）

    static func parseDirectory(_ json: [String: Any]) -> Page? {
        if let code = number(json["code"]), code != 200 { return nil }
        guard let data = json["data"] as? [String: Any] else { return nil }
        let list = data["artistList"] as? [[String: Any]] ?? []
        let items = list.compactMap(artist(from:))
        guard !items.isEmpty else { return nil }
        return Page(total: number(data["total"]) ?? items.count, items: items)
    }

    static func artist(from item: [String: Any]) -> Artist? {
        guard let id = text(item["id"]), !id.isEmpty else { return nil }
        guard let name = text(item["name"]), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let pic = text(item["pic300"]) ?? text(item["pic"]) ?? text(item["pic120"]) ?? ""
        return Artist(
            id: id,
            name: TextClean.text(name),
            alias: TextClean.text(text(item["aartist"]) ?? ""),
            picURL: KuwoPlaylist.https(pic),
            fans: number(item["artistFans"]) ?? 0,
            songCount: number(item["musicNum"]) ?? 0,
            albumCount: number(item["albumNum"]) ?? 0
        )
    }

    static func parseSongs(_ json: [String: Any]) -> [KuwoPlaylist.Release]? {
        if let code = number(json["code"]), code != 200 { return nil }
        guard let data = json["data"] as? [String: Any] else { return nil }
        let list = data["list"] as? [[String: Any]] ?? []
        let releases = list.compactMap(release(from:))
        return releases.isEmpty ? nil : releases
    }

    /// 歌手歌曲 → 复用 `KuwoPlaylist.Release`（播放层要的就是 Song）
    static func release(from item: [String: Any]) -> KuwoPlaylist.Release? {
        guard let rid = text(item["rid"]), !rid.isEmpty, rid != "0" else { return nil }
        guard let name = text(item["name"]), !name.isEmpty else { return nil }
        let seconds = number(item["duration"])
        let duration = KuwoPlaylist.durationSec(seconds: seconds, minutes: text(item["songTimeMinutes"]))
        let song = Song(
            platform: .kuwo,
            platformID: rid,
            name: TextClean.text(name),
            singer: TextClean.text(text(item["artist"]) ?? ""),
            album: TextClean.text(text(item["album"]) ?? ""),
            duration: TimeInterval(duration),
            picURL: KuwoPlaylist.https(text(item["pic"]) ?? text(item["albumpic"]) ?? "")
        )
        // 歌手的接口是 `releasedate`（全小写），歌单是 `releaseDate`
        let date = text(item["releasedate"]) ?? text(item["releaseDate"]) ?? ""
        return KuwoPlaylist.Release(song: song, releaseDate: date)
    }

    // MARK: 缓存（只缓存每个分类"热门"的第一页）

    private static func cacheKey(category: Int) -> String {
        "kw_artists_v1_\(category)"
    }

    private struct CachedPage: Codable {
        let day: Int
        let page: Page
    }

    static func cached(category: Int, day: Int = KuwoArtist.today) -> Page? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(category: category)),
              let cached = try? JSONDecoder().decode(CachedPage.self, from: data),
              cached.day == day, !cached.page.items.isEmpty else { return nil }
        return cached.page
    }

    static func cachedAnyDay(category: Int) -> Page? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(category: category)),
              let cached = try? JSONDecoder().decode(CachedPage.self, from: data),
              !cached.page.items.isEmpty else { return nil }
        return cached.page
    }

    static func save(_ page: Page, category: Int, day: Int = KuwoArtist.today) {
        let cached = CachedPage(day: day, page: page)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(category: category))
    }

    // MARK: 字段取值

    private static func text(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func number(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(trimmed) { return n }
            if let d = Double(trimmed) { return Int(d) }
        }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}

// MARK: - 数字缩写（播放量 / 粉丝数）
//
// 912116 → "91.2万"；106793500 → "1.1亿"；8849 → "8849"。
// 抽成纯函数是为了 CI 能钉住"别把 1.06 亿写成 10679 万"这类手滑。
enum CountFormat {

    static func short(_ value: Int) -> String {
        guard value > 0 else { return "0" }
        if value >= 100_000_000 {
            return trim(String(format: "%.1f", Double(value) / 100_000_000)) + "亿"
        }
        if value >= 10_000 {
            return trim(String(format: "%.1f", Double(value) / 10_000)) + "万"
        }
        return "\(value)"
    }

    /// "91.0万" → "91万"（整数倍时不带 .0）
    private static func trim(_ text: String) -> String {
        text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

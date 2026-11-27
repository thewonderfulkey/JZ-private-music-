import Foundation

// MARK: - 酷我官方榜单（发现页「编辑精选 → 榜单歌曲」模块的数据源）
//
// 端点（2026-11-17 实测：匿名、无签名、无 cookie，https 直连即通）：
//   · 榜单目录  GET https://wapi.kuwo.cn/api/pc/bang/list                         36 个叶子榜
//   · 榜单歌曲  GET https://kbangserver.kuwo.cn/ksong.s?from=pc&type=bang&id=<mobileId>&pn=0&rn=100
//
// 两个必须记住的坑（都是实测出来的，写在这里免得后来人再踩一遍）：
//
//   ① **两级 id**：目录里每个榜有两个 id——`id`（web 口径，如 489927）和 `sourceid`（移动端口径，如 16）。
//      把 web id 喂给 `ksong.s` 只回 `{}`（实测 2 字节，HTTP 却是 200，很能骗人）；
//      取歌必须用 `sourceid`。所以 `Chart` 两个 id 都留着，但只有 `mobileId` 会上请求。
//
//   ② **曲长不在 `duration`**：同一批曲目里 `duration` 是 4 / 1 / 41 / 107 这类明显不是曲长的值，
//      真正的曲长在 `song_duration`（189 / 272 / …）。这个字段用错不是"少个信息"——
//      播放侧的 ±25s 时长闸门（`PlaybackRules.durationToleranceSec`）会拿它当期望值：
//      期望 4s 时真歌 189s 被判成坏源全网跳歌，反过来 4s 的试听片段反而会被当好源放出去。
//
// 榜单曲**没有任何封面字段**（`ksong.s` 不返回图片），所以这里 `picURL` 一律 nil，
// 由 `CoverResolver` 的酷我分支（`rid_pic`，同平台按 rid 取图）补——这正是封面兜底链要补的洞。
enum KuwoChart {

    /// 一个榜。两个 id 都留着：`webId` 只用于目录展示与封面主视觉，`mobileId` 才是取歌用的。
    struct Chart: Identifiable, Hashable {
        let webId: String
        let mobileId: String
        let name: String

        var id: String { mobileId }

        /// 发现页「编辑精选」里挂的那个榜（酷我热歌榜，100 首，每日更新）。
        /// 放在 `Chart` 上而不是 `KuwoChart` 上，调用点才能写 `.hot`
        /// （写在枚举上时 `KuwoChart.Chart` 里找不到它——只有 xcodebuild 会报这个错，
        /// 本地 typecheck 不含视图文件，踩过一次）。
        static let hot = Chart(webId: "489927", mobileId: "16", name: "酷我热歌榜")
    }

    /// 一页榜单：榜名 + 更新日期 + 曲目。日期由接口给（`pub`），不自己猜。
    struct Page {
        let name: String
        let publishedDate: String
        let songs: [Song]

        var count: Int { songs.count }
    }

    /// 请求头：酷我这一族接口带自家 Referer 最稳（实测不带也能通，带上更接近真实客户端）。
    static let headers = ["Referer": "https://www.kuwo.cn/"]

    static func songsURL(mobileId: String, page: Int = 0, rn: Int = 100) -> String {
        "https://kbangserver.kuwo.cn/ksong.s?from=pc&type=bang&id=\(mobileId)&pn=\(page)&rn=\(rn)"
    }

    /// 拉一个榜的前 `rn` 首。失败抛错，由调用方显示失败态 + 重试（不放假数据糊页面）。
    ///
    /// 成功时顺手把整页写进当天缓存：榜单一天只变一次，冷启动/再次进页面直接读缓存，
    /// 一个请求都不发（老板 r84："热门音乐是一天中定死的，不用每次打开都加载"）。
    static func fetchPage(_ chart: Chart, rn: Int = 100, day: Int = KuwoChart.today) async throws -> Page {
        let json = try await APIClient.shared.getJSON(
            songsURL(mobileId: chart.mobileId, rn: rn),
            headers: headers,
            timeout: 20
        )
        guard let page = parsePage(json) else {
            throw APIError.parse("榜单解析失败（\(chart.name)）")
        }
        save(page, for: chart, day: day)
        return page
    }

    /// 只问"这个榜现在是哪一天的"——`rn=1` 的 `ksong.s` 只有 ~1.5 KB（整页 100 首要 ~120 KB）。
    ///
    /// 老板："热门音乐不用按本地日期强刷，按酷我接口自己换榜的时间换就行。"
    /// 所以缓存有效性不再看"我们的哪一天"，而是看**服务端返回的 `pub` 日期**：
    /// 日期没变 → 一个整页请求都不发；日期变了 → 才重取 100 首。
    static func latestPublishedDate(_ chart: Chart) async -> String? {
        guard let json = try? await APIClient.shared.getJSON(
            songsURL(mobileId: chart.mobileId, rn: 1),
            headers: headers, timeout: 12),
            let pub = json["pub"] as? String, !pub.isEmpty else { return nil }
        return pub
    }

    // MARK: 缓存（UserDefaults，JSON）

    static var today: Int { DiscoverRules.today }

    private static func cacheKey(_ chart: Chart) -> String {
        "kw_chart_page_v1_\(chart.mobileId)"
    }

    private struct CachedPage: Codable {
        let day: Int
        let name: String
        let publishedDate: String
        let songs: [Song]
    }

    /// 缓存里的整页（不问日期）——调用方先拿它铺满界面，再决定要不要按 `pub` 核对
    static func cachedPageAnyDay(_ chart: Chart) -> Page? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(chart)),
              let cached = try? JSONDecoder().decode(CachedPage.self, from: data),
              !cached.songs.isEmpty else { return nil }
        return Page(name: cached.name, publishedDate: cached.publishedDate, songs: cached.songs)
    }

    /// 只有"缓存里的 `pub` 与给定的服务端日期一致"才算命中。
    static func cachedPage(_ chart: Chart, publishedDate: String) -> Page? {
        guard let page = cachedPageAnyDay(chart), page.publishedDate == publishedDate else { return nil }
        return page
    }

    static func save(_ page: Page, for chart: Chart, day: Int = KuwoChart.today) {
        let cached = CachedPage(day: day, name: page.name,
                                publishedDate: page.publishedDate, songs: page.songs)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(chart))
    }

    // MARK: 解析（纯函数，CI 断言直接喂字典进来）

    /// 解析 `ksong.s` 的响应。`musiclist` 空 / 全被丢掉时返回 nil —— 让上层走失败态，
    /// 而不是显示一个 0 首的"正常"页面。
    static func parsePage(_ json: [String: Any]) -> Page? {
        let list = json["musiclist"] as? [[String: Any]] ?? []
        // 2026-11-27（老板）：榜单里也不许出现上传者的变速/剪辑条目
        let songs = JunkAudioRules.filter(list.compactMap(song(from:)))
        guard !songs.isEmpty else { return nil }
        return Page(
            name: (json["name"] as? String) ?? "",
            publishedDate: (json["pub"] as? String) ?? "",
            songs: songs
        )
    }

    static func song(from item: [String: Any]) -> Song? {
        // rid 是这一条的身份证：没有它就没法播放、也没法按 rid 取封面，直接丢掉
        guard let rid = text(item["id"]), !rid.isEmpty else { return nil }
        guard let rawName = text(item["name"]), !rawName.isEmpty else { return nil }
        return Song(
            platform: .kuwo,
            platformID: rid,
            name: TextClean.text(rawName),
            singer: TextClean.text(text(item["artist"]) ?? ""),
            album: TextClean.text(text(item["album"]) ?? ""),
            duration: TimeInterval(durationSec(from: item)),
            picURL: nil
        )
    }

    /// 曲长：`song_duration` 优先（见文件头坑 ②），退化到 `duration`。
    /// 两个都没有时返回 0：0 会让时长闸门失效（`durationMismatch` 要求 expected > 0），
    /// 但比编一个假时长好——编了就变成"猜着换源"。
    static func durationSec(from item: [String: Any]) -> Int {
        for key in ["song_duration", "duration"] {
            if let n = number(item[key]), n > 0 { return n }
        }
        return 0
    }

    // MARK: 字段取值（接口里同一字段常常有时是字符串有时是数字）

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

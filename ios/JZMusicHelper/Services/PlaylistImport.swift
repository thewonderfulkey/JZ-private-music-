import Foundation

// MARK: - 导入歌单（QQ / 网易云 / 酷我 / 酷狗）
//
// 老板口径（2026-11-19）：
//   · 只给一个**分享链接**（微信/QQ 里复制出来的那种），App 自己认出是哪家、把歌单读出来；
//   · 读出来以后**一次性写死**：歌单歌曲全部落盘，往后不再发请求（"加载一次后写死"）。
//
// 四家接口实测（2026-11-19，本机 Windows，**匿名、无登录、无 cookie**）：
//   · QQ：分享链接里的 `id` 就是 disstid。官方老接口
//         `c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?...&disstid=` 直连可用；
//         **必须带 `Referer: https://y.qq.com/`**——缺了会回 `{"code":0,"subcode":1,"msg":"invalid referer"}`。
//         实测样例（老板给的链接）返回 102 首，字段 `songlist[].mid / name / singer[].name /
//         album.name / album.mid / interval`。
//   · 网易：`music.163.com/api/v6/playlist/detail?id=...&n=1000&s=8`（Referer 即可，cookie 非必需）
//         返回 `playlist.name / coverImgUrl / creator.nickname / tracks[]`（`id/name/ar/al/dt`）。
//         `n` 是**本次最多回多少首**，服务端上限 1000；超过 1000 首的歌单只导前 1000 首。
//         私密歌单/别人"我喜欢的音乐"没登录读不到（回 404 或空 tracks），这是设计边界。
//   · 酷我：直接复用发现页「最新单曲」那套 `KuwoPlaylist`（wapi `playListInfo`，pid + 分页 100）。
//   · 酷狗：`mobiles.kugou.com/api/v3/special/info`（名字/作者/封面）+
//         `mobiles.kugou.com/api/v3/special/song`（hash / filename / duration / union_cover，一页 100）。
//         新版分享链接是 `m.kugou.com/songlist/gcid_xxx/`（没有数字 id），先取这个 H5 页面，
//         从它内联的 state 里抠 `"specialid":数字`——这是唯一一处"读页面"，其余全走 JSON 接口。
//
// 为什么不在 App 里内嵌一个后端：四家接口都是公开 GET/JSON，App 直连最省事；这些 Host
//（y.qq.com / music.163.com / wapi.kuwo.cn / mobiles.kugou.com）本来就在搜索/取流链路上用着，
// 网络可达性与现有功能**同一水位**，不引入新的暴露面。

/// 一个导入进来的歌单（一次性快照：歌手/歌曲/封面都存下来，之后不再请求）
struct ImportedPlaylist: Codable, Identifiable, Hashable {
    let platform: MusicPlatform
    /// 平台侧的歌单 id（酷狗可能是 `gcid_xxx`，见 `PlaylistImport.Link`）
    let sourceID: String
    let name: String
    let creator: String
    let cover: String
    let songs: [Song]
    let importedAt: Date

    /// 同一家的同一个歌单只留一份（重复导入＝覆盖）
    var id: String { "\(platform.rawValue)_\(sourceID)" }

    /// 列表里的一行元信息：`QQ音乐 · 102 首 · Roma`
    var metaLine: String {
        var parts = ["\(songs.count) 首", platform.displayName]
        if !creator.isEmpty { parts.append(creator) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 导入失败的原因（都是"用户看得懂"的话）

enum PlaylistImportError: LocalizedError {
    /// 链接不是这四家里的任何一个（或者不是歌单链接）
    case unrecognized
    /// 连上了、也认出来了，但一首歌都没读到
    case empty
    /// 平台明确拒绝（私密歌单、链接失效、接口改版）
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .unrecognized:
            return "没认出这是哪家的歌单链接（支持 QQ / 网易云 / 酷我 / 酷狗）"
        case .empty:
            return "歌单里没读到歌曲（可能是私密歌单，或链接已失效）"
        case .blocked(let why):
            return why
        }
    }
}

// MARK: - 导入器

enum PlaylistImport {

    /// 认出来的结果：哪家 + 平台侧 id
    struct Link: Equatable {
        let platform: MusicPlatform
        let sourceID: String
    }

    /// 一页 100 首（四家接口的实际上限都接近这个数）
    static let pageSize = 100
    /// 一次导入最多收多少首：挡住"几千首的超大歌单"把首屏/落盘撑爆。
    /// 网易的接口上限也是 1000（`n=1000`），两边口径一致。
    static let maxSongs = 1000
    /// 最多翻几页（10 × 100 = 1000，和 `maxSongs` 对齐）
    static let maxPages = 10

    // MARK: 链接识别（纯函数，CI 断言直接喂字符串）

    /// 从一段分享文案里抠出第一个 http(s) 链接。
    /// 微信/QQ 的分享文本长这样：`【QQ音乐】2001-2010 https://i2.y.qq.com/... 复制打开`，
    /// 所以不能整段当 URL 解析，要截到空白或中文标点为止。
    static func extractURLString(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.range(of: "http") else { return nil }
        var candidate = String(trimmed[start.lowerBound...])
        let stop = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "，。；、）】「」\"'<>"))
        if let end = candidate.rangeOfCharacter(from: stop) {
            candidate = String(candidate[..<end.lowerBound])
        }
        // 句末的英文标点也切掉（`...id=123.` 这种）
        while let last = candidate.last, ",.!?;:".contains(last) {
            candidate.removeLast()
        }
        return candidate.isEmpty ? nil : candidate
    }

    /// 认链接：只看 host + path/query（不看页面内容），认不出返回 nil。
    ///
    /// 四家的分享链接形态（都实测过）：
    ///   QQ      `i2.y.qq.com/n3/other/pages/details/playlist.html?id=8887675900...`
    ///           `y.qq.com/n/ryqq/playlist/8887675900`
    ///   网易    `music.163.com/playlist?id=3778678` / `y.music.163.com/m/playlist?id=...`
    ///           `music.163.com/#/playlist?id=...`（参数在 # 后面，要单独认）
    ///   酷我    `www.kuwo.cn/playlist_detail/1082685104` / `m.kuwo.cn/newh5app/playlist_detail/...`
    ///   酷狗    `m.kugou.com/songlist/gcid_3z9vj1svz2yz0c4/?src_cid=...`
    ///           `www.kugou.com/yy/special/single/5988470.html`
    static func detect(_ text: String) -> Link? {
        guard var raw = extractURLString(text) else { return nil }
        if raw.contains("%"), let decoded = raw.removingPercentEncoding { raw = decoded }
        guard let comps = URLComponents(string: raw), let rawHost = comps.host?.lowercased() else {
            return nil
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost

        var path = comps.path
        var query: [String: String] = [:]
        func absorb(_ items: [URLQueryItem]?) {
            for item in items ?? [] { query[item.name.lowercased()] = item.value ?? "" }
        }
        absorb(comps.queryItems)
        // 网易网页版把参数放在 `#` 后面：`https://music.163.com/#/playlist?id=123`
        if let fragment = comps.fragment, fragment.contains("?") {
            let tail = fragment.hasPrefix("/") ? fragment : "/" + fragment
            if let inner = URLComponents(string: tail) {
                absorb(inner.queryItems)
                if !inner.path.isEmpty, inner.path != "/" { path += inner.path }
            }
        }

        if host == "qq.com" || host.hasSuffix(".qq.com") {
            if let id = digits(query["id"] ?? query["disstid"] ?? query["songlistid"] ?? "") {
                return Link(platform: .qq, sourceID: id)
            }
            if let id = numberAfter("playlist", in: path) {
                return Link(platform: .qq, sourceID: id)
            }
            return nil
        }

        if host == "163.com" || host.hasSuffix(".163.com")
            || host == "163cn.tv" || host.hasSuffix(".163cn.tv") {
            if let id = digits(query["id"] ?? "") {
                return Link(platform: .netease, sourceID: id)
            }
            if let id = numberAfter("playlist", in: path) {
                return Link(platform: .netease, sourceID: id)
            }
            return nil
        }

        if host == "kuwo.cn" || host.hasSuffix(".kuwo.cn") {
            if let id = digits(query["pid"] ?? query["id"] ?? "") {
                return Link(platform: .kuwo, sourceID: id)
            }
            if let id = numberAfter("playlist_detail", in: path) ?? numberAfter("playlist", in: path) {
                return Link(platform: .kuwo, sourceID: id)
            }
            return nil
        }

        if host == "kugou.com" || host.hasSuffix(".kugou.com") {
            for part in path.split(separator: "/") where part.hasPrefix("gcid_") {
                return Link(platform: .kugou, sourceID: String(part))
            }
            if let id = digits(query["specialid"] ?? query["listid"] ?? "") {
                return Link(platform: .kugou, sourceID: id)
            }
            if let id = numberAfter("single", in: path) {
                return Link(platform: .kugou, sourceID: id)
            }
            return nil
        }

        return nil
    }

    /// 认链接 + 处理短链（`c6.y.qq.com/base/fcgi-bin/u?__=` / `163cn.tv/xxx` / `t1.kugou.com/xxx`）。
    /// 短链本身不带 id，只能跟一次 302，从落地页的 URL 里再认。
    ///
    /// 只对四家的域名跟跳转：用户粘错成别的网页时，不该让 App 去请求一个陌生地址。
    static func resolve(_ text: String) async -> Link? {
        if let link = detect(text) { return link }
        guard let raw = extractURLString(text),
              let url = URL(string: raw.removingPercentEncoding ?? raw),
              isKnownHost(url.host) else { return nil }
        guard let final = await followRedirect(url) else { return nil }
        return detect(final.absoluteString)
    }

    /// 是不是四家里的域名（含子域）；短链域名也算
    static func isKnownHost(_ rawHost: String?) -> Bool {
        guard let rawHost = rawHost?.lowercased() else { return false }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        for family in ["qq.com", "163.com", "163cn.tv", "kuwo.cn", "kugou.com"] {
            if host == family || host.hasSuffix("." + family) { return true }
        }
        return false
    }

    /// 跟一次重定向，返回最终 URL（`URLSession` 默认就会跟 301/302，`response.url` 是落地地址）
    static func followRedirect(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode) else { return nil }
        return response.url
    }

    /// 路径里 `segment` 的下一段开头的数字：`.../playlist/8887675900` → `8887675900`，
    /// `.../single/5988470.html` → `5988470`
    static func numberAfter(_ segment: String, in path: String) -> String? {
        let parts = path.split(separator: "/").map { String($0) }
        guard let index = parts.firstIndex(of: segment), index + 1 < parts.count else { return nil }
        return digits(parts[index + 1])
    }

    /// 取开头连续数字（`5988470.html` → `5988470`；`abc` → nil）
    static func digits(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let run = trimmed.prefix { $0.isNumber }
        return run.isEmpty ? nil : String(run)
    }

    // MARK: 拉取

    static func fetch(_ link: Link) async throws -> ImportedPlaylist {
        switch link.platform {
        case .qq: return try await fetchQQ(link.sourceID)
        case .netease: return try await fetchNetease(link.sourceID)
        case .kuwo: return try await fetchKuwo(link.sourceID)
        case .kugou: return try await fetchKugou(link.sourceID)
        }
    }

    // MARK: QQ

    static func qqURL(_ disstid: String) -> String {
        "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg"
            + "?type=1&json=1&utf8=1&onlysong=0&new_format=1&format=json&disstid=\(disstid)"
    }

    static func fetchQQ(_ disstid: String) async throws -> ImportedPlaylist {
        let json = try await APIClient.shared.getJSON(
            qqURL(disstid),
            headers: ["Referer": "https://y.qq.com/"],
            timeout: 25
        )
        guard let playlist = parseQQ(json, sourceID: disstid) else {
            throw PlaylistImportError.empty
        }
        return playlist
    }

    /// QQ 歌单解析（纯函数）。`cdlist[0]` 上带歌单名/创建者/封面，`songlist` 是完整歌曲列表。
    static func parseQQ(_ json: [String: Any], sourceID: String) -> ImportedPlaylist? {
        guard let cd = (json["cdlist"] as? [[String: Any]])?.first else { return nil }
        let list = cd["songlist"] as? [[String: Any]] ?? []
        let songs: [Song] = list.compactMap { item -> Song? in
            guard let mid = text(item["mid"]), !mid.isEmpty,
                  let name = text(item["name"]), !name.isEmpty else { return nil }
            let singers = (item["singer"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .joined(separator: "/")
            let album = item["album"] as? [String: Any]
            let albumName = text(album?["name"]) ?? ""
            let albumMid = text(album?["mid"]) ?? ""
            // 和 QQ 搜索同口径：有 albummid 就能拼出官方封面
            let pic = albumMid.isEmpty
                ? nil
                : "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg"
            let duration = Double(number(item["interval"]) ?? 0)
            return Song.make(platform: .qq, platformID: mid, name: name, singer: singers,
                             album: albumName, duration: duration, picURL: pic)
        }
        let unique = dedupe(songs)
        guard !unique.isEmpty else { return nil }
        return ImportedPlaylist(
            platform: .qq,
            sourceID: sourceID,
            name: TextClean.text(text(cd["dissname"]) ?? "QQ 歌单"),
            creator: TextClean.text(text(cd["nickname"]) ?? text(cd["nick"]) ?? ""),
            cover: httpsURL(text(cd["logo"]) ?? ""),
            songs: unique,
            importedAt: Date()
        )
    }

    // MARK: 网易云
    //
    // 两个坑，都是 2026-11-19 导入真机反馈的「我喜欢的音乐」（729 首只进来 6 首）踩出来的：
    //
    //   ① `api/v6/playlist/detail` 的 `tracks` **不是全量**。普通歌单（热歌榜 200 首）按 `n` 给全；
    //      但 `specialType == 5` 的「我喜欢的音乐」匿名访问只回 **6 首**——实测 729 首的歌单：
    //      `trackCount=729`、`trackIds=729`、`tracks=6`。不是我们解析丢歌，是接口只给 6 首试听。
    //      所以"没登录也导入成功、只是数量不对"是预期内的：歌单本身是公开的，被截断的是详情里的歌曲数组。
    //   ② 真正全的是 `playlist.trackIds`（顺序与歌单一致）。`tracks` 不够时按 id 批量补
    //      `api/song/detail?ids=[...]`：实测一次 200 个 id 正常（约 620 KB / 4s），500 个会回空，
    //      所以一页 200。补回来的单曲字段是 `artists / album / duration(ms)`，和详情里的 `ar / al / dt` 不同名。

    /// 补歌时一次带多少个 id（500 个服务端会回空数组）
    static let neteaseSongBatch = 200

    static func neteaseURL(_ id: String) -> String {
        "https://music.163.com/api/v6/playlist/detail?id=\(id)&n=\(maxSongs)&s=8"
    }

    /// 按 id 批量取单曲（`ids=[1,2,3]` 要百分号编码方括号）
    static func neteaseSongsURL(_ ids: [String]) -> String {
        "https://music.163.com/api/song/detail?ids="
            + APIClient.encode("[\(ids.joined(separator: ","))]")
    }

    static func fetchNetease(_ id: String) async throws -> ImportedPlaylist {
        let json = try await APIClient.shared.getJSON(
            neteaseURL(id),
            headers: ["Referer": "https://music.163.com/"],
            timeout: 25
        )
        guard let meta = parseNeteaseMeta(json) else {
            throw PlaylistImportError.blocked("网易云歌单打不开（私密歌单或链接已失效）")
        }
        let primary = parseNeteaseSongs(playlistTracks(json))
        let trackIDs = Array(neteaseTrackIDs(json).prefix(maxSongs))

        // tracks 被接口截断（"我喜欢的音乐"只回 6 首）时，按 trackIds 把剩下的补回来
        var fetched: [Song] = []
        if trackIDs.count > primary.count {
            let known = Set(primary.map(\.platformID))
            for chunk in trackIDs.filter({ !known.contains($0) }).chunked(neteaseSongBatch) {
                if let songs = try? await fetchNeteaseSongs(ids: chunk) {
                    fetched.append(contentsOf: songs)
                }
            }
        }

        let songs = mergeNetease(trackIDs: trackIDs, primary: primary, fetched: fetched)
        guard !songs.isEmpty else { throw PlaylistImportError.empty }
        return ImportedPlaylist(
            platform: .netease,
            sourceID: id,
            name: meta.name,
            creator: meta.creator,
            cover: meta.cover,
            songs: songs,
            importedAt: Date()
        )
    }

    /// 一页单曲详情（`ids` 由调用方按 `neteaseSongBatch` 分批）
    static func fetchNeteaseSongs(ids: [String]) async throws -> [Song] {
        let json = try await APIClient.shared.getJSON(
            neteaseSongsURL(ids),
            headers: ["Referer": "https://music.163.com/"],
            timeout: 25
        )
        return parseNeteaseSongs(json["songs"] as? [[String: Any]] ?? [])
    }

    /// 详情响应里的 `playlist.tracks`（可能被截断，见上面的坑 ①）
    static func playlistTracks(_ json: [String: Any]) -> [[String: Any]] {
        (json["playlist"] as? [String: Any])?["tracks"] as? [[String: Any]] ?? []
    }

    /// 歌单里全部歌曲 id（顺序即歌单顺序；`tracks` 被截断时靠它补齐）
    static func neteaseTrackIDs(_ json: [String: Any]) -> [String] {
        guard let pl = json["playlist"] as? [String: Any],
              let list = pl["trackIds"] as? [[String: Any]] else { return [] }
        return list.compactMap { item -> String? in
            guard let id = text(item["id"]), !id.isEmpty, id != "0" else { return nil }
            return id
        }
    }

    /// 歌单元信息（`code != 200` / 没有 playlist → nil）
    static func parseNeteaseMeta(_ json: [String: Any]) -> (name: String, creator: String, cover: String)? {
        if let code = number(json["code"]), code != 200 { return nil }
        guard let pl = json["playlist"] as? [String: Any] else { return nil }
        let creator = (pl["creator"] as? [String: Any]).flatMap { text($0["nickname"]) } ?? ""
        return (
            name: TextClean.text(text(pl["name"]) ?? "网易云歌单"),
            creator: TextClean.text(creator),
            cover: httpsURL(text(pl["coverImgUrl"]) ?? "")
        )
    }

    /// 单曲字典 → Song：详情里是 `ar / al / dt`，`api/song/detail` 里是 `artists / album / duration`，两种都认。
    static func neteaseSong(from item: [String: Any]) -> Song? {
        guard let songID = text(item["id"]), !songID.isEmpty, songID != "0",
              let name = text(item["name"]), !name.isEmpty else { return nil }
        let artistItems = (item["ar"] as? [[String: Any]])
            ?? (item["artists"] as? [[String: Any]])
            ?? []
        let singers = artistItems.compactMap { $0["name"] as? String }.joined(separator: "/")
        let album = (item["al"] as? [String: Any]) ?? (item["album"] as? [String: Any])
        let albumName = text(album?["name"]) ?? ""
        let pic: String? = text(album?["picUrl"]).map { httpsURL($0) }
        let ms = number(item["dt"]) ?? number(item["duration"]) ?? 0
        return Song.make(platform: .netease, platformID: songID, name: name, singer: singers,
                         album: albumName, duration: Double(ms) / 1000.0, picURL: pic)
    }

    static func parseNeteaseSongs(_ list: [[String: Any]]) -> [Song] {
        dedupe(list.compactMap { neteaseSong(from: $0) })
    }

    /// 按**歌单顺序**合并「详情已给的」与「按 id 补回来的」。
    /// `trackIDs` 为空（老响应 / 没给 trackIds）时退回 primary 原序，保证不丢歌。
    static func mergeNetease(trackIDs: [String], primary: [Song], fetched: [Song]) -> [Song] {
        guard !trackIDs.isEmpty else { return Array(dedupe(primary).prefix(maxSongs)) }
        var byID: [String: Song] = [:]
        for song in primary { byID[song.platformID] = song }
        for song in fetched where byID[song.platformID] == nil { byID[song.platformID] = song }
        var seen = Set<String>()
        var out: [Song] = []
        for id in trackIDs {
            guard out.count < maxSongs, seen.insert(id).inserted, let song = byID[id] else { continue }
            out.append(song)
        }
        return out
    }

    /// 兼容入口（SelfTest 用它验证纯解析）：只用详情里的 `tracks`，不补歌。
    static func parseNetease(_ json: [String: Any], sourceID: String) -> ImportedPlaylist? {
        guard let meta = parseNeteaseMeta(json) else { return nil }
        let songs = mergeNetease(trackIDs: neteaseTrackIDs(json),
                                 primary: parseNeteaseSongs(playlistTracks(json)),
                                 fetched: [])
        guard !songs.isEmpty else { return nil }
        return ImportedPlaylist(
            platform: .netease,
            sourceID: sourceID,
            name: meta.name,
            creator: meta.creator,
            cover: meta.cover,
            songs: songs,
            importedAt: Date()
        )
    }

    // MARK: 酷我（复用 `KuwoPlaylist`，一页 100 首，往后翻到读满 / 读完）

    static func fetchKuwo(_ pid: String) async throws -> ImportedPlaylist {
        var releases: [KuwoPlaylist.Release] = []
        var summary: KuwoPlaylist.Summary?
        var page = 0
        while page < maxPages {
            guard let detail = try? await KuwoPlaylist.fetchDetail(pid: pid, page: page) else {
                // 第一页就失败 → 真的是失败；后面的页失败 → 说明翻到头了，停
                if page == 0 { throw PlaylistImportError.blocked("酷我歌单打不开（私密歌单或链接已失效）") }
                break
            }
            summary = detail.summary
            releases.append(contentsOf: detail.releases)
            if detail.releases.count < KuwoPlaylist.pageSize || releases.count >= maxSongs { break }
            page += 1
        }
        guard let summary, !releases.isEmpty else { throw PlaylistImportError.empty }
        let songs = Array(dedupe(releases.map(\.song)).prefix(maxSongs))
        return ImportedPlaylist(
            platform: .kuwo,
            sourceID: pid,
            name: TextClean.text(summary.name.isEmpty ? "酷我歌单" : summary.name),
            creator: TextClean.text(summary.creator),
            cover: httpsURL(summary.cover),
            songs: songs,
            importedAt: Date()
        )
    }

    // MARK: 酷狗（gcid 链接要先从 H5 页面里抠出数字 specialid）

    static let kugouHeaders = ["Referer": "https://m.kugou.com/"]

    static func kugouInfoURL(_ specialID: String) -> String {
        "https://mobiles.kugou.com/api/v3/special/info?specialid=\(specialID)&version=8000&plat=0"
    }

    static func kugouSongsURL(_ specialID: String, page: Int) -> String {
        "https://mobiles.kugou.com/api/v3/special/song?specialid=\(specialID)"
            + "&page=\(page)&pagesize=\(pageSize)&version=8000&plat=0"
    }

    static func fetchKugou(_ sourceID: String) async throws -> ImportedPlaylist {
        var specialID = sourceID
        var name = "酷狗歌单"
        var creator = ""
        var cover = ""

        if sourceID.hasPrefix("gcid_") {
            let html = try await APIClient.shared.getString(
                "https://m.kugou.com/songlist/\(sourceID)/",
                headers: kugouHeaders,
                timeout: 20
            )
            guard let parsed = firstMatch(#""specialid"\s*:\s*"?(\d+)"#, in: html) else {
                throw PlaylistImportError.blocked("这个酷狗歌单链接解析不出歌单 id（可能已失效）")
            }
            specialID = parsed
            if let inline = firstMatch(#""name"\s*:\s*"([^"]+)""#, in: html) {
                name = TextClean.text(inline)
            }
            if let inlineCover = firstMatch(#""cover"\s*:\s*"([^"]+)""#, in: html) {
                cover = kugouCover(inlineCover)
            }
        }

        // 歌单元信息（名字 / 作者 / 封面）以 special/info 为准，H5 页面里抠到的只做兜底
        if let info = try? await APIClient.shared.getJSON(kugouInfoURL(specialID),
                                                          headers: kugouHeaders, timeout: 15),
           let data = info["data"] as? [String: Any] {
            if let realName = text(data["specialname"]), !realName.isEmpty {
                name = TextClean.text(realName)
            }
            if let nick = text(data["nickname"]) { creator = TextClean.text(nick) }
            if let img = text(data["imgurl"]) ?? text(data["cover"]), !img.isEmpty {
                cover = kugouCover(img)
            }
        }

        var songs: [Song] = []
        var page = 1
        while page <= maxPages {
            guard let json = try? await APIClient.shared.getJSON(kugouSongsURL(specialID, page: page),
                                                                 headers: kugouHeaders, timeout: 20),
                  let list = json.nested(["data", "info"]) as? [[String: Any]] else { break }
            songs.append(contentsOf: parseKugouSongs(list))
            let total = number(json.nested(["data", "total"])) ?? 0
            if list.count < pageSize || (total > 0 && songs.count >= total) || songs.count >= maxSongs {
                break
            }
            page += 1
        }

        let unique = Array(dedupe(songs).prefix(maxSongs))
        guard !unique.isEmpty else {
            throw PlaylistImportError.blocked("酷狗歌单里没读到歌曲（私密歌单或链接已失效）")
        }
        return ImportedPlaylist(
            platform: .kugou,
            sourceID: sourceID,
            name: name,
            creator: creator,
            cover: cover,
            songs: unique,
            importedAt: Date()
        )
    }

    /// 酷狗歌单页的条目：`filename` 是 `"歌手 - 歌名"`（不是分开的字段），时长在 `duration` 秒，
    /// 封面在 `trans_param.union_cover`（带 `{size}` 占位）。
    static func parseKugouSongs(_ list: [[String: Any]]) -> [Song] {
        list.compactMap { item -> Song? in
            guard let hash = text(item["hash"]), !hash.isEmpty,
                  let raw = text(item["filename"]), !raw.isEmpty else { return nil }
            let split = splitKugouFilename(raw)
            guard !split.name.isEmpty else { return nil }
            let duration = Double(number(item["duration"]) ?? 0)
            let union = (item["trans_param"] as? [String: Any])?["union_cover"] as? String ?? ""
            let pic: String? = union.isEmpty ? nil : kugouCover(union)
            return Song.make(platform: .kugou, platformID: hash, name: split.name,
                             singer: split.artist, album: "", duration: duration, picURL: pic)
        }
    }

    /// `"队长 - NUNA"` → `(name: "NUNA", artist: "队长")`；没有分隔符就整条当歌名。
    static func splitKugouFilename(_ raw: String) -> (name: String, artist: String) {
        let cleaned = raw.replacingOccurrences(of: "\\/", with: "/")
        guard let range = cleaned.range(of: " - ") else { return (TextClean.text(cleaned), "") }
        let artist = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let name = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if artist.isEmpty || name.isEmpty { return (TextClean.text(cleaned), "") }
        return (TextClean.text(name), TextClean.text(artist))
    }

    /// 酷狗封面模板：`http://imge.kugou.com/stdmusic/{size}/xxx.jpg` + `\/` 转义
    static func kugouCover(_ raw: String) -> String {
        let unescaped = raw.replacingOccurrences(of: "\\/", with: "/")
        let sized = unescaped.replacingOccurrences(of: "{size}", with: "400")
        return httpsURL(sized)
    }

    // MARK: 小工具（纯函数）

    /// 同一平台同一个 id 只留第一次出现（跨平台的同曲不在这里去——那是播放器的事）
    static func dedupe(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }

    /// 接口偶尔给 `http://`（封面全是）。ATS 严格，统一升 https。
    static func httpsURL(_ raw: String) -> String {
        guard raw.hasPrefix("http://") else { return raw }
        return "https://" + raw.dropFirst("http://".count)
    }

    /// 正则取第一个捕获组（酷狗 gcid 页面里抠 specialid 用）
    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // 接口里同一字段常常有时是字符串有时是数字，这里统一成 String / Int
    static func text(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    static func number(_ any: Any?) -> Int? {
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

import Foundation

// MARK: - 搜索适配器协议
protocol SearchAdapter: Sendable {
    var platform: MusicPlatform { get }
    /// `page` 从 1 开始（r65 老板反馈 ⑦：「查看更多结果」按页往下翻）
    func search(keyword: String, limit: Int, page: Int) async throws -> [Song]
}

extension SearchAdapter {
    /// 只取第一页（封面兜底这类"够用就行"的调用方走这个）
    func search(keyword: String, limit: Int) async throws -> [Song] {
        try await search(keyword: keyword, limit: limit, page: 1)
    }
}

// MARK: - QQ 音乐
// https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=20&w=关键词&format=json
struct QQSearchAdapter: SearchAdapter {
    let platform: MusicPlatform = .qq

    func search(keyword: String, limit: Int, page: Int = 1) async throws -> [Song] {
        let url = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
            + "?p=\(max(1, page))&n=\(limit)&w=\(APIClient.encode(keyword))&format=json"
        let json = try await APIClient.shared.getJSON(url, headers: ["Referer": "https://y.qq.com/"])
        guard let list = json.nested(["data", "song", "list"]) as? [[String: Any]] else {
            throw APIError.parse("QQ 搜索结果结构异常")
        }
        var songs: [Song] = []
        for item in list {
            guard let name = item["songname"] as? String, !name.isEmpty,
                  let mid = item["songmid"] as? String, !mid.isEmpty else { continue }
            let singers = (item["singer"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .joined(separator: "/")
            let album = item["albumname"] as? String ?? ""
            let dur = (item["interval"] as? Int) ?? 0
            let albumMid = item["albummid"] as? String ?? ""
            let pic = albumMid.isEmpty
                ? nil
                : "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg"
            songs.append(Song.make(platform: .qq, platformID: mid, name: name, singer: singers,
                              album: album, duration: Double(dur), picURL: pic))
        }
        return songs
    }
}

// MARK: - 网易云音乐
// 2026-10-31 实测：老接口 /api/search/get/web 已被风控（code=405），改用 /api/search/get
// 2026-11-16 复测：/api/search/get 正常返回 20 条
//
// r123（《연애의 조건》iOS 下载不到无损的真凶）：官方 `/api/search/get` 在**真机上**会对
// iOS 这侧（UA + TLS 指纹）回"200 但 0 条"或直接 405，于是跨源搜索里**网易候选一个都没有**——
// 弹层诊断能对上：6 条候选全是 QQ/酷狗，失败原因里根本没有"网易"。
// 现在补一条兜底：官方搜不到时改用 gdstudio 的 `types=search&source=netease`
// （和取流同一个域名，官方被风控时它通常还通），映射成同样的 Song。
struct NeteaseSearchAdapter: SearchAdapter {
    let platform: MusicPlatform = .netease

    func search(keyword: String, limit: Int, page: Int = 1) async throws -> [Song] {
        // 网易用 offset 分页：第 n 页 = 跳过 (n-1)*limit 条
        let offset = max(0, page - 1) * limit
        let url = "https://music.163.com/api/search/get"
            + "?s=\(APIClient.encode(keyword))&type=1&offset=\(offset)&limit=\(limit)"
        // 真机上官方接口可能是"卡住不回"而不是快速报错：给它 4s，把剩下的预算留给 gdstudio 兜底
        // （整个平台在 searchAll 里只有 8s，官方一卡就把兜底也一起饿死了——r123 的真凶之一）
        if let json = try? await APIClient.shared.getJSON(
            url, headers: ["Referer": "https://music.163.com/"], timeout: 4),
           (json["code"] as? Int) == 200,
           let list = json.nested(["result", "songs"]) as? [[String: Any]] {
            let songs = Self.songs(fromOfficial: list)
            if !songs.isEmpty {
                return await Self.fillCovers(songs)
            }
        }
        // 官方没给结果（被风控 / 空结果）→ gdstudio 搜索兜底
        let fallback = await Self.gdstudioSearch(keyword: keyword, limit: limit, page: page)
        if !fallback.isEmpty { return fallback }
        return []
    }

    static func songs(fromOfficial list: [[String: Any]]) -> [Song] {
        var songs: [Song] = []
        for item in list {
            guard let id = item["id"] as? Int, id > 0,
                  let name = item["name"] as? String, !name.isEmpty else { continue }
            let artists = (item["artists"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .joined(separator: "/")
            let album = (item["album"] as? [String: Any])?["name"] as? String ?? ""
            let durMs = (item["duration"] as? Int) ?? 0
            songs.append(Song.make(platform: .netease, platformID: String(id), name: name,
                              singer: artists, album: album,
                              duration: Double(durMs / 1000), picURL: nil))
        }
        return songs
    }

    /// gdstudio 搜索 → Song 列表（纯函数，CI 断言可直接喂字典）
    ///
    /// gdstudio 不返回时长（选曲侧只用于"找 id"），`duration` 记 0：
    /// `sameSong` 的时长闸门会跳过，`DownloadResolver` 也会退回档位桶比较。
    /// 取流那一侧用接口自报的 `br`/`size` 兜底定档，所以时长缺不影响"是不是无损"。
    static func songs(fromGdstudio items: [[String: Any]]) -> [Song] {
        var seen = Set<String>()
        var songs: [Song] = []
        for item in items {
            let id: String
            if let n = item["id"] as? Int { id = String(n) }
            else if let s = item["id"] as? String, !s.isEmpty { id = s }
            else { continue }
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            let name = (item["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let artists: String
            if let arr = item["artist"] as? [String] {
                artists = arr.joined(separator: "/")
            } else if let s = item["artist"] as? String {
                artists = s
            } else {
                artists = ""
            }
            let album = item["album"] as? String ?? ""
            songs.append(Song.make(platform: .netease, platformID: id, name: name,
                              singer: artists, album: album, duration: 0, picURL: nil))
        }
        return songs
    }

    /// gdstudio 搜索（官方 /api/search/get 被风控时的兜底）
    static func gdstudioSearch(keyword: String, limit: Int, page: Int = 1) async -> [Song] {
        let url = "https://music-api.gdstudio.xyz/api.php"
            + "?types=search&source=netease&name=\(APIClient.encode(keyword))"
            + "&count=\(max(1, min(limit, 30)))&pages=\(max(1, page))"
        guard let raw = try? await APIClient.shared.getJSONArray(
            url, headers: ["User-Agent": "LX-Music-Mobile"], timeout: 10) else { return [] }
        let items = raw.compactMap { $0 as? [String: Any] }
        return songs(fromGdstudio: items)
    }

    /// v2.1.94：/api/search/get 只回 picId 不回 picUrl，用 /api/song/detail 批量补（20 首一次）
    private static func fillCovers(_ songs: [Song]) async -> [Song] {
        guard !songs.isEmpty else { return songs }
        let ids = songs.prefix(20).map(\.platformID).joined(separator: ",")
        let url = "https://music.163.com/api/song/detail?ids=[\(ids)]"
        guard let json = try? await APIClient.shared.getJSON(
            url, headers: ["Referer": "https://music.163.com/"], timeout: 3),
              let arr = json["songs"] as? [[String: Any]] else { return songs }
        var pics: [String: String] = [:]
        for o in arr {
            guard let id = o["id"] as? Int,
                  let pic = (o["album"] as? [String: Any])?["picUrl"] as? String,
                  !pic.isEmpty else { continue }
            pics[String(id)] = pic
        }
        guard !pics.isEmpty else { return songs }
        return songs.map { s in
            guard (s.picURL ?? "").isEmpty, let p = pics[s.platformID] else { return s }
            return Song.make(platform: s.platform, platformID: s.platformID, name: s.name,
                        singer: s.singer, album: s.album, duration: s.duration, picURL: p)
        }
    }
}

// MARK: - 酷我音乐
// 必须带老客户端参数 vipver=MUSIC_8.7.8.0_WX：不带时对歌手查询返回集为 UGC 翻唱/节目/DJ
// 返回的是 Python 风格单引号文本，解析与相关性过滤都在 KuwoParser 里（有单测）
struct KuwoSearchAdapter: SearchAdapter {
    let platform: MusicPlatform = .kuwo

    func search(keyword: String, limit: Int, page: Int = 1) async throws -> [Song] {
        let rn = min(limit, 50)
        let url = "https://search.kuwo.cn/r.s"
            + "?all=\(APIClient.encode(keyword))&ft=music&rn=\(rn)&pn=\(max(1, page))"
            + "&rformat=json&encoding=utf8&vipver=MUSIC_8.7.8.0_WX"
        let text = try await APIClient.shared.getString(url, headers: ["Referer": "https://www.kuwo.cn/"])
        let records = KuwoParser.relevantRecords(KuwoParser.extractAbsList(from: text), keyword: keyword)

        var songs: [Song] = []
        var variants: [Song] = []
        for item in records {
            let name = (item["SONGNAME"] ?? item["NAME"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rid = (item["MUSICRID"] ?? "").replacingOccurrences(of: "MUSIC_", with: "")
            guard !name.isEmpty, !rid.isEmpty else { continue }
            let artist = item["ARTIST"] ?? ""
            let album = item["ALBUM"] ?? ""
            let dur = KuwoParser.parseDuration(item["DURATION"] ?? "")
            // MVPIC 是酷我曲图路径，约 78% 有值；空值交给 CoverResolver 走 QQ 兜底
            let mvpic = (item["MVPIC"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let pic = mvpic.isEmpty ? nil : "https://img1.kuwo.cn/wmvpic/\(mvpic)"
            let song = Song.make(platform: .kuwo, platformID: rid, name: name, singer: artist,
                            album: album, duration: Double(dur), picURL: pic)
            // 变体不直接丢：整页都是变体时也要能出结果（否则界面显示"酷我 0 首"，像接口挂了）
            if KuwoParser.isVariant(name) { variants.append(song) } else { songs.append(song) }
        }
        return songs.isEmpty ? variants : songs
    }
}

// MARK: - 酷狗音乐
// v2.1.94：宿主从 mobilecdn.kugou.com（证书与域名不匹配）换成 mobiles.kugou.com；2026-11-16 复测 200/20 条
// 封面用 trans_param.union_cover（{size} → 500，http → https）；无该字段时返回 nil 交上层 QQ 兜底
struct KugouSearchAdapter: SearchAdapter {
    let platform: MusicPlatform = .kugou

    func search(keyword: String, limit: Int, page: Int = 1) async throws -> [Song] {
        let url = "https://mobiles.kugou.com/api/v3/search/song"
            + "?format=json&keyword=\(APIClient.encode(keyword))&page=\(max(1, page))&pagesize=\(limit)&showtype=1"
        let json = try await APIClient.shared.getJSON(url, headers: ["Referer": "https://www.kugou.com/"])
        guard let list = json.nested(["data", "info"]) as? [[String: Any]] else {
            throw APIError.parse("酷狗搜索结果结构异常")
        }
        var songs: [Song] = []
        for item in list {
            guard let name = item["songname"] as? String, !name.isEmpty,
                  let hash = item["hash"] as? String, !hash.isEmpty else { continue }
            let singer = item["singername"] as? String ?? ""
            let album = item["album_name"] as? String ?? ""
            let dur = (item["duration"] as? Int) ?? 0
            var pic: String? = nil
            if let union = (item["trans_param"] as? [String: Any])?["union_cover"] as? String,
               !union.isEmpty {
                pic = union.replacingOccurrences(of: "{size}", with: "500")
                    .replacingOccurrences(of: "http://", with: "https://")
            }
            songs.append(Song.make(platform: .kugou, platformID: hash, name: name, singer: singer,
                              album: album, duration: Double(dur), picURL: pic))
        }
        return songs
    }
}

// MARK: - 全部适配器（顺序即平台优先级 QQ → 网易 → 酷我 → 酷狗）
enum SearchAdapters {
    static let all: [SearchAdapter] = [
        QQSearchAdapter(),
        NeteaseSearchAdapter(),
        KuwoSearchAdapter(),
        KugouSearchAdapter(),
    ]

    static var platforms: [MusicPlatform] { all.map(\.platform) }
}


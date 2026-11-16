import Foundation

// MARK: - 搜索适配器协议
protocol SearchAdapter: Sendable {
    var platform: MusicPlatform { get }
    func search(keyword: String, limit: Int) async throws -> [Song]
}

// MARK: - QQ 音乐
// https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=20&w=关键词&format=json
struct QQSearchAdapter: SearchAdapter {
    let platform: MusicPlatform = .qq

    func search(keyword: String, limit: Int) async throws -> [Song] {
        let url = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
            + "?p=1&n=\(limit)&w=\(APIClient.encode(keyword))&format=json"
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
            songs.append(Song(platform: .qq, platformID: mid, name: name, singer: singers,
                              album: album, duration: Double(dur), picURL: pic))
        }
        return songs
    }
}

// MARK: - 网易云音乐
// 2026-10-31 实测：老接口 /api/search/get/web 已被风控（code=405），改用 /api/search/get
// 2026-11-16 复测：/api/search/get 正常返回 20 条
struct NeteaseSearchAdapter: SearchAdapter {
    let platform: MusicPlatform = .netease

    func search(keyword: String, limit: Int) async throws -> [Song] {
        let url = "https://music.163.com/api/search/get"
            + "?s=\(APIClient.encode(keyword))&type=1&offset=0&limit=\(limit)"
        let json = try await APIClient.shared.getJSON(url, headers: ["Referer": "https://music.163.com/"])
        if (json["code"] as? Int) != 200 { return [] }
        guard let list = json.nested(["result", "songs"]) as? [[String: Any]] else {
            throw APIError.parse("网易搜索结果结构异常")
        }
        var songs: [Song] = []
        for item in list {
            guard let id = item["id"] as? Int, id > 0,
                  let name = item["name"] as? String, !name.isEmpty else { continue }
            let artists = (item["artists"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .joined(separator: "/")
            let album = (item["album"] as? [String: Any])?["name"] as? String ?? ""
            let durMs = (item["duration"] as? Int) ?? 0
            songs.append(Song(platform: .netease, platformID: String(id), name: name,
                              singer: artists, album: album,
                              duration: Double(durMs / 1000), picURL: nil))
        }
        return await Self.fillCovers(songs)
    }

    /// v2.1.94：/api/search/get 只回 picId 不回 picUrl，用 /api/song/detail 批量补（20 首一次）
    private static func fillCovers(_ songs: [Song]) async -> [Song] {
        guard !songs.isEmpty else { return songs }
        let ids = songs.prefix(20).map(\.platformID).joined(separator: ",")
        let url = "https://music.163.com/api/song/detail?ids=[\(ids)]"
        guard let json = try? await APIClient.shared.getJSON(
            url, headers: ["Referer": "https://music.163.com/"]),
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
            return Song(platform: s.platform, platformID: s.platformID, name: s.name,
                        singer: s.singer, album: s.album, duration: s.duration, picURL: p)
        }
    }
}

// MARK: - 酷我音乐
// 必须带老客户端参数 vipver=MUSIC_8.7.8.0_WX：不带时对歌手查询返回集为 UGC 翻唱/节目/DJ
// 返回的是 Python 风格单引号文本，解析与相关性过滤都在 KuwoParser 里（有单测）
struct KuwoSearchAdapter: SearchAdapter {
    let platform: MusicPlatform = .kuwo

    func search(keyword: String, limit: Int) async throws -> [Song] {
        let rn = min(limit, 50)
        let url = "https://search.kuwo.cn/r.s"
            + "?all=\(APIClient.encode(keyword))&ft=music&rn=\(rn)&pn=1"
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
            let song = Song(platform: .kuwo, platformID: rid, name: name, singer: artist,
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

    func search(keyword: String, limit: Int) async throws -> [Song] {
        let url = "https://mobiles.kugou.com/api/v3/search/song"
            + "?format=json&keyword=\(APIClient.encode(keyword))&page=1&pagesize=\(limit)&showtype=1"
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
            songs.append(Song(platform: .kugou, platformID: hash, name: name, singer: singer,
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

import Foundation

// MARK: - 专辑曲目服务（2026-11-26）
//
// 新碟点进去要看到**这张专辑的全部曲目**。实测（2026-11-26）：
//   · 网易 `/api/v1/album/{id}` **匿名可用**（`/api/album/{id}` 是 -462 要 cookie）；
//   · 酷我 `wapi/api/www/album/albumInfo?albumId=` 匿名可用；
//   · QQ `musicu` 的 `GetAlbumSongList` 匿名可用；
//   · 酷狗那条字段名对不上（曲目名是 null），先不用。
//
// 解析全是纯函数；搜索兜底（`partial = true`）只在三条腿全空时用，
// 页面上要标「曲目可能不全」——绝不把搜索结果冒充成完整专辑。

struct AlbumTracks: Sendable, Equatable {
    let albumID: String
    let name: String
    let artist: String
    let cover: String?
    let publishDate: String?
    let songs: [Song]
    /// true = 这份曲目是"搜出来的"，可能不全（页面要标）
    let partial: Bool
}

enum AlbumService {

    private static let timeout: TimeInterval = 10

    /// 按专辑 id 拿曲目：平台对应接口 → 全空才走搜索兜底
    static func tracks(albumID: String, platform: MusicPlatform,
                       name: String = "", artist: String = "") async -> AlbumTracks? {
        switch platform {
        case .netease:
            if let t = await netease(albumID: albumID) { return t }
        case .kuwo:
            if let t = await kuwo(albumID: albumID) { return t }
        case .qq:
            if let t = await qq(albumID: albumID) { return t }
        default:
            break
        }
        // 只对"有名字"的调用方做搜索兜底（新碟卡片一定带名字）
        guard !name.isEmpty else { return nil }
        let keyword = "\(name) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        let results = await SearchService.shared.searchAll(keyword: keyword, limit: 30)
        let songs = results.flatMap { $0.songs }
        guard !songs.isEmpty else { return nil }
        return partialFromSearch(songs, albumID: albumID, name: name, artist: artist)
    }

    // MARK: 各家网络

    private static func netease(albumID: String) async -> AlbumTracks? {
        guard let json = try? await APIClient.shared.getJSON(
            "https://music.163.com/api/v1/album/\(albumID)",
            headers: ["Referer": "https://music.163.com/"], timeout: timeout) else { return nil }
        return parseNeteaseV1(json, albumID: albumID)
    }

    private static func kuwo(albumID: String) async -> AlbumTracks? {
        guard let json = try? await APIClient.shared.getJSON(
            "https://wapi.kuwo.cn/api/www/album/albumInfo?albumId=\(albumID)&pn=1&rn=100&httpsStatus=1",
            headers: ["Referer": "https://www.kuwo.cn/"], timeout: timeout) else { return nil }
        return parseKuwo(json, albumID: albumID)
    }

    private static func qq(albumID: String) async -> AlbumTracks? {
        let body: [String: Any] = [
            "comm": ["ct": 24, "cv": 0],
            "req_1": ["module": "music.musichallAlbum.AlbumSongList",
                      "method": "GetAlbumSongList",
                      "param": ["albumMid": albumID, "begin": 0, "num": 100, "order": 2]],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let bodyStr = String(data: bodyData, encoding: .utf8),
              let json = try? await APIClient.shared.postJSON(
                "https://u.y.qq.com/cgi-bin/musicu.fcg", body: bodyStr,
                headers: ["Referer": "https://y.qq.com/"], timeout: timeout) else { return nil }
        return parseQQ(json, albumID: albumID)
    }

    // MARK: 解析（纯函数）

    static func parseNeteaseV1(_ json: [String: Any], albumID: String) -> AlbumTracks? {
        let album = json["album"] as? [String: Any] ?? [:]
        let raw = (album["songs"] as? [[String: Any]])
            ?? (json["songs"] as? [[String: Any]]) ?? []
        let songs: [Song] = raw.compactMap { item in
            guard let id = item["id"] as? Int, id > 0,
                  let name = item["name"] as? String, !name.isEmpty else { return nil }
            let artists = ((item["ar"] as? [[String: Any]]) ?? (item["artists"] as? [[String: Any]]) ?? [])
                .compactMap { $0["name"] as? String }.joined(separator: "/")
            let al = item["al"] as? [String: Any] ?? item["album"] as? [String: Any] ?? [:]
            let pic = (al["picUrl"] as? String) ?? ""
            let ms = (item["dt"] as? Int) ?? (item["duration"] as? Int) ?? 0
            return Song.make(platform: .netease, platformID: String(id), name: name,
                             singer: artists, album: (al["name"] as? String) ?? "",
                             duration: Double(ms / 1000),
                             picURL: pic.isEmpty ? nil : pic)
        }
        guard !songs.isEmpty else { return nil }
        let cover = (album["picUrl"] as? String) ?? songs.first?.picURL
        let publish = (album["publishTime"] as? Int).map { Self.dateString($0) }
        return AlbumTracks(albumID: albumID,
                           name: (album["name"] as? String) ?? "",
                           artist: ((album["artist"] as? [String: Any])?["name"] as? String)
                               ?? ((album["artists"] as? [[String: Any]]) ?? [])
                                   .compactMap { $0["name"] as? String }.joined(separator: "/"),
                           cover: cover, publishDate: publish, songs: songs, partial: false)
    }

    static func parseKuwo(_ json: [String: Any], albumID: String) -> AlbumTracks? {
        let data = json["data"] as? [String: Any] ?? [:]
        let raw = (data["musicList"] as? [[String: Any]])
            ?? (data["songs"] as? [[String: Any]]) ?? []
        let songs: [Song] = raw.compactMap { item in
            let rid = (item["rid"] as? String) ?? String(describing: item["rid"] ?? "")
            guard !rid.isEmpty, rid != "nil",
                  let name = item["name"] as? String, !name.isEmpty else { return nil }
            let artist = (item["artist"] as? String) ?? ""
            let album = (item["album"] as? String) ?? ""
            let pic = (item["pic"] as? String) ?? ""
            let dur = Self.seconds(item["duration"])
            return Song.make(platform: .kuwo, platformID: rid, name: name, singer: artist,
                             album: album, duration: dur,
                             picURL: pic.isEmpty ? nil : pic)
        }
        guard !songs.isEmpty else { return nil }
        let cover = (data["img"] as? String) ?? (data["pic"] as? String)
        return AlbumTracks(albumID: albumID,
                           name: (data["name"] as? String) ?? (data["album"] as? String) ?? "",
                           artist: (data["artist"] as? String) ?? "",
                           cover: cover, publishDate: data["publishTime"] as? String,
                           songs: songs, partial: false)
    }

    static func parseQQ(_ json: [String: Any], albumID: String) -> AlbumTracks? {
        let req = json["req_1"] as? [String: Any] ?? [:]
        let data = req["data"] as? [String: Any] ?? [:]
        let raw = data["songList"] as? [[String: Any]] ?? []
        let songs: [Song] = raw.compactMap { item in
            let info = item["songInfo"] as? [String: Any] ?? item
            guard let mid = info["mid"] as? String, !mid.isEmpty,
                  let name = info["name"] as? String ?? info["title"] as? String,
                  !name.isEmpty else { return nil }
            let singers = ((info["singer"] as? [[String: Any]]) ?? [])
                .compactMap { $0["name"] as? String }.joined(separator: "/")
            let albumDict = info["album"] as? [String: Any] ?? [:]
            let mid2 = (albumDict["mid"] as? String) ?? ""
            let interval = (info["interval"] as? Int) ?? 0
            return Song.make(platform: .qq, platformID: mid, name: name, singer: singers,
                             album: (albumDict["name"] as? String) ?? "",
                             duration: Double(interval),
                             picURL: mid2.isEmpty ? nil
                                 : "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(mid2).jpg")
        }
        guard !songs.isEmpty else { return nil }
        return AlbumTracks(albumID: albumID, name: "", artist: "",
                           cover: songs.first?.picURL, publishDate: nil,
                           songs: songs, partial: false)
    }

    /// 搜索兜底：只保留"专辑名对得上"的歌，并标 `partial = true`
    static func partialFromSearch(_ songs: [Song], albumID: String,
                                  name: String, artist: String) -> AlbumTracks? {
        let albumKey = NameMatch.normTitle(name)
        let kept = songs.filter { song in
            let s = NameMatch.normTitle(song.album)
            guard !s.isEmpty, !albumKey.isEmpty else { return false }
            return s == albumKey || s.contains(albumKey) || albumKey.contains(s)
        }
        guard !kept.isEmpty else { return nil }
        return AlbumTracks(albumID: albumID, name: name, artist: artist,
                           cover: kept.first?.picURL, publishDate: nil,
                           songs: kept, partial: true)
    }

    // MARK: 小工具

    private static func seconds(_ any: Any?) -> Double {
        if let d = any as? Double { return d > 1000 ? d / 1000 : d }
        if let i = any as? Int { return i > 1000 ? Double(i) / 1000 : Double(i) }
        if let s = any as? String, let v = Double(s) { return v > 1000 ? v / 1000 : v }
        return 0
    }

    private static func dateString(_ millis: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }
}

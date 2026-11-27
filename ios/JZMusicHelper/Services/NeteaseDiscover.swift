import Foundation

// MARK: - 网易发现数据源（2026-11-26）
//
// 发现页 2.0 的第二条腿。全部匿名、不需要登录。
// 实测（2026-11-26）：
//   · `api/toplist` 65 个榜（id/name/trackCount/updateFrequency/coverImgUrl）
//   · `api/playlist/detail?id=` 100 首（tracks[]）
//   · `api/homepage/block/page` 15 块：BANNER（extInfo.banners）、
//     NEW_ALBUM_NEW_SONG / PLAYLIST_RCMD（creatives[].resources[]）
//   · `api/playlist/list` 680 个歌单
//
// 解析全部是纯函数（CI 里喂 fixture 断言），网络只在 `fetch*` 里。

struct NeteaseChartBrief: Sendable, Equatable {
    let id: String
    let name: String
    let updateFrequency: String
    let cover: String?
    let trackCount: Int
}

/// BANNER 一条：图片 + 文案 + 站内落点（歌单 id）。
/// `Codable` 是为了按天缓存——首页块响应不小，当天不该反复拉。
struct NeteaseBannerItem: Sendable, Equatable, Codable {
    let image: String
    let title: String
    /// 只保留能站内跳转的（歌单 id）；外链 banner 直接过滤掉
    let playlistID: String?
}

/// 歌单摘要（广场第二条腿展示用）。`Codable` 是为了按天缓存。
struct NeteasePlaylistBrief: Sendable, Equatable, Codable {
    let id: String
    let name: String
    let cover: String?
    let trackCount: Int
}

/// 一页曲目（榜单或歌单）：歌单页要显示的名字/封面 + 可播放的歌曲
struct NeteaseTrackPage: Sendable, Equatable {
    let name: String
    let cover: String?
    let songs: [Song]
}

enum NeteaseDiscover {

    private static let headers = ["Referer": "https://music.163.com/"]
    private static let timeout: TimeInterval = 8

    // MARK: 网络

    static func charts() async -> [NeteaseChartBrief] {
        guard let json = try? await APIClient.shared.getJSON(
            "https://music.163.com/api/toplist", headers: headers, timeout: timeout) else { return [] }
        return parseChartList(json)
    }

    // 2026-11-27 实测更正：`api/playlist/detail?id=`（v1）对榜单/歌单**都回 0 首**
    // （`playlist` 为空、`tracks` 缺失）。能用的是 `api/v3/playlist/detail?id=&n=`：
    // 返回 `playlist.name` / `coverImgUrl` / `tracks[]`，但曲目字段是短名——
    // `dt`（毫秒）/ `ar`（歌手）/ `al`（专辑），和 v1 的 `duration`/`artists`/`album` 不同。
    // 所以解析要两种形状都吃（`song(fromTrack:)` 做了回退），端点按 v3 → v1 兜底。
    static func trackPage(id: String, limit: Int = 100) async -> NeteaseTrackPage? {
        let v3 = "https://music.163.com/api/v3/playlist/detail?id=\(id)&n=\(limit)"
        if let json = try? await APIClient.shared.getJSON(v3, headers: headers, timeout: timeout),
           let page = parseTrackPage(json), !page.songs.isEmpty {
            return page
        }
        let v1 = "https://music.163.com/api/playlist/detail?id=\(id)"
        if let json = try? await APIClient.shared.getJSON(v1, headers: headers, timeout: timeout),
           let page = parseTrackPage(json), !page.songs.isEmpty {
            return page
        }
        return nil
    }

    static func chartSongs(id: String, limit: Int = 100) async -> [Song] {
        await trackPage(id: id, limit: limit)?.songs ?? []
    }

    /// 通用歌单页（BANNER 点击的落点、广场卡片、榜单页共用同一条路径）
    static func playlistDetail(id: String, limit: Int = 100) async -> NeteaseTrackPage? {
        await trackPage(id: id, limit: limit)
    }

    static func banners() async -> [NeteaseBannerItem] {
        guard let json = try? await homePage() else { return [] }
        return parseBanners(json)
    }

    static func playlists(limit: Int = 30) async -> [NeteasePlaylistBrief] {
        guard let json = try? await APIClient.shared.getJSON(
            "https://music.163.com/api/playlist/list?cat=%E5%85%A8%E9%83%A8&limit=\(limit)&offset=0",
            headers: headers, timeout: timeout) else { return [] }
        return parsePlaylists(json)
    }

    private static func homePage() async throws -> [String: Any] {
        try await APIClient.shared.getJSON(
            "https://music.163.com/api/homepage/block/page?refresh=false&cursor=&pageType=0",
            headers: headers, timeout: 10)
    }

    // MARK: 解析（纯函数）

    static func parseChartList(_ json: [String: Any]) -> [NeteaseChartBrief] {
        let list = json["list"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = intValue(item["id"]), id > 0,
                  let name = item["name"] as? String, !name.isEmpty else { return nil }
            let cover = (item["coverImgUrl"] as? String) ?? ""
            return NeteaseChartBrief(
                id: String(id), name: name,
                updateFrequency: (item["updateFrequency"] as? String) ?? "",
                cover: cover.isEmpty ? nil : cover,
                trackCount: intValue(item["trackCount"]) ?? 0)
        }
    }

    static func parseChartSongs(_ json: [String: Any]) -> [Song] {
        let playlist = (json["playlist"] as? [String: Any])
            ?? (json["result"] as? [String: Any]) ?? [:]
        let tracks = playlist["tracks"] as? [[String: Any]] ?? []
        // 2026-11-27（老板）：榜单/歌单里也不许出现上传者的变速/剪辑条目
        return JunkAudioRules.filter(tracks.compactMap(song(fromTrack:)))
    }

    /// 歌单/榜单详情页：名字 + 封面 + 曲目（v3 与 v1 同路径 `playlist.{name,coverImgUrl,tracks}`）
    static func parseTrackPage(_ json: [String: Any], limit: Int = 100) -> NeteaseTrackPage? {
        let playlist = (json["playlist"] as? [String: Any])
            ?? (json["result"] as? [String: Any]) ?? [:]
        guard !playlist.isEmpty else { return nil }
        let songs = Array(parseChartSongs(json).prefix(limit))
        let name = (playlist["name"] as? String) ?? ""
        let cover = (playlist["coverImgUrl"] as? String) ?? ""
        return NeteaseTrackPage(name: name,
                                cover: cover.isEmpty ? nil : cover,
                                songs: songs)
    }

    /// banner：只留 targetType == 1000（歌单，站内可跳）；3000（演出/外链）过滤掉
    static func parseBanners(_ json: [String: Any]) -> [NeteaseBannerItem] {
        var out: [NeteaseBannerItem] = []
        for block in blocks(json) where block["blockCode"] as? String == "HOMEPAGE_BANNER" {
            let ext = block["extInfo"] as? [String: Any] ?? [:]
            for banner in (ext["banners"] as? [[String: Any]]) ?? [] {
                guard let pic = banner["pic"] as? String, !pic.isEmpty else { continue }
                let targetType = intValue(banner["targetType"]) ?? -1
                let targetID = intValue(banner["targetId"]).map(String.init)
                    ?? (banner["targetId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ""
                let title = (banner["typeTitle"] as? String)
                    ?? (banner["mainTitle"] as? String) ?? ""
                let playlistID = (targetType == 1000 && !targetID.isEmpty) ? targetID : nil
                out.append(NeteaseBannerItem(image: pic, title: title, playlistID: playlistID))
            }
        }
        return out
    }

    static func parsePlaylists(_ json: [String: Any]) -> [NeteasePlaylistBrief] {
        let list = json["playlists"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = intValue(item["id"]), id > 0,
                  let name = item["name"] as? String, !name.isEmpty else { return nil }
            let cover = (item["coverImgUrl"] as? String) ?? ""
            return NeteasePlaylistBrief(id: String(id), name: name,
                                        cover: cover.isEmpty ? nil : cover,
                                        trackCount: intValue(item["trackCount"]) ?? 0)
        }
    }

    // MARK: 小工具

    private static func blocks(_ json: [String: Any]) -> [[String: Any]] {
        ((json["data"] as? [String: Any])?["blocks"] as? [[String: Any]]) ?? []
    }

    /// 曲目 → Song。**两种形状都吃**：
    /// v1 `duration`/`artists`/`album`，v3 `dt`/`ar`/`al`（2026-11-27 实测，v3 是现在唯一有曲目的端点）。
    private static func song(fromTrack item: [String: Any]) -> Song? {
        guard let id = intValue(item["id"]), id > 0,
              let name = item["name"] as? String, !name.isEmpty else { return nil }
        let artistList = (item["artists"] as? [[String: Any]])
            ?? (item["ar"] as? [[String: Any]]) ?? []
        let artists = artistList.compactMap { $0["name"] as? String }.joined(separator: "/")
        let albumDict = (item["album"] as? [String: Any])
            ?? (item["al"] as? [String: Any]) ?? [:]
        let album = (albumDict["name"] as? String) ?? ""
        let pic = (albumDict["picUrl"] as? String) ?? ""
        let ms = intValue(item["duration"]) ?? intValue(item["dt"]) ?? 0
        return Song.make(platform: .netease, platformID: String(id), name: name,
                         singer: artists, album: album,
                         duration: Double(ms / 1000),
                         picURL: pic.isEmpty ? nil : pic)
    }

    /// 同一字段在不同接口里可能是 Int / NSNumber / String，统一收口
    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

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

struct NeteaseBannerItem: Sendable, Equatable {
    let image: String
    let title: String
    /// 只保留能站内跳转的（歌单 id）；外链 banner 直接过滤掉
    let playlistID: String?
}

struct NeteasePlaylistBrief: Sendable, Equatable {
    let id: String
    let name: String
    let cover: String?
    let trackCount: Int
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

    static func chartSongs(id: String, limit: Int = 100) async -> [Song] {
        guard let json = try? await APIClient.shared.getJSON(
            "https://music.163.com/api/playlist/detail?id=\(id)",
            headers: headers, timeout: timeout) else { return [] }
        return Array(parseChartSongs(json).prefix(limit))
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
            guard let id = item["id"] as? Int, id > 0,
                  let name = item["name"] as? String, !name.isEmpty else { return nil }
            let cover = (item["coverImgUrl"] as? String) ?? ""
            return NeteaseChartBrief(
                id: String(id), name: name,
                updateFrequency: (item["updateFrequency"] as? String) ?? "",
                cover: cover.isEmpty ? nil : cover,
                trackCount: (item["trackCount"] as? Int) ?? (item["trackCount"] as? NSNumber)?.intValue ?? 0)
        }
    }

    static func parseChartSongs(_ json: [String: Any]) -> [Song] {
        let playlist = (json["playlist"] as? [String: Any])
            ?? (json["result"] as? [String: Any]) ?? [:]
        let tracks = playlist["tracks"] as? [[String: Any]] ?? []
        return tracks.compactMap(song(fromTrack:))
    }

    /// banner：只留 targetType == 1000（歌单，站内可跳）；3000（演出/外链）过滤掉
    static func parseBanners(_ json: [String: Any]) -> [NeteaseBannerItem] {
        var out: [NeteaseBannerItem] = []
        for block in blocks(json) where block["blockCode"] as? String == "HOMEPAGE_BANNER" {
            let ext = block["extInfo"] as? [String: Any] ?? [:]
            for banner in (ext["banners"] as? [[String: Any]]) ?? [] {
                guard let pic = banner["pic"] as? String, !pic.isEmpty else { continue }
                let targetType = (banner["targetType"] as? Int) ?? -1
                let targetID = String(describing: banner["targetId"] ?? "")
                let title = (banner["typeTitle"] as? String)
                    ?? (banner["mainTitle"] as? String) ?? ""
                let playlistID = (targetType == 1000 && targetID != "nil" && !targetID.isEmpty)
                    ? targetID : nil
                out.append(NeteaseBannerItem(image: pic, title: title, playlistID: playlistID))
            }
        }
        return out
    }

    static func parsePlaylists(_ json: [String: Any]) -> [NeteasePlaylistBrief] {
        let list = json["playlists"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? Int, id > 0,
                  let name = item["name"] as? String, !name.isEmpty else { return nil }
            let cover = (item["coverImgUrl"] as? String) ?? ""
            return NeteasePlaylistBrief(id: String(id), name: name,
                                        cover: cover.isEmpty ? nil : cover,
                                        trackCount: (item["trackCount"] as? Int) ?? 0)
        }
    }

    // MARK: 小工具

    private static func blocks(_ json: [String: Any]) -> [[String: Any]] {
        ((json["data"] as? [String: Any])?["blocks"] as? [[String: Any]]) ?? []
    }

    private static func song(fromTrack item: [String: Any]) -> Song? {
        guard let id = item["id"] as? Int, id > 0,
              let name = item["name"] as? String, !name.isEmpty else { return nil }
        let artists = ((item["artists"] as? [[String: Any]]) ?? [])
            .compactMap { $0["name"] as? String }.joined(separator: "/")
        let albumDict = item["album"] as? [String: Any] ?? [:]
        let album = (albumDict["name"] as? String) ?? ""
        let pic = (albumDict["picUrl"] as? String) ?? ""
        let ms = (item["duration"] as? Int) ?? 0
        return Song.make(platform: .netease, platformID: String(id), name: name,
                         singer: artists, album: album,
                         duration: Double(ms / 1000),
                         picURL: pic.isEmpty ? nil : pic)
    }
}

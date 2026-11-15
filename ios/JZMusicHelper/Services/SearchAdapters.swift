import Foundation

// MARK: - 搜索适配器协议
/// 每个平台一个搜索适配器：输入关键词，返回该平台的歌曲列表。
protocol SearchAdapter {
    var platform: MusicPlatform { get }
    func search(keyword: String, limit: Int) async throws -> [Song]
}

// MARK: - QQ 音乐搜索
/// https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=10&w=关键词&format=json
final class QQSearchAdapter: SearchAdapter {
    let platform: MusicPlatform = .qq

    func search(keyword: String, limit: Int) async throws -> [Song] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=\(limit)&w=\(encoded)&format=json"
        let json = try await APIClient.shared.getJSON(url, headers: [
            "Referer": "https://y.qq.com/",
            "Accept": "application/json, text/javascript, */*; q=0.01"
        ])
        guard let list = json.nested(["data", "song", "list"]) as? [[String: Any]] else {
            throw APIError.parse("QQ 搜索结果结构异常")
        }
        var songs: [Song] = []
        for item in list {
            guard let songname = item["songname"] as? String,
                  let songmid = item["songmid"] as? String else { continue }
            let singers = (item["singer"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let album = (item["albumname"] as? String) ?? ""
            let dur = (item["interval"] as? Int).map(Double.init) ?? 0
            var pic: String? = nil
            if let picStr = item["albummid"] as? String, !picStr.isEmpty {
                pic = "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(picStr).jpg"
            }
            songs.append(Song(platform: .qq, platformID: songmid, name: songname,
                              singer: singers.joined(separator: "/"), album: album,
                              duration: dur, picURL: pic))
        }
        return songs
    }
}

// MARK: - 网易云音乐搜索
/// https://music.163.com/api/search/get/web?csrf_token=&s=关键词&type=1&offset=0&limit=10
final class NeteaseSearchAdapter: SearchAdapter {
    let platform: MusicPlatform = .netease

    func search(keyword: String, limit: Int) async throws -> [Song] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "https://music.163.com/api/search/get/web?csrf_token=&s=\(encoded)&type=1&offset=0&limit=\(limit)"
        let json = try await APIClient.shared.getJSON(url, headers: [
            "Referer": "https://music.163.com/",
            "Accept": "application/json, text/javascript, */*; q=0.01"
        ])
        guard let code = json["code"] as? Int, code == 200,
              let songsList = json.nested(["result", "songs"]) as? [[String: Any]] else {
            throw APIError.parse("网易云搜索结果结构异常")
        }
        var songs: [Song] = []
        for item in songsList {
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { continue }
            let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let album = (item.nested(["album", "name"]) as? String) ?? ""
            let dur = (item["duration"] as? Int).map { Double($0) / 1000.0 } ?? 0
            var pic: String? = nil
            if let picStr = item.nested(["album", "picUrl"]) as? String { pic = picStr }
            songs.append(Song(platform: .netease, platformID: "\(id)", name: name,
                              singer: artists.joined(separator: "/"), album: album,
                              duration: dur, picURL: pic))
        }
        return songs
    }
}

// MARK: - 酷我音乐搜索
/// https://search.kuwo.cn/r.s?all=关键词&ft=music&rn=10&pn=1&rformat=json&encoding=utf8
/// 返回 Python 风格单引号键值文本（非标准 JSON），需做兼容解析。
final class KuwoSearchAdapter: SearchAdapter {
    let platform: MusicPlatform = .kuwo

    func search(keyword: String, limit: Int) async throws -> [Song] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "https://search.kuwo.cn/r.s?all=\(encoded)&ft=music&rn=\(limit)&pn=1&rformat=json&encoding=utf8"
        let data = try await APIClient.shared.getData(url, headers: [
            "Referer": "https://www.kuwo.cn/",
            "Accept": "*/*"
        ], allowTextPlain: true)
        let text = String(data: data, encoding: .utf8) ?? ""
        let list = Self.extractAbsList(from: text)
        var songs: [Song] = []
        for item in list {
            guard let name = item["SONGNAME"] as? String else { continue }
            let rawRid = (item["MUSICRID"] as? String) ?? ""
            // MUSIC_51685512 -> 51685512
            let rid = rawRid.replacingOccurrences(of: "MUSIC_", with: "")
            guard !rid.isEmpty else { continue }
            let artist = (item["ARTIST"] as? String) ?? ""
            let album = (item["ALBUM"] as? String) ?? ""
            let dur = Self.parseDuration(item["DURATION"] as? String)
            songs.append(Song(platform: .kuwo, platformID: rid, name: Self.cleanName(name),
                              singer: artist, album: album, duration: dur, picURL: nil))
        }
        return songs
    }

    // MARK: 酷我特殊解析

    /// 酷我旧搜索返回形如 `{'key':'value','abslist':[...]}` 的文本，
    /// 逐条抽取 abslist 中每条记录的字段。
    static func extractAbsList(from text: String) -> [[String: Any]] {
        guard let range = text.range(of: "'abslist'") else { return [] }
        let rest = text[range.lowerBound...]
        guard let open = rest.firstIndex(of: "["), let close = rest.lastIndex(of: "]") else { return [] }
        let listText = String(rest[open...close])
        // 按顶层逗号切分每条记录
        let chunks = splitTopLevel(listText)
        var result: [[String: Any]] = []
        for chunk in chunks {
            if let dict = parseSingleQuotedDict(chunk) {
                result.append(dict)
            }
        }
        return result
    }

    /// 把 `[...]` 的内容按顶层逗号切分成记录文本。
    static func splitTopLevel(_ s: String) -> [String] {
        let inner = String(s.dropFirst().dropLast())
        var depth = 0
        var current = ""
        var chunks: [String] = []
        for ch in inner {
            if ch == "[" || ch == "{" { depth += 1 }
            if ch == "]" || ch == "}" { depth -= 1 }
            if ch == "," && depth == 0 {
                chunks.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// 解析单引号包裹的 Python 风格 dict 文本为 [String: Any]。
    static func parseSingleQuotedDict(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        var result: [String: Any] = [:]
        // 匹配 'key':'value' 或 'key':'val with \' escapes'
        let pattern = #"'([^']*)':\s*'((?:[^'\\]|\\.)*)'"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = inner as NSString
        for match in regex.matches(in: inner, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1))
            var value = ns.substring(with: match.range(at: 2))
            value = value.replacingOccurrences(of: #"\'"#, with: "'")
            result[key] = value
        }
        return result.isEmpty ? nil : result
    }

    static func cleanName(_ name: String) -> String {
        // 去除 HTML 实体
        var n = name.replacingOccurrences(of: "&nbsp;", with: " ")
        n = n.replacingOccurrences(of: "&amp;", with: "&")
        return n.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseDuration(_ s: String?) -> TimeInterval {
        guard let s = s, !s.isEmpty else { return 0 }
        // "04:30" 或 "04:30:10"
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3 else { return 0 }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

// MARK: - 酷狗音乐搜索
/// https://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=关键词&page=1&pagesize=10&showtype=1
/// 注意该域名证书与主机名不匹配，App 需依赖 ATS 例外（已在 Info.plist 开启任意加载），
/// URLSession 默认校验证书，若真机仍失败可改用 m.kugou.com 或 http。
final class KugouSearchAdapter: SearchAdapter {
    let platform: MusicPlatform = .kugou

    func search(keyword: String, limit: Int) async throws -> [Song] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = "https://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=\(encoded)&page=1&pagesize=\(limit)&showtype=1"
        let json = try await APIClient.shared.getJSON(url, headers: [
            "Referer": "https://www.kugou.com/",
            "Accept": "application/json, text/javascript, */*; q=0.01"
        ])
        guard let list = json.nested(["data", "info"]) as? [[String: Any]] else {
            throw APIError.parse("酷狗搜索结果结构异常")
        }
        var songs: [Song] = []
        for item in list {
            guard let songname = item["songname"] as? String,
                  let hash = item["hash"] as? String else { continue }
            let singer = (item["singername"] as? String) ?? ""
            let album = (item["album_name"] as? String) ?? ""
            let dur = (item["duration"] as? Int).map(Double.init) ?? 0
            var pic: String? = nil
            if let albumID = item["album_id"] as? Int {
                pic = "https://imgessl.kugou.com/stdmusic/\(albumID)/500.jpg"
            }
            songs.append(Song(platform: .kugou, platformID: hash, name: songname,
                              singer: singer, album: album, duration: dur, picURL: pic))
        }
        return songs
    }
}

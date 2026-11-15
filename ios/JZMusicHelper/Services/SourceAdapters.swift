import Foundation

// MARK: - 取流后端协议
/// 每个后端一个解析器：给定歌曲与音质，返回可用的流地址（下载/播放 URL）。
/// resolve 内部应尽量轻量校验（如 Range GET 检查返回音频而非 HTML 落地页）。
protocol StreamSourceAdapter {
    var name: String { get }
    var platform: MusicPlatform { get }
    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource
}

// MARK: - 轻量校验工具
/// 对候选 URL 做 Range GET：仅当返回 200/206 且 Content-Type 非 HTML 时视为可用。
enum StreamVerifier {
    static func isAudioURL(_ urlString: String, timeout: TimeInterval = 8) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            guard (200..<400).contains(http.statusCode) else { return false }
            let ct = (http.allHeaderFields["Content-Type"] as? String) ?? ""
            if ct.lowercased().contains("text/html") { return false }
            // 空类型但字节流（audio/octet-stream、application/octet-stream）视为音频
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 酷我系后端

/// haitangw 酷我直链：https://musicapi.haitangw.net/music/kw.php?type=mp3&id={rid}&level={level}
final class HaitangKuwoAdapter: StreamSourceAdapter {
    let name = "haitangw 酷我"
    let platform: MusicPlatform = .kuwo

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let level: String
        var format = "mp3"
        switch quality {
        case .standard: level = "standard"
        case .high: level = "exhigh"
        case .lossless: level = "lossless"; format = "flac"
        }
        let url = "https://musicapi.haitangw.net/music/kw.php?type=mp3&id=\(song.platformID)&level=\(level)"
        guard await StreamVerifier.isAudioURL(url) else {
            throw APIError.httpStatus(0)
        }
        return StreamSource(url: url, backendName: name, platform: platform, quality: quality, format: format, note: "320k MP3 全量")
    }
}

/// nxinxz 酷我直链：http://music.nxinxz.com/kw.php?id={rid}&level={level}&type=mp3
final class NxinxzKuwoAdapter: StreamSourceAdapter {
    let name = "nxinxz 酷我"
    let platform: MusicPlatform = .kuwo

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let level: String
        var format = "mp3"
        switch quality {
        case .standard: level = "standard"
        case .high: level = "exhigh"
        case .lossless: level = "lossless"; format = "flac"
        }
        let url = "https://music.nxinxz.com/kw.php?id=\(song.platformID)&level=\(level)&type=mp3"
        guard await StreamVerifier.isAudioURL(url) else {
            throw APIError.httpStatus(0)
        }
        return StreamSource(url: url, backendName: name, platform: platform, quality: quality, format: format, note: "320k MP3 全量")
    }
}

/// oiapi Kuwo（搜索式）：https://oiapi.net/api/Kuwo?msg={keyword}&n=1&br={7|5|1} → data.url
final class OiapiKuwoAdapter: StreamSourceAdapter {
    let name = "oiapi 酷我"
    let platform: MusicPlatform = .kuwo

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let br: String
        var format = "mp3"
        switch quality {
        case .standard: br = "7"
        case .high: br = "5"
        case .lossless: br = "1"; format = "flac"
        }
        let keyword = song.searchKeyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? song.name
        let url = "https://oiapi.net/api/Kuwo?msg=\(keyword)&n=1&br=\(br)"
        let json = try await APIClient.shared.getJSON(url, timeout: 10)
        guard let data = json["data"] as? [String: Any],
              let stream = (data["url"] as? String) ?? (json["url"] as? String), !stream.isEmpty else {
            throw APIError.parse("oiapi 酷我未返回 URL")
        }
        guard await StreamVerifier.isAudioURL(stream) else {
            throw APIError.httpStatus(0)
        }
        return StreamSource(url: stream, backendName: name, platform: platform, quality: quality, format: format, note: "搜索式取流")
    }
}

/// KuwoDES 官方签名链：mobi.kuwo.cn convert_url_with_sign（实测 320k 完整 10,797,030B）
final class KuwoDESAdapter: StreamSourceAdapter {
    let name = "KuwoDES 官方"
    let platform: MusicPlatform = .kuwo

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let br: String
        let format: String
        switch quality {
        case .standard: br = "128kmp3"; format = "mp3"
        case .high: br = "320kmp3"; format = "mp3"
        case .lossless: br = "2000kflac"; format = "flac"
        }
        let url = "https://mobi.kuwo.cn/mobi.s?f=web&source=kwplayer_ar_8.5.5.0_apk_keluze.apk&type=convert_url_with_sign&br=\(br)&format=\(format)&sig=0&rid=\(song.platformID)&network=WIFI&user=0"
        let json = try await APIClient.shared.getJSON(url, headers: ["User-Agent": "okhttp/3.10.0"], timeout: 12)
        guard let code = json["code"] as? Int, code == 200,
              let data = json["data"] as? [String: Any],
              let stream = data["url"] as? String, !stream.isEmpty else {
            throw APIError.parse("KuwoDES 未返回 URL")
        }
        guard await StreamVerifier.isAudioURL(stream) else {
            throw APIError.httpStatus(0)
        }
        return StreamSource(url: stream, backendName: name, platform: platform, quality: quality, format: format, note: "官方签名链")
    }
}

/// zddyr 自建后端（需 X-Token）：https://yy.zddyr.top/lx/api/?source=kw&name=&singer=&songmid={rid}&quality={q}
final class ZddyrKuwoAdapter: StreamSourceAdapter {
    let name = "zddyr 酷我"
    let platform: MusicPlatform = .kuwo

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let q: String
        var format = "mp3"
        switch quality {
        case .standard: q = "128k"
        case .high: q = "320k"
        case .lossless: q = "flac"; format = "flac"
        }
        let nameEnc = song.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? song.name
        let singerEnc = song.singer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? song.singer
        let url = "https://yy.zddyr.top/lx/api/?source=kw&name=\(nameEnc)&singer=\(singerEnc)&songmid=\(song.platformID)&quality=\(q)"
        let token = Self.makeToken()
        let json = try await APIClient.shared.getJSON(url, headers: ["X-Token": token, "X-Client": "JZMusicHelper/1.0 (iOS)"], timeout: 10)
        guard let code = json["code"] as? Int, code == 200,
              let stream = json["url"] as? String, !stream.isEmpty else {
            throw APIError.parse("zddyr 未返回 URL")
        }
        guard await StreamVerifier.isAudioURL(stream) else {
            throw APIError.httpStatus(0)
        }
        return StreamSource(url: stream, backendName: name, platform: platform, quality: quality, format: format, note: "自建后端")
    }

    private static func makeToken() -> String {
        let payload: [String: Any] = [
            "device_id": "ios-" + String(format: "%06x", Int.random(in: 0...0xFFFFFF)),
            "ip": "0.0.0.0",
            "timestamp": Int(Date().timeIntervalSince1970),
            "random": String(format: "%08x", Int.random(in: 0...0xFFFFFFFF))
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return "" }
        return data.base64EncodedString()
    }
}

// MARK: - QQ 系后端

/// cyapi.top QQ 直链：https://cyapi.top/API/qq_music.php?apikey=...&type=json&mid={songmid} → url
final class CyapiQQAdapter: StreamSourceAdapter {
    let name = "cyapi QQ"
    let platform: MusicPlatform = .qq

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let url = "https://cyapi.top/API/qq_music.php?apikey=1ffdf5733f5d538760e63d7e46ba17438d9f7b9dfc18c51be1109386fd74c3a1&type=json&mid=\(song.platformID)"
        let json = try await APIClient.shared.getJSON(url, headers: ["Referer": "https://y.qq.com/"], timeout: 12)
        guard let stream = json["url"] as? String, !stream.isEmpty else {
            throw APIError.parse("cyapi 未返回 URL")
        }
        guard await StreamVerifier.isAudioURL(stream) else {
            throw APIError.httpStatus(0)
        }
        return StreamSource(url: stream, backendName: name, platform: platform, quality: quality, format: "m4a", note: "VIP 全量 m4a")
    }
}

/// a.aa.cab QQ（搜索式）：https://a.aa.cab/qq.music?msg={keyword}&n=1&type={0|1|4} → data.music
final class AacabQQAdapter: StreamSourceAdapter {
    let name = "a.aa.cab QQ"
    let platform: MusicPlatform = .qq

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let type: String
        var format = "mp3"
        switch quality {
        case .standard: type = "0"
        case .high: type = "1"
        case .lossless: type = "4"; format = "flac"
        }
        let keyword = song.searchKeyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? song.name
        let url = "https://a.aa.cab/qq.music?msg=\(keyword)&n=1&type=\(type)"
        let json = try await APIClient.shared.getJSON(url, headers: ["Referer": "https://y.qq.com/"], timeout: 12)
        guard let data = json["data"] as? [String: Any],
              let stream = (data["music"] as? String) ?? (json["url"] as? String), !stream.isEmpty else {
            throw APIError.parse("a.aa.cab 未返回 URL")
        }
        guard await StreamVerifier.isAudioURL(stream) else {
            throw APIError.httpStatus(0)
        }
        return StreamSource(url: stream, backendName: name, platform: platform, quality: quality, format: format, note: "搜索式取流")
    }
}

// MARK: - 网易云系后端

/// gdstudio 网易：music-api.gdstudio.xyz/api.php?...&types=url&source=netease&id={id}&br={128|320|740|999}
final class GdstudioNeteaseAdapter: StreamSourceAdapter {
    let name = "gdstudio 网易"
    let platform: MusicPlatform = .netease

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let br: String
        var format = "mp3"
        switch quality {
        case .standard: br = "128"
        case .high: br = "320"
        case .lossless: br = "740"; format = "flac"
        }
        let url = "https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease&id=\(song.platformID)&br=\(br)"
        let json = try await APIClient.shared.getJSON(url, headers: ["User-Agent": "LX-Music-Mobile"], timeout: 12)
        guard let stream = json["url"] as? String, !stream.isEmpty else {
            throw APIError.parse("gdstudio 未返回 URL")
        }
        guard await StreamVerifier.isAudioURL(stream) else {
            throw APIError.httpStatus(0)
        }
        return StreamSource(url: stream, backendName: name, platform: platform, quality: quality, format: format, note: "VIP 全量 mp3/FLAC")
    }
}

/// oiapi Music_163：https://oiapi.net/api/Music_163?id={id} → {code:0, data:[{url}]}
final class OiapiNeteaseAdapter: StreamSourceAdapter {
    let name = "oiapi 网易"
    let platform: MusicPlatform = .netease

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let url = "https://oiapi.net/api/Music_163?id=\(song.platformID)"
        let json = try await APIClient.shared.getJSON(url, timeout: 12)
        guard let code = json["code"] as? Int, code == 0 else {
            throw APIError.parse("oiapi 网易 code != 0")
        }
        var stream: String? = nil
        if let data = json["data"] as? [[String: Any]], let first = data.first {
            stream = first["url"] as? String
        }
        if stream == nil { stream = json["url"] as? String }
        guard let finalURL = stream, !finalURL.isEmpty else {
            throw APIError.parse("oiapi 网易未返回 URL")
        }
        guard await StreamVerifier.isAudioURL(finalURL) else {
            throw APIError.httpStatus(0)
        }
        return StreamSource(url: finalURL, backendName: name, platform: platform, quality: quality, format: "mp3", note: "ID 直查")
    }
}

// MARK: - 酷狗系后端

/// haitangw 酷狗直链：https://music.haitangw.cc/kgqq/kg.php?type=mp3&id={hash}&level={level}
final class HaitangKugouAdapter: StreamSourceAdapter {
    let name = "haitangw 酷狗"
    let platform: MusicPlatform = .kugou

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let level: String
        var format = "mp3"
        switch quality {
        case .standard: level = "standard"
        case .high: level = "exhigh"
        case .lossless: level = "lossless"; format = "flac"
        }
        let url = "https://music.haitangw.cc/kgqq/kg.php?type=mp3&id=\(song.platformID)&level=\(level)"
        guard await StreamVerifier.isAudioURL(url) else {
            throw APIError.httpStatus(0)
        }
        return StreamSource(url: url, backendName: name, platform: platform, quality: quality, format: format, note: "hash 直查")
    }
}

// MARK: - 后端注册表
enum SourceRegistry {
    /// 所有后端（按平台分组，resolve 时取 song.platform 对应的后端 + 全部搜索式后端）
    static let all: [StreamSourceAdapter] = [
        HaitangKuwoAdapter(),
        NxinxzKuwoAdapter(),
        OiapiKuwoAdapter(),
        KuwoDESAdapter(),
        ZddyrKuwoAdapter(),
        CyapiQQAdapter(),
        AacabQQAdapter(),
        GdstudioNeteaseAdapter(),
        OiapiNeteaseAdapter(),
        HaitangKugouAdapter()
    ]

    /// 某首歌可用的后端：同平台后端 + 跨平台搜索式后端（oiapi 酷我、a.aa.cab）
    static func adapters(for song: Song) -> [StreamSourceAdapter] {
        let samePlatform = all.filter { $0.platform == song.platform }
        let cross: [StreamSourceAdapter] = [
            OiapiKuwoAdapter(),
            AacabQQAdapter()
        ]
        // 去重（同平台后端不重复）
        var seen = Set<String>()
        var result: [StreamSourceAdapter] = []
        for a in samePlatform + cross {
            if !seen.contains(a.name) {
                seen.insert(a.name)
                result.append(a)
            }
        }
        return result
    }
}

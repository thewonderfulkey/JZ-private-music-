import Foundation

// MARK: - 音频 URL 规范化
//
// 2026-11-16 实测：妖狐酷我返回的直链是 **http**（`http://car-lw.kuwo.cn/...`），
// 而 App 必须保持 ATS 严格（不许开 NSAllowsArbitraryLoads），http 在 iOS 上播放不了。
// 实测同一个 URL 换成 https 一样能取到（206 / audio/x-flac / 22.7MB），
// 所以统一把 http 升级成 https；升级后取不到的源按"不可用"处理，正好符合"宁缺毋滥"的口径。
enum UrlNormalizer {
    static func upgraded(_ raw: String) -> String {
        guard raw.lowercased().hasPrefix("http://") else { return raw }
        return "https://" + raw.dropFirst("http://".count)
    }
}
// MARK: - 取流校验 + 真实音质探测
//
// 与 Android `StreamVerifier` 同口径：一次 Range GET 同时回答两件事——
//   ① 这个 URL 到底是不是音频（而不是 HTML 落地页 / JSON 错误页）
//   ② 它是哪种容器、有多大（体积 ÷ 时长 = 真实码率）
// 为什么必须做：实测 cyapi 的 QQ 直链只有 ~97kbps m4a、oiapi 三档返回同一条 128k mp3。
// 只信接口自报，UI 就会"说能下无损、实际下到 128k"。
enum StreamVerifier {

    struct AudioFacts {
        /// flac / ogg / m4a / mp3 / wav / unknown
        let container: String
        /// 总字节数（服务端没给 Content-Range / Content-Length 时为 0）
        let totalBytes: Int64
    }

    static func inspect(_ urlString: String, timeout: TimeInterval = 8) async -> AudioFacts? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            let code = http.statusCode
            guard (200..<300).contains(code) || code == 206 else { return nil }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            // 服务端忽略 Range 直接回 200 时没有 Content-Range，此时 Content-Length 就是总长。
            // 少了这一步 totalBytes 恒为 0 → kbps 恒为 0 → 一律被判成 128k。
            var total: Int64 = 0
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            if let slash = contentRange.lastIndex(of: "/") {
                total = Int64(contentRange[contentRange.index(after: slash)...]) ?? 0
            }
            if total == 0, let len = http.value(forHTTPHeaderField: "Content-Length") {
                total = Int64(len) ?? 0
            }

            // 只读容器头 16 字节：服务端若忽略 Range 回 200，读全量会拖到超时、把"有无损"误判成"没源"
            var head: [UInt8] = []
            head.reserveCapacity(16)
            for try await byte in bytes {
                head.append(byte)
                if head.count >= 16 { break }
            }

            let container = sniffHead(head)
            let looksAudio = contentType.hasPrefix("audio/")
                || contentType.contains("octet-stream")
                || container != "unknown"
            guard looksAudio else { return nil }
            return AudioFacts(container: container, totalBytes: total)
        } catch {
            return nil
        }
    }

    static func isAudio(_ urlString: String, timeout: TimeInterval = 8) async -> Bool {
        await inspect(urlString, timeout: timeout) != nil
    }

    /// 前 16 字节容器头判定真实容器；认不出回 unknown（HTML / JSON 错误页会落到这里）
    static func sniffHead(_ b: [UInt8]) -> String {
        func at(_ i: Int) -> UInt8 { i < b.count ? b[i] : 0 }
        func eq(_ c: Character, _ i: Int) -> Bool { at(i) == (c.asciiValue ?? 0) }

        if b.count >= 4, eq("f", 0), eq("L", 1), eq("a", 2), eq("C", 3) { return "flac" }
        if b.count >= 4, eq("O", 0), eq("g", 1), eq("g", 2), eq("S", 3) { return "ogg" }
        if b.count >= 8, eq("f", 4), eq("t", 5), eq("y", 6), eq("p", 7) { return "m4a" }
        if b.count >= 3, eq("I", 0), eq("D", 1), eq("3", 2) { return "mp3" }
        if b.count >= 2, at(0) == 0xFF,
           [0xFB, 0xF3, 0xF2, 0xFA].contains(at(1)) { return "mp3" }
        if b.count >= 4, eq("R", 0), eq("I", 1), eq("F", 2), eq("F", 3) { return "wav" }
        return "unknown"
    }
}

// MARK: - 由容器与体积反推真实档位
// 接口自报的音质一律不信，只认探测到的事实
enum QualityFacts {

    /// 真实档位 + 实际容器后缀（下载文件名据此生成，杜绝 ".flac 里装 mp3"）
    static func of(_ facts: StreamVerifier.AudioFacts, durationSec: Int) -> (QualityLevel, String) {
        let ext = extOf(facts.container)
        if facts.container == "flac" || facts.container == "wav" { return (.lossless, ext) }
        let kb = kbps(facts.totalBytes, durationSec)
        // 算不出码率时宁可往低标——"没有无损却标无损"正是这一层要消灭的问题
        return (kb >= 256 ? .high : .standard, ext)
    }

    static func extOf(_ container: String) -> String {
        switch container {
        case "flac": return "flac"
        case "wav": return "wav"
        case "m4a": return "m4a"
        case "ogg": return "ogg"
        default: return "mp3"
        }
    }

    static func kbps(_ totalBytes: Int64, _ durationSec: Int) -> Int64 {
        guard durationSec > 0, totalBytes > 0 else { return 0 }
        return totalBytes * 8 / Int64(durationSec) / 1000
    }

    /// 目标档校验：三档共用唯一口径。无损看容器，320k/128k 看码率区间。
    /// kbps = 0（算不出）→ 一律不算命中，由上层按业务决定降级与否。
    static func matches(_ want: QualityLevel, container: String, kbps kb: Int64) -> Bool {
        let isLosslessContainer = container == "flac" || container == "wav"
        switch want {
        case .lossless:
            return isLosslessContainer || kb >= 600
        case .high:
            return !isLosslessContainer && (256...600).contains(kb)
        case .standard:
            return !isLosslessContainer && (48...255).contains(kb)
        }
    }
}

// MARK: - 取流后端协议
protocol StreamSourceAdapter: Sendable {
    var name: String { get }
    var platform: MusicPlatform { get }
    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource
}

extension QualityLevel {
    /// oiapi 的档位参数名
    var levelName: String {
        switch self {
        case .standard: return "standard"
        case .high: return "exhigh"
        case .lossless: return "lossless"
        }
    }
}

// MARK: - QQ 系：cyapi.top 直链
// 2026-11-16 实测：HTTP 200，返回 m4a，~97kbps（与 Android 侧注释一致），按事实标注为"标准 128k"
struct CyapiQQAdapter: StreamSourceAdapter {
    let name = "cyapi QQ"
    let platform: MusicPlatform = .qq

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let url = "https://cyapi.top/API/qq_music.php"
            + "?apikey=1ffdf5733f5d538760e63d7e46ba17438d9f7b9dfc18c51be1109386fd74c3a1"
            + "&type=json&mid=\(song.platformID)"
        let json = try await APIClient.shared.getJSON(
            url, headers: ["Referer": "https://y.qq.com/"], timeout: 12)
        guard let raw = json["url"] as? String, !raw.isEmpty else {
            throw APIError.parse("cyapi 未返回 URL")
        }
        let stream = UrlNormalizer.upgraded(raw)
        guard let facts = await StreamVerifier.inspect(stream) else {
            throw APIError.httpStatus(0)
        }
        let (q, fmt) = QualityFacts.of(facts, durationSec: song.durationSec)
        return StreamSource(url: stream, backendName: name, platform: platform, quality: q,
                            format: fmt, note: "VIP 全量 \(fmt)（实测标注）", directId: true,
                            kbps: QualityFacts.kbps(facts.totalBytes, song.durationSec),
                            totalBytes: facts.totalBytes)
    }
}

// MARK: - 网易系：gdstudio
// 2026-11-16 实测：br=320 → mp3、320kbps、10.83MB（诚实分档）
struct GdstudioNeteaseAdapter: StreamSourceAdapter {
    let name = "gdstudio 网易"
    let platform: MusicPlatform = .netease

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let br: String
        switch quality {
        case .standard: br = "128"
        case .high: br = "320"
        case .lossless: br = "740"
        }
        let url = "https://music-api.gdstudio.xyz/api.php"
            + "?use_xbridge3=true&loader_name=forest&need_sec_link=1&sec_link_scene=im&theme=light"
            + "&types=url&source=netease&id=\(song.platformID)&br=\(br)"
        let json = try await APIClient.shared.getJSON(
            url, headers: ["User-Agent": "LX-Music-Mobile"], timeout: 12)
        guard let raw = json["url"] as? String, !raw.isEmpty else {
            throw APIError.parse("gdstudio 未返回 URL")
        }
        let stream = UrlNormalizer.upgraded(raw)
        guard let facts = await StreamVerifier.inspect(stream) else {
            throw APIError.httpStatus(0)
        }
        let (q, fmt) = QualityFacts.of(facts, durationSec: song.durationSec)
        return StreamSource(url: stream, backendName: name, platform: platform, quality: q,
                            format: fmt, note: "VIP 全量 mp3/FLAC（实测标注）", directId: true,
                            kbps: QualityFacts.kbps(facts.totalBytes, song.durationSec),
                            totalBytes: facts.totalBytes)
    }
}

// MARK: - 网易系：oiapi（溯音 key 版）
// 2026-11-16 实测：code=0 但 data 里没有 url（通道当前失效）。保留是为了它恢复时零改动，
// 失败很快（一次 GET），不会拖慢整条解析链；kdstudio 仍是网易的主通道。
struct OiapiNeteaseAdapter: StreamSourceAdapter {
    let name = "oiapi 网易"
    let platform: MusicPlatform = .netease

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let url = "https://oiapi.net/api/Music_163"
            + "?key=oiapi-ef6133b7-ac2f-dc7d-878c-d3e207a82575"
            + "&type=json&level=\(quality.levelName)&n=1&id=\(song.platformID)"
        let json = try await APIClient.shared.getJSON(url, timeout: 12)
        if (json["code"] as? Int) != 0 { throw APIError.parse("oiapi 网易 code != 0") }
        var stream = ""
        if let data = json["data"] as? [[String: Any]], let first = data.first {
            stream = first["url"] as? String ?? ""
        }
        if stream.isEmpty { stream = json["url"] as? String ?? "" }
        guard !stream.isEmpty else { throw APIError.parse("oiapi 网易未返回 URL") }
        stream = UrlNormalizer.upgraded(stream)
        guard let facts = await StreamVerifier.inspect(stream) else {
            throw APIError.httpStatus(0)
        }
        let (q, fmt) = QualityFacts.of(facts, durationSec: song.durationSec)
        return StreamSource(url: stream, backendName: name, platform: platform, quality: q,
                            format: fmt, note: "ID 直查（溯音 key 版，实测标注）", directId: true,
                            kbps: QualityFacts.kbps(facts.totalBytes, song.durationSec),
                            totalBytes: facts.totalBytes)
    }
}

// MARK: - 酷我系：妖狐（搜索式取流，必须通过身份校验）
// 2026-11-16 实测：酷我「晴天」返回 flac 55.4MB、「夜曲」26.7MB，通道健康
// 按「歌名+歌手」无空格搜索；歌名/歌手对不上、或歌名不是裸名（(Live)/伴奏…）即丢弃
struct YaohuKuwoAdapter: StreamSourceAdapter {
    let name = "妖狐酷我"
    let platform: MusicPlatform = .kuwo

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let searchKey = song.searchKeywordCompact
        guard !searchKey.isEmpty else { throw APIError.parse("妖狐酷我：无歌名") }
        let url = "https://api.yaohud.cn/api/music/kuwo"
            + "?key=nvgKtvzw7CFSNFrDhA6&action=search&msg=\(APIClient.encode(searchKey))&n=1"
        let json = try await APIClient.shared.getJSON(
            url, headers: ["X-Client-Software": "lx"], timeout: 12)
        if (json["code"] as? Int) != 200 { throw APIError.parse("妖狐酷我 code != 200") }
        guard let data = json["data"] as? [String: Any] else {
            throw APIError.parse("妖狐酷我无 data")
        }
        // 身份校验：歌名/歌手必须与请求匹配（多歌手串与版本后缀用 NameMatch 统一口径）
        let respSong = (data["songtitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (data["name"] as? String ?? "")
        let respSinger = data["songname"] as? String ?? ""
        let titlePart = NameMatch.yaohuTitle(respSong)
        guard NameMatch.titleMatches(song.name, titlePart),
              NameMatch.singerMatches(song.singer, respSinger) else {
            throw APIError.parse("妖狐酷我结果不匹配：\(respSong)/\(respSinger)")
        }
        // 版本防线：歌名段不是裸名就当场拒绝——宁可不下，也不把别人的现场版当原唱
        guard StudioPick.isCleanTitle(titlePart) else {
            throw APIError.parse("妖狐酷我返回变体版本：\(titlePart)")
        }
        guard let vm = data["vipmusic"] as? [String: Any],
              let rawStream = vm["url"] as? String, !rawStream.isEmpty else {
            throw APIError.parse("妖狐酷我未返回 URL")
        }
        let stream = UrlNormalizer.upgraded(rawStream)
        let declared = vm["level"] as? String ?? "?"
        guard let facts = await StreamVerifier.inspect(stream) else {
            throw APIError.httpStatus(0)
        }
        let (q, fmt) = QualityFacts.of(facts, durationSec: song.durationSec)
        return StreamSource(url: stream, backendName: name, platform: platform, quality: q,
                            format: fmt, note: "官方直链（按歌名搜索，自报 \(declared)）",
                            directId: false,
                            kbps: QualityFacts.kbps(facts.totalBytes, song.durationSec),
                            totalBytes: facts.totalBytes)
    }
}

// MARK: - 酷狗系：官方 playInfo（hash 直查）
// 2026-11-16 实测：接口 HTTP 200 但响应里**没有 url**（只有 status/audio_id 等元数据），
// trackercdn 变体一律 errcode=20028。也就是说酷狗当前"能搜不能播"——与 Android v2.1.90 之前的处境一样。
// 保留适配器（恢复时零改动），酷狗的取流实际由 SameSongCrossResolver 跨平台补位承担。
struct KugouPlayInfoAdapter: StreamSourceAdapter {
    let name = "酷狗官方"
    let platform: MusicPlatform = .kugou

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let hash = song.platformID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { throw APIError.parse("酷狗：无 hash") }
        let url = "https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=\(hash)"
        let json = try await APIClient.shared.getJSON(
            url, headers: ["Referer": "https://m.kugou.com/"], timeout: 12)
        guard let raw = json["url"] as? String, !raw.isEmpty else {
            throw APIError.parse("酷狗未返回 URL（errcode \(json["errcode"] ?? -1)）")
        }
        let stream = UrlNormalizer.upgraded(raw)
        guard let facts = await StreamVerifier.inspect(stream) else {
            throw APIError.httpStatus(0)
        }
        let (q, fmt) = QualityFacts.of(facts, durationSec: song.durationSec)
        return StreamSource(url: stream, backendName: name, platform: platform, quality: q,
                            format: fmt, note: "酷狗官方 playInfo（hash 直查）", directId: false,
                            kbps: QualityFacts.kbps(facts.totalBytes, song.durationSec),
                            totalBytes: facts.totalBytes)
    }
}

// MARK: - 后端注册表
enum SourceRegistry {

    static let all: [StreamSourceAdapter] = [
        CyapiQQAdapter(),
        GdstudioNeteaseAdapter(),
        OiapiNeteaseAdapter(),
        YaohuKuwoAdapter(),
        KugouPlayInfoAdapter(),
    ]

    /// 某首歌可用的后端 = 同平台后端（Android 的 cross 恒为空，跨平台补源走 SameSongCrossResolver）
    static func adapters(for song: Song) -> [StreamSourceAdapter] {
        var seen = Set<String>()
        var out: [StreamSourceAdapter] = []
        for a in all where a.platform == song.platform {
            if seen.insert(a.name).inserted { out.append(a) }
        }
        return out
    }
}

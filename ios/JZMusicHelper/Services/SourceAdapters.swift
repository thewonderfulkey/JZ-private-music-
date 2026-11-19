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
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")

        // 真机上 `URLSession.bytes(for:)` 偶发"连接成功但一个字节都读不到"（HTTP/2 流被 CDN 重置、
        // 或者 Range 请求走了另一条边缘节点）。以前这种情况直接返回 nil → 这条后端被当成"没源"，
        // 于是"网易明明有无损，iOS 却只剩 128k"（《연애의 조건》r120）。
        // 现在最多试两次；两次都读不到头时，只要**体积已知**就仍然返回 unknown 容器，
        // 交给 `QualityFacts` 用码率反推档位（≥601kbps 即无损），不再整条后端判死。
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            if let facts = await inspectOnce(request) {
                if facts.container != "unknown" || facts.totalBytes > 0 { return facts }
            }
        }
        return nil
    }

    /// 一次 Range GET：读 HTTP 头 + 最多 16 字节容器头
    private static func inspectOnce(_ request: URLRequest) async -> AudioFacts? {
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
            // 判断"这是不是音频"：容器头认得、或 Content-Type 像音频、或这是一段 206 分片（只有音频 CDN 会这么回）
            let looksAudio = contentType.hasPrefix("audio/")
                || contentType.contains("octet-stream")
                || container != "unknown"
                || (total > 0 && code == 206)
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
    ///
    /// r120（《연애의 조건》事故）：库里那首网易无损的直链，头 4 字节不是 `fLaC`——
    /// 126.net 给的部分文件前面挂了一段 ID3v2 标签，真正的 `fLaC` 在后面。旧实现只看偏移 0，
    /// 于是把一条 1087kbps 的真无损判成 "unknown → mp3"，档位跟着掉成 320k，
    /// 下载弹层就变成"没有无损，最高可得 320k / 128k"。
    /// 现在在头 16 字节里**任意位置**找特征串，认得出就认。
    static func sniffHead(_ b: [UInt8]) -> String {
        guard !b.isEmpty else { return "unknown" }
        func at(_ i: Int) -> UInt8 { i < b.count ? b[i] : 0 }
        func has(_ s: String, from: Int = 0) -> Bool {
            let bytes = Array(s.utf8)
            guard b.count >= from + bytes.count else { return false }
            for (k, v) in bytes.enumerated() where at(from + k) != v { return false }
            return true
        }

        // 1) 容器特征串：标准位置 + 任意偏移都算（ID3v2 前缀后面才是真容器）。
        //    顺序很重要：**先**找真实容器——"ID3" 只说明前面挂了标签，不代表就是 mp3。
        if has("fLaC") { return "flac" }
        if has("OggS") { return "ogg" }
        if has("RIFF") { return "wav" }
        if b.count >= 8, has("ftyp", from: 4) { return "m4a" }
        for offset in 1..<b.count {
            if has("fLaC", from: offset) { return "flac" }
            if has("OggS", from: offset) { return "ogg" }
            if has("RIFF", from: offset) { return "wav" }
            if has("ftyp", from: offset) { return "m4a" }
        }

        // 2) 认不出容器才看标签 / 帧同步
        if b.count >= 3, has("ID3") { return "mp3" }
        if b.count >= 2, at(0) == 0xFF, [0xFB, 0xF3, 0xF2, 0xFA].contains(at(1)) { return "mp3" }
        return "unknown"
    }
}

// MARK: - 由容器与体积反推真实档位
// 接口自报的音质一律不信，只认探测到的事实
enum QualityFacts {

    /// 判定门槛（`of` 与 `matches` **共用同一组常量**，不允许各说各话）
    ///
    /// r120：《연애의 조건》那次事故的后半段——`matches(.lossless)` 认「码率 ≥600k 也算无损」，
    /// 但 `of()` 只认容器，于是同一条 1087kbps 的源在"能不能算命中"里是无损，
    /// 在"显示成哪一档"里却是 320k：弹层写"只有高品 320k"、文件其实是 FLAC。
    /// 现在两边都走这里，命中与标注从根上一致。
    /// 无损与"高品"的分界：601kbps 起算无损（600 仍属高品区间，和 SelfTest 的历史断言一致）
    static let losslessFloorKbps: Int64 = 601
    /// 高品区间（256–600）与标准区间（48–255）
    static let highBandKbps: ClosedRange<Int64> = 256...600
    static let standardBandKbps: ClosedRange<Int64> = 48...255

    /// 真实档位 + 实际容器后缀（下载文件名据此生成，杜绝 ".flac 里装 mp3"）
    static func of(_ facts: StreamVerifier.AudioFacts, durationSec: Int) -> (QualityLevel, String) {
        let ext = extOf(facts.container)
        if facts.container == "flac" || facts.container == "wav" { return (.lossless, ext) }
        let kb = kbps(facts.totalBytes, durationSec)
        // 容器认不出但码率已经是无损量级（CDN 把容器头改了 / 前面挂 ID3）：按无损标，
        // 和 `matches` 同一个口径；算不出码率时仍宁可往低标
        if kb >= losslessFloorKbps { return (.lossless, ext) }
        return (highBandKbps.contains(kb) ? .high : .standard, ext)
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

    /// 目标档校验：三档共用唯一口径。无损看容器或无损量级码率，320k/128k 看码率区间。
    /// kbps = 0（算不出）→ 一律不算命中，由上层按业务决定降级与否。
    ///
    /// 与 `of()` 共用 `losslessFloorKbps` / `highFloorKbps`：命中判定与档位标注必须一致，
    /// 否则就会出现"命中无损、界面显示 320k"（r120 的事故）。
    static func matches(_ want: QualityLevel, container: String, kbps kb: Int64) -> Bool {
        let isLosslessContainer = container == "flac" || container == "wav"
        switch want {
        case .lossless:
            return isLosslessContainer || kb >= losslessFloorKbps
        case .high:
            return !isLosslessContainer && highBandKbps.contains(kb)
        case .standard:
            return !isLosslessContainer && standardBandKbps.contains(kb)
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

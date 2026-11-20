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
        /// 服务端是否支持 Range（206 或回了 Content-Range）。
        /// 下载链的"来源可靠性"评分和播放 seek 都看它；200 全量也无所谓，但要知道。
        var rangeOK: Bool = false
    }

    /// 探测一条直链的真实容器与体积。
    ///
    /// 真机事故（r122，《연애의 조건》）：iOS 上 `URLSession.bytes(for:)` 对着 126.net / 酷我 CDN
    /// 会"连接成功但一个字节都读不到"（HTTP/2 流被重置、或 Range 请求走到不认的边缘节点），
    /// 于是整条后端被判"没源"——网易明明有真无损，iOS 只剩 QQ 的 128k。
    ///
    /// 现在三道路，任何一条通就能定档：
    ///   ① peek：自己接 `URLSessionDataDelegate`，拿到 ≥16 字节就取消任务（不拉整首 25MB）；
    ///   ② 再 peek 一次（换一次连接，覆盖边缘节点抖动）；
    ///   ③ **HEAD**：不读 body，只拿 Content-Length + Content-Type——容器认不出也能用码率反推档位。
    /// 超时压到 5s/4s：`URLResolver` 给单个后端的预算是 12s，还得留出"接口取 URL"的时间。
    static func inspect(_ urlString: String, timeout: TimeInterval = 5) async -> AudioFacts? {
        guard let url = URL(string: urlString) else { return nil }
        let referer = referer(forHost: url.host)

        var get = URLRequest(url: url)
        get.timeoutInterval = timeout
        get.cachePolicy = .reloadIgnoringLocalCacheData
        get.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        get.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        get.setValue(referer, forHTTPHeaderField: "Referer")

        // 每道 peek 再套一层硬超时：delegate 万一没回调，也不会把整条下载流程挂住
        if let peeked = (await withTimeoutOrNil(timeout + 1, { await peek(get) }) ?? nil),
           let facts = facts(from: peeked.0, head: peeked.1),
           facts.container != "unknown" || facts.totalBytes > 0 {
            return facts
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        if let peeked = (await withTimeoutOrNil(timeout + 1, { await peek(get) }) ?? nil),
           let facts = facts(from: peeked.0, head: peeked.1),
           facts.container != "unknown" || facts.totalBytes > 0 {
            return facts
        }

        // ③ HEAD：最省的一条路（有些 CDN 的 GET 会被风控，HEAD 反而正常）
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 4
        head.cachePolicy = .reloadIgnoringLocalCacheData
        head.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        head.setValue(referer, forHTTPHeaderField: "Referer")
        if let (_, response) = try? await URLSession.shared.data(for: head),
           let resp = response as? HTTPURLResponse,
           let facts = facts(from: resp, head: Data()), facts.totalBytes > 0 {
            return facts
        }
        return nil
    }

    /// 按域名给 Referer：以前所有源都发 music.qq.com，126.net/酷我 CDN 偶尔因此回 403
    static func referer(forHost host: String?) -> String {
        let h = (host ?? "").lowercased()
        if h.contains("126.net") || h.contains("163.com") { return "https://music.163.com/" }
        if h.contains("kuwo") { return "https://www.kuwo.cn/" }
        if h.contains("kugou") { return "https://m.kugou.com/" }
        if h.contains("qq.com") || h.contains("gtimg") || h.contains("stream.qqmusic") { return "https://y.qq.com/" }
        return "https://music.qq.com/"
    }

    /// 一次 peek：收到 ≥16 字节就取消，最多等 `timeout`（见 `PeekDelegate`）
    private static func peek(_ request: URLRequest) async -> (HTTPURLResponse, Data)? {
        let delegate = PeekDelegate()
        let result = await delegate.run(request)
        delegate.cleanup()
        return result
    }

    /// HTTP 头 + 头 16 字节 → 容器与总长（纯函数，便于断言）
    static func facts(from http: HTTPURLResponse, head: Data) -> AudioFacts? {
        let code = http.statusCode
        guard (200..<300).contains(code) || code == 206 else { return nil }
        var total: Int64 = 0
        let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
        if let slash = contentRange.lastIndex(of: "/") {
            total = Int64(contentRange[contentRange.index(after: slash)...]) ?? 0
        }
        if total == 0, let len = http.value(forHTTPHeaderField: "Content-Length") {
            total = Int64(len) ?? 0
        }
        let container = sniffHead([UInt8](head.prefix(16)))
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        // 是不是音频：容器头认得、Content-Type 像音频、或这是 206 分片（只有音频 CDN 会这么回）
        let looksAudio = contentType.hasPrefix("audio/")
            || contentType.contains("octet-stream")
            || container != "unknown"
            || (total > 0 && code == 206)
        guard looksAudio else { return nil }
        return AudioFacts(container: container, totalBytes: total,
                          rangeOK: code == 206 || !contentRange.isEmpty)
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

// MARK: - 只读"头 16 字节"的 peek（替代 URLSession.bytes）
//
// 为什么不用 `bytes(for:)`：真机上它对 126.net / 酷我 CDN 会"连接成功但读不到字节"，
// 于是整条后端被判"没源"（《연애의 조건》r122：网易明明有真无损、iOS 只剩 QQ 128k）。
// 这里自己接 `URLSessionDataDelegate`：拿到响应就记下头，收到 ≥16 字节立刻取消任务——
// 既不下载整首 25MB，也不依赖 AsyncBytes 的实现细节。
private final class PeekDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var head = Data()
    private var http: HTTPURLResponse?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(HTTPURLResponse, Data)?, Never>?
    private var finished = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func run(_ request: URLRequest) async -> (HTTPURLResponse, Data)? {
        await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.lock()
            self.continuation = continuation
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    /// 结束后清理（不 resume；`run` 已经返回）
    func cleanup() {
        lock.lock()
        finished = true
        let task = self.task
        continuation = nil
        lock.unlock()
        task?.cancel()
        session.invalidateAndCancel()
    }

    private func complete() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        let result: (HTTPURLResponse, Data)? = http.map { ($0, head) }
        let task = self.task
        lock.unlock()
        task?.cancel()
        cont?.resume(returning: result)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        http = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        head.append(data)
        let enough = head.count >= 16
        lock.unlock()
        if enough { complete() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if http == nil { http = task.response as? HTTPURLResponse }
        lock.unlock()
        complete()
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
        return (quality(container: facts.container, kbps: kb), ext)
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

    /// 由「容器 + 码率」定档（`of()` 与"接口自报兜底"共用）
    static func quality(container: String, kbps kb: Int64) -> QualityLevel {
        if container == "flac" || container == "wav" { return .lossless }
        if kb >= losslessFloorKbps { return .lossless }
        return highBandKbps.contains(kb) ? .high : .standard
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
                            totalBytes: facts.totalBytes, rangeOK: facts.rangeOK)
    }
}

// MARK: - QQ 系：落月 vkeys（**已下线**，2026-11-20 晚）
//
// 现状：**不注册**（`SourceRegistry.all` 里没有它），QQ 只有 cyapi 一条后端。
// 下线原因：上线当天（v2.4.36）真机反馈「QQ 源直接听不了、被风控」。
// 它的上游是公共共享账号，本身就在被风控：同一端点会回 HTTP 200 + `{"code":503}`，
// 或者 `{"code":110001,"message":"cookie异常：账号被风控无法获取"}`；
// 更麻烦的是它偶尔仍回 200 + 一个 URL（比 cyapi 快得多，会赢下 `firstPlayable`），
// 但那条 URL 到播放时已经不可用——于是「后端看起来成功、实际听着没声」。
//
// 保留这份实现与它的断言（纯逻辑：档位映射 / 加密包闸门 / 信封解析），
// 因为落月一旦恢复，在 `SourceRegistry.all` 加回一行就能用。
// 真要重启前必须先解决"回 200 但链接已死"这件事（例如只用于下载、不用于播放）。
//
// 以下是当初上线时的实测依据（2026-11-20 白天，脚本仿真器实测）：
//   · quality=8  → mp3 10,792,943 B = 真 320 kbps（Range 206、容器可认）
//   · quality=10 → flac 55,397,039 B
//   · 同一个 mid 下 cyapi 只有 3,283,546 B / ~97 kbps
struct LuoyueQQAdapter: StreamSourceAdapter {
    let name = "落月 QQ"
    let platform: MusicPlatform = .qq

    /// 我们的三档 → 落月 quality 码。
    /// 只用 6/8/10；11/13/14/16（hires / atmos / atmos_plus / master）一律不碰：
    /// 播放链按 `PlaybackQualityRules` 不吃 ≥601kbps，下载档 flac 已经够。
    static func vkeysQuality(_ q: QualityLevel) -> Int {
        switch q {
        case .standard: return 6
        case .high: return 8
        case .lossless: return 10
        }
    }

    /// `.mgg` 是 QQ 音乐的加密 OGG（O4M / O6M / O8M 前缀），第三方播放器解不开。
    /// 实测《大鱼》320k 就是这种：HTTP 200、11,698,595 B、Content-Range 正常，
    /// 但首字节和偏移 100000 处都是随机字节、任何容器魔数都不匹配——播放器拿到手才炸。
    /// 必须在取流侧就拒掉，别指望 StreamVerifier 的"认不出容器"顺带挡住。
    static func isEncryptedQQ(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains(".mgg") { return true }
        return ["/o4m", "/o6m", "/o8m"].contains { lower.contains($0) }
    }

    /// 解析落月的响应信封。**它的失败也是 HTTP 200**（`APIClient` 只看状态码会当成成功），
    /// 所以这里必须自己判 `code`：
    ///   `{"code":200,"data":{"url":"…"}}`            ← 成功
    ///   `{"code":503,"message":"系统运行错误！"}`      ← 上游挂了
    ///   `{"code":110001,"message":"cookie异常…"}`     ← 账号被风控
    static func parse(_ json: [String: Any]) throws -> String {
        let code = (json["code"] as? Int) ?? Int((json["code"] as? String) ?? "") ?? -1
        guard code == 200 else {
            let msg = (json["message"] as? String) ?? ""
            throw APIError.parse("落月 code=\(code) \(msg)")
        }
        let data = json["data"]
        let raw: String?
        if let dict = data as? [String: Any] {
            raw = dict["url"] as? String
        } else if let s = data as? String {
            // 少数线路把 URL 直接放 data 里
            raw = s
        } else {
            raw = nil
        }
        guard let url = raw, !url.isEmpty else {
            throw APIError.parse("落月 未返回 URL")
        }
        return url
    }

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let url = "https://api.vkeys.cn/v2/music/tencent/geturl"
            + "?mid=\(song.platformID)&quality=\(Self.vkeysQuality(quality))"
        let json = try await APIClient.shared.getJSON(
            url, headers: ["Accept": "application/json"], timeout: 10)
        let raw = try Self.parse(json)
        guard !Self.isEncryptedQQ(raw) else {
            throw APIError.parse("落月 回的是 QQ 加密包（.mgg）")
        }
        let stream = UrlNormalizer.upgraded(raw)
        guard let facts = await StreamVerifier.inspect(stream) else {
            throw APIError.httpStatus(0)
        }
        // 档位按**实测**报，不按请求报：实测出现过"要 flac 回 320k mp3"（报告 §4.1）
        let (q, fmt) = QualityFacts.of(facts, durationSec: song.durationSec)
        return StreamSource(url: stream, backendName: name, platform: platform, quality: q,
                            format: fmt, note: "聚合直链（实测标注）", directId: true,
                            kbps: QualityFacts.kbps(facts.totalBytes, song.durationSec),
                            totalBytes: facts.totalBytes, rangeOK: facts.rangeOK)
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
            url, headers: ["User-Agent": "LX-Music-Mobile"], timeout: 8)
        guard let raw = json["url"] as? String, !raw.isEmpty else {
            throw APIError.parse("gdstudio 未返回 URL")
        }
        let stream = UrlNormalizer.upgraded(raw)

        // r123：gdstudio 的响应自带 `br`（实测 740 档回 1086~1095）与 `size`。
        // 真机上探测偶尔还会失败（CDN 风控/超时），这时**不能整条后端判死**——
        // 有这两个字段就能定档：容器认不出就用码率，时长未知（gdstudio 搜索不返回时长）就用 br。
        let apiBr = (json["br"] as? Int) ?? ((json["br"] as? NSNumber)?.intValue ?? 0)
        let apiSize = Int64((json["size"] as? Int) ?? ((json["size"] as? NSNumber)?.intValue ?? 0))

        let facts = await StreamVerifier.inspect(stream)
        let total = facts?.totalBytes ?? apiSize
        let container = facts?.container ?? "unknown"
        let calcKbps = QualityFacts.kbps(total, song.durationSec)
        let kb = calcKbps > 0 ? calcKbps : Int64(apiBr)
        guard total > 0 || kb > 0 else { throw APIError.httpStatus(0) }

        let q = QualityFacts.quality(container: container, kbps: kb)
        let fmt = QualityFacts.extOf(container)
        let note = facts == nil ? "VIP 全量（探测失败，按接口自报 br=\(apiBr)）" : "VIP 全量 mp3/FLAC（实测标注）"
        return StreamSource(url: stream, backendName: name, platform: platform, quality: q,
                            format: fmt, note: note, directId: true,
                            kbps: kb, totalBytes: total, rangeOK: facts?.rangeOK ?? false)
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
                            totalBytes: facts.totalBytes, rangeOK: facts.rangeOK)
    }
}

// MARK: - 酷我系：妖狐（搜索式取流，必须通过身份校验）
// 2026-11-16 实测：酷我「晴天」返回 flac 55.4MB、「夜曲」26.7MB，通道健康
// 按「歌名+歌手」无空格搜索；歌名/歌手对不上、或歌名不是裸名（(Live)/伴奏…）即丢弃
struct YaohuKuwoAdapter: StreamSourceAdapter {
    let name = "妖狐酷我"
    let platform: MusicPlatform = .kuwo

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        // 2026-11-19 实测：把「歌名+歌手」原样拼（含 (恋爱的条件)(LOVE OPTIONS)）会先命中 (INST) 伴奏版；
        // 只留「核心歌名 + 主歌手」时同一通道返回的是**原唱无损**（26,251,814 B / 1082kbps）。
        let searchKey = NameMatch.yaohuSearchKey(name: song.name, singer: song.singer)
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
        // 版本防线（2026-11-19 修正口径）：只拦**版本类**（live/伴奏/inst/remix/翻唱/纯音乐…），
        // 不拦官方副标题/译名。旧实现用 `isCleanTitle` 要求"裸名"，把
        // 「연애의 조건 (LOVE OPTIONS)」这种带官方英文副标题的原唱也判成变体丢掉了。
        let candVer = NameMatch.versionClass(titlePart)
        if !candVer.isSubset(of: NameMatch.versionClass(song.name)) {
            throw APIError.parse("妖狐酷我返回版本变体：\(titlePart)")
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
                            totalBytes: facts.totalBytes, rangeOK: facts.rangeOK)
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
                            totalBytes: facts.totalBytes, rangeOK: facts.rangeOK)
    }
}

// MARK: - 酷我系：官方 anti.s（按 rid 直接换播放地址）
//
// 为什么要有这一条（2026-11-20，A 方案"在线 ≤320k、FLAC 不进播放链"）：
// 妖狐酷我**只有一个档位**——实测「晴天」「夜曲」都回 `level=lossless / bitrate=740`（FLAC 26MB），
// 而酷我歌的播放链原本只有妖狐这一条。按 A 口径过滤掉 FLAC，等于整首没源——而歌单广场、
// 热门音乐、最新单曲都是酷我的歌，这会直接把主界面打空。
//
// 官方 `anti.s` 按 rid 换地址：实测回 **129kbps mp3**（audio/mpeg，2,302,801 B / 143s），
// 直连、支持 Range，正好补上"≤320k 的那一条"。想要 320k 只能靠起播后的跨平台后台升档
// （`schedulePlaybackUpgrade`，仍受 ≤320k 约束）；`br=320` 这个参数服务端不认，
// 回的是一个约 181KB 的残片，别用。
struct KuwoOfficialAdapter: StreamSourceAdapter {
    let name = "酷我官方"
    let platform: MusicPlatform = .kuwo

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let rawID = song.platformID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rid = rawID.hasPrefix("MUSIC_") ? String(rawID.dropFirst("MUSIC_".count)) : rawID
        guard !rid.isEmpty, rid.allSatisfy({ $0.isNumber }) else {
            throw APIError.parse("酷我官方：rid 非法")
        }
        let url = "https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3"
            + "&response=url&rid=MUSIC_\(rid)"
        let rawText = try await APIClient.shared.getString(
            url, headers: ["Referer": "https://www.kuwo.cn/"], timeout: 10)
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 这条接口失败时回的不是 JSON，而是一句人话（如 "refuse request!"）
        guard text.lowercased().hasPrefix("http") else {
            throw APIError.parse("酷我官方未返回地址")
        }
        let stream = UrlNormalizer.upgraded(text)
        guard let facts = await StreamVerifier.inspect(stream) else {
            throw APIError.httpStatus(0)
        }
        let (q, fmt) = QualityFacts.of(facts, durationSec: song.durationSec)
        return StreamSource(url: stream, backendName: name, platform: platform, quality: q,
                            format: fmt, note: "官方直链（rid 直查，实测标注）", directId: true,
                            kbps: QualityFacts.kbps(facts.totalBytes, song.durationSec),
                            totalBytes: facts.totalBytes, rangeOK: facts.rangeOK)
    }
}

// MARK: - 后端注册表
enum SourceRegistry {

    static let all: [StreamSourceAdapter] = [
        CyapiQQAdapter(),
        // 2026-11-20 晚：`LuoyueQQAdapter` 已**下线**（见下方结构体上的说明）。
        // QQ 恢复成只有 cyapi 一条后端——即 v2.4.35 及之前的行为。
        // 要重新启用：在下面 CyapiQQAdapter() 之后加回 `LuoyueQQAdapter(),` 一行即可。
        GdstudioNeteaseAdapter(),
        OiapiNeteaseAdapter(),
        YaohuKuwoAdapter(),
        KuwoOfficialAdapter(),
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

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
        // 加密包闸门：QQ 有概率回 .mgg（O4M/O6M/O8M），HTTP 200 且体积正常但放不出声
        guard !StreamEncryptionRules.isEncrypted(raw) else {
            throw APIError.parse("cyapi 回的是 QQ 加密包（.mgg）")
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

// MARK: - QQ 系：落月 vkeys（v3 已恢复注册，2026-11-21）
//
// 时间线（别把这条再搞丢，踩过两次）：
//   · v2.4.36 上线，接的是 **v2** `/v2/music/tencent/geturl`；
//   · 当天真机"QQ 听不了"，v2.4.38 按老板要求下线——**但那次的真因是端点选错了**：
//     v2 现在恒回 `{"code":503,"message":"系统运行错误！"}`；
//   · 2026-11-21 逐端点复测：**v3** `/music/tencent/song/link` 正常，晴天 q=8 →
//     10,792,943 B（真 320k）、q=10 → 55,397,039 B（flac），`data.url` 就是 CDN 直链；
//     同一首 2 轮各 2/2 命中；大鱼 flac 也通。
//
// 仍然只当**机会性加分源**：上游是公共共享账号，会回 `code=110001 cookie异常：账号被风控`；
// 七里香、大鱼 320k 在 2026-11-21 的抽样里 0/2。所以它：
//   · 不挡路（失败很快，冷却 5 分钟，`BackendHealth` 记着）；
//   · 不许"回 200 但链接已死"的 URL 赢下 firstPlayable —— 靠 `StreamVerifier` 实测体积/容器兜住。
//
// 以下是上线时的实测依据（2026-11-20 白天，脚本仿真器实测）：
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

    /// 加密容器判定交给统一入口（`StreamEncryptionRules`），保留这个别名是因为
    /// SelfTest 里已有针对它的断言。
    static func isEncryptedQQ(_ url: String) -> Bool { StreamEncryptionRules.isEncrypted(url) }

    /// 解析**落月 v3**（`/music/tencent/song/link`）的信封。
    ///
    /// 2026-11-21 实测（这是 v2.4.38 撤掉落月之后的纠正）：
    ///   · v2 `/v2/music/tencent/geturl` → 恒回 `{"code":503,"message":"系统运行错误！"}`
    ///     ——v2.4.36 接的就是这条，所以"落月挂了"其实是**接错端点**；
    ///   · v3 `/music/tencent/song/link` → `{"code":0,"data":{"url":"…M800….mp3"}}`，
    ///     晴天 q=8 给 10,792,943 B（真 320k）、q=10 给 55,397,039 B（flac）。
    /// 注意 `data.link` 只是 i.y.qq.com 的播放页，**不能用**；必须取 `data.url`。
    static func parseV3(_ json: [String: Any]) throws -> String {
        let code = (json["code"] as? Int) ?? Int((json["code"] as? String) ?? "") ?? -1
        guard code == 0 else {
            let msg = (json["message"] as? String) ?? ""
            throw APIError.parse("落月 v3 code=\(code) \(msg)")
        }
        let data = json["data"] as? [String: Any] ?? [:]
        guard let raw = data["url"] as? String, !raw.isEmpty else {
            let msg = (data["message"] as? String) ?? "空"
            throw APIError.parse("落月 v3 无 url（\(msg)）")
        }
        return raw
    }

    /// 取一次 `/music/tencent/song/link`（重试逻辑复用它，别把 URL 抄两遍）
    static func fetchLink(song: Song, quality: QualityLevel) async throws -> [String: Any] {
        let url = "https://api.vkeys.cn/music/tencent/song/link"
            + "?mid=\(song.platformID)&quality=\(Self.vkeysQuality(quality))"
        return try await APIClient.shared.getJSON(
            url, headers: ["Accept": "application/json"], timeout: 10)
    }

    /// 哪些错误码值得**立刻重试一次**（纯函数，CI 可断言）
    ///
    /// 2026-11-21 实测：`110001 账号被风控` 是**逐次**的——同一首隔 400ms 重试通常就过
    /// （夜曲第 1 次 110001 → 重试 320k 成功；晴天/稻香一次就过）。
    /// 所以它不该在第一次失败后立刻冷却 5 分钟：那等于把周杰伦这条路自己堵死。
    static func shouldRetryOnce(code: Int) -> Bool { code == 110001 }

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        var json = try await Self.fetchLink(song: song, quality: quality)
        var code = (json["code"] as? Int) ?? -1

        if Self.shouldRetryOnce(code: code) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let again = try? await Self.fetchLink(song: song, quality: quality) {
                let c2 = (again["code"] as? Int) ?? -1
                if c2 == 0 { json = again; code = 0 }
            }
        }
        if code != 0 {
            // 110001 = 共享账号被风控；冷却 5 分钟，别每首播放都去撞
            let msg = (json["message"] as? String) ?? ""
            if let cool = BackendHealthRules.cooldownSeconds(apiCode: code, message: msg,
                                                              httpStatus: nil) {
                BackendHealth.shared.block(name, seconds: cool)
            }
            throw APIError.parse("落月 v3 code=\(code) \(msg)")
        }
        let raw = try Self.parseV3(json)
        BackendHealth.shared.clear(name)
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

    /// 解析落月 **v2** 的响应信封（历史实现，留作断言基线；线上走 v3）。
    ///   `{"code":200,"data":{"url":"…"}}`            ← 成功
    ///   `{"code":503,"message":"系统运行错误！"}`      ← 上游挂了（v2 现在恒回这个）
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
//
// 2026-11-25 事故（v2.4.117 之后《众》彻底没源）：
//   这条通道从接进来那天起**一次都没成功过**——旧解析只认 `data` 是数组
//   （`data as? [[String: Any]]`），而 oiapi 实际返回的是
//   `{"code":0,"data":{"items":[{"url":…}]}}`，`data` 是**字典**。
//   于是每次都走到"未返回 URL"那一句，被当成"通道失效"记在注释里（2026-11-16 的结论）。
//   《众》在四个平台里只剩这一条源（gdstudio 全档空、meting 空、酷狗 502、QQ 403），
//   所以它以前"能播"其实是跨源串到了同歌手的《侧脸》；身份闸堵住串歌之后，它就真的没源了。
struct OiapiNeteaseAdapter: StreamSourceAdapter {
    let name = "oiapi 网易"
    let platform: MusicPlatform = .netease

    /// 从响应里取直链（纯函数，CI 钉死三种形状）
    ///
    /// 现行形状：`data.items[0].url`；兼容老形状 `data[0].url` 与根上的 `url`。
    /// 注意 `url` 可能是 `null`（无版权/受限歌）——那不是"解析失败"，是"这首没有"。
    static func streamURL(from json: [String: Any]) -> String {
        if let data = json["data"] as? [String: Any] {
            if let items = data["items"] as? [[String: Any]],
               let url = items.first?["url"] as? String, !url.isEmpty {
                return url
            }
            if let url = data["url"] as? String, !url.isEmpty { return url }
        }
        if let data = json["data"] as? [[String: Any]],
           let url = data.first?["url"] as? String, !url.isEmpty {
            return url
        }
        if let url = json["url"] as? String, !url.isEmpty { return url }
        return ""
    }

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let url = "https://oiapi.net/api/Music_163"
            + "?key=oiapi-ef6133b7-ac2f-dc7d-878c-d3e207a82575"
            + "&type=json&level=\(quality.levelName)&n=1&id=\(song.platformID)"
        let json = try await APIClient.shared.getJSON(url, timeout: 12)
        if (json["code"] as? Int) != 0 { throw APIError.parse("oiapi 网易 code != 0") }
        var stream = Self.streamURL(from: json)
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
        let apiCode = (json["code"] as? Int) ?? -1
        let apiMsg = (json["msg"] as? String) ?? (json["message"] as? String) ?? ""
        if apiCode != 200 {
            // 2026-11-20 实测：连续请求几十次后回 403「由于你多次频繁请求，系统已暂时屏蔽」，
            // 冷却 25 分钟仍未解封。冷却期内别再叫它（否则每播一首都在续封）。
            if let cool = BackendHealthRules.cooldownSeconds(apiCode: apiCode, message: apiMsg,
                                                              httpStatus: nil) {
                BackendHealth.shared.block(name, seconds: cool)
            }
            throw APIError.parse("妖狐酷我 code=\(apiCode) \(apiMsg)")
        }
        BackendHealth.shared.clear(name)
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

// MARK: - 酷我系：ikun 聚合（按 rid 直取，320k / flac）
//
// 2026-11-20 23:2x 实测（老板要求"多接几个源"之后从星澜脚本里挑出来的）：
//   `POST https://c.wwwweb.top/music/url  {"source":"kw","musicId":"<rid>","quality":"320k"}`
//   · 晴天 rid=228908 → mp3 10,792,943 B（真 320k），flac → 55,397,039 B
//   · 七里香 rid=94237 → 11,970,297 B（320kbps）、大鱼 rid=7095195 → 12,551,167 B
//   · 3 首 × 2 档 × 2 轮 = **6/6 命中**，接口 0.8–2.1s，音频首字节 80–400ms
// 为什么它重要：酷我官方 anti.s 对周杰伦（杰威尔）只回 181,521 B 的提示音，
// 这条是**唯一能把周杰伦给成整首 320k** 的通道。
struct IkunKuwoAdapter: StreamSourceAdapter {
    let name = "ikun 酷我"
    let platform: MusicPlatform = .kuwo

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let rawID = song.platformID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rid = rawID.hasPrefix("MUSIC_") ? String(rawID.dropFirst("MUSIC_".count)) : rawID
        guard !rid.isEmpty, rid.allSatisfy({ $0.isNumber }) else {
            throw APIError.parse("ikun 酷我：rid 非法")
        }
        let q = quality == .lossless ? "flac" : "320k"
        let body = "{\"source\":\"kw\",\"musicId\":\"\(rid)\",\"quality\":\"\(q)\"}"
        let json = try await APIClient.shared.postJSON(
            "https://c.wwwweb.top/music/url", body: body, timeout: 15)
        let apiCode = (json["code"] as? Int) ?? -1
        let apiMsg = (json["message"] as? String) ?? ""
        guard apiCode == 200 else {
            if let cool = BackendHealthRules.cooldownSeconds(apiCode: apiCode, message: apiMsg,
                                                              httpStatus: nil) {
                BackendHealth.shared.block(name, seconds: cool)
            }
            throw APIError.parse("ikun 酷我 code=\(apiCode) \(apiMsg)")
        }
        guard let raw = json["url"] as? String, !raw.isEmpty else {
            throw APIError.parse("ikun 酷我未返回 URL")
        }
        guard !StreamEncryptionRules.isEncrypted(raw) else {
            throw APIError.parse("ikun 回的是加密包")
        }
        let stream = UrlNormalizer.upgraded(raw)
        guard let facts = await StreamVerifier.inspect(stream) else {
            throw APIError.httpStatus(0)
        }
        let (qq, fmt) = QualityFacts.of(facts, durationSec: song.durationSec)
        BackendHealth.shared.clear(name)
        return StreamSource(url: stream, backendName: name, platform: platform, quality: qq,
                            format: fmt, note: "聚合直链（按 rid 直取，实测标注）", directId: true,
                            kbps: QualityFacts.kbps(facts.totalBytes, song.durationSec),
                            totalBytes: facts.totalBytes, rangeOK: facts.rangeOK)
    }
}

// MARK: - 酷我系：星海（yy.zddyr.top，按 rid 取流，只给 FLAC）
//
// 2026-11-20 23:3x 实测：`GET https://yy.zddyr.top/lx/api/?source=kw&name=&id=<rid>&quality=`
//   · ID 参数必须是 `id`（星澜脚本自己写的 `songid` 已被服务端拒："缺少歌曲 ID"）
//   · 返回的是**跳板** `/lx/api/kwplay.php?mid=…&s=…`，跟随后才是酷我 CDN 的 FLAC
//   · 3 首 × 2 轮 = 6/6，晴天 55,397,039 B；跳板多付 1.1–1.7s 首字节
// 所以它只当"第三条独立来源"：播放链里排在 ≤320k 之后，走 allowLossless 兜底；
// 下载链按实测码率如实标无损。
struct XinghaiKuwoAdapter: StreamSourceAdapter {
    let name = "星海酷我"
    let platform: MusicPlatform = .kuwo

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let rawID = song.platformID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rid = rawID.hasPrefix("MUSIC_") ? String(rawID.dropFirst("MUSIC_".count)) : rawID
        guard !rid.isEmpty, rid.allSatisfy({ $0.isNumber }) else {
            throw APIError.parse("星海酷我：rid 非法")
        }
        let q = quality == .lossless ? "flac" : "320kmp3"
        let name = "\(song.name) \(song.singer)"
        let url = "https://yy.zddyr.top/lx/api/?source=kw"
            + "&name=\(APIClient.encode(name))&id=\(rid)&quality=\(q)"
        let json = try await APIClient.shared.getJSON(
            url, headers: ["Referer": "https://www.kuwo.cn/"], timeout: 12)
        let apiCode = (json["code"] as? Int) ?? -1
        let apiMsg = (json["msg"] as? String) ?? ""
        guard apiCode == 200, let raw = json["url"] as? String, !raw.isEmpty else {
            if let cool = BackendHealthRules.cooldownSeconds(apiCode: apiCode, message: apiMsg,
                                                              httpStatus: nil) {
                BackendHealth.shared.block(self.name, seconds: cool)
            }
            throw APIError.parse("星海酷我 code=\(apiCode) \(apiMsg)")
        }
        guard !StreamEncryptionRules.isEncrypted(raw) else {
            throw APIError.parse("星海酷我 回的是加密包")
        }
        let stream = UrlNormalizer.upgraded(raw)
        guard let facts = await StreamVerifier.inspect(stream) else {
            throw APIError.httpStatus(0)
        }
        let (qq, fmt) = QualityFacts.of(facts, durationSec: song.durationSec)
        BackendHealth.shared.clear(self.name)
        return StreamSource(url: stream, backendName: self.name, platform: platform, quality: qq,
                            format: fmt, note: "聚合直链（星海跳板，实测标注）", directId: true,
                            kbps: QualityFacts.kbps(facts.totalBytes, song.durationSec),
                            totalBytes: facts.totalBytes, rangeOK: facts.rangeOK)
    }
}

// MARK: - 酷狗系：星海 zddyr `source=kg`（hash 直查，128k / 320k / flac）
//
// 为什么必须补这一条（2026-11-21 实测）：酷狗官方 `getSongInfo.php?cmd=playInfo` 至今回
// `errcode=1002`、**没有 url** —— 也就是说酷狗曲在 App 里根本没有原生取流，全靠
// `SameSongCrossResolver` 按歌名去别家猜。那条路既慢、又会拿错版本（周杰伦实测网易给的是翻唱），
// 酷狗独家曲则直接没源。
//
// 端点（照 聆滙岛报告 §3 那家 zddyr 的同族接口，2026-11-21 本机 4 首 × 4 档全通）：
//   `GET https://yy.zddyr.top/lx/api/?source=kg&quality=<128k|320k|flac>&mainHash=<FileHash>`
//   · `songmid` / `albumId` **可以不填**（报告里那两个值是它抓包时的残留，填了也一样）
//   · 回 `{code:200, msg:"成功", url:"http://fsandroid.tx.kugou.com/…"}`，直连 CDN，支持 Range 与 seek
//   · 实测（孤勇者 256s）：128k→4,097,029 B；320k→10,242,283 B；flac→28,729,042 B；master→108,494,040 B
//   · 首字节 77–181ms，接口 0.82–1.02s → 是现在最快的一条取流
//
// **只用三档，不用 master**：master 是 3,390kbps / 108MB 的母带，播放链吃不下、流量也不合理。
// **直链约 20 分钟后 403**（路径里带时间戳）：所以绝不可落库缓存 URL；下载长暂停后失败由
// `AudioPlayer` 已有的"失败重取一次"兜住。
struct XinghaiKugouAdapter: StreamSourceAdapter {
    let name = "星海酷狗"
    let platform: MusicPlatform = .kugou

    /// 三档 → zddyr 的 quality 参数（纯函数，CI 断言）
    static func qualityParam(_ q: QualityLevel) -> String {
        switch q {
        case .standard: return "128k"
        case .high: return "320k"
        case .lossless: return "flac"
        }
    }

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let hash = song.platformID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // 酷狗的 FileHash 是 32 位十六进制；不像 hash 的直接判死，别把歌名当 hash 发出去
        guard hash.count == 32, hash.allSatisfy({ $0.isHexDigit }) else {
            throw APIError.parse("星海酷狗：hash 非法")
        }
        let url = "https://yy.zddyr.top/lx/api/?source=kg"
            + "&quality=\(Self.qualityParam(quality))&mainHash=\(hash)"
        let json = try await APIClient.shared.getJSON(
            url, headers: ["Referer": "https://www.kugou.com/"], timeout: 12)
        let apiCode = (json["code"] as? Int) ?? -1
        let apiMsg = (json["msg"] as? String) ?? ""
        guard apiCode == 200, let raw = json["url"] as? String, !raw.isEmpty else {
            if let cool = BackendHealthRules.cooldownSeconds(apiCode: apiCode, message: apiMsg,
                                                             httpStatus: nil) {
                BackendHealth.shared.block(name, seconds: cool)
            }
            throw APIError.parse("星海酷狗 code=\(apiCode) \(apiMsg)")
        }
        guard !StreamEncryptionRules.isEncrypted(raw) else {
            throw APIError.parse("星海酷狗 回的是加密包")
        }
        let stream = UrlNormalizer.upgraded(raw)
        guard let facts = await StreamVerifier.inspect(stream) else {
            throw APIError.httpStatus(0)
        }
        let (q, fmt) = QualityFacts.of(facts, durationSec: song.durationSec)
        BackendHealth.shared.clear(name)
        return StreamSource(url: stream, backendName: name, platform: platform, quality: q,
                            format: fmt, note: "聚合直链（酷狗 hash 直查，实测标注）", directId: true,
                            kbps: QualityFacts.kbps(facts.totalBytes, song.durationSec),
                            totalBytes: facts.totalBytes, rangeOK: facts.rangeOK)
    }
}

// MARK: - 网易系：meting（qijieya，`type=url` 直接吐音频字节）
//
// 为什么补：网易现在只有 `gdstudio` 一条活后端（oiapi 已死）。两家都在同一批聚合商上游，
// 但域名/限流是独立的——老板要的"一个挂了自动换下一个"需要的是**独立域**，不是同域多参数。
//
// 端点：`GET https://api.qijieya.cn/meting/?server=netease&type=url&id=<songId>`
//   · **它不是 JSON，直接把音频字节吐出来**（302 落到 m701.music.126.net），所以这条 URL
//     本身就是可播地址；Range/mid-file seek 实测都通（206 + Content-Range）
//   · 实测 6/6：320k mp3，8.4–13.3MB，1.0–2.9s
//   · **坑**：拿不到时它回 **HTTP 200 + text/html + 0 字节**——只看状态码会把 HTML 当歌放。
//     这里靠 `StreamVerifier`（容器头/Content-Type）拦，并且再要求体积 ≥1MB。
enum MetingStreamRules {
    /// 体积下限：真歌 320k 至少几 MB；HTML 错误页 / 空响应都在 1MB 以下
    static let minBytes: Int64 = 1_000_000

    /// 这条 meting 结果像不像一首真歌（纯函数，CI 断言）
    static func looksLikeAudio(container: String, totalBytes: Int64) -> Bool {
        guard totalBytes >= minBytes else { return false }
        return ["mp3", "flac", "m4a", "ogg", "wav"].contains(container)
    }
}

struct MetingNeteaseAdapter: StreamSourceAdapter {
    let name = "meting 网易"
    let platform: MusicPlatform = .netease

    func resolve(song: Song, quality: QualityLevel) async throws -> StreamSource {
        let id = song.platformID.filter { $0.isNumber }
        guard !id.isEmpty else { throw APIError.parse("meting 网易：id 非法") }
        // meting 只给一条 320k 流，不认档位参数——请求无损时它仍是 320k，
        // 所以按实测标注（QualityFacts），不按请求标注。
        let stream = "https://api.qijieya.cn/meting/?server=netease&type=url&id=\(id)"
        guard let facts = await StreamVerifier.inspect(stream) else {
            throw APIError.httpStatus(0)
        }
        guard MetingStreamRules.looksLikeAudio(container: facts.container,
                                               totalBytes: facts.totalBytes) else {
            throw APIError.parse("meting 网易：不是音频（\(facts.container) / \(facts.totalBytes) B）")
        }
        let (q, fmt) = QualityFacts.of(facts, durationSec: song.durationSec)
        BackendHealth.shared.clear(name)
        return StreamSource(url: stream, backendName: name, platform: platform, quality: q,
                            format: fmt, note: "meting 直吐字节（实测标注）", directId: true,
                            kbps: QualityFacts.kbps(facts.totalBytes, song.durationSec),
                            totalBytes: facts.totalBytes, rangeOK: facts.rangeOK)
    }
}

// MARK: - 后端注册表
enum SourceRegistry {

    static let all: [StreamSourceAdapter] = [
        CyapiQQAdapter(),
        // 2026-11-21：落月恢复注册，但走的是 **v3** `/music/tencent/song/link`
        // （v2 `/v2/music/tencent/geturl` 恒回 code=503，v2.4.36 就是接错了这条）。
        // 它给真 320k/flac，但上游共享账号会风控（110001）→ 失败快、带冷却，只当机会性加分源。
        LuoyueQQAdapter(),
        GdstudioNeteaseAdapter(),
        OiapiNeteaseAdapter(),
        YaohuKuwoAdapter(),
        KuwoOfficialAdapter(),
        // 2026-11-21：酷我补两条独立取流器（老板"多条取流器"的初衷）
        //   · ikun：按 rid 直取，能给周杰伦整首 320k（官方 anti.s 只回提示音）
        //   · 星海：只给 FLAC，走 allowLossless 兜底 / 下载链
        IkunKuwoAdapter(),
        XinghaiKuwoAdapter(),
        // 2026-11-21：补两家"以前完全没有"的平台/独立域取流
        //   · 星海酷狗：zddyr `source=kg`，hash 直查。酷狗官方 playInfo 至今 errcode=1002 没有 url，
        //     这条是酷狗唯一的原生取流（320k 0.82–1.02s，flac 26–31MB）
        //   · meting 网易：qijieya 直吐字节，给网易一条与 gdstudio 完全不同域的活路
        XinghaiKugouAdapter(),
        MetingNeteaseAdapter(),
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

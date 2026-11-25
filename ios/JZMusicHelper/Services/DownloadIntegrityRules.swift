import Foundation

// MARK: - 下载落盘后的「身份 + 完整性」校验（2026-11-25）
//
// 事故（老板 21:29 录屏，23:0x 确认）：下载了黄霄雲《众》的"无损 FLAC"，
// 播放页红字写着「文件 3:17 · 曲目 3:35（差 18 秒）」——那份 FLAC 根本不是《众》，
// 是黄霄雲的**另一首歌**。它偏偏过了所有闸门：
//   · 字节校验在上游不给 Content-Length 时直接放行（`DownloadGuard.isComplete` 的 `expected > 0` 短路）；
//   · 文件名是我们自己用「歌手 - 歌名」拼的，所以"看起来"完全正确；
//   · 以前**没人拿"文件自己报的长度"和"曲目时长"对过一次**。
//
// 产品口径（老板 23:0x 拍板）：**宁缺勿错**——
// 拿不到可靠文件就标「无可靠源」，不落盘、不标"已下载"，绝不让一个错的音频进曲库。
//
// 这里只放**纯判定**（不读文件、不联网），CI 直接断言；读文件头在调用方做
// （`LocalAudioFacts.facts(url:)`）。
enum DownloadIntegrityRules {

    /// 文件自报长度与曲目时长的容差。
    ///
    /// 为什么是 1.5 秒：官方 FLAC 实测 **215.45s** vs 曲目 215.5s（差 0.05）；
    /// 而错的那份是 **197s**（差 18 秒）。跨平台同一条母带的差异通常 <1.5s，
    /// 所以这条线既不会误杀正常文件，也吃不下"另一首歌"。
    static let durationToleranceSec: Double = 1.5

    /// 落盘文件的自述
    struct Facts: Equatable {
        /// 嗅探出来的容器（mp3/flac/m4a/wav/ogg…；unknown = 认不出）
        let container: String
        /// 文件自己头里写的长度（nil = 解不出，不可信）
        let durationSec: Double?
        let bytes: Int64

        init(container: String, durationSec: Double?, bytes: Int64) {
            self.container = container
            self.durationSec = durationSec
            self.bytes = bytes
        }
    }

    enum Verdict: Equatable {
        /// 通过（带文件自报长度，落库后给播放页/行显示用）
        case ok(Double)
        /// 拒收（人话原因，直接当 `errorMessage`）
        case reject(String)
    }

    /// 已知能播的容器（与 `PlaybackCacheRules.isPlayableExtension` 同口径）
    static func isKnownContainer(_ c: String) -> Bool {
        ["mp3", "m4a", "flac", "wav", "ogg", "aac", "aif", "aiff", "caf"]
            .contains(c.lowercased())
    }

    /// 主判定（顺序即优先级：先看是不是音频，再看长度，再看体积，再看是不是这首）
    ///
    /// - Parameters:
    ///   - facts: 落盘文件的容器 / 自报长度 / 字节数
    ///   - displayedTitle / displayedSinger / displayedDurationSec: 列表上这首歌
    ///   - matchedName / matchedSinger: 这条源实际对应哪条候选（跨源补位时可能不是本歌的 id）
    ///   - expectedBytes: 取流阶段探到的预期体积（0 = 上游没给）
    static func check(facts: Facts,
                      displayedTitle: String, displayedSinger: String,
                      displayedDurationSec: Int,
                      matchedName: String?, matchedSinger: String?,
                      expectedBytes: Int64) -> Verdict {
        // ① 容器：认不出 = 不可信（宁可不要）
        guard isKnownContainer(facts.container) else {
            return .reject("文件头认不出音频容器（\(facts.container)），已删除")
        }
        // ② 文件自己的长度必须解得出来（"流式 FLAC 没写总长"就死在这一步）
        guard let fileSec = facts.durationSec, fileSec > 1 else {
            return .reject("文件里读不出可信长度，无法确认是不是这首，已删除")
        }
        // ③ 体积：上游给了预期就必须够（以前 expected=0 直接放行，等于没校验）
        if expectedBytes > 0,
           !DownloadGuard.isComplete(actual: facts.bytes, expected: expectedBytes) {
            return .reject("文件不完整（\(DownloadGuard.sizeText(facts.bytes)) / "
                           + "预期 \(DownloadGuard.sizeText(expectedBytes))），已删除")
        }
        // ④ 长度：这就是《众》的真正判据（3:17 vs 3:35）
        if displayedDurationSec > 0 {
            let diff = abs(fileSec - Double(displayedDurationSec))
            guard diff <= durationToleranceSec else {
                return .reject("文件只有 \(timeText(fileSec))、曲目 "
                               + "\(timeText(Double(displayedDurationSec)))"
                               + "（差 \(Int(diff.rounded())) 秒）—— 不是这首歌，已删除")
            }
        }
        // ⑤ 身份：来源候选的歌名必须对得上（老流程没记身份时，前面几条已经验过长度，放行）
        if let name = matchedName, !name.isEmpty {
            let displayed = Song.make(platform: .netease, platformID: "displayed",
                                      name: displayedTitle, singer: displayedSinger,
                                      album: "", duration: Double(displayedDurationSec),
                                      picURL: nil)
            let candidate = Song.make(platform: .netease, platformID: "source:\(name)",
                                      name: name, singer: matchedSinger ?? displayedSinger,
                                      album: "", duration: fileSec, picURL: nil)
            guard NameMatch.sameRecording(src: displayed, cand: candidate) else {
                return .reject("这条源其实是《\(name)》，不是《\(displayedTitle)》，已删除")
            }
        }
        return .ok(fileSec)
    }

    /// 秒 → `m:ss`（错误文案用，和播放页同一口径）
    static func timeText(_ sec: Double) -> String {
        let t = max(0, Int(sec.rounded()))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - 下载「判死名单」（2026-11-26，老板 ①）
//
// 事故（11-25 录屏 02:35 → 03:52）：
//   ① 02:35 《众》的无损下到 93% 才被判「文件只有 5:01、曲目 3:35——不是这首歌，已删除」；
//   ② 03:47 再点下载，同一个源又被排到"最高可得"（面板写「只有 无损 FLAC」）——
//      因为**下载侧根本没有"这条已经判死"的记忆**：播放侧有 `rejectedSourceURLs`，
//      但那只是进程内、per-song；下载重开一次就全忘了。
//
// 这里补上持久化的判死名单：同一个「歌 + 主机 + 容器 + 体积 + 码率」不再推荐。
// 为什么不用 URL 做键：这类 CDN 直链带 token，每次都变；体积+码率才是"同一份文件"的特征。
enum DownloadRejections {

    private static let key = "download_rejected_sources_v1"
    private static let ttl: TimeInterval = 7 * 24 * 3600
    private static let limit = 200

    private struct Entry: Codable {
        let fp: String
        let reason: String
        let at: Date
    }

    /// 「同一份文件」的指纹：URL 里的 host + 容器 + 体积 + 实测码率（token 不参与）
    static func fingerprint(url: String, format: String, totalBytes: Int64, kbps: Int64) -> String {
        let host = URL(string: url)?.host?.lowercased() ?? "-"
        return "\(host)|\(format.lowercased())|\(totalBytes)|\(kbps)"
    }

    static func fingerprint(_ src: StreamSource) -> String {
        fingerprint(url: src.url, format: src.format,
                    totalBytes: src.totalBytes, kbps: src.kbps)
    }

    static func isRejected(_ src: StreamSource) -> Bool {
        isRejected(fingerprint: Self.fingerprint(src))
    }

    static func isRejected(fingerprint fp: String) -> Bool {
        let now = Date()
        return load().contains { $0.fp == fp && now.timeIntervalSince($0.at) < ttl }
    }

    static func reject(_ src: StreamSource, reason: String) {
        reject(fingerprint: Self.fingerprint(src), reason: reason)
    }

    static func reject(fingerprint fp: String, reason: String) {
        var all = load().filter { Date().timeIntervalSince($0.at) < ttl }
        all.removeAll { $0.fp == fp }
        all.append(Entry(fp: fp, reason: reason, at: Date()))
        if all.count > limit { all = Array(all.suffix(limit)) }
        save(all)
    }

    /// 给下载面板显示用：这首歌有哪些源被判死过（最近一条原因）
    static func reasons() -> [String] { load().map(\.reason) }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rows = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return rows
    }

    private static func save(_ rows: [Entry]) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - 下全量之前先探头部（2026-11-26，老板 ⑩）
//
// 目标：把「下到 93% 才发现不是这首歌」提前到「下之前就知道」。
// 做法与限制（都是实测过的）：
//   · FLAC / WAV：STREAMINFO 就在文件头，Range 取前 256KB 就能解出总时长 → **可以硬拒**；
//   · MP3：只有 Xing/Info 带帧数时能解，否则解不出 → 不拦（交给落盘后的完整校验）；
//   · M4A：moov 有可能在文件**尾**，头里读不到 → 不拦；这里只试头部，尾巴留给下一轮。
// 拿不到就返回 nil（= 不知道，不阻塞下载）——宁可放过，不能误杀。
enum DownloadHeadProbe {

    struct Verdict {
        let ok: Bool
        let reason: String
        let durationSec: Double?
    }

    /// 与音频下载同一套头（部分 CDN 不带 Referer 直接 403）
    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 8
        r.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        r.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")
        r.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        return r
    }

    /// nil = 探不出来（不阻塞）；否则给出"能不能下"的结论
    static func check(_ src: StreamSource, song: Song) async -> Verdict? {
        guard let url = URL(string: src.url) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request(url)) else {
            return nil
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil   // 403/404 属于"这次拿不到"，不是"文件不对"
        }
        // 服务器不认 Range 时会回 200 + 整首（几十 MB）。那种情况我们不算数——
        // 宁可当"不知道"，也不拿一份"已经被完整下载"的字节去判（而且这次请求的钱已经花掉了，
        // 四个后端实测都认 Range、回 206，所以这条路基本不会走到）。
        guard http.statusCode == 206 else { return nil }
        guard data.count >= 256 else { return nil }
        let head = data.prefix(262_144)
        let container = StreamVerifier.sniffHead([UInt8](head.prefix(16)))
        guard let fileSec = MediaIndexRules.duration(head: Data(head), container: container,
                                                     totalBytes: src.totalBytes) else {
            return nil   // 头里没有可信长度（mp3 无 Xing / m4a 的 moov 在尾部）→ 不拦
        }
        guard song.duration > 1 else { return Verdict(ok: true, reason: "", durationSec: fileSec) }
        let diff = abs(fileSec - song.duration)
        guard diff <= DownloadIntegrityRules.durationToleranceSec else {
            return Verdict(ok: false,
                           reason: "文件头只有 \(DownloadIntegrityRules.timeText(fileSec))、曲目 "
                             + "\(DownloadIntegrityRules.timeText(song.duration))"
                             + "（差 \(Int(diff.rounded())) 秒）—— 不是这首歌，没下载",
                           durationSec: fileSec)
        }
        return Verdict(ok: true, reason: "", durationSec: fileSec)
    }
}

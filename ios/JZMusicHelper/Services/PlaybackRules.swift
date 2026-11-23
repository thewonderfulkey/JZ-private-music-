import Foundation

// MARK: - 播放模式
//
// 与 Android `PlayMode` 同口径，循环顺序：单曲循环 → 列表循环 → 随机播放 → **心动模式** → 单曲循环。
// 注意 SINGLE_LOOP 不是"放完停"，是**循环重播当前曲**。
//
// 心动模式（heartbeat，第四十一轮）：`queue` 变成"本次心动的会话队列"
// （已播 + 当前 + 即将播放），下一首由 `HeartbeatEngine` 按用户数据算出来再追加进去，
// 所以它的 next/previous 就是 **index ± 1**，不做取模、也不随机。
enum PlayMode: String, Codable, CaseIterable, Sendable {
    case singleLoop
    case listLoop
    case shuffle
    case heartbeat

    /// 界面文案
    var displayName: String {
        switch self {
        case .singleLoop: return "单曲循环"
        case .listLoop: return "列表循环"
        case .shuffle: return "随机播放"
        case .heartbeat: return "心动模式"
        }
    }

    /// SF Symbols
    var symbolName: String {
        switch self {
        case .singleLoop: return "repeat.1"
        case .listLoop: return "repeat"
        case .shuffle: return "shuffle"
        case .heartbeat: return "sparkles"
        }
    }

    /// 点一下换到下一档（单曲 → 列表 → 随机 → 心动 → 单曲）
    func cycled() -> PlayMode {
        switch self {
        case .singleLoop: return .listLoop
        case .listLoop: return .shuffle
        case .shuffle: return .heartbeat
        case .heartbeat: return .singleLoop
        }
    }
}

// MARK: - 播放规则（纯函数）
//
// 为什么单独抽出来：这些是"放完一首之后到底放哪首""什么算坏源""连跳几首要停"的判定，
// 改错了界面不会崩，只会表现为"随机老是重复同一首""明明能放却被跳过"。
// 抽成不依赖 AVFoundation 的纯函数后，CI 的 `logic-tests` 可以直接断言（`ios/SelfTest/main.swift`）。
enum PlaybackRules {

    /// 连跳上限（Android `AUTO_SKIP_MAX = 3`）：连续这么多首无源就停，别把整个队列烧光
    static let autoSkipLimit = 3

    /// 实际时长与曲目时长允许的误差。
    ///
    /// Android 原来是 5s，那条口径在 iOS 上误伤太多：同一首歌的另一个剪辑（多一段前奏/尾奏）
    /// 动辄差 10~20 秒，本身完全正常，却被判成坏源反复换源（观感就是"刚播就换源"）。
    /// r66 起放宽到 25s —— 真正的危险源（30 秒试听、别的歌）差得远不止 25s。
    static let durationToleranceSec: Double = 25

    /// 下一首的索引；nil = 没有可播的下一首（队列为空）
    ///
    /// - 单曲循环：还是当前这首
    /// - 列表循环：顺序取模，最后一首回到第 0 首
    /// - 随机：随机到一个**不等于当前**的索引（只有一首时就是它自己）
    /// - 心动：会话队列里已经排好了下一首（`HeartbeatEngine` 追加的），按 index+1 前进；
    ///   后面没有就是 nil（等引擎算出来再追加，绝不取模回到开头）
    ///
    /// `randomIn` 由调用方注入（测试里给确定性实现），范围语义同 `Int.random(in:)`。
    static func nextIndex(count: Int,
                          current: Int,
                          mode: PlayMode,
                          randomIn: (Range<Int>) -> Int) -> Int? {
        guard count > 0 else { return nil }
        switch mode {
        case .singleLoop:
            return min(max(current, 0), count - 1)
        case .listLoop:
            guard current >= 0 else { return 0 }
            return (current + 1) % count
        case .shuffle:
            if count == 1 { return 0 }
            var pick = randomIn(0..<count)
            // 不允许"随机到自己"（Android 同样处理）；撞上了就取下一个，保证一定前进
            if pick == current {
                pick = (pick + 1) % count
            }
            return pick
        case .heartbeat:
            let next = current + 1
            return next < count ? next : nil
        }
    }

    /// 上一首的索引；手点"上一首"时随机模式也要换一首（Android 同口径）
    static func previousIndex(count: Int,
                              current: Int,
                              mode: PlayMode,
                              randomIn: (Range<Int>) -> Int) -> Int? {
        guard count > 0 else { return nil }
        switch mode {
        case .singleLoop:
            return min(max(current, 0), count - 1)
        case .listLoop:
            guard current >= 0 else { return count - 1 }
            return (current - 1 + count) % count
        case .shuffle:
            return nextIndex(count: count, current: current, mode: .shuffle, randomIn: randomIn)
        case .heartbeat:
            let prev = current - 1
            return prev >= 0 ? prev : nil
        }
    }

    /// 时长校验：两边都已知且差超过 5s 才算"不是同一份音频"（任一方未知则不拦）
    static func durationMismatch(actual: Double, expected: Double) -> Bool {
        guard actual.isFinite, expected > 0, actual > 0 else { return false }
        return abs(actual - expected) > durationToleranceSec
    }

    /// 连续无源到上限就停（避免"搜出来 20 首全都放不出来"时无限跳）
    static func shouldStopAfterSkips(_ consecutiveSkips: Int) -> Bool {
        consecutiveSkips >= autoSkipLimit
    }

    /// 「这次点的就是正在放的那首」——此时**不该**重新解析、不该重头播（r63 老板反馈 ⑤）。
    ///
    /// 三个条件缺一不可：同一首歌、已经装上了播放项（不是上次解析失败留下的空壳）、
    /// 当前没有错误态（失败过的歌再点一次应该重试）。
    static func shouldReuseCurrentSong(currentID: String?, targetID: String,
                                       hasLoadedItem: Bool, hasError: Bool) -> Bool {
        guard let currentID, !currentID.isEmpty, !targetID.isEmpty else { return false }
        return currentID == targetID && hasLoadedItem && !hasError
    }

    /// 上限可配置版：设置里的「跳过上限」关掉自动跳歌时传 1
    static func shouldStopAfterSkips(_ consecutiveSkips: Int, limit: Int) -> Bool {
        consecutiveSkips >= max(1, limit)
    }

    /// 这一轮取流回来时，还是不是"最新那一轮"。
    ///
    /// 老板 2026-11-20 报的 bug：连着点 A → B → C，三路取流同时在跑，**谁先回来谁就起播**——
    /// 封面和歌词已经是 C，A 的请求迟到回来却把音频换成了 A。
    /// 每一轮取流开始时 +1 代次，回来先比一次：不是最新那轮就整个丢掉（不起播、不改状态行）。
    static func isCurrentLoad(token: Int, currentToken: Int) -> Bool {
        token == currentToken
    }

    /// 换曲前要不要先暂停当前这首（r71）。
    ///
    /// 老板："换曲的时候先暂停当前的歌曲，之前好好的，现在又没了这个功能。"
    /// 口径：**已经装上播放项就暂停**（不管是暂停中还是播放中，暂停是幂等的），
    /// 没有 item（第一次起播、刚被换源清空）则什么都不用做。
    /// 这一条以前是"解析完直接 replaceCurrentItem"，于是点下一首之后旧音频还会再唱 1~12 秒。
    static func shouldPauseBeforeSwitch(hasLoadedItem: Bool) -> Bool {
        hasLoadedItem
    }

    /// 同一首歌内最多换几条源（A6）。
    ///
    /// 老板 2026-11-20：「起播失败时在同一首歌内换下一条候选（保持进度、seek 回原位置），
    /// 全部失败才跳歌」。这里给一个上限，避免"这首的每一路都慢慢超时"把整个队列卡死在原地：
    /// 换满 3 条还不成，就按老口径跳歌并给一句人话。
    static let maxSameSongSwitches = 3

    /// 连续失败后的提示文案（口语、可执行，不甩代码）
    static func skipMessage(_ consecutiveSkips: Int) -> String {
        skipMessage(consecutiveSkips, limit: autoSkipLimit)
    }

    static func skipMessage(_ consecutiveSkips: Int, limit: Int) -> String {
        if shouldStopAfterSkips(consecutiveSkips, limit: limit) {
            return "连着 \(consecutiveSkips) 首都没有可用的播放源，先停在这里。换个关键词，或稍后再试。"
        }
        return "这首暂时没有可用的播放源，已跳到下一首（第 \(consecutiveSkips) 首）"
    }
}

// MARK: - 播放链条的档位口径（2026-11-20 老板定稿：在线播放 ≤320k，无损只用于下载）
//
// 口径来源：老板 2026-11-20 拍板「A. 在线播放降档 + 无损只用于下载」。
//   · 播放链固定 ≤320k，**FLAC 不进播放链**（哪怕它更好听——无损只给下载）；
//   · 播放链排名按**实测码率** 320 > 256 > 128；码率算不出的垫底（不知道就别拿它起播）；
//   · 下载链不动，仍是 无损 > 320 > 256 > 128（见 `DownloadResolver` 的 Score）。
//
// 为什么抽成纯函数：改错了不会崩，只会"明明有 320 却在放 128"或者"无损又溜回播放链"，
// 界面完全看不出来。CI 的断言（`ios/SelfTest/main.swift`）钉住这几个门槛。
enum PlaybackQualityRules {

    /// 播放链硬上限（kbps）。320k 的 mp3 实测常在 300~330 之间，所以门槛取"无损下界"而不是 320 整数。
    static let maxKbps: Int64 = 320

    /// 无损下界：**与 `QualityFacts` 共用同一个常量**——两边各写一个数，就会出现
    /// "界面标 320k、其实拿到 FLAC"（r120 那类事故）。
    static var losslessFloorKbps: Int64 { QualityFacts.losslessFloorKbps }

    /// 这条源能不能进播放链
    static func isPlayable(_ src: StreamSource) -> Bool {
        let fmt = src.format.lowercased()
        if fmt.contains("flac") || fmt.contains("wav") || fmt.contains("ape") { return false }
        if src.quality == .lossless { return false }        // 标着无损（哪怕码率算不出）也不进播放链
        if src.kbps >= losslessFloorKbps { return false }   // 容器认错但码率是无损量级
        return true
    }

    // MARK: 内容闸门（2026-11-21 老板报障的直接产物）

    /// 低于这个码率不可能是歌：酷我对受限歌统一回的那段 11.3s 提示音，算出来只有 4 kbps。
    /// 以前这条"能播"——`isPlayable` 只看「非无损 + 码率 < 601」，于是它被当成了有效源，
    /// 用户听到的是「当前音乐只在酷我最新手机端才能播放」。（181,521 B / 344s = 4 kbps）
    static let minPlausibleKbps: Int64 = 32

    /// 不是歌的东西：体积算不出码率、或码率量级明显不对、或命中已知占位文件的体积窗口
    static func isPlaceholder(_ src: StreamSource, songDurationSec: Int) -> Bool {
        guard src.totalBytes > 0 else { return false }   // 体积未知不在这里判（交给时长闸门）
        let kb = QualityFacts.kbps(src.totalBytes, songDurationSec)
        if kb > 0, kb < minPlausibleKbps { return true }
        // 已知占位文件的字节数是 181,521（酷我受限歌统一那段提示音，实测 md5 43fe5f64…）。
        // 给一个窗口是为了容 CDN 加头；同时要求"按这首歌算出来码率很低"，避免误伤短歌。
        let sizeWindow = (150_000...210_000).contains(src.totalBytes)
        return sizeWindow && (kb == 0 || kb < 96)
    }

    /// 一条源的「内容指纹」：体积 + 曲目时长。
    ///
    /// 2026-11-20 的事故：酷我对周杰伦回的那段 11.3s 提示音，每次调用都给一个**新的带 token 的 URL**，
    /// 所以只按 URL 去重的 `rejectedSourceURLs` 永远认不出"还是那段东西"。体积+时长能认出来。
    static func fingerprint(totalBytes: Int64, durationSec: Int) -> String {
        "\(totalBytes)-\(durationSec)"
    }

    /// 例外开关：允许无损进播放链。
    ///
    /// 老板 2026-11-21 定：周杰伦这类"酷我只有 FLAC"的歌必须能出声。
    /// 但它**只当最后一条可用源**用（`firstPlayable(allowLossless:)`），不参与常规排名、
    /// 也不在"自然播完"的关键路径上现拉——否则又会回到"播完卡住"（见下）。
    static let allowsLosslessPlayback = true

    /// 能不能真正拿来出声（任意档位）——播放链的最后一道可用性判定
    ///
    /// 顺序要紧：先过「加密包 / 占位音频」，再谈档位。反过来就会出现
    /// "占位音频满足 ≤320k → 被选中 → 播出一句人话"。
    static func isUsable(_ src: StreamSource, songDurationSec: Int,
                         allowLossless: Bool = false) -> Bool {
        guard !src.url.isEmpty else { return false }
        if StreamEncryptionRules.isEncrypted(src.url) { return false }
        if isPlaceholder(src, songDurationSec: songDurationSec) { return false }
        if isPlayable(src) { return true }
        guard allowLossless, allowsLosslessPlayback else { return false }
        let fmt = src.format.lowercased()
        if fmt.contains("flac") || fmt.contains("wav") { return true }
        return src.quality == .lossless || src.kbps >= losslessFloorKbps
    }

    /// 播放链择优：实测码率高的赢；同码率优先「按平台 ID 直连」的后端（身份更可靠）。
    /// 无损源一律不算"更好"——它在播放链里根本不该被选中。
    static func isBetter(_ a: StreamSource, than b: StreamSource?) -> Bool {
        guard isPlayable(a) else { return false }
        guard let b else { return true }
        guard isPlayable(b) else { return true }
        if a.kbps != b.kbps { return a.kbps > b.kbps }
        return a.directId && !b.directId
    }

    /// 已经在 320 档（实测 ≥296kbps）：起播后不用再找"更好的一档"，省掉一轮 15s 的完整排名。
    /// 320k 的 mp3 实测常在 300~330，门槛取 296 给编码误差留余量。
    static func isTopTier(_ src: StreamSource) -> Bool { src.kbps >= 296 }

    /// 播放页/设置页那句诚实标注（老板 2026-11-20 原话口径）
    static let label = "高品 320k（无损仅下载）"
}

// MARK: - 加密容器（QQ 的 .mgg / O4M-O8M）
//
// 实测（2026-11-20，星澜脚本的 QQ 后端）：320k 有概率回 `.mgg` —— HTTP 200、
// 11,698,595 B、Content-Range 也正常，但首字节是随机字节，任何第三方播放器都解不开。
// 以前这条判断只写在落月适配器里，cyapi 漏了；现在所有后端共用一个入口。
enum StreamEncryptionRules {
    static func isEncrypted(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains(".mgg") { return true }
        return ["/o4m", "/o6m", "/o8m"].contains { lower.contains($0) }
    }
}

// MARK: - 后端熔断：403 限流 / 风控不再每次播放都去撞
//
// 2026-11-20 实测：妖狐酷我连续请求几十次后回 `code=403 由于你多次频繁请求…`，
// 冷却 25 分钟仍未解封；而 App 每播一首会打它 2~4 次（firstPlayable + plan + 跨源），
// 越打越久解不了封。规则抽成纯函数，冷却时长进 SelfTest 断言。
enum BackendHealthRules {

    /// 从一次失败里算出要冷却多久（nil = 不用冷却，正常失败而已）
    static func cooldownSeconds(apiCode: Int?, message: String, httpStatus: Int?) -> TimeInterval? {
        if let code = apiCode {
            switch code {
            case 403: return 900          // 妖狐 / ikun：频繁请求被屏蔽
            case 110001: return 300       // 落月：共享账号被风控
            case 429: return 300
            case 503: return 120          // 上游系统错误（落月 v2 恒回这个）
            default: break
            }
        }
        if let status = httpStatus, status == 403 || status == 429 { return 300 }
        let m = message.lowercased()
        if m.contains("频繁") || m.contains("风控") || m.contains("屏蔽") || m.contains("too many") {
            return 900
        }
        return nil
    }

    /// 冷却是不是还没过（纯函数，便于断言）
    static func isCoolingDown(blockedUntil: TimeInterval?, now: TimeInterval) -> Bool {
        guard let until = blockedUntil else { return false }
        return until > now
    }
}

/// 进程内 + 磁盘（UserDefaults）的后端冷却表
final class BackendHealth: @unchecked Sendable {

    static let shared = BackendHealth()

    private let lock = NSLock()
    private var blockedUntil: [String: TimeInterval] = [:]
    private let defaultsKey = "jz_backend_cooldown_v1"

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] {
            blockedUntil = saved
        }
    }

    func isCoolingDown(_ name: String, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = blockedUntil[name] else { return false }
        if until <= now {
            blockedUntil[name] = nil     // 到期顺手清掉，不留脏数据
            return false
        }
        return true
    }

    func remaining(_ name: String, now: TimeInterval = Date().timeIntervalSince1970) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let until = blockedUntil[name], until > now else { return 0 }
        return until - now
    }

    func block(_ name: String, seconds: TimeInterval,
               now: TimeInterval = Date().timeIntervalSince1970) {
        guard seconds > 0 else { return }
        lock.lock()
        blockedUntil[name] = now + seconds
        let snapshot = blockedUntil
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: defaultsKey)
    }

    /// 成功一次就把冷却清掉（恢复得比预期快时不至于一直在黑名单里）
    func clear(_ name: String) {
        lock.lock()
        guard blockedUntil.removeValue(forKey: name) != nil else {
            lock.unlock()
            return
        }
        let snapshot = blockedUntil
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: defaultsKey)
    }

    /// 诊断/测试用
    func snapshot() -> [String: TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return blockedUntil
    }
}


//
// 老板 2026-11-20：「当前曲剩余 20–30 秒时后台解析下一首的源，播完直接 replaceCurrentItem + play()」。
// 窗口/条件抽成纯函数，CI 钉住——窗口改坏了不会崩，只会表现为"预取早了浪费流量/晚了赶不上"。
enum PrefetchRules {

    /// 当前曲剩多少秒时开始预取
    static let windowSec: ClosedRange<Double> = 20...30

    static func shouldPrefetch(remainingSec: Double,
                               hasItem: Bool,
                               isResolving: Bool,
                               mode: PlayMode) -> Bool {
        // 只有"自然连播"的两种模式值得预取：单曲循环重播同一份音频，心动模式有自己的预取和本地缓存
        guard mode == .listLoop || mode == .shuffle else { return false }
        guard hasItem, !isResolving else { return false }
        guard remainingSec.isFinite else { return false }
        return windowSec.contains(remainingSec)
    }
}

// MARK: - 车载自动播放（纯函数）
//
// 第四十轮（老板："加了车载 car play：连上车载蓝牙之后自动播放歌曲"）。
//
// 边界先说清：真正的 **CarPlay 界面**需要 Apple 单独批的 `com.apple.developer.carplay-audio`
// 权限（自签分发拿不到），所以这里做的是**车里"上车就响"这件事本身**：
// 监听音频路由变成车机 / 蓝牙音频，就自动接着上次的往下放。
//
// 为什么把判断抽成纯函数：真机上"连上 AirPods 也算蓝牙音频"这种边界改错了不会崩，
// 只会表现为"怎么突然自己放歌了"。CI 能把这张表钉住。
enum CarRouteKind: String, Sendable {

    /// 车机端口（有线 / 无线 CarPlay、USB 车机）
    case carAudio

    /// 蓝牙音频输出（车载蓝牙、蓝牙音箱、蓝牙耳机都走这一类）
    case bluetooth

    /// 有线 USB 音频（电脑、声卡）——不算车载
    case usb

    /// 其它（外放、耳机孔、AirPlay 等）
    case other
}

enum CarAudioRules {

    /// 连接后要不要自动起播：开关开着 + 当前没在播 + 这次的端口算"车里"
    static func shouldAutoplay(enabled: Bool, isPlaying: Bool, kind: CarRouteKind) -> Bool {
        guard enabled, !isPlaying else { return false }
        return kind == .carAudio || kind == .bluetooth
    }

    /// 端口名里有没有车的关键词（蓝牙端口名就是车机自己的名字，如 "BYD"、"Tesla Model 3"）。
    /// 只用于**文案/诊断**，不参与开合判断——蓝牙音频一律算（用户开的就是"上车自动播"）。
    static func looksLikeCarName(_ name: String) -> Bool {
        let n = name.lowercased()
        let keys = ["car", "auto", "车", "byd", "tesla", "bmw", "benz", "audi", "volvo",
                    "toyota", "honda", "nissan", "mazda", "vw", "ford", "chevrolet", "buick",
                    "hyundai", "kia", "lexus", "porsche", "geely", "chery", "haval", "nio",
                    "xpeng", "li auto", "lynk", "mg ", "roewe", "wuling", "hop"]
        return keys.contains { n.contains($0) }
    }
}

// MARK: - 上次没播完 → 接着放（纯函数）
//
// 第四十轮：车载连上时"接着上次没播完的接着放"。
// 三条边界：从开头几秒（还没进副歌）不算"没播完"；剩不到 8 秒的也不用续，
// 直接当"上一轮已经听完了"（交给热门歌单兜底），避免一上车就是一句尾奏。
enum PlaybackRestoreRules {

    /// 至少播过这么多秒才值得续播
    static let minResumePositionSec: Double = 3

    /// 距离结尾至少还要剩这么多秒才值得续播
    static let minRemainingSec: Double = 8

    static func shouldResume(positionSec: Double, durationSec: Double) -> Bool {
        guard positionSec.isFinite, durationSec.isFinite, durationSec > 0 else { return false }
        let position = max(0, positionSec)
        guard position >= minResumePositionSec else { return false }
        return durationSec - position >= minRemainingSec
    }
}


// MARK: - 总长与越界（纯函数，2026-11-23）
//
// 老板《半岛铁盒》：「拖动进度条之后跟时间条对不上，明明都唱完了还在唱」。
// 量出来：这份本地 FLAC 的**容器声明 5:19，实际能解出 ≥5:32**。进度条按声明走，
// 于是 5:19 就 100% / 剩余 -0:00，歌还要唱 13 秒。
//
// r66 也报过一模一样的话（代码里那条注释），当时的做法是"每拍把 duration +0.5"——
// 结果就是进度条永远 100%、剩余永远 -0:00，**这个症状正是那条兜底自己造出来的**。
// 现在改成：连续两拍越过声明总长 → 认定这一首已经播完（切下一首），并把量到的真实长度记下来，
// 下次起播进度条就准了。
enum TrackDurationRules {

    /// 起播时的总长：元数据与"以前量到的真实长度"取大的那个。
    /// 元数据偏短（坏头文件）时，第二次起播就靠这个把进度条摆正。
    static func initialDuration(metadata: Double, measured: Double?) -> Double {
        max(max(0, metadata.isFinite ? metadata : 0), max(0, measured ?? 0))
    }

    /// 越过声明总长多少秒算"越界"。留 2 秒余量：正常的元数据常常比音频短一两秒，
    /// 那种不该被当成"播完了"直接砍掉尾巴。
    static let overrunToleranceSec: Double = 2.0

    /// 连续几拍（0.5 秒一拍）才算确认，免得 seek 途中的一帧毛刺就切歌。
    static let overrunTicksToConfirm = 2

    static func isOverrun(currentTime: Double, duration: Double) -> Bool {
        guard duration > 0, currentTime.isFinite else { return false }
        return currentTime > duration + overrunToleranceSec
    }

    /// 越界确认后记下的"真实长度"：再多留 0.5 秒余量，下次起播才不会又贴边触发。
    static func measuredDuration(currentTime: Double) -> Double {
        guard currentTime.isFinite, currentTime > 0 else { return 0 }
        return currentTime + 0.5
    }

    /// 拖到最右端时不要 seek 到总长本身：AVPlayer 会 clamp 到末尾，容易直接触发结束/卡在 100%。
    /// 留最后 0.5 秒，让它自然收尾。
    static let tailGuardSec: Double = 0.5

    static func seekTarget(fraction: Double, duration: Double) -> Double {
        guard duration > 0, duration.isFinite else { return 0 }
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        return min(duration * f, max(0, duration - tailGuardSec))
    }
}
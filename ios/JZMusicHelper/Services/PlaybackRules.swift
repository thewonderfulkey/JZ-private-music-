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

// MARK: - 预取窗口（B1）
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


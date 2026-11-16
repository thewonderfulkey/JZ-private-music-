import Foundation

// MARK: - 播放模式
//
// 与 Android `PlayMode` 同口径，三态循环顺序一致：单曲循环 → 列表循环 → 随机播放 → 单曲循环。
// 注意 SINGLE_LOOP 不是"放完停"，是**循环重播当前曲**。
enum PlayMode: String, Codable, CaseIterable, Sendable {
    case singleLoop
    case listLoop
    case shuffle

    /// 界面文案（与 Android 一致）
    var displayName: String {
        switch self {
        case .singleLoop: return "单曲循环"
        case .listLoop: return "列表循环"
        case .shuffle: return "随机播放"
        }
    }

    /// SF Symbols（设计稿 §7.1）
    var symbolName: String {
        switch self {
        case .singleLoop: return "repeat.1"
        case .listLoop: return "repeat"
        case .shuffle: return "shuffle"
        }
    }

    /// 点一下换到下一档（Android：SINGLE_LOOP → LIST_LOOP → SHUFFLE → SINGLE_LOOP）
    func cycled() -> PlayMode {
        switch self {
        case .singleLoop: return .listLoop
        case .listLoop: return .shuffle
        case .shuffle: return .singleLoop
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

    /// 实际时长与曲目时长允许的误差（Android：>5s 判为劣质/伪装源并拒绝播放）
    static let durationToleranceSec: Double = 5

    /// 下一首的索引；nil = 没有可播的下一首（队列为空）
    ///
    /// - 单曲循环：还是当前这首
    /// - 列表循环：顺序取模，最后一首回到第 0 首
    /// - 随机：随机到一个**不等于当前**的索引（只有一首时就是它自己）
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

    /// 上限可配置版：设置里的「跳过上限」关掉自动跳歌时传 1
    static func shouldStopAfterSkips(_ consecutiveSkips: Int, limit: Int) -> Bool {
        consecutiveSkips >= max(1, limit)
    }

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

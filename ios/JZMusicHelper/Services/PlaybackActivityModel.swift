import Foundation

// MARK: - 锁屏 / 灵动岛上一帧要显示的内容
//
// 刻意不依赖 ActivityKit：这些是纯数据与纯函数，能被 CI 的 logic-tests（macOS + Foundation）
// 直接断言。真正的 `ActivityAttributes` 在 PlaybackActivity.swift 里，只做一层映射。
struct PlaybackActivitySnapshot: Codable, Hashable {
    var title: String
    var artist: String
    var lyricLine: String
    /// 0…1
    var progress: Double
    var isPlaying: Bool
    var updatedAt: Date
}

enum PlaybackActivityRules {

    /// 锁屏只有一行歌词的位置，超过就截断
    static let maxLyricLength = 24

    /// 播放进度（0…1）；时长未知或非法时给 0
    static func progress(current: Double, duration: Double) -> Double {
        guard duration > 0, duration.isFinite, current.isFinite else { return 0 }
        return min(max(current / duration, 0), 1)
    }

    /// 歌词行截断：保留 `limit - 1` 个字符再加省略号，中英文都按字符算
    static func shorten(_ line: String, limit: Int = maxLyricLength) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 1, trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// 刷新节流。
    ///
    /// 为什么必须节流：Live Activity 的刷新有系统预算，按 0.5 秒的播放进度去刷会把预算烧光，
    /// 结果就是锁屏那块"卡住不动"。所以：
    ///   · 内容变了（换歌 / 换歌词行 / 播放暂停）→ 最快 0.5 秒一次
    ///   · 只有进度在走 → 6 秒一次（进度条本来就只需要大致对齐）
    static func shouldRefresh(previous: PlaybackActivitySnapshot?,
                              next: PlaybackActivitySnapshot,
                              lastUpdate: Date,
                              now: Date) -> Bool {
        guard let previous else { return true }
        let elapsed = now.timeIntervalSince(lastUpdate)
        let contentChanged = previous.title != next.title
            || previous.lyricLine != next.lyricLine
            || previous.isPlaying != next.isPlaying
        return elapsed >= (contentChanged ? 0.5 : 6)
    }

    /// 活动过期时间：App 被系统杀掉后，锁屏上那块应该在 2 分钟后自己消失，而不是永远显示旧歌
    static func staleDate(from now: Date) -> Date {
        now.addingTimeInterval(120)
    }
}

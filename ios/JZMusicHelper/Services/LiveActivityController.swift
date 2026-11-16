import ActivityKit
import Foundation

// MARK: - Live Activity 的开关与更新
//
// 与播放引擎的关系：引擎每 0.5 秒（时间观察者）调一次 `sync`，这里负责三件事——
//   ① 决定要不要真的刷新（节流在 PlaybackActivityRules 里，纯函数、有断言）
//   ② 换歌时结束旧活动、开一个新的（Attributes 不可变，只能重开）
//   ③ 停止播放 / 没有歌时把活动收掉
//
// 全部失败都静默：Live Activity 是"锦上添花"，用户可能在系统设置里关掉了它，
// 或者机型不支持——这些都不该影响播放本身。
@MainActor
final class LiveActivityController {

    static let shared = LiveActivityController()

    private var activity: Activity<SongActivityAttributes>?
    private var currentSongID: String?
    private var lastSnapshot: PlaybackActivitySnapshot?
    private var lastUpdate = Date.distantPast

    private init() {}

    /// 引擎在每个状态变化点调用（幂等、可高频调用）
    func sync(song: Song?, isPlaying: Bool, currentTime: Double, duration: Double, lyric: String?) {
        // 用户在系统设置里关了实时活动，就什么都不做（不要报错、不要提示）
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        guard let song else {
            end()
            return
        }

        let snapshot = PlaybackActivitySnapshot(
            title: song.name,
            artist: song.singer,
            lyricLine: PlaybackActivityRules.shorten(lyric ?? ""),
            progress: PlaybackActivityRules.progress(current: currentTime, duration: duration),
            isPlaying: isPlaying,
            updatedAt: Date())

        // 换歌：Attributes 不可变，只能结束旧的、开新的
        if activity == nil || currentSongID != song.id {
            restart(song: song, snapshot: snapshot)
            return
        }

        let now = Date()
        guard PlaybackActivityRules.shouldRefresh(previous: lastSnapshot, next: snapshot,
                                                  lastUpdate: lastUpdate, now: now) else { return }

        lastSnapshot = snapshot
        lastUpdate = now
        let content = ActivityContent(state: SongActivityAttributes.ContentState(snapshot: snapshot),
                                      staleDate: PlaybackActivityRules.staleDate(from: now))
        let current = activity
        Task { await current?.update(content) }
    }

    /// 停止播放（用户点了暂停且要收掉活动时用；目前暂停仍保留活动，只是变灰）
    func end() {
        guard activity != nil else { return }
        let current = activity
        activity = nil
        currentSongID = nil
        lastSnapshot = nil
        lastUpdate = .distantPast
        Task { await current?.end(nil, dismissalPolicy: .immediate) }
    }

    private func restart(song: Song, snapshot: PlaybackActivitySnapshot) {
        let previous = activity
        activity = nil
        currentSongID = song.id
        lastSnapshot = snapshot
        lastUpdate = Date()

        Task {
            await previous?.end(nil, dismissalPolicy: .immediate)
            do {
                let attributes = SongActivityAttributes(songID: song.id)
                let content = ActivityContent(
                    state: SongActivityAttributes.ContentState(snapshot: snapshot),
                    staleDate: PlaybackActivityRules.staleDate(from: Date()))
                let started = try Activity.request(attributes: attributes,
                                                   content: content,
                                                   pushType: nil)
                self.activity = started
            } catch {
                // 系统拒绝（后台启动 / 达到上限 / 关闭了实时活动）都不影响播放
                self.activity = nil
                self.currentSongID = nil
            }
        }
    }
}

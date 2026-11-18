import Foundation

// MARK: - 上次播放快照
//
// 第四十轮（车载自动播放）：老板要"接着上次没播完的接着放"。
//
// iOS 上没有"进程退出前一定还能跑一段代码"的保证（用户上滑杀 App 只走 `willTerminate`，
// 而且不保证被调用），所以快照是**播放过程中定期写**的：每 10 秒一次 + 暂停/切歌/播完时各一次。
//
// 存什么：当前这首 + **从这首往后最多 50 首**（队列尾巴不存，快照要小）+ 播放位置 + 时长。
// 为什么不是整条队列：一屏搜索结果 20 首、收藏几百首，整条存进 UserDefaults 每次十几 KB，
// 而续播真正需要的只是"从这里往下还能接着放"。
struct PlaybackSnapshot: Codable {

    /// 当前这首（也是队列第一首）
    let song: Song

    /// 从当前这首往后的队列（第 0 个就是 `song`）
    let songs: [Song]

    /// 断点位置（秒）
    let positionSec: Double

    /// 这首歌的总长（秒）；断点判定用
    let durationSec: Double

    let savedAt: Date

    /// 上次是"播到结尾"结束的（这种情况不续播，交给热门歌单）
    let finished: Bool

    /// 队列（取不到就退化成单曲）
    var effectiveQueue: [Song] { songs.isEmpty ? [song] : songs }

    /// 能不能接着放：有位置、离结尾还够远、上一轮不是自然播完
    var canResume: Bool {
        guard !finished else { return false }
        return PlaybackRestoreRules.shouldResume(positionSec: positionSec,
                                                 durationSec: durationSec)
    }
}

/// 快照落盘（UserDefaults，键 `PlaybackSnapshotStore.key`）
///
/// 写成单例而不是塞进 PlayerEngine：`CarAudioAutoPlay` 在引擎之外读它，
/// 而引擎只是**写**的一方，两边不互相持有。
@MainActor
final class PlaybackSnapshotStore {

    static let shared = PlaybackSnapshotStore()

    static let key = "last_playback_snapshot_v1"

    /// 两次落盘的最小间隔（秒）：进度观察者 0.5 秒一跳，不能每跳都写盘
    private static let minInterval: TimeInterval = 10

    private let defaults = UserDefaults.standard
    private var lastWrite: Date = .distantPast
    private var lastSongID: String?

    private init() {}

    func save(_ snapshot: PlaybackSnapshot, force: Bool = false) {
        // 换歌一定立刻写（否则"刚切到下一首就杀进程"会留下上一首的断点）；
        // 同一首的进度最多 10 秒落一次盘（进度观察者 0.5 秒一跳，不能每跳都写）
        let songChanged = snapshot.song.id != lastSongID
        guard force || songChanged || Date().timeIntervalSince(lastWrite) >= Self.minInterval else {
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        lastWrite = Date()
        lastSongID = snapshot.song.id
        defaults.set(data, forKey: Self.key)
    }

    func load() -> PlaybackSnapshot? {
        guard let data = defaults.data(forKey: Self.key),
              let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
        lastWrite = .distantPast
        lastSongID = nil
    }
}

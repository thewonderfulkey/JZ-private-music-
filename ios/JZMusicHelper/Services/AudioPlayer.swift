import AVFoundation
import Foundation
import Observation
import UIKit

// MARK: - 播放引擎
//
// 职责：队列 + 播放模式 + 取流（复用网络层）+ 时长校验 + 无源跳歌 + 进度/缓冲 + 锁屏信息。
// 与 Android `PlayerManager` / `AppState` 的口径对齐，但实现换成 AVPlayer：
//   · 单后端 12s 超时、三级取流链、音质按「探测到的事实」挑（都在网络层，这里只调用）
//   · 播完按 PlayMode 推进（单曲循环是重播当前曲，不是停止）
//   · 实际时长与曲目时长差 >5s 判为坏源 → 拒播并换源
//   · 连续 3 首无源就停下并给一句人话

// MARK: - 播放诊断打点（老板 2026-11-20 拍板：长期保留，放「设置 → 播放诊断」）
//
// 为什么要有它：后台播完不换歌这类问题，**代码读一百遍也判不出**"到底卡在哪一秒、当时 App 是不是
// 已经进了后台"——只有带时间戳 + appState 的现场记录能定案。所以这里做一个 200 条的环形缓冲，
// 只记 5 个关键点（didPlayToEnd / goTo / resolve 起止 / item ready / play），开销可以忽略。
//
// 用 NSLock + 快照而不是 @Observable：写点的人都在主线程，读它的是设置页里一个轮询刷新的列表，
// 走锁比把整个引擎拖进观察链更省事，也不会因为"在诊断页上打字"影响播放。
struct PlaybackTraceEntry: Identifiable {
    let id = UUID()
    let at: Date
    let stage: String
    let appState: String
    let note: String
}

final class PlaybackTrace: @unchecked Sendable {

    static let shared = PlaybackTrace()

    private let lock = NSLock()
    private var buffer: [PlaybackTraceEntry] = []
    /// 只留最近 200 条：一次连播 3 首大约 40 条，够倒查好几轮
    private static let limit = 200

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    /// 记一条。`appState` 由这里自己取，调用点不用关心自己跑在什么状态里。
    @MainActor
    func log(_ stage: String, _ note: String = "") {
        let entry = PlaybackTraceEntry(at: Date(), stage: stage,
                                       appState: Self.appStateText(), note: note)
        lock.lock()
        buffer.append(entry)
        if buffer.count > Self.limit { buffer.removeFirst(buffer.count - Self.limit) }
        lock.unlock()
        // 2026-11-21：同时写进 `诊断/trace.log`。崩溃时内存里的 200 条会一起消失，
        // 落盘之后至少能看到"崩之前最后在做什么"（信号崩溃没有栈时这是唯一线索）。
        CrashReporter.trace(Self.line(entry))
        #if DEBUG
        print("[PlaybackTrace] \(Self.line(entry))")
        #endif
    }

    func snapshot() -> [PlaybackTraceEntry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }

    static func line(_ e: PlaybackTraceEntry) -> String {
        "\(stamp.string(from: e.at))  \(e.appState)  \(e.stage)  \(e.note)"
    }

    @MainActor
    private static func appStateText() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "前台"
        case .inactive: return "未激活"
        case .background: return "后台"
        @unknown default: return "未知"
        }
    }
}

@MainActor
@Observable
final class PlayerEngine {

    // MARK: 对外状态

    private(set) var queue: [Song] = []
    private(set) var index: Int = -1
    private(set) var currentSong: Song?
    private(set) var source: StreamSource?

    /// 起播后台换源（先粗后精）：同一首只换一次，换曲时取消
    private var upgradeTask: Task<Void, Never>?
    private var upgradedSongID: String?

    private(set) var isPlaying = false
    private(set) var isResolving = false
    /// 状态行（解析中 / 音源信息 / 跳歌提示）
    private(set) var statusText: String?
    /// 错误行（无源、播放失败）
    private(set) var errorText: String?

    private(set) var currentTime: Double = 0
    /// 总长：**起播时按文件头定一次，之后冻结**（2026-11-24）。
    ///
    /// 老板拿 VLC 对照过：《不凡2024》就是 4:12 —— 我本地把这个文件挖到底也是这样
    /// （48kHz/24bit，STREAMINFO total_samples=12,102,400 → 252.133s，解码出来一模一样的 252.133s）。
    /// 以前这里会被"播放器后来报的值 / 我们自己量出来的值"反复覆盖，一拖进度条总长就变，
    /// 这就是「拖到哪都不对」的根。锁一次、谁都不许再改。
    private(set) var duration: Double = 0
    /// 总长是否已被文件头锁定（锁上之后谁都不许改）
    private var durationLocked = false
    /// 这个总长是不是**有证据的**（本地精确时长 / 完整落盘的缓存文件 / 索引校验通过）。
    ///
    /// 2026-11-25：只有它为 true 才允许"到点收尾"和显示精确百分比。
    /// 在线流那个数是 AVFoundation 的估算，拿它判播完就会出现"歌没唱完自己切下一首"。
    private var durationVerified = false
    /// 当前这首的缓存会话（走字节层时非空）——用来"断了续拉"，不再偷偷换源
    private var cacheSession: CacheSession?
    /// 字节层没跑起来时已经回退过一次（本次运行不再尝试，避免来回抖）
    private var cacheFallbackUsed = false
    /// 越过声明总长已经判过"播完"（防止同一首重复触发切歌）
    private var endGuardFired = false

    /// 精确播放位置（秒）：直接向 AVPlayer 取，供逐字歌词按 30fps 推进使用。
    /// 常规 UI 仍用 `currentTime`（0.5 秒一次的时间观察者），避免全页高频重绘。
    var preciseTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : currentTime
    }

    /// 进度条 / 时间标签显示用的位置——**必须和歌词用同一个时钟**。
    ///
    /// 为什么不能直接用 `currentTime`：seek 之后 `currentTime` 先被设成目标，但 0.5 秒一次的
    /// 时间观察者随后会把播放头**尚未落地时的旧值**写回来（录屏里表现为：点歌词跳到 1:49，
    /// 标签却回到 1:20；拖到 1:46，标签对而高亮是 0:41）。标签和歌词各自用一套时间，
    /// 用户看到的就永远是"歌词不准"。
    ///
    /// 现在两边都走 `LyricsUXRules.seekClockSource`：seek 未落地用目标位置，落地（±1.2s）或
    /// 窗口到期用真实位置。这样"标签显示的时间"和"高亮那一行"在任何时刻都对得上。
    var displayTime: Double {
        guard let optimistic = seekOptimistic else { return currentTime }
        let rawMs = Int(preciseTime * 1000)
        let source = LyricsUXRules.seekClockSource(
            positionMs: rawMs,
            targetMs: optimistic.targetMs,
            optimisticExpired: Date() >= optimistic.until)
        return source == .useTarget ? Double(optimistic.targetMs) / 1000 : currentTime
    }

    /// 进度条（含迷你条那条 2pt 细线）用的比例：跟着 `displayTime` 走
    var displayProgress: Double {
        guard duration > 0 else { return 0 }
        return min(max(displayTime / duration, 0), 1)
    }

    // 歌词（由 LyricsService 取，酷我官方优先、失败回退 LDDC）
    private(set) var lyrics: [LyricLine] = []
    private(set) var lyricsSource: String = ""
    private(set) var lyricIndex: Int = -1

    /// 该被滚到屏幕中间的那一行（比 `lyricIndex` 早 `LyricsUXRules.scrollLeadMs`）。
    ///
    /// r65 老板："歌词现在统一都是滚动晚了一些"——高亮是准的，晚的是滚动动画。
    /// 播放页用 `lyricIndex` 决定哪一行白字，用这个决定 `scrollTo` 滚到哪一行。
    private(set) var lyricScrollIndex: Int = -1

    /// 歌词判定用的位置（毫秒）= 精确播放位置 + **这首自己的**偏移。
    ///
    /// 为什么要 `preciseTime` 而不是 0.5 秒才更新一次的 `currentTime`：
    /// 之前高亮用的是时间观察者里的 currentTime，最坏情况整整晚半秒——表现出来就是"唱到下一句了，上一句还亮着"。
    /// 25Hz 的专用 ticker 把这个误差压到 40ms 内。
    ///
    /// r71：偏移改成**按单曲**取（`SettingsStore.offsetMs(forSong:)`）。以前读的是全局一个数，
    /// 为了对齐某一首调出来的偏移会把其它所有歌一起推走。
    var lyricPositionMs: Int { Int(preciseTime * 1000) + lyricOffsetMs }

    /// 当前这首实际生效的歌词偏移（毫秒）
    var lyricOffsetMs: Int {
        SettingsStore.shared.offsetMs(forSong: currentSong?.id)
    }

    /// 每次跳转 +1。歌词面板监听它，跳完强制重排一次（r68：快进/快退后滚动不准）
    private(set) var seekNonce: Int = 0

    /// seek 之后的**乐观窗口**：窗口内用"目标位置"推歌词（画面不倒退），
    /// 窗口一到就改用播放头真实位置（宁可跳一下，也绝不冻住）。
    ///
    /// 历史：r76 写死 0.7 秒（太短，远端流还没落地就被旧位置拽回上一句）；
    /// r77 改成"等追上目标才解，兜底 10 秒"——结果远端流的 seek 完成回调经常不回来，
    /// 高亮/滚动整整冻 10 秒（老板 r85："一跳就瞬间对不上，滚动时间也不对"）。
    /// 第二十二轮：窗口上限 **1.5 秒**，并且**永远给出一个位置**（见 `LyricsUXRules.seekClockSource`），
    /// 播放头一旦落到目标 ±1.2 秒内立刻切回真实位置。规则与歌曲无关，所以所有歌表现一致。
    private var seekOptimistic: (targetMs: Int, until: Date)?
    /// 每次 seek +1：完成回调回来时如果已经不是最新那次，直接丢掉
    private var seekToken: Int = 0

    /// 取流代次：每次"该放哪一首"变化（点歌、切歌、同曲换源、解析重试）时 +1。
    ///
    /// 为什么必须有（老板 2026-11-20 报的 bug）：连着点 A → B → C 时三路取流同时在跑，
    /// **谁先回来谁就起播**——界面已经在显示 C 的封面和歌词，A 的请求迟到回来却把音频换成了 A。
    /// 现在每一轮取流记住自己的代次，回来先核对：不是最新那一轮就整个丢掉（不改状态行、不起播）。
    private var loadToken: Int = 0
    /// 正在跑的那一轮取流。新一轮开始时取消上一轮，旧请求不必再白等网络。
    private var loadTask: Task<Void, Never>?

    /// 点某一句歌词跳转后"还没唱到的那一行"。播放头走到这一行的时间之前，高亮与滚动都钉在它上面。
    ///
    /// 为什么需要：`AVPlayer.seek` 真机上常落到目标**之前**几百毫秒（关键帧对齐），
    /// 而 `indexAt` 是「行时间 ≤ 位置」，早 1ms 就推成上一句 —— 于是"点下去是对的、
    /// 下一拍又退回上一句"，正是老板反复提的"用歌词快进/后退之后就不准了"。
    /// 规则见 `LyricsCleaning.lyricSeekHoldDecision`（纯函数，CI 有断言），与歌曲无关。
    private var pendingLyricLine: Int?

    /// 已确认放不出来的歌（搜索结果里会被隐藏，与 Android 的 deadSongKeys 同口径）。
    ///
    /// 2026-11-20 老板拍板（A5）：**不再往里写**。单条源失败 ≠ 整首歌没源——
    /// 写进来会让这首歌在搜索结果里被永久隐藏，而它换一条源其实是能放的。
    /// 保留这个属性只为兼容视图层的过滤口径（现在恒为空）。
    private(set) var deadSongKeys: Set<String> = []
    private(set) var isLoadingLyrics = false
    var hasLyrics: Bool { !lyrics.isEmpty }
    var currentLyricLine: LyricLine? {
        guard lyricIndex >= 0, lyrics.indices.contains(lyricIndex) else { return nil }
        return lyrics[lyricIndex]
    }
    /// 已缓冲到的位置（进度条上那条浅色带）
    private(set) var bufferedTime: Double = 0

    /// 播放模式（持久化，键名与 Android 一致：`play_mode`）
    ///
    /// 切换统一走 `didSet`：进/出心动模式必须同步给引擎（否则从收藏页点「随机播放」
    /// 这种直接赋值的路径会绕过 `setMode`，心动规划在后台继续跑）。
    var mode: PlayMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.keyMode)
            if oldValue != mode { syncHeartbeatMode() }
        }
    }

    /// 音质偏好（持久化，键名 `quality`）。
    ///
    /// 第四十轮：设置页不再暴露这一项——老板口径是"默认就是最高音质，拿不到再逐级往下降"。
    /// 这里仍保留这个值（下载页/诊断要看"我在按哪一档取"），初始化恒为无损；
    /// 真正的降档由 `SourcePicker.score` 完成（无损 > 高品 > 标准，同分优先直连后端）。
    var quality: QualityLevel {
        didSet { defaults.set(quality.rawValue, forKey: Self.keyQuality) }
    }

    // MARK: 内部

    private let player = AVPlayer()

    /// 心动模式（选歌 + 预取 + 负反馈）。播放器只负责"放"，它只负责"选"。
    /// 放在 init 里显式建（而不是属性默认值）：`@MainActor` 类型在属性默认值里初始化，
    /// 在部分 Swift 版本会被判成"nonisolated 上下文里初始化主线程隔离类型"。
    let heartbeat: HeartbeatEngine

    /// 播放页要显示的心动状态（透传，避免视图直接摸引擎内部）
    var heartbeatReason: String { heartbeat.reason }
    var heartbeatNotice: String? { heartbeat.notice }
    var isHeartbeatPlanning: Bool { heartbeat.isPlanning }
    var heartbeatUpcoming: [HeartbeatEngine.Pick] { heartbeat.upcoming }

    private let defaults = UserDefaults.standard
    private static let keyMode = "play_mode"
    private static let keyQuality = "quality"

    private var timeObserver: Any?
    private var lyricTicker: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    /// `item.duration` 的观察（远端流要读一会儿头才知道总长，可能在 readyToPlay 之后才有效）
    private var durationObservation: NSKeyValueObservation?

    private var consecutiveSkips = 0
    /// 被判为坏源（时长不符 / 放不出来）的 URL，换源时跳过，避免同一首歌反复撞同一条
    private var rejectedSourceURLs: Set<String> = []
    /// 坏源的**内容指纹**（体积+时长）：占位提示音每次都是新 URL，只按 URL 记永远认不出来
    private var rejectedFingerprints: Set<String> = []
    /// 续播断点：等这一条播放项 ready 之后再 seek（见 `play(queue:startAt:positionSeconds:)`）
    private var pendingRestoreSeconds: Double?

    /// 心动模式预取下来的本地文件（切歌那一秒直接用，不再走网络）
    private var pendingLocal: (songID: String, url: URL)?

    /// 心动模式已经解析好的流地址（没来得及下载时用，省掉再解析一遍的 1-8 秒）
    private var pendingStream: (songID: String, url: String)?

    // MARK: 下一首预取（B1）/ 跨曲取源的后台任务（B2）/ 自愈状态（B3）

    /// 播放链档位：**固定 320k**。无损只用于下载（老板 2026-11-20 定稿）。
    /// 注意与 `quality`（下载默认档，恒无损）分工，两者不要混用。
    static let playbackQuality: QualityLevel = .high

    /// 预取任务（当前曲剩 20~30 秒时把下一首的源解析好）
    private var prefetchTask: Task<Void, Never>?
    /// 正在/已经预取过的那首（同一首不重复解析）
    private var prefetchSongID: String?
    /// 已经"定下来"的下一首。随机模式下预取和真正换曲**必须**是同一个下标，
    /// 否则预取的源对不上、等于白跑一趟（`goTo` 会按 songID 校验，对不上就重新解析）。
    private var plannedNext: (index: Int, songID: String)?
    /// 跨曲取源期间的后台任务：让系统多给 30 秒，别在"没声音的空档"里把进程挂起
    private var resolveBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// 用户自己按的暂停：回前台自愈时不能把这当成"卡住"（否则用户暂停了会被自动放起来）
    private var userPaused = false
    /// 被来电/闹钟打断：恢复交给 interruption 回调，自愈不要抢跑
    private var interrupted = false
    /// 同一首歌内已经换过几条源（A6）：换满 `PlaybackRules.maxSameSongSwitches` 才允许跳歌
    private var sameSongSwitches = 0

    /// 最近一次主动切歌的时间：切歌后 1.2 秒内收到的"播完"一定是上一首的迟到通知，必须忽略。
    /// （老板录屏：「淋雨一直走」刚起播就被切走，就是旧 item 的 didPlayToEnd 迟到了）
    private var lastAdvanceAt = Date.distantPast

    /// 进入心动模式时的队列下标：它之后的才是"心动自己追加的歌"。
    /// 「上一首」之后再按「下一首」要靠它回到刚才那首，而不是在旧歌单里往下走。
    private var heartbeatStartIndex = -1

    var hasCurrentSong: Bool { currentSong != nil }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    // MARK: 生命周期

    /// 系统面（音频会话 / 远程命令 / 进度观察）推迟到第一次真正播放时再装配
    /// （见 `attachSystemIfNeeded`），这样 View 里创建引擎只付一个 UserDefaults 读取的代价。
    init() {
        let store = UserDefaults.standard
        let savedMode = store.string(forKey: Self.keyMode).flatMap(PlayMode.init(rawValue:))
        mode = savedMode ?? .listLoop
        // 第四十轮：音质不再是设置项。恒从最高档起取，拿不到由取流器逐级下降
        // （老用户存过的低档值一并忽略，不再把"以前调过 128k"带着走）。
        quality = .lossless
        heartbeat = HeartbeatEngine()
        // 第 44 轮：元数据写回的唯一广播口（`MetadataWriter` 发，这里收）。
        // 不直接持有 DownloadManager：播放器不该依赖下载库，反过来也一样。
        NotificationCenter.default.addObserver(
            forName: .songMetadataUpdated, object: nil, queue: .main) { [weak self] note in
                guard let song = note.object as? Song else { return }
                MainActor.assumeIsolated { self?.applySongMetadata(song) }
            }
    }

    /// 元数据写回（第 44 轮）：队列里那一份 + 当前这首一起换。
    ///
    /// 为什么必须有这一步：老板明确要求"不许出现列表改了、播放页还是旧的"。
    /// 播放页读的是 `currentSong`、播放列表读的是 `queue`，两者各存一份 Song 副本。
    /// 歌名/歌手真变了就连锁屏信息和歌词一起刷（旧的词是按旧名字取的，留着就是错的）。
    func applySongMetadata(_ song: Song) {
        for i in queue.indices where queue[i].id == song.id {
            if queue[i].name != song.name || queue[i].singer != song.singer
                || queue[i].album != song.album || queue[i].picURL != song.picURL
                || queue[i].meta != song.meta {
                queue[i] = song
            }
        }
        guard let current = currentSong, current.id == song.id else { return }
        let renamed = current.name != song.name || current.singer != song.singer
        currentSong = song
        // 锁屏/灵动岛：`NowPlayingCenter` 的封面判重带 coverRevision，换图会自己重取
        updateNowPlaying()
        if renamed { prepareLyrics(for: song) }
    }

    private var systemAttached = false

    /// 首次播放前把锁屏/远程命令/进度观察装起来（幂等）
    private func attachSystemIfNeeded() {
        guard !systemAttached else { return }
        systemAttached = true
        NowPlayingCenter.shared.attach(engine: self)
        installTimeObserver()
        startLyricTicker()
    }

    // MARK: 播放入口

    /// 单曲播放（搜索结果、识曲结果、歌单里点一首）
    func playSingle(_ song: Song) {
        play(queue: [song], startAt: 0)
    }

    /// 以给定队列起播（搜索结果的"整列当队列"、收藏的"播放全部"）
    ///
    /// r63（老板反馈 ⑤）：点的是**正在播的这首**时不再重新请求、不再重头播——
    /// 只把播放列表换成这次的整列，然后打开播放页。原来同一点击会走整条取流链，
    /// 表现为"切回去了、转圈、从头开始"。
    func play(queue songs: [Song], startAt start: Int) {
        guard !songs.isEmpty else { return }
        attachSystemIfNeeded()
        let target = min(max(start, 0), songs.count - 1)
        if PlaybackRules.shouldReuseCurrentSong(currentID: currentSong?.id,
                                                targetID: songs[target].id,
                                                hasLoadedItem: player.currentItem != nil,
                                                hasError: errorText != nil) {
            adoptQueue(songs, at: target)
            return
        }
        // 上一首到此为止：把"听了多久"结算掉（心动模式的负反馈与质量分都靠它）
        heartbeat.trackEnded(listened: preciseTime, completed: false)
        stopCurrentForSwitch()
        queue = songs
        index = target
        currentSong = songs[target]
        rejectedSourceURLs.removeAll(); rejectedFingerprints.removeAll()
        consecutiveSkips = 0
        sameSongSwitches = 0
        plannedNext = nil
        prefetchSongID = nil
        shuffleHistory.reset()   // 换了一列歌：随机历史作废
        resetProgress()
        prepareLyrics(for: songs[target])
        syncHeartbeatSeed(songs[target])
        beginResolveBackgroundTask()
        beginLoad()
    }

    /// 心动模式下用户手点了别的歌：种子跟着换（网易云同款），待播重排。
    private func syncHeartbeatSeed(_ song: Song) {
        guard mode == .heartbeat else { return }
        // 换了一整列歌：从这一列的最后一个下标之后才算"心动自己追加的"
        heartbeatStartIndex = queue.count - 1
        if heartbeat.isActive {
            heartbeat.adoptSeed(song)
        } else {
            heartbeat.activate(seed: song)
        }
    }

    /// 从"上次断点"续播（车载自动播放用）：队列 + 起始位置一起给。
    ///
    /// 位置要等播放项真的 ready 才能 seek（远端流刚 replace 时 `duration` 还是 0），
    /// 所以这里只记 `pendingRestoreSeconds`，由 `wire(item:...)` 的 readyToPlay 分支落地。
    func play(queue songs: [Song], startAt start: Int, positionSeconds: Double) {
        guard !songs.isEmpty else { return }
        attachSystemIfNeeded()
        let target = min(max(start, 0), songs.count - 1)
        heartbeat.trackEnded(listened: preciseTime, completed: false)
        stopCurrentForSwitch()
        queue = songs
        index = target
        currentSong = songs[target]
        rejectedSourceURLs.removeAll(); rejectedFingerprints.removeAll()
        consecutiveSkips = 0
        sameSongSwitches = 0
        plannedNext = nil
        prefetchSongID = nil
        shuffleHistory.reset()   // 换了一列歌：随机历史作废
        resetProgress()
        pendingRestoreSeconds = positionSeconds.isFinite ? max(0, positionSeconds) : 0
        prepareLyrics(for: songs[target])
        syncHeartbeatSeed(songs[target])
        beginResolveBackgroundTask()
        beginLoad()
    }

    /// 上次播放快照（车载连上时"接着上次没播完的接着放"读它）
    ///
    /// - Parameter finished: 是否"自然播到结尾"结束（这种不算没播完，下次交给热门歌单）
    func flushSnapshot(finished: Bool = false, force: Bool = false) {
        guard let song = currentSong else { return }
        let tail: [Song]
        if queue.indices.contains(index) {
            tail = Array(queue[index...].prefix(50))
        } else {
            tail = [song]
        }
        let total = duration > 0 ? duration : Double(song.durationSec)
        let snapshot = PlaybackSnapshot(song: song,
                                        songs: tail,
                                        positionSec: max(0, currentTime),
                                        durationSec: total,
                                        savedAt: Date(),
                                        finished: finished)
        PlaybackSnapshotStore.shared.save(snapshot, force: force || finished)
    }

    /// 同一首歌再次被点：只换列表，不动正在放的音频/进度/歌词
    private func adoptQueue(_ songs: [Song], at newIndex: Int) {
        queue = songs
        index = newIndex
        // currentSong 不变（同一首），进度、歌词、音源全部保留
        updateNowPlaying()
    }

    func toggle() {
        guard currentSong != nil else { return }
        attachSystemIfNeeded()
        // r71：正在换曲解析时不要把上一首又播起来（那时 currentItem 还是旧的）
        //
        // B3（老板 2026-11-20）：但也不能像以前那样直接 return —— 后台被挂起过之后，
        // 用户回到前台点播放，`isResolving` 可能还挂着，原来这一下等于"点了没反应"。
        // 现在改成：没在出声就再踢一次解析（解析是幂等的，重复调用只会多一次候选并行）。
        if isResolving {
            if !isPlaying {
                PlaybackTrace.shared.log("toggle", "解析中重试")
                beginLoad()
            }
            return
        }
        if isPlaying {
            player.pause()
            isPlaying = false
            userPaused = true
            // 暂停时落一次快照：车载连上要"接着放"，断点就在这一下
            flushSnapshot(force: true)
        } else if player.currentItem != nil {
            player.play()
            isPlaying = true
            userPaused = false
        } else {
            userPaused = false
            beginLoad()
            return
        }
        updateNowPlaying()
    }

    /// 随机播放的"来过这里"记录（2026-11-24）：上一首要回到刚才那首，不是再随机一首
    private var shuffleHistory = ShuffleHistory()

    /// 下一首（用户点的，或播完自动推进）
    func nextTrack() {
        guard !queue.isEmpty else { return }
        if mode == .heartbeat {
            // 用户按的"下一首"= 一次"跳过"，<30 秒算负反馈（写进事件，画像自己会用）
            heartbeat.trackEnded(listened: preciseTime, completed: false)
            // 回来过（上一首 → 下一首）就走心动自己追加过的那一首，而不是再算一首新的
            let queuedNext = index + 1
            if queuedNext < queue.count, queuedNext > heartbeatStartIndex {
                goTo(queuedNext)
                return
            }
            if let pick = heartbeat.takeNext() {
                playHeartbeat(pick: pick)
            } else {
                planAndPlayHeartbeat()
            }
            return
        }
        // 随机播放：刚才按过"上一首"的话，先回到原来那条线（A→B→返回A，再按下一首应该回 B）
        if mode == .shuffle, let fwd = shuffleHistory.stepForward(from: index) {
            goTo(fwd, recordHistory: false)
            return
        }
        guard let next = PlaybackRules.nextIndex(
            count: queue.count, current: index, mode: mode,
            randomIn: { Int.random(in: $0) }) else { return }
        goTo(next)
    }

    func previousTrack() {
        guard !queue.isEmpty else { return }
        // 随机播放：回到**真的刚放过的那一首**（不是再随机一首）
        if mode == .shuffle {
            guard let prev = shuffleHistory.stepBack(from: index) else {
                statusText = "已经是这次随机的第一首"
                return
            }
            goTo(prev, recordHistory: false)
            return
        }
        guard let prev = PlaybackRules.previousIndex(
            count: queue.count, current: index, mode: mode,
            randomIn: { Int.random(in: $0) }) else { return }
        goTo(prev)
    }

    func cycleMode() {
        mode = mode.cycled()
        statusText = mode.displayName
        shuffleHistory.reset()   // 换了模式：随机历史作废
    }

    /// 直接指定播放模式（播放页菜单里选某一档）
    func setMode(_ newMode: PlayMode) {
        guard mode != newMode else { return }
        mode = newMode
        statusText = newMode.displayName
        shuffleHistory.reset()
        updateNowPlaying()
    }

    /// 进/出心动模式：进去就以当前这首为种子排下一首，出来就停掉规划。
    private func syncHeartbeatMode() {
        if mode == .heartbeat {
            // 原有队列的最后一个下标：它之后才是心动自己追加的歌
            heartbeatStartIndex = queue.count - 1
            heartbeat.activate(seed: currentSong)
        } else {
            heartbeatStartIndex = -1
            heartbeat.deactivate()
        }
    }

    /// 绝对位置跳转（秒）。所有跳转（进度条拖动 / 点歌词 / 无障碍调整）都走这里，
    /// 不再各自乘一遍 `duration`——`duration` 一旦与实际音频有毫秒级差，乘除会把误差放大。
    ///
    /// 第二十二轮：这里只负责"把 seek 发出去 + 记下目标 + 立刻把高亮放到目标那一行"，
    /// 之后由 `updateLyricIndex()` 用乐观窗口 + 真实位置接管（见 `seekOptimistic`）。
    func seek(toSeconds seconds: Double) {
        guard duration > 0 else { return }
        let safe = seconds.isFinite ? seconds : 0
        let target = max(0, min(duration, safe))
        seekToken &+= 1
        let token = seekToken
        // 任何一次绝对位置跳转（进度条拖动 / 无障碍调整）都取消"等它唱到"的钉子；
        // 点歌词那条路径（`seek(toLyricLine:)`）会在下面重新钉住目标行。
        pendingLyricLine = nil
        currentTime = target
        // 乐观窗口：这段时间内以"目标位置"推歌词，落地（或 1.5 秒到）就切回真实位置
        seekOptimistic = (Int(target * 1000),
                          Date().addingTimeInterval(LyricsUXRules.seekOptimisticMaxSeconds))
        seekNonce &+= 1
        // 刚 seek 完 `AVPlayer.currentTime()` 还是旧值，而 40ms 的歌词 ticker 只在播放时跑：
        // 暂停状态下如果照旧用 preciseTime 算，就会出现"跳过去了，高亮还停在上上句"。
        lyricIndex = LyricsCleaning.indexAt(
            lyrics,
            positionMs: Int(target * 1000) + lyricOffsetMs)
        lyricScrollIndex = lyricIndex
        updateNowPlaying()
        issueSeek(target: target, token: token, attempt: 0)
    }

    /// 真正把 seek 发出去，并**回读落地位置**、必要时重跳（2026-11-24）。
    ///
    /// 三条保证（老板：「什么时候拖拽都应该是同一个时间点」）：
    ///   ① 播放项没就绪就先等它就绪 —— 在没就绪的 item 上 seek，AVPlayer 会落偏；
    ///   ② 跳完回读 `currentTime()`，不是"发出去就当成功了"；
    ///   ③ 落地差超过 `SeekVerify.toleranceSec` 就重跳（最多 `SeekVerify.maxRetry` 次），
    ///      这样"同一个 4:00 拖三次"不会再出现 3:29 / 2:06 / 3:57 三种结果。
    private func issueSeek(target: Double, token: Int, attempt: Int) {
        if attempt == 0, let item = player.currentItem, item.status != .readyToPlay {
            Task { @MainActor [weak self] in
                for _ in 0..<20 {
                    guard let self, self.seekToken == token else { return }
                    if self.player.currentItem?.status == .readyToPlay { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                guard let self, self.seekToken == token else { return }
                self.issueSeek(target: target, token: token, attempt: attempt)
            }
            return
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekToken == token else { return }
                // 让播放头把新位置吐出来再读（completion 回来说明已经落定）
                try? await Task.sleep(nanoseconds: 20_000_000)
                let landed = self.preciseTime
                let off = abs(landed - target)
                if SeekVerify.shouldRetry(off: off, attempt: attempt) {
                    PlaybackTrace.shared.log("seek 重跳",
                                             "目标 \(Int(target))s / 实际落地 \(Int(landed))s"
                                             + "（差 \(Int(off))s，第 \(attempt + 1) 次重跳）")
                    self.issueSeek(target: target, token: token, attempt: attempt + 1)
                    return
                }
                self.settleSeek()
            }
        }
    }

    /// seek 完成回调：**以播放器回报的真实位置为准**（第四条规矩）。
    ///
    /// 落点在目标附近 → 立刻用真实位置；明显落偏 → 记一条诊断并**马上停止"假装在目标"**，
    /// 让条和歌词立刻跟到真实位置。以前这里会继续按目标显示最多 8 秒，
    /// 那 8 秒里屏幕和耳朵就是两条线（老板看到的"拖完对不上"）。
    private func settleSeek() {
        let raw = Int(preciseTime * 1000)
        if let opt = seekOptimistic {
            let offMs = abs(raw - opt.targetMs)
            if offMs <= LyricsUXRules.seekLandToleranceMs {
                seekOptimistic = nil
            } else if offMs > 2_000 {
                // 明显没落到目标（真机上 seek 偶尔会这样）→ 立刻以真实位置为准，
                // 不再按目标"假装"下去。1.2~2 秒的小偏差交给乐观窗口自然过期。
                PlaybackTrace.shared.log("seek 落点偏了",
                                         "目标 \(opt.targetMs / 1000)s / 实际落地 \(raw / 1000)s"
                                         + "（差 \(offMs / 1000)s），按真实位置显示")
                seekOptimistic = nil
            }
        }
        updateLyricIndex()
    }

    func seek(toFraction fraction: Double) {
        // 手指在哪就是哪：落点 = 比例 × 总长。总长是文件头锁定的那个数，seek 不会改它。
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        seek(toSeconds: SeekTargetRules.target(fraction: f, duration: duration))
    }

    /// 点某一句歌词 → 跳到那一句。
    ///
    /// 目标是「行时间 − 用户偏移」：跳完以后 `indexAt(位置 + 偏移)` 正好等于这一行，
    /// 所以高亮一定落在被点的那一句上。
    /// 老板说的"点歌词跳转的位置不对"，一半是这个偏移没算进去，一半是按 fraction 乘出来的误差。
    func seek(toLyricLine index: Int) {
        guard lyrics.indices.contains(index) else { return }
        let offset = lyricOffsetMs
        let targetMs = LyricsCleaning.seekTargetMs(lineMs: lyrics[index].timeMs, userOffsetMs: offset)
        seek(toSeconds: Double(targetMs) / 1000)
        lyricIndex = index
        lyricScrollIndex = index
        // seek 落地常提前几百毫秒：在那之前把这一行钉住，否则下一拍 ticker 会退回上一句
        pendingLyricLine = index
    }

    /// 播放列表里点某一首（队列不动，只换当前曲）
    func jump(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        if newIndex == index {
            if !isPlaying { toggle() }
            return
        }
        goTo(newIndex)
    }

    /// 队列整体替换（页头「播放全部」/「随机」；Siri 的「从收藏里随机起播」也走这里）
    ///
    /// 2026-11-24 修：`shuffle: true` 以前**只切播放模式**、起播下标永远是 0，
    /// 于是七个页面的「随机」全都变成"从第一首开始放"；再点一次目标还是第 0 首、
    /// 而它正在播（`shouldReuseCurrentSong` → `adoptQueue`），表现为"又回到当前这首"。
    /// 现在**先抽签再起播**：等概率抽一份候选、排除正在播的那首，每点一次重新抽。
    ///
    /// - Parameter start: 明确指定下标（调用方自己算好的）；nil = 随机模式下由这里抽
    func replaceQueue(_ songs: [Song], startAt start: Int? = nil, shuffle: Bool = false) {
        guard !songs.isEmpty else { return }
        guard shuffle else {
            play(queue: songs, startAt: start ?? 0)
            return
        }
        mode = .shuffle
        let pick = start ?? ShuffleStart.index(ids: songs.map { $0.id },
                                               currentID: currentSong?.id,
                                               randomIn: { Int.random(in: $0) }) ?? 0
        play(queue: songs, startAt: pick)
    }

    /// 队列追加（发现页「播放全部」先起播 5 首，其余解析完再补进队列；已在队列里的不重复加）
    func appendToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let existing = Set(queue.map { $0.id })
        let fresh = songs.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }
        queue.append(contentsOf: fresh)
    }

    // MARK: 内部流程

    /// 换到某一下标。
    ///
    /// - Parameter pauseFirst: 换之前要不要先暂停当前这首。
    ///   用户手动切歌 = true（r71：「换曲的时候先暂停当前的歌曲」）；
    ///   **自然播完 = false**（老板 2026-11-20 拍板 B4：连续播放不是切歌，静音正是空档被挂起的起点，
    ///   而且预取命中时根本不该有任何空档）。
    private func goTo(_ newIndex: Int, localURL: URL? = nil, streamURL: String? = nil,
                      pauseFirst: Bool = true, recordHistory: Bool = true) {
        guard queue.indices.contains(newIndex) else { return }
        // 随机播放：把"从哪首来的"记下来，上一首才能回到那一首（返回/前进自己那两条路不记）
        if mode == .shuffle, recordHistory, newIndex != index {
            shuffleHistory.recordAdvance(from: index)
        }
        lastAdvanceAt = Date()
        PlaybackTrace.shared.log("goTo", "→\(newIndex)/\(queue.count) pauseFirst=\(pauseFirst)")
        heartbeat.trackEnded(listened: preciseTime, completed: false)
        // 预取存下来的源只在"目标就是那首"时才留着；换了别的歌立刻作废
        if let localURL {
            pendingLocal = (songID: queue[newIndex].id, url: localURL)
        } else if pendingLocal?.songID != queue[newIndex].id {
            pendingLocal = nil
        }
        if let streamURL {
            pendingStream = (songID: queue[newIndex].id, url: streamURL)
        } else if pendingStream?.songID != queue[newIndex].id {
            pendingStream = nil
        }
        if pauseFirst {
            stopCurrentForSwitch()
        } else {
            cancelUpgradeForSwitch()
        }
        plannedNext = nil
        sameSongSwitches = 0
        index = newIndex
        currentSong = queue[newIndex]
        rejectedSourceURLs.removeAll(); rejectedFingerprints.removeAll()
        resetProgress()
        prepareLyrics(for: queue[newIndex])
        beginResolveBackgroundTask()
        beginLoad()
    }

    /// 换曲前**先把当前这首停下来**（r71，老板："换曲的时候先暂停当前的歌曲，之前好好的，现在又没了"）。
    ///
    /// 为什么必须有：新曲要先解析音源（同平台解析 1~3 秒，跨平台补位最长 12 秒），
    /// 这段时间旧音频还在播——听起来像"点了下一首，上一首又唱了半句"。
    /// 现在点下去立刻静音（`player.pause()` + `isPlaying = false`），解析完 `start(item:)` 再起播。
    ///
    /// 只暂停、不 `replaceCurrentItem`：保留当前 item 和进度，用户在解析期间点播放键还能继续听这首。
    private func stopCurrentForSwitch() {
        cancelUpgradeForSwitch()
        guard PlaybackRules.shouldPauseBeforeSwitch(hasLoadedItem: player.currentItem != nil) else { return }
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    /// 只取消"换曲要作废的后台任务"，**不动正在播的音频**（B4：自然播完走这条）
    private func cancelUpgradeForSwitch() {
        upgradeTask?.cancel()
        upgradeTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    // MARK: 跨曲取源的后台任务（B2）

    /// 取源期间向系统申请后台时间（30 秒）。
    ///
    /// 为什么必须有：后台音频 App 的"执行权"是跟着**有没有在出声**走的。上一首播完、下一首还没
    /// 开始的那段时间里，进程随时会被挂起——取源的请求就停在那儿，回前台才继续。
    /// `beginBackgroundTask` 给的是定时长的豁免（这里 30 秒），足够覆盖"一次完整排名 + 跨源补位"。
    /// 结束必须配对 `endResolveBackgroundTask`，否则到期会被系统强杀。
    private func beginResolveBackgroundTask() {
        // 连点时不要 end/begin 反复拆装（2026-11-21 SIGABRT 的触发条件之一：
        // 1 秒内 6 次 goTo = 6 次后台任务拆装 + 6 次换 item）。已经有就复用。
        if resolveBackgroundTask != .invalid {
            PlaybackTrace.shared.log("后台任务", "复用")
            return
        }
        endResolveBackgroundTask()
        resolveBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "jz-resolve-next") { [weak self] in
            // 到期回调：系统马上要收走执行权，必须自己先结束，不然进程会被强杀
            MainActor.assumeIsolated {
                PlaybackTrace.shared.log("后台任务", "到期")
                self?.endResolveBackgroundTask()
            }
        }
        if resolveBackgroundTask != .invalid {
            PlaybackTrace.shared.log("后台任务", "开始")
        }
    }

    private func endResolveBackgroundTask() {
        guard resolveBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(resolveBackgroundTask)
        resolveBackgroundTask = .invalid
    }

    // MARK: 下一首预取（B1）

    /// 时间观察者每 0.5 秒调一次：剩余 20~30 秒时把下一首的源解析好存进 `pendingStream`。
    private func maybePrefetchNext() {
        let remaining = duration - currentTime
        guard PrefetchRules.shouldPrefetch(remainingSec: remaining,
                                           hasItem: player.currentItem != nil,
                                           isResolving: isResolving,
                                           mode: mode) else { return }
        let next: Int
        if let planned = plannedNext,
           queue.indices.contains(planned.index),
           queue[planned.index].id == planned.songID,
           planned.index != index {
            next = planned.index
        } else {
            guard let picked = PlaybackRules.nextIndex(
                count: queue.count, current: index, mode: mode,
                randomIn: { Int.random(in: $0) }) else { return }
            next = picked
            // 随机模式下先把"下一首是谁"钉住：预取和真正换曲必须是同一个下标
            plannedNext = (picked, queue[picked].id)
        }
        guard queue.indices.contains(next) else { return }
        let song = queue[next]
        guard prefetchSongID != song.id else { return }
        prefetchSongID = song.id
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            await self?.prefetch(song: song)
        }
    }

    /// 预取：只解析 URL（老板 2026-11-20：**不做音频字节预取**，瓶颈是取源决策不是下载）。
    private func prefetch(song: Song) async {
        // 已下载的不用预取：`loadCurrent` 第一条分支直接播本地文件
        if DownloadManager.shared.localFileURL(for: song) != nil { return }
        // 已整首落盘过的也不用再解析
        if PlaybackCache.shared.hasComplete(song.id) { return }
        if pendingStream?.songID == song.id || pendingLocal?.songID == song.id { return }
        let src = await resolveStream(for: song)
        guard !Task.isCancelled, prefetchSongID == song.id else { return }
        guard let src else {
            PlaybackTrace.shared.log("预取失败", song.name)
            return
        }
        pendingStream = (songID: song.id, url: src.url)
        // 2026-11-25：预取不再只是"解析 URL"——**整首落盘**，切过去时就是本地读，
        // 既不依赖那一刻的网络，也不会中途断流（老板要的"切歌零等待"）。
        PlaybackCache.shared.prefetch(song: song, source: src)
        PlaybackTrace.shared.log("预取", "\(song.name) ← \(src.backendName) \(src.kbps)kbps")
    }

    private func resetProgress() {
        currentTime = 0
        // 总长：先用接口时长占位（播放器还没就绪的那一瞬间，条不该是 0）。
        // 真正锁定发生在 `adoptDuration`：文件头报多少就是多少，之后冻结。
        duration = Double(currentSong?.durationSec ?? 0)
        durationLocked = false
        durationVerified = false
        endGuardFired = false
        bufferedTime = 0
        errorText = nil
        // r77：换曲时把 seek 状态也清掉。上一首的 completion 有可能因为 item 被换掉
        // 而回 finished=false，窗口要是留着，新曲开头的高亮会被冻住。
        seekOptimistic = nil
        // 换曲：上一首"还没唱到的那一行"不能带到新曲上（行号会撞到别的歌词）
        pendingLyricLine = nil
        // 换曲：上一首的续播断点也不能带过来（否则这首会莫名其妙跳到那个位置）
        pendingRestoreSeconds = nil
    }

    /// 起播/换源统一入口：**先作废上一轮还没回来的取流**，再开始这一轮。
    ///
    /// 老板 2026-11-20：「快速点了歌 A、歌 B、歌 C，所有歌都在请求，封面歌词是 C，
    /// 但 A 或 B 的请求先回来就直接放 A 了」。根因就是每一轮取流各跑各的、回来就起播。
    /// 现在每轮 +1 代次并取消上一轮；`loadCurrent` 在 await 之后、起播之前核对代次，
    /// 过期的结果整个丢掉——最终只有最后点的那一首会响。
    private func beginLoad() {
        loadToken &+= 1
        loadTask?.cancel()
        // 上一轮可能正卡在"解析中"：这一轮接管界面状态，别让转圈留在那儿
        isResolving = false
        loadTask = Task { [weak self] in
            await self?.loadCurrent()
        }
    }

    private func loadCurrent() async {
        // 已被下一轮取代的任务连跑都不用跑（`Task.cancel()` 不会阻止 body 执行）
        guard !Task.isCancelled else { return }
        // 这一轮自己的代次：await 回来之后拿它判断"是不是还是最新那一轮"
        let token = loadToken
        guard let song = currentSong else { return }
        // 注意：这里**不**清 errorText。A6 的"几路源都放不出来，已跳到下一首"要留到新歌
        // 真正起播（`start()` 里清），否则那句提示会被这一行立刻抹掉，用户什么也看不到。

        // 已下到本地的歌优先播本地文件：离线也能放，也省掉一次解析
        if let localURL = DownloadManager.shared.localFileURL(for: song) {
            let local = StreamSource(url: localURL.absoluteString,
                                     backendName: "本地文件",
                                     platform: song.platform,
                                     quality: quality,
                                     format: localURL.pathExtension.lowercased(),
                                     note: "已下载")
            statusText = "本地文件 · \(localURL.lastPathComponent)"
            start(item: Self.makeItem(url: localURL), song: song, source: local)
            return
        }

        // 已经整首落盘过的（播放缓存）：直接播本地文件——连解析都省了，也永远不会断流
        if let cached = PlaybackCache.shared.completeFile(for: song.id) {
            let local = StreamSource(url: cached.absoluteString,
                                     backendName: "播放缓存",
                                     platform: song.platform,
                                     quality: quality,
                                     format: cached.pathExtension.lowercased(),
                                     note: "整首已缓存")
            statusText = "播放缓存 · \(cached.lastPathComponent)"
            start(item: Self.makeItem(url: cached), song: song, source: local,
                  durationVerified: true)
            return
        }

        // 心动模式预取下来的那一首：直接本地起播（这就是"切歌无缝"的关键）
        if let pending = pendingLocal, pending.songID == song.id {
            pendingLocal = nil
            pendingStream = nil
            if FileManager.default.fileExists(atPath: pending.url.path) {
                let local = StreamSource(url: pending.url.absoluteString,
                                         backendName: "心动缓存",
                                         platform: song.platform,
                                         quality: .high,
                                         format: pending.url.pathExtension.lowercased(),
                                         note: "播放中预取")
                statusText = "心动缓存 · \(pending.url.lastPathComponent)"
                start(item: Self.makeItem(url: pending.url), song: song, source: local)
                // 这里**不做后台升档**（老板 2026-11-19 反馈：切下一首卡 10 秒、还被自动切走）。
                // 原因：升档会 replaceCurrentItem 换成远端流，新 item 缓冲期间进度停在 0:00；
                // 一旦那条远端源失败/时长对不上就会走 rejectSource → 自动跳歌。
                // 心动模式优先"不断"，320k 缓存起播即可；音质升档只留给普通起播路径。
                return
            }
        }
        pendingLocal = nil

        // 解析好的流地址直接用：心动模式的现场解析 + 普通连播的预取（B1）都走这里。
        // 这是"空档 ≤0.3s"的关键路径——命中它就没有任何网络等待。
        if let pending = pendingStream, pending.songID == song.id,
           let url = URL(string: pending.url) {
            pendingStream = nil
            let src = StreamSource(url: pending.url,
                                   backendName: "预取源",
                                   platform: song.platform,
                                   quality: PlayerEngine.playbackQuality,
                                   format: url.pathExtension.lowercased(),
                                   note: "播放中预取")
            statusText = "预取 · \(src.format.isEmpty ? "流" : src.format.uppercased())"
            PlaybackTrace.shared.log("预取命中", "\(song.name)")
            await startRemote(song: song, src: src)
            return
        }
        pendingStream = nil

        isResolving = true
        statusText = "正在解析音源…"
        PlaybackTrace.shared.log("resolve 开始", song.name)
        let startedAt = Date()

        let resolved = await resolveStream(for: song)
        // 迟到的取流结果：期间用户已经点了别的歌（或这一轮已被下一轮取流取代）
        // → 整个丢掉：不改状态行、不动 isResolving、更不起播。
        guard PlaybackRules.isCurrentLoad(token: token, currentToken: loadToken),
              !Task.isCancelled,
              currentSong?.id == song.id else {
            PlaybackTrace.shared.log("resolve 丢弃", "\(song.name)（已切到别的歌）")
            return
        }
        isResolving = false
        let outcome: String
        if let resolved {
            outcome = "\(resolved.backendName) \(resolved.kbps)kbps"
        } else {
            outcome = "无源"
        }
        PlaybackTrace.shared.log("resolve 结束",
                                 "\(Int(Date().timeIntervalSince(startedAt) * 1000))ms \(outcome)")

        guard let src = resolved else {
            handleNoSource()
            return
        }

        // A7：播放链的诚实标注（无损只用于下载）
        statusText = "音源 \(src.backendName) · \(src.format.uppercased()) · \(src.kbps) kbps"
            + " · \(PlaybackQualityRules.label)"
        await startRemote(song: song, src: src)
        // 2026-11-22 **不再做"起播后升档"**：`swapToBetterSource` 会 `replaceCurrentItem` + seek，
        // 缓冲从 0 重来，就是老板说的"开头 10 秒左右卡一下"。
        // 档位已经在 `resolveStream` 第①步（`DownloadResolver.startPick`）挑好了：
        // 320k 一到就用 320k 起播，拿不到才等满窗口用手上最高的一档。
        // 函数与 `upgradedSongID` 留着是为了回滚（把下面这行注释放开即可）。
        // schedulePlaybackUpgrade(for: song)
    }

    /// 起播一条**在线**源（2026-11-25 改）：先过"文件自己的索引 + ±5 秒"闸门，
    /// 能过就交给缓存字节层（整首落盘、断流续拉），过不了就换下一条，绝不"先播着看"。
    ///
    /// 走缓存层之后：播放器不再直连 CDN，断流/403 时我们换 token 续写同一个文件，
    /// 播放器只感觉"读得慢"，不会报错、不会换 item、也不会出现"按旧总长提前切歌"。
    private func startRemote(song: Song, src: StreamSource) async {
        // 时长闸门：±5 秒。对不上就换下一条候选（最多 4 条），
        // 全都对不上就**停**——不播错的、不跳下一首、也不从 0 重播（老板 2026-11-25 定）。
        var candidate = src
        var rejected: [String] = []
        for _ in 0..<4 {
            let probe = await PlaybackCache.shared.probe(song: song, source: candidate)
            if case .mismatch(let diff) = probe.gate {
                rejected.append(candidate.url)
                rejectedSourceURLs.insert(candidate.url)
                PlaybackTrace.shared.log("时长不符",
                                         "\(song.name)：\(Int(diff))s 差，换下一条")
                guard let next = await resolveStream(for: song) else { break }
                candidate = next
                continue
            }
            var verified = false
            if case .match = probe.gate { verified = true }
            // 服务端没给总字节时，用探测拿到的那个（缓存层要它才能报 contentLength）
            var ready = candidate
            if ready.totalBytes <= 0, probe.totalBytes > 0 { ready.totalBytes = probe.totalBytes }

            if !cacheFallbackUsed,
               let built = PlaybackCache.shared.playbackItem(
                song: song, source: ready, container: ready.format,
                headHash: probe.headHash,
                resolver: { [weak self] tried in
                    guard let self else { return nil }
                    return await self.refreshSource(for: song, tried: tried)
                }) {
                cacheSession?.cancel()
                cacheSession = built.session
                start(item: built.item, song: song, source: ready,
                      durationVerified: verified)
                return
            }
            // 缓存层不可用（拿不到总字节）→ 退回直连
            guard let url = URL(string: ready.url) else { break }
            start(item: Self.makeItem(url: url), song: song, source: ready,
                  durationVerified: verified)
            return
        }
        PlaybackTrace.shared.log("无同一份文件", "\(song.name)：试过 \(rejected.count) 条")
        stopBecauseFileUnavailable(reason: "所有候选的时长都不是同一份")
    }

    /// 缓存层要求"换一条同一首歌的源"时走这里：把试过的 URL 记进坏源名单，再解析一次。
    ///
    /// 注意：**这不是"播放中偷偷换源"**——换来的新直链必须通过"同一份文件"校验
    /// （总长 + 首段指纹），否则缓存层会继续要下一条；全都对不上就停，不播错的。
    private func refreshSource(for song: Song, tried: Set<String>) async -> StreamSource? {
        rejectedSourceURLs.formUnion(tried)
        guard currentSong?.id == song.id else { return nil }
        PlaybackTrace.shared.log("缓存续拉解析", "\(song.name)（已排除 \(tried.count) 条）")
        return await resolveStream(for: song)
    }

    /// 造播放项：**本地文件必须带 `AVURLAssetPreferPreciseDurationAndTimingKey`**。
    ///
    /// 2026-11-24 血的教训：不加这个 key，AVFoundation 对 FLAC 只做"字节估算"来定位，
    /// 24bit/48k 的那个文件上实测落偏 35 秒（时钟说 4:00、实际在放 3:27），而且当前时间
    /// 还报得像没事一样，回读都发现不了。加上这个 key 它会去读文件自带的 seek 索引
    /// （VLC 一直准，就是因为它走 libFLAC 的索引）。
    private static func makeItem(url: URL) -> AVPlayerItem {
        if url.isFileURL {
            let asset = AVURLAsset(url: url,
                                   options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            return AVPlayerItem(asset: asset)
        }
        return AVPlayerItem(url: url)
    }

    /// 装配并起播一个 item（本地文件与在线取流共用这一处）
    ///
    /// - Parameter durationVerified: 这个总长是不是**有证据的**（本地精确 / 整首落盘 / 索引校验通过）。
    ///   只有 true 才允许"到点收尾"和精确百分比，见 `installTimeObserver`。
    private func start(item: AVPlayerItem, song: Song, source: StreamSource,
                       durationVerified: Bool = false) {
        // 最后一道闸：出声的必须是"当前显示的这一首"。
        // 取流代次已经拦过一轮，这里再兜一次——本地文件 / 预取 / 换源这些同步分支也走同一处。
        guard song.id == currentSong?.id else {
            PlaybackTrace.shared.log("起播丢弃", "\(song.name)（已切到别的歌）")
            return
        }
        self.durationVerified = durationVerified
            || source.backendName == "本地文件"
            || source.backendName == "播放缓存"
        self.source = source
        consecutiveSkips = 0
        sameSongSwitches = 0
        userPaused = false
        interrupted = false
        errorText = nil
        // 已经起播：这次换曲不再需要后台豁免
        endResolveBackgroundTask()
        PlaybackTrace.shared.log("play", "\(song.name) ← \(source.backendName) "
            + "\(source.format.uppercased()) \(source.kbps)kbps")
        wire(item: item, song: song, source: source)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        // 冷启动续播（快照/车载）走的不是 play(queue:)，这里补一次激活，否则心动引擎是"关着"的
        if mode == .heartbeat, !heartbeat.isActive {
            heartbeatStartIndex = queue.count - 1
            heartbeat.activate(seed: song)
        }
        // 每首真正起播都记一次事件（不限心动模式）：画像是靠全部播放历史学的
        heartbeat.trackStarted(song)
        updateNowPlaying()
        // 起播就记一次（位置 0）：万一进程在这儿被杀，下次车载连上也知道"上一首是它"
        flushSnapshot()
    }

    /// 取流（2026-11-20 老板口径重写：**先到先用 + 同曲换源 + 全程 ≤320k**）。
    ///
    ///   ① 本平台后端里**第一个**「身份闸 + ≤320k」的候选立刻用——不再等齐三个后端；
    ///   ② 一个都没回来 → 拿下载链的完整排名，挑「可播且没被拒」的最高实测码率；
    ///   ③ 仍然没有 → 同一首在别家的条目（跨平台补位），同样受 ≤320k 约束；
    ///   ④ 全空 → nil（调用方决定"同曲再换一条"还是"跳歌"，见 `switchSourceWithinSong`）。
    ///
    /// 这里**不写状态行、也不起后台升档**：预取也会走它，而预取不该改界面。
    /// 升档由 `loadCurrent` 在真正起播之后决定（那时才知道"当前这条是多少码率"）。
    private func resolveStream(for song: Song) async -> StreamSource? {
        // 被拒的 URL / 指纹只属于"当前这首"：预取别的歌时不能拿这份名单去筛
        let rejectedURLs = (song.id == currentSong?.id) ? rejectedSourceURLs : []
        let rejectedFP = (song.id == currentSong?.id) ? rejectedFingerprints : []

        func usable(_ src: StreamSource, allowLossless: Bool = false) -> Bool {
            if rejectedURLs.contains(src.url) { return false }
            let fp = PlaybackQualityRules.fingerprint(totalBytes: src.totalBytes,
                                                      durationSec: song.durationSec)
            if rejectedFP.contains(fp) { return false }
            return PlaybackQualityRules.isUsable(src, songDurationSec: song.durationSec,
                                                 allowLossless: allowLossless)
        }

        // ① 起播挑选（2026-11-22）：窗口内挑**最高档**的一条起播，起播之后不再换 item。
        //    旧路径是"谁先回来用谁 + 后台升档"，那一步 `replaceCurrentItem` 会让缓冲从 0 重来，
        //    听感就是老板说的"开头 10 秒左右卡一下"（见 `DownloadResolver.startPick`）。
        if let quick = await DownloadResolver.startPick(song: song, want: PlayerEngine.playbackQuality),
           usable(quick.source) {
            return quick.source
        }

        // ② 先到先用（老路径，6s 预算）：启动窗口没等到任何候选时**必须**留着这一档。
        //    为什么不能直接跳去 plan()：plan 要等"跨源候选"（搜索 + 逐个解析，最长 15s），
        //    而妖狐/ikun 这类慢后端 2–5s 才回——直接进 plan 会把"3s 能起播"拖成 15s，
        //    正是 2026-11-20 老板投诉的"切歌卡 10 秒"。这里先抢一条出来响，
        //    音质不好也没关系：起播之后**不再换 item**（宁可这一首 128k，也不中途卡一下）。
        if let quick = await DownloadResolver.firstPlayable(song: song, want: PlayerEngine.playbackQuality),
           usable(quick.source) {
            return quick.source
        }

        // ③ 完整排名（同曲换源就靠这一步往前走：已被拒的 URL 会被跳过）
        let plan = await DownloadResolver.plan(song: song, want: PlayerEngine.playbackQuality)
        if let picked = plan.ranked.first(where: { usable($0.source) }) {
            return picked.source
        }

        // ④ 同一首在别家的条目（网易 ↔ QQ ↔ 酷我 ↔ 酷狗）
        if let cross = await SameSongCrossResolver.resolve(
            song: song, quality: PlayerEngine.playbackQuality, triedKeys: TriedKeys()),
           usable(cross) {
            return cross
        }

        // ⑤ 无损兜底：**只在前四条全空时**才放开 FLAC（周杰伦这类"酷我只有 FLAC"的歌）。
        //
        // 为什么必须放在最后、且只跑一次：无损要现拉 26~55MB 的远端流，首字节 1.5~2s，
        // 放在关键路径上就会重现"播完卡住"（2026-11-19 心动模式的结论：无损必须现拉，
        // 那就是卡顿来源）。这里只作为"否则整首没声"的兜底，且走的是同一个
        // `beginBackgroundTask` 保护区（`loadCurrent` 外层已开）。
        if let lossless = await DownloadResolver.firstPlayable(
            song: song, want: .lossless, allowLossless: true),
           usable(lossless.source, allowLossless: true) {
            PlaybackTrace.shared.log("无损兜底", "\(lossless.source.backendName) "
                + "\(lossless.source.kbps)kbps")
            return lossless.source
        }

        // ⑥ 弱网/接口抖动的最后一下：隔 2 秒再问一次（只这一次，别把空档拖长）
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let retry = await DownloadResolver.firstPlayable(song: song, want: PlayerEngine.playbackQuality),
           usable(retry.source) {
            return retry.source
        }
        if let retryLossless = await DownloadResolver.firstPlayable(
            song: song, want: .lossless, allowLossless: true),
           usable(retryLossless.source, allowLossless: true) {
            return retryLossless.source
        }
        return nil
    }

    // MARK: 后台再判一次"有没有更高码率"（只在 ≤320k 以内）—— **2026-11-22 停用**

    /// 老板 2026-11-20 定稿：旧的 `scheduleQualityUpgrade`（会顺手把播放链升到 FLAC）**必须下线**。
    /// 这里是它的替代品——只在 ≤320k 之内往更高**实测码率**走（320 > 256 > 128），无损永远不参与。
    ///
    /// **2026-11-22 起停用（`loadCurrent` 里的调用已注释）**：老板反馈《下一个天亮》开头 10 秒左右
    /// 会明显卡一下。根因就是这里——`swapToBetterSource` 是 `replaceCurrentItem` + seek，缓冲从 0 重来，
    /// 而它触发时进度已经走了 1–5 秒，正好落在"开头 10 秒"里。
    /// 档位改由 `DownloadResolver.startPick` 在**起播之前**一次挑好（320k 到手就用 320k 起播）。
    /// 保留实现只为回滚：把 `loadCurrent` 里那行注释放开即可。
    private func schedulePlaybackUpgrade(for song: Song) {
        guard let cur = source, PlaybackQualityRules.isPlayable(cur) else { return }
        guard !PlaybackQualityRules.isTopTier(cur) else { return }
        guard upgradedSongID != song.id else { return }
        upgradeTask?.cancel()
        upgradeTask = Task { [weak self] in
            guard let self else { return }
            let plan = await DownloadResolver.plan(song: song, want: PlayerEngine.playbackQuality)
            guard !Task.isCancelled, self.currentSong?.id == song.id else { return }
            let best = plan.ranked
                .map(\.source)
                .filter { PlaybackQualityRules.isPlayable($0) }
                .max { PlaybackQualityRules.isBetter($1, than: $0) }
            guard let better = best,
                  PlaybackQualityRules.isBetter(better, than: self.source) else { return }
            self.upgradedSongID = song.id
            PlaybackTrace.shared.log("升档", "\(better.backendName) \(better.kbps)kbps")
            self.swapToBetterSource(better)
        }
    }

    private func swapToBetterSource(_ src: StreamSource) {
        guard let url = URL(string: src.url), let song = currentSong else { return }
        let pos = player.currentTime().seconds
        // 换源保留进度：ready 之后由 pendingRestoreSeconds 归位（见 wire(item:)）
        pendingRestoreSeconds = (pos.isFinite && pos > 1) ? pos : nil
        statusText = "换源 \(src.backendName) · \(src.format.uppercased()) · \(src.kbps) kbps"
        start(item: Self.makeItem(url: url), song: song, source: src)
    }

    // MARK: 播放项装配

    private func wire(item: AVPlayerItem, song: Song, source: StreamSource) {
        teardownObservers()

        // r66：时长单独观察。远端渐进式流在 readyToPlay 那一刻 `item.duration` 常是 indefinite，
        // 只在 status 回调里读一次就会永远停在元数据时长（→ 进度条先到头、歌还在唱）。
        durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            let seconds = item.duration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            Task { @MainActor in self?.adoptDuration(seconds) }
        }

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let actual = item.duration.seconds
                    // 注意：远端流这一刻的 duration 可能是 indefinite（NaN），直接 Int() 会崩
                    let durationText = actual.isFinite ? "\(Int(actual))s" : "时长未知"
                    PlaybackTrace.shared.log("item ready", "\(song.name) \(durationText)")
                    self.adoptDuration(actual)
                    // 续播断点：ready 之后才能 seek（这时 duration 才可信）
                    if let restore = self.pendingRestoreSeconds {
                        self.pendingRestoreSeconds = nil
                        self.seek(toSeconds: restore)
                    }
                    // 时长防线：与曲目时长差 >25s 就是"标着这首歌、给的是别的版本"
                    //
                    // 本地文件豁免：这首歌就是本地那份音频，"曲目时长"只是接口元数据，
                    // 拿它判本地文件会把好好的歌判成坏源 → 换源 → 跳歌（录屏里被自动切走的一类）。
                    let isLocalSource = source.backendName == "本地文件" || source.backendName == "心动缓存"
                    // 走缓存层的：时长已经由"文件自己的索引"在起播前校验过，这里不再拿播放器的估算值二次判
                    if !isLocalSource, self.cacheSession == nil,
                       PlaybackRules.durationMismatch(actual: actual, expected: song.duration) {
                        self.rejectSource(source, reason: "拿到的音频时长 \(Int(actual))s 与曲目 \(Int(song.duration))s 不符（±\(Int(PlaybackRules.durationToleranceSec))s），已换源")
                    }
                    self.updateNowPlaying()
                case .failed:
                    // 走缓存层时"读不到"意味着连"同一份文件"都找不到了 → 停，不换源、不跳歌
                    if self.cacheSession != nil {
                        self.stopBecauseFileUnavailable(reason: "音频读取失败")
                    } else {
                        self.rejectSource(source, reason: "播放失败（源可能已失效），已换源")
                    }
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                // 只有"当前装着的这个 item"放完才算数：
                // 切歌那一瞬间旧 item 的迟到通知会把刚起播的新歌再切走（老板录屏里的那次"我没动它自己跳了"）
                guard let finished = note.object as? AVPlayerItem,
                      finished === self.player.currentItem else {
                    self.statusText = "忽略上一首的迟到结束通知"
                    return
                }
                self.handleTrackFinished()
            }
        }

        failedObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.cacheSession != nil {
                    // 缓存层已经把"换同一份文件"这件事做完了；到这儿就是真拿不到 → 停
                    self.stopBecauseFileUnavailable(reason: "播放中断")
                } else {
                    self.rejectSource(source, reason: "播放中断（源失效），已换源")
                }
            }
        }
    }

    private func handleTrackFinished() {
        PlaybackTrace.shared.log("didPlayToEnd", "index=\(index)/\(queue.count) mode=\(mode.displayName)")
        // 刚切过歌（<1.2s）又收到"播完"：一定是上一首的迟到通知——再切一次就是"我没动它自己跳了"
        guard Date().timeIntervalSince(lastAdvanceAt) > 1.2 else {
            statusText = "忽略切歌瞬间的迟到结束通知"
            return
        }
        // 播到结尾了（AVPlayer 自己的结束通知 = 音频真的放完了）。
        // 这里**不改总长**：总长是文件头锁定的，播放结束不产生新数字。
        // 这一轮已经放完：快照标 finished，下次车载连上就不"续播"它，改放热门
        flushSnapshot(finished: true)
        switch mode {
        case .singleLoop:
            // 单曲循环：同一份音频重播，不重新解析（省 1~12s）
            player.seek(to: .zero)
            player.play()
            currentTime = 0
            isPlaying = true
            endGuardFired = false   // 重播了，到点收尾要重新生效
        case .listLoop, .shuffle:
            guard let next = plannedNextForAdvance() else { return }
            // B4：自然播完是连续播放，**不先暂停**（静音就是空档被挂起的起点）
            goTo(next, pauseFirst: false)
        case .heartbeat:
            // 播完这首才算"听完"（负反馈只看 userSkipped/nextTrack 那条路径）
            heartbeat.trackEnded(listened: duration > 0 ? duration : currentTime, completed: true)
            if let pick = heartbeat.takeNext() {
                playHeartbeat(pick: pick)
            } else {
                // 预取还没来得及（弱网/刚切进来）：现场算一首，算不出来就停在这里，不静默跳走
                planAndPlayHeartbeat()
            }
        }
    }

    /// 自然播完要去哪：预取时定下的那首优先。
    ///
    /// 随机模式必须走这条——不然预取时随出来的是 A、播完时又随一次成了 B，预取的源对不上，
    /// 等于白跑一趟，而且 B 还得现取（又回到"空档里被挂起"的老路）。
    private func plannedNextForAdvance() -> Int? {
        if let planned = plannedNext,
           queue.indices.contains(planned.index),
           queue[planned.index].id == planned.songID {
            plannedNext = nil
            PlaybackTrace.shared.log("下一首", "\(queue[planned.index].name)（预取已定）")
            return planned.index
        }
        return PlaybackRules.nextIndex(count: queue.count, current: index, mode: mode,
                                       randomIn: { Int.random(in: $0) })
    }

    // MARK: 心动模式

    /// 把引擎选的下一首接进队列并起播。
    ///
    /// 队列语义：心动模式下的 `queue` 就是"本次心动的会话队列"（已播 + 当前 + 即将），
    /// 所以新歌追加在后面，`index` 跟过去；上一首/播放列表因此天然可用。
    private func playHeartbeat(pick: HeartbeatEngine.Pick) {
        if let existing = queue.firstIndex(where: { $0.id == pick.song.id }) {
            guard existing != index else { return }
            goTo(existing, localURL: pick.localURL, streamURL: pick.streamURL)
            return
        }
        queue.append(pick.song)
        goTo(queue.count - 1, localURL: pick.localURL, streamURL: pick.streamURL)
    }

    /// 待播空了：现场算一首（最多等一次解析）。算不出来就停住并给一句人话。
    private func planAndPlayHeartbeat() {
        guard !isResolving else { return }
        isResolving = true
        statusText = "心动模式正在选下一首…"
        Task { [weak self] in
            guard let self else { return }
            // 预取可能正在跑：先等它（最多 10 秒），别在"快好了"的时候判死刑
            for _ in 0..<20 {
                if let pick = self.heartbeat.takeNext() {
                    self.isResolving = false
                    self.statusText = nil
                    self.playHeartbeat(pick: pick)
                    return
                }
                if !self.heartbeat.isPlanning { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let pick = await self.heartbeat.planOneNow()
            self.isResolving = false
            if let pick {
                self.statusText = nil
                self.heartbeat.setNotice(nil)
                self.playHeartbeat(pick: pick)
            } else {
                self.fallbackFromQueue()
            }
        }
    }

    /// 心动模式四级梯子全空时的最后一手：**退回队列顺序**，绝不静默停在这里。
    ///
    /// - 队列里还有别的歌 → 按列表循环继续（"先别停"，不是把模式改掉）；
    /// - 队列只有这一首 → 重播这首。
    /// 一首可播的都没有（外面已经连跳 3 次）才会真停。
    private func fallbackFromQueue() {
        guard !queue.isEmpty, let song = currentSong else {
            isPlaying = false
            errorText = "心动模式暂时选不出下一首（没有可用数据与歌源），点播放再试一次。"
            return
        }
        errorText = nil
        if queue.count > 1 {
            heartbeat.setNotice("暂无新歌，先按列表继续")
            goTo((index + 1) % queue.count)
        } else {
            heartbeat.setNotice("暂无新歌，先重播这首")
            heartbeat.trackEnded(listened: duration > 0 ? duration : currentTime, completed: true)
            player.seek(to: .zero)
            player.play()
            isPlaying = true
            currentTime = 0
            endGuardFired = false   // 重播了，到点收尾要重新生效
            heartbeat.trackStarted(song)
            updateNowPlaying()
        }
    }

    /// 「不感兴趣」：这首歌不再出现、同歌手降权，并立刻跳过当前这首。
    func dislikeCurrentSong() {
        guard let song = currentSong else { return }
        heartbeat.dislike(song)
        statusText = "已减少《\(song.name)》这类推荐"
        if mode == .heartbeat { nextTrack() }
    }

    /// 播放列表里点"即将播放"的某一首（心动模式）
    func playUpcoming(id: String) {
        guard let pick = heartbeat.removeUpcoming(id: id) else { return }
        heartbeat.trackEnded(listened: preciseTime, completed: false)
        playHeartbeat(pick: pick)
    }

    /// 连跳上限：第四十轮起不再是设置项，恒为 `PlaybackRules.autoSkipLimit`（3 首）。
    /// 连续 3 首都没源就停下来给一句人话，不把整个队列烧光。
    private var skipLimit: Int { PlaybackRules.autoSkipLimit }

    /// 采纳文件头报的时长：**只认第一次**，锁上之后任何后来的值（包括播放器自己重新算的、
    /// 我们量出来的）都不许改它。
    ///
    /// 为什么锁：这个文件的文件头就是对的（48kHz/24bit，total_samples=12,102,400 → 4:12.13，
    /// 本地解码出来一模一样）。以前我们让"后面报的值"反复覆盖，一拖进度条总长就从 4:12 变成 4:47。
    private func adoptDuration(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        guard !durationLocked else { return }
        guard abs(seconds - duration) > 0.2 else {
            durationLocked = true   // 和占位值一致，也算锁定
            return
        }
        duration = seconds
        durationLocked = true
        refetchLyricsIfDurationChanged()
    }

    /// 采纳一个**实测**的时长。
    ///
    /// `rank` 是证据强度：1 = 解码到 EOF，2 = 播放器可跳区间末位 / 以前量过的缓存，3 = 播到真结尾。
    /// 真实时长与"取词时用的目标时长"差了 8 秒以上 → 重取一次词（r69）。
    ///
    /// 为什么值一次重取：歌词候选的分数里有"时长差"这一档，差 8 秒足够让排序翻盘
    /// （《发如雪》那次就是元数据 5:00、候选 5:13 的醇享版压过了原版）。
    private func refetchLyricsIfDurationChanged() {
        guard !lyricsRefetched, !isLoadingLyrics, lyricsTargetSec > 0 else { return }
        let actual = Int(duration)
        guard actual > 0, abs(actual - lyricsTargetSec) > 8 else { return }
        guard let song = currentSong else { return }
        lyricsRefetched = true
        lyricsTargetSec = actual
        isLoadingLyrics = true
        Task { [weak self] in
            let result = await LyricsService.shared.fetch(song, audioSec: actual, force: true)
            guard let self else { return }
            guard self.currentSong?.id == song.id else {
                self.isLoadingLyrics = false
                return
            }
            if let result, !result.lines.isEmpty {
                self.adoptLyrics(result, for: song)
                return
            }
            self.isLoadingLyrics = false
        }
    }

    /// 某一条源放不出来（403 / 坏容器 / 时长不符 / 播放中断）。
    ///
    /// A6（老板 2026-11-20）：**先在同一首歌内换下一条源**（保持进度、seek 回原位置），全换完才跳歌。
    /// A5：`deadSongKeys.insert` 删掉——单条源失败不等于整首歌没源，记进那个集合会让这首歌
    /// 在搜索结果里永远被隐藏（同一个错误模式不该从"一条源"升级成"整首歌"）。
    private func rejectSource(_ source: StreamSource, reason: String) {
        PlaybackTrace.shared.log("源失败", "\(source.backendName)：\(reason)")
        rejectedSourceURLs.insert(source.url)
        if let song = currentSong {
            // 也记内容指纹：占位提示音每次换新 URL，只记 URL 会一直重试同一段东西
            rejectedFingerprints.insert(
                PlaybackQualityRules.fingerprint(totalBytes: source.totalBytes,
                                                 durationSec: song.durationSec))
        }
        errorText = reason
        switchSourceWithinSong()
    }

    /// 一首歌的候选**全部**试完（取流链自己走空了）：这时才允许跳歌。
    private func handleNoSource() {
        PlaybackTrace.shared.log("无源", currentSong?.name ?? "—")
        consecutiveSkips += 1
        errorText = PlaybackRules.skipMessage(consecutiveSkips, limit: skipLimit)
        isPlaying = false
        if PlaybackRules.shouldStopAfterSkips(consecutiveSkips, limit: skipLimit) {
            endResolveBackgroundTask()
            return
        }
        advanceAfterFailure()
    }

    /// 走缓存层时"这份文件真的取不全了"：**不换源、不跳下一首**，停在原地给一句人话。
    ///
    /// 老板 2026-11-25 定：「不允许播错的，继续重新找相同文件；所有的源全都找不到相同文件，那就停即可」。
    ///
    /// 唯一的例外是**字节层本身没跑起来**（一秒都没出声）：这不是"源不对"，是这套新机制在这个
    /// 环境里不可用（例如自定义 scheme 被系统拒）。这时退回直连、并在本次运行里关掉缓存层，
    /// 否则用户会一首歌都放不出来 —— 宁可回到旧行为，也不能让 App 变砖。
    private func stopBecauseFileUnavailable(reason: String) {
        let neverStarted = currentTime < 1 && preciseTime < 1
        if neverStarted, cacheSession != nil, !cacheFallbackUsed {
            cacheFallbackUsed = true
            PlaybackTrace.shared.log("缓存层回退", "\(currentSong?.name ?? "—")：\(reason)，改直连")
            statusText = "缓存不可用，改直连播放"
            cacheSession?.cancel()
            cacheSession = nil
            beginLoad()
            return
        }
        PlaybackTrace.shared.log("缓存停止",
                                 "\(currentSong?.name ?? "—")：\(reason)")
        isPlaying = false
        isResolving = false
        errorText = "《\(currentSong?.name ?? "这首")》的文件取不全了（找不到同一份），已停止。点播放可重试。"
        cacheSession?.cancel()
        endResolveBackgroundTask()
        updateNowPlaying()
    }

    /// 同曲换源：先记住播放位置，再重新解析这一首。
    /// `rejectedSourceURLs` 已经收下刚失败的那条 URL，取流链会跳过它、挑同曲的下一条候选；
    /// 新源 ready 之后 `pendingRestoreSeconds` 把进度 seek 回原位（见 `wire(item:)`）。
    private func switchSourceWithinSong() {
        guard let song = currentSong else { return }
        let pos = player.currentTime().seconds
        if pos.isFinite, pos > 1 { pendingRestoreSeconds = pos }
        sameSongSwitches += 1
        guard sameSongSwitches <= PlaybackRules.maxSameSongSwitches else {
            // 这首的几路源都换过了：这才跳歌，并明确提示（`start()` 之前不会被清掉）
            sameSongSwitches = 0
            consecutiveSkips += 1
            PlaybackTrace.shared.log("同曲换源放弃", "\(song.name) 换满 \(PlaybackRules.maxSameSongSwitches) 条")
            if PlaybackRules.shouldStopAfterSkips(consecutiveSkips, limit: skipLimit) {
                isPlaying = false
                errorText = PlaybackRules.skipMessage(consecutiveSkips, limit: skipLimit)
                endResolveBackgroundTask()
                return
            }
            advanceAfterFailure()
            errorText = "《\(song.name)》的几路音源都放不出来，已跳到下一首（第 \(consecutiveSkips) 首）"
            return
        }
        statusText = "这首在换源（第 \(sameSongSwitches) 条）…"
        PlaybackTrace.shared.log("同曲换源",
                                 "\(song.name) 第\(sameSongSwitches)条 pos=\(Int(max(0, pos.isFinite ? pos : 0)))s")
        beginResolveBackgroundTask()
        beginLoad()
    }

    /// 这首放不出来时往哪走：普通模式按队列规则；心动模式换引擎里的下一首（或现场算）。
    private func advanceAfterFailure() {
        if mode == .heartbeat {
            if let pick = heartbeat.takeNext() {
                playHeartbeat(pick: pick)
            } else {
                planAndPlayHeartbeat()
            }
            return
        }
        guard let next = PlaybackRules.nextIndex(
            count: queue.count, current: index, mode: mode,
            randomIn: { Int.random(in: $0) }) else { return }
        goTo(next)
    }

    // MARK: 进度观察

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite {
                    self.currentTime = seconds
                    self.updateLyricIndex()
                    // B1：剩余 20~30 秒时把下一首的源解析好（"播完不换歌"的正解）
                    self.maybePrefetchNext()
                    // 播放中每 10 秒落一次断点（store 内部还会再夹一次间隔）
                    if self.isPlaying, Int(seconds) % 10 == 0 {
                        self.flushSnapshot()
                    }
                }
                if let item = self.player.currentItem {
                    // 总长只在这里锁一次（= 文件头写的长度），之后谁都不许改
                    self.adoptDuration(item.duration.seconds)
                    // 已经放到文件头写的长度了 → 这一首就是播完了。
                    // 2026-11-25：**只有 `durationVerified` 才允许这一手**。
                    // 在线流那个总长是系统估算（不是文件索引），拿它判播完就是老板报的
                    // "歌没唱完自己切下一首"；没有证据就只等播放器自己的结束通知。
                    if self.durationVerified, self.durationLocked, self.isPlaying, !self.endGuardFired,
                       TrackEndRules.isReached(currentTime: self.currentTime, duration: self.duration) {
                        self.endGuardFired = true
                        PlaybackTrace.shared.log("到点收尾",
                                                 "\(self.currentSong?.name ?? "—") 已到文件头长度 \(Int(self.duration))s")
                        self.handleTrackFinished()
                    }
                    let ranges = item.loadedTimeRanges
                    if let last = ranges.last {
                        let range = last.timeRangeValue
                        let end = range.start.seconds + range.duration.seconds
                        if end.isFinite { self.bufferedTime = end }
                    }
                }
                self.updateNowPlaying()
            }
        }
    }


    private func teardownObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        failedObserver = nil
    }

    // MARK: 系统面

    func pauseForInterruption() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        // 被打断不是"卡住"：回前台自愈不能把来电/闹钟之后的暂停当成故障自动放起来
        interrupted = true
        updateNowPlaying()
        // 拔耳机 / 断开蓝牙（含下车）：把断点落盘，下次连上从这儿接着放
        flushSnapshot(force: true)
    }

    func resumeAfterInterruption() {
        guard player.currentItem != nil, !isPlaying else { return }
        player.play()
        isPlaying = true
        interrupted = false
        userPaused = false
        updateNowPlaying()
    }

    // MARK: 回前台自愈（B3）

    /// 回到前台时调一次：**应该出声却没出声**就重新踢一次解析。
    ///
    /// 为什么需要：后台被挂起之后，取源那个 Task 有可能已经死掉（进程被系统清掉、
    /// 或请求在挂起期间直接失败），只靠"任务自己恢复"不够——用户看到的就是
    /// "回前台还是没声音，点一下才好"。这里排除三种情况：
    /// 用户自己按的暂停、来电/闹钟打断、以及已经明确判定"没有可用源"（重试只会原地打转）。
    func recoverIfStalled() {
        guard currentSong != nil, !isPlaying, !isResolving, errorText == nil else { return }
        guard !userPaused, !interrupted else { return }
        PlaybackTrace.shared.log("回前台自愈", currentSong?.name ?? "—")
        beginLoad()
    }

    // MARK: 歌词

    /// 歌词取不到时的原因（播放页空状态里显示给人看，r63 加：下一轮一眼就能定位是哪条链断了）
    private(set) var lyricsFailure: String = ""

    /// 「这份词是怎么选出来的」——候选标题 / 时长 / 各档分数（r69，详情页可见）
    private(set) var lyricsMatchNote: String = ""

    /// 取词时用的"目标时长"（秒）：真实时长远晚于它时才值得重取一次
    private var lyricsTargetSec: Int = 0
    /// 歌空态出来之后的那一次静默重试（换歌时取消）
    private var lyricsRetryTask: Task<Void, Never>?
    /// 这首歌是否已经因为"时长后知后觉"重取过（每首最多一次，避免循环）
    private var lyricsRefetched = false

    /// 切歌时先清空，再异步取词（不阻塞起播：Android 同样是"起播前并发预热歌词"）
    ///
    /// 第五轮（老板反馈 ⑧）：已下载的歌**先读下载时一起存下的本地 LRC**——
    /// 无网络环境（飞机上、地铁里）点开下载好的歌，也要有词可看，不能只剩播放器。
    /// 本地没有才走网络；网络失败时保持空态（播放页有「重试」+ 失败原因）。
    /// 同一首歌的歌词来源变了（酷我 → LDDC → LRCLIB…）→ 把这首的偏移归零。
    ///
    /// 老板 r74 口径：「快一点/慢一点保留，但默认 0、换歌或换歌词来源时归零，只在用户手动调过之后生效」。
    /// 不同来源的时间轴基准本来就不同，沿用上一个来源的偏移只会更不准。
    private var lyricSourceBySong: [String: String] = [:]

    private func adoptLyrics(_ result: LyricsResult?, for song: Song) {
        // 第 55 轮：取到词就落旁车（只剩"文件夹里没有"的那 24 首靠播放补齐）。
        // 内部会先判 `Lyrics/<基名>.lrc` 在不在，不会覆盖已有文件。
        if let result, !result.lines.isEmpty {
            DownloadManager.shared.persistFetchedLyrics(result, for: song)
        }
        if let result {
            let previous = lyricSourceBySong[song.id]
            // 只比"来源名"（标签里有耗时，如 `LDDC · 逐字 · 1.8s`，按首个 · 前的前缀比）
            let tag = result.source.split(separator: "·").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? result.source
            if let previous, previous != tag {
                SettingsStore.shared.resetOffset(forSong: song.id)
            }
            lyricSourceBySong[song.id] = tag
        }
        lyrics = result?.lines ?? []
        lyricsSource = result?.source ?? ""
        lyricsMatchNote = result?.matchNote ?? ""
        isLoadingLyrics = false
        // 词被换掉了：旧的"还没唱到的那一行"行号已无意义，按当前位置重新推导
        pendingLyricLine = nil
        updateLyricIndex()
    }

    /// 上一首（用来在换歌时清掉它那次手动调的偏移，老板 r74：「换歌…归零」）
    private var previousLyricSongID: String?

    private func prepareLyrics(for song: Song) {
        if let previous = previousLyricSongID, previous != song.id {
            SettingsStore.shared.resetOffset(forSong: previous)
        }
        previousLyricSongID = song.id
        lyricsRetryTask?.cancel()
        lyricsRetryTask = nil
        lyrics = []
        lyricsSource = ""
        lyricIndex = -1
        lyricScrollIndex = -1
        pendingLyricLine = nil
        lyricsFailure = ""
        lyricsMatchNote = ""
        lyricsRefetched = false
        lyricsTargetSec = duration > 2 ? Int(duration) : song.durationSec

        if let local = DownloadManager.shared.localLyrics(for: song), !local.isEmpty {
            lyrics = local
            lyricsSource = "本地歌词"
            isLoadingLyrics = false
            updateLyricIndex()
            return
        }

        isLoadingLyrics = true
        let targetSec = lyricsTargetSec
        Task { [weak self] in
            let result = await LyricsService.shared.fetch(song, audioSec: targetSec)
            guard let self else { return }
            // 期间可能又切歌了，只有仍停在同一个 ID 才落地
            guard self.currentSong?.id == song.id else { return }
            self.adoptLyrics(result, for: song)
            if result == nil {
                let reason = await LyricsService.shared.failureReason()
                guard self.currentSong?.id == song.id else { return }
                self.lyricsFailure = reason
                self.scheduleLyricsRetry(for: song, targetSec: targetSec)
            }
        }
    }

    /// 空态画出来之后**静默再试一次**（1.5 秒后，仍停在这首、仍然没词才动手）。
    ///
    /// r74 去掉的是"整条链重跑"——那会让一次取词拖到几十秒、还挡着界面。
    /// 这里改在空态已经出现之后补一次：用户看到的是"过一两秒词自己出来了"，
    /// 而第二次也失败也不会让他多等一轮（不占首屏时间）。
    private func scheduleLyricsRetry(for song: Song, targetSec: Int) {
        lyricsRetryTask?.cancel()
        lyricsRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.currentSong?.id == song.id, self.lyrics.isEmpty,
                  !self.isLoadingLyrics else { return }
            self.isLoadingLyrics = true
            let result = await LyricsService.shared.fetch(song, audioSec: targetSec, force: true)
            guard self.currentSong?.id == song.id else {
                self.isLoadingLyrics = false
                return
            }
            if let result, !result.lines.isEmpty {
                self.adoptLyrics(result, for: song)
                self.lyricsFailure = ""
            } else {
                self.isLoadingLyrics = false
            }
        }
    }

    private func updateLyricIndex() {
        let offset = lyricOffsetMs
        let rawMs = Int(preciseTime * 1000)

        // ① 点歌词跳转的"等它唱到"窗口：
        // seek 常落在目标之前几百毫秒，而 `indexAt` 早 1ms 就会推成上一句。
        // 还没走到被点那一行之前，高亮与滚动都钉在那一行；走到了立刻交还给正常推导。
        // 用**播放头真实位置**判断"唱到了没有"，所以与歌曲无关。
        if let pending = pendingLyricLine {
            guard lyrics.indices.contains(pending) else {
                pendingLyricLine = nil
                // 歌词换了（重取/换歌），继续走正常推导
                return finishLyricIndex(position: rawMs + offset)
            }
            let decision = LyricsCleaning.lyricSeekHoldDecision(
                positionMs: rawMs + offset,
                lineMs: lyrics[pending].timeMs,
                toleranceMs: LyricsUXRules.lyricSeekHoldToleranceMs)
            if decision == .hold {
                if lyricIndex != pending { lyricIndex = pending }
                if lyricScrollIndex != pending { lyricScrollIndex = pending }
                return
            }
            pendingLyricLine = nil
        }

        // ② seek 之后的时钟（进度条拖动也走这条）：窗口内用目标位置，落地或 1.5 秒后
        //    用播放头真实位置。**永远给出一个位置**——旧实现会 return（=冻住），
        //    一旦 completion 不回来就冻 10 秒，正是老板说的"一跳就瞬间对不上"。
        var effectiveMs = rawMs
        if let optimistic = seekOptimistic {
            let source = LyricsUXRules.seekClockSource(
                positionMs: rawMs,
                targetMs: optimistic.targetMs,
                optimisticExpired: Date() >= optimistic.until)
            if source == .useTarget {
                effectiveMs = optimistic.targetMs
            } else {
                seekOptimistic = nil
            }
        }

        finishLyricIndex(position: effectiveMs + offset)
    }

    /// 正常推导：高亮与滚动走同一份位置，保证"亮的行"和"滚到中间的行"不打架
    private func finishLyricIndex(position: Int) {
        let idx = LyricsCleaning.indexAt(lyrics, positionMs: position)
        if idx != lyricIndex { lyricIndex = idx }
        let anchor = LyricsCleaning.scrollAnchorIndex(lyrics, positionMs: position,
                                                     leadMs: LyricsUXRules.scrollLeadMs)
        if anchor != lyricScrollIndex { lyricScrollIndex = anchor }
    }

    /// 25Hz 的歌词定位 ticker（只在播放时推进）
    ///
    /// 为什么不放在 TimeObserver 里：那个是 0.5 秒一次，用来驱动进度条足够，
    /// 用来切歌词就是"永远慢半拍"。这里只在 `isPlaying` 时算，代价是每 40ms 一次
    /// `AVPlayer.currentTime()` + 一次线性扫（歌词几百行，扫到头也就微秒级）。
    private func startLyricTicker() {
        lyricTicker?.cancel()
        lyricTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard let self else { return }
                if self.isPlaying, !self.lyrics.isEmpty { self.updateLyricIndex() }
            }
        }
    }

    /// 播放页重取歌词（首次取词失败时自动/手动重试；不打断播放）
    ///
    /// 之前「歌词一直是空」有两层原因，都会在这里被兜住：
    ///   ① 取词发生在切歌那一瞬间，弱网/接口抽风失败后没有第二次机会 → 现在播放页打开时会再取一次；
    ///   ② 用户只能看到一句"暂无歌词"，没有重试入口 → 播放页的空状态里给了一个「重试」。
    func reloadLyrics() {
        guard let song = currentSong, !isLoadingLyrics else { return }
        prepareLyrics(for: song)
    }

    private func updateNowPlaying() {
        // r65：实时活动（锁屏黑卡 / 灵动岛）已下线，这里只喂系统自带的锁屏播放器
        NowPlayingCenter.shared.update(
            song: currentSong,
            source: source,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            buffered: bufferedTime,
            playMode: mode
        )
    }
}

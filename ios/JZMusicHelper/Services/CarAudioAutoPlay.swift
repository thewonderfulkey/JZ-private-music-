import AVFoundation
import Foundation

// MARK: - 车载自动播放（"上车就响"）
//
// 第四十轮（老板："额外需要添加的选项是车载 car play，当连接车载蓝牙之后自动播放歌曲，
// 至于播放什么歌曲，可以接着上次没播完的接着放，如果上次没有放歌，那就自动选择热门歌单上的歌曲放"）。
//
// **边界先说清**：真正的 CarPlay（车机屏上出现我们的界面）需要 Apple 单独审批的
// `com.apple.developer.carplay-audio` 权限，自签分发拿不到。所以这里落地的是老板要的**行为**：
// 监听音频路由换成车机 / 车载蓝牙 → 自动开始播，别在车里还要掏手机点一下。
//
// 为什么不放在 `NowPlayingCenter`：那一层只在**第一次播放之后**才装配（省启动开销），
// 而"车载连上要自动播"恰恰是"还没播"的时候要生效，所以单独一个类，随根视图启动就挂上。
//
// 会话口径（这一条决定了功能灵不灵）：iOS 的路由变更通知基本只在音频会话**激活过**之后才送到 App，
// 而"车载连上要自动播"恰恰是"这次还没播过"的时候要生效。所以在挂观察者时就把会话配好并激活，
// 但带 `.mixWithOthers`：不去打断/不抢别人正在放的歌（我们只是一直在等车里那次的连接），
// 真正起播时 `NowPlayingCenter` 会重新配成独占的 `.playback`。
// 边界说清楚：**进程被上滑杀掉之后**连上车机不会自动响——那不是 App 能收到通知的状态，
// 得先打开一次 App；这一点也写在设置页说明里。
@MainActor
final class CarAudioAutoPlay {

    static let shared = CarAudioAutoPlay()

    private weak var player: PlayerEngine?
    private weak var feed: DiscoverFeed?
    private weak var library: LibraryStore?
    private var observer: NSObjectProtocol?
    /// 起播流程只跑一份（同一时刻可能连着来两条路由通知）
    private var starting = false

    private init() {}

    /// 根视图出现时挂上（幂等）
    func attach(player: PlayerEngine, feed: DiscoverFeed, library: LibraryStore) {
        self.player = player
        self.feed = feed
        self.library = library
        guard observer == nil else { return }
        prepareSession()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handle(note) }
        }
    }

    /// 配好会话并激活（`mixWithOthers`：不打断别人；只为让路由通知能送到）
    private func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    // MARK: 路由变化

    private func handle(_ note: Notification) {
        guard SettingsStore.shared.carAutoPlay else { return }
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .newDeviceAvailable else { return }
        let kind = Self.routeKind(AVAudioSession.sharedInstance().currentRoute.outputs.first)
        let playing = player?.isPlaying ?? false
        guard CarAudioRules.shouldAutoplay(enabled: true, isPlaying: playing, kind: kind) else {
            return
        }
        Task { await start() }
    }

    /// `AVAudioSession.Port` → 纯规则用的三分类（`CarRouteKind` 抽出去是为了能被 CI 断言）
    static func routeKind(_ port: AVAudioSessionPortDescription?) -> CarRouteKind {
        guard let type = port?.portType else { return .other }
        switch type {
        case .carAudio:
            return .carAudio
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return .bluetooth
        case .usbAudio:
            return .usb
        default:
            return .other
        }
    }

    // MARK: 起播

    private func start() async {
        guard let player else { return }
        guard !starting else { return }
        guard !player.isPlaying else { return }
        starting = true
        defer { starting = false }

        // ① 刚才只是暂停（App 一直活着）：接着这首的原位置继续，别重头放
        if player.hasCurrentSong {
            player.toggle()
            return
        }

        // ② 进程重开过：读上一次的快照，从断开的地方接着放
        if let snapshot = PlaybackSnapshotStore.shared.load(), snapshot.canResume {
            player.play(queue: snapshot.effectiveQueue,
                        startAt: 0,
                        positionSeconds: snapshot.positionSec)
            library?.recordPlayed(snapshot.song)
            return
        }

        // ③ 上次没有放歌（或上一轮已经播完）：放热门
        if let feed {
            await feed.loadHotIfNeeded()
        }
        let hot = feed?.hotSongs ?? []
        guard let first = hot.first else { return }
        player.play(queue: hot, startAt: 0)
        library?.recordPlayed(first)
    }
}

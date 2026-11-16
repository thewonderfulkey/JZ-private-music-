import Foundation
import Network
import Observation

// MARK: - 网络类型（仅 Wi-Fi 下载要用）
//
// 只需要回答一个问题："现在是不是 Wi-Fi"。用 NWPathMonitor 缓存最近一次路径状态，
// 不阻塞、不弹系统权限。还没拿到第一条路径时**按 Wi-Fi 处理**——
// 宁可在弱网下多下一次，也不要一进 App 就把下载按钮判死。
final class NetworkStatus: @unchecked Sendable {

    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.jz.musichelper.network")
    private let lock = NSLock()
    private var wifi = true
    private var started = false

    private init() {}

    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isWifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            self.lock.lock()
            self.wifi = isWifi
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    var isOnWiFi: Bool {
        start()
        lock.lock()
        defer { lock.unlock() }
        return wifi
    }
}

// MARK: - 下载编排（选档 → 取源 → 确认 → 落盘）
//
// 与 Android `DownloadCoordinator` 同口径：
//   1. 用户选档（默认跟着播放音质）
//   2. `DownloadResolver.plan` 走三级换源链，拿"核实就是该档"的候选
//   3. 拿不到目标档就退回**最高可得档**，并把事实写在确认页上（绝不悄悄降级）
//   4. 真正落盘交给 `DownloadManager`（后台 URLSession + 完成通知 + 95% 体积校验）
//
// 为什么不在这里直接下载：解析可能耗时 30–40 秒，用户必须看见"我在找源"这件事，
// 而且"选了无损却只能给 320k"必须由用户点头，不能替他决定。
@MainActor
@Observable
final class DownloadFlow {

    enum Stage {
        /// 选音质
        case choosing
        /// 正在走换源链
        case resolving
        /// 已拿到一条可下的源，等用户确认（**只在降级时需要点头**）
        case offer
        /// 已经开下（老板反馈 ⑥：选完档位直接下，不再让人点第二遍）
        case started
        /// 没有可用源 / 被开关拦下
        case failed
    }

    struct Offer {
        let quality: QualityLevel
        let source: StreamSource
        /// true = 就是用户选的那一档；false = 降级兜底（必须显式告知）
        let isExact: Bool
        let note: String
    }

    private(set) var stage: Stage = .choosing
    private(set) var song: Song?
    private(set) var want: QualityLevel = .lossless
    private(set) var offer: Offer?
    private(set) var message: String?
    /// 已经开始过下载（用来把按钮文案从"开始下载"换成"重新下载"）
    private(set) var startedDownload = false

    /// 由 RootTabView 绑定到 `.sheet(isPresented:)`
    var isPresented = false

    private var resolveTask: Task<Void, Never>?

    // MARK: 入口

    func start(song: Song, want: QualityLevel) {
        resolveTask?.cancel()
        self.song = song
        self.want = want
        offer = nil
        message = nil
        startedDownload = false
        stage = .choosing
        isPresented = true
    }

    func dismiss() {
        resolveTask?.cancel()
        isPresented = false
        stage = .choosing
        offer = nil
        message = nil
    }

    // MARK: 选档 → 取源

    func choose(_ quality: QualityLevel) {
        guard let song else { return }
        want = quality
        message = nil
        offer = nil
        stage = .resolving
        resolveTask?.cancel()
        resolveTask = Task { @MainActor in
            let plan = await DownloadResolver.plan(song: song, want: quality)
            guard !Task.isCancelled else { return }
            apply(plan)
        }
    }

    private func apply(_ plan: DownloadResolver.Plan) {
        if let exact = plan.exact.first {
            let offer = Offer(quality: exact.quality,
                              source: exact,
                              isExact: true,
                              note: plan.switched ? "本平台无源，已换到 \(exact.platform.shortName)" : "")
            self.offer = offer
            // 实测就是用户要的那一档 → 直接开下，不再要求点第二遍「开始下载」
            start(offer)
        } else if let fallback = plan.fallback {
            offer = Offer(quality: fallback.quality,
                          source: fallback,
                          isExact: false,
                          note: "没有\(plan.want.displayName)，最高可得\(fallback.quality.displayName)")
            stage = .offer
        } else {
            message = "这首歌四家都取不到音源。换一首，或稍后再试。"
            stage = .failed
        }
    }

    // MARK: 确认 → 落盘

    /// 落盘。正常路径（实测命中目标档）由 `apply` 直接调；降级路径由用户在 offer 页点确认。
    private func start(_ offer: Offer) {
        guard let song else { return }

        if let reason = DownloadGuard.refusalReason(
            wifiOnly: SettingsStore.shared.wifiOnlyDownload,
            onWiFi: NetworkStatus.shared.isOnWiFi) {
            message = reason
            stage = .failed
            return
        }

        DownloadManager.shared.download(
            song: song,
            streamSource: offer.source,
            expectedBytes: offer.source.totalBytes,
            useBackground: SettingsStore.shared.backgroundDownload)

        startedDownload = true
        stage = .started
        Haptics.success()

        // 给一个"已开始"的确认画面，1.8 秒后自己收起（不用用户再点关闭）
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if stage == .started { dismiss() }
        }
    }

    /// 降级路径的确认按钮
    func confirm() {
        guard let offer else { return }
        start(offer)
    }

    /// 这首歌是否已经在本地（用于把入口显示成"已下载"）
    func isDownloaded(_ song: Song) -> Bool {
        DownloadManager.shared.hasCompleted(song: song)
    }
}

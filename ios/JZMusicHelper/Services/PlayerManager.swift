import Foundation
import AVFoundation

// MARK: - 播放管理器
/// 在线试听：AVPlayer 播放流地址。切换曲目/停止时释放。
final class PlayerManager: NSObject, ObservableObject {

    static let shared = PlayerManager()

    @Published var currentURL: String?
    @Published var isPlaying: Bool = false
    @Published var isPreparing: Bool = false
    @Published var errorMessage: String?

    private var player: AVPlayer?
    private var timeObserver: Any?

    private override init() {
        super.init()
        configureAudioSession()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    // MARK: - 播放控制

    /// 播放指定 URL（替换当前曲目）
    func play(url: String) {
        guard let streamURL = URL(string: url) else {
            errorMessage = "无效播放地址"
            return
        }
        stop()
        isPreparing = true
        errorMessage = nil
        currentURL = url

        var request = URLRequest(url: streamURL)
        request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")

        // AVPlayer 无法直接带自定义头播放，改用 AVURLAsset 加载请求
        let asset = AVURLAsset(url: streamURL, options: [
            "AVURLAssetOutOfBandMIMETypeKey": "audio/mpeg",
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": APIClient.mobileUA,
                "Referer": "https://music.qq.com/"
            ]
        ])
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        self.player = newPlayer

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(itemDidEnd(_:)),
                                               name: .AVPlayerItemDidPlayToEndTime,
                                               object: item)

        addTimeObserver()

        newPlayer.play()
        isPlaying = true
        isPreparing = false

        // 播放错误监听
        item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, item.status == .failed else { return }
                self.errorMessage = "播放失败（源可能已失效）"
                self.isPlaying = false
                self.isPreparing = false
            }
        }
    }

    /// 暂停/继续
    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    /// 停止并释放
    func stop() {
        let oldPlayer = player
        oldPlayer?.pause()
        player = nil
        isPlaying = false
        isPreparing = false
        currentURL = nil
        if let timeObserver, let oldPlayer {
            oldPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        // 移除结束通知观察者（通过 newPlayer 重建时会重新添加）
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    @objc private func itemDidEnd(_ notification: Notification) {
        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }

    private func addTimeObserver() {
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                                                      queue: .main) { _ in }
    }
}

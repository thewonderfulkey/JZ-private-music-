import AVFoundation
import MediaPlayer
import UIKit

// MARK: - 锁屏 / 控制中心 / 耳机键 / 音频会话
//
// 这一层是 iOS 的"系统面"：Android 那边对应的是「前台服务 + 常驻通知 + MediaSession」三件套，
// 而 iOS 全都由系统提供，只要把 Now Playing 信息与远程命令接上、音频会话配对：
//   · 锁屏与控制中心：封面、歌名、歌手、进度、上一首/播放/下一首
//   · 耳机/AirPods：单击播放暂停、双击下一首、长按 Siri（系统自动）
//   · 拔耳机自动暂停（routeChange 的 oldDeviceUnavailable）
//   · 来电/闹钟打断后按系统指示恢复（interruption）
@MainActor
final class NowPlayingCenter {

    static let shared = NowPlayingCenter()

    private weak var engine: PlayerEngine?
    private var configured = false

    private var lastArtworkSongID: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    private init() {}

    /// 退出 App 时清掉系统面的残留：控制中心/锁屏的"正在播放"卡片、音频会话占用。
    ///
    /// 用户上滑杀掉 App 后，系统那条锁屏播放卡片如果没人收，会一直挂在那儿——
    /// 这里在 `applicationWillTerminate` 里把能清的都清掉。
    /// （r65 起 App 自己的实时活动 / 灵动岛已整体下线，只剩系统自带的这条透明卡片）
    func teardown() {
        engine = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        lastArtworkSongID = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            #if DEBUG
            print("[NowPlaying] 释放音频会话失败：\(error)")
            #endif
        }
    }

    // MARK: 装配

    func attach(engine: PlayerEngine) {
        self.engine = engine
        guard !configured else { return }
        configured = true
        configureAudioSession()
        configureRemoteCommands()
        observeAudioSession()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // 播放类 App 的标准配置：后台继续、静音键不打断、支持 AirPlay
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // 拿不到音频会话时不要崩：播放会退化成前台可用
            #if DEBUG
            print("[NowPlaying] 音频会话配置失败：\(error)")
            #endif
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine?.toggle() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let engine = self?.engine, engine.isPlaying else { return }
                engine.toggle()
            }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine?.toggle() }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine?.nextTrack() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine?.previousTrack() }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                guard let engine = self?.engine, engine.duration > 0 else { return }
                engine.seek(toFraction: e.positionTime / engine.duration)
            }
            return .success
        }
    }

    private func observeAudioSession() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification,
                       object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                switch type {
                case .began:
                    self?.engine?.pauseForInterruption()
                case .ended:
                    let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                    if options.contains(.shouldResume) {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self?.engine?.resumeAfterInterruption()
                    }
                @unknown default:
                    break
                }
            }
        }

        // 拔耳机 / 断开蓝牙：系统期望你暂停，别继续外放
        nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                       object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            if reason == .oldDeviceUnavailable {
                Task { @MainActor in self?.engine?.pauseForInterruption() }
            }
        }
    }

    // MARK: 更新锁屏信息

    func update(song: Song?,
                source: StreamSource?,
                isPlaying: Bool,
                currentTime: Double,
                duration: Double,
                buffered: Double,
                playMode: PlayMode) {
        guard let song else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            artwork = nil
            lastArtworkSongID = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.singer.isEmpty ? "未知歌手" : song.singer,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            // 顺序/循环这个信息在 iOS 上无法直接展示；塞进"备注"方便调试面板看到
            MPMediaItemPropertyComments: "\(playMode.displayName)\(source.map { " · \($0.backendName)" } ?? "")",
        ]
        let total = duration > 0 ? duration : Double(song.durationSec)
        if total > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = total
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = min(max(currentTime, 0), total)
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        loadArtworkIfNeeded(for: song)
    }

    /// 锁屏卡的封面。
    ///
    /// r65：以前只读 `song.picURL`，于是"列表里有封面、锁屏/播放页却是空占位"
    /// （老板截屏里那条系统卡片就是空的）。现在跟列表行、播放页共用
    /// `CoverImageCache.image(for:)`：本地封面 → picURL → CoverResolver 兜底。
    private func loadArtworkIfNeeded(for song: Song) {
        guard song.id != lastArtworkSongID else { return }
        lastArtworkSongID = song.id
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let image = await CoverImageCache.shared.image(for: song) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                guard let self else { return }
                // 期间又切歌了：这张图属于上一首，丢掉
                guard self.lastArtworkSongID == song.id else { return }
                self.artwork = art
                if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    info[MPMediaItemPropertyArtwork] = art
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }
    }
}

import Foundation
import Observation
import SwiftUI

// MARK: - 设置（键名与 Android 对齐，见 IOS-FEATURE-PARITY §6–§9）
//
// 只放"用户可改、且各页面都要读"的项。播放模式与音质已经由 PlayerEngine 持有并持久化
// （键 `play_mode` / `quality`），这里不重复存，避免两个事实源。
//
// 第四十轮（2026-11-18，老板："设置页面太乱太杂了"）：设置页只留**真正需要用户做决定**的项。
// 下面这些都是"只能这么办"的默认行为，改回代码里的常量，不再出现在界面上：
//   · 音质偏好 → 恒为最高档（无损），拿不到由 `SourcePicker` 逐级往下降；
//   · 无源自动换源 / 跨平台补源 / 无源自动跳过 → 恒开；
//   · 连续跳过上限 → 恒 3 首（`PlaybackRules.autoSkipLimit`）；
//   · 逐字动画 → 词里有毫秒级逐字时间就逐字染色，只有行级时间就整行（见 NowPlayingView）；
//   · QQ 歌词源 → 内置，恒参与（见 `LddcLyrics.searchCandidates`）；
//   · 默认偏移 / 清空偏移 → 播放页按单曲微调照旧，默认值恒 0，不在设置页摆出来；
//   · 识别前暂停本机播放 → 恒暂停（不暂停收到的就是自己放的歌）。
// 新增：歌词缓存上限（原来是写死的 200 首）、车载自动播放、下载保存位置。
@Observable
final class SettingsStore {

    /// 全进程共用一份：下载编排（Service 层）要读「仅 Wi-Fi / 后台下载」两个开关，
    /// 而这两个开关的 UI 在设置页。共用同一个实例才不会出现"设置里关了、下载还照旧"。
    static let shared = SettingsStore()

    /// 外观：跟随系统 / 浅色 / 深色
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    /// 歌词字号档（跟随系统 / 大 / 特大）
    enum LyricFontScale: String, CaseIterable, Identifiable {
        case system, large, extraLarge
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .system: return "跟随系统"
            case .large: return "大"
            case .extraLarge: return "特大"
            }
        }
        var dynamicTypeSize: DynamicTypeSize? {
            switch self {
            case .system: return nil
            case .large: return .xxLarge
            case .extraLarge: return .accessibility1
            }
        }
    }

    private enum Key {
        static let appearance = "appearance"
        static let lyricFont = "lyrics_font"
        static let recognizeSeconds = "rec_seconds"
        static let wifiOnlyDownload = "wifi_only"
        static let backgroundDownload = "bg_download"
        /// iCloud 备份（默认**关**：老板 2026-11-21 定。关掉后重装/换机会丢本地文件）
        static let iCloudBackup = "icloud_backup"
        static let lyricOffsetPerSong = "lyric_offset_by_song"
        /// 歌词缓存上限（`LyricsCacheRules.key`，LyricsService 直接读同一个键）
        static let lyricsCacheLimit = LyricsCacheRules.key
        /// 车载（车机 / 车载蓝牙）连上就自动播
        static let carAutoPlay = "car_auto_play"
        /// 心动模式「熟悉度」：旧爱（收藏 / 下载过）在连播里的占比
        static let heartbeatOldShare = "heartbeat_old_share"
        /// 下载保存位置：安全书签（Data）+ 显示名（键定义在 `DownloadLocation`，
        /// 因为下载落盘在 URLSession 的 delegate 队列上，那边不能读 @Observable 的 store）
        static let downloadBookmark = DownloadLocation.bookmarkKey
        static let downloadFolderName = DownloadLocation.folderNameKey
    }

    private let defaults = UserDefaults.standard

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var lyricFontScale: LyricFontScale {
        didSet { defaults.set(lyricFontScale.rawValue, forKey: Key.lyricFont) }
    }

    /// 识曲聆听时长（12 / 15 / 20 秒，默认 12，与 Android 一致）
    var recognizeSeconds: Int {
        didSet { defaults.set(recognizeSeconds, forKey: Key.recognizeSeconds) }
    }

    var wifiOnlyDownload: Bool {
        didSet { defaults.set(wifiOnlyDownload, forKey: Key.wifiOnlyDownload) }
    }

    var backgroundDownload: Bool {
        didSet { defaults.set(backgroundDownload, forKey: Key.backgroundDownload) }
    }

    /// 本地文件是否进 iCloud 备份（默认关）。改完立刻对整个下载目录生效。
    var iCloudBackup: Bool {
        didSet {
            defaults.set(iCloudBackup, forKey: Key.iCloudBackup)
            DownloadLocation.applyBackupExclusion(!iCloudBackup)
        }
    }

    /// 歌词缓存最多留多少首（默认 200，与 r74 起写死的那个常量一致）。
    /// 超出后按"最旧的先丢"裁剪——歌词缓存丢了大不了重下，不值得做 LRU。
    var lyricsCacheLimit: Int {
        didSet {
            let clamped = LyricsCacheRules.clamp(lyricsCacheLimit)
            if clamped != lyricsCacheLimit { lyricsCacheLimit = clamped }
            defaults.set(clamped, forKey: Key.lyricsCacheLimit)
        }
    }

    /// 车载自动播放：连上车机 / 车载蓝牙后自动开始放。
    ///
    /// 默认开：老板要的就是"上车就响"。播什么见 `CarAudioAutoPlay`——
    /// 有上次没播完的从那句接着放，没有就放热门。
    var carAutoPlay: Bool {
        didSet { defaults.set(carAutoPlay, forKey: Key.carAutoPlay) }
    }

    /// 心动模式「熟悉度」：下一次心动连播里，"旧爱（收藏 / 下载过）"占多少。
    ///
    /// 0 = 全推没听过的新歌；默认 1/3（三首里两首新、一首旧）；上限 0.6。
    /// 再高就退化成"随机播放收藏"了——那是另一种模式，不是心动。
    var heartbeatOldShare: Double {
        didSet {
            let clamped = HeartbeatRules.clampOldShare(heartbeatOldShare)
            if clamped != heartbeatOldShare { heartbeatOldShare = clamped }
            defaults.set(clamped, forKey: Key.heartbeatOldShare)
        }
    }

    /// 自选下载文件夹的安全书签（nil = 用 App 自己的「文件 › JZ 音乐 › 音乐」）
    var downloadFolderBookmark: Data? {
        didSet {
            if let data = downloadFolderBookmark {
                defaults.set(data, forKey: Key.downloadBookmark)
            } else {
                defaults.removeObject(forKey: Key.downloadBookmark)
            }
        }
    }

    /// 自选文件夹的显示名（「文件」App 里看到的那一层名字）
    var downloadFolderName: String? {
        didSet {
            if let name = downloadFolderName {
                defaults.set(name, forKey: Key.downloadFolderName)
            } else {
                defaults.removeObject(forKey: Key.downloadFolderName)
            }
        }
    }

    /// 单曲偏移（`Song.id` → 毫秒绝对值，**0 也会存**：表示"这首就是要对齐"）。
    ///
    /// 默认偏移（全局那一个数）在第四十轮下线：老板要的是"设置页别再摆这些"，
    /// 而按单曲记的微调是播放页实际在用的（同一首歌不同版本前奏能差几秒），保留。
    private(set) var lyricOffsetBySong: [String: Int] {
        didSet {
            defaults.set(lyricOffsetBySong, forKey: Key.lyricOffsetPerSong)
        }
    }

    /// 偏移的唯一边界口径（播放页微调、引擎消费都走它）
    static func clampOffset(_ value: Int) -> Int { LyricOffsetRules.clamp(value) }

    // MARK: 单曲偏移

    /// 这一首实际生效的偏移（没单独调过就是 0 = 对齐）
    func offsetMs(forSong songID: String?) -> Int {
        LyricOffsetRules.effective(global: 0,
                                   perSong: lyricOffsetBySong,
                                   songID: songID)
    }

    /// 播放页「慢一点 / 快一点」：只动这一首
    func adjustOffset(byMs delta: Int, forSong songID: String?) {
        let next = LyricOffsetRules.adjusted(global: 0,
                                             perSong: lyricOffsetBySong,
                                             songID: songID,
                                             byMs: delta)
        setOffset(next, forSong: songID)
    }

    /// 「归零」：这一首回到 0
    func resetOffset(forSong songID: String?) {
        setOffset(0, forSong: songID)
    }

    /// 直接写这一首的偏移
    func setOffset(_ value: Int, forSong songID: String?) {
        guard let songID else { return }
        lyricOffsetBySong[songID] = Self.clampOffset(value)
    }

    /// 被单独调过的歌数（播放页菜单里显示"已单独调过 N 首"）
    var songOffsetCount: Int { lyricOffsetBySong.count }

    init() {
        let d = UserDefaults.standard
        appearance = Appearance(rawValue: d.string(forKey: Key.appearance) ?? "system") ?? .system
        lyricFontScale = LyricFontScale(rawValue: d.string(forKey: Key.lyricFont) ?? "system") ?? .system
        let seconds = d.integer(forKey: Key.recognizeSeconds)
        recognizeSeconds = [12, 15, 20].contains(seconds) ? seconds : 12
        wifiOnlyDownload = d.object(forKey: Key.wifiOnlyDownload) as? Bool ?? true
        backgroundDownload = d.object(forKey: Key.backgroundDownload) as? Bool ?? true
        iCloudBackup = d.object(forKey: Key.iCloudBackup) as? Bool ?? false

        let savedLimit = d.integer(forKey: Key.lyricsCacheLimit)
        lyricsCacheLimit = savedLimit > 0 ? LyricsCacheRules.clamp(savedLimit)
                                          : LyricsCacheRules.defaultLimit

        carAutoPlay = d.object(forKey: Key.carAutoPlay) as? Bool ?? true

        let savedShare = d.object(forKey: Key.heartbeatOldShare) as? Double
        heartbeatOldShare = savedShare.map(HeartbeatRules.clampOldShare)
            ?? HeartbeatRules.defaultOldShare

        downloadFolderBookmark = d.data(forKey: Key.downloadBookmark)
        downloadFolderName = d.string(forKey: Key.downloadFolderName)

        let perSong = d.dictionary(forKey: Key.lyricOffsetPerSong) as? [String: Int] ?? [:]
        lyricOffsetBySong = perSong.mapValues { Self.clampOffset($0) }
    }
}

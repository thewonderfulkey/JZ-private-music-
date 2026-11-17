import Foundation
import Observation
import SwiftUI

// MARK: - 设置（键名与 Android 对齐，见 IOS-FEATURE-PARITY §6–§9）
//
// 只放"用户可改、且各页面都要读"的项。播放模式与音质已经由 PlayerEngine 持有并持久化
// （键 `play_mode` / `quality`），这里不重复存，避免两个事实源。
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
        static let autoFallback = "auto_fallback"
        static let crossPlatform = "cross_platform"
        static let autoSkip = "auto_skip"
        static let skipLimit = "skip_limit"
        static let lyricAnimation = "lyric_anim"
        static let lyricFont = "lyrics_font"
        static let lyricsQQ = LddcLyrics.qqPrefKey
        static let recognizeSeconds = "rec_seconds"
        static let pauseBeforeRecognize = "rec_pause"
        static let wifiOnlyDownload = "wifi_only"
        static let backgroundDownload = "bg_download"
        static let lyricOffset = "lyric_offset_ms"
        static let lyricOffsetPerSong = "lyric_offset_by_song"
        /// r71 的一次性迁移标记：旧版那个全局偏移升级时归零（否则它会把每首歌都推歪）
        static let lyricOffsetMigrated = "lyric_offset_migrated_v71"
    }

    private let defaults = UserDefaults.standard

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }
    var autoFallback: Bool {
        didSet { defaults.set(autoFallback, forKey: Key.autoFallback) }
    }
    var crossPlatformBackfill: Bool {
        didSet { defaults.set(crossPlatformBackfill, forKey: Key.crossPlatform) }
    }
    var autoSkipDeadSongs: Bool {
        didSet { defaults.set(autoSkipDeadSongs, forKey: Key.autoSkip) }
    }
    var skipLimit: Int {
        didSet { defaults.set(skipLimit, forKey: Key.skipLimit) }
    }
    var lyricAnimation: Bool {
        didSet { defaults.set(lyricAnimation, forKey: Key.lyricAnimation) }
    }
    /// QQ 歌词源（实验，默认关）：老板手机开回国代理时可能可用。
    /// 打开后 QQ 作为**并行候选**参与（2.5 秒上限），只在其返回可用且身份一致时采用，
    /// 不挡主链、超时也不拖慢取词（见 `LddcLyrics.searchCandidates`）。
    var lyricsQQEnabled: Bool {
        didSet { defaults.set(lyricsQQEnabled, forKey: Key.lyricsQQ) }
    }

    var lyricFontScale: LyricFontScale {
        didSet { defaults.set(lyricFontScale.rawValue, forKey: Key.lyricFont) }
    }
    /// 识曲聆听时长（12 / 15 / 20 秒，默认 12，与 Android 一致）
    var recognizeSeconds: Int {
        didSet { defaults.set(recognizeSeconds, forKey: Key.recognizeSeconds) }
    }
    var pauseBeforeRecognize: Bool {
        didSet { defaults.set(pauseBeforeRecognize, forKey: Key.pauseBeforeRecognize) }
    }
    var wifiOnlyDownload: Bool {
        didSet { defaults.set(wifiOnlyDownload, forKey: Key.wifiOnlyDownload) }
    }
    var backgroundDownload: Bool {
        didSet { defaults.set(backgroundDownload, forKey: Key.backgroundDownload) }
    }
    /// 歌词时间偏移的**默认值**（毫秒）：正数 = 歌词提前，负数 = 歌词延后；范围 ±2000，步进 200
    ///
    /// 为什么放到 ±2000：第四轮老板说"歌词还是没对上"。同一个歌名不同版本（Live / 重制 / 电视剧版）
    /// 的前奏能差好几秒，±600 根本调不动；真机上现场按「快一点 / 慢一点」最多 20 下就能对齐。
    ///
    /// r71 起这只是**默认值**：播放页的微调写进 `lyricOffsetBySong`（按单曲），
    /// 否则调一首歌会顺手把别的歌全推走（老板原话："其他歌曲原来还是准的、现在又不准了"）。
    var lyricOffsetMs: Int {
        didSet {
            let clamped = Self.clampOffset(lyricOffsetMs)
            if clamped != lyricOffsetMs { lyricOffsetMs = clamped }
            defaults.set(clamped, forKey: Key.lyricOffset)
        }
    }

    /// 单曲偏移（`Song.id` → 毫秒绝对值，**0 也会存**：表示"这首就是要对齐"）。
    /// 没被单独调过的歌不在这里，直接吃默认值。
    private(set) var lyricOffsetBySong: [String: Int] {
        didSet {
            defaults.set(lyricOffsetBySong, forKey: Key.lyricOffsetPerSong)
        }
    }

    /// 偏移的唯一边界口径（设置页 Stepper、播放页微调、引擎消费都走它）
    static func clampOffset(_ value: Int) -> Int { LyricOffsetRules.clamp(value) }

    // MARK: 单曲偏移

    /// 这一首实际生效的偏移（没有单曲值时就用默认值）
    func offsetMs(forSong songID: String?) -> Int {
        LyricOffsetRules.effective(global: lyricOffsetMs,
                                   perSong: lyricOffsetBySong,
                                   songID: songID)
    }

    /// 播放页「慢一点 / 快一点」：只动这一首
    func adjustOffset(byMs delta: Int, forSong songID: String?) {
        let next = LyricOffsetRules.adjusted(global: lyricOffsetMs,
                                             perSong: lyricOffsetBySong,
                                             songID: songID,
                                             byMs: delta)
        setOffset(next, forSong: songID)
    }

    /// 「归零」：这一首回到 0（写成单曲值 0，**不动**设置页的默认值）
    func resetOffset(forSong songID: String?) {
        setOffset(0, forSong: songID)
    }

    /// 直接写这一首的偏移
    func setOffset(_ value: Int, forSong songID: String?) {
        guard let songID else { return }
        lyricOffsetBySong[songID] = Self.clampOffset(value)
    }

    /// 「清空所有单曲偏移」：把所有按单曲记的值一次性去掉（设置页的默认值保留）
    func clearAllSongOffsets() {
        guard !lyricOffsetBySong.isEmpty else { return }
        lyricOffsetBySong = [:]
    }

    /// 被单独调过的歌数（设置页显示"已单独调过 N 首"）
    var songOffsetCount: Int { lyricOffsetBySong.count }

    init() {
        let d = UserDefaults.standard
        appearance = Appearance(rawValue: d.string(forKey: Key.appearance) ?? "system") ?? .system
        autoFallback = d.object(forKey: Key.autoFallback) as? Bool ?? true
        crossPlatformBackfill = d.object(forKey: Key.crossPlatform) as? Bool ?? true
        autoSkipDeadSongs = d.object(forKey: Key.autoSkip) as? Bool ?? true
        let limit = d.integer(forKey: Key.skipLimit)
        skipLimit = limit > 0 ? limit : 3
        lyricAnimation = d.object(forKey: Key.lyricAnimation) as? Bool ?? true
        lyricFontScale = LyricFontScale(rawValue: d.string(forKey: Key.lyricFont) ?? "system") ?? .system
        lyricsQQEnabled = d.object(forKey: Key.lyricsQQ) as? Bool ?? false
        let seconds = d.integer(forKey: Key.recognizeSeconds)
        recognizeSeconds = [12, 15, 20].contains(seconds) ? seconds : 12
        pauseBeforeRecognize = d.object(forKey: Key.pauseBeforeRecognize) as? Bool ?? true
        wifiOnlyDownload = d.object(forKey: Key.wifiOnlyDownload) as? Bool ?? true
        backgroundDownload = d.object(forKey: Key.backgroundDownload) as? Bool ?? true
        // r71 迁移：以前偏移是**全局一个数**，为了对齐某一首调出来的值会把其它歌一起推走
        // （老板："其他歌曲原来还是准的、现在又不准了"）。升级到这一版时一次性归零，
        // 让所有歌先回到"对齐"状态；之后微调只写单曲，默认值仍可在设置页重设。
        let offsetMigrated = d.bool(forKey: Key.lyricOffsetMigrated)
        if offsetMigrated {
            lyricOffsetMs = Self.clampOffset(d.integer(forKey: Key.lyricOffset))
        } else {
            lyricOffsetMs = 0
            d.set(0, forKey: Key.lyricOffset)
            d.set(true, forKey: Key.lyricOffsetMigrated)
        }
        let perSong = d.dictionary(forKey: Key.lyricOffsetPerSong) as? [String: Int] ?? [:]
        lyricOffsetBySong = perSong.mapValues { Self.clampOffset($0) }
    }
}


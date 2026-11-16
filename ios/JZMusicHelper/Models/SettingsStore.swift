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
        static let recognizeSeconds = "rec_seconds"
        static let pauseBeforeRecognize = "rec_pause"
        static let wifiOnlyDownload = "wifi_only"
        static let backgroundDownload = "bg_download"
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
        let seconds = d.integer(forKey: Key.recognizeSeconds)
        recognizeSeconds = [12, 15, 20].contains(seconds) ? seconds : 12
        pauseBeforeRecognize = d.object(forKey: Key.pauseBeforeRecognize) as? Bool ?? true
        wifiOnlyDownload = d.object(forKey: Key.wifiOnlyDownload) as? Bool ?? true
        backgroundDownload = d.object(forKey: Key.backgroundDownload) as? Bool ?? true
    }
}

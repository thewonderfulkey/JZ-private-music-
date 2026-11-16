import SwiftUI

// MARK: - 设置（设计稿 §3.11）
//
// 分组顺序照设计稿：外观 / 播放 / 歌词 / 识曲 / 下载 / 数据 / 关于。
// 键名与 Android 对齐（见 IOS-FEATURE-PARITY §6–§9）；破坏性操作一律二次确认 + 报数量。
struct SettingsView: View {

    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @EnvironmentObject private var downloads: DownloadManager

    @State private var lyricsCacheCount = 0
    @State private var showClearLyricsConfirm = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("外观") {
                Picker("外观", selection: $settings.appearance) {
                    ForEach(SettingsStore.Appearance.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("播放") {
                Picker("音质偏好", selection: Binding(
                    get: { player.quality },
                    set: { player.quality = $0 }
                )) {
                    ForEach(QualityLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Toggle("无源自动换源", isOn: $settings.autoFallback)
                Toggle("跨平台补源", isOn: $settings.crossPlatformBackfill)
                Toggle("无源自动跳过", isOn: $settings.autoSkipDeadSongs)
                Stepper("连续跳过上限：\(settings.skipLimit) 首",
                        value: $settings.skipLimit, in: 1...10)
            }

            Section("歌词") {
                Toggle("逐字动画", isOn: $settings.lyricAnimation)
                Picker("歌词字号", selection: $settings.lyricFontScale) {
                    ForEach(SettingsStore.LyricFontScale.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                Stepper("时间偏移：\(lyricOffsetText)",
                        value: $settings.lyricOffsetMs, in: -600...600, step: 100)
                Text("歌词比声音慢就往上调（正数 = 歌词提前），反之往下调。播放页歌词区也有「快一点 / 慢一点」现场微调。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("已缓存", value: "\(lyricsCacheCount) 首")
                Button("清空歌词缓存", role: .destructive) {
                    showClearLyricsConfirm = true
                }
            }

            Section("锁屏与灵动岛") {
                Toggle("实时活动（锁屏歌词 / 灵动岛）", isOn: $settings.liveActivityEnabled)
                Text(settings.liveActivityEnabled
                     ? "播放时会在锁屏与灵动岛显示歌词卡片；暂停着退到后台、或退出 App 时会收掉，不留残影。"
                     : "已关闭：播放时不会创建任何实时活动，退出 App 后系统里也不会留音乐组件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("识曲") {
                Picker("聆听时长", selection: $settings.recognizeSeconds) {
                    Text("12 秒").tag(12)
                    Text("15 秒").tag(15)
                    Text("20 秒").tag(20)
                }
                .pickerStyle(.segmented)
                Toggle("识别前暂停本机播放", isOn: $settings.pauseBeforeRecognize)
            }

            Section("下载") {
                Picker("默认音质", selection: Binding(
                    get: { player.quality },
                    set: { player.quality = $0 }
                )) {
                    ForEach(QualityLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Toggle("仅 Wi-Fi 下载", isOn: $settings.wifiOnlyDownload)
                Toggle("后台下载", isOn: $settings.backgroundDownload)
                LabeledContent("已下载", value: "\(downloads.items.count) 首")
                LabeledContent("保存位置", value: "文件 › JZ 音乐 › 下载")
            }

            Section("数据") {
                Button("清空搜索历史（\(library.searchHistory.count) 条）", role: .destructive) {
                    library.clearSearchHistory()
                }
                Button("清空最近播放（\(library.recentSongs.count) 首）", role: .destructive) {
                    library.clearRecent()
                }
                Button("清空识曲历史（\(library.recognizeHistory.count) 首）", role: .destructive) {
                    library.clearRecognizeHistory()
                }
            }

            Section("关于") {
                LabeledContent("应用", value: "JZ 音乐")
                LabeledContent("版本", value: appVersion)
                Text("音乐与歌词来自第三方公开接口（QQ 音乐 / 网易云 / 酷我 / 酷狗），仅供个人使用；版权归各平台所有。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Tokens.Palette.paper)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            lyricsCacheCount = await LyricsService.shared.cachedCount()
        }
        .confirmationDialog("清空 \(lyricsCacheCount) 首歌词缓存？",
                            isPresented: $showClearLyricsConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                Task {
                    await LyricsService.shared.clearCache()
                    lyricsCacheCount = await LyricsService.shared.cachedCount()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var lyricOffsetText: String {
        let v = settings.lyricOffsetMs
        if v == 0 { return "0 ms（对齐）" }
        return v > 0 ? "+\(v) ms（提前）" : "\(v) ms（延后）"
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

import SwiftUI

// MARK: - 设置（设计稿 §3.11）
//
// 分组顺序照设计稿：外观 / 播放 / 歌词 / 识曲 / 下载 / 数据 / 关于。
// 键名与 Android 对齐（见 IOS-FEATURE-PARITY §6–§9）；破坏性操作一律二次确认 + 报数量。
//
// 第四轮（老板反馈 ③）：这页从"收藏页右上角齿轮"挪成**独立 Tab**（见 RootTabView），
// 所以标题用大标题、和发现/识曲/下载三个 Tab 保持一致。
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
                Stepper("默认偏移：\(lyricOffsetText)",
                        value: $settings.lyricOffsetMs, in: -2000...2000, step: 100)
                Button("把默认偏移归零") { settings.lyricOffsetMs = 0 }
                if settings.songOffsetCount > 0 {
                    Button("清空所有单曲偏移（\(settings.songOffsetCount) 首）", role: .destructive) {
                        settings.clearAllSongOffsets()
                    }
                }
                Text("时间偏移的默认值：歌词比声音慢（唱到下一句了字还没亮）就往上调正数（让歌词提前），反之调负数。播放页歌词区的「快一点 / 慢一点」只调当前这一首（按单曲记住，±2 秒），不会影响其它歌——同一个歌名不同版本（Live / 重制）前奏常差几秒，靠它手动对齐。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("已缓存", value: "\(lyricsCacheCount) 首")
                Button("清空歌词缓存", role: .destructive) {
                    showClearLyricsConfirm = true
                }
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
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerClearance() }
        .scrollContentBackground(.hidden)
        .background(Tokens.Palette.paper)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
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

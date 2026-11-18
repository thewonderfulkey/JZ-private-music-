import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置（设计稿 §3.11）
//
// 分组顺序照设计稿：外观 / 播放 / 歌词 / 识曲 / 下载 / 数据 / 关于。
// 键名与 Android 对齐（见 IOS-FEATURE-PARITY §6–§9）；破坏性操作一律二次确认 + 报数量。
//
// 第四轮（老板反馈 ③）：这页从"收藏页右上角齿轮"挪成**独立 Tab**（见 RootTabView），
// 所以标题用大标题、和发现/识曲/下载三个 Tab 保持一致。
//
// 第四十轮（2026-11-18，老板："设置页面有些太乱太杂了，有些设置选项是不需要展示的"）：
// 这一页只留"用户真的要做决定"的项。以下全部下线（行为退回代码里的固定口径，不再可配）：
//   音质偏好（恒最高档，拿不到自动降档）· 无源自动换源 / 跨平台补源 / 无源自动跳过（恒开）
//   · 连续跳过上限（恒 3 首）· 逐字动画（有毫秒级词就逐字、没有就整行）
//   · QQ 歌词源（内置）· 默认偏移 / 清空偏移（播放页按单曲调，默认 0）
//   · 识别前暂停本机播放（恒暂停）
// 新上：可缓存歌曲数量（歌词缓存上限）· 车载自动播放 · 下载保存位置可选。
struct SettingsView: View {

    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var library
    @EnvironmentObject private var downloads: DownloadManager

    @State private var lyricsCacheCount = 0
    @State private var showClearLyricsConfirm = false
    @State private var showFolderPicker = false
    @State private var folderError: String?

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
                Toggle("车载自动播放", isOn: $settings.carAutoPlay)
                Text("连上车载蓝牙或车机后自动开始放：上次没播完的从断开的地方接着放，没有就放热门歌单。App 被系统杀掉之后需要先打开一次。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("歌词") {
                Picker("歌词字号", selection: $settings.lyricFontScale) {
                    ForEach(SettingsStore.LyricFontScale.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                Stepper("可缓存歌曲数量：\(settings.lyricsCacheLimit) 首",
                        value: $settings.lyricsCacheLimit,
                        in: LyricsCacheRules.minLimit...LyricsCacheRules.maxLimit,
                        step: LyricsCacheRules.step)
                Text("歌词缓存最多留这么多首，超出后先丢最旧的（丢了大不了重下）。")
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
            }

            Section("下载") {
                Toggle("仅 Wi-Fi 下载", isOn: $settings.wifiOnlyDownload)
                Toggle("后台下载", isOn: $settings.backgroundDownload)
                LabeledContent("已下载", value: "\(downloads.items.count) 首")
                Button {
                    showFolderPicker = true
                } label: {
                    LabeledContent("保存位置", value: settings.downloadFolderName ?? DownloadLocation.defaultFolderName)
                        .foregroundStyle(.primary)
                }
                if let name = settings.downloadFolderName {
                    Button("恢复默认保存位置（\(DownloadLocation.defaultFolderName)）") {
                        settings.downloadFolderBookmark = nil
                        settings.downloadFolderName = nil
                        folderError = nil
                    }
                }
                Text(downloadFolderHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let folderError {
                    Text(folderError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
        .fileImporter(isPresented: $showFolderPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // 选完必须"就地"建书签：`startAccessing` 只在这段作用域内有效
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let bookmark = DownloadLocation.makeBookmark(for: url) else {
                    folderError = "这个文件夹拿不到长期权限，请换一个（例如「我的 iPhone」下的文件夹）。"
                    return
                }
                settings.downloadFolderBookmark = bookmark
                settings.downloadFolderName = url.lastPathComponent
                folderError = nil
            case .failure(let error):
                folderError = "没选成文件夹：\(error.localizedDescription)"
            }
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

    private var downloadFolderHint: String {
        if let name = settings.downloadFolderName {
            return "已选「\(name)」：新下载的歌存到这里，已经下好的不动。删掉或移走这个文件夹，会退回默认位置。"
        }
        return "默认存在 App 自己的文件夹：文件 › JZ 音乐 › \(DownloadLocation.defaultFolderName)。也可以点上面选「文件」App 里的其它文件夹。"
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

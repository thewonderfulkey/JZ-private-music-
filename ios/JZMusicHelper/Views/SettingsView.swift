import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var historyStore: HistoryStore
    @AppStorage("defaultQuality") private var defaultQualityRaw: String = QualityLevel.high.rawValue
    @AppStorage("useBackgroundDownload") private var useBackgroundDownload: Bool = true
    /// 歌词服务内存缓存里现在有多少首（进设置页时刷新）
    @State private var lyricsCacheCount = 0

    private var defaultQuality: QualityLevel {
        get { QualityLevel(rawValue: defaultQualityRaw) ?? .high }
        set { defaultQualityRaw = newValue.rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("下载设置") {
                    Picker("默认音质", selection: Binding(
                        get: { defaultQuality },
                        set: { defaultQualityRaw = $0.rawValue }
                    )) {
                        ForEach(QualityLevel.allCases, id: \.self) { q in
                            Text(q.displayName).tag(q)
                        }
                    }
                    Toggle("后台下载", isOn: $useBackgroundDownload)
                    Text("后台下载使用系统后台会话，App 退到后台仍会继续；第三方源链接带签名可能过期导致失败。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("保存位置") {
                    HStack {
                        Text("文件 App 目录")
                        Spacer()
                        Text("我的 iPhone / JZ的音乐助手")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Button("打开下载目录") {
                        openDownloadsFolder()
                    }
                }

                Section("数据管理") {
                    Button("清空搜索历史", role: .destructive) {
                        historyStore.clearSearchHistory()
                    }
                }

                Section("歌词") {
                    LabeledContent("已缓存", value: "\(lyricsCacheCount) 首")
                    Button("清空歌词缓存", role: .destructive) {
                        Task {
                            await LyricsService.shared.clearCache()
                            lyricsCacheCount = await LyricsService.shared.cachedCount()
                        }
                    }
                }

                Section("关于") {
                    LabeledContent("应用", value: "JZ的音乐助手")
                    LabeledContent("版本", value: "1.0")
                    Text("音乐源为第三方接口聚合（酷我/QQ/网易/酷狗系），仅供个人学习测试，请支持正版音乐。接口为实测可用状态，随时可能失效。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
            .task {
                lyricsCacheCount = await LyricsService.shared.cachedCount()
            }
        }
    }

    private func openDownloadsFolder() {
        // 使用 UIDocumentPickerViewController 展示应用沙箱文档目录，
        // 用户可在其中看到 Downloads/Music 下已下载的音频文件
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.audio, UTType.item],
                                                    asCopy: false)
        picker.allowsMultipleSelection = false
        root.present(picker, animated: true)
    }
}

#Preview {
    SettingsView()
}

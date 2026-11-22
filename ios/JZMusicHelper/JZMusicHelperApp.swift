import SwiftUI
import UserNotifications

@main
struct JZMusicHelperApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // 下载是 ObservableObject（内部要跑 URLSession delegate），其余是 iOS 17 的 @Observable
    @StateObject private var downloads = DownloadManager.shared
    @State private var player = MainActor.assumeIsolated { PlayerEngine() }
    @State private var library = LibraryStore.shared
    @State private var settings = SettingsStore.shared
    /// 导入进来的歌单（本地快照；发现页「我的歌单」与设置页「导入歌单」共用）
    @State private var myPlaylists = MyPlaylistStore.shared
    @State private var downloadFlow = MainActor.assumeIsolated { DownloadFlow() }
    @State private var discoverFeed = MainActor.assumeIsolated { DiscoverFeed() }
    @State private var squareFeed = MainActor.assumeIsolated { SquareFeed() }
    @State private var artistFeed = MainActor.assumeIsolated { ArtistFeed() }
    @State private var router = AppRouter()

    /// 开屏动画：只在**这次进程的第一次**显示（App 的 @State 一个进程只初始化一次，
    /// 所以从后台回来不会重播）。时长/曲线见 `Services/SplashTimeline.swift`。
    @State private var showSplash = true

    init() {
        // 下载完成提示（可选权限，拒绝也不影响下载）
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        // 收藏的文件级去重：收藏那一刻只做元数据级，指纹由后台补（延迟几秒，不和首屏抢网络）
        // 2026-11-22：再往后推一点 —— 它要读文件指针，开屏动画期间不该跟主线程抢 I/O。
        let excludeFromBackup = !SettingsStore.shared.iCloudBackup
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            FavoriteDedupeService.shared.scheduleLaunchPass()
        }
        // 2026-11-22（老板："开屏动画总是卡一下，新包第一次更严重"）：
        // `applyBackupExclusion` 会枚举 Documents 下最多 5000 个文件、**逐个** `setResourceValues`。
        // 以前它在 `init` 里同步跑 —— 也就是第一帧之前，开屏动画还没开始就被它拖住了。
        // 现在等开屏动画走完（1.7s）+ 几秒缓冲，再丢到后台队列慢慢设。
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            DispatchQueue.global(qos: .utility).async {
                DownloadLocation.applyBackupExclusion(excludeFromBackup)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // 首页在开屏底下**照常挂载**：启动时它自己的首帧数据/布局跟动画同时跑，
                // 动画一退场就是现成的界面，不用再等一次白屏。
                RootTabView()
                    .environment(player)
                    .environment(library)
                    .environment(settings)
                    .environment(myPlaylists)
                    .environment(downloadFlow)
                    .environment(discoverFeed)
                    .environment(squareFeed)
                    .environment(artistFeed)
                    .environment(router)
                    .environmentObject(downloads)
                    // 开屏期间首页既点不到，VoiceOver 也读不到（否则读屏会把底下整页念一遍）
                    .allowsHitTesting(!showSplash)
                    .accessibilityHidden(showSplash)

                if showSplash {
                    SplashView {
                        // 自然播完时纸底已经淡到 0，这层 animation 只是给"点击跳过"一个收尾
                        withAnimation(.easeOut(duration: 0.22)) { showSplash = false }
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }

                // 收藏去重的提示：老板要"自动化"，但必须让人看见发生了什么（不弹窗、不打断）
                if let notice = library.favoriteNotice {
                    VStack {
                        Spacer()
                        ToastView(text: notice)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(2)
                }
            }
            .animation(.easeOut(duration: 0.2), value: library.favoriteNotice)
            // 下载前发现本地已有同一首：问一句（并存 / 覆盖 / 取消）
            .confirmationDialog(
                downloadFlow.duplicatePrompt.map { "本地已有《\($0.song.name)》" } ?? "",
                isPresented: Binding(
                    get: { downloadFlow.duplicatePrompt != nil },
                    set: { if !$0 { downloadFlow.resolveDuplicate(.cancel) } }),
                titleVisibility: .visible) {
                Button("仍然下载（两份并存）") { downloadFlow.resolveDuplicate(.keepBoth) }
                Button("覆盖本地（删旧再下）", role: .destructive) {
                    downloadFlow.resolveDuplicate(.replace)
                }
                Button("取消", role: .cancel) { downloadFlow.resolveDuplicate(.cancel) }
            } message: {
                if let local = downloadFlow.duplicatePrompt {
                    Text("已有：\(local.song.name) · \(local.song.singer)（\(local.quality.displayName) · \(local.sizeText)）")
                }
            }
            .preferredColorScheme(settings.appearance.colorScheme)
            .tint(Tokens.Palette.vermilion)
            // 「用 JZ 音乐打开」/ 共享进来的音频（第三条导入入口，不经过系统选择器）。
            // SwiftUI 是 scene-based：系统多半走场景回调而不是 AppDelegate 的 `application(_:open:)`，
            // 所以这里必须也接一份；两条路都汇到 `enqueueOpenIn`（0.4s 去重合并）。
            .onOpenURL { url in
                guard url.isFileURL else { return }
                DownloadManager.enqueueOpenIn([url])
            }
        }
    }
}

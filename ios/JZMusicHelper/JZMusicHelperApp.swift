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
            }
            .preferredColorScheme(settings.appearance.colorScheme)
            .tint(Tokens.Palette.vermilion)
        }
    }
}

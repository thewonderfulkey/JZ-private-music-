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
    @State private var downloadFlow = MainActor.assumeIsolated { DownloadFlow() }
    @State private var discoverFeed = MainActor.assumeIsolated { DiscoverFeed() }
    @State private var router = AppRouter()

    init() {
        // 下载完成提示（可选权限，拒绝也不影响下载）。
        // 模拟器冒烟测试时用 JZ_SKIP_NOTIFICATION_PROMPT=1 跳过：否则首启的系统弹窗会盖住截图。
        if ProcessInfo.processInfo.environment["JZ_SKIP_NOTIFICATION_PROMPT"] != "1" {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(player)
                .environment(library)
                .environment(settings)
                .environment(downloadFlow)
                .environment(discoverFeed)
                .environment(router)
                .environmentObject(downloads)
                .preferredColorScheme(settings.appearance.colorScheme)
                .tint(Tokens.Palette.vermilion)
        }
    }
}

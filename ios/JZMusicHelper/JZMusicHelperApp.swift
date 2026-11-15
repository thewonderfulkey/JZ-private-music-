import SwiftUI
import UserNotifications

@main
struct JZMusicHelperApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var playerManager = PlayerManager.shared
    @StateObject private var historyStore = HistoryStore.shared

    init() {
        // 请求通知权限（下载完成提示）
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(downloadManager)
                .environmentObject(playerManager)
                .environmentObject(historyStore)
                .onAppear {
                    historyStore.loadAll()
                }
        }
    }
}

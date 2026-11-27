import Foundation
import UserNotifications

// MARK: - 下载完成提醒的权限（2026-11-27 从 App.init 挪到这里）
//
// 以前 `JZMusicHelperApp.init` 第一行就 `requestAuthorization` —— 首次装包时系统弹窗
// 正好压在开屏动画上（老板问"为什么会有通知权限框"就是它）。
// 现在改成：**第一次真的开始下载时**才问，而且只问一次；拒绝也不影响下载，
// 只是下载完成不再发通知（`DownloadManager.notifyCompletion` 本来就会自己判权限）。

enum DownloadNotifications {

    private static let askedKey = "download.notifyAsked.v1"

    /// 第一次下载时调用：只问一次，不再重复弹
    static func requestIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: askedKey) else { return }
        d.set(true, forKey: askedKey)
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}

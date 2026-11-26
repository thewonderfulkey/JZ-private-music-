import Foundation

// MARK: - BANNER 轮播规则（2026-11-27，发现页 2.0 Task 5）
//
// 老板口径：BANNER 要能滑、能关，**只跳站内**（点外链等于把用户扔出 App）。
// 这里只放纯逻辑，UI 与网络都不进来，方便 CI 断言（本机无 Xcode，视图层只能靠真机验收）。

enum BannerRules {

    /// 自动轮播间隔（秒）
    static let autoAdvanceSec: Double = 4

    /// 0 条就整块不渲染（不留空壳）；1 条也不渲染轮播——一张图自动切来切去看着像闪屏
    static func shouldShow(count: Int) -> Bool { count > 0 }

    /// 只有 1 条时原地不动：不启定时器，省电也避免"同一张图自己闪"
    static func shouldAutoAdvance(count: Int) -> Bool { count > 1 }

    /// 循环下一张（右滑到末尾回到第一张；传负数也回绕，左滑用得上）
    static func nextIndex(current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let i = current % count
        return i < 0 ? i + count : i
    }

    /// 自动轮播的下一个下标：最后一张之后回到 0（不反向、不夹在末尾）
    static func advanced(from current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return nextIndex(current: current + 1, count: count)
    }

    /// 只留**站内可跳**的 banner：`playlistID` 为空的是演出/外链（网易 targetType 3000），
    /// 点了会把用户扔出 App，所以直接不进轮播。
    static func usable(_ items: [NeteaseBannerItem]) -> [NeteaseBannerItem] {
        items.filter { !$0.image.isEmpty && $0.playlistID != nil }
    }

    /// 今天是不是已经关过了（关闭只关当天，第二天自然回来）
    ///
    /// 用"本地日"而不是时间戳：老板要的是"今天别烦我"，不是"24 小时内别出现"——
    /// 第二天早上打开应该又能看到。
    static func isHidden(closedDay: Int?, today: Int) -> Bool {
        guard let closedDay else { return false }
        return closedDay == today
    }
}

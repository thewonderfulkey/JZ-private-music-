import Foundation

// MARK: - 版式规则（纯函数）
//
// 与 SwiftUI 无关，CI 的 logic-tests 可以直接断言。视图侧只负责把它们套到布局上
// （见 Views/ReadableWidth.swift）。
enum LayoutRules {

    /// iPad / 横屏下的内容最大宽度：单列 700 居中（设计口径见 IOS-IA-SCREENS §4.1）
    static let maxContentWidth: Double = 700

    /// 给定可用宽度，返回内容应占的宽度：
    ///   · 已知且比上限窄 → 原样（iPhone 竖屏 393 就是 393）
    ///   · 比上限宽 → 截到 700（iPad 1024 / 横屏 852）
    ///   · 未知（0 / 负数 / NaN）→ 直接给上限，让调用方按 700 布局
    static func contentWidth(available: Double, max: Double = maxContentWidth) -> Double {
        guard available.isFinite, available > 0 else { return max }
        return min(available, max)
    }

    /// 是否属于"宽屏"（需要居中限宽）：≥ 768 视为 iPad 竖屏起步宽度
    static func isWide(_ available: Double) -> Bool {
        available.isFinite && available >= 768
    }

    /// 播放页内容宽度：**必须钉在屏幕上，钉死。**
    ///
    /// 为什么单独抽出来当一个纯函数：第四轮老板录屏里播放页是"整页横向溢出"——
    /// 顶部收起/更多、歌名歌手、模式与下载、进度两端时间全被推到屏幕外，只剩居中那三个键。
    /// 起因是外层给到播放页的宽度比屏幕还宽（全屏 cover + 模糊背景这类组合会偶发），
    /// 而旧版式全靠 `Spacer` 把元素顶到两头，一宽就顶出屏幕。
    ///
    /// 口径：
    ///   · 可用宽度有效且不超过屏幕 → 原样用（iPhone 竖屏 393 就是 393）
    ///   · 可用宽度无效（0 / 负数 / NaN / ∞）或比屏幕还宽 → 退回屏幕宽
    ///   · iPad 之类宽屏再限 700（与其它页面的 `readableWidth` 同口径）
    static func playerWidth(available: Double, screen: Double) -> Double {
        let cap = (screen.isFinite && screen > 0) ? min(screen, maxContentWidth) : maxContentWidth
        guard available.isFinite, available > 0 else { return cap }
        return min(available, cap)
    }

    /// 播放页「封面 / 歌名 / 音质标签」与「功能键」之间那段留白的高度。
    ///
    /// 第五轮老板截屏：封面到播放栏之间空出一大块。根因不是封面太小，而是这块留白用了
    /// **无上限的 `Spacer()`**——屏幕上所有富余高度都被它吞在标题和功能键之间。
    /// 参考截屏（APK）里这段只有 ~60pt，其余高度落在最底部（状态行下面）。
    /// 现在按屏高给一个**有上限**的值：手机上大约 50~64pt，小屏也不会挤成一团。
    static func playerGap(availableHeight: Double) -> Double {
        guard availableHeight.isFinite, availableHeight > 0 else { return 48 }
        return min(max(availableHeight * 0.075, 12), 64)
    }
}

// MARK: - 歌词浏览手感（纯函数）
//
// 第五轮老板反馈 ⑤⑥⑦，全是**手感**问题，改坏了界面不会崩，只会表现为"还没看清就弹回去"
// "没点歌词却跳了""在歌词页一划就把播放页关了"。抽成纯函数，CI 能钉住这些阈值。
enum LyricsUXRules {

    /// 用户滑过歌词后，停留这么多秒没有新操作，就自动回到当前唱的那一句。
    ///
    /// 为什么是 4 秒：旧版一停手就立刻 `scrollTo` 回当前行，老板"还没来得及点就弹回去了"；
    /// 4 秒够看清两三行、也够点中想跳的那句，又不会让人以为自动跟随坏了。
    static let dwellSeconds: Double = 4

    /// 一次点击允许的最大位移（pt）：超过就按"滑动"处理，不跳歌。
    /// 之前整行铺满宽度、还带 4pt 上下留白，手指扫过就算点了；现在只认字上的一小块。
    static let tapMaxMovement: Double = 8

    /// 一次点击允许的最长按压（秒）：长按、拖拽都不算。
    static let tapMaxDuration: Double = 0.5

    /// 滑动结束后这段时间内的"触摸"只当刹车，不当点击（`ScrollView` 惯性滚动时点一下会停住，
    /// 这一下不能顺带跳歌）。
    static let tapCooldownAfterScroll: Double = 0.35

    /// 是不是一次有效点击（没怎么动、也没按太久）
    static func isTap(moved: Double, duration: Double) -> Bool {
        guard moved.isFinite, duration.isFinite else { return false }
        return abs(moved) <= tapMaxMovement && duration >= 0 && duration <= tapMaxDuration
    }

    /// 停留够了没有（`secondsSinceInteraction` = 距上次滑动/点击的秒数）
    static func shouldResumeFollowing(secondsSinceInteraction: Double) -> Bool {
        guard secondsSinceInteraction.isFinite else { return true }
        return secondsSinceInteraction >= dwellSeconds
    }

    /// 滑动结束后多久内的触摸要当成"刹车"
    static func isTapCoolingDown(secondsSinceScrollEnd: Double) -> Bool {
        guard secondsSinceScrollEnd.isFinite else { return false }
        return secondsSinceScrollEnd < tapCooldownAfterScroll
    }
}

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

    /// 播放页里相邻两块之间的**最小**间距（r63「封面撑满型」）。
    ///
    /// 第六轮老板截屏：封面到功能键那块留白被压到 64pt 之后，富余高度全堆到了播放键下面
    /// ——"进度条下方还有一大段空着的"。根因是整列**顶端对齐**：富余空间不会自己消失。
    /// 现在改成整列铺满（外层 VStack 高度 = 屏高，各段之间用等权 `Spacer`），
    /// 这个值只作为 `Spacer(minLength:)` 的下限：小屏上别挤成一团，大屏上富余由 Spacer 均分。
    static func playerGap(availableHeight: Double) -> Double {
        guard availableHeight.isFinite, availableHeight > 0 else { return 16 }
        return min(max(availableHeight * 0.02, 12), 24)
    }

    /// 播放页封面边长（r63「封面撑满型」）：让封面吃掉富余高度，其余元素铺满整屏。
    ///
    /// 口径：先把「除封面以外那些块的固定高度」估成 `chromeHeight`（顶栏 48 + 标题/标签 95 +
    /// 功能键 52 + 进度 40 + 播放键 72 + 底部呼吸 ≈ 380），剩下的高度 72% 给封面、28% 留给间距。
    /// 再限制「不超过屏宽 − 左右各 28pt」，夹在 140…380。
    /// 为什么不用"扣到精确"的算法：字体/动态字号一变，固定高度就变，估一个小常数比逐块测量稳，
    /// 而且间距是 `Spacer`，估偏了也会被它吸收。
    static func playerCoverSide(width: Double, height: Double) -> Double {
        let w = (width.isFinite && width > 0) ? width : 393
        let h = (height.isFinite && height > 0) ? height : 852
        let byWidth = w - 56
        let byHeight = (h - chromeHeight) * 0.72
        return max(140, min(min(byWidth, byHeight), 380))
    }

    /// 播放页除封面以外的块大致占掉的高度（估出来的常数，见 `playerCoverSide`）
    static let chromeHeight: Double = 380
}

// MARK: - 迷你播放条占位（纯函数）
//
// 第六轮老板反馈 ⑦："悬浮条和底层栏最后一条记录之间空隙太大，要严丝合缝。"
// 根因：条子本体 56 + 上下各 4 内边距 = 64，而列表末尾让了 `56 + 16` 的占位、又额外
// padding 了 32 —— 于是最后一条和条子之间空出 40pt。这里把"该让多少"钉成一个数。
enum MiniPlayerMetrics {

    /// 条子连同上下内边距占掉的真实高度
    static let barHeight: Double = 56 + 4 + 4

    /// 没在播歌时的页面底部呼吸（列表最后一条不要贴着屏幕边缘）
    static let idleBottomInset: Double = 24

    /// 列表末尾应该让出的高度：在播歌时**正好等于条子高度**（最后一条紧贴条子上沿）
    static func listBottomInset(playing: Bool) -> Double {
        playing ? barHeight : idleBottomInset
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

    /// 滚动的**提前量**（毫秒）。**r74 起为 0**。
    ///
    /// r65 老板说"歌词统一都是滚动晚了一些"，当时给滚动加了 220ms 提前量去抵消动画时长。
    /// 但 r74 老板把口径定死了：「LRC 每句前的中括号时间戳就是该句出现的时刻，除非 LRC 文件
    /// 本身错，否则滚动必须与时间戳严格对应」。提前量等于**故意让滚动比时间戳早 220ms**，
    /// 与这条口径冲突，所以归零：滚动与高亮用同一个下标（同一时刻）。
    /// 动画时长也压到 0.18s，尽量做到"时间戳一到就在中间"（见 `NowPlayingView.scroll`）。
    static let scrollLeadMs: Int = 0

    // MARK: seek 保护窗（r77）

    /// 保护窗内"现在能不能用播放位置改高亮"。
    ///
    /// 为什么要有这条判定：`AVPlayer.seek` 是异步的，跳转刚发出时 `currentTime()` 还是旧值。
    /// 以前是**写死 0.7 秒**：窗一过就无条件解保护，于是真机上（seek 常要 1~2 秒）ticker
    /// 会拿旧位置把刚设好的高亮拽回上一句，seek 落地后再弹回目标句 —— 老板 r76 说的
    /// "一旦通过歌词快进或者后退就变得不准了"就是这个。现在改成"**追上目标才解**，
    /// 超时只作为兜底"，超时上限放到 10 秒（由 seek 的完成回调提前解除）。
    static let seekGuardToleranceMs: Int = 400
    static let seekGuardMaxSeconds: Double = 10

    /// 点歌词跳转后允许"提前多少毫秒仍算落在这一行"。
    ///
    /// 真机上 seek 常落到目标前 200~600ms（关键帧对齐），2.5 秒足够覆盖这种情况；
    /// 再远就不是"落点误差"而是用户改了意图（拖进度条 / 换歌），此时不该继续钉住旧行。
    static let lyricSeekHoldToleranceMs: Int = 2500

    /// `.wait` = 这段时间的位置不可信，别动高亮；`.release` = 位置可信（追上目标了，或兜底超时）
    enum SeekGuardDecision: Equatable {
        case wait
        case release
    }

    /// - Parameters:
    ///   - positionMs: 当前播放位置（毫秒，**不含**用户偏移）
    ///   - targetMs: 这次 seek 的目标（毫秒）
    ///   - guardExpired: 兜底上限到了没有
    static func seekGuardDecision(positionMs: Int, targetMs: Int,
                                  guardExpired: Bool) -> SeekGuardDecision {
        // 已经跳到目标附近（±400ms）：位置可信，提前解保护
        if abs(positionMs - targetMs) <= seekGuardToleranceMs { return .release }
        // 还没到目标：窗内继续等（这时的位置一定是旧的）；窗过了也不能永远等
        return guardExpired ? .release : .wait
    }
}

// MARK: - 播放页下拽收起（纯函数）
//
// r65 老板："播放页手指下滑关闭播放页有点太不灵敏了，可以再灵敏一点，但不要影响歌词逻辑，
// 歌词上下滑动还是不能退出播放页。"
//
// 旧口径：位移 > 110pt，或预测位移 > 280pt → 关。实测手感很钝：手指要划掉四分之一屏才关得掉。
// 现在的口径（都调小，但保留"必须确实在往下拽"的约束，避免横滑/轻点误关）：
//   · 位移 ≥ 56pt 就关（约一个半指节的行程）
//   · 或者预测位移 ≥ 170pt（快速轻扫那一下）
// 歌词页压根不挂这个手势（见 NowPlayingView.page），所以调灵敏不会影响歌词上下滑。
enum PlayerDismissRules {

    /// 手指移动超过这个距离才算"在拽"（低于它当成轻点，交给按钮/双击）
    static let minDragDistance: Double = 8

    /// 松手时位移达到这个值就关（旧版 110，太钝）
    static let dismissDistance: Double = 56

    /// 或者"再滑一点点就到位"的预测位移达到这个值（快速轻扫）
    static let dismissPredictedDistance: Double = 170

    /// 松手判定：位移够远，或者预测位移够远
    static func shouldDismiss(translation: Double, predicted: Double) -> Bool {
        guard translation.isFinite, predicted.isFinite else { return false }
        guard translation > 0 else { return false }
        return translation >= dismissDistance || predicted >= dismissPredictedDistance
    }
}

// MARK: - 歌词偏移：**按单曲**记（纯函数）
//
// r71 老板："其他歌曲的歌词滚动原来还是准的、现在又不准了。"
//
// 根因不是渲染，是**偏移是全局的**：播放页那三个「慢一点 / 归零 / 快一点」以前直接改
// `SettingsStore.lyricOffsetMs`（UserDefaults 里一个数），于是为了对齐某一首（尤其《发如雪》
// 这种取不到词、只能反复按按钮的歌）调出来的偏移，会同时把**其它所有歌**一起推走。
// 老板看到的"别的歌本来准、现在不准"，就是这条全局量被改过之后的样子。
//
// 现在的口径：
//   · 播放页的微调只作用于**当前这首**（按 `Song.id` = 平台_ID 存一条绝对值，0 也存）；
//   · 设置页那个滑杆是**默认值**（没被单独调过的歌都用它）；
//   · 「归零」把这一首写成 0，设置页另有一个"清空所有单曲偏移"。
enum LyricOffsetRules {

    /// 偏移上下限（毫秒）：±2000 是第四轮定的，真机上前奏差几秒也调得动
    static let limitMs: Int = 2000

    /// 一次微调的步进（播放页三个胶囊每点一下）
    static let stepMs: Int = 200

    static func clamp(_ value: Int) -> Int {
        min(max(value, -limitMs), limitMs)
    }

    /// 这首实际生效的偏移：单曲绝对值优先（含 0），没有就用默认值
    static func effective(global: Int, perSong: [String: Int], songID: String?) -> Int {
        if let songID, let own = perSong[songID] { return clamp(own) }
        return clamp(global)
    }

    /// 微调之后这首的值（`byMs` 可正可负；结果照样夹在 ±2000）。
    /// 起点是**当前生效值**，不是默认值——否则在"默认值非 0 + 已单独调过"时会跳一下。
    static func adjusted(global: Int, perSong: [String: Int], songID: String?, byMs: Int) -> Int {
        clamp(effective(global: global, perSong: perSong, songID: songID) + byMs)
    }
}

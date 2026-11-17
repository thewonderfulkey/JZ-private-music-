import SwiftUI

// MARK: - 设计令牌
//
// 全 App **唯一**允许出现颜色/字号/间距数值的地方。设计依据：docs/ios/IOS-UI-DESIGN.md §3–§5。
//
// 约定（评审时按这条查）：
//   · 自定义颜色只有三个：`Color.paper` / `Color.paperElevated` / `Color.vermilion`（= AccentColor）
//   · 其余一律走语义色：`.label` / `.secondary` / `.tertiary` / `.separator`
//   · 字号一律用语义字体（`.title2` / `.body` …），不写 `Font.system(size:)`
//   · 圆角与间距只从这里取，不就地写字面量
enum Tokens {

    // MARK: 颜色

    enum Palette {
        /// 纸底（浅色 #FAF8F3 / 暗色 #0E0D0B）——页面与弹层背景
        static let paper = Color("Paper")
        /// 纸·浮（浅色 #FFFDF8 / 暗色 #1B1916）——卡片、分组行底
        static let paperElevated = Color("PaperElevated")
        /// 朱砂（浅色 #B03A2E / 暗色 #FF8A76）——一屏只允许一处实心使用
        static let vermilion = Color("AccentColor")
    }

    // MARK: 间距（4pt 基数）

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 28
        static let xxl: CGFloat = 32
        /// 页面左右边距（iPhone）
        static let pageMargin: CGFloat = 16
        /// 可点元素最小边长（HIG 44pt 硬指标）
        static let minTapTarget: CGFloat = 44
    }

    // MARK: 圆角（连续圆角）

    enum Radius {
        static let artworkSmall: CGFloat = 8
        static let card: CGFloat = 12
        static let artworkLarge: CGFloat = 16
        static let playerArtwork: CGFloat = 20
        static let sheet: CGFloat = 20
    }

    // MARK: 尺寸

    enum Size {
        static let songRowArtwork: CGFloat = 52
        static let songRowHeight: CGFloat = 72
        static let miniPlayerHeight: CGFloat = 56
        static let playButton: CGFloat = 56
        static let transportButton: CGFloat = 52
    }

    // MARK: 动效

    enum Motion {
        /// 封面 ↔ 歌词
        static let coverToggle = Animation.spring(response: 0.42, dampingFraction: 0.86)
        /// 歌词行推进
        static let lyricAdvance = Animation.spring(response: 0.28, dampingFraction: 1.0)
        /// 收藏心跳
        static let favorite = Animation.bouncy(duration: 0.26)
        /// 列表状态切换
        static let stateChange = Animation.snappy(duration: 0.26)
        /// 逐字染色单字时长（秒）
        static let perCharacterSeconds: Double = 0.14
    }
}

// MARK: - 语义字体角色
//
// 只做"角色 → 系统样式"的映射，方便统一改；不要在 View 里直接写字号。

enum FontRole {
    static let pageTitle = Font.largeTitle.weight(.bold)
    static let sectionTitle = Font.title3.weight(.semibold)
    static let songTitle = Font.body
    static let songSubtitle = Font.subheadline
    static let metadata = Font.footnote
    static let navInline = Font.headline
    static let playerTitle = Font.title.weight(.bold)
    static let playerArtist = Font.title3.weight(.medium)
    static let lyricCurrent = Font.title2.weight(.bold)
    static let lyricOther = Font.body
    static let button = Font.body.weight(.semibold)
}

// MARK: - 无障碍小工具

extension View {
    /// 把可点区域补到至少 44×44pt（列表行内的小按钮用）
    func minimumTapTarget() -> some View {
        frame(minWidth: Tokens.Spacing.minTapTarget,
              minHeight: Tokens.Spacing.minTapTarget)
            .contentShape(Rectangle())
    }
}

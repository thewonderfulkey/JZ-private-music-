import UIKit

// MARK: - 触觉
//
// 设计依据：docs/ios/IOS-UI-DESIGN.md §6.2。
// 原则：只在"状态真的变了"时给一下，滚动/翻页/每次打勾一律不给——
// 触觉过多等于没有触觉，而且会让节电模式下的表现更糟。
//
// 用法：`Haptics.playbackToggle()` / `Haptics.success()` 这类语义方法，
// 不要在业务代码里直接 new 生成器（生成器需要 prepare 才有低延迟）。
enum Haptics {

    // 生成器复用：反复 new 会有首击延迟
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    // MARK: 播放

    /// 播放 / 暂停
    static func playbackToggle() {
        light.impactOccurred()
    }

    /// 上一首 / 下一首
    static func trackChange() {
        light.impactOccurred()
    }

    /// 进度拖动经过整 10%（不要逐点触发）
    static func scrubTick() {
        selection.selectionChanged()
    }

    /// 收藏 / 取消收藏
    static func favorite() {
        light.impactOccurred()
    }

    /// 点歌词行跳到该句
    static func lyricSeek() {
        light.impactOccurred()
    }

    /// 麦克风开始聆听（物理动作，给 medium）
    static func listeningStart() {
        medium.impactOccurred()
    }

    // MARK: 结果

    /// 下载完成、识曲出结果
    static func success() {
        notification.notificationOccurred(.success)
    }

    /// 需要用户注意（无源、权限被拒）
    static func warning() {
        notification.notificationOccurred(.warning)
    }

    /// 明确失败（全部源解析失败）
    static func error() {
        notification.notificationOccurred(.error)
    }

    // MARK: 预热

    /// 进入可能触发触觉的界面前调一次，压低首击延迟
    static func prepare() {
        light.prepare()
        medium.prepare()
        selection.prepare()
    }
}

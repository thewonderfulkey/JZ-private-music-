import Foundation

// MARK: - 开屏动画的时间轴
//
// 纯数据 + 纯函数，**不 import SwiftUI**：这样它能进 CI 的 `logic-tests`（Linux/macOS 上 swiftc
// 直接编），每一拍的前后关系都能被断言钉住。视图层（`Views/SplashView.swift`）只读这里的常量，
// 自己不再写魔法数字。
//
// 动画在讲什么（三条都要成立，否则就是装饰）：
//   ① 落笔   头梁沿着自己的弧度长出来 —— 图标的第一笔
//   ② 戴上   两只耳罩自下弹入落位 —— "戴上耳机"这个动作本身
//   ③ 出声   声波 + 图标轻顶一下 —— 戴上之后音乐开始
// 然后才交棒给首页。总长压到 1.7s 以内：开屏是首启流失点，超过两秒就会有人烦。
enum SplashTimeline {

    /// 一拍：从 `start` 开始跑 `duration` 秒。
    struct Beat: Equatable {
        let start: Double
        let duration: Double

        var end: Double { start + duration }

        /// 该拍在 `time` 时刻的进度（0…1，两端夹紧，绝不越界）。
        func progress(at time: Double) -> Double {
            guard duration > 0 else { return time >= start ? 1 : 0 }
            let raw = (time - start) / duration
            return raw < 0 ? 0 : (raw > 1 ? 1 : raw)
        }

        func isActive(at time: Double) -> Bool { time >= start && time < end }
    }

    // MARK: 各拍

    /// 头梁：扇形遮罩从 152° 扫到 385°，墨沿着头梁的方向长出来
    static let bandDraw = Beat(start: 0.00, duration: 0.62)
    /// 左耳罩弹入（spring 0.40 / 0.72，落位时约 0.62s 后完全静止）
    static let cupLeft = Beat(start: 0.34, duration: 0.62)
    /// 右耳罩比左边晚 0.06s：两只同时落会像"啪"一下，错开才像"戴"
    static let cupRight = Beat(start: 0.40, duration: 0.62)
    /// 声波：两道朱砂弧从耳罩外侧荡开
    static let sound = Beat(start: 0.66, duration: 0.66)
    /// 图标轻顶（scale 1 → 1.04 → 1）
    static let thump = Beat(start: 0.66, duration: 0.32)
    /// 退场：纸底淡出、首页从 0.985 涨到 1
    static let exit = Beat(start: 1.30, duration: 0.42)
    /// 图标比纸底先走一步：不留一枚淡影压在新出现的封面上
    static let markFade = Beat(start: 1.30, duration: 0.28)
    /// 首页内容淡入（与退场交叉，不是等黑屏再出来）
    static let contentIn = Beat(start: 1.36, duration: 0.36)

    // MARK: 总长

    /// 全片时长（= 退场结束）。超过它就该把自己从层级里摘掉。
    static let total: Double = exit.end

    /// 减弱动效：不做落笔/弹入/声波，图标**直接就是完整的**，停一下再淡出。
    static let reduceMotionHold: Double = 0.35
    static let reduceMotionFade: Double = 0.30
    static var reduceMotionTotal: Double { reduceMotionHold + reduceMotionFade }

    // MARK: 纯函数（给视图层用，顺便被断言覆盖）

    static func exitProgress(at time: Double) -> Double { exit.progress(at: time) }

    static func markOpacity(at time: Double, reduceMotion: Bool) -> Double {
        if reduceMotion {
            let raw = (time - reduceMotionHold) / reduceMotionFade
            return 1 - (raw < 0 ? 0 : (raw > 1 ? 1 : raw))
        }
        return 1 - markFade.progress(at: time)
    }

    static func isFinished(at time: Double, reduceMotion: Bool) -> Bool {
        time >= (reduceMotion ? reduceMotionTotal : total)
    }
}

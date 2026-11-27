import Foundation

// MARK: - 开屏动画的时间轴
//
// 纯数据 + 纯函数，**不 import SwiftUI**：这样它能进 CI 的 `logic-tests`（Linux/macOS 上 swiftc
// 直接编），每一拍的前后关系、以及"画面上还有没有在动"都能被断言钉住。
// 视图层（`Views/SplashView.swift`）只读 `snapshot(at:)` 里的数，自己不再写魔法数字、也不再算曲线。
// （2026-11-22 之前 easeOut / spring / 声波透明度都散在视图里，于是"哪一段画面上不动"没人量得出来，
//   直到老板看见"卡在固定的一帧"。）
//
// 动画在讲什么（三条都要成立，否则就是装饰）：
//   ① 落笔   头梁沿着自己的弧度长出来 —— 图标的第一笔
//   ② 戴上   两只耳罩自下弹入落位 —— "戴上耳机"这个动作本身
//   ③ 出声   声波 + 图标轻顶一下 —— 戴上之后音乐开始
// 然后才交棒给首页。总长压在 1.7s 以内：开屏是首启流失点，超过两秒就会有人烦。
//
// ── 2026-11-22 二改（v2.4.82）：把"固定的一帧"填掉 ────────────────────────────────
// 老板连着两轮说"开屏卡在固定的一帧"。逐帧量下来真凶不是启动重活（那份在 v2.4.81 已经挪走了），
// 而是**时间轴自己留了 300ms 空档**：
//   · 声波透明度原来写的是 `0.55 × (1 − easeOut(local))`，easeOut 把 local 在 0.15s 内推到 0.9，
//     声波出场 0.1s 就淡到 10% 以下 —— 名义上 0.66–1.32，实际 0.98s 就看不见了；
//   · 轻顶 0.98s 结束；
//   · 退场要 1.30s 才开始。
// 于是 1.03–1.33 这 300ms 画面上一个像素都不动（录屏逐帧实测 diff = 0.00，连录 4 次冷启动都一样）。
// 改法：
//   ① 声波透明度改成跟整拍同步淡出，**两道波错开**（0.66–1.20 / 0.80–1.20），看得见一直撑到退场；
//   ② 轻顶拉满到 1.02s；
//   ③ 退场提前到 1.10s，总长 1.72 → 1.52s。
// 结果：最长静止窗 300ms → 92ms（= 落笔完成到出声之间的一拍，30fps 下 3 帧，肉眼看不出），
// 并由 `longestStillWindow()` 钉进 CI —— 以后谁再挪时间轴，CI 先拦。
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
    static let bandDraw = Beat(start: 0.00, duration: 0.58)
    /// 进场：整枚图标"从纸里浮出来"（透明度 0→1、放大 1.04→1、下移 4pt→0）。
    ///
    /// 2026-11-23（老板："开屏整个过程刚开始略显突兀，像是突然出现"）：
    /// 以前第一帧就是硬边墨迹 + 已经画了一截的弧，加上系统启动转场的推近，读起来就是"啪一下出现"。
    /// 现在整个图标先柔化登场，墨的落笔再从这一层里长出来。
    ///
    /// **2026-11-27（老板："刚开始耳机出现的太突兀了，不够丝滑"）**：
    /// 逐条曲线量下来，问题不在"落笔"（那条 0.10s 只画 5%，本来就慢），而在这层**开场淡入**：
    /// 旧曲线 `easeOut` 0.24s 前 64ms 就把不透明度推到 **61%**，而那时笔才画 2%——
    /// 观感是"一整枚耳机幽灵先糊上屏幕"，不是"一笔一笔长出来"。
    /// 现在换 `smootherstep` 0.34s：前 64ms 只到 5%，前 160ms 到 45%，起手有"起势"。
    static let entrance = Beat(start: 0.00, duration: 0.34)
    /// 左耳罩弹入（**2026-11-27 改软**：spring 0.40/0.72 → 0.52/0.86，去掉那下过冲）
    ///
    /// 旧参数弹簧一起手就是最大速度，耳罩是"啪一下贴上来"；新参数落位约 0.39s、几乎不过冲，
    /// 读起来是"长出来"。起手也跟着后挪 0.04s：先让整枚图标浮出来，再长耳罩。
    static let cupLeft = Beat(start: 0.34, duration: 0.62)
    /// 右耳罩比左边晚 0.06s：两只同时落会像"啪"一下，错开才像"戴"
    static let cupRight = Beat(start: 0.40, duration: 0.62)
    /// 出声：第一道朱砂弧（从头梁/耳罩外侧荡开），0.58 → 1.18
    ///
    /// **2026-11-27（老板："那 130ms 也一起修了"）**：这里原来是 0.60，而头梁 0.58 就画完了、
    /// 耳罩也刚好落位——两拍之间出现一段 58ms 完全不动（旧曲线量出来是 130ms）。
    /// 现在让声波**落笔一结束就起**（0.58），正好接掉那一段。
    static let sound = Beat(start: 0.58, duration: 0.60)
    /// 第二道（更外圈）晚 0.14s 起：两拍错开，画面一直动到退场（1.04）接上
    static let soundSecond = Beat(start: 0.80, duration: 0.38)
    /// 图标轻顶（scale 1 → 1.045 → 1），拉到 0.98s
    /// 2026-11-27：0.66 → **0.62**，与声波一起把"耳罩落位"之后的空档填满
    static let thump = Beat(start: 0.62, duration: 0.36)
    /// 退场：纸底淡出、首页从 0.985 涨到 1。
    /// 2026-11-22 三改：1.10 → **1.04**（声波还在 20% 透明度的时就起淡出，接掉"退场前那 2 帧"）
    static let exit = Beat(start: 1.04, duration: 0.42)
    /// 图标比纸底先走一步：不留一枚淡影压在新出现的封面上
    static let markFade = Beat(start: 1.04, duration: 0.28)
    /// 首页内容淡入（与退场交叉，不是等黑屏再出来）
    static let contentIn = Beat(start: 1.10, duration: 0.36)

    // MARK: 总长

    /// 全片时长（= 退场结束）。超过它就该把自己从层级里摘掉。
    static let total: Double = exit.end

    /// 减弱动效：不做落笔/弹入/声波，图标**直接就是完整的**，停一下再淡出。
    static let reduceMotionHold: Double = 0.35
    static let reduceMotionFade: Double = 0.30
    static var reduceMotionTotal: Double { reduceMotionHold + reduceMotionFade }

    // MARK: - 某一时刻画面上的全部活动量
    //
    // 视图只读这个（不再自己算曲线），CI 的量测也读这个 —— 两边读的是同一份数，
    // 断言才有意义。

    struct Snapshot: Equatable {
        /// 头梁画到哪（0…1）
        var band: Double
        /// 整枚图标的进场柔化（0…1）
        var entrance: Double
        /// 左/右耳罩弹入（0…1，弹簧会轻微过冲）
        var cupLeft: Double
        var cupRight: Double
        /// 两道声波各自的行进（0…1）
        var wave1: Double
        var wave2: Double
        /// 轻顶（0…1）
        var thump: Double
        /// 退场（0…1，纸底 = 1 − exit）
        var exit: Double
        /// 图标整体透明度
        var markOpacity: Double
    }

    static func snapshot(at time: Double, reduceMotion: Bool = false) -> Snapshot {
        if reduceMotion {
            return Snapshot(band: 1, entrance: 1, cupLeft: 1, cupRight: 1, wave1: 0, wave2: 0,
                            thump: 0, exit: 0,
                            markOpacity: markOpacity(at: time, reduceMotion: true))
        }
        return Snapshot(
            band: bandCurve(bandDraw.progress(at: time)),
            entrance: smootherstep(entrance.progress(at: time)),
            cupLeft: spring(elapsed: time - cupLeft.start,
                            response: cupSpringResponse, damping: cupSpringDamping),
            cupRight: spring(elapsed: time - cupRight.start,
                             response: cupSpringResponse, damping: cupSpringDamping),
            wave1: sound.progress(at: time),
            wave2: soundSecond.progress(at: time),
            thump: thumpCurve(at: time),
            exit: exit.progress(at: time),
            markOpacity: markOpacity(at: time, reduceMotion: false))
    }

    // MARK: - 曲线（纯函数，被断言覆盖）

    static func clamp01(_ v: Double) -> Double { v < 0 ? 0 : (v > 1 ? 1 : v) }

    static func easeOut(_ v: Double) -> Double {
        let m = 1 - clamp01(v)
        return 1 - m * m * m
    }

    /// 首尾都收住的三次平滑（0 → 1）：f'(0) = f'(1) = 0。
    ///
    /// 开场淡入专用（2026-11-27）：`easeOut` 的起点是**最大速度**，第一帧就把图糊上来；
    /// 这条两端速度都为 0，起点有"起势"、收尾也不再是硬停——这就是"丝滑"在数学上的样子。
    static func smootherstep(_ v: Double) -> Double {
        let t = clamp01(v)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// 耳罩弹簧参数（2026-11-27 从 0.40/0.72 改软）
    /// 0.40/0.72 的过冲约 4%，肉眼就是"弹一下"；0.52/0.86 的过冲 <0.5%，落位更沉。
    static let cupSpringResponse: Double = 0.52
    static let cupSpringDamping: Double = 0.86

    /// 耳罩在某一时刻的落位（供 CI 断言用同一份参数）
    static func cupProgress(at time: Double, left: Bool) -> Double {
        let start = left ? cupLeft.start : cupRight.start
        return spring(elapsed: time - start, response: cupSpringResponse, damping: cupSpringDamping)
    }

    /// 落笔的曲线：**起步慢、收尾快**（`1.9t² − 0.9t³`）。
    ///
    /// 2026-11-23（老板："刚开始略显突兀，像是突然出现"）：原来用 `easeOut`，前 100ms 就画出 43%，
    /// 读起来就是"弧一下跳出来"。这条曲线 f'(0)=0（起笔轻）、f'(1)=1.1（不拖尾巴，
    /// 所以不会又把"落笔完成→出声"那 2 帧变成停顿），前 100ms 只画 3%。
    static func bandCurve(_ v: Double) -> Double {
        let t = clamp01(v)
        return t * t * (1.9 - 0.9 * t)
    }

    /// 阻尼弹簧（spring response / dampingFraction 的解析解），落位约 1.0，允许轻微过冲
    static func spring(elapsed: Double, response: Double = 0.40, damping: Double = 0.72) -> Double {        guard elapsed > 0 else { return 0 }
        let w0 = 2 * Double.pi / response
        let wd = w0 * (1 - damping * damping).squareRoot()
        let decay = exp(-damping * w0 * elapsed)
        return 1 - decay * (cos(wd * elapsed) + (damping * w0 / wd) * sin(wd * elapsed))
    }

    /// 0 → 1 → 0 的一顶
    static func thumpCurve(at time: Double) -> Double {
        let s = sin(Double.pi * thump.progress(at: time))
        return s * s
    }

    /// 声波的透明度：**跟整拍同步**淡出（旧版把 easeOut 放进分母，0.1s 就淡没了）。
    static func waveOpacity(progress p: Double) -> Double {
        p <= 0 ? 0 : 0.62 * pow(1 - clamp01(p), 1.1)
    }

    /// 声波的扩散：从 0.86 倍荡到 1.16 倍
    static func waveScale(progress p: Double) -> Double {
        0.86 + 0.30 * easeOut(clamp01(p))
    }

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

    // MARK: - "画面上还有没有在动"（CI 用）

    /// 声波在屏幕上的实际存在感（透明度 × 尺寸）
    static func waveEnergy(progress p: Double) -> Double {
        waveOpacity(progress: p) * waveScale(progress: p)
    }

    /// 相邻两帧之间"看得出来的变化"。权重按每个量占多少屏幕面积估：
    /// 头梁/退场是整片、图标淡出是整枚、弹簧是局部位移、声波是两根细线。
    static func motionDelta(from a: Snapshot, to b: Snapshot) -> Double {
        abs(b.band - a.band) * 100
            + abs(b.entrance - a.entrance) * 80
            + abs(b.cupLeft - a.cupLeft) * 6
            + abs(b.cupRight - a.cupRight) * 6
            + abs(waveEnergy(progress: b.wave1) - waveEnergy(progress: a.wave1)) * 40
            + abs(waveEnergy(progress: b.wave2) - waveEnergy(progress: a.wave2)) * 40
            + abs(b.thump - a.thump) * 8
            + abs(b.exit - a.exit) * 100
            + abs(b.markOpacity - a.markOpacity) * 60
    }

    /// 全片里最长的一段"画面上什么都在不动"（秒）。
    ///
    /// 2026-11-22：旧时间轴在 1.04–1.30 有 **258ms** 完全静止（老板的"卡在固定的一帧"）；
    /// 现在最长只剩 92ms（落笔完成到出声之间的一拍）。CI 断言 < 150ms，
    /// 谁再把某一拍往后挪、留下空档，这里先红。
    static func longestStillWindow(dt: Double = 1.0 / 120, threshold: Double = 0.25) -> Double {
        var longest = 0.0
        var run = 0.0
        var t = dt
        while t <= total + 1e-9 {
            let d = motionDelta(from: snapshot(at: t - dt), to: snapshot(at: t))
            if d < threshold {
                run += dt
                longest = max(longest, run)
            } else {
                run = 0
            }
            t += dt
        }
        return longest
    }
}

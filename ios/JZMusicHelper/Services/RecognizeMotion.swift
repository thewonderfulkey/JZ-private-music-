import Foundation

// MARK: - 识曲舞台的动效口径（纯函数，CI 可断言）
//
// 第三十二轮（2026-11-18）：老板说"点击识曲是渐变，太丑且不符合功能"。
// 旧实现只有一颗 210pt 的圈在 `easeInOut(0.6)` 里整体淡入淡出——它既没有"在听"的信息，
// 也把图标、文字、结果卡一起拖着渐变，所以像一张 PPT 淡入。
//
// 新舞台按"听 → 认 → 出结果"三拍，每一拍都只动该动的东西：
//   · 听：三圈声波从麦克风往外扩（错峰 0.42s，1.5s 一圈），外圈透明度随距离衰减；
//          一圈 28 根径向电平条跟着 `AudioCapture` 的 level 起伏；外圈走 12 秒倒计时进度环。
//   · 认：声波收掉，换成一条 1.1s 转一圈的雷达弧（窄弧 + 渐隐），中心换 waveform 变量色。
//   · 结果：一次 0.55s 的成功脉冲（1 → 1.55，透明度 0.55 → 0），图标弹一下；
//          失败/没听出来：舞台横向抖 3 下（±6pt、0.36s），不是整页渐变。
//
// 这里的数字全部是"肉眼调过"的常量，同时供 HTML 预演（docs/ios/mockups/motion-rework.html）复用；
// 改任何一个都会同时改 Swift 与预演，避免两边对不上。
enum RecognizeMotion {

    // MARK: 尺寸（pt）

    /// 麦克风底盘直径
    static let coreDiameter: Double = 136
    /// 底盘外的一圈光晕（衬在电平条后面）
    static let haloDiameter: Double = 160
    /// 倒计时环直径（在电平条外侧，留 8pt 空）
    static let countdownDiameter: Double = 204
    /// 舞台总高（圈 + 上下呼吸）
    static let stageHeight: Double = 236

    // MARK: 声波（listening）

    static let rippleCount = 3
    /// 一圈声波从 1 扩到 1.55 的时长（秒）
    static let rippleCycle: Double = 1.5
    /// 相邻两圈的错峰（秒）
    static let rippleStagger: Double = 0.42
    static let rippleMaxScale: Double = 1.55
    static let rippleStroke: Double = 2
    /// 刚出生那一下的最高透明度（再高就糊成一片）
    static let ripplePeakOpacity: Double = 0.32

    // MARK: 电平频谱（listening）

    static let barCount = 24
    /// 安静时的最短长度：留一条"还活着"的短线，不要全部消失
    static let barBaseLength: Double = 3
    /// 满电平时最长长度
    static let barMaxLength: Double = 15
    /// 频谱环绕半径（频谱内端到圆心的距离，外端再 +barMaxLength）
    static let barRadius: Double = 80
    /// 条宽：2.5 在浅色纸底上太细，远看像一圈虚线
    static let barWidth: Double = 3.0
    static let barPeakOpacity: Double = 0.75

    // MARK: 雷达扫描（recognizing）

    /// 转一圈的时长（秒）
    static let scanCycle: Double = 1.1
    /// 扫描弧占整圈的比例（窄尾巴，像雷达）
    static let scanSpan: Double = 0.18

    // MARK: 结果（result / 失败）

    /// 成功脉冲时长
    static let burstCycle: Double = 0.55
    static let burstMaxScale: Double = 1.55
    /// 失败抖动：总时长与单边振幅
    static let shakeDuration: Double = 0.36
    static let shakeAmplitude: Double = 6

    // MARK: 减弱动效

    /// 减弱动效下所有"位移/扩散"都退化成 0.15s 的淡变
    static let reduceFade: Double = 0.15

    // MARK: - 纯函数

    /// 夹到 0…1；NaN 按 0 处理（动画中途拿到脏数据不许把画面画飞）
    static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// 第 index 圈声波在 elapsed 秒时的进度（0…1），错峰后循环
    static func rippleProgress(elapsed: Double, index: Int) -> Double {
        guard elapsed.isFinite, index >= 0 else { return 0 }
        let cycle = max(rippleCycle, 0.001)
        var t = elapsed - Double(index) * rippleStagger
        t = t.truncatingRemainder(dividingBy: cycle)
        if t < 0 { t += cycle }
        return clamp01(t / cycle)
    }

    /// 进度 → 缩放（1 → 1.62，线性外扩；声波不是弹簧，不要回弹）
    static func rippleScale(progress: Double) -> Double {
        let p = clamp01(progress)
        return 1 + (rippleMaxScale - 1) * p
    }

    /// 进度 → 透明度（峰值 → 0；外圈必须淡掉，否则像一堵墙）
    static func rippleOpacity(progress: Double) -> Double {
        ripplePeakOpacity * (1 - clamp01(progress))
    }

    /// 第 index 根电平条在 elapsed 秒时的长度（pt）
    ///
    /// 安静时也有 3pt 短线；有声音时按 level 放大，再叠一个与邻条错开的慢摆动，
    /// 让频谱"活着"而不是整排一起跳。
    static func barLength(index: Int, level: Double, elapsed: Double) -> Double {
        let l = clamp01(level)
        let phase = Double(index) * 0.73 + elapsed * 2.3
        let wobble = 0.55 + 0.45 * abs(sin(phase))
        let span = max(barMaxLength - barBaseLength, 0)
        return barBaseLength + span * l * wobble
    }

    /// 第 index 根电平条的透明度（安静时也更淡，但别淡到看不见）
    static func barOpacity(level: Double) -> Double {
        barPeakOpacity * (0.45 + 0.55 * clamp01(level))
    }

    /// 倒计时进度：0 = 刚开始听，1 = 听满
    static func countdownProgress(remaining: Double, total: Double) -> Double {
        guard total > 0, remaining.isFinite else { return 0 }
        return clamp01(1 - remaining / total)
    }

    /// 雷达弧旋转进度（0…1，一秒多一点一圈）
    static func scanRotation(elapsed: Double) -> Double {
        guard elapsed.isFinite else { return 0 }
        let cycle = max(scanCycle, 0.001)
        var t = elapsed.truncatingRemainder(dividingBy: cycle)
        if t < 0 { t += cycle }
        return clamp01(t / cycle)
    }

    /// 成功脉冲：先快后慢地扩到 1.55，透明度同步归零
    static func burstScale(elapsed: Double) -> Double {
        let p = clamp01(elapsed / max(burstCycle, 0.001))
        let eased = 1 - pow(1 - p, 3)
        return 1 + (burstMaxScale - 1) * eased
    }

    static func burstOpacity(elapsed: Double) -> Double {
        let p = clamp01(elapsed / max(burstCycle, 0.001))
        return 0.55 * (1 - p)
    }

    /// 失败抖动位移：3 个来回，两端收敛到 0
    static func shakeOffset(elapsed: Double) -> Double {
        let p = clamp01(elapsed / max(shakeDuration, 0.001))
        guard p < 1 else { return 0 }
        let envelope = 1 - p
        return shakeAmplitude * envelope * sin(p * .pi * 3)
    }
}

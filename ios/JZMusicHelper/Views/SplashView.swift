import SwiftUI

// MARK: - 开屏动画（耳机标）
//
// 图标本身就是"一副耳机"，所以开屏不另造图形，让它自己把三个动作做完：
//   ① 落笔：头梁沿着自己的弧度长出来
//   ② 戴上：两只耳罩自下弹入、微微外倾 6° 再收正（右耳罩晚 0.06s，一起落会像"啪"一下）
//   ③ 出声：两道朱砂声波从耳罩外侧荡开，图标轻顶一下
// 然后纸底淡出、首页从 0.985 涨到 1 —— 不是"黑屏一下再出来"。
//
// 为什么不做成 LaunchScreen 图：iOS 的 LaunchScreen 只能是静态的（系统截图，不能播动画），
// 所以这一屏必须"从一张空白纸开始"才接得上——第一个动作就是落笔，正好由空白纸起笔。
// 时间轴全部在 `Services/SplashTimeline.swift`（纯数据，CI 有断言）；这里只管画。
//
// 三条硬约束：
//   · 只在**冷启动**出现一次（由 `JZMusicHelperApp` 的 @State 控制，回前台不再播）
//   · 点任意处立刻退场；`减弱动效` 下不做落笔/弹入/声波，图标直接是完整的，停 0.35s 再淡出
//   · 整层是 Touch 拦截层：开屏期间首页点不到，VoiceOver 也读不到（见 App 里的 accessibilityHidden）
struct SplashView: View {

    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var start = Date()
    @State private var reducedOpacity: Double = 1
    @State private var finished = false

    /// 图标设计坐标系的边长（与 `SplashMarkPath` 一致）
    private let unit: CGFloat = 240
    /// 图标在屏幕上的边长
    private let markSize: CGFloat = 150

    /// 显式写 init：结构体里有 `private` 的 @State，合成的逐成员 init 会被降成 private，
    /// 别的文件就 `SplashView { … }` 不进来（编译期直接报 inaccessible）。
    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    var body: some View {
        Group {
            if reduceMotion {
                // 减弱动效：图标就是完整的，不做任何位移/缩放。
                // 外面必须包一层 ZStack：`Group` 上的修饰符是**逐子视图**生效的，
                // 直接并列两个 view 会让 VoiceOver 把「JZ 音乐」念两遍。
                ZStack {
                    paper(opacity: 1)
                    markShape(band: 1, cupLeft: 1, cupRight: 1, sound: 0, thump: 0, exit: 0)
                        .opacity(reducedOpacity)
                }
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSince(start)
                    ZStack {
                        paper(opacity: 1 - SplashTimeline.exitProgress(at: t))
                        markShape(
                            band: easeOut(SplashTimeline.bandDraw.progress(at: t)),
                            cupLeft: springValue(elapsed: t - SplashTimeline.cupLeft.start),
                            cupRight: springValue(elapsed: t - SplashTimeline.cupRight.start),
                            sound: SplashTimeline.sound.progress(at: t),
                            thump: thumpCurve(at: t),
                            exit: SplashTimeline.exitProgress(at: t)
                        )
                        .opacity(SplashTimeline.markOpacity(at: t, reduceMotion: false))
                    }
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        // 装饰图形对 VoiceOver 没有信息量，但"能跳过"这件事要有：当成一个按钮读出来
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("JZ 音乐")
        .accessibilityHint("轻点跳过开屏动画")
        .accessibilityAddTraits(.isButton)
        .task { await runTimeline() }
    }

    // MARK: - 定时

    private func runTimeline() async {
        if reduceMotion {
            try? await Task.sleep(nanoseconds: UInt64(SplashTimeline.reduceMotionHold * 1_000_000_000))
            withAnimation(.easeOut(duration: SplashTimeline.reduceMotionFade)) { reducedOpacity = 0 }
            try? await Task.sleep(nanoseconds: UInt64(SplashTimeline.reduceMotionFade * 1_000_000_000))
            finish()
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(SplashTimeline.total * 1_000_000_000))
        finish()
    }

    /// 只交棒一次（自然结束与点击跳过可能几乎同时到）
    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished()
    }

    // MARK: - 画面

    private func paper(opacity: Double) -> some View {
        Tokens.Palette.paper.opacity(opacity).ignoresSafeArea()
    }

    private func markShape(band: Double, cupLeft: Double, cupRight: Double,
                           sound: Double, thump: Double, exit: Double) -> some View {
        ZStack {
            soundWaves(progress: sound)
                .frame(width: unit, height: unit)
            // 头梁：一块从弧心扫过去的扇形遮罩，让墨沿着弧的方向长出来（不是整块淡入）
            MarkShape(points: SplashMarkPath.band, mirror: false)
                .fill(ink)
                .mask(
                    BandWedge(endDegrees: 152 + (385 - 152) * band)
                        .fill(Color.black)
                        .blur(radius: 0.6)
                )
            cupGroup(points: SplashMarkPath.cup, mirrored: false, progress: cupLeft, exit: exit)
            cupGroup(points: SplashMarkPath.flank, mirrored: false, progress: cupLeft, exit: exit)
            cupGroup(points: SplashMarkPath.cup, mirrored: true, progress: cupRight, exit: exit)
            cupGroup(points: SplashMarkPath.flank, mirrored: true, progress: cupRight, exit: exit)
        }
        .frame(width: unit, height: unit)
        .scaleEffect(markSize / unit)
        .frame(width: markSize, height: markSize)
        // 收尾：整枚图标上浮 7pt、缩回 1.5%
        .offset(y: -7 * exit)
        .scaleEffect(1 + 0.04 * thump - 0.015 * exit)
    }

    private func cupGroup(points: [CGFloat], mirrored: Bool,
                          progress: Double, exit: Double) -> some View {
        let dir: CGFloat = mirrored ? 1 : -1
        let p = CGFloat(progress)
        let anchor = UnitPoint(x: 120 / unit, y: 176 / unit)
        return MarkShape(points: points, mirror: mirrored)
            .fill(ink)
            .scaleEffect(0.86 + 0.14 * p, anchor: anchor)
            .rotationEffect(.degrees(Double(dir) * 6 * (1 - Double(p))), anchor: anchor)
            // 退场时两只耳罩各自向外让开 6 单位（像"张开"）
            .offset(x: dir * 6 * CGFloat(exit), y: 26 * (1 - p))
            .opacity(Double(min(1, p / 0.14)))
    }

    /// 两道朱砂声波：左 140°→220°，右镜像 -40°→40°，荡开的同时淡出
    private func soundWaves(progress: Double) -> some View {
        let leftLocal = easeOut(clamp01((progress - 0.05) / 0.78))
        let rightLocal = easeOut(clamp01((progress - 0.11) / 0.78))
        return ZStack {
            ForEach(0..<2, id: \.self) { i in
                arcPath(center: CGPoint(x: 12, y: 176),
                        radius: 26 + CGFloat(i) * 15, from: 140, to: 220)
                    .stroke(Tokens.Palette.vermilion,
                            style: StrokeStyle(lineWidth: i == 0 ? 2.2 : 1.8, lineCap: .round))
                    .opacity(progress > 0 ? 0.55 * (1 - leftLocal) : 0)
                    .scaleEffect(0.86 + 0.30 * CGFloat(leftLocal),
                                 anchor: UnitPoint(x: 12 / unit, y: 176 / unit))
                arcPath(center: CGPoint(x: 228, y: 176),
                        radius: 26 + CGFloat(i) * 15, from: -40, to: 40)
                    .stroke(Tokens.Palette.vermilion,
                            style: StrokeStyle(lineWidth: i == 0 ? 2.2 : 1.8, lineCap: .round))
                    .opacity(progress > 0 ? 0.55 * (1 - rightLocal) : 0)
                    .scaleEffect(0.86 + 0.30 * CGFloat(rightLocal),
                                 anchor: UnitPoint(x: 228 / unit, y: 176 / unit))
            }
        }
    }

    // MARK: - 曲线

    private var ink: Color { Color(uiColor: .label) }

    private func clamp01(_ v: Double) -> Double { v < 0 ? 0 : (v > 1 ? 1 : v) }

    private func easeOut(_ v: Double) -> Double {
        let c = clamp01(v)
        let m = 1 - c
        return 1 - m * m * m
    }

    /// 阻尼弹簧（spring response / dampingFraction 的解析解），落位约 1.0，允许轻微过冲
    private func springValue(elapsed: Double, response: Double = 0.40, damping: Double = 0.72) -> Double {
        guard elapsed > 0 else { return 0 }
        let w0 = 2 * Double.pi / response
        let wd = w0 * (1 - damping * damping).squareRoot()
        let decay = exp(-damping * w0 * elapsed)
        return 1 - decay * (cos(wd * elapsed) + (damping * w0 / wd) * sin(wd * elapsed))
    }

    /// 0 → 1 → 0 的一顶
    private func thumpCurve(at t: Double) -> Double {
        let s = sin(Double.pi * SplashTimeline.thump.progress(at: t))
        return s * s
    }

    private func arcPath(center: CGPoint, radius: CGFloat, from: Double, to: Double) -> Path {
        var path = Path()
        let steps = 24
        for i in 0...steps {
            let deg = from + (to - from) * Double(i) / Double(steps)
            let a = deg * Double.pi / 180
            let pt = CGPoint(x: center.x + radius * CGFloat(cos(a)),
                             y: center.y + radius * CGFloat(sin(a)))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }
}

// MARK: - 形状

/// 从 `SplashMarkPath` 的点阵描出来的形状（坐标就在 240×240 设计单位里，不吃 frame）
private struct MarkShape: Shape {
    let points: [CGFloat]
    let mirror: Bool

    func path(in rect: CGRect) -> Path {
        SplashMarkPath.path(points, mirror: mirror)
    }
}

/// 头梁的扇形遮罩：弧心 (120, 98)、半径 330，从 152° 扫到 `endDegrees`。
/// 前端是"垂直于头梁走向的一刀"，所以墨看起来是沿着弧长出来的。
private struct BandWedge: Shape {
    var endDegrees: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: 120, y: 98)
        let radius: CGFloat = 330
        let steps = 48
        var path = Path()
        path.move(to: center)
        for i in 0...steps {
            let deg = 152 + (endDegrees - 152) * Double(i) / Double(steps)
            let a = deg * Double.pi / 180
            let pt = CGPoint(x: center.x + radius * CGFloat(cos(a)),
                             y: center.y + radius * CGFloat(sin(a)))
            path.addLine(to: pt)
        }
        path.closeSubpath()
        return path
    }
}

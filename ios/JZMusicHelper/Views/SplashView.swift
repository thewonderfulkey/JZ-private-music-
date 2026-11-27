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
// 时间轴与所有曲线都在 `Services/SplashTimeline.swift`（纯函数，CI 有断言）；这里只管画。
//
// 三条硬约束：
//   · 只在**冷启动**出现一次（由 `JZMusicHelperApp` 的 @State 控制，回前台不再播）
//   · 点任意处立刻退场；`减弱动效` 下不做落笔/弹入/声波，图标直接是完整的，停 0.35s 再淡出
//   · 整层是 Touch 拦截层：开屏期间首页点不到，VoiceOver 也读不到（见 App 里的 accessibilityHidden）
struct SplashView: View {

    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 起拍时刻：**第一帧真的被画出来之后**才置上。
    /// 2026-11-22：以前是 `@State private var start = Date()`，也就是 View 一构造就开始计时 ——
    /// 而构造发生在首帧之前（系统启动转场约 0.16s），于是第一帧画面上头梁已经画了 26%，
    /// 观感是"一出来就跳了一下"。现在 onAppear 之前一律按 t=0 画，正好等于 LaunchScreen 的空白纸。
    @State private var start: Date?
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
                    markShape(SplashTimeline.snapshot(at: 0, reduceMotion: true))
                        .opacity(reducedOpacity)
                }
            } else {
                TimelineView(.animation) { context in
                    // start 还没置上（首帧）就按 t=0 画：空白纸 + 一个点都还没落笔
                    let t = start.map { context.date.timeIntervalSince($0) } ?? 0
                    let s = SplashTimeline.snapshot(at: t)
                    ZStack {
                        paper(opacity: 1 - s.exit)
                        markShape(s)
                            // 进场柔化：整枚图标从 0 浮起来（0.24s），不是第一帧就硬着出现
                            .opacity(s.markOpacity * s.entrance)
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
        .task {
            LaunchBreadcrumbs.mark("splash-start")
            LaunchBreadcrumbs.reportLastRun()
            // 2026-11-27：先空一拍再起笔。启动那一下的第一帧常常要 100~200ms 才真正呈现，
            // 若这时计时已经开始，用户看到的第一帧就是"半成品"→ 观感"一下全量"。
            // 这段空拍画面是干净的白纸，等于把启动抖动藏进"还没起笔"里。
            if start == nil { try? await Task.sleep(nanoseconds: UInt64(SplashTimeline.startDelay * 1_000_000_000)) }
            // 首帧已经画出来了，从这一帧起拍
            if start == nil { start = Date() }
            await runTimeline()
        }
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

    private func markShape(_ s: SplashTimeline.Snapshot) -> some View {
        ZStack {
            soundWaves(s)
                .frame(width: unit, height: unit)
            // 头梁：一块从弧心扫过去的扇形遮罩，让墨沿着弧的方向长出来（不是整块淡入）
            MarkShape(points: SplashMarkPath.band, mirror: false)
                .fill(ink)
                .mask(
                    BandWedge(endDegrees: 152 + (385 - 152) * s.band)
                        .fill(Color.black)
                        .blur(radius: 0.6)
                )
            cupGroup(points: SplashMarkPath.cup, mirrored: false, progress: s.cupLeft, exit: s.exit)
            cupGroup(points: SplashMarkPath.flank, mirrored: false, progress: s.cupLeft, exit: s.exit)
            cupGroup(points: SplashMarkPath.cup, mirrored: true, progress: s.cupRight, exit: s.exit)
            cupGroup(points: SplashMarkPath.flank, mirrored: true, progress: s.cupRight, exit: s.exit)
        }
        .frame(width: unit, height: unit)
        .scaleEffect(markSize / unit)
        .frame(width: markSize, height: markSize)
        // 收尾：整枚图标上浮 7pt、缩回 1.5%；
        // 进场：从 1.04 缩到 1、下移 4pt 浮上来（与透明度一起，解决"突然出现"）
        .offset(y: -7 * s.exit + 4 * (1 - s.entrance))
        .scaleEffect(1 + 0.04 * s.thump + 0.04 * (1 - s.entrance) - 0.015 * s.exit)
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
            // 2026-11-23：耳罩原来 0.087s（3 帧）就满不透明，一起落像"啪"一下；
            // 拉长到 0.19s，让两只耳罩是"浮"上来而不是"弹"出来。
            .opacity(Double(min(1, p / 0.30)))
    }

    /// 两道朱砂声波：**错开两拍**（0.66 起、0.80 起），一内一外，
    /// 荡开的同时按整拍匀速淡出 —— 2026-11-22 之前两道是同时的、且 0.1s 就淡没了，
    /// 于是"出声"这一拍等于没做，1.03–1.33 那 300ms 画面上什么都不动。
    private func soundWaves(_ s: SplashTimeline.Snapshot) -> some View {
        ZStack {
            waveArc(side: .left, radius: 26, progress: s.wave1)
            waveArc(side: .right, radius: 26, progress: s.wave1)
            waveArc(side: .left, radius: 41, progress: s.wave2)
            waveArc(side: .right, radius: 41, progress: s.wave2)
        }
    }

    private enum Side { case left, right }

    private func waveArc(side: Side, radius: CGFloat, progress: Double) -> some View {
        let center = CGPoint(x: side == .left ? 12 : 228, y: 176)
        let from: Double = side == .left ? 140 : -40
        let to: Double = side == .left ? 220 : 40
        return arcPath(center: center, radius: radius, from: from, to: to)
            .stroke(Tokens.Palette.vermilion,
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
            .opacity(SplashTimeline.waveOpacity(progress: progress))
            .scaleEffect(SplashTimeline.waveScale(progress: progress),
                         anchor: UnitPoint(x: center.x / unit, y: center.y / unit))
    }

    // MARK: - 曲线

    private var ink: Color { Color(uiColor: .label) }

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

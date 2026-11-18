import SwiftUI

// MARK: - 识曲舞台（第三十二轮重做）
//
// 旧版：一颗 210pt 的圈 + 整页 `.easeInOut(0.6)` 渐变。老板原话："点击识曲是渐变，太丑且不符合功能"。
// 新版把一个"听音"过程画成三拍（数值口径见 Services/RecognizeMotion.swift，CI 有断言）：
//
//   听：三圈声波从麦克风往外扩（错峰 0.42s / 1.5s 一圈），
//       24 根径向电平条跟着麦克风 level 起伏，
//       外圈一条 12 秒倒计时进度环（唯一"功能性"装饰——它真的在走）。
//   认：声波收掉，换雷达弧（1.1s 一圈）+ waveform 变量色图标。
//   果：一次成功脉冲 + 图标弹一下；没听出来/失败则舞台横向抖 3 下。
//
// 所有位移、扩散、抖动在 Reduce Motion 下全部取消，只留 0.15s 淡变与倒计时环。
struct RecognizeStage: View {

    let phase: RecognizeView.Phase
    let level: Float
    let remaining: Int
    let totalSeconds: Int
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var listeningStart = Date()
    @State private var analyzingStart = Date()
    @State private var shakeTrigger = 0

    private var isListening: Bool { phase == .listening }
    private var isRecognizing: Bool { phase == .recognizing }
    private var isResult: Bool { phase == .result }

    var body: some View {
        Button(action: onTap) {
            stage
                .frame(height: CGFloat(RecognizeMotion.stageHeight))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(StagePressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .onChange(of: phase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
    }

    // MARK: 舞台

    private var stage: some View {
        ZStack {
            halo
            if isListening, !reduceMotion {
                listeningLayer
                    .transition(.opacity)
            }
            if isListening {
                countdownRing
                    .transition(.opacity)
            }
            if isRecognizing {
                scanRing
                    .transition(.opacity)
            }
            if isResult, !reduceMotion {
                SuccessBurst(diameter: CGFloat(RecognizeMotion.coreDiameter))
                    .transition(.opacity)
            }
            core
        }
        .animation(reduceMotion ? .easeOut(duration: RecognizeMotion.reduceFade)
                                : .easeInOut(duration: 0.22),
                   value: phase)
        .keyframeAnimator(initialValue: ShakeValues(), trigger: shakeTrigger) { content, value in
            content.offset(x: CGFloat(value.x))
        } keyframes: { _ in
            KeyframeTrack(\.x) {
                CubicKeyframe(RecognizeMotion.shakeAmplitude, duration: 0.06)
                CubicKeyframe(-RecognizeMotion.shakeAmplitude, duration: 0.09)
                CubicKeyframe(RecognizeMotion.shakeAmplitude * 0.60, duration: 0.08)
                CubicKeyframe(-RecognizeMotion.shakeAmplitude * 0.35, duration: 0.07)
                CubicKeyframe(0, duration: 0.06)
            }
        }
    }

    // MARK: 光晕

    private var halo: some View {
        Circle()
            .fill(Tokens.Palette.vermilion.opacity(haloOpacity))
            .frame(width: CGFloat(RecognizeMotion.haloDiameter),
                   height: CGFloat(RecognizeMotion.haloDiameter))
            .scaleEffect(haloScale)
            .animation(.easeOut(duration: 0.12), value: level)
            .animation(.easeOut(duration: 0.30), value: phase)
    }

    private var haloOpacity: Double {
        switch phase {
        case .listening: return 0.05
        case .recognizing: return 0.08
        case .result: return 0.10
        case .noMatch, .failed: return 0.05
        case .idle: return 0.05
        }
    }

    private var haloScale: CGFloat {
        guard !reduceMotion else { return 1 }
        let loud = CGFloat(RecognizeMotion.clamp01(Double(level)))
        switch phase {
        case .listening: return 1 + loud * 0.06
        case .recognizing: return 1.02
        case .result: return 1.10
        default: return 1
        }
    }

    // MARK: 听：声波 + 电平频谱

    private var listeningLayer: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let elapsed = context.date.timeIntervalSince(listeningStart)
            ZStack {
                // 先画电平条，再让声波从上面掠过去——反过来的话三圈波会被条子挡掉一半
                spectrum(elapsed: elapsed)
                ripples(elapsed: elapsed)
            }
        }
    }

    private func ripples(elapsed: Double) -> some View {
        ForEach(0..<RecognizeMotion.rippleCount, id: \.self) { index in
            let progress = RecognizeMotion.rippleProgress(elapsed: elapsed, index: index)
            Circle()
                .stroke(Tokens.Palette.vermilion.opacity(RecognizeMotion.rippleOpacity(progress: progress)),
                        lineWidth: CGFloat(RecognizeMotion.rippleStroke))
                .frame(width: CGFloat(RecognizeMotion.coreDiameter),
                       height: CGFloat(RecognizeMotion.coreDiameter))
                .scaleEffect(CGFloat(RecognizeMotion.rippleScale(progress: progress)))
        }
    }

    private func spectrum(elapsed: Double) -> some View {
        let loud = Double(RecognizeMotion.clamp01(Double(level)))
        return ZStack {
            ForEach(0..<RecognizeMotion.barCount, id: \.self) { index in
                let length = RecognizeMotion.barLength(index: index, level: loud, elapsed: elapsed)
                Capsule(style: .continuous)
                    .fill(Tokens.Palette.vermilion.opacity(RecognizeMotion.barOpacity(level: loud)))
                    .frame(width: CGFloat(RecognizeMotion.barWidth), height: CGFloat(length))
                    // 先沿半径外推，再绕圆心转——每根条子指向圆心外侧
                    .offset(y: -CGFloat(RecognizeMotion.barRadius + length / 2))
                    .rotationEffect(.degrees(Double(index) * 360 / Double(RecognizeMotion.barCount)))
            }
        }
    }

    // MARK: 倒计时环（功能反馈）

    private var countdownRing: some View {
        ZStack {
            // 底轨：让人知道"一共 12 秒"，不是只有一条越走越长的红弧
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 2)
                .frame(width: CGFloat(RecognizeMotion.countdownDiameter),
                       height: CGFloat(RecognizeMotion.countdownDiameter))
            Circle()
                .trim(from: 0,
                      to: CGFloat(RecognizeMotion.countdownProgress(remaining: Double(remaining),
                                                                     total: Double(totalSeconds))))
                .stroke(Tokens.Palette.vermilion.opacity(0.90),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: CGFloat(RecognizeMotion.countdownDiameter),
                       height: CGFloat(RecognizeMotion.countdownDiameter))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: remaining)
        }
        .accessibilityHidden(true)
    }

    // MARK: 认：雷达扫描

    private var scanRing: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let progress = reduceMotion
                ? 0.25
                : RecognizeMotion.scanRotation(elapsed: context.date.timeIntervalSince(analyzingStart))
            ZStack {
                Circle()
                    .stroke(Tokens.Palette.vermilion.opacity(0.10), lineWidth: 2)
                    .frame(width: CGFloat(RecognizeMotion.countdownDiameter),
                           height: CGFloat(RecognizeMotion.countdownDiameter))
                Circle()
                    .trim(from: 0, to: CGFloat(RecognizeMotion.scanSpan))
                    .stroke(AngularGradient(
                        gradient: Gradient(colors: [Tokens.Palette.vermilion.opacity(0),
                                                     Tokens.Palette.vermilion]),
                        center: .center),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: CGFloat(RecognizeMotion.countdownDiameter),
                           height: CGFloat(RecognizeMotion.countdownDiameter))
                    .rotationEffect(.degrees(progress * 360 - 90))
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: 中心

    private var core: some View {
        ZStack {
            Circle()
                .fill(Tokens.Palette.paperElevated)
                .frame(width: CGFloat(RecognizeMotion.coreDiameter),
                       height: CGFloat(RecognizeMotion.coreDiameter))
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            icon
        }
        .scaleEffect(coreScale)
        .animation(.easeOut(duration: 0.12), value: level)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Tokens.Motion.stagePop, value: phase)
    }

    private var coreScale: CGFloat {
        guard !reduceMotion else { return 1 }
        switch phase {
        case .listening: return 1 + CGFloat(RecognizeMotion.clamp01(Double(level))) * 0.03
        case .recognizing: return 0.97
        case .result: return 1.05
        default: return 1
        }
    }

    private var icon: some View {
        Image(systemName: iconName)
            .font(.system(size: 36, weight: .regular))
            .foregroundStyle(iconColor)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.variableColor.iterative.reversing,
                          options: .repeating,
                          isActive: isRecognizing && !reduceMotion)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : Tokens.Motion.stagePop, value: phase)
    }

    private var iconName: String {
        switch phase {
        case .idle: return "mic.fill"
        case .listening: return "stop.fill"
        case .recognizing: return "waveform"
        case .result: return "checkmark"
        case .noMatch: return "waveform.slash"
        case .failed: return "mic.slash.fill"
        }
    }

    private var iconColor: Color {
        switch phase {
        case .listening, .result: return Tokens.Palette.vermilion
        case .noMatch, .failed: return Color.secondary
        default: return Color.primary
        }
    }

    // MARK: 阶段切换的触觉

    private func handlePhaseChange(_ newPhase: RecognizeView.Phase) {
        switch newPhase {
        case .listening:
            listeningStart = Date()
            Haptics.listeningStart()
        case .recognizing:
            analyzingStart = Date()
        case .result:
            Haptics.success()
        case .noMatch:
            shakeTrigger += 1
            Haptics.warning()
        case .failed:
            shakeTrigger += 1
            Haptics.error()
        case .idle:
            // 取消由 RecognizeView.handleMicTap 补一下 tap，这里不再给——
            // 切走 Tab 自动取消时不该再响一声。
            break
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .listening: return "正在聆听，轻点停止"
        case .recognizing: return "正在辨认"
        case .result: return "已识别出歌曲，轻点再听一次"
        case .noMatch: return "这次没听出来，轻点再试一次"
        case .failed: return "识别没成功，轻点再试一次"
        case .idle: return "开始识曲"
        }
    }

    // MARK: 失败抖动轨道

    private struct ShakeValues {
        var x: Double = 0
    }
}

// MARK: - 成功脉冲

private struct SuccessBurst: View {

    let diameter: CGFloat
    @State private var expand = false

    var body: some View {
        Circle()
            .stroke(Tokens.Palette.vermilion.opacity(expand ? 0 : 0.55), lineWidth: 2)
            .frame(width: diameter, height: diameter)
            .scaleEffect(expand ? CGFloat(RecognizeMotion.burstMaxScale) : 1)
            .onAppear {
                withAnimation(.easeOut(duration: RecognizeMotion.burstCycle)) { expand = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - 按压

private struct StagePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(configuration.isPressed ? Tokens.Motion.pressDown : Tokens.Motion.micPress,
                       value: configuration.isPressed)
    }
}

import Combine
import SwiftUI

// MARK: - 助眠模式
//
// 版式来自老板给的那条参考录屏（纯黑底 + 圆形声音按钮网格 + 底部"正在播放"条），
// 但配色换成我们自己的水墨口径：纸底、墨色圆钮、**朱砂只用在"这一层开着"**。
//
// 交互：
//   · 点圆钮 = 开 / 关这一层（0.5 秒淡入淡出，不炸耳朵）
//   · 长按 = 单独调这一层的音量
//   · 底部条 = 当前叠了哪几层 + 总暂停
//   · 右上"定时" = 15/30/60/90 分钟，到点 30 秒淡出
struct SleepView: View {

    @Environment(\.dismiss) private var dismiss
    private var engine: SleepAudioEngine { .shared }

    /// 长按 / 点底部标签要调音量的那一层
    @State private var volumeTarget: SleepSound?
    @State private var showTimerMenu = false
    /// 每秒走一格，给"还剩几分几秒"用
    @State private var now = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// 定时剩余（秒），没开就是 nil
    private var remaining: TimeInterval? {
        guard let ends = engine.timerEndsAt else { return nil }
        return max(0, ends.timeIntervalSince(now))
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Tokens.Spacing.m),
                                count: 3)

    var body: some View {
        ZStack {
            Tokens.Palette.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    grid
                    hint
                }
                .scrollIndicators(.hidden)

                if !engine.activeIDs.isEmpty {
                    bottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(Tokens.Motion.stateChange, value: engine.activeIDs)
        .onReceive(clock) { now = $0 }
        .sheet(item: $volumeTarget) { sound in
            SleepVolumeSheet(sound: sound)
                .presentationDetents([.height(210)])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.s) {
            Button {
                Haptics.tabChanged()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .minimumTapTarget()
            }
            .accessibilityLabel("返回")

            VStack(alignment: .leading, spacing: 2) {
                Text("助眠")
                    .font(FontRole.navInline)
                if let left = remaining {
                    Text("\(Int(left) / 60) 分 \(Int(left) % 60) 秒后关闭")
                        .font(FontRole.metadata)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if engine.stoppedByTimer && !engine.isPlaying {
                    Text("已按定时停止 · 点播放原样回来")
                        .font(FontRole.metadata)
                        .foregroundStyle(Tokens.Palette.vermilion)
                } else if !engine.activeIDs.isEmpty {
                    Text("\(engine.activeIDs.count) 层叠加中")
                        .font(FontRole.metadata)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Haptics.tabChanged()
                showTimerMenu = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "moon.zzz")
                    Text(engine.timerSelection == nil ? "定时" : "定时中")
                }
                .font(FontRole.metadata.weight(.medium))
                .padding(.horizontal, Tokens.Spacing.s)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(Tokens.Palette.paperElevated)
                )
                .foregroundStyle(engine.timerSelection == nil ? Color.secondary : Tokens.Palette.vermilion)
            }
            .confirmationDialog("定时关闭", isPresented: $showTimerMenu, titleVisibility: .visible) {
                ForEach(SleepTimerMinutes.allCases) { m in
                    Button(m.title) {
                        Haptics.success()
                        engine.startTimer(m)
                    }
                }
                if engine.timerSelection != nil {
                    Button("关闭定时", role: .destructive) {
                        Haptics.tabChanged()
                        engine.cancelTimer()
                    }
                }
            } message: {
                Text("到点后会先淡出 30 秒再停，不会突然安静。")
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.top, Tokens.Spacing.s)
        .padding(.bottom, Tokens.Spacing.m)
    }

    // MARK: 声音网格

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: Tokens.Spacing.l) {
            ForEach(SleepSound.all) { sound in
                SleepTile(sound: sound,
                          isOn: engine.activeIDs.contains(sound.id),
                          onTap: {
                              if engine.activeIDs.contains(sound.id) { Haptics.tabChanged() }
                              else { Haptics.success() }
                              engine.toggle(sound.id)
                          },
                          onLongPress: {
                              Haptics.tabChanged()
                              volumeTarget = sound
                          })
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.top, Tokens.Spacing.xs)
    }

    private var hint: some View {
        Text("点一下开一层，可以叠着听；长按可单独调音量")
            .font(FontRole.metadata)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Tokens.Spacing.l)
            .padding(.top, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.l)
    }

    /// 底部条标题：区分"正在响 / 手动暂停 / 定时到点停"
    private var barTitle: String {
        let n = engine.activeIDs.count
        if engine.isPlaying { return "正在播放（\(n)）" }
        if engine.stoppedByTimer { return "已停止 · \(n) 层保留" }
        return "已暂停（\(n)）"
    }

    // MARK: 底部"正在播放"

    private var bottomBar: some View {
        HStack(spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(barTitle)
                    .font(FontRole.metadata)
                    .foregroundStyle(.secondary)
                Text(engine.summary)
                    .font(FontRole.songSubtitle.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let first = engine.activeIDs.first, let s = SleepSound.find(first) {
                    volumeTarget = s
                }
            }

            Spacer()

            Button {
                Haptics.tabChanged()
                engine.togglePlayPause()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Tokens.Palette.paper)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Tokens.Palette.vermilion))
            }
            .accessibilityLabel(engine.isPlaying ? "暂停助眠音" : "继续助眠音")
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                .fill(Tokens.Palette.paperElevated)
        )
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.bottom, Tokens.Spacing.s)
    }
}

// MARK: - 单个圆形声音钮

private struct SleepTile: View {

    let sound: SleepSound
    let isOn: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    /// 按下就缩一点（老板一直嫌"点击反馈不明显"，这里给实时的）
    @State private var pressed = false
    /// 长按之后手指抬起时系统还会补一次 tap，用它吃掉
    @State private var didLongPress = false

    var body: some View {
        VStack(spacing: Tokens.Spacing.xs) {
            ZStack {
                Circle()
                    .fill(isOn ? Tokens.Palette.vermilion : Tokens.Palette.paperElevated)
                    .frame(width: 84, height: 84)
                    .overlay(
                        Circle().strokeBorder(Color.primary.opacity(isOn ? 0 : 0.10), lineWidth: 0.5)
                    )
                Image(systemName: sound.symbol)
                    .font(.system(size: 29, weight: .regular))
                    .foregroundStyle(isOn ? Tokens.Palette.paper : Color.secondary)
            }
            .scaleEffect(isOn ? 1.0 : 0.97)
            .animation(Tokens.Motion.stateChange, value: isOn)

            Text(sound.name)
                .font(FontRole.metadata)
                .foregroundStyle(isOn ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .scaleEffect(pressed ? 0.93 : 1)
        .animation(Tokens.Motion.pressDown, value: pressed)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.35, pressing: { pressing in
            pressed = pressing
        }, perform: {
            didLongPress = true
            onLongPress()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { didLongPress = false }
        })
        .onTapGesture {
            if didLongPress { didLongPress = false; return }
            onTap()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sound.name)，\(sound.caption)")
        .accessibilityValue(isOn ? "开" : "关")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onTap() }
    }
}

// MARK: - 单层音量

private struct SleepVolumeSheet: View {

    let sound: SleepSound
    @Environment(\.dismiss) private var dismiss
    private var engine: SleepAudioEngine { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack {
                Image(systemName: sound.symbol)
                    .foregroundStyle(Tokens.Palette.vermilion)
                Text(sound.name).font(FontRole.sectionTitle)
                Text(sound.caption).font(FontRole.metadata).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }
                    .font(FontRole.button)
            }

            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(engine.level(for: sound.id)) },
                    set: { engine.setLevel(Float($0), for: sound.id) }
                ), in: 0...1)
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
            }

            Button {
                Haptics.tabChanged()
                engine.switchOff(sound.id)
                dismiss()
            } label: {
                Text(engine.activeIDs.contains(sound.id) ? "关掉这一层" : "打开这一层")
                    .font(FontRole.button)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.Spacing.s)
            }
            .buttonStyle(.bordered)
            .tint(Tokens.Palette.vermilion)

            Spacer(minLength: 0)
        }
        .padding(Tokens.Spacing.l)
    }
}


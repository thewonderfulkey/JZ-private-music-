import Combine
import SwiftUI

// MARK: - 助眠模式（第一版：声音全部来自 Moodist，按 URL 取）
//
// 版式参考 moodist.mvze.net（分类栏 + 图标网格 + 底部正在播放条），
// 但配色走我们自己的水墨口径：纸底、墨色圆钮、**朱砂只用来标"这一层开着"**。
//
// 页面是 **push 进导航栈** 的（不是全屏 cover），所以底部五格栏还在、左上角有系统返回。
struct SleepView: View {

    private var engine: SleepAudioEngine { .shared }

    @State private var category = SleepCategory.all.first?.id ?? "nature"
    @State private var volumeTarget: SleepSound?
    @State private var showTimerMenu = false
    @State private var now = Date()
    @State private var showPresetEditor = false

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Tokens.Spacing.s), count: 4)

    private var remaining: TimeInterval? {
        guard let ends = engine.timerEndsAt else { return nil }
        return max(0, ends.timeIntervalSince(now))
    }

    private var sounds: [SleepSound] { SleepSound.inCategory(category) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Tokens.Palette.paper.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l, pinnedViews: []) {
                    presetStrip
                    categoryStrip
                    grid
                    footerNote
                }
                .padding(.top, Tokens.Spacing.s)
                .padding(.bottom, engine.activeIDs.isEmpty ? Tokens.Spacing.l : 96)
                .readableWidth()
            }
            .scrollIndicators(.hidden)

            if !engine.activeIDs.isEmpty { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(Tokens.Motion.stateChange, value: engine.activeIDs)
        .navigationTitle("助眠")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { timerButton }
        }
        .confirmationDialog("定时关闭", isPresented: $showTimerMenu, titleVisibility: .visible) {
            ForEach(SleepTimerMinutes.allCases) { m in
                Button(m.title) { Haptics.success(); engine.startTimer(m) }
            }
            if engine.timerSelection != nil {
                Button("关闭定时", role: .destructive) { Haptics.tabChanged(); engine.cancelTimer() }
            }
        } message: {
            Text("到点后先淡出 30 秒再停，明晚点一下就能原样回来。")
        }
        .sheet(item: $volumeTarget) { sound in
            SleepVolumeSheet(sound: sound).presentationDetents([.height(220)])
        }
        .onReceive(clock) { now = $0 }
        .overlay(alignment: .top) {
            if let err = engine.lastError {
                Text(err)
                    .font(FontRole.metadata)
                    .foregroundStyle(Tokens.Palette.paper)
                    .padding(.horizontal, Tokens.Spacing.m)
                    .padding(.vertical, Tokens.Spacing.xs)
                    .background(Capsule().fill(Tokens.Palette.vermilion))
                    .padding(.top, Tokens.Spacing.s)
                    .transition(.opacity)
                    .onTapGesture { engine.clearError() }
            }
        }
    }

    // MARK: 定时

    private var timerButton: some View {
        Button {
            Haptics.tabChanged()
            showTimerMenu = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz")
                if let left = remaining {
                    Text("\(Int(left) / 60):\(String(format: "%02d", Int(left) % 60))")
                        .monospacedDigit()
                } else {
                    Text("定时")
                }
            }
            .font(FontRole.metadata.weight(.medium))
            .foregroundStyle(engine.timerSelection == nil ? Color.secondary : Tokens.Palette.vermilion)
        }
    }

    // MARK: 搭配组合

    private var presetStrip: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack {
                Text("搭配组合").font(FontRole.sectionTitle)
                Spacer()
                Text("点一下整组调出来").font(FontRole.metadata).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)

            ScrollView(.horizontal) {
                HStack(spacing: Tokens.Spacing.s) {
                    ForEach(SleepPreset.builtIn) { p in
                        Button {
                            Haptics.success()
                            engine.apply(p)
                        } label: {
                            presetCard(p)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.pageMargin)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func presetCard(_ p: SleepPreset) -> some View {
        let on = !p.mix.isEmpty && p.mix.allSatisfy { engine.activeIDs.contains($0.0) }
        return VStack(alignment: .leading, spacing: 4) {
            Text(p.name)
                .font(FontRole.songTitle.weight(.semibold))
                .foregroundStyle(on ? Tokens.Palette.paper : .primary)
            Text(p.caption)
                .font(FontRole.metadata)
                .foregroundStyle(on ? Tokens.Palette.paper.opacity(0.85) : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(Tokens.Spacing.s)
        .frame(width: 148, height: 78, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(on ? Tokens.Palette.vermilion : Tokens.Palette.paperElevated)
        )
    }

    // MARK: 分类

    private var categoryStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Tokens.Spacing.xs) {
                ForEach(SleepCategory.all) { c in
                    Button {
                        Haptics.tabChanged()
                        withAnimation(Tokens.Motion.stateChange) { category = c.id }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: c.symbol).font(.caption)
                            Text(c.name).font(FontRole.metadata.weight(.medium))
                        }
                        .padding(.horizontal, Tokens.Spacing.s)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(category == c.id ? Tokens.Palette.vermilion
                                                            : Tokens.Palette.paperElevated)
                        )
                        .foregroundStyle(category == c.id ? Tokens.Palette.paper : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: 网格

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: Tokens.Spacing.m) {
            ForEach(sounds) { s in
                SleepTile(sound: s,
                          isOn: engine.activeIDs.contains(s.id),
                          isPreparing: engine.preparing.contains(s.id),
                          onTap: {
                              if engine.activeIDs.contains(s.id) { Haptics.tabChanged() } else { Haptics.success() }
                              engine.toggle(s.id)
                          },
                          onLongPress: { Haptics.tabChanged(); volumeTarget = s })
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
    }

    private var footerNote: some View {
        Text("点一下开一层，可以叠着听；长按单独调音量。声音首次播放需要联网，之后本地就有。")
            .font(FontRole.metadata)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Tokens.Spacing.l)
            .padding(.top, Tokens.Spacing.s)
    }

    // MARK: 底部条

    private var bottomBar: some View {
        HStack(spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(barTitle).font(FontRole.metadata).foregroundStyle(.secondary)
                Text(engine.summary)
                    .font(FontRole.songSubtitle.weight(.medium))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let f = engine.activeIDs.first, let s = SleepSound.find(f) { volumeTarget = s }
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
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                .fill(Tokens.Palette.paperElevated)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        )
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private var barTitle: String {
        let n = engine.activeIDs.count
        if engine.isPlaying { return "正在播放（\(n)）" }
        if engine.stoppedByTimer { return "已停止 · \(n) 层保留" }
        return "已暂停（\(n)）"
    }
}

// MARK: - 单个声音钮

private struct SleepTile: View {

    let sound: SleepSound
    let isOn: Bool
    let isPreparing: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var pressed = false
    @State private var didLongPress = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(isOn ? Tokens.Palette.vermilion : Tokens.Palette.paperElevated)
                    .frame(width: 62, height: 62)
                if isPreparing {
                    ProgressView().tint(isOn ? Tokens.Palette.paper : .secondary)
                } else {
                    Image(systemName: sound.symbol)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(isOn ? Tokens.Palette.paper : Color.secondary)
                }
            }
            Text(sound.name)
                .font(.caption2)
                .foregroundStyle(isOn ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .scaleEffect(pressed ? 0.93 : 1)
        .animation(Tokens.Motion.pressDown, value: pressed)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.35, pressing: { pressed = $0 }, perform: {
            didLongPress = true
            onLongPress()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { didLongPress = false }
        })
        .onTapGesture {
            if didLongPress { didLongPress = false; return }
            onTap()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sound.name)，\(SleepCategory.name(sound.category))")
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
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: sound.symbol).foregroundStyle(Tokens.Palette.vermilion)
                Text(sound.name).font(FontRole.sectionTitle)
                Text(sound.english).font(FontRole.metadata).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.font(FontRole.button)
            }
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(engine.level(for: sound.id)) },
                                      set: { engine.setLevel(Float($0), for: sound.id) }), in: 0...1)
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Haptics.tabChanged()
                if engine.activeIDs.contains(sound.id) { engine.switchOff(sound.id) } else { engine.switchOn(sound.id) }
                dismiss()
            } label: {
                Text(engine.activeIDs.contains(sound.id) ? "关掉这一层" : "打开这一层")
                    .font(FontRole.button).frame(maxWidth: .infinity).padding(.vertical, Tokens.Spacing.s)
            }
            .buttonStyle(.bordered)
            .tint(Tokens.Palette.vermilion)
            Spacer(minLength: 0)
        }
        .padding(Tokens.Spacing.l)
    }
}

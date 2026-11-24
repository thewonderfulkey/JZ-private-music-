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
    private var library: SleepLibrary { .shared }
    private var store: SleepPresetStore { .shared }

    @State private var category = SleepCategory.all.first?.id ?? "nature"
    @State private var volumeTarget: SleepSound?
    @State private var showTimerMenu = false
    @State private var now = Date()
    @State private var showCustomTimer = false
    @State private var customMinutes = ""
    @State private var showSavePreset = false
    @State private var presetName = ""

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Tokens.Spacing.s), count: 2)

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
            ToolbarItem(placement: .topBarTrailing) { libraryMenu }
            ToolbarItem(placement: .topBarTrailing) { timerButton }
        }
        .confirmationDialog("定时关闭", isPresented: $showTimerMenu, titleVisibility: .visible) {
            ForEach(SleepTimerMinutes.allCases) { m in
                Button(m.title) { Haptics.success(); engine.startTimer(m) }
            }
            Button("自定义…") {
                customMinutes = ""
                showCustomTimer = true
            }
            if engine.timerEndsAt != nil {
                Button("关闭定时", role: .destructive) { Haptics.tabChanged(); engine.cancelTimer() }
            }
        } message: {
            Text("到点后先淡出 30 秒再停，明晚点一下就能原样回来。")
        }
        .alert("自定义定时", isPresented: $showCustomTimer) {
            TextField("分钟（1–720）", text: $customMinutes)
                .keyboardType(.numberPad)
            Button("开始") {
                if let m = Int(customMinutes), SleepTimerMinutes.customRange.contains(m) {
                    Haptics.success()
                    engine.startTimer(minutes: m)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("到点后先淡出 30 秒再停。")
        }
        .alert("保存为搭配组合", isPresented: $showSavePreset) {
            TextField("给它起个名字", text: $presetName)
            Button("保存") { saveCurrentMix() }
            Button("取消", role: .cancel) { presetName = "" }
        } message: {
            Text("会存下当前这几层和各自的音量，下次一键调出来。")
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

    // MARK: 下载 / 存储

    private var libraryMenu: some View {
        Menu {
            Button {
                Haptics.success()
                Task { await library.download(category: category) }
            } label: {
                Label("下载「\(SleepCategory.name(category))」全部", systemImage: "arrow.down.to.line")
            }
            Button {
                Haptics.tabChanged()
                library.clearCache()
            } label: {
                Label("清理播放缓存", systemImage: "trash")
            }
            if !library.downloaded.isEmpty {
                Button(role: .destructive) {
                    library.removeAllDownloads()
                } label: {
                    Label("删除全部已下载", systemImage: "trash.fill")
                }
            }
        } label: {
            Image(systemName: library.downloading.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
                .foregroundStyle(library.downloading.isEmpty ? Color.secondary : Tokens.Palette.vermilion)
        }
        .accessibilityLabel("下载与存储")
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
                        Button { Haptics.success(); engine.apply(p) } label: { presetCard(p) }
                            .buttonStyle(.plain)
                    }
                    ForEach(store.custom) { p in
                        Button { Haptics.success(); engine.apply(p) } label: { presetCard(p) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    Haptics.warning()
                                    store.delete(p.id)
                                } label: { Label("删除这个组合", systemImage: "trash") }
                            }
                    }
                    if !engine.activeIDs.isEmpty {
                        Button { Haptics.tabChanged(); showSavePreset = true } label: { saveCard }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.pageMargin)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func presetCard(_ p: SleepPreset) -> some View {
        let on = !p.mix.isEmpty && p.mix.allSatisfy { engine.activeIDs.contains($0.soundID) }
        let custom = p.isCustom
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(p.name)
                    .font(FontRole.songTitle.weight(.semibold))
                    .lineLimit(1)
                if custom {
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                        .opacity(0.7)
                }
            }
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

    private var saveCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Tokens.Palette.vermilion)
            Text("存下当前混音")
                .font(FontRole.metadata)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 148, height: 78)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.vermilion.opacity(0.45),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private func saveCurrentMix() {
        let mix = engine.currentMix()
        guard !mix.isEmpty else { presetName = ""; return }
        let name = presetName
        presetName = ""
        Haptics.success()
        store.save(name: name, mix: mix)
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
                          isDownloaded: library.isDownloaded(s.id),
                          isDownloading: library.downloading.contains(s.id),
                          level: Double(engine.level(for: s.id)),
                          onTap: {
                              if engine.activeIDs.contains(s.id) { Haptics.tabChanged() } else { Haptics.success() }
                              engine.toggle(s.id)
                          },
                          onLevel: { engine.setLevel(Float($0), for: s.id) },
                          onLongPress: { Haptics.tabChanged(); volumeTarget = s })
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
    }

    private var footerNote: some View {
        Text("点左边图标开一层，拖动卡里的滑杆单独调音量；长按可以下载到本地。\n已下载 \(library.downloaded.count) 个 · 本地 \(fmt(library.libraryBytes)) · 缓存 \(fmt(library.cacheBytes))")
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

    private func fmt(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private var barTitle: String {
        let n = engine.activeIDs.count
        if engine.isPlaying { return "正在播放（\(n)）" }
        if engine.stoppedByTimer { return "已停止 · \(n) 层保留" }
        return "已暂停（\(n)）"
    }
}

/// 按下就缩一点（老板一直嫌点击反馈不明显）
private struct SleepIconBlockStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Tokens.Motion.pressDown, value: configuration.isPressed)
    }
}

// MARK: - 单个声音卡
//
// 版式照 Moodist 的卡片：左边一块图标、右边名字 + **卡内音量滑杆**。
// 老板要的「每个声音单独的声音大小配置」就放在卡里，不用长按。
private struct SleepTile: View {

    let sound: SleepSound
    let isOn: Bool
    let isPreparing: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let level: Double
    let onTap: () -> Void
    let onLevel: (Double) -> Void
    let onLongPress: () -> Void

    @State private var didLongPress = false

    var body: some View {
        HStack(spacing: 0) {
            // 左：图标块（点它开关）
            Button {
                if didLongPress { didLongPress = false; return }
                onTap()
            } label: {
                ZStack {
                    Rectangle()
                        .fill(isOn ? Tokens.Palette.vermilion : Tokens.Palette.paperElevated)
                    if isPreparing || isDownloading {
                        ProgressView().tint(isOn ? Tokens.Palette.paper : .secondary)
                    } else {
                        Image(systemName: sound.symbol)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(isOn ? Tokens.Palette.paper : Color.secondary)
                    }
                }
                .frame(width: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(SleepIconBlockStyle())

            // 右：名字 + 音量
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(sound.name)
                        .font(.footnote.weight(isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Tokens.Palette.vermilion.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                // 长按名字（不是滑杆）才能调出下载面板
                .onLongPressGesture(minimumDuration: 0.4) {
                    didLongPress = true
                    onLongPress()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { didLongPress = false }
                }
                HStack(spacing: 5) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Slider(value: Binding(get: { level }, set: onLevel), in: 0...1)
                        .controlSize(.mini)
                        .tint(isOn ? Tokens.Palette.vermilion : Color.secondary.opacity(0.5))
                }
                .frame(height: 14)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 74)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(isOn ? Tokens.Palette.vermilion.opacity(0.10) : Tokens.Palette.paperElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(isOn ? Tokens.Palette.vermilion.opacity(0.45) : .clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sound.name)，\(SleepCategory.name(sound.category))")
        .accessibilityValue("\(isOn ? "开" : "关")，音量 \(Int(level * 100))%")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onTap() }
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: onLevel(min(1, level + 0.1))
            case .decrement: onLevel(max(0, level - 0.1))
            @unknown default: break
            }
        }
    }
}

// MARK: - 单层音量

private struct SleepVolumeSheet: View {

    let sound: SleepSound
    @Environment(\.dismiss) private var dismiss
    private var engine: SleepAudioEngine { .shared }
    private var library: SleepLibrary { .shared }
    private var store: SleepPresetStore { .shared }

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
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: SleepLibrary.shared.isDownloaded(sound.id)
                      ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(SleepLibrary.shared.isDownloaded(sound.id)
                                     ? Tokens.Palette.vermilion : Color.secondary)
                Text(SleepLibrary.shared.isDownloaded(sound.id) ? "已下载到本地，飞行模式也能听"
                                                               : "还没下载，播放时才拉取")
                    .font(FontRole.metadata)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(SleepLibrary.shared.isDownloaded(sound.id) ? "删除" : "下载") {
                    Haptics.tabChanged()
                    if SleepLibrary.shared.isDownloaded(sound.id) {
                        SleepLibrary.shared.removeDownload(sound)
                    } else {
                        Task { await SleepLibrary.shared.download(sound) }
                    }
                }
                .font(FontRole.metadata.weight(.semibold))
                .tint(Tokens.Palette.vermilion)
                .disabled(SleepLibrary.shared.downloading.contains(sound.id))
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

import SwiftUI

// MARK: - 识曲（设计稿 §3.8）
//
// 这一版是**舞台 + 状态机**：麦克风舞台、聆听倒计时、辨认中、结果/不可用四种状态都通了；
// 真正的识别通道（酷狗指纹 + 网易 fp）随 P3 接入——所以到点后落的是"通道未接"这一态，不假装有结果。
struct RecognizeView: View {

    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var library

    enum Phase: Equatable {
        case idle
        case listening
        case recognizing
        case unavailable
    }

    @State private var phase: Phase = .idle
    @State private var remaining = 12
    @State private var pulse = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: Tokens.Spacing.l) {
                stage
                phaseText
                recentSection
            }
            .padding(.top, Tokens.Spacing.m)
            .padding(.bottom, Tokens.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach([12, 15, 20], id: \.self) { seconds in
                        Button {
                            settings.recognizeSeconds = seconds
                        } label: {
                            if settings.recognizeSeconds == seconds {
                                Label("听 \(seconds) 秒", systemImage: "checkmark")
                            } else {
                                Text("听 \(seconds) 秒")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text("听 \(settings.recognizeSeconds) 秒")
                            .font(.footnote)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .disabled(phase == .listening || phase == .recognizing)
            }
        }
        .onDisappear { stop() }
    }

    // MARK: 麦克风舞台

    private var stage: some View {
        ZStack {
            // 聆听时外圈呼吸
            Circle()
                .fill(Tokens.Palette.vermilion.opacity(0.06))
                .frame(width: 210, height: 210)
                .scaleEffect(pulse && phase == .listening ? 1.06 : 1.0)
                .opacity(phase == .listening ? 1 : 0.5)
            Circle()
                .fill(Tokens.Palette.vermilion.opacity(0.10))
                .frame(width: 176, height: 176)
            Circle()
                .fill(Tokens.Palette.paperElevated)
                .frame(width: 146, height: 146)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))

            Image(systemName: phase == .listening ? "stop.fill" : "mic.fill")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(phase == .listening ? Tokens.Palette.vermilion : Color.primary)
        }
        .frame(height: 220)
        .contentShape(Rectangle())
        .onTapGesture(perform: handleMicTap)
        .accessibilityElement()
        .accessibilityLabel(phase == .listening ? "停止聆听" : "开始识曲")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { handleMicTap() }
        .animation(.easeInOut(duration: 0.6), value: phase)
        .onChange(of: phase) { _, newValue in
            if newValue == .listening {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { pulse = false }
            }
        }
    }

    // MARK: 阶段文案

    @ViewBuilder
    private var phaseText: some View {
        VStack(spacing: Tokens.Spacing.xxs) {
            switch phase {
            case .idle:
                Text("点一下麦克风，开始听")
                    .font(.title3)
                Text("把手机靠近正在外放的音箱")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .listening:
                Text("正在聆听…")
                    .font(.title3)
                Text("还能听 \(remaining) 秒 · 再点一下可取消")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .recognizing:
                Text("正在辨认…")
                    .font(.title3)
                Text("比对曲库中")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Text("识别通道还没接上")
                    .font(.title3)
                Text("指纹通道（酷狗 + 网易）随 P3 接入；现在这条链只到状态机")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Tokens.Spacing.l)
                Button("再听一次") { handleMicTap() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, Tokens.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 最近识过

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(title: "最近识过")
            if library.recognizeHistory.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("第一次用？")
                        .font(.footnote.weight(.semibold))
                    ForEach(["外放不用开到最大，正常音量就够",
                             "一米内，别用手挡住麦克风",
                             "环境太吵就换个地方"], id: \.self) { tip in
                        Text("· \(tip)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.pageMargin)
            } else {
                VStack(spacing: 0) {
                    ForEach(library.recognizeHistory.prefix(10)) { song in
                        SongRow(song: song)
                            .padding(.horizontal, Tokens.Spacing.pageMargin)
                    }
                }
            }
        }
    }

    // MARK: 状态机

    private func handleMicTap() {
        switch phase {
        case .listening, .recognizing:
            stop()
        case .idle, .unavailable:
            start()
        }
    }

    private func start() {
        task?.cancel()
        remaining = settings.recognizeSeconds
        phase = .listening
        task = Task { @MainActor in
            for _ in 0..<settings.recognizeSeconds {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
            }
            guard !Task.isCancelled else { return }
            phase = .recognizing
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            phase = .unavailable
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        phase = .idle
        remaining = settings.recognizeSeconds
    }
}

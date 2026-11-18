import SwiftUI

// MARK: - 下载弹层（P2）
//
// 三段式，和 Android 的下载流程同口径：
//   选档 → 核对音源（跨平台换源，最多 40s）→ 确认体积/码率后开始下载。
// 关键点：**降级必须让用户看见**——选无损只拿到 320k 时，标题会写"只有高品 320k"，
// 把"没有无损"这件事摆在按钮上面，而不是下完再在列表里偷偷标一下。
struct DownloadSheet: View {

    @Environment(DownloadFlow.self) private var flow
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                    if let song = flow.song {
                        header(song)
                    }
                    stageContent
                }
                .padding(.horizontal, Tokens.Spacing.pageMargin)
                .padding(.top, Tokens.Spacing.s)
                .padding(.bottom, Tokens.Spacing.xxl)
            }
            .scrollIndicators(.hidden)
            .background(Tokens.Palette.paper.ignoresSafeArea())
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { flow.dismiss() }
                        .accessibilityLabel("关闭下载面板")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: 歌头

    private func header(_ song: Song) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            SongArtwork(song: song, size: 56, radius: Tokens.Radius.artworkSmall)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(song.singer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Spacing.xs)
            if flow.isDownloaded(song) {
                Text("已在本地")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 三段内容

    @ViewBuilder
    private var stageContent: some View {
        switch flow.stage {
        case .choosing:
            choosing
        case .resolving:
            resolving
        case .offer:
            offerView
        case .started:
            startedView
        case .failed:
            failed
        }
    }

    private var choosing: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("选择音质")
                .font(FontRole.sectionTitle)

            ForEach(DownloadGuard.qualityOptions()) { level in
                Button {
                    flow.choose(level)
                } label: {
                    qualityRow(level)
                }
                .buttonStyle(.press)
                .accessibilityHint("直接开始下载\(level.displayName)")
            }

            Text("点一下就直接开始下载：先核对音源（跨平台换源，最多 40 秒），拿到的就是这一档才下；\n万一只取到更低档位，会先问你一句，不会悄悄降级。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, Tokens.Spacing.xxs)
        }
    }

    private func qualityRow(_ level: QualityLevel) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(level.displayName)
                    .font(FontRole.songTitle)
                Text(hint(for: level))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Tokens.Spacing.xs)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Tokens.Spacing.s)
        .padding(.vertical, Tokens.Spacing.s)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.paperElevated)
        )
    }

    private func hint(for level: QualityLevel) -> String {
        switch level {
        case .lossless: return "FLAC 原样保留，体积最大（一首约 20–40 MB）"
        case .high: return "大多数歌都拿得到，体积约无损的三分之一"
        case .standard: return "兼容性最好，体积最小"
        }
    }

    private var resolving: some View {
        VStack(spacing: Tokens.Spacing.m) {
            ProgressView()
            Text("正在核对音源…")
                .font(FontRole.songTitle)
            Text("按「歌名 + 歌手」跨平台换源，最多 40 秒。这一步决定你能不能真拿到 \(flow.want.displayName)。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("取消") { flow.dismiss() }
                .font(.footnote)
                .foregroundStyle(Tokens.Palette.vermilion)
                .buttonStyle(.press)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Spacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在核对音源，最多 40 秒")
    }

    @ViewBuilder
    private var offerView: some View {
        if let offer = flow.offer {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(offer.isExact ? "可以下载 \(offer.quality.displayName)"
                                       : "只有 \(offer.quality.displayName)")
                        .font(FontRole.sectionTitle)
                    if !offer.note.isEmpty {
                        Text(offer.note)
                            .font(.footnote)
                            .foregroundStyle(offer.isExact ? Color.secondary : Color.orange)
                    }
                }

                facts(offer.source)

                Button {
                    flow.confirm()
                } label: {
                    Text(flow.startedDownload ? "重新下载" : "开始下载")
                        .font(FontRole.button)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Spacing.minTapTarget)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                                .fill(Tokens.Palette.vermilion)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.press)

                Button("换个档位") {
                    flow.choose(flow.want == .lossless ? .high : .lossless)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .buttonStyle(.press)

                Text(settings.wifiOnlyDownload
                     ? "已开启「仅 Wi-Fi 下载」，蜂窝网络下会被拦下。"
                     : "会在后台下载，完成后发一条通知。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func facts(_ src: StreamSource) -> some View {
        VStack(spacing: 0) {
            factRow("来源", "\(src.platform.shortName) · \(src.backendName)")
            Divider().padding(.leading, Tokens.Spacing.s)
            factRow("实测", "\(src.format.uppercased()) · \(src.kbps > 0 ? "\(src.kbps) kbps" : "码率待测")")
            Divider().padding(.leading, Tokens.Spacing.s)
            factRow("体积", DownloadGuard.sizeText(src.totalBytes))
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.paperElevated)
        )
        .accessibilityElement(children: .combine)
    }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: Tokens.Spacing.xs)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Tokens.Spacing.s)
        .padding(.vertical, 10)
    }

    private var startedView: some View {
        VStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Tokens.Palette.vermilion)
            Text("已开始下载")
                .font(FontRole.sectionTitle)
            if let offer = flow.offer {
                Text("\(offer.quality.displayName) · \(DownloadGuard.sizeText(offer.source.totalBytes))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("可以在「下载」页看进度，完成后会发一条通知。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("去看下载") {
                // 老板 r116："点了『去看下载』人还停在播放页，虽然底下已经切到下载页了，但播放页没退出。"
                // 所以这一下要做三件事：关弹层 → 退出播放页 → 切到下载 Tab。
                // （播放页是盖在根视图上的全屏模态，只关弹层的话人当然还在播放页里。）
                flow.dismiss()
                router.showPlayer = false
                router.tab = .downloads
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Tokens.Palette.vermilion)
            .buttonStyle(.press)
            .padding(.top, Tokens.Spacing.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Spacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("已开始下载")
    }

    private var failed: some View {
        VStack(spacing: Tokens.Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(flow.message ?? "下载没能开始")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            HStack(spacing: Tokens.Spacing.l) {
                Button("重新选档") { flow.choose(flow.want) }
                    .font(.footnote.weight(.semibold))
                Button("关闭") { flow.dismiss() }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.press)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Spacing.xl)
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI
import UIKit

// MARK: - 全局组件（设计稿 §2）

// MARK: 纸底

extension View {
    /// 所有页面根视图都套这一层（设计稿 §2 / §5.3）
    func paperBackground() -> some View {
        background(Tokens.Palette.paper.ignoresSafeArea())
    }
}

// MARK: 封面

/// 歌曲封面：原图 → 加载失败/缺失时用 CoverResolver 兜底 → 仍无则占位
struct SongArtwork: View {
    let song: Song
    var size: CGFloat = Tokens.Size.songRowArtwork
    var radius: CGFloat = Tokens.Radius.artworkSmall

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: song.id) { await load() }
    }

    /// 封面走内存缓存：滚动离开再回来不重新下载（AsyncImage 会重下）
    ///
    /// r65：取图逻辑收进 `CoverImageCache.image(for:)`，播放页也走同一条链
    /// ——老板反馈"列表里有封面、点进播放页却没有封面"，根因就是播放页只读 `song.picURL`，
    /// 没有走这条路（网易/酷我的歌常常 picURL 为空，靠 CoverResolver 兜底才有图）。
    private func load() async {
        if image != nil { return }
        image = await CoverImageCache.shared.image(for: song)
    }

    private var placeholder: some View {
        ZStack {
            Tokens.Palette.paperElevated
            Image(systemName: "music.note")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: SongRow（§2.1）

/// 全 App 唯一行样式：52 封面 + 歌名 + 歌手·专辑 + 平台胶囊 + 时长
///
/// r65（老板反馈 ⑧："每一条返回结果都太细了，显得挨的很紧，可以查看图片中的样式"）：
/// 参照群里那张截屏的排布——封面 48→52、行内上下各留 12（行高 ≈ 76）、标题与副行间距 3、
/// 列表**不再用分隔线**，靠行高本身隔开；按压时整行铺一层高亮（见 `.rowPress`）。
struct SongRow: View {
    let song: Song
    var showsFavorite = false
    var isFavorite = false
    var onFavorite: (() -> Void)?
    var subtitle: String?

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            SongArtwork(song: song)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.name)
                    .font(FontRole.songTitle)
                    .lineLimit(1)
                Text(subtitle ?? secondaryText)
                    .font(FontRole.songSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Tokens.Spacing.xs)

            // r66（老板反馈 ③"后面的标签统一都被挤压了，要横着显示"）：
            // 歌名/专辑一长，HStack 就把右边这组挤扁 —— 平台胶囊被压成一字一行、
            // 时长 "03:43" 折成 "03:4 / 3"。这一组给 `fixedSize` + 最高布局优先级，
            // 宁可让左边的歌名省略号，也不让标签换行。
            HStack(spacing: Tokens.Spacing.xs) {
                PlatformChip(platform: song.platform)
                Text(song.durationText)
                    .font(FontRole.metadata)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(minWidth: 36, alignment: .trailing)
                if showsFavorite, let onFavorite {
                    Button(action: onFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(isFavorite ? Tokens.Palette.vermilion : Color.secondary)
                            .minimumTapTarget()
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        // 行高用 minHeight 而不是 height：Dynamic Type 最大档（AX5）时行要能长高，不能截断
        .frame(minHeight: Tokens.Size.songRowHeight)
        .padding(.vertical, Tokens.Spacing.xxs)
        .padding(.horizontal, Tokens.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(song.name)，\(song.singer)，\(song.durationText)")
        .accessibilityHint("轻点播放")
    }

    private var secondaryText: String {
        song.album.isEmpty ? song.singer : "\(song.singer) · \(song.album)"
    }
}

/// 平台胶囊（§3.3）：统一墨色胶囊 + 文字，不用四家各自的颜色
///
/// r66：胶囊里的文字**必须单行且不压缩**——搜索结果是两字平台名（酷狗/酷我），
/// 被挤窄以后会变成一字一行（老板截屏里就是竖着排的）。
struct PlatformChip: View {
    let platform: MusicPlatform

    var body: some View {
        Text(platform.shortName)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .foregroundStyle(.secondary)
    }
}

// MARK: StatusLine（§2.2）

/// 状态行：进行中 / 换源 / 错误 / 提示，一律"图标 + 文字"，不靠颜色单独传达
struct StatusLine: View {
    enum Kind {
        case progress(String)
        case switching(String)
        case error(String)
        case info(String)
    }

    let kind: Kind

    var body: some View {
        HStack(spacing: 6) {
            switch kind {
            case .progress(let text):
                ProgressView().scaleEffect(0.6)
                body(text, color: .secondary)
            case .switching(let text):
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                body(text, color: .secondary)
            case .error(let text):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                body(text, color: .orange)
            case .info(let text):
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                body(text, color: .secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
    }

    private func body(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

// MARK: 平台状态行（§2.5）

/// 搜索结果顶部：`酷我 12 · QQ 8 · 网易 暂无 · 酷狗 5`，失败显示"超时"
struct PlatformStatusRow: View {
    let results: [SearchService.PlatformResult]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text(" · ")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 3) {
                    Text(item.platform.shortName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.failed || item.songs.isEmpty ? Color.secondary : Color.primary)
                    if item.failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                        Text("超时")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if item.songs.isEmpty {
                        Text("暂无")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("\(item.songs.count)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var ordered: [SearchService.PlatformResult] {
        results
    }

    private var accessibilityText: String {
        ordered.map { item in
            if item.failed { return "\(item.platform.shortName)超时" }
            if item.songs.isEmpty { return "\(item.platform.shortName)无结果" }
            return "\(item.platform.shortName)\(item.songs.count)条"
        }.joined(separator: "，")
    }
}

// MARK: MediaCard（§2.4）

/// 横向卡片：160pt 方图 + 标题 + 副标题（发现页的编辑精选 / 最近播放）
struct MediaCard: View {
    let title: String
    let subtitle: String
    var artwork: AnyView? = nil      // 没有封面图时用纯色块
    var size: CGFloat = 160
    var onTap: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let artwork {
                    artwork
                } else {
                    ZStack {
                        Tokens.Palette.paperElevated
                        Image(systemName: "music.note")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.top, Tokens.Spacing.xs)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(subtitle)")
    }
}

// MARK: 状态页（空 / 加载 / 失败）

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var description: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let description {
                Text(description)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
    }
}

/// 首屏骨架：几行灰块，比整屏转圈更少跳动
struct SkeletonRows: View {
    var count = 5

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: Tokens.Spacing.s) {
                    RoundedRectangle(cornerRadius: Tokens.Radius.artworkSmall, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: Tokens.Size.songRowArtwork, height: Tokens.Size.songRowArtwork)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                            .frame(height: 12).frame(maxWidth: 160, alignment: .leading)
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05))
                            .frame(height: 10).frame(maxWidth: 110, alignment: .leading)
                    }
                    Spacer()
                }
                .frame(height: Tokens.Size.songRowHeight)
                .padding(.horizontal, Tokens.Spacing.pageMargin)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: 小工具

/// 区块标题（发现/资料库用）：标题 + 右侧可点动作
struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(FontRole.sectionTitle)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote)
                    .foregroundStyle(Tokens.Palette.vermilion)
                    .buttonStyle(.press)
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
    }
}

/// 待接入占位：明确写出"这一块随哪一期接入"，不用假数据糊
struct PendingFeatureRow: View {
    let title: String
    let note: String

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "clock.badge.questionmark")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(FontRole.songTitle)
                    .foregroundStyle(.secondary)
                Text(note)
                    .font(FontRole.metadata)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(minHeight: Tokens.Size.songRowHeight)
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 按压反馈（老板反馈 ③ / r65 反馈 ⑨：点击反馈不明显）

/// 全 App 统一的按压反馈：按下缩到 0.94、压暗到 0.72、松手弹回。
///
/// 为什么不用 `.plain`：`.plain` 把系统的按下高亮也一起去掉了，行/卡片点下去毫无反馈，
/// 加上"卡了一下"的体感就变成"点了没反应"。触觉由调用方在动作里补（`Haptics.tap()`）。
///
/// r65：老板对着群里那段 Light Player 的录屏说"所有的点击反馈都不明显"，所以缩得更狠、压得更暗，
/// 松手用更快的 spring 弹回——按下去要立刻有"被按住了"的感觉。
struct PressFeedbackButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    var dim: Double = 0.72

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? dim : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressFeedbackButtonStyle {
    /// 用法：`.buttonStyle(.press)`
    static var press: PressFeedbackButtonStyle { PressFeedbackButtonStyle() }
    /// 大块卡片用更轻的缩放（整张卡缩 0.94 会显得晃）
    static var pressSubtle: PressFeedbackButtonStyle {
        PressFeedbackButtonStyle(scale: 0.97, dim: 0.88)
    }
}

/// 列表行 / 卡片专用：按下时**整块铺一层高亮**（Light Player 那种"整条压暗"），再轻缩一点。
///
/// 为什么行不能只靠 `.press` 的缩放：行太宽，0.94 的缩放肉眼几乎看不出来；
/// 而"按下就有一整条底色"是手机上最容易被看见的反馈。高亮淡出比淡入慢，按一下有拖尾感。
struct RowPressButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.985
    var highlight: Double = 0.10
    var cornerRadius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? highlight : 0))
            )
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed
                       ? .easeOut(duration: 0.06)
                       : .easeOut(duration: 0.22),
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == RowPressButtonStyle {
    /// 用法（列表行）：`Button { … } label: { SongRow(song: song) }.buttonStyle(.rowPress)`
    static var rowPress: RowPressButtonStyle { RowPressButtonStyle() }
}

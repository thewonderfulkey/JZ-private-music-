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
    ///
    /// 第二十轮（老板：半壶纱播完、切到奢香夫人时**悬浮栏封面不换**）：这里原来第一行是
    /// `if image != nil { return }`。`.task(id: song.id)` 虽然会随换歌重跑，但函数一进门就返回，
    /// 于是 `@State image` 一直留着上一首那张图 —— 列表行因为随列表重建看不出问题，
    /// 悬浮栏是常驻视图，一眼就能看出"封面没换"。
    /// 现在**每次 id 变都取一次**：取图期间旧图先留着（不闪占位），取到再替换；
    /// 中途又被换歌时 `.task` 会取消旧任务，这里用 `Task.isCancelled` 挡住过期结果覆盖新图。
    private func load() async {
        let loaded = await CoverImageCache.shared.image(for: song)
        guard !Task.isCancelled else { return }
        image = loaded
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
    /// 榜单/歌单页要的名次位（1 开始）。传 nil 就不占位。
    /// 第二十轮（老板："榜单页太丑、太细了"）：榜单页改回用这个统一行样式，
    /// 名次作为行首的小字——不再另写一套更瘦的榜单行。
    var leadingRank: Int?

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            if let leadingRank {
                // 第二十轮（老板 r83：榜单最后一行"100"横向挤不下、被折成了两行）：
                // 名次槽 20 → 26，并且 `lineLimit(1)` + `minimumScaleFactor` 双保险——
                // 20pt 刚好够两位数，三位数（100）就会换行；大字号下再缩一点也比折行好看。
                Text(String(format: "%02d", leadingRank))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(leadingRank <= 3 ? Tokens.Palette.vermilion : Color.secondary)
                    .frame(width: 26, alignment: .trailing)
            }

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
        // 第三十二轮：从 `onTapGesture` 改成 Button + `.pressSubtle`——
        // 大卡片原来点下去只有导航，没有任何"被按住"的画面，老板对着 Light Player 说"反馈不明显"。
        Button {
            onTap?()
        } label: {
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
        }
        .buttonStyle(.pressSubtle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(subtitle)")
        .accessibilityAddTraits(.isButton)
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

// MARK: 轻提示（Toast）

/// 一句话、1.4 秒自动消失、不吃点击的轻提示。
///
/// 老板 r86："所有模块点击「换一批」之后需要有个小弹窗提醒，否则用户根本不知道有没有更新。"
/// 不做系统 Alert（会打断操作、要点确定），也不做卡片（太重），就是迷你条上方浮一条胶囊。
struct ToastView: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Tokens.Palette.paper)
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.vertical, Tokens.Spacing.xs)
            .background(Capsule().fill(Color.primary.opacity(0.86)))
            .padding(.bottom, Tokens.Size.miniPlayerHeight + Tokens.Spacing.m)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityAddTraits(.isStaticText)
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

// MARK: - 按压反馈（老板反馈 ③ / r65 反馈 ⑨ / 第三十二轮：对齐 Light Player）

/// 全 App 统一的按压反馈：按下缩到 0.95、压暗到 0.78，松手弹回。
///
/// 为什么不用 `.plain`：`.plain` 把系统的按下高亮也一起去掉了，行/卡片点下去毫无反馈，
/// 加上"卡了一下"的体感就变成"点了没反应"。触觉由调用方在动作里补（`Haptics.tap()`）。
///
/// 第三十二轮（2026-11-18，老板对着 Light Player 录屏）：按下要"一按就有"——
/// 下落压到 0.14s 的紧 spring，松手才用 0.30s 的慢一档 spring 顶回来；
/// 两边用同一条曲线会显得"按下去和弹回来一样软"，没有手感。
struct PressFeedbackButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    var dim: Double = 0.78

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? dim : 1)
            .animation(configuration.isPressed ? Tokens.Motion.pressDown : Tokens.Motion.pressUp,
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressFeedbackButtonStyle {
    /// 用法：`.buttonStyle(.press)`
    static var press: PressFeedbackButtonStyle { PressFeedbackButtonStyle() }
    /// 大块卡片用更轻的缩放（整张卡缩 0.95 会显得晃）
    static var pressSubtle: PressFeedbackButtonStyle {
        PressFeedbackButtonStyle(scale: 0.968, dim: 0.90)
    }
}

/// 列表行 / 卡片专用：按下时**整块铺一层高亮**（Light Player 那种"整条压暗"），再轻缩一点。
///
/// 为什么行不能只靠 `.press` 的缩放：行太宽，0.95 的缩放肉眼几乎看不出来；
/// 而"按下就有一整条底色"是手机上最容易被看见的反馈。高亮淡出比淡入慢，按一下有拖尾感。
struct RowPressButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.99
    var highlight: Double = 0.12
    var cornerRadius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? highlight : 0))
            )
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed
                       ? .easeOut(duration: 0.05)
                       : Tokens.Motion.pressUp,
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == RowPressButtonStyle {
    /// 用法（列表行）：`Button { … } label: { SongRow(song: song) }.buttonStyle(.rowPress)`
    static var rowPress: RowPressButtonStyle { RowPressButtonStyle() }
}

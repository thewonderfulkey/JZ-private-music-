import SwiftUI

// MARK: - 发现页 BANNER 轮播（2026-11-27，发现页 2.0 Task 5）
//
// 老板口径：能滑、能关、**只跳站内**。
//   · 图与落点全部来自网易首页 banner（`NeteaseDiscover.banners`），
//     外链（演出/广告）在 `BannerRules.usable` 里就被过滤掉，点不出去；
//   · 落点是**通用歌单页**（`NeteasePlaylistView`）——实测那 4 条站内 banner 全是歌单
//     （targetType 1000），没有一条是单曲，所以歌单页是唯一能真听歌的落点；
//   · 关闭只关当天（`BannerRules.isHidden`），第二天自然回来。
//
// 组件自己不管取数：`DiscoverFeed.banners` 已经是过滤过、按天缓存过的那一份。

struct DiscoverBannerCarousel: View {

    /// 已经过滤好的 banner（站内可跳）
    let banners: [NeteaseBannerItem]
    /// 关掉（父视图负责记"今天关过"）
    let onClose: () -> Void

    @State private var index: Int = 0

    /// 高度跟随 Dynamic Type，但给一个舒服的宽高比区间（16:9 偏矮，3:2 偏方）
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 148

    var body: some View {
        if BannerRules.shouldShow(count: banners.count) {
            ZStack(alignment: .topTrailing) {
                carousel
                closeButton
            }
            .overlay(alignment: .bottom) {
                if BannerRules.shouldAutoAdvance(count: banners.count) {
                    pageDots
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var carousel: some View {
        TabView(selection: $index) {
            ForEach(Array(banners.enumerated()), id: \.offset) { offset, banner in
                NavigationLink {
                    NeteasePlaylistView(playlistID: banner.playlistID ?? "",
                                        fallbackTitle: banner.title)
                } label: {
                    cell(banner)
                }
                .buttonStyle(.pressSubtle)
                .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: height)
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .onChange(of: index) { _, new in
            // 用户手动滑到别的位置后，自动轮播从新位置继续（不"抢回去"）
            _ = BannerRules.nextIndex(current: new, count: banners.count)
        }
        .task(id: banners.count) {
            // 只有 1 条不启定时器；也不在拖动中推进
            guard BannerRules.shouldAutoAdvance(count: banners.count) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(BannerRules.autoAdvanceSec * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    index = BannerRules.advanced(from: index, count: banners.count)
                }
            }
        }
    }

    private func cell(_ banner: NeteaseBannerItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            // 图片自己拉：banner 图不在封面缓存里（那是按歌曲走的）
            AsyncImage(url: URL(string: banner.image), transaction: .init(animation: .easeOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Tokens.Palette.paperElevated
                default:
                    Tokens.Palette.paperElevated
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // 底部压一层暗角：图可能很亮，白字压不住（只在真有文案时才需要）
            if let caption = BannerRules.caption(banner.title) {
                LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.55)],
                               startPoint: .center, endPoint: .bottom)
                Text(caption)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, Tokens.Spacing.s)
                    .padding(.bottom, Tokens.Spacing.s)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityLabel(BannerRules.caption(banner.title) ?? "推荐歌单")
        .accessibilityHint("点一下打开这个歌单")
    }

    private var closeButton: some View {
        Button {
            Haptics.trackChange()
            withAnimation(Tokens.Motion.stateChange) { onClose() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.35), in: Circle())
        }
        .padding(Tokens.Spacing.s)
        .accessibilityLabel("关闭推荐横幅")
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(banners.indices, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.white : Color.white.opacity(0.45))
                    .frame(width: i == index ? 14 : 5, height: 5)
            }
        }
        .padding(.bottom, 8)
        .animation(Tokens.Motion.stateChange, value: index)
        .accessibilityHidden(true)
    }
}

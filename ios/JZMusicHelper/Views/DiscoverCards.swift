import SwiftUI
import UIKit

// MARK: - 发现页新模块的卡片（歌单广场 / 歌手大全）
//
// 所有封面都走 `CoverImageCache`（内存 → 磁盘 → 网络）：和歌曲封面同一条链，
// 只是这里给的是 URL 而不是 Song——所以单独做一个 `RemoteArtwork`，没有第二套缓存。
//
// 尺寸口径（390pt 宽）：
//   · 发现页歌单卡 132×132（一屏露 2.5 张）；广场页双列 171×171
//   · 发现页歌手头像 64（5 个刚好 352 = 390−32）；大全页 88（三列）
struct RemoteArtwork: View {

    let url: String
    var size: CGFloat
    var radius: CGFloat = Tokens.Radius.card
    var circular = false

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Tokens.Palette.paperElevated
                    Image(systemName: "music.note")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(clipShape)
        .task(id: url) {
            guard !url.isEmpty, let parsed = URL(string: url) else { return }
            let loaded = await CoverImageCache.shared.image(for: parsed)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    private var clipShape: AnyShape {
        circular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - 歌单卡

/// 广场双列用的方形封面：宽度跟容器走（不写死 171，iPad / 分屏也对）
struct RemoteSquareArtwork: View {

    let url: String
    var radius: CGFloat = Tokens.Radius.card

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Tokens.Palette.paperElevated
                            Image(systemName: "music.note")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .task(id: url) {
                guard !url.isEmpty, let parsed = URL(string: url) else { return }
                let loaded = await CoverImageCache.shared.image(for: parsed)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}

/// 发现页模块里的一张（132 宽）：封面 + 播放量角标 + 两行歌名
struct PlaylistCoverCard: View {

    let summary: KuwoPlaylist.Summary
    var width: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            RemoteArtwork(url: summary.cover, size: width)
                .overlay(alignment: .bottomLeading) { PlayCountBadge(count: summary.playCount) }
            Text(summary.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.name)，\(summary.songCount) 首，\(CountFormat.short(summary.playCount))播放")
        .accessibilityHint("打开歌单")
    }
}

/// 网易歌单卡（2026-11-27，歌单广场的第二条腿）
///
/// 与 `PlaylistCoverCard` 同一套版式（封面 + 两行名 + 张数），只是数据来自网易
/// （`NeteasePlaylistBrief`），点进去落到通用歌单页 `NeteasePlaylistView`。
struct NeteasePlaylistCard: View {

    let brief: NeteasePlaylistBrief
    var width: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            RemoteArtwork(url: brief.cover ?? "", size: width)
            Text(brief.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(brief.trackCount > 0 ? "\(brief.trackCount) 首" : "网易歌单")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(brief.name)，\(brief.trackCount) 首")
        .accessibilityHint("打开歌单")
    }
}

/// 网易歌单骨架（与 `PlaylistCoverCard` 一样高，避免加载时跳一下）
struct NeteasePlaylistCardSkeleton: View {

    var width: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.paperElevated)
                .frame(width: width, height: width)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Tokens.Palette.paperElevated)
                .frame(width: width * 0.7, height: 12)
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityHidden(true)
    }
}


    let summary: KuwoPlaylist.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            RemoteSquareArtwork(url: summary.cover)
                .overlay(alignment: .bottomLeading) { PlayCountBadge(count: summary.playCount) }
            Text(summary.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(meta)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.name)，\(summary.songCount) 首，\(CountFormat.short(summary.playCount))播放，\(summary.creator)")
        .accessibilityHint("打开歌单")
    }

    private var meta: String {
        summary.creator.isEmpty ? "\(summary.songCount) 首" : "\(summary.songCount) 首 · \(summary.creator)"
    }
}

/// 封面左下的播放量角标：黑 42% 胶囊 + 白字（和最新单曲的深底白字同一套）
struct PlayCountBadge: View {

    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "headphones")
                .font(.system(size: 9, weight: .semibold))
            Text(CountFormat.short(count))
                .font(.caption2.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.42)))
        .padding(Tokens.Spacing.xs)
        .accessibilityHidden(true)
    }
}

// MARK: - 歌手卡

/// 发现页模块里的一个歌手（64 圆头像 + 名字 + 粉丝）
struct ArtistCircleCell: View {

    let artist: KuwoArtist.Artist
    var size: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            avatar(size: size)
            Text(artist.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.top, 6)
            Text(CountFormat.short(artist.fans))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(width: size)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(artist.name)，\(CountFormat.short(artist.fans))粉丝")
        .accessibilityHint("打开歌手页")
    }

    @ViewBuilder
    private func avatar(size: CGFloat) -> some View {
        if artist.picURL.isEmpty {
            ZStack {
                Circle().fill(Tokens.Palette.paperElevated)
                Text(artist.initial)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
        } else {
            RemoteArtwork(url: artist.picURL, size: size, circular: true)
        }
    }
}

/// 大全页三列里的一个（88 圆头像 + 名字 + 粉丝）
struct ArtistGridCell: View {

    let artist: KuwoArtist.Artist
    var avatarSize: CGFloat = 88

    var body: some View {
        VStack(spacing: 0) {
            if artist.picURL.isEmpty {
                ZStack {
                    Circle().fill(Tokens.Palette.paperElevated)
                    Text(artist.initial)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: avatarSize, height: avatarSize)
            } else {
                RemoteArtwork(url: artist.picURL, size: avatarSize, circular: true)
            }
            Text(artist.name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .padding(.top, Tokens.Spacing.xs)
            Text(CountFormat.short(artist.fans))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(artist.name)，\(CountFormat.short(artist.fans))粉丝")
        .accessibilityHint("打开歌手页")
    }
}

// MARK: - 小工具

/// 发现页歌单广场的骨架（三张卡的位置，不出字）
struct SquareSkeletonRow: View {

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 132, height: 132)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 110, height: 12)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .accessibilityHidden(true)
    }
}

/// 发现页歌手大全的骨架（五个圆头像的位置）
struct ArtistSkeletonRow: View {

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
            ForEach(0..<5, id: \.self) { _ in
                VStack(spacing: 0) {
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 64, height: 64)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 40, height: 10)
                        .padding(.top, 8)
                }
                .frame(width: 64)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .accessibilityHidden(true)
    }
}

/// 筛选胶囊（热门/最新、分类）：选中墨色实心，未选中纸卡底
struct FilterPill: View {

    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Tokens.Palette.paper : Color.secondary)
                .padding(.horizontal, Tokens.Spacing.s)
                .frame(minHeight: 32)
                .background(
                    Capsule().fill(isSelected ? Color.primary.opacity(0.9) : Tokens.Palette.paperElevated)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.press)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

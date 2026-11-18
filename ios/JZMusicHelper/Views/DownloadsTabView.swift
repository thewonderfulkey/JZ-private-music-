import SwiftUI

// MARK: - 下载（第四十轮补丁 3：与「我的收藏」保持同一种列表）
//
// 老板真机反馈（第二张截图，下载后的文件夹里 3 个文件挤在一起）：
//   · "歌曲 / 歌词 / 封面" 要分到三个文件夹——见 DownloadLocation 的
//     `Download › Music / Lyrics / Cover`；
//   · "下载界面和我的收藏保持一致吧，别弄什么每一首歌的背景什么的"——
//     原来这里是 `List(.insetGrouped)`，每一行都被分组背景包成一张小卡。
//     现在换成和收藏页**同一套**：ScrollView + LazyVStack + `SongRow`，
//     行本身没有底色，只有分隔留白；已下载的行就是一行歌（封面 / 歌名 / 歌手 / 平台 / 时长 / ❤）。
//
// 正在下载和失败的行仍然需要进度与原因，所以保留"封面 + 标题 + 状态/进度"的同款无底色行，
// 删除 / 重试 / 取消都收进长按菜单（和收藏页的操作方式一致）。
struct DownloadsTabView: View {

    @EnvironmentObject private var downloads: DownloadManager
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    private var ongoing: [DownloadItem] {
        downloads.items.filter { $0.status == .downloading || $0.status == .pending }
    }
    private var finished: [DownloadItem] {
        downloads.items.filter { $0.status == .completed }
    }
    private var failed: [DownloadItem] {
        downloads.items.filter { $0.status == .failed || $0.status == .cancelled }
    }

    private var totalBytes: Int64 {
        downloads.items.reduce(0) { $0 + $1.totalBytes }
    }

    var body: some View {
        Group {
            if downloads.items.isEmpty {
                EmptyStateView(title: "还没有下载任务",
                               systemImage: "arrow.down.circle",
                               description: "在播放页点「下载」，选一个音质")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        header
                        if !ongoing.isEmpty {
                            sectionLabel("正在下载（\(ongoing.count)）")
                            ForEach(ongoing) { item in
                                activeRow(item)
                            }
                        }
                        if !failed.isEmpty {
                            sectionLabel("失败（\(failed.count)）")
                            ForEach(failed) { item in
                                failedRow(item)
                            }
                        }
                        if !finished.isEmpty {
                            sectionLabel("已下载（\(finished.count)）")
                            ForEach(finished) { item in
                                completedRow(item)
                            }
                        }
                        // 迷你条是浮层：末尾让出它的高度
                        MiniPlayerSpacer()
                    }
                    .readableWidth()
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerClearance() }
            }
        }
    }

    // MARK: 头部（版式与「我的收藏」一致）

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .fill(
                            LinearGradient(colors: [Tokens.Palette.vermilion.opacity(0.85),
                                                    Tokens.Palette.vermilion.opacity(0.45)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.white)
                }
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("我的下载")
                        .font(.title3.weight(.bold))
                    Text("\(finished.count) 首 · \(sizeText(totalBytes))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Tokens.Spacing.s) {
                        Button {
                            playAll(shuffle: false)
                        } label: {
                            Label("播放全部", systemImage: "play.fill")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .background(Capsule().fill(Tokens.Palette.paperElevated))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                        }
                        .buttonStyle(.press)
                        .disabled(finished.isEmpty)

                        Button {
                            playAll(shuffle: true)
                        } label: {
                            Label("随机", systemImage: "shuffle")
                                .font(.footnote)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .background(Capsule().fill(Tokens.Palette.paperElevated))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                        }
                        .buttonStyle(.press)
                        .disabled(finished.isEmpty)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }

            // 保存位置：只写一行小字（不再是一张卡），和收藏页那种"只有内容"的观感一致
            HStack(spacing: Tokens.Spacing.xxs) {
                Image(systemName: "folder")
                    .font(.caption2)
                Text(DownloadLocation.currentPathText)
                    .font(.caption2)
                    .lineLimit(1)
                Text("·")
                    .font(.caption2)
                Text(DownloadPathRules.foldersSummary)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.vertical, Tokens.Spacing.m)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Spacing.pageMargin)
            .padding(.top, Tokens.Spacing.m)
            .padding(.bottom, Tokens.Spacing.xxs)
    }

    // MARK: 已下载（就是一行歌，和收藏页同款）

    private func completedRow(_ item: DownloadItem) -> some View {
        Button {
            RowTap.afterHighlight {
                let songs = downloads.completedSongs
                if let index = songs.firstIndex(where: { $0.id == item.song.id }) {
                    player.play(queue: songs, startAt: index)
                } else {
                    player.playSingle(item.song)
                }
                router.showPlayer = true
            }
        } label: {
            SongRow(song: item.song,
                    showsFavorite: true,
                    isFavorite: library.isFavorite(item.song),
                    onFavorite: {
                        Haptics.favorite()
                        withAnimation(Tokens.Motion.favorite) {
                            library.toggleFavorite(item.song)
                        }
                    },
                    subtitle: completedSubtitle(item))
                .padding(.horizontal, Tokens.Spacing.pageMargin)
        }
        .buttonStyle(.rowPress)
        .contextMenu {
            Button(role: .destructive) {
                downloads.remove(itemID: item.id, deleteFile: true)
            } label: {
                Label("删除下载", systemImage: "trash")
            }
        }
    }

    /// 已下载行的副标题：音质 · 体积（"有没有词和图"不再写成一行字，文件夹里一眼能看到）
    private func completedSubtitle(_ item: DownloadItem) -> String {
        "\(item.quality.displayName) · \(item.sizeText)"
    }

    // MARK: 正在下载 / 失败（同款无底色行，多一条进度或原因）

    private func activeRow(_ item: DownloadItem) -> some View {
        plainRow(item: item,
                 subtitle: item.status == .pending
                    ? "\(item.quality.displayName) · 等待中"
                    : "\(item.quality.displayName) · \(item.progressText)",
                 tint: .secondary) {
            ProgressView(value: item.progress)
                .tint(Tokens.Palette.vermilion)
        } menu: {
            Button(role: .destructive) {
                downloads.cancel(itemID: item.id)
            } label: {
                Label("取消下载", systemImage: "xmark.circle")
            }
        }
    }

    private func failedRow(_ item: DownloadItem) -> some View {
        plainRow(item: item,
                 subtitle: "\(item.quality.displayName) · 失败",
                 tint: .orange,
                 note: item.errorMessage) {
            EmptyView()
        } menu: {
            Button {
                downloads.retry(itemID: item.id, useBackground: true)
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                downloads.remove(itemID: item.id, deleteFile: true)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 无底色的一行：封面 + 歌名 + 状态（可选进度条 / 黄字原因）
    private func plainRow<Extra: View, Menu: View>(
        item: DownloadItem,
        subtitle: String,
        tint: Color,
        note: String? = nil,
        @ViewBuilder extra: () -> Extra,
        @ViewBuilder menu: () -> Menu
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            HStack(spacing: Tokens.Spacing.s) {
                SongArtwork(song: item.song)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.song.name)
                        .font(FontRole.songTitle)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(FontRole.songSubtitle)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Spacer(minLength: Tokens.Spacing.xs)
                Text(item.song.singer)
                    .font(FontRole.metadata)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            extra()
            if let note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.vertical, Tokens.Spacing.xs)
        .contentShape(Rectangle())
        .contextMenu(menuItems: menu)
    }

    // MARK: 工具

    private func playAll(shuffle: Bool) {
        let songs = downloads.completedSongs
        guard !songs.isEmpty else { return }
        if shuffle {
            player.replaceQueue(songs, shuffle: true)
        } else {
            player.play(queue: songs, startAt: 0)
        }
        router.showPlayer = true
    }

    private func sizeText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return String(format: "%.1f MB", mb)
    }
}

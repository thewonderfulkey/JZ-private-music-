import SwiftUI

// MARK: - 下载（第四十轮补丁 4）
//
// 老板三条真机反馈（r115）：
//   ① 下载完了进度条还挂着、不消失；
//   ② 下载页里删不掉歌（改成 ScrollView 之后左滑删除没了，长按菜单他又碰不到）；
//   ③ 点播没了 / "直接变成了照片"——本地文件找不到时只剩封面。
//
// 这一版的做法：
//   · 回到 `List`（`.plain`）但**行背景全透明、分隔线全隐藏**——观感仍是收藏页那种"干净的一行行歌"，
//     同时把左滑删除/重试/取消**恢复**（和以前一样的用法）；
//   · 已下载的行只有 `SongRow`（封面/歌名/歌手/平台/时长/❤），**任何情况下都不画进度条**；
//     只有"正在下载"的行才画进度，而且完成度 ≥99.9% 时也不画（那一瞬间已经在收尾）；
//   · 长按菜单保留（删除下载），左滑是第二条路——两种都能删。
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
                list
            }
        }
    }

    private var list: some View {
        List {
            header
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if !ongoing.isEmpty {
                Section {
                    ForEach(ongoing) { item in
                        activeRow(item)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    downloads.cancel(itemID: item.id)
                                } label: {
                                    Label("取消", systemImage: "xmark.circle")
                                }
                            }
                    }
                } header: {
                    sectionHeader("正在下载（\(ongoing.count)）")
                }
            }

            if !failed.isEmpty {
                Section {
                    ForEach(failed) { item in
                        failedRow(item)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    downloads.remove(itemID: item.id, deleteFile: true)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    downloads.retry(itemID: item.id, useBackground: true)
                                } label: {
                                    Label("重试", systemImage: "arrow.clockwise")
                                }
                                .tint(Tokens.Palette.vermilion)
                            }
                    }
                } header: {
                    sectionHeader("失败（\(failed.count)）")
                }
            }

            if !finished.isEmpty {
                Section {
                    ForEach(finished) { item in
                        completedRow(item)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    downloads.remove(itemID: item.id, deleteFile: true)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    sectionHeader("已下载（\(finished.count)）")
                }
            }

            Color.clear
                .frame(height: MiniPlayerMetrics.barHeight)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerClearance() }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.horizontal, Tokens.Spacing.pageMargin)
            .padding(.top, Tokens.Spacing.s)
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

    // MARK: 已下载（一行歌，和收藏页同款；没有进度条）

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
                    subtitle: "\(item.quality.displayName) · \(item.sizeText)")
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

    // MARK: 正在下载（唯一会画进度条的行）

    private func activeRow(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            rowHeadline(item: item,
                        subtitle: item.status == .pending
                            ? "\(item.quality.displayName) · 等待中"
                            : "\(item.quality.displayName) · \(item.progressText)",
                        tint: .secondary)
            // 收尾（≥99.9%）不再画进度条：老板说的"下载完还挂着进度条"就是这一帧
            if item.status == .downloading, item.progress < 0.999 {
                ProgressView(value: item.progress)
                    .tint(Tokens.Palette.vermilion)
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
            }
        }
        .padding(.vertical, Tokens.Spacing.xs)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                downloads.cancel(itemID: item.id)
            } label: {
                Label("取消下载", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: 失败

    private func failedRow(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            rowHeadline(item: item,
                        subtitle: "\(item.quality.displayName) · 失败",
                        tint: .orange)
            if let note = item.errorMessage, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
            }
        }
        .padding(.vertical, Tokens.Spacing.xs)
        .contentShape(Rectangle())
        .contextMenu {
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

    /// 封面 + 歌名 + 状态 + 歌手（无底色）
    private func rowHeadline(item: DownloadItem, subtitle: String, tint: Color) -> some View {
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
        .padding(.horizontal, Tokens.Spacing.pageMargin)
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

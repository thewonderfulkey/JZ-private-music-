import SwiftUI

// MARK: - 下载（设计稿 §3.9）
//
// 分组（正在进行 / 已完成 / 失败），行内进度与状态；左滑删除/重试；
// 保存位置沿用 DownloadManager 的沙盒目录（文件 App 可见）。
struct DownloadsTabView: View {

    @EnvironmentObject private var downloads: DownloadManager
    @Environment(PlayerEngine.self) private var player

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
                List {
                    Section {
                        HStack(spacing: Tokens.Spacing.xs) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text("我的 iPhone › JZ 音乐 › 下载")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(sizeSummary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if !ongoing.isEmpty {
                        Section("正在进行（\(ongoing.count)）") {
                            ForEach(ongoing) { item in
                                DownloadRowView(item: item)
                            }
                        }
                    }
                    if !finished.isEmpty {
                        Section("已完成（\(finished.count)）") {
                            ForEach(finished) { item in
                                DownloadRowView(item: item)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            downloads.remove(itemID: item.id, deleteFile: true)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                    if !failed.isEmpty {
                        Section("失败（\(failed.count)）") {
                            ForEach(failed) { item in
                                DownloadRowView(item: item)
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
                        }
                    }
                    // 迷你条是浮层：用真实的底部 inset 让位（r63：insetGrouped 的 section 间距
                    // 会插在占位行和最后一条记录之间，占位行做不到"严丝合缝"）
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerClearance() }
            }
        }
    }

    private var sizeSummary: String {
        let mb = Double(totalBytes) / 1_000_000
        let count = downloads.items.count
        return String(format: "共 %d 首 · %.1f MB", count, mb)
    }
}

// MARK: - 下载行

private struct DownloadRowView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    let item: DownloadItem

    var body: some View {
        Button {
            // 点行直接用播放器放这首（本地文件与在线取流都走同一条链），并进播放页。
            //
            // 第五轮（老板反馈 ②："播放列表只有一首歌，列表循环也来回只放这一首"）：
            // 从列表里点一首时，**整列已完成下载**就是队列——否则队列里只有这一首，
            // 列表循环退化成单曲循环。
            Haptics.tap()
            let songs = downloads.completedSongs
            if let index = songs.firstIndex(where: { $0.id == item.song.id }) {
                player.play(queue: songs, startAt: index)
            } else {
                player.playSingle(item.song)
            }
            router.showPlayer = true
        } label: {
            rowContent
        }
        // r65 反馈 ⑨：点击反馈要"一按就有"——下载行原来只有 onTapGesture，按下去毫无变化
        .buttonStyle(.rowPress)
        .accessibilityElement(children: .combine)
        .accessibilityHint("轻点播放")
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            HStack(spacing: Tokens.Spacing.s) {
                SongArtwork(song: item.song)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.song.name)
                        .font(FontRole.songTitle)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(FontRole.songSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(item.progressText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            if item.status == .downloading || item.status == .pending {
                ProgressView(value: item.progress)
                    .tint(Tokens.Palette.vermilion)
            }

            if let error = item.errorMessage, item.status == .failed {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            // 落盘实测与标注不一致（例：标着无损，文件其实是 320k）——写清楚，别让用户自己去比体积
            if let note = item.actualNote, item.status == .completed {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            // 第五轮（老板反馈 ⑧）：歌词和封面有没有跟着歌一起下来，这里能一眼看到
            if let note = item.companionsNote, item.status == .completed {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, Tokens.Spacing.xs)
        .padding(.horizontal, Tokens.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        switch item.status {
        case .completed: return "\(item.quality.displayName) · \(item.sizeText)"
        case .failed: return "\(item.quality.displayName) · 失败"
        case .downloading: return "\(item.quality.displayName) · 下载中"
        case .pending: return "\(item.quality.displayName) · 等待中"
        case .cancelled: return "\(item.quality.displayName) · 已取消"
        }
    }
}

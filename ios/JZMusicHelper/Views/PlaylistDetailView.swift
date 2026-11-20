import SwiftUI

// MARK: - 歌单详情（广场点进来的落地页）
//
// 与旧「编辑精选歌单页」最大的差别：这里的每首歌**自带 rid + 封面**，进页面就是歌，
// 不需要逐首四平台搜索（旧页那套"占位行 → 正式行"的替换过程在这里不存在）。
//
// 加载：`KuwoPlaylist.fetchDetail` 一次拿元信息 + 第一页 100 首；失败保留头图与"重试"。
struct PlaylistDetailView: View {

    let summary: KuwoPlaylist.Summary

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    @State private var detail: KuwoPlaylist.Detail?
    @State private var loading = false
    @State private var failed = false
    /// 这份详情是什么时候拿到的（缓存命中就写缓存里的时间）
    @State private var updatedAt: Date?

    private var songs: [Song] {
        detail?.releases.map(\.song) ?? []
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if let detail {
                    ForEach(Array(detail.releases.enumerated()), id: \.element.id) { index, release in
                        Button {
                            play(songs, at: index)
                        } label: {
                            SongRow(song: release.song,
                                    showsFavorite: true,
                                    isFavorite: library.isFavorite(release.song),
                                    onFavorite: {
                                        Haptics.favorite()
                                        withAnimation(Tokens.Motion.favorite) {
                                            library.toggleFavorite(release.song)
                                        }
                                    })
                                .padding(.horizontal, Tokens.Spacing.pageMargin)
                        }
                        .buttonStyle(.rowPress)
                        .accessibilityHint("点一下以整张歌单为队列播放")
                    }
                } else if loading {
                    SkeletonRows(count: 8)
                        .padding(.top, Tokens.Spacing.s)
                } else if failed {
                    EmptyStateView(title: "歌单暂时打不开",
                                   systemImage: "music.note.list",
                                   description: "换个网络或稍后再试",
                                   actionTitle: "重试") {
                        Task { await load() }
                    }
                    .padding(.top, Tokens.Spacing.xl)
                }
                MiniPlayerSpacer()
            }
            .padding(.top, Tokens.Spacing.xs)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle("歌单")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        // 老板 2026-11-20（第二批）：**回前台不自动刷新**，只有下拉才手动更新
        .refreshable { await load(force: true) }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                RemoteArtwork(url: summary.cover, size: 112)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(detail?.summary.name.isEmpty == false ? detail!.summary.name : summary.name)
                        .font(FontRole.sectionTitle)
                        .lineLimit(2)
                    if !creator.isEmpty {
                        Text(creator)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            Button {
                play(songs, at: 0)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.caption)
                    Text("播放全部")
                        .font(FontRole.button)
                }
                .frame(minHeight: 34)
                .padding(.horizontal, Tokens.Spacing.m)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .fill(Tokens.Palette.vermilion)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.press)
            .disabled(songs.isEmpty)
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private var creator: String {
        detail?.summary.creator.isEmpty == false ? detail!.summary.creator : summary.creator
    }

    /// 副行：首数 + 播放量（接口给的两个数都写实话）+ 上次更新时间（缓存命中时就是缓存时间）
    private var meta: String {
        var parts = ["\(detail?.summary.songCount ?? summary.songCount) 首"]
        let plays = detail?.summary.playCount ?? summary.playCount
        if plays > 0 { parts.append("\(CountFormat.short(plays))播放") }
        if !updatedText.isEmpty { parts.append(updatedText) }
        return parts.joined(separator: " · ")
    }

    private var updatedText: String {
        guard let updatedAt else { return "" }
        let minutes = Int(Date().timeIntervalSince(updatedAt) / 60)
        if minutes < 1 { return "刚刚更新" }
        if minutes < 60 { return "\(minutes) 分钟前更新" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前更新" }
        return "\(hours / 24) 天前更新"
    }

    // MARK: 播放

    private func play(_ songs: [Song], at index: Int) {
        guard songs.indices.contains(index) else { return }
        // 第三十九轮：让行高亮先铺满，再起播/弹悬浮栏/开播放页
        RowTap.afterHighlight {
            player.play(queue: songs, startAt: index)
            library.recordPlayed(songs[index])
            router.showPlayer = true
        }
    }

    // MARK: 取数

    /// 读详情：内存 → 磁盘（24h）→ 网络。
    ///
    /// 老板 2026-11-20（第二批）：命中缓存时**一个请求都不发**；回前台不自动刷新；
    /// 只有下拉刷新（`force: true`）才重新拉一次。"上次更新时间"写在页头副行里。
    private func load(force: Bool = false) async {
        guard !loading else { return }
        if !force, let hit = KuwoPlaylist.cachedDetail(pid: summary.id) {
            detail = hit
            updatedAt = KuwoPlaylist.detailSavedAt(pid: summary.id)
            return
        }
        // 页面上已经有内容、缓存也没到期：不重取（Tab 保活反复进出时不该再打一次接口）
        guard force || detail == nil else { return }
        loading = detail == nil
        failed = false
        do {
            let fresh = try await KuwoPlaylist.fetchDetail(pid: summary.id)
            detail = fresh
            KuwoPlaylist.saveDetail(fresh, pid: summary.id)
            updatedAt = Date()
        } catch {
            failed = detail == nil
        }
        loading = false
    }
}

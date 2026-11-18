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

    /// 副行：首数 + 播放量（接口给的两个数都写实话）
    private var meta: String {
        var parts = ["\(detail?.summary.songCount ?? summary.songCount) 首"]
        let plays = detail?.summary.playCount ?? summary.playCount
        if plays > 0 { parts.append("\(CountFormat.short(plays))播放") }
        return parts.joined(separator: " · ")
    }

    // MARK: 播放

    private func play(_ songs: [Song], at index: Int) {
        guard songs.indices.contains(index) else { return }
        Haptics.tap()
        player.play(queue: songs, startAt: index)
        library.recordPlayed(songs[index])
        router.showPlayer = true
    }

    // MARK: 取数

    private func load() async {
        guard detail == nil, !loading else { return }
        loading = true
        failed = false
        do {
            detail = try await KuwoPlaylist.fetchDetail(pid: summary.id)
        } catch {
            failed = detail == nil
        }
        loading = false
    }
}

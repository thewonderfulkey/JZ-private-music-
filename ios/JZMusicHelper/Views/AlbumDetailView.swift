import SwiftUI

// MARK: - 专辑页（2026-11-26）
//
// 入口：发现页「新碟」卡片。曲目走 `AlbumService`（网易 v1 → 酷我 → QQ → 搜索兜底）。
// 设计口径见 docs/superpowers/specs/2026-11-26-discover-v2-design.md：
//   · 能拿到整张曲目就正常展示；只有搜索兜底时才标「曲目可能不全」；
//   · 不造假数据：拿不到就显示失败态 + 重试。

struct AlbumDetailView: View {

    let album: NeteaseAlbumBrief

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    private enum LoadState { case idle, loading, loaded, failed }

    @State private var state: LoadState = .idle
    @State private var tracks: AlbumTracks?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                header
                content
                MiniPlayerSpacer()
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            RemoteArtwork(url: tracks?.cover ?? album.cover ?? "", size: 132)
            VStack(alignment: .leading, spacing: 6) {
                Text(tracks?.name ?? album.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(tracks?.artist ?? album.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let date = tracks?.publishDate, !date.isEmpty {
                    Text(date).font(.caption).foregroundStyle(.tertiary)
                }
                if let tracks {
                    Text("\(tracks.songs.count) 首")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Tokens.Spacing.s)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        case .failed:
            VStack(spacing: Tokens.Spacing.s) {
                Text("这张专辑暂时取不到曲目").font(.subheadline)
                Button("重试") { Task { await load(force: true) } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        case .loaded:
            if let tracks {
                if tracks.partial {
                    Text("曲目可能不全（按专辑名搜出来的）")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Button {
                    play(tracks.songs, at: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .padding(.vertical, 4)

                ForEach(Array(tracks.songs.enumerated()), id: \.element.id) { index, song in
                    Button {
                        play(tracks.songs, at: index)
                    } label: {
                        SongRow(song: song, leadingRank: index + 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 动作

    private func load(force: Bool = false) async {
        if !force, state == .loaded { return }
        state = .loading
        let result = await AlbumService.tracks(albumID: album.id, platform: .netease,
                                               name: album.name, artist: album.artist)
        guard !Task.isCancelled else { return }
        if let result {
            tracks = result
            state = .loaded
        } else {
            state = .failed
        }
    }

    private func play(_ songs: [Song], at index: Int) {
        guard songs.indices.contains(index) else { return }
        RowTap.afterHighlight {
            player.play(queue: songs, startAt: index)
            library.recordPlayed(songs[index])
            router.showPlayer = true
        }
    }
}

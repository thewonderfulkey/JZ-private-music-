import SwiftUI

// MARK: - 歌手页（歌手大全点进来的落地页）
//
// 只做「热门歌曲」：接口有 albumNum / mvNum，但这一轮不铺专辑/MV 页，
// 避免交付一个只有标题的空页。50 首都是带 rid 的，点开即播。
struct ArtistDetailView: View {

    let artist: KuwoArtist.Artist

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    @State private var releases: [KuwoPlaylist.Release] = []
    @State private var loading = false
    @State private var failed = false
    /// 第四十四轮：「定位到正在播放」的状态
    @State private var locator = SongLocator()

    private var songs: [Song] { releases.map(\.song) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    if releases.isEmpty {
                        if loading {
                            SkeletonRows(count: 8)
                                .padding(.top, Tokens.Spacing.s)
                        } else if failed {
                            EmptyStateView(title: "歌手的歌暂时取不到",
                                           systemImage: "person.crop.circle",
                                           description: "换个网络或稍后再试",
                                           actionTitle: "重试") {
                                Task { await load() }
                            }
                            .padding(.top, Tokens.Spacing.xl)
                        }
                    } else {
                        Text("热门歌曲")
                            .font(FontRole.sectionTitle)
                            .padding(.horizontal, Tokens.Spacing.pageMargin)
                            .padding(.top, Tokens.Spacing.s)
                            .padding(.bottom, Tokens.Spacing.xs)
                        ForEach(Array(releases.enumerated()), id: \.element.id) { index, release in
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
                            // 第四十四轮：行 id 要让 ScrollViewReader 找得到
                            .id(release.song.id)
                            .locatedFlash(active: locator.isHighlighted(release.song))
                            .accessibilityHint("点一下以这位歌手的歌为队列播放")
                        }
                    }
                    MiniPlayerSpacer()
                }
                .padding(.top, Tokens.Spacing.xs)
                .readableWidth()
            }
            .scrollIndicators(.hidden)
            .locateToast(locator.toast)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    LocateNowPlayingButton {
                        locator.locate(current: player.currentSong,
                                       songs: songs,
                                       proxy: proxy)
                    }
                }
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .center, spacing: Tokens.Spacing.m) {
                avatar
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(artist.name)
                        .font(FontRole.sectionTitle)
                        .lineLimit(2)
                    if !artist.alias.isEmpty {
                        Text(artist.alias)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text(meta)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            PlayAllButtons(isEnabled: !(songs.isEmpty)) {
                play(songs, at: 0)
            } onShuffle: {
                // 打乱后整份进队列：和「我的收藏 / 下载页」的随机同一个口径
                RowTap.afterHighlight {
                    player.replaceQueue(songs, shuffle: true)
                    router.showPlayer = true
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.bottom, Tokens.Spacing.xs)
    }

    @ViewBuilder
    private var avatar: some View {
        if artist.picURL.isEmpty {
            ZStack {
                Circle().fill(Tokens.Palette.paperElevated)
                Text(artist.initial)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 88, height: 88)
        } else {
            RemoteArtwork(url: artist.picURL, size: 88, circular: true)
        }
    }

    private var meta: String {
        var parts = ["\(CountFormat.short(artist.fans))粉丝"]
        if artist.songCount > 0 { parts.append("\(artist.songCount) 首") }
        if artist.albumCount > 0 { parts.append("\(artist.albumCount) 张专辑") }
        return parts.joined(separator: " · ")
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

    private func load() async {
        guard releases.isEmpty, !loading else { return }
        loading = true
        failed = false
        do {
            releases = try await KuwoArtist.fetchSongs(artistID: artist.id)
        } catch {
            failed = releases.isEmpty
        }
        loading = false
    }
}

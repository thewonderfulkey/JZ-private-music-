import SwiftUI

// MARK: - 资料库（设计稿 §3.10）
//
// 收藏 / 最近播放 两段（合并了旧「历史」Tab 的内容）；右上角 gear 进设置。
struct LibraryView: View {

    enum Segment: String, CaseIterable, Identifiable {
        case favorites = "收藏"
        case recent = "最近播放"
        var id: String { rawValue }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadFlow.self) private var downloadFlow

    @State private var segment: Segment = .favorites

    private var currentSongs: [Song] {
        segment == .favorites ? library.favorites : library.recentSongs
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("分段", selection: $segment) {
                ForEach(Segment.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Tokens.Spacing.pageMargin)
            .padding(.top, Tokens.Spacing.xs)

            if currentSongs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if segment == .favorites {
                            favoriteHeader
                        }
                        ForEach(Array(currentSongs.enumerated()), id: \.element.id) { index, song in
                            Button {
                                player.play(queue: currentSongs, startAt: index)
                                library.recordPlayed(song)
                            } label: {
                                SongRow(song: song,
                                        showsFavorite: true,
                                        isFavorite: library.isFavorite(song),
                                        onFavorite: { library.toggleFavorite(song) },
                                        subtitle: segment == .recent ? recentSubtitle(song) : nil)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, Tokens.Spacing.pageMargin)
                            .contextMenu {
                                Button {
                                    downloadFlow.start(song: song, want: player.quality)
                                } label: {
                                    Label("下载…", systemImage: "arrow.down.circle")
                                }
                                Button {
                                    library.toggleFavorite(song)
                                } label: {
                                    Label(library.isFavorite(song) ? "取消收藏" : "收藏",
                                          systemImage: library.isFavorite(song) ? "heart.slash" : "heart")
                                }
                            }
                            Divider()
                                .padding(.leading, Tokens.Spacing.pageMargin + 48 + Tokens.Spacing.s)
                        }
                    }
                    .padding(.bottom, Tokens.Spacing.xxl)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle("资料库")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
    }

    // MARK: 收藏头部

    private var favoriteHeader: some View {
        HStack(spacing: Tokens.Spacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Tokens.Palette.paperElevated)
                Image(systemName: "heart.fill")
                    .foregroundStyle(Tokens.Palette.vermilion)
            }
            .frame(width: 88, height: 88)

            VStack(alignment: .leading, spacing: 3) {
                Text("我喜欢的音乐")
                    .font(.title3.weight(.semibold))
                Text("\(library.favorites.count) 首 · 收藏即得")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: Tokens.Spacing.xs) {
                    Button("播放全部") {
                        guard let first = library.favorites.first else { return }
                        player.play(queue: library.favorites,
                                    startAt: library.favorites.firstIndex(of: first) ?? 0)
                    }
                    .font(.footnote.weight(.semibold))
                    Button("随机播放") {
                        player.replaceQueue(library.favorites, shuffle: true)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.vertical, Tokens.Spacing.m)
    }

    // MARK: 空态

    @ViewBuilder
    private var emptyState: some View {
        if segment == .favorites {
            EmptyStateView(title: "还没有收藏的歌曲",
                           systemImage: "heart",
                           description: "在歌曲右侧点心形，或在搜索结果里左滑收藏")
        } else {
            EmptyStateView(title: "还没有播放记录",
                           systemImage: "clock",
                           description: "放一首歌，这里会留下痕迹")
        }
    }

    private func recentSubtitle(_ song: Song) -> String {
        song.album.isEmpty ? song.singer : "\(song.singer) · \(song.album)"
    }
}

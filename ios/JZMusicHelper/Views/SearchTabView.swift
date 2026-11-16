import SwiftUI

// MARK: - 搜索（设计稿 §3.4）
//
// 平台状态行（§2.5）在上，结果在下；已确认无源的歌隐藏并可展开；搜过才记历史。
struct SearchTabView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library

    @State private var keyword = ""
    @State private var songs: [Song] = []
    @State private var platformResults: [SearchService.PlatformResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showHidden = false

    private var visibleSongs: [Song] {
        songs.filter { !player.deadSongKeys.contains($0.id) }
    }

    private var hiddenSongs: [Song] {
        songs.filter { player.deadSongKeys.contains($0.id) }
    }

    var body: some View {
        Group {
            if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                idleView
            } else if isSearching && songs.isEmpty {
                SkeletonRows()
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if songs.isEmpty {
                EmptyStateView(title: "没有找到「\(keyword)」",
                               systemImage: "magnifyingglass",
                               description: "换个关键词，或只搜歌名")
            } else {
                resultList
            }
        }
        .navigationTitle("搜索")
        .searchable(text: $keyword,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "歌曲、歌手、专辑")
        .onSubmit(of: .search) { runSearch() }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: 初始态（最近搜索）

    @ViewBuilder
    private var idleView: some View {
        if library.searchHistory.isEmpty {
            EmptyStateView(title: "搜一次，四家一起找",
                           systemImage: "magnifyingglass",
                           description: "QQ 音乐 / 网易云 / 酷我 / 酷狗 同时搜，按可信度合并排序")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    SectionHeader(title: "最近搜索", actionTitle: "清空") {
                        library.clearSearchHistory()
                    }
                    FlowLayout(spacing: Tokens.Spacing.xs) {
                        ForEach(library.searchHistory, id: \.self) { word in
                            Button {
                                keyword = word
                                runSearch()
                            } label: {
                                Text(word)
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill(Tokens.Palette.paperElevated))
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                }
                .padding(.top, Tokens.Spacing.s)
            }
        }
    }

    // MARK: 结果

    private var resultList: some View {
        VStack(spacing: 0) {
            PlatformStatusRow(results: platformResults)
                .padding(.horizontal, Tokens.Spacing.pageMargin)
                .padding(.top, Tokens.Spacing.xs)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                        Button {
                            player.play(queue: visibleSongs, startAt: index)
                            library.recordPlayed(song)
                        } label: {
                            SongRow(song: song,
                                    showsFavorite: true,
                                    isFavorite: library.isFavorite(song),
                                    onFavorite: { library.toggleFavorite(song) })
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Tokens.Spacing.pageMargin)
                        Divider().padding(.leading, Tokens.Spacing.pageMargin + 48 + Tokens.Spacing.s)
                    }

                    if !hiddenSongs.isEmpty {
                        hiddenFooter
                    }

                    if player.isResolving {
                        StatusLine(kind: .progress("正在解析音源…"))
                            .padding(.horizontal, Tokens.Spacing.pageMargin)
                            .padding(.top, Tokens.Spacing.s)
                    }
                }
                .padding(.bottom, Tokens.Spacing.xxl)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var hiddenFooter: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Text("已隐藏 \(hiddenSongs.count) 首无音源")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Button(showHidden ? "收起" : "显示") {
                showHidden.toggle()
            }
            .font(.footnote)
            .foregroundStyle(Tokens.Palette.vermilion)
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.top, Tokens.Spacing.s)
    }

    // MARK: 搜索

    private func runSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        songs = []
        platformResults = []
        isSearching = true
        library.recordSearch(trimmed)

        searchTask = Task { @MainActor in
            let result = await SearchService.shared.searchRanked(keyword: trimmed, limit: 20)
            guard !Task.isCancelled else { return }
            songs = result.songs
            platformResults = result.platforms
            isSearching = false
        }
    }
}

// MARK: - 胶囊流布局（最近搜索）

/// 轻量流式布局：iOS 16 的 `Layout`，不引第三方
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var currentRow = 0
        var height: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentRow > 0, rows[currentRow] + spacing + size.width > maxWidth {
                height += lineHeight + spacing
                rows.append(0)
                currentRow += 1
                lineHeight = 0
            }
            rows[currentRow] += (rows[currentRow] > 0 ? spacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        height += lineHeight
        return CGSize(width: maxWidth == .infinity ? rows.max() ?? 0 : maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

import SwiftUI

// MARK: - 搜索页（老板反馈 ⑥⑦）
//
// ⑥ **不再是 Tab**：从发现页最上方的搜索框 push 进来（`navigationBarBackButtonHidden` 不设，
//    保留系统返回）。进来自动聚焦键盘，少一次点击。
// ⑦ **结果按「归一化歌名 + 歌手」跨平台去重**（口径在 `SearchRanker.dedupe`，与 Android v2.1.10 一致）：
//    同一首《晴天》四家各回一条时只留匹配度最高的一条，不再出现"一屏全是倔强"。
//
// 平台状态行（§2.5）在上，结果在下；已确认无源的歌隐藏并可展开；搜过才记历史。
struct SearchView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadFlow.self) private var downloadFlow
    @Environment(AppRouter.self) private var router

    @State private var keyword = ""
    @State private var songs: [Song] = []
    @State private var platformResults: [SearchService.PlatformResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showHidden = false
    @FocusState private var fieldFocused: Bool

    private var visibleSongs: [Song] {
        songs.filter { !player.deadSongKeys.contains($0.id) }
    }

    private var hiddenSongs: [Song] {
        songs.filter { player.deadSongKeys.contains($0.id) }
    }

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            content
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { fieldFocused = true }
        .onDisappear { searchTask?.cancel() }
        // App Intent（「搜索歌曲」快捷指令）把词塞进 router，这里消费掉
        .onChange(of: router.pendingSearch) { _, _ in consumePendingSearch() }
        .task { consumePendingSearch() }
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索歌曲、歌手、专辑", text: $keyword)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($fieldFocused)
                .onSubmit { runSearch() }
                .accessibilityLabel("搜索关键词")

            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    songs = []
                    platformResults = []
                    isSearching = false
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空")
            }

            Button("搜索") {
                fieldFocused = false
                runSearch()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Tokens.Palette.vermilion)
            .buttonStyle(.plain)
            .disabled(trimmedKeyword.isEmpty)
        }
        .padding(.leading, Tokens.Spacing.s)
        .padding(.trailing, Tokens.Spacing.xs)
        .frame(minHeight: 44)
        .background(Capsule().fill(Tokens.Palette.paperElevated))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.vertical, Tokens.Spacing.xs)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if trimmedKeyword.isEmpty && songs.isEmpty {
            idleView
        } else if isSearching && songs.isEmpty {
            SkeletonRows()
                .frame(maxHeight: .infinity, alignment: .top)
        } else if songs.isEmpty {
            EmptyStateView(title: "没有找到「\(trimmedKeyword)」",
                           systemImage: "magnifyingglass",
                           description: "换个关键词，或只搜歌名")
        } else {
            resultList
        }
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
                .readableWidth()
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: 结果

    private var resultList: some View {
        VStack(spacing: 0) {
            PlatformStatusRow(results: platformResults)
                .padding(.horizontal, Tokens.Spacing.pageMargin)
                .padding(.top, Tokens.Spacing.xxs)
                .padding(.bottom, Tokens.Spacing.xxs)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                        Button {
                            player.play(queue: visibleSongs, startAt: index)
                            library.recordPlayed(song)
                            router.showPlayer = true
                        } label: {
                            SongRow(song: song,
                                    showsFavorite: true,
                                    isFavorite: library.isFavorite(song),
                                    onFavorite: { library.toggleFavorite(song) })
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
                .readableWidth()
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

    /// 消费 App Intent 留下的搜索词（取走即清空，避免重复触发）
    private func consumePendingSearch() {
        guard let pending = router.pendingSearch else { return }
        router.pendingSearch = nil
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keyword = trimmed
        runSearch()
    }

    private func runSearch() {
        let trimmed = trimmedKeyword
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

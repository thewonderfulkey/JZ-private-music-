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
    /// 第四十四轮：「定位到正在播放」的状态
    @State private var locator = SongLocator()

    // r65（老板反馈 ⑦）：搜索只回第一页，底部要能「查看更多结果」。
    // 翻页时按 `SearchRanker.dedupeKey` 跟已经显示的做去重，翻到"这一页没有新的"就收口。
    @State private var page = 1
    @State private var isLoadingMore = false
    @State private var canLoadMore = true
    @State private var seenKeys: Set<String> = []
    // 2026-11-27（智能搜索 v1：输入联想）
    @State private var suggestions: [Song] = []
    @State private var suggestTask: Task<Void, Never>?
    /// 当前结果对应的关键词（联想在"输入 != 已提交"时才盖住结果）
    @State private var submittedKeyword = ""
    private let pageSize = 20
    /// 一屏结果最多累到这个数就不再往下翻（2026-11-21：真机上翻到近千行后崩，
    /// 列表太长时 SwiftUI 的布局/封面加载会把主线程压垮）
    private let maxRows = 400

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
            if showsSuggestions {
                suggestionList
            } else {
                content
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // r66（老板反馈 ②）：键盘**等 push 动画走完再弹**。
        // 原来 `onAppear` 里立刻 fieldFocused = true，键盘要跟导航转场抢同一帧的主线程，
        // 表现就是"点搜索卡一下"。晚 0.3 秒弹键盘，观感是"页面先到、键盘再上"，反而顺。
        .task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { fieldFocused = true }
        }
        .onDisappear {
            searchTask?.cancel()
            suggestTask?.cancel()
        }
        // App Intent（「搜索歌曲」快捷指令）把词塞进 router，这里消费掉
        .onChange(of: router.pendingSearch) { _, _ in consumePendingSearch() }
        .task { consumePendingSearch() }
        // 2026-11-27（智能搜索第一版）：边打边联想——防抖 280ms，停下才发请求
        .onChange(of: keyword) { _, _ in scheduleSuggest() }
    }

    // MARK: 搜索联想（智能搜索 v1）

    /// 联想被点/被提交之前，一直盖在结果上面
    private var showsSuggestions: Bool {
        fieldFocused
            && SearchSuggestRules.shouldSuggest(keyword)
            && !suggestions.isEmpty
            && trimmedKeyword != submittedKeyword
    }

    /// 防抖：每次输入都取消上一轮，停了 `debounceMs` 才真发请求
    private func scheduleSuggest() {
        suggestTask?.cancel()
        let query = keyword
        guard SearchSuggestRules.shouldSuggest(query) else {
            suggestions = []
            return
        }
        suggestTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(SearchSuggestRules.debounceMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            let result = await SearchService.shared.suggest(keyword: query)
            guard !Task.isCancelled else { return }
            // 结果回来时用户可能已经改了输入：只接受"当前输入"的结果
            guard query == keyword else { return }
            suggestions = result
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { song in
                Button {
                    // 点一条 = 拿它当关键词直接搜（不是直接播放：用户可能还想看别的平台版本）
                    keyword = song.name
                    submittedKeyword = ""
                    fieldFocused = false
                    runSearch()
                } label: {
                    HStack(spacing: Tokens.Spacing.s) {
                        Image(systemName: "magnifyingglass")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            let sub = SearchSuggestRules.subtitle(for: song)
                            if !sub.isEmpty {
                                Text(sub)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.rowPress)
                .accessibilityLabel("搜索 \(song.name)")
                Divider().padding(.leading, Tokens.Spacing.pageMargin)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
                .buttonStyle(.press)
                .accessibilityLabel("清空")
            }

            Button("搜索") {
                fieldFocused = false
                runSearch()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Tokens.Palette.vermilion)
            .buttonStyle(.press)
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
                                // r63（老板反馈 ⑥）：点历史记录后键盘要自己收回去，
                                // 不然结果被键盘顶掉一半，还得手动点一下才看得到
                                fieldFocused = false
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
                            .buttonStyle(.press)
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                    // 最近搜索页同样会被迷你条压住（第五轮反馈 ⑨）：末尾让出高度
                    MiniPlayerSpacer()
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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                            Button {
                                // 第三十九轮：让行高亮先铺满，再起播/弹悬浮栏/开播放页
                                RowTap.afterHighlight {
                                    player.play(queue: visibleSongs, startAt: index)
                                    library.recordPlayed(song)
                                    router.showPlayer = true
                                }
                            } label: {
                                SongRow(song: song,
                                        showsFavorite: true,
                                        isFavorite: library.isFavorite(song),
                                        onFavorite: { library.toggleFavorite(song) })
                                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                            }
                            .buttonStyle(.rowPress)
                            // 第四十四轮：行 id 要让 ScrollViewReader 找得到
                            .id(song.id)
                            .locatedFlash(active: locator.isHighlighted(song))
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
                        }

                        if !hiddenSongs.isEmpty {
                            hiddenFooter
                        }

                        if player.isResolving {
                            StatusLine(kind: .progress("正在解析音源…"))
                                .padding(.horizontal, Tokens.Spacing.pageMargin)
                                .padding(.top, Tokens.Spacing.s)
                        }

                        moreResultsFooter

                        MiniPlayerSpacer()
                    }
                    .readableWidth()
                }
                .scrollIndicators(.hidden)
                .locateToast(locator.toast)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        LocateNowPlayingButton {
                            locator.locate(current: player.currentSong,
                                           songs: visibleSongs,
                                           proxy: proxy)
                        }
                    }
                }
            }
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
            .buttonStyle(.press)
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
        suggestTask?.cancel()
        suggestions = []
        submittedKeyword = trimmed
        songs = []
        platformResults = []
        seenKeys = []
        page = 1
        canLoadMore = true
        isLoadingMore = false
        isSearching = true
        library.recordSearch(trimmed)

        searchTask = Task { @MainActor in
            let result = await SearchService.shared.searchRanked(keyword: trimmed,
                                                                limit: pageSize, page: 1)
            guard !Task.isCancelled else { return }
            songs = result.songs
            platformResults = result.platforms
            seenKeys = Set(result.songs.map(SearchRanker.dedupeKey))
            canLoadMore = !result.songs.isEmpty
            isSearching = false
        }
    }

    // MARK: 查看更多结果（老板 r65 反馈 ⑦）

    private var moreResultsFooter: some View {
        VStack(spacing: Tokens.Spacing.xs) {
            if canLoadMore {
                Button {
                    loadMore()
                } label: {
                    HStack(spacing: Tokens.Spacing.xs) {
                        if isLoadingMore {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.footnote.weight(.semibold))
                        }
                        Text(isLoadingMore ? "正在加载…" : "查看更多结果")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(Tokens.Palette.vermilion)
                    .padding(.horizontal, Tokens.Spacing.l)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(Tokens.Palette.paperElevated))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                }
                .buttonStyle(.press)
                .disabled(isLoadingMore)
                .accessibilityHint("往下再取一页搜索结果")
            } else {
                Text("已经到底了 · 共 \(songs.count) 首")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, Tokens.Spacing.m)
        .padding(.bottom, Tokens.Spacing.xs)
    }

    /// 再取一页：四个平台同时翻页，合并排序后只留下没显示过的那些
    private func loadMore() {
        guard !isLoadingMore, canLoadMore else { return }
        guard songs.count < maxRows else {
            canLoadMore = false
            return
        }
        let trimmed = trimmedKeyword
        guard !trimmed.isEmpty else { return }
        isLoadingMore = true
        let next = page + 1
        let already = seenKeys

        Task { @MainActor in
            let result = await SearchService.shared.searchRanked(keyword: trimmed,
                                                                limit: pageSize, page: next)
            // 期间又搜了别的词 → 这一页作废
            guard trimmedKeyword == trimmed, keyword.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else {
                return
            }
            page = next
            isLoadingMore = false
            let fresh = result.songs.filter { !already.contains(SearchRanker.dedupeKey($0)) }
            guard !fresh.isEmpty else {
                canLoadMore = false
                return
            }
            seenKeys.formUnion(fresh.map(SearchRanker.dedupeKey))
            songs.append(contentsOf: fresh)
            platformResults = merged(platformResults, with: result.platforms)
        }
    }

    /// 平台状态行累加各平台已取到的条数
    private func merged(_ old: [SearchService.PlatformResult],
                        with new: [SearchService.PlatformResult]) -> [SearchService.PlatformResult] {
        new.map { item in
            guard let previous = old.first(where: { $0.platform == item.platform }) else { return item }
            return SearchService.PlatformResult(platform: item.platform,
                                                songs: previous.songs + item.songs,
                                                error: item.error ?? previous.error,
                                                elapsedMs: previous.elapsedMs + item.elapsedMs)
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

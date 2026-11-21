import SwiftUI

// MARK: - 我的收藏（老板反馈 ⑤：资料库那页设计不行，直接换成"我的收藏"）
//
// 只做一件事：把收藏的歌排成一张干净的列表。
//   · 顶部一张大卡写明「我喜欢的音乐 · N 首」，播放全部 / 随机播放两个动作就在卡上；
//   · 下面是收藏列表，行内可直接取消收藏（爱心）；
//   · 设置收进右上角齿轮（原来在"资料库"里）。
// 最近播放没有消失：它作为一屏「最近播放」留在发现页（那里本来就有一栏）。
struct FavoritesView: View {

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadFlow.self) private var downloadFlow
    @Environment(AppRouter.self) private var router

    /// 第四十四轮：「定位到正在播放」的状态
    @State private var locator = SongLocator()

    /// 页面快照（2026-11-21 老板："加载一次、退出后台不要重新加载"）：
    /// 数据层本来就是 `LibraryStore` 单例 + JSON 落盘（进 tab 不重读盘），封面也有 NSCache+磁盘两级缓存；
    /// 真正会"回到顶部"的是滚动位置，所以这里把停留的那一行记进 `@SceneStorage`，重进页面自动回到原处。
    @State private var scrollTarget: String?
    @SceneStorage("favorites.scroll.anchor") private var savedAnchor: String = ""
    /// 「整理重复」入口（灰区才出现，不主动弹）
    @State private var showDuplicates = false
    /// 收藏页本地搜索（在去重后的列表上过滤）
    @State private var query = ""

    /// 搜索后的收藏（空查询 = 全部；有查询按命中强度排序，同分保持原顺序）
    private var filteredFavorites: [Song] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return library.favorites }
        return library.favorites.enumerated()
            .compactMap { index, song -> (Int, Song, Int)? in
                let rank = LibrarySearch.rank(song: song, fileName: nil, query: q)
                return rank > 0 ? (index, song, rank) : nil
            }
            .sorted { a, b in a.2 == b.2 ? a.0 < b.0 : a.2 > b.2 }
            .map(\.1)
    }

    var body: some View {
        Group {
            if filteredFavorites.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            header
                            ForEach(Array(filteredFavorites.enumerated()), id: \.element.id) { index, song in
                                Button {
                                    // 第三十九轮：让行高亮先铺满，再起播/弹悬浮栏/开播放页
                                    RowTap.afterHighlight {
                                        player.play(queue: filteredFavorites, startAt: index)
                                        library.recordPlayed(song)
                                        router.showPlayer = true
                                    }
                                } label: {
                                    SongRow(song: song,
                                            showsFavorite: true,
                                            isFavorite: true,
                                            onFavorite: {
                                                Haptics.favorite()
                                                withAnimation(Tokens.Motion.favorite) {
                                                    library.toggleFavorite(song)
                                                }
                                            })
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
                                    Button(role: .destructive) {
                                        library.toggleFavorite(song)
                                    } label: {
                                        Label("取消收藏", systemImage: "heart.slash")
                                    }
                                }
                            }
                            // 迷你条是浮层：末尾让出它的高度，最后一条收藏不会被压住
                            MiniPlayerSpacer()
                        }
                        .readableWidth()
                        .scrollTargetLayout()
                    }
                    .scrollPosition(id: $scrollTarget)
                    .onAppear {
                        // 回到上次停留的那一行（只在从未定位过时恢复，别和"定位到正在播放"抢）
                        guard scrollTarget == nil, !savedAnchor.isEmpty else { return }
                        scrollTarget = savedAnchor
                    }
                    .onChange(of: scrollTarget) { _, new in
                        if let new, !new.isEmpty { savedAnchor = new }
                    }
                    .scrollIndicators(.hidden)
                    .locateToast(locator.toast)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            LocateNowPlayingButton {
                                locator.locate(current: player.currentSong,
                                               songs: library.favorites,
                                               proxy: proxy)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("我的收藏")
        .searchable(text: $query, prompt: "搜歌名 / 歌手 / 专辑")
        .onAppear { library.refreshDuplicateGroups() }
        .sheet(isPresented: $showDuplicates) { DuplicateReviewSheet() }
        // 第四轮（老板反馈 ③）：设置已经单独占一个 Tab，这里的齿轮撤掉，只留一个入口。
    }

    // MARK: 头部

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
                    Image(systemName: "heart.fill")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.white)
                }
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("我喜欢的音乐")
                        .font(.title3.weight(.bold))
                    Text("\(library.favorites.count) 首 · 收藏即得")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Tokens.Spacing.s) {
                        Button {
                            guard !library.favorites.isEmpty else { return }
                            player.play(queue: library.favorites, startAt: 0)
                            library.recordPlayed(library.favorites[0])
                            router.showPlayer = true
                        } label: {
                            Label("播放全部", systemImage: "play.fill")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .background(Capsule().fill(Tokens.Palette.paperElevated))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                        }
                        .buttonStyle(.press)

                        Button {
                            guard !library.favorites.isEmpty else { return }
                            player.replaceQueue(library.favorites, shuffle: true)
                            router.showPlayer = true
                        } label: {
                            Label("随机", systemImage: "shuffle")
                                .font(.footnote)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .background(Capsule().fill(Tokens.Palette.paperElevated))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                        }
                        .buttonStyle(.press)
                    }
                    .padding(.top, 2)

                    // 灰区只有"机械判不了、但确实可能是同一首"的才会进来（同期时长差 4–12s、
                    // 歌名相似度 0.6–0.75）。不主动弹，只在这里给一个可点的入口。
                    if !library.duplicateGroups.isEmpty {
                        Button {
                            showDuplicates = true
                        } label: {
                            Label("疑似重复 \(library.duplicateGroups.reduce(0) { $0 + $1.count }) 首",
                                  systemImage: "rectangle.stack.badge.minus")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .frame(minHeight: 28)
                                .background(Capsule().fill(Tokens.Palette.vermilion.opacity(0.10)))
                                .overlay(Capsule().strokeBorder(
                                    Tokens.Palette.vermilion.opacity(0.25), lineWidth: 0.5))
                        }
                        .buttonStyle(.press)
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.vertical, Tokens.Spacing.m)
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "heart")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Tokens.Palette.vermilion.opacity(0.7))
            Text("还没有收藏的歌")
                .font(.headline)
            Text(query.isEmpty
                 ? "在播放页点 ❤，或在搜索结果里左滑收藏"
                 : "这个收藏里没有匹配「\(query)」的歌")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Tokens.Spacing.l)
    }
}

// MARK: - 整理重复（灰区复核）
//
// 老板 2026-11-21 拍板：
//   · 默认全自动（一级同曲 + 二级同文件都在收藏/后台静默做完），**不在收藏时询问**；
//   · 只有机械判不了的灰区才在这里出现，入口是收藏页顶部那个不主动弹的「整理重复 · N 组」；
//   · 「合并」保留**音质更好**的那条（码率 → 体积），封面换专辑原图，另一条记别名；
//   · 「不是同一首」写否定缓存，以后同一对不再出现；
//   · 合并可撤销（把两条原样放回）。
private struct DuplicateReviewSheet: View {

    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if library.duplicateGroups.isEmpty {
                    ContentUnavailableView("没有疑似重复", systemImage: "checkmark.circle",
                                           description: Text("收藏里暂时没有需要人工判断的重复"))
                } else {
                    List {
                        ForEach(Array(library.duplicateGroups.enumerated()), id: \.offset) { _, group in
                            Section {
                                ForEach(group) { song in
                                    HStack(spacing: Tokens.Spacing.s) {
                                        SongArtwork(song: song, size: 44)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(song.name)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                            Text(song.singer)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            Text(factsText(song))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Text(song.platform.displayName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                HStack(spacing: Tokens.Spacing.s) {
                                    Button {
                                        library.mergeGroup(group)
                                    } label: {
                                        Label("合并（留音质好的）", systemImage: "arrow.triangle.merge")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    Button("不是同一首") {
                                        library.dismissAsDifferent(group[0], group[1])
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .font(.footnote)
                            }
                        }
                    }
                }
            }
            .navigationTitle("整理重复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if library.canUndoMerge {
                    Button {
                        library.undoLastMerge()
                    } label: {
                        Label("撤销上一次合并", systemImage: "arrow.uturn.backward")
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                    .padding(.bottom, Tokens.Spacing.s)
                }
            }
        }
    }

    /// 每首的"证据"：实测码率 + 体积 + 时长（没测到就直说，不编）
    private func factsText(_ song: Song) -> String {
        var parts: [String] = []
        if let fp = library.fingerprints[song.id] {
            parts.append("\(fp.kbps) kbps")
            parts.append(String(format: "%.1f MB", Double(fp.bytes) / 1_048_576))
        } else {
            parts.append("码率未测得")
        }
        parts.append(song.durationText)
        return parts.joined(separator: " · ")
    }
}

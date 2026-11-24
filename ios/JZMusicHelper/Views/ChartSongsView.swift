import SwiftUI

// MARK: - 榜单歌曲页（发现页「热门音乐 → 查看全部」的落地页）
//
// 与歌单广场 / 歌手页同一套骨架：**这里的每首歌都已经带着平台 id（酷我 rid）**，
// 点开不需要再四平台搜索，整榜可以直接进队列——所以顶部给「播放全部」，点行就是整榜为队列起播。
//
// 数据来自 `KuwoChart`：酷我官方榜、匿名接口、每日更新。榜单曲没有封面字段，
// 行内封面走 `CoverImageCache` → `CoverResolver` 的酷我 rid 分支（同平台按 rid 取图）。
struct ChartSongsView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    /// 默认就是编辑精选里挂的「酷我热歌榜」；以后要挂别的榜，只换这一个参数。
    var chart: KuwoChart.Chart = .hot

    @State private var page: KuwoChart.Page?
    /// 当前页面数据是哪一天的：App 挂着跨过 0 点再进榜单页时，必须按新的一天重取
    @State private var pageDay: Int = -1
    @State private var loading = false
    @State private var failed = false
    /// 第四十四轮：「定位到正在播放」的状态
    @State private var locator = SongLocator()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let page {
                        header(page)
                        ForEach(Array(page.songs.enumerated()), id: \.element.id) { index, song in
                            // 第二十轮（老板："榜单页太丑、太细了"）：不再用 `DiscoverSongRow`（那是发现页
                            // 的紧凑行，副行只有歌手、没有专辑/平台/时长），改回**全 App 统一行样式** `SongRow`：
                            // 52pt 封面 + 歌名 + 歌手·专辑 + 平台胶囊 + 时长 + 收藏，行高 72。
                            // 名次用 `leadingRank` 放在行首（前三名朱砂），与其它榜单口径一致。
                            Button {
                                play(page.songs, at: index)
                            } label: {
                                SongRow(song: song,
                                        showsFavorite: true,
                                        isFavorite: library.isFavorite(song),
                                        onFavorite: {
                                            Haptics.favorite()
                                            withAnimation(Tokens.Motion.favorite) {
                                                library.toggleFavorite(song)
                                            }
                                        },
                                        leadingRank: index + 1)
                                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                            }
                            .buttonStyle(.rowPress)
                            // 第四十四轮：行 id 要让 ScrollViewReader 找得到
                            .id(song.id)
                            .locatedFlash(active: locator.isHighlighted(song))
                            .accessibilityLabel("第 \(index + 1) 名，\(song.name)，\(song.singer)")
                            .accessibilityHint("点一下以整榜为队列播放")
                        }
                        // 迷你条是浮层：末尾让出高度（第五轮反馈 ⑨）
                        MiniPlayerSpacer()
                    } else if loading {
                        SkeletonRows(count: 10)
                            .padding(.top, Tokens.Spacing.xs)
                    } else if failed {
                        EmptyStateView(title: "榜单暂时取不到",
                                       systemImage: "chart.bar",
                                       description: "换个网络或稍后再试",
                                       actionTitle: "重试") {
                            Task { await load(force: true) }
                        }
                        .padding(.top, Tokens.Spacing.xl)
                    }
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
                                       songs: page?.songs ?? [],
                                       proxy: proxy)
                    }
                }
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle(chart.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            Haptics.prepare()
            await load(force: false)
        }
    }

    // MARK: 头部

    private func header(_ page: KuwoChart.Page) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            HStack(alignment: .center, spacing: Tokens.Spacing.s) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(page.name.isEmpty ? chart.name : page.name)
                        .font(FontRole.sectionTitle)
                        .lineLimit(1)
                    Text(meta(page))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                PlayAllButtons(isEnabled: !(page.songs.isEmpty)) {
                    play(page.songs, at: 0)
                } onShuffle: {
                    // 抽一首直接起播，不弹播放页（停在榜单页看底部悬浮条）
                    player.replaceQueue(page.songs, shuffle: true)
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.bottom, Tokens.Spacing.s)
    }

    /// 副行写清楚**来源与更新时间**：这是酷我单平台的官方榜，不冒充四平台合并的结果。
    private func meta(_ page: KuwoChart.Page) -> String {
        var parts: [String] = ["\(page.count) 首"]
        if !page.publishedDate.isEmpty {
            parts.append("更新 \(page.publishedDate)")
        }
        parts.append("酷我官方榜")
        return parts.joined(separator: " · ")
    }

    // MARK: 播放

    /// 整榜为队列起播。这些歌已经带 rid，起播时不用再解析，所以点哪首都是立刻有声音；
    /// 取流仍由引擎按平台适配器走（酷我按歌名+歌手取流，失败再跨平台补位）。
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

    private func load(force: Bool) async {
        if loading { return }
        if !force, page != nil, pageDay == KuwoChart.today { return }

        // ① 先铺缓存（不区分我们这边的日期）——用户进页面立刻有内容
        if !force, let cached = KuwoChart.cachedPageAnyDay(chart) {
            page = cached
            failed = false
            // ② 再按**服务端 pub 日期**核对：只有酷我换榜了才重取整页（rn=1 探测约 1.5 KB）
            if let latest = await KuwoChart.latestPublishedDate(chart),
               latest != cached.publishedDate {
                await reloadFull()
            } else {
                pageDay = KuwoChart.today
            }
            return
        }

        await reloadFull()
    }

    /// 真正拉整页（100 首）
    private func reloadFull() async {
        loading = true
        failed = false
        do {
            page = try await KuwoChart.fetchPage(chart)
            pageDay = KuwoChart.today
        } catch {
            // 已经有内容时不清空：刷新失败不把用户正在看的榜单抽走
            failed = page == nil
        }
        loading = false
    }
}

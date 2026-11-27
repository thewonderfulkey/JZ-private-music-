import SwiftUI
import UIKit

// MARK: - 我的歌单（导入后的模块 / 整页 / 详情 / 设置里的导入页）
//
// 老板 2026-11-19 口径（原话拆开）：
//   ① 入口只在**设置页**（"导入歌单"）；
//   ② 没导入过就保持现有界面原样——最近播放后直接就是最新单曲，**中间不加任何东西、也不加标题**；
//   ③ 导入以后才在「最近播放」和「最新单曲」之间出现「我的歌单」，模块 UI 跟「最新单曲」同款
//      （横滑宽卡：左半封面、右半同图糊底 + 白字），右上角一个「查看全部」；
//   ④ 点某一个歌单进详情页，版式同「热门音乐 → 查看全部」（页头 + 播放全部 + 带名次的统一行）；
//   ⑤ 导入是**一次性快照**：歌曲全部落盘，之后不再请求（"加载一次后写死，往后不再加载"）。
//
// 为什么卡片是"打开"而不是"播放"：一张卡代表一个歌单（几十上百首），点一下应当是"看看里面有什么"，
// 播放动作放在详情页的「播放全部」和行点击上——和歌单广场 → 歌单详情同一套交互。

// MARK: - 发现页模块里的横滑宽卡（版式对齐 `NewReleaseCard`）

struct MyPlaylistCard: View {

    let playlist: ImportedPlaylist

    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 100
    /// 卡片右半要用**同一张图**糊成底，`RemoteArtwork` 拿不到原图，所以这里自己拉一份
    @State private var cover: UIImage?

    private var cardWidth: CGFloat { max(cardHeight * 3, 1) }
    private var panelWidth: CGFloat { max(cardWidth - cardHeight, 1) }

    var body: some View {
        HStack(spacing: 0) {
            artwork
            panel
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .task(id: playlist.id) {
            let loaded = await loadCover()
            guard !Task.isCancelled else { return }
            cover = loaded
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playlist.name)，\(playlist.songs.count) 首，\(playlist.platform.displayName)")
        .accessibilityHint("打开歌单")
    }

    private var artwork: some View {
        Group {
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    // 卡片整块是深底白字（照片卡），缺图占位也用深底，别跟着浅色主题变白
                    Color.black.opacity(0.55)
                    Image(systemName: "music.note.list")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .frame(width: cardHeight, height: cardHeight)
        .clipped()
    }

    private var panel: some View {
        ZStack(alignment: .bottomTrailing) {
            background
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.platform.shortName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.white.opacity(0.22))
                    )
                Spacer(minLength: 2)
                Text(playlist.name)
                    .font(FontRole.songTitle.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(creatorLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Text("\(playlist.songs.count) 首 · \(playlist.platform.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.leading, Tokens.Spacing.s)
            // 右下角给"打开"箭头让位，长歌名宁可省略也不压到箭头上
            .padding(.trailing, Tokens.Spacing.xxl)
            .padding(.vertical, Tokens.Spacing.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(Tokens.Spacing.s)
        }
        .frame(width: panelWidth, height: cardHeight)
        .clipped()
    }

    /// 右半底色：同一张封面糊开 + 压暗；没有封面就用深色兜底（仍然是深底白字）
    ///
    /// `scaleEffect(1.2)` 与 `NewReleaseCard` 同一做法：不放大时 blur 的软边会在卡片接缝处
    /// 透出一条纸色，看起来像卡片裂了。
    @ViewBuilder
    private var background: some View {
        if let cover {
            Image(uiImage: cover)
                .resizable()
                .scaledToFill()
                .frame(width: panelWidth, height: cardHeight)
                .scaleEffect(1.2)
                .blur(radius: 16)
                .overlay(Color.black.opacity(0.42))
        } else {
            Color.black.opacity(0.55)
        }
    }

    private var creatorLine: String {
        playlist.creator.isEmpty ? "\(playlist.songs.count) 首" : playlist.creator
    }

    /// 歌单封面优先；没有封面就退第一首歌的封面（总比一块黑好）
    private func loadCover() async -> UIImage? {
        if !playlist.cover.isEmpty, let url = URL(string: playlist.cover),
           let image = await CoverImageCache.shared.image(for: url) {
            return image
        }
        if let first = playlist.songs.first {
            return await CoverImageCache.shared.image(for: first)
        }
        return nil
    }
}

// MARK: - 「我的歌单 → 查看全部」整页

struct MyPlaylistsView: View {

    @Environment(MyPlaylistStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.playlists.isEmpty {
                    EmptyStateView(title: "还没有导入歌单",
                                   systemImage: "music.note.list",
                                   description: "在「设置 → 导入歌单」里粘贴分享链接")
                        .padding(.top, Tokens.Spacing.xl)
                } else {
                    ForEach(store.playlists) { playlist in
                        NavigationLink {
                            MyPlaylistDetailView(playlistID: playlist.id)
                        } label: {
                            MyPlaylistRow(playlist: playlist)
                        }
                        .buttonStyle(.rowPress)
                        .contextMenu {
                            Button("删除歌单", role: .destructive) {
                                store.remove(playlist.id)
                            }
                        }
                        .accessibilityHint("打开歌单")
                    }
                    MiniPlayerSpacer()
                }
            }
            .padding(.top, Tokens.Spacing.xs)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle("我的歌单")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 整页里的一行：封面 + 歌单名 + 「N 首 · 平台 · 创建者」
struct MyPlaylistRow: View {

    let playlist: ImportedPlaylist

    private var coverURL: String {
        if !playlist.cover.isEmpty { return playlist.cover }
        return playlist.songs.first?.picURL ?? ""
    }

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            RemoteArtwork(url: coverURL, size: Tokens.Size.songRowArtwork)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(FontRole.songTitle)
                    .lineLimit(1)
                Text(playlist.metaLine)
                    .font(FontRole.songSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Spacing.xs)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: Tokens.Size.songRowHeight)
        .padding(.vertical, Tokens.Spacing.xxs)
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .contentShape(Rectangle())
    }
}

// MARK: - 歌单详情（版式同「热门音乐 → 查看全部」）
//
// 与 `ChartSongsView` 同一套骨架：页头（歌单名 + 元信息 + 播放全部）+ 统一 `SongRow`（带名次）。
// 唯一差别是**数据来自本地快照**，进页面零请求、零 loading——老板要的"加载一次后写死"就落在这里。

struct MyPlaylistDetailView: View {

    let playlistID: String

    @Environment(MyPlaylistStore.self) private var store
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    /// 第四十四轮：「定位到正在播放」的状态
    @State private var locator = SongLocator()
    /// 2026-11-27（老板）：本页搜索——只筛这份歌单，不打网络
    @State private var query = ""

    private var playlist: ImportedPlaylist? { store.playlist(id: playlistID) }

    /// 搜索过滤后的行（队列仍是整份歌单）
    private var visibleSongs: [Song] {
        SongListFilter.filter(playlist?.songs ?? [], query: query)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0,
                           pinnedViews: [.sectionHeaders]) {
                    // 2026-11-27（老板）：头部三件套——播放全部/随机（原有）+ 搜索（新加），整块吸顶
                    Section {
                    if let playlist {
                        ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                            Button {
                                play(playlist.songs, at: playlist.songs.firstIndex(of: song) ?? index)
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
                            .accessibilityHint("点一下以整张歌单为队列播放")
                        }
                        MiniPlayerSpacer()
                    } else {
                        // 详情页开着的时候在设置里把这个歌单删了：给一句实话，不留空白页
                        EmptyStateView(title: "这个歌单已经不在了",
                                       systemImage: "music.note.list",
                                       description: "回设置里重新导入一次")
                            .padding(.top, Tokens.Spacing.xl)
                    }
                    } header: {
                        if let playlist {
                            SongListHeader(songCount: playlist.songs.count,
                                           query: $query,
                                           showsPlayAll: false,
                                           shownCount: visibleSongs.count) {
                                header(playlist)
                            }
                        }
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
                                       songs: playlist?.songs ?? [],
                                       proxy: proxy)
                    }
                }
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle(playlist?.name ?? "歌单")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 头部

    private func header(_ playlist: ImportedPlaylist) -> some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text(playlist.name)
                    .font(FontRole.sectionTitle)
                    .lineLimit(1)
                Text(meta(playlist))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)   // 副行可以省略，按钮文案不能（老板 2026-11-24）
            }
            Spacer(minLength: 0)
            PlayAllButtons(isEnabled: !(playlist.songs.isEmpty)) {
                play(playlist.songs, at: 0)
            } onShuffle: {
                // 抽一首直接起播，不弹播放页（停在歌单首页看底部悬浮条）
                player.replaceQueue(playlist.songs, shuffle: true)
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.bottom, Tokens.Spacing.s)
    }

    /// 副行写清楚来源：这是从哪家导入的、谁建的、多少首，不冒充"四平台合并"
    private func meta(_ playlist: ImportedPlaylist) -> String {
        var parts = ["\(playlist.songs.count) 首", playlist.platform.displayName]
        if !playlist.creator.isEmpty { parts.append(playlist.creator) }
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
}

// MARK: - 设置 → 导入歌单

struct ImportPlaylistView: View {

    @Environment(MyPlaylistStore.self) private var store

    @State private var link = ""
    @State private var importing = false
    @State private var errorText: String?
    @State private var successText: String?
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section("歌单链接") {
                TextField("粘贴歌单分享链接", text: $link, axis: .vertical)
                    .lineLimit(3...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                HStack(spacing: Tokens.Spacing.s) {
                    Button("从剪贴板粘贴") {
                        if let text = UIPasteboard.general.string { link = text }
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await runImport() }
                    } label: {
                        if importing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("导入")
                        }
                    }
                    .disabled(trimmedLink.isEmpty || importing)
                }
                if importing {
                    // 网易「我喜欢的音乐」这类歌单要按 id 补齐（详情只回 6 首），700 首约十几秒
                    StatusLine(kind: .progress("正在读取歌单…大歌单要十几秒"))
                }
                if let errorText {
                    StatusLine(kind: .error(errorText))
                }
                if let successText {
                    StatusLine(kind: .info(successText))
                }
            }

            Section("支持哪些链接") {
                Text("QQ 音乐、网易云音乐、酷我音乐、酷狗音乐的公开歌单分享链接。整段分享文案粘进来就行，链接前后的文字会自动忽略。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("导入后歌单会整份存到本机：之后打开不再联网、也不会变。私密歌单和「我喜欢的音乐」读不到（需要登录，App 不做登录）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("已导入（\(store.playlists.count) 个）") {
                if store.playlists.isEmpty {
                    Text("还没有导入过歌单")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.playlists) { playlist in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                                .lineLimit(1)
                            Text(playlist.metaLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .onDelete { indexSet in
                        // 先取 id 再删：边删边按下标取会错位
                        let ids = indexSet.map { store.playlists[$0].id }
                        ids.forEach(store.remove)
                    }
                    Button("清空已导入歌单（\(store.playlists.count) 个）", role: .destructive) {
                        showClearConfirm = true
                    }
                }
            }
        }
        .navigationTitle("导入歌单")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清空 \(store.playlists.count) 个已导入歌单？",
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                store.removeAll()
                successText = nil
                errorText = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var trimmedLink: String {
        link.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func runImport() async {
        guard !importing, !trimmedLink.isEmpty else { return }
        importing = true
        errorText = nil
        successText = nil
        Haptics.prepare()
        do {
            let playlist = try await store.importLink(trimmedLink)
            link = ""
            successText = "已导入《\(playlist.name)》\(playlist.songs.count) 首"
            Haptics.success()
        } catch {
            errorText = error.localizedDescription
        }
        importing = false
    }
}

import SwiftUI

// MARK: - 编辑精选歌单页（设计稿 §3.2）
//
// 第二十轮（老板："编辑精选里剩下 4 个页面，里面都是纯文字，没有封面、没有歌手、没有收藏"）：
// 这一页原来只有「歌名 + 歌手」两行纯文字——因为池子里存的就只有名字，平台 id 要等点开才去搜。
// 现在**进页面就在后台把 20 首逐首解析成真实 Song**（并发 3，解析出一首填一格）：
// 填到哪一行，哪一行就从占位行换成**全 App 统一行样式** `SongRow`——
// 52pt 封面 + 歌名 + 歌手·专辑 + 平台胶囊 + 时长 + 收藏心。
//
// 还没解析到、或者确实搜不到的行，留一行带占位封面的行（不空、不跳），
// 搜不到的行尾会显示警告图标——与原来"失败必须在行尾看得见"的口径一致。
struct EditorPlaylistView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DiscoverFeed.self) private var feed
    @Environment(AppRouter.self) private var router

    let playlist: DiscoverCatalog.Playlist
    /// 发现页「换一批」的轮次（叠加到日期上，用来换一组 20 首）
    let rotation: Int

    @State private var resolvingIndex: Int?
    @State private var failedRows: Set<Int> = []
    @State private var status: String?
    @State private var preparing = false

    /// 当天这批 20 首：进页面时算一次（内部会记「今天展示过」，所以不能放在 body 里算）
    @State private var seeds: [DiscoverCatalog.Seed] = []
    /// index → 解析出来的真实歌曲（进页面就后台补；补到就整行换成 SongRow）
    @State private var songs: [Int: Song] = [:]

    private var accent: Color { Color(hex: playlist.accentHex) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(Array(seeds.enumerated()), id: \.offset) { index, seed in
                    row(index: index, seed: seed)
                }
                if let status {
                    StatusLine(kind: .info(status))
                        .padding(.horizontal, Tokens.Spacing.pageMargin)
                        .padding(.top, Tokens.Spacing.s)
                }
                // 迷你条是浮层：末尾让出高度，最后一行不会被压住（第五轮反馈 ⑨）
                MiniPlayerSpacer()
            }
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            Haptics.prepare()
            guard seeds.isEmpty else { return }
            seeds = feed.editorSeeds(for: playlist, rotation: rotation)
            feed.markShown(seeds, in: playlist)
            // 这一页现在自己就需要把 20 首解析出来，不再借热门音乐的缓存预热
            await resolveAll()
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(LinearGradient(colors: [accent.opacity(0.36), accent.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "music.note.list")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(accent)
            }
            .frame(width: 88, height: 88)

            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text(playlist.title)
                    .font(.title3.weight(.semibold))
                Text("今日精选 \(seeds.count) 首 · 点单曲即播")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await playAll() }
                } label: {
                    HStack(spacing: 6) {
                        if preparing {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "play.fill").font(.caption)
                        }
                        Text(preparing ? "准备中…" : "播放全部")
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
                .disabled(preparing || resolvingIndex != nil)
                .padding(.top, Tokens.Spacing.xxs)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.vertical, Tokens.Spacing.m)
    }

    // MARK: 行

    /// 解析到的行用统一 `SongRow`（封面/歌手·专辑/平台/时长/收藏）；
    /// 没解析到的行先用占位行，解析完成会自己换过来（两行的封面槽都是 52pt，换行不跳）。
    @ViewBuilder
    private func row(index: Int, seed: DiscoverCatalog.Seed) -> some View {
        if let song = songs[index] {
            Button {
                Task { await play(index: index) }
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
            .disabled(resolvingIndex != nil || preparing)
            .accessibilityLabel("第 \(index + 1) 首，\(song.name)，\(song.singer)")
            .accessibilityHint("点一下播放")
        } else {
            placeholderRow(index: index, seed: seed)
        }
    }

    private func placeholderRow(index: Int, seed: DiscoverCatalog.Seed) -> some View {
        Button {
            Task { await play(index: index) }
        } label: {
            HStack(spacing: Tokens.Spacing.s) {
                Text(String(format: "%02d", index + 1))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(index < 3 ? Tokens.Palette.vermilion : Color.secondary)
                    .frame(width: 20, alignment: .trailing)

                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.Radius.artworkSmall, style: .continuous)
                        .fill(Tokens.Palette.paperElevated)
                    Image(systemName: "music.note")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: Tokens.Size.songRowArtwork, height: Tokens.Size.songRowArtwork)

                VStack(alignment: .leading, spacing: 3) {
                    Text(seed.name)
                        .font(FontRole.songTitle)
                        .lineLimit(1)
                    Text(seed.singer)
                        .font(FontRole.songSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Tokens.Spacing.xs)

                if resolvingIndex == index {
                    ProgressView().controlSize(.small)
                } else if failedRows.contains(index) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("没找到可播放的版本")
                }
            }
            .frame(minHeight: Tokens.Size.songRowHeight)
            .padding(.vertical, Tokens.Spacing.xxs)
            .padding(.horizontal, Tokens.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowPress)
        .disabled(resolvingIndex != nil || preparing)
        .padding(.horizontal, Tokens.Spacing.pageMargin - Tokens.Spacing.xxs)
        .accessibilityLabel("第 \(index + 1) 首，\(seed.name)，\(seed.singer)")
        .accessibilityHint("点一下解析并播放")
    }

    // MARK: 取歌

    /// 第 index 首的 Song：进页面时的后台补全、或之前点过，就直接复用；
    /// 否则现搜一次并记下来（同一首不会被搜两遍：后台补全 / 点播放 / 补队列共用这一处）。
    private func resolvedSong(at index: Int) async -> Song? {
        guard seeds.indices.contains(index) else { return nil }
        if let hit = songs[index] { return hit }
        let resolved = await feed.resolve(seed: seeds[index])
        if let resolved {
            songs[index] = resolved
            failedRows.remove(index)
        } else {
            failedRows.insert(index)
        }
        return resolved
    }

    /// 进页面后台补全：并发 3（一首一次四平台搜索，20 首一起打出去会拖垮首屏）。
    /// 每解析出一首就填一格，行自动从占位行换成正式行——页面不会"等 20 首齐了才出现"。
    @MainActor
    private func resolveAll() async {
        let list = seeds
        guard !list.isEmpty else { return }
        // 已经全部解析过了（比如从播放页返回）就不用再搜一遍
        if songs.count == list.count { return }

        let concurrency = 3
        var next = 0
        var done = songs.count
        let total = list.count
        // 捕获成局部常量再进 Task：`feed` 是 @Environment 属性，闭包里直接写它要靠隐式 self，
        // 在并发的子任务里既慢又容易触发隔离检查——先落到局部 let。
        let feedRef = feed

        await withTaskGroup(of: (Int, Song?).self) { group in
            while next < min(concurrency, total) {
                let index = next
                next += 1
                group.addTask { (index, await feedRef.resolve(seed: list[index])) }
            }
            while let (index, resolved) = await group.next() {
                done += 1
                if let resolved {
                    songs[index] = resolved
                    failedRows.remove(index)
                } else {
                    failedRows.insert(index)
                }
                if done < total {
                    status = "正在补全封面 \(done)/\(total)…"
                }
                if next < total {
                    let index = next
                    next += 1
                    group.addTask { (index, await feedRef.resolve(seed: list[index])) }
                }
            }
        }

        status = songs.count == total
            ? "今日精选 \(total) 首 · 点任意一首播放"
            : "今日精选 \(total) 首，其中 \(total - songs.count) 首没找到可播放版本"
    }

    // MARK: 播放

    private func play(index: Int) async {
        guard resolvingIndex == nil else { return }
        let list = seeds
        guard list.indices.contains(index) else { return }
        resolvingIndex = index
        failedRows.remove(index)
        status = nil

        if let song = await resolvedSong(at: index) {
            // 第五轮（老板反馈 ②）：点单曲时队列里只有这一首，列表循环就退化成单曲循环。
            // 先播点中的这首（1~3 秒有声音），再把这张歌单其余曲目后台补进队列。
            player.play(queue: [song], startAt: 0)
            library.recordPlayed(song)
            Haptics.playbackToggle()
            router.showPlayer = true
            Task { await fillAround(tapped: index) }
        } else {
            failedRows.insert(index)
            status = "《\(list[index].name)》没找到可播放的版本"
        }
        resolvingIndex = nil
    }

    /// 点单曲起播后，把同一张歌单里**其余**曲目后台解析并追加进队列。
    ///
    /// 顺序：从点中那首的下一行开始，绕回列表开头——这样"下一首"就是列表上看到的下一行。
    /// 为什么不一次解析完再起播：这个池子每首都要四平台搜索，20 首要一分多钟，
    /// 用户会以为卡死（`playAll` 那边同样只先凑 5 首）。
    private func fillAround(tapped: Int) async {
        guard seeds.count > 1 else { return }
        let order = (1..<seeds.count).map { (tapped + $0) % seeds.count }
        var added = 0
        for index in order {
            if let song = await resolvedSong(at: index) {
                player.appendToQueue([song])
                added += 1
            }
        }
        status = added > 0
            ? "队列已就绪 \(added + 1) 首（整张 \(seeds.count) 首）"
            : "队里暂时只有这一首可播放"
    }

    /// 「播放全部」：逐首解析，凑到 5 首就先起播（其余等用户点）。
    /// 为什么不是整张 20 首：一首一次四平台搜索，20 首要一分多钟，用户会以为卡死。
    /// 与 Android 的差别写在 docs/ios/IOS-DISCOVER.md「已知取舍」里。
    private func playAll() async {
        guard !preparing, resolvingIndex == nil else { return }
        preparing = true
        status = "正在准备队列…"

        var resolved: [Song] = []
        let target = 5
        var nextIndex = 0
        for (index, _) in seeds.enumerated() {
            nextIndex = index + 1
            if resolved.count >= target { break }
            status = "正在准备队列 \(resolved.count)/\(target)…"
            resolvingIndex = index
            if let song = await resolvedSong(at: index) {
                resolved.append(song)
            }
        }
        resolvingIndex = nil

        if resolved.isEmpty {
            status = "这张歌单今天没有可播放的曲目"
            Haptics.warning()
        } else {
            player.play(queue: resolved, startAt: 0)
            library.recordPlayed(resolved[0])
            Haptics.success()
            status = "队列已就绪 \(resolved.count) 首，正在补齐其余…"
            // 其余曲目后台解析并追加进队列（用户不用一首首点，也不卡住首播）
            Task { await fillRemaining(from: nextIndex, already: resolved.count) }
        }
        preparing = false
    }

    /// 后台补齐：解析一首补一首，队列追加后「下一首」自然往下走
    private func fillRemaining(from start: Int, already: Int) async {
        guard start < seeds.count else { return }
        var added = 0
        for index in start..<seeds.count {
            if let song = await resolvedSong(at: index) {
                player.appendToQueue([song])
                added += 1
            }
            if added % 5 == 0, added > 0 {
                status = "队列已就绪 \(already + added) 首…"
            }
        }
        status = "队列已就绪 \(already + added) 首（整张 \(seeds.count) 首）"
    }
}

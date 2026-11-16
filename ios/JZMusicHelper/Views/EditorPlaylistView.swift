import SwiftUI

// MARK: - 编辑精选歌单页（设计稿 §3.2）
//
// 歌单里只有「歌名 + 歌手」（内置池），平台 ID 要等用户点开某首时才去搜——与 Android
// 「点单曲才搜索播放」同口径。所以这一页每一行都能失败，失败必须在行尾看得见。
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

    private var accent: Color { Color(hex: playlist.accentHex) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(Array(seeds.enumerated()), id: \.offset) { index, seed in
                    row(index: index, seed: seed)
                    Divider().padding(.leading, Tokens.Spacing.pageMargin + 24 + Tokens.Spacing.s)
                }
                if let status {
                    StatusLine(kind: .info(status))
                        .padding(.horizontal, Tokens.Spacing.pageMargin)
                        .padding(.top, Tokens.Spacing.s)
                }
            }
            .padding(.bottom, Tokens.Spacing.xxl)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            Haptics.prepare()
            if seeds.isEmpty {
                seeds = feed.editorSeeds(for: playlist, rotation: rotation)
                feed.markShown(seeds, in: playlist)
            }
            await feed.loadHotIfNeeded()
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

    private func row(index: Int, seed: DiscoverCatalog.Seed) -> some View {
        Button {
            Task { await play(index: index) }
        } label: {
            HStack(spacing: Tokens.Spacing.s) {
                Text(String(format: "%02d", index + 1))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .trailing)

                VStack(alignment: .leading, spacing: 1) {
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
                } else {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: Tokens.Size.songRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .disabled(resolvingIndex != nil || preparing)
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .accessibilityLabel("第 \(index + 1) 首，\(seed.name)，\(seed.singer)")
        .accessibilityHint("点一下解析并播放")
    }

    // MARK: 播放

    private func play(index: Int) async {
        guard resolvingIndex == nil else { return }
        let list = seeds
        guard list.indices.contains(index) else { return }
        resolvingIndex = index
        failedRows.remove(index)
        status = nil

        if let song = await feed.resolve(seed: list[index]) {
            player.playSingle(song)
            library.recordPlayed(song)
            Haptics.playbackToggle()
            router.showPlayer = true
        } else {
            failedRows.insert(index)
            status = "《\(list[index].name)》没找到可播放的版本"
        }
        resolvingIndex = nil
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
        for (index, seed) in seeds.enumerated() {
            nextIndex = index + 1
            if resolved.count >= target { break }
            status = "正在准备队列 \(resolved.count)/\(target)…"
            resolvingIndex = index
            if let song = await feed.resolve(seed: seed) {
                resolved.append(song)
                failedRows.remove(index)
            } else {
                failedRows.insert(index)
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
            let seed = seeds[index]
            if let song = await feed.resolve(seed: seed) {
                player.appendToQueue([song])
                added += 1
                failedRows.remove(index)
            } else {
                failedRows.insert(index)
            }
            if added % 5 == 0, added > 0 {
                status = "队列已就绪 \(already + added) 首…"
            }
        }
        status = "队列已就绪 \(already + added) 首（整张 \(seeds.count) 首）"
    }
}

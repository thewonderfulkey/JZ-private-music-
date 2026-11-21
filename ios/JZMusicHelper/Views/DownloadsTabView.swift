import SwiftUI
import UniformTypeIdentifiers

// MARK: - 下载（第四十轮补丁 4）
//
// 老板三条真机反馈（r115）：
//   ① 下载完了进度条还挂着、不消失；
//   ② 下载页里删不掉歌（改成 ScrollView 之后左滑删除没了，长按菜单他又碰不到）；
//   ③ 点播没了 / "直接变成了照片"——本地文件找不到时只剩封面。
//
// 这一版的做法：
//   · 回到 `List`（`.plain`）但**行背景全透明、分隔线全隐藏**——观感仍是收藏页那种"干净的一行行歌"，
//     同时把左滑删除/重试/取消**恢复**（和以前一样的用法）；
//   · 已下载的行只有 `SongRow`（封面/歌名/歌手/平台/时长/❤），**任何情况下都不画进度条**；
//     只有"正在下载"的行才画进度，而且完成度 ≥99.9% 时也不画（那一瞬间已经在收尾）；
//   · 长按菜单保留（删除下载），左滑是第二条路——两种都能删。
struct DownloadsTabView: View {

    @EnvironmentObject private var downloads: DownloadManager
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    /// 第四十四轮：「定位到正在播放」的状态
    @State private var locator = SongLocator()
    /// 本地搜索（下载/导入都在这一页，按内容过滤，纯本地不联网）
    @State private var query = ""
    @State private var showImporter = false
    @State private var showDedupeConfirm = false

    private var queryKey: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func hit(_ item: DownloadItem) -> Bool {
        queryKey.isEmpty
            || LibrarySearch.matches(song: item.song, fileName: item.fileName, query: queryKey)
    }

    private var ongoing: [DownloadItem] {
        downloads.items.filter {
            ($0.status == .downloading || $0.status == .pending) && hit($0)
        }
    }
    private var finished: [DownloadItem] {
        downloads.items.filter { $0.status == .completed && hit($0) }
    }
    private var failed: [DownloadItem] {
        downloads.items.filter { ($0.status == .failed || $0.status == .cancelled) && hit($0) }
    }

    private var totalBytes: Int64 {
        downloads.items.reduce(0) { $0 + $1.totalBytes }
    }

    var body: some View {
        Group {
            if downloads.items.isEmpty {
                EmptyStateView(title: "还没有下载任务",
                               systemImage: "arrow.down.circle",
                               description: "在播放页点「下载」，选一个音质")
            } else {
                list
            }
        }
        // 2026-11-21：SwiftUI 的 `.fileImporter` 在真机上"打开"点了没反应（菜单动作里直接 present，
        // 选择器的委托连线被吞）。换成自己包的 UIDocumentPickerViewController：自己收回调、自己 dismiss。
        .sheet(isPresented: $showImporter) {
            DocumentPicker { urls in
                showImporter = false
                guard !urls.isEmpty else { return }
                startImport(urls)
            }
        }
        .alert("导入", isPresented: Binding(
            get: { downloads.lastImportReport != nil },
            set: { if !$0 { downloads.lastImportReport = nil } })) {
            Button("好") { downloads.lastImportReport = nil }
        } message: {
            Text(downloads.lastImportReport ?? "")
        }
        .confirmationDialog("把同一首歌的多条合成一条？（只留音质更好的）",
                            isPresented: $showDedupeConfirm, titleVisibility: .visible) {
            Button("整理", role: .destructive) {
                let r = downloads.dedupeSameRecording()
                downloads.lastImportReport = r.merged == 0
                    ? "没有需要整理的重复"
                    : "已合并 \(r.merged) 条，释放 \(ByteCountFormatter.string(fromByteCount: r.freedBytes, countStyle: .file))"
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 导入进度（后台在干活时显示；没有进度条用户就以为"没反应"）
    @ViewBuilder
    private var importProgressBanner: some View {
        if let p = downloads.importProgress {
            HStack(spacing: Tokens.Spacing.xs) {
                ProgressView().scaleEffect(0.8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("正在导入 \(min(p.done + 1, p.total))/\(p.total)")
                        .font(.footnote.weight(.semibold))
                    Text(p.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("取消") { downloads.cancelImport() }
                    .font(.footnote)
                    .buttonStyle(.press)
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)
            .padding(.vertical, Tokens.Spacing.xs)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// 真正开始导入：**必须 detached**（哈希/复制是重活，放主线程会把选择器与界面卡死）
    private func startImport(_ urls: [URL]) {
        downloads.importCancelled = false
        // 结果由 `DownloadManager.lastImportReport` 发布（View 的 @State 在 detached 里写不回去）
        Task.detached(priority: .userInitiated) {
            _ = await downloads.importAudioFiles(urls)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                importProgressBanner
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if !ongoing.isEmpty {
                    Section {
                        ForEach(ongoing) { item in
                            activeRow(item)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        downloads.cancel(itemID: item.id)
                                    } label: {
                                        Label("取消", systemImage: "xmark.circle")
                                    }
                                }
                        }
                    } header: {
                        sectionHeader("正在下载（\(ongoing.count)）")
                    }
                }

                if !failed.isEmpty {
                    Section {
                        ForEach(failed) { item in
                            failedRow(item)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        downloads.remove(itemID: item.id, deleteFile: true)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    Button {
                                        downloads.retry(itemID: item.id, useBackground: true)
                                    } label: {
                                        Label("重试", systemImage: "arrow.clockwise")
                                    }
                                    .tint(Tokens.Palette.vermilion)
                                }
                        }
                    } header: {
                        sectionHeader("失败（\(failed.count)）")
                    }
                }

                if !finished.isEmpty {
                    Section {
                        ForEach(finished) { item in
                            completedRow(item)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        downloads.remove(itemID: item.id, deleteFile: true)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                                // 第四十四轮：行 id 要让 ScrollViewReader 找得到
                                // （用 uuidString 而不是 UUID：ScrollViewReader 的 id 统一走 String）
                                .id(item.id.uuidString)
                        }
                    } header: {
                        sectionHeader("已下载（\(finished.count)）")
                    }
                }

                Color.clear
                    .frame(height: MiniPlayerMetrics.barHeight)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerClearance() }
            .locateToast(locator.toast)
            .searchable(text: $query, prompt: "搜歌名 / 歌手 / 专辑 / 文件名")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showImporter = true
                        } label: {
                            Label("导入本地音乐…", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            showDedupeConfirm = true
                        } label: {
                            Label("整理重复（同曲留最高音质）", systemImage: "rectangle.stack.badge.minus")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("导入与整理")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    LocateNowPlayingButton {
                        // 下载页的行按 `DownloadItem.id` 认（同一首歌可以有两档音质，`song.id` 会重复）
                        locator.locate(current: player.currentSong,
                                       songs: downloads.completedSongs,
                                       rowIDs: finished.map { $0.id.uuidString },
                                       scroll: { id in
                                           proxy.scrollTo(id, anchor: .center)
                                       })
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.horizontal, Tokens.Spacing.pageMargin)
            .padding(.top, Tokens.Spacing.s)
    }

    // MARK: 头部（版式与「我的收藏」一致）

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
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.white)
                }
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("我的下载")
                        .font(.title3.weight(.bold))
                    Text("\(finished.count) 首 · \(sizeText(totalBytes))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Tokens.Spacing.s) {
                        Button {
                            playAll(shuffle: false)
                        } label: {
                            Label("播放全部", systemImage: "play.fill")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .background(Capsule().fill(Tokens.Palette.paperElevated))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                        }
                        .buttonStyle(.press)
                        .disabled(finished.isEmpty)

                        Button {
                            playAll(shuffle: true)
                        } label: {
                            Label("随机", systemImage: "shuffle")
                                .font(.footnote)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .background(Capsule().fill(Tokens.Palette.paperElevated))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                        }
                        .buttonStyle(.press)
                        .disabled(finished.isEmpty)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Tokens.Spacing.xxs) {
                Image(systemName: "folder")
                    .font(.caption2)
                Text(DownloadLocation.currentPathText)
                    .font(.caption2)
                    .lineLimit(1)
                Text("·")
                    .font(.caption2)
                Text(DownloadPathRules.foldersSummary)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.vertical, Tokens.Spacing.m)
    }

    // MARK: 已下载（一行歌，和收藏页同款；没有进度条）

    private func completedRow(_ item: DownloadItem) -> some View {
        Button {
            RowTap.afterHighlight {
                let songs = downloads.completedSongs
                if let index = songs.firstIndex(where: { $0.id == item.song.id }) {
                    player.play(queue: songs, startAt: index)
                } else {
                    player.playSingle(item.song)
                }
                router.showPlayer = true
            }
        } label: {
            SongRow(song: item.song,
                    showsFavorite: true,
                    isFavorite: library.isFavorite(item.song),
                    onFavorite: {
                        Haptics.favorite()
                        withAnimation(Tokens.Motion.favorite) {
                            library.toggleFavorite(item.song)
                        }
                    },
                    subtitle: "\(item.origin == "import" ? "本地导入 · " : "")\(item.quality.displayName) · \(item.sizeText)")
                .padding(.horizontal, Tokens.Spacing.pageMargin)
        }
        .buttonStyle(.rowPress)
        .contextMenu {
            Button(role: .destructive) {
                downloads.remove(itemID: item.id, deleteFile: true)
            } label: {
                Label("删除下载", systemImage: "trash")
            }
        }
    }

    // MARK: 正在下载（唯一会画进度条的行）

    private func activeRow(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            rowHeadline(item: item,
                        subtitle: item.status == .pending
                            ? "\(item.quality.displayName) · 等待中"
                            : "\(item.quality.displayName) · \(item.progressText)",
                        tint: .secondary)
            // 收尾（≥99.9%）不再画进度条：老板说的"下载完还挂着进度条"就是这一帧
            if item.status == .downloading, item.progress < 0.999 {
                ProgressView(value: item.progress)
                    .tint(Tokens.Palette.vermilion)
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
            }
        }
        .padding(.vertical, Tokens.Spacing.xs)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                downloads.cancel(itemID: item.id)
            } label: {
                Label("取消下载", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: 失败

    private func failedRow(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            rowHeadline(item: item,
                        subtitle: "\(item.quality.displayName) · 失败",
                        tint: .orange)
            if let note = item.errorMessage, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
            }
        }
        .padding(.vertical, Tokens.Spacing.xs)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                downloads.retry(itemID: item.id, useBackground: true)
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                downloads.remove(itemID: item.id, deleteFile: true)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 封面 + 歌名 + 状态 + 歌手（无底色）
    private func rowHeadline(item: DownloadItem, subtitle: String, tint: Color) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            SongArtwork(song: item.song)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.song.name)
                    .font(FontRole.songTitle)
                    .lineLimit(1)
                Text(subtitle)
                    .font(FontRole.songSubtitle)
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Spacing.xs)
            Text(item.song.singer)
                .font(FontRole.metadata)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
    }

    // MARK: 工具

    private func playAll(shuffle: Bool) {
        let songs = downloads.completedSongs
        guard !songs.isEmpty else { return }
        if shuffle {
            player.replaceQueue(songs, shuffle: true)
        } else {
            player.play(queue: songs, startAt: 0)
        }
        router.showPlayer = true
    }

    private func sizeText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - 系统文件选择器（UIKit 包装）

/// 为什么不用 SwiftUI 的 `.fileImporter`：2026-11-21 真机上它 present 之后，
/// "打开"按钮点了完全没反应（从 Menu 动作里直接 present，选择器的 delegate 连线被吞）。
/// UIKit 这条路我们自己控制 dismiss 与回调，且能显示扩展名。
struct DocumentPicker: UIViewControllerRepresentable {

    var onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // `.item` = 任何文件都能选（对方 App 的自定义扩展名也能选）；文件夹同样可选
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

import SwiftUI
import UIKit
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
    @State private var showDedupeConfirm = false
    /// 导入面板（内置浏览器；不经过系统选择器）
    @State private var showImportBrowser = false
    /// 一句话轻提示（"开始导入 N 个文件…"这种，1.5 秒后自己消失）
    @State private var notice: String?
    /// 多选态（2026-11-21 老板：多选 + 全选 + 批量删除）
    @State private var selectMode = false
    @State private var picked: Set<UUID> = []
    @State private var showBatchDeleteConfirm = false

    /// 第 41 轮 P0-2：首屏只建这么多行，滚到底/点「继续加载」再追加。
    /// 第 42 轮（真机 perf.log：80 行要 507–813ms ≈ 7–10ms/行）：**首帧只建 8 行**，
    /// 之后分块补到 `fillTarget`（每块 4 行，一旦出现 >150ms 的长停顿就停止自动补，
    /// 交给「继续加载」按钮 —— 保证验收口径 maxGap < 100ms）。
    @State private var visibleLimit = DownloadListPaging.firstFrame
    /// 自动补行是否还在跑
    @State private var fillScheduled = false
    /// 已经挂上左滑/长按菜单的行（只有"要动手的那些行"才挂，见 `completedRow`）
    @State private var armed: Set<UUID> = []
    /// 自动续加载的节流（同一帧里连开好几页就等于没分页）
    @State private var lastAutoLoadAt = Date.distantPast

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

    /// 这一帧真正要建的行（第 41 轮 P0-2）。顺序/预算口径见 `DownloadListPaging`。
    /// 顺手在这里打 t2（body 首次求值一定先算它）—— 见 `PerfProbe`。
    private var paged: DownloadPageSlices {
        PerfProbe.pageBody("downloads")
        return DownloadListPaging.slices(ongoing: ongoing, failed: failed, finished: finished,
                                         limit: visibleLimit)
    }

    var body: some View {
        Group {
            if downloads.items.isEmpty {
                empty
            } else {
                list
            }
        }
        // 三个点（导入 / 整理）挂在**外层**。
        // 2026-11-21 老板反馈："下载页没有下载的歌曲就没有三个点，也就没有导入入口"
        // —— 以前这个 Menu 写在 `list` 的 toolbar 里，而空页面走的是另一个分支，所以整条
        // 工具栏（含三个点）在空状态下根本不存在。现在两个分支共用这一条工具栏。
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { importMenu }
        }
        .sheet(isPresented: $showImportBrowser) {
            ImportBrowserView { urls in
                flash("开始导入 \(urls.count) 个文件…")
                startImport(urls)
            }
            .environmentObject(downloads)
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
        .confirmationDialog("删除选中的 \(picked.count) 首？",
                            isPresented: $showBatchDeleteConfirm, titleVisibility: .visible) {
            Button("删除（文件一起删掉）", role: .destructive) { deletePicked() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下载记录和磁盘上的文件都会删掉，删了找不回来。")
        }
        // 条目变化（删了一首 / 导入进来一批）后清理选择：别删到看不见的东西
        .onChange(of: downloads.items.count) { _, _ in
            picked = BatchSelection.pruning(picked, visible: visibleIDs)
            armed.formIntersection(visibleIDs)
            if downloads.items.isEmpty { selectMode = false }
        }
        // 换了搜索词就回到首帧行数（否则上一轮的"加载到 400 行"会带过来，白白多建行）
        .onChange(of: queryKey) { _, _ in
            visibleLimit = DownloadListPaging.firstFrame
            fillScheduled = false
            scheduleFill()
        }
        .locateToast(notice)
    }

    /// 工具栏上的三个点：导入（系统选择器为主）+ 文件夹导入 + 整理重复
    private var importMenu: some View {
        Menu {
            Button {
                pickFilesFromMenu()
            } label: {
                Label("导入本地音乐（选择文件）", systemImage: "square.and.arrow.down")
            }
            Button {
                showImportBrowser = true
            } label: {
                Label("从「JZ 音乐」文件夹导入…", systemImage: "folder")
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

    /// 直接弹**系统文件选择器**（老板实测这条路能导成功，所以它是主入口，一步到位）
    private func pickFiles() {
        DocumentPickerPresenter.present(onFail: { message in
            flash(message)
        }, onPick: { urls in
            guard !urls.isEmpty else { return }
            flash("已选 \(urls.count) 个文件，开始导入…")
            startImport(urls)
        })
    }

    /// 从 Menu 里点：等菜单收起动画过去再弹（不然会和菜单抢同一帧，present 失败）
    private func pickFilesFromMenu() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            pickFiles()
        }
    }

    /// 空状态：按钮用 `EmptyStateView(action:)`，**不再**是 ContentUnavailableView 后面
    /// 跟一个 Button —— 那个 Button 会被撑满的 ContentUnavailableView 顶到屏幕外，
    /// 老板看到的"没有导入本地按钮"就是这么来的。
    private var empty: some View {
        ScrollView {
            VStack(spacing: Tokens.Spacing.s) {
                EmptyStateView(title: "还没有下载任务",
                               systemImage: "arrow.down.circle",
                               description: "在播放页点「下载」，选一个音质。\n已有的本地音乐也可以导进来。",
                               actionTitle: "导入本地音乐",
                               action: { pickFiles() })
                Text("会打开系统「文件」选择器；也可以点右上角「⋯」从「JZ 音乐」文件夹导入")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Tokens.Spacing.l)
            .padding(.bottom, Tokens.Spacing.xxl)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerClearance() }
    }

    /// 一句话提示，1.5 秒后自己消失（导入开始/系统选择器失败都用它，绝不静默）
    private func flash(_ text: String) {
        notice = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if notice == text { notice = nil }
        }
    }

    /// 导入进度（后台在干活时显示；没有进度条用户就以为"没反应"）
    @ViewBuilder
    private var importProgressBanner: some View {
        if let p = downloads.importProgress {
            HStack(spacing: Tokens.Spacing.xs) {
                ProgressView().scaleEffect(0.8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.phase == .grabbing
                         ? "正在取回 \(min(p.done + 1, p.total))/\(p.total)"
                         : "正在导入 \(min(p.done + 1, p.total))/\(p.total)")
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
                        ForEach(paged.ongoing) { item in
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

                if !paged.failed.isEmpty {
                    Section {
                        ForEach(paged.failed) { item in
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
                        sectionHeader(failedHeaderText)
                    }
                }

                if !paged.finished.isEmpty {
                    Section {
                        ForEach(paged.finished) { item in
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
                                // 第 42 轮：**去掉** `.id(uuidString)`。
                                // 行本身就是 `ForEach(finished)` 的元素，identity 已经是 `item.id`；
                                // 再挂一层 String id 等于每行每帧多一次身份重算（真机上这层很贵）。
                                // `ScrollViewReader.scrollTo` 直接认元素 id（UUID），见下面的「定位」。
                        }
                    } header: {
                        sectionHeader(finishedHeaderText)
                    }
                }

                // 第 41 轮 P0-2：还没显示完时的「继续加载」。滚到底自动续，
                // 也留一个能点的按钮（老板明确要"已显示 N / 总 M"的反馈，不能让人以为丢歌）。
                if paged.hasMore {
                    loadMoreRow
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Color.clear
                    .frame(height: MiniPlayerMetrics.barHeight)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // t3（第 41 轮打点）：列表首帧到了
            .onAppear {
                PerfProbe.pageReady("downloads", rows: paged.shown)
                // 第 42 轮：首帧挂完，下一拍开始分块补行（并给这几行挂上左滑/长按）
                DispatchQueue.main.async { armVisibleRows() }
                scheduleFill()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerClearance() }
            // 批量操作条浮在**迷你条上沿**：迷你条是父视图的 overlay，
            // 直接把操作条放 safeAreaInset 里会被它盖住（下载页经常在播歌）。
            .overlay(alignment: .bottom) {
                if selectMode {
                    batchBar
                        .padding(.bottom, CGFloat(MiniPlayerMetrics.listBottomInset(
                            playing: player.hasCurrentSong)))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .locateToast(locator.toast)
            .searchable(text: $query, prompt: "搜歌名 / 歌手 / 专辑 / 文件名")
            .toolbar {
                // 导入/整理的三个点在**外层**（`body` 的 toolbar 里），两个分支共用。
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selectMode {
                        Button(allSelected ? "取消全选" : "全选") {
                            withAnimation(.easeOut(duration: 0.15)) {
                                picked = BatchSelection.togglingAll(picked: picked,
                                                                    visible: visibleIDs)
                            }
                        }
                        Button("完成") { exitSelectMode() }
                    } else {
                        Button {
                            enterSelectMode()
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .accessibilityLabel("多选")
                        LocateNowPlayingButton {
                            // 行可能还在"未加载区"：先把 limit 撑到那一行，再滚（下一帧才有这行）
                            let revealed = revealRowForCurrentSong()
                            let scrollToCurrent = {
                                // 下载页的行按 `DownloadItem.id` 认（同一首歌可以有两档音质，`song.id` 会重复）。
                                // 第 42 轮：行的 identity 就是 `item.id`（不再挂 String id），所以这里直接传 UUID。
                                locator.locate(current: player.currentSong,
                                               songs: downloads.completedSongs,
                                               rowIDs: finished.map(\.id),
                                               scroll: { id in
                                                   proxy.scrollTo(id, anchor: .center)
                                               })
                            }
                            if revealed {
                                DispatchQueue.main.async(execute: scrollToCurrent)
                            } else {
                                scrollToCurrent()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 分页（第 41 轮 P0-2）

    private var failedHeaderText: String {
        let shown = paged.failed.count
        return shown < failed.count ? "失败（\(failed.count) · 已显示 \(shown)）" : "失败（\(failed.count)）"
    }

    private var finishedHeaderText: String {
        let shown = paged.finished.count
        return shown < finished.count
            ? "已下载（\(finished.count) · 已显示 \(shown)）"
            : "已下载（\(finished.count)）"
    }

    /// 还没显示完时的那一行：给明确反馈（已显示 N / 总 M），能点，也能滚到底自动续。
    private var loadMoreRow: some View {
        VStack(spacing: Tokens.Spacing.xs) {
            Text("已显示 \(paged.shown) / \(paged.total) 首")
                .font(FontRole.metadata)
                .foregroundStyle(.secondary)
            Button {
                loadMore()
            } label: {
                Label("继续加载 \(min(DownloadListPaging.pageStep, paged.hidden)) 首（还有 \(paged.hidden) 首没显示）",
                      systemImage: "arrow.down.circle")
                    .font(FontRole.songSubtitle)
                    .padding(.horizontal, Tokens.Spacing.m)
                    .frame(minHeight: Tokens.Spacing.minTapTarget)
                    .background(Capsule().fill(Tokens.Palette.paperElevated))
            }
            .buttonStyle(.press)
            if !queryKey.isEmpty {
                Text("搜索命中的歌里还有 \(paged.hidden) 首没显示，点上面继续加载")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Spacing.m)
        .onAppear {
            // 滚到底自动续：延迟一拍，别在布局过程中改状态。
            // 节流 0.4s：List 插入 80 行后这一行会被挤出可视区，
            // 万一 SwiftUI 连着触发 onAppear，也不会一口气把 662 行全建回来（那就等于没分页）。
            let now = Date()
            guard now.timeIntervalSince(lastAutoLoadAt) > 0.4 else { return }
            lastAutoLoadAt = now
            DispatchQueue.main.async { loadMore() }
        }
    }

    private func loadMore() {
        guard paged.hasMore else { return }
        visibleLimit = DownloadListPaging.nextLimit(visibleLimit, total: paged.total)
        armVisibleRows()
    }

    // MARK: 首帧 8 行 + 分块补行（第 42 轮）

    /// 只给"真的要动手的行"挂左滑/长按菜单。
    /// 跟 `visibleLimit` 在同一个函数里改，SwiftUI 会合并成一次渲染（不会多付一遍）。
    private func armVisibleRows() {
        let page = DownloadListPaging.slices(ongoing: ongoing, failed: failed,
                                             finished: finished, limit: visibleLimit)
        var next = armed
        next.formUnion(page.finished.map(\.id))
        next.formUnion(page.failed.map(\.id))
        next.formUnion(page.ongoing.map(\.id))
        if next.count != armed.count { armed = next }
    }

    /// 首帧之后分块补到 `fillTarget`：每拍 4 行，一旦这一轮已经出现过 >150ms 的停顿就停手，
    /// 剩下的交给「继续加载」按钮 —— 宁可少补几行，也不要再让主线程整段卡住。
    private func scheduleFill() {
        guard !fillScheduled else { return }
        fillScheduled = true
        DispatchQueue.main.async { fillStep() }
    }

    private func fillStep() {
        let target = min(DownloadListPaging.fillTarget, paged.total)
        guard visibleLimit < target, !PerfProbe.hadLongGap else {
            fillScheduled = false
            return
        }
        visibleLimit = DownloadListPaging.nextFillLimit(visibleLimit, target: target)
        armVisibleRows()
        DispatchQueue.main.async { fillStep() }
    }

    /// 「定位到正在播放」：目标行可能还在未加载区，先把 limit 撑到那一行。
    /// 返回 true = 这一帧还滚不了，要等下一帧（调用方负责延迟滚动）。
    private func revealRowForCurrentSong() -> Bool {
        guard let current = player.currentSong, !finished.isEmpty else { return false }
        guard let idx = ListLocate.index(of: current, in: finished.map(\.song)) else { return false }
        if paged.finished.count > idx { return false }

        var limit = visibleLimit
        while limit < paged.total {
            limit = DownloadListPaging.nextLimit(limit, total: paged.total)
            let probe = DownloadListPaging.slices(ongoing: ongoing, failed: failed,
                                                   finished: finished, limit: limit)
            if probe.finished.count > idx { break }
        }
        visibleLimit = limit
        return true
    }

    // MARK: 多选（2026-11-21 老板：多选按钮 + 全选 + 批量删除）

    /// 当前可见（受搜索过滤）的全部行 id —— 「全选」只作用于看得见的这些
    private var visibleIDs: [UUID] { (ongoing + failed + finished).map(\.id) }

    private var allSelected: Bool {
        BatchSelection.isAllSelected(picked: picked, visible: visibleIDs)
    }

    /// 底部批量操作条
    private var batchBar: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Text(picked.isEmpty ? "选择要处理的歌" : "已选 \(picked.count) 首")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, Tokens.Spacing.m)
                    .frame(minHeight: Tokens.Spacing.minTapTarget)
                    .background(Capsule().fill(Tokens.Palette.vermilion.opacity(0.14)))
            }
            .buttonStyle(.press)
            .disabled(picked.isEmpty)
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.vertical, Tokens.Spacing.xs)
        .background(.regularMaterial)
    }

    private func enterSelectMode() {
        withAnimation(.easeOut(duration: 0.15)) {
            selectMode = true
            picked = []
        }
    }

    private func exitSelectMode() {
        withAnimation(.easeOut(duration: 0.15)) {
            selectMode = false
            picked = []
        }
    }

    /// 批量删除：在飞的下载先叫停（否则删了记录任务还在跑），再删记录 + 文件
    private func deletePicked() {
        let ids = picked
        guard !ids.isEmpty else { return }
        for id in ids {
            if let item = downloads.items.first(where: { $0.id == id }),
               item.status == .downloading || item.status == .pending {
                downloads.cancel(itemID: id)
            }
            downloads.remove(itemID: id, deleteFile: true)
        }
        picked.removeAll()
        selectMode = false
        flash("已删除 \(ids.count) 首")
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
                    Text("\(finished.count) 首 · \(sizeText(totalBytes))"
                         + (paged.hasMore ? " · 已显示 \(paged.shown)" : ""))
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

    // MARK: 已下载（瘦行 + 交互按需挂载）

    private func completedRow(_ item: DownloadItem) -> some View {
        let interactive = armed.contains(item.id)
        return Button {
            if selectMode {
                picked = BatchSelection.toggling(picked, item.id)
                return
            }
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
            DownloadRow(item: item,
                        // 多选态里不显示红心：那是个内嵌按钮，会和"点整行勾选"抢手势
                        showsFavorite: !selectMode,
                        isFavorite: library.isFavorite(item.song),
                        onFavorite: {
                            Haptics.favorite()
                            withAnimation(Tokens.Motion.favorite) {
                                library.toggleFavorite(item.song)
                            }
                        },
                        isSelected: selectMode ? picked.contains(item.id) : nil)
                .padding(.horizontal, Tokens.Spacing.pageMargin)
        }
        .buttonStyle(.rowPress)
        // 第 42 轮：左滑删除 / 长按菜单只在"露过脸的行"上挂。
        // 每行少挂 2 个交互修饰符，80 行就是 160 份开销；而真正会被左滑的只有看得见的那些。
        .modifier(DownloadRowActions(itemID: item.id, enabled: interactive) { id in
            downloads.remove(itemID: id, deleteFile: true)
        })
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
        .onTapGesture {
            // 多选态：点整行 = 勾选/取消（平时这一行没有点击行为，只有长按菜单）
            if selectMode { picked = BatchSelection.toggling(picked, item.id) }
        }
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
        .onTapGesture {
            if selectMode { picked = BatchSelection.toggling(picked, item.id) }
        }
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

    /// 封面 + 歌名 + 状态 + 歌手（无底色）；多选态行首多一个勾选圈
    private func rowHeadline(item: DownloadItem, subtitle: String, tint: Color) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            if selectMode {
                Image(systemName: picked.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(picked.contains(item.id)
                                     ? Tokens.Palette.vermilion : Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
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
        ByteText.human(bytes)
    }
}

// MARK: - 下载页瘦行（第 42 轮）

/// 真机 perf.log：80 行首帧 507–813ms ≈ 7–10ms/行，所以行本身必须瘦。
///
/// 和收藏页的 `SongRow` 相比：
///   · 去掉平台胶囊（下载页全是「本地」，那一枚没有信息量）；
///   · 去掉名次槽、`fixedSize`/`layoutPriority` 那一组布局修饰；
///   · 封面尺寸 52 → 48，其余字号沿用同一套 `FontRole`（视觉上仍是同一族）。
/// 功能一个不少：点整行起播（整列排队）、红心、多选勾选圈。
private struct DownloadRow: View {

    let item: DownloadItem
    let showsFavorite: Bool
    let isFavorite: Bool
    let onFavorite: () -> Void
    let isSelected: Bool?

    private var subtitle: String {
        "\(item.origin == "import" ? "本地导入 · " : "")\(item.quality.displayName) · \(item.sizeText)"
    }

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            if let isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isSelected ? Tokens.Palette.vermilion : Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }

            SongArtwork(song: item.song, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.song.name)
                    .font(FontRole.songTitle)
                    .lineLimit(1)
                Text(subtitle)
                    .font(FontRole.songSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Tokens.Spacing.xs)

            Text(item.song.durationText)
                .font(FontRole.metadata)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(minWidth: 36, alignment: .trailing)

            if showsFavorite {
                Button(action: onFavorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(isFavorite ? Tokens.Palette.vermilion : Color.secondary)
                        .minimumTapTarget()
                }
                .buttonStyle(.press)
                .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
            }
        }
        // 行高用 minHeight：AX5 时行要能长高
        .frame(minHeight: Tokens.Size.songRowHeight)
        .padding(.vertical, Tokens.Spacing.xxs)
        .padding(.horizontal, Tokens.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .onAppear { PerfProbe.firstRow("downloads") }
    }
}

/// 左滑删除 + 长按菜单：只有"露过脸"的行才挂（`enabled`）。
/// 没挂上的行照样能点、能看，只是暂时没有左滑 —— 行第一次出现的那一拍就会把 `enabled` 打开。
private struct DownloadRowActions: ViewModifier {

    let itemID: UUID
    let enabled: Bool
    let onDelete: (UUID) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        onDelete(itemID)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        onDelete(itemID)
                    } label: {
                        Label("删除下载", systemImage: "trash")
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - 内置导入浏览器（2026-11-21 第三次修导入：不再把系统选择器当唯一入口）

/// 老板这台机器上系统文件选择器的「打开」**按下去不回调**：
///   · 2026-11-19「保存位置」用 SwiftUI `.fileImporter`（选文件夹）→ 同一个死法，
///     当时改成"在 App 自己的文件夹里列表选"，成了；
///   · 2026-11-21 导入先 `.fileImporter`、再 UIKit 模态 `UIDocumentPickerViewController`，
///     两条完全不同的呈现路径，还是死在同一个按钮上。
/// 三条路死在同一个地方 ⇒ 不是我们的回调写错，是系统那层没把结果交回来。
/// 所以导入的主路径改成**先在本 App 的文件夹里挑**：
///   · `文件 › JZ 音乐` 就是本 App 的 Documents（`UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` 都已开）；
///   · 用「文件」App / LocalSend / 隔空投送 / 微信把歌放进去，这里直接列出来，勾选导入；
///   · 系统选择器降级成"还想试一下"的次选入口（下面 `DocumentPickerPresenter`）。
struct ImportBrowserView: View {

    /// 确认导入后交给下载页（那边统一走 `Task.detached` 的导入流程）
    let onImport: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var folder = DownloadLocation.documentsDirectory()
    @State private var entries: [Entry] = []
    @State private var selected: Set<String> = []
    @State private var hint: String?
    /// 正在后台扫目录（列表先空着，别在主线程上扫）
    @State private var scanning = false
    /// 只认最后一次扫描的结果（边翻目录边返回时，旧结果不能盖新的）
    @State private var scanToken = UUID()

    private let root = DownloadLocation.documentsDirectory()

    struct Entry: Identifiable {
        let url: URL
        let kind: ImportRules.BrowserKind
        /// 体积在**扫描时**就取好（以前是在 body 里 stat，行一多就卡）
        let sizeBytes: Int64
        var id: String { url.path }
        var isFolder: Bool { kind == .folder }
    }

    var body: some View {
        NavigationStack {
            List {
                // 提示条（选择器/扫描遇到问题时显示在最上面，两段入口都能看到）
                if let hint {
                    Section {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(Tokens.Palette.vermilion)
                    }
                }

                // ① 系统选择器 —— **第一种方式**
                //
                // 老板 2026-11-21 实测：这条路（UIKit 模态 + `asCopy: true`）能导成功。
                // 所以它回到第一位。唯一要提醒的是：点「打开」之后系统是在**复制**文件，
                // 选得多/文件大时要等几秒，看起来像"没反应"——不是死了。
                Section {
                    Button {
                        openSystemPicker()
                    } label: {
                        HStack(spacing: Tokens.Spacing.xs) {
                            Image(systemName: "square.and.arrow.down.on.square")
                            Text("选择文件导入")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity, minHeight: Tokens.Spacing.minTapTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets(top: Tokens.Spacing.xs,
                                              leading: Tokens.Spacing.pageMargin,
                                              bottom: Tokens.Spacing.xs,
                                              trailing: Tokens.Spacing.pageMargin))
                    .listRowBackground(Color.clear)
                    Text("点「打开」后如果像没反应，多半是系统在把文件复制进来（大文件要等几秒，选得多会更久）。选了就等它一下，别反复点。\n一次选 150 首以内最稳：iOS 只保证选择器的临时副本约 1 分钟可用，选太多会被系统清掉一半。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("从「文件」里选（推荐这条）")
                }

                // ② 从 App 自己的文件夹导入（不经过系统选择器）
                Section {
                    Text("系统选择器那次没成的话：先把歌放进「文件 › JZ 音乐」，这里会直接列出来，勾选后导入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        openFilesApp()
                    } label: {
                        Label("打开「文件」App（去放歌）", systemImage: "folder")
                    }
                    HStack(spacing: Tokens.Spacing.s) {
                        Button {
                            reload()
                        } label: {
                            Label(scanning ? "正在读取…" : "刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(scanning)
                        Spacer(minLength: 0)
                        if !audioEntries.isEmpty {
                            Button("全选本页 \(audioEntries.count) 首") {
                                selected = Set(audioEntries.map { $0.url.path })
                            }
                            .font(.footnote)
                        }
                    }
                    Button {
                        scanWholeContainer()
                    } label: {
                        Label("扫描整个「JZ 音乐」并导入", systemImage: "wand.and.stars")
                    }
                } header: {
                    Text("或者从「JZ 音乐」文件夹导入")
                } footer: {
                    Text("列表里只列能播的音频（mp3 / m4a / flac / wav / aiff…），图片、歌词、压缩包不会被选进来；ape / wma / ogg 这种 iOS 放不了的会灰掉并写明原因。同一个文件（字节一样）和同一首歌（同一条录音）会自动跳过，不会重复占地方。")
                }

                Section {
                    if folder.path != root.path {
                        Button {
                            goUp()
                        } label: {
                            Label("上一级", systemImage: "chevron.up")
                        }
                    }
                    if entries.isEmpty {
                        Text(scanning ? "正在读取这个文件夹…"
                                      : "这个文件夹里没有可导入的音频文件。用上面的「打开「文件」App」把歌放进 JZ 音乐，再点「刷新」。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        row(entry)
                    }
                } header: {
                    Text(pathText)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("导入本地音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(importTitle) { runImport() }
                        .disabled(selectedAudioURLs.isEmpty)
                }
            }
            .task { reload() }
        }
    }

    // MARK: 列表

    private var audioEntries: [Entry] { entries.filter { $0.kind == .audio } }

    private var selectedAudioURLs: [URL] {
        entries.filter { $0.kind == .audio && selected.contains($0.url.path) }.map(\.url)
    }

    private var importTitle: String {
        let n = selectedAudioURLs.count
        return n == 0 ? "导入" : "导入（\(n)）"
    }

    /// `文件 › JZ 音乐` + 当前子路径（老板一眼能对上「文件」App 里的那个文件夹）
    private var pathText: String {
        let base = "文件 › JZ 音乐"
        guard folder.path != root.path, folder.path.hasPrefix(root.path) else { return base }
        let rel = String(folder.path.dropFirst(root.path.count))
        let parts = rel.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        return ([base] + parts).joined(separator: " › ")
    }

    private func row(_ entry: Entry) -> some View {
        Button {
            switch entry.kind {
            case .folder:
                folder = entry.url
                selected.removeAll()
                hint = nil
                reload()
            case .audio:
                toggle(entry.url)
            case .unsupported:
                hint = "《\(entry.url.lastPathComponent)》iOS 放不了这种格式，导进来也播不出声，所以没让选。"
            case .other:
                break
            }
        } label: {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: iconName(for: entry))
                    .frame(width: 22)
                    .foregroundStyle(entry.kind == .unsupported
                                     ? Color.secondary
                                     : (entry.isFolder ? Tokens.Palette.vermilion : Color.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.url.lastPathComponent)
                        .font(.body)
                        .lineLimit(2)
                        .foregroundStyle(entry.kind == .unsupported ? Color.secondary : Color.primary)
                    Text(subtitle(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Tokens.Spacing.xs)
                if entry.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if entry.kind == .audio {
                    Image(systemName: selected.contains(entry.url.path)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(entry.url.path)
                                         ? Tokens.Palette.vermilion : Color.secondary.opacity(0.4))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconName(for entry: Entry) -> String {
        switch entry.kind {
        case .folder: return "folder"
        case .audio: return "music.note"
        case .unsupported: return "exclamationmark.triangle"
        case .other: return "doc"
        }
    }

    private func subtitle(for entry: Entry) -> String {
        switch entry.kind {
        case .folder:
            return "文件夹"
        case .audio:
            let ext = entry.url.pathExtension.uppercased()
            let size = ImportRules.browserSizeText(entry.sizeBytes)
            return size.isEmpty ? ext : "\(ext) · \(size)"
        case .unsupported:
            return "iOS 不支持这种格式（\(entry.url.pathExtension.uppercased())）"
        case .other:
            return ""
        }
    }

    // MARK: 动作

    /// 目录扫描 + 体积 stat 全在后台：以前在主线程上做，歌一多（几百个）就会"卡一下"
    private func reload() {
        let dir = folder
        let token = UUID()
        let label = pathText
        scanToken = token
        scanning = true
        Task.detached(priority: .userInitiated) {
            let list = Self.scan(dir)
            await MainActor.run {
                guard scanToken == token else { return }
                entries = list
                selected = selected.intersection(Set(list.map { $0.url.path }))
                scanning = false
                CrashReporter.logImport("browser: \(label) → \(list.count) 个条目")
            }
        }
    }

    /// 后台线程执行：列目录 + 取每个条目的体积（`resourceValues` 一次拿全，不再逐行 stat）
    private static func scan(_ dir: URL) -> [Entry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        var list: [Entry] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            let isDir = values?.isDirectory ?? false
            let kind = ImportRules.browserKind(name: url.lastPathComponent, isDirectory: isDir)
            guard kind != .other else { continue }
            let size = Int64(values?.fileSize ?? 0)
            list.append(Entry(url: url, kind: kind, sizeBytes: size))
        }
        list.sort {
            ImportRules.browserComesBefore($0.url.lastPathComponent, $0.isFolder,
                                           $1.url.lastPathComponent, $1.isFolder)
        }
        return list
    }

    private func toggle(_ url: URL) {
        if selected.contains(url.path) {
            selected.remove(url.path)
        } else {
            selected.insert(url.path)
        }
    }

    private func goUp() {
        guard folder.path != root.path else { return }
        folder = folder.deletingLastPathComponent()
        selected.removeAll()
        hint = nil
        reload()
    }

    private func runImport() {
        let urls = selectedAudioURLs
        guard !urls.isEmpty else { return }
        CrashReporter.logImport("browser: 勾选 \(urls.count) 首 → 交给导入流程")
        dismiss()
        onImport(urls)
    }

    /// 不管用户把歌丢在哪一层子文件夹，一次全扫进来
    private func scanWholeContainer() {
        hint = "正在扫描「JZ 音乐」…"
        Task.detached(priority: .userInitiated) {
            let files = DownloadManager.audioFilesInDocuments()
            await MainActor.run {
                guard !files.isEmpty else {
                    hint = "「JZ 音乐」里没找到能导入的音频。先把歌放进这个文件夹（用「文件」App 或 LocalSend），再回来点这一项。"
                    return
                }
                CrashReporter.logImport("browser: 全容器 \(files.count) 首 → 交给导入流程")
                hint = nil
                dismiss()
                onImport(files)
            }
        }
    }

    /// 直接跳到「文件」App：把歌拖进 JZ 音乐这一步不用用户自己找路径
    private func openFilesApp() {
        guard let url = URL(string: "shareddocuments://") else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            CrashReporter.logImport("browser: 打开「文件」App → \(ok ? "成功" : "失败")")
        }
    }

    private func openSystemPicker() {
        CrashReporter.logImport("picker: 用户点了「选择文件导入」")
        DocumentPickerPresenter.present(onFail: { message in
            hint = message
        }, onPick: { urls in
            guard !urls.isEmpty else { return }
            CrashReporter.logImport("picker: 收到 \(urls.count) 个 → 交给导入流程")
            dismiss()
            onImport(urls)
        })
    }
}

// MARK: - 系统文件选择器（次选入口：模态呈现 + 复制模式 + 全程日志）

/// 每步都写 `诊断/import.log`：请求 / 顶层 VC / 是否被占用 / 已呈现 / 回调 / 取消 / 放弃。
/// 上一次（v2.4.45）只改了呈现方式、没留痕，结果"还是没反应"时无法判断死在哪一步，
/// 这一版把"能不能弹、弹了有没有回调"分开记。
final class DocumentPickerPresenter: NSObject, UIDocumentPickerDelegate {

    /// present 期间保活（delegate 一旦释放，"打开"就会失效）
    private static var alive: DocumentPickerPresenter?

    private var onPick: (([URL]) -> Void)?
    private var onFail: ((String) -> Void)?

    static func present(onFail: @escaping (String) -> Void = { _ in },
                        onPick: @escaping ([URL]) -> Void) {
        CrashReporter.logImport("picker: 请求打开系统选择器")
        guard let host = topViewController() else {
            CrashReporter.logImport("picker: 找不到可用的顶层 VC → 放弃")
            onFail("系统选择器打不开（找不到窗口）。请用上面的文件夹列表导入。")
            return
        }
        CrashReporter.logImport("picker: 顶层 VC = \(type(of: host))")

        let presenter = DocumentPickerPresenter()
        presenter.onPick = onPick
        presenter.onFail = onFail
        alive = presenter

        // `asCopy: true`：让系统把选中的文件**复制**到我们的临时目录。
        // 上一版是 `asCopy: false`（就地打开），那条路要求文档提供方与我们的容器协商安全作用域，
        // 在老板这台机器上「打开」压根不回调（2026-11-19 的文件夹选择器是同一个死法）。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio, .item],
                                                    asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = presenter

        func giveUp(_ message: String) {
            CrashReporter.logImport("picker: 放弃 · \(message)")
            DocumentPickerPresenter.alive = nil
            onFail(message)
        }

        func attempt(_ triesLeft: Int) {
            if let busy = host.presentedViewController {
                guard triesLeft > 0 else {
                    giveUp("刚才有别的弹层压着（\(type(of: busy))），系统选择器没弹出来。请重试，或用上面的文件夹列表导入。")
                    return
                }
                CrashReporter.logImport("picker: 顶层被占用（\(type(of: busy))），0.3s 后重试")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { attempt(triesLeft - 1) }
                return
            }
            host.present(picker, animated: true) {
                CrashReporter.logImport("picker: 已呈现（等系统回调）")
            }
        }
        attempt(3)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: "、")
        CrashReporter.logImport("picker: 回调 \(urls.count) 个 → \(names)")
        let callback = onPick
        releaseSelf()
        controller.dismiss(animated: true) { callback?(urls) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        CrashReporter.logImport("picker: 用户取消")
        releaseSelf()
    }

    private func releaseSelf() {
        onPick = nil
        onFail = nil
        if DocumentPickerPresenter.alive === self { DocumentPickerPresenter.alive = nil }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

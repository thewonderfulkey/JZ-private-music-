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
//   · 左滑两条动作：「歌曲信息」（灰，左）+「删除」（红，右）。
//     第 47 轮（老板 2026-11-21）：长按菜单**下线**（它只在 `armed` 的前几行有效，
//     观感是"有的歌能改、有的不能"），编辑入口改成显式按钮；同时删掉重复的那份
//     `.swipeActions`（一行滑出两个垃圾桶的根源）。顺序见 `DownloadRowSwipe`。
struct DownloadsTabView: View {

    @EnvironmentObject private var downloads: DownloadManager
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router

    /// 第四十四轮：「定位到正在播放」的状态
    @State private var locator = SongLocator()
    /// 本地搜索（下载/导入都在这一页，按内容过滤，纯本地不联网）
    @State private var query = ""
    @State private var showDedupeConfirm = false
    /// 第 48/49 轮：把歌曲信息写回音频文件（老板：前台换了封面/信息，文件里还是旧的，要对齐）
    @State private var showSongInfoWriteConfirm = false
    /// 第 52 轮：未对齐明细（名单 + 可复制 + 可只重跑这些）
    @State private var showUnresolved = false
    /// 2026-11-22：存储自检（老板找不到那多出来的 18 GB）
    @State private var showStorageAudit = false
    /// 导入面板（内置浏览器；不经过系统选择器）
    @State private var deduping = false
    /// 一句话轻提示（"开始导入 N 个文件…"这种，1.5 秒后自己消失）
    @State private var notice: String?
    /// 多选态（2026-11-21 老板：多选 + 全选 + 批量删除）
    @State private var selectMode = false
    @State private var picked: Set<UUID> = []
    @State private var showBatchDeleteConfirm = false
    /// 第 47 轮：左滑「歌曲信息」的目标条目（nil = 不弹）
    @State private var editingItem: DownloadItem?
    /// 批量编辑（只改歌手/专辑）
    @State private var showBatchEdit = false
    /// 2026-11-23：还原修过的 FLAC 头（老板要求"可回滚"）

    // 2026-11-22：`gaps`（补全缺口计数）+「补全信息」入口已下线（老板：不准、也没见到效果）。
    // 每首歌「修改信息 → 保存」时的自动匹配（SongMetadataEditor → MetadataMatcher）不受影响。

    /// 第 41 轮 P0-2：首屏只建这么多行，滚到底/点「继续加载」再追加。
    /// 第 42 轮（真机 perf.log：80 行要 507–813ms ≈ 7–10ms/行）：**首帧只建 8 行**，
    /// 之后分块补到 `fillTarget`（每块 4 行，一旦出现 >150ms 的长停顿就停止自动补，
    /// 交给「继续加载」按钮 —— 保证验收口径 maxGap < 100ms）。
    @State private var visibleLimit = DownloadListPaging.firstFrame
    /// 自动补行是否还在跑
    @State private var fillScheduled = false
    /// 已经挂上左滑按钮的行（只有"要动手的那些行"才挂，见 `completedRow`）
    @State private var armed: Set<UUID> = []
    /// 「露脸即挂」的排队（2026-11-22）：同一拍里出现的几行合并成一次状态变更
    @State private var pendingArm: Set<UUID> = []
    @State private var armFlushScheduled = false
    /// 自动续加载的节流（同一帧里连开好几页就等于没分页）
    @State private var lastAutoLoadAt = Date.distantPast

    private var queryKey: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// **真正生效**的搜索词（2026-11-22）。
    ///
    /// 老板："663 首的时候，每输入一个字母就开始卡"。两个原因叠在一起：
    ///   ① 每敲一个字母，全表 663 首 × 4 个字段各归一化一次（繁简映射 + 两次正则），
    ///      而这几个列表在同一帧里还要被求值好几遍；
    ///   ② 字母一个个进来时，每一拍都完整重算一次，等于把一次输入变成 6 次全表扫描。
    /// 现在：输入框仍然实时回显（`query`），但**过滤**用 200ms 防抖之后的 `appliedQuery` ——
    /// 连续敲字时列表不动，停手才筛一次；配合 `DownloadsSearchCache` 的"每首歌只归一化一次"，
    /// 一拍只付 N 次 `contains`。
    @State private var appliedQuery = ""

    private var appliedQueryKey: String {
        appliedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 全表过滤 + 排序的缓存（一帧只算一次，见 `DownloadsSearchCache`）
    @State private var searchCache = DownloadsSearchCache()

    // MARK: 歌手筛选（2026-11-23）

    /// 当前选中的歌手（`nil` = 全部）。**只按歌手一个维度**，老板 2026-11-23 定稿：
    /// "下载 tab 只增加一个筛选选项：歌手，每一首歌的歌手名称都是对的，人工修改过。"
    @State private var artistFilter: String?
    /// 是否打开「全部歌手」列表
    @State private var showArtistPicker = false
    /// 歌手聚合的缓存（664 首不能每帧算一遍，见 `DownloadsArtistIndex`）
    @State private var artistIndex = DownloadsArtistIndex()

    private var artistGroups: [DownloadArtistGroup] {
        artistIndex.groups(items: downloads.items, revision: downloads.revision)
    }

    /// 顶部横条只放前几位（其余的在「全部歌手」里）
    private var topArtistGroups: [DownloadArtistGroup] {
        Array(artistGroups.prefix(12))
    }

    /// 横条上真正铺的胶囊：前 12 位；如果当前选中的歌手不在前 12 位（从「全部歌手」里挑的），
    /// 就把它临时插到最前面——否则会出现"筛着某人、却一个胶囊都没高亮"的怪状态。
    private var chipGroups: [DownloadArtistGroup] {
        if let artist = artistFilter,
           !topArtistGroups.contains(where: { $0.name == artist }),
           let selected = artistGroups.first(where: { $0.name == artist }) {
            return [selected] + topArtistGroups
        }
        return topArtistGroups
    }

    /// 库里一共多少首已下载（胶囊「全部」和「全部歌手」上的总数）
    private var artistTotalCount: Int {
        artistGroups.reduce(0) { $0 + $1.count }
    }

    private var lists: (ongoing: [DownloadItem], finished: [DownloadItem], failed: [DownloadItem]) {
        searchCache.lists(items: downloads.items, revision: downloads.revision,
                           query: appliedQueryKey, artist: artistFilter)
    }

    private var ongoing: [DownloadItem] { lists.ongoing }
    private var finished: [DownloadItem] { lists.finished }
    private var failed: [DownloadItem] { lists.failed }

    private var totalBytes: Int64 {
        downloads.items.reduce(0) { $0 + $1.totalBytes }
    }

    /// 写回会被处理到的条数（确认弹窗里先告诉老板"要动多少首"）
    private var songInfoWriteTargets: Int {
        downloads.items.filter { $0.status == .completed && $0.localPath != nil }.count
    }

    /// 同一时刻只弹一个结果框（写回 / 对齐检查），谁先到弹谁 —— 两个 `.alert` 挂同一个视图
    /// 在 SwiftUI 里会互相打架，所以这里合成一个。
    private var activeReport: (title: String, message: String)? {
        if let text = downloads.lastFileStateReport { return ("文件对齐检查", text) }
        if let text = downloads.lastSongInfoWriteReport { return ("歌曲信息写回", text) }
        return nil
    }

    private func clearReports() {
        downloads.lastFileStateReport = nil
        downloads.lastSongInfoWriteReport = nil
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
        // 2026-11-22：`ImportBrowserView`（从「JZ 音乐」文件夹导入）入口已下线——
        // 老板：有了「导入本地音乐（选择文件）」就不需要第二条进同一个导入器的路。
        // 视图代码留着（`ImportBrowserView` 还在文件末尾），要恢复只加回一个 Button + sheet 即可。
        // 第 44 轮引入、第 47 轮改为左滑「歌曲信息」→ 编辑歌曲信息（歌名/歌手/专辑/封面）
        .sheet(item: $editingItem) { item in
            // 保存后编辑页立刻关，结果用列表页的轻提示回话（第 45 轮）
            SongMetadataEditor(item: item, onSaved: { message in flash(message) })
        }
        // 批量编辑：只允许统一改歌手/专辑（歌名、封面不批量）
        .sheet(isPresented: $showBatchEdit) {
            BatchMetadataEditor(items: downloads.items.filter { picked.contains($0.id) })
        }
        .alert("导入", isPresented: Binding(
            get: { downloads.lastImportReport != nil },
            set: { if !$0 { downloads.lastImportReport = nil } })) {
            Button("好") { downloads.lastImportReport = nil }
        } message: {
            Text(downloads.lastImportReport ?? "")
        }
        .confirmationDialog("把同一首歌的多条合成一条？（只留音质更好的）",                            isPresented: $showDedupeConfirm, titleVisibility: .visible) {
            Button("整理", role: .destructive) {
                // 2026-11-22：改成异步 + 后台比对 + 一次性落库。
                // 旧实现是主线程 O(n²)（664 首 ≈ 22 万次「同一条录音」判定，每次都要繁简映射 +
                // 两次正则），点下去就是 10 秒卡死。现在只卡在"比对"的几毫秒，界面不冻结。
                deduping = true
                Task {
                    let r = await downloads.dedupeSameRecording()
                    deduping = false
                    downloads.lastImportReport = r.merged == 0
                        ? "没有需要整理的重复"
                        : "已合并 \(r.merged) 条，释放 "
                          + ByteCountFormatter.string(fromByteCount: r.freedBytes, countStyle: .file)
                }
            }
            Button("取消", role: .cancel) {}
        }
        // 第 48/49 轮：把歌曲信息写回音频文件（老板："本地的后台文件封面并没有和前端内置的对齐"，
        // 随后又问"能不能封面、歌名、歌手、专辑还有音频信息一起写进文件"）
        .confirmationDialog("把现在显示的歌曲信息写进音频文件？",
                            isPresented: $showSongInfoWriteConfirm, titleVisibility: .visible) {
            Button("开始写回") {
                let n = downloads.writeSongInfoToFiles()
                if n == 0 { flash("没有可写回的歌") }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将处理 \(songInfoWriteTargets) 首：歌名 / 歌手 / 专辑 / 时长 / 封面 / 歌词"
                 + "一起写进音频文件本身（别的标签和音频本身一个字节都不动）。"
                 + "文件里已经是这一套的会跳过；没有封面的会顺便补上 Cover 旁车。")
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
        .onChange(of: appliedQueryKey) { _, _ in
            visibleLimit = DownloadListPaging.firstFrame
            fillScheduled = false
            scheduleFill()
        }
        // 2026-11-23 歌手筛选：任何一条改筛选的路径（胶囊 / 全部歌手 / 定位自动清掉）
        // 都走这里 —— 选择范围一变小，多选和"已挂交互"的集合必须跟着收，不然会删到看不见的歌。
        .onChange(of: artistFilter) { _, _ in
            picked = BatchSelection.pruning(picked, visible: visibleIDs)
            armed.formIntersection(visibleIDs)
            visibleLimit = DownloadListPaging.firstFrame
            fillScheduled = false
            scheduleFill()
        }
        // 库变了（删歌 / 批量改歌手）：这位歌手已经不存在了就把筛选退回「全部」，
        // 不留一个"空着但还写着周杰伦"的列表。
        .onChange(of: downloads.revision) { _, _ in
            if let artist = artistFilter,
               !DownloadArtistFilter.contains(artist, in: downloads.items) {
                artistFilter = nil
            }
        }
        // 2026-11-22（老板：663 首时每敲一个字母就卡）：输入防抖 200ms。
        // `query` 驱动输入框回显（必须实时），`appliedQuery` 才是过滤依据。
        // `.task(id:)` 在 id 变化时自动取消上一拍——连着敲 5 个字母只筛 1 次。
        .task(id: query) {
            guard query != appliedQuery else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            appliedQuery = query
        }
        // 第 47 轮兜底：**行数一变就 arm**。
        // 以前 arm 只跟着 `fillStep` / `loadMore` 走，而 `revealRowForCurrentSong()`（「定位」）
        // 会把 visibleLimit 从 8 一路撑到 104 却完全不 arm —— 那一屏有 84 行能显示、
        // 只有前 6 行挂了左滑，其余长按/左滑都没反应。挂在这里就不再有"漏 arm"的路径。
        .onChange(of: visibleLimit) { _, _ in
            armVisibleRows()
        }
        // 2026-11-22（老板：新下的歌横拉要等一会儿才灵）：**下载完成不改 items.count**，
        // 只是把条目从「正在下载」挪进「已下载」，所以上面两条 arm 都不会触发。
        // 这一条盯住"已下载多了一行"，当场把它挂上左滑。
        .onChange(of: paged.finished.count) { _, _ in
            armVisibleRows()
        }
        // 2026-11-22：原来这里有个 1.2 秒后跑「补全缺口计数（662 次 stat）」的 task，
        // 只为给已下线的「补全信息」按钮凑文案 —— 一并删掉，少一次全表扫盘。
        .locateToast(notice)
    }

    /// 工具栏上的三个点（2026-11-22 老板精简：「从 JZ 音乐文件夹导入」和「补全信息」都下线）
    ///
    /// 下线理由（老板原话）：
    ///   · 有了「导入本地音乐（选择文件）」就没必要再有「从文件夹导入」——两条路进同一个导入器；
    ///   · 「补全信息」不准、也没见到实际效果，不如他在每首歌上「修改信息 → 保存」时自动匹配来得快，
    ///     所以只保留后者（`SongMetadataEditor` → `MetadataMatcher`，那条链路一个字没动）。
    private var importMenu: some View {
        Menu {
            Button {
                pickFilesFromMenu()
            } label: {
                Label("导入本地音乐（选择文件）", systemImage: "square.and.arrow.down")
            }
            Button {
                showDedupeConfirm = true
            } label: {
                Label(deduping ? "正在整理重复…" : "整理重复（同曲留最高音质）",
                      systemImage: "rectangle.stack.badge.minus")
            }
            .disabled(deduping)
            Divider()
            // 第 51 轮 A 方案：只读检查（不写文件），给每行算出"文件里 vs 列表上"的小圆点。
            Button {
                let n = downloads.scanFileStates()
                flash(n == 0 ? "没有可检查的歌" : "开始检查 \(n) 首…")
            } label: {
                Label("检查文件对齐（封面/标签/歌词）",
                      systemImage: "doc.text.magnifyingglass")
            }
            Divider()
            // 2026-11-22（老板："空间从 20 多 G 变 40 多 G，我找不到多余的文件"）：
            // 把"磁盘上到底被什么占了"摊开给他看，并给出三类**可安全删除**的残留。
            Button {
                showStorageAudit = true
            } label: {
                Label("存储自检（空间被谁占了）", systemImage: "internaldrive")
            }
            Divider()
            // 第 48/49 轮：把**列表上显示的这一套**写进音频文件本身。
            // 和上面「补全信息」不是一回事：那个是联网去**取**，这个是**把已有的写进文件**。
            Button {
                showSongInfoWriteConfirm = true
            } label: {
                Label("把歌曲信息写进音频文件（封面/歌名/歌手/专辑）",
                      systemImage: "square.and.arrow.down.on.square")
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

    /// 写回 / 对齐检查的进度条（第 48/49 轮 + 第 51 轮）。662 首要跑几十秒到几分钟，
    /// **必须有进度**，否则老板会以为"点了没反应"，中途划走 App 也会被系统挂起。
    @ViewBuilder
    private var songInfoWriteBanner: some View {
        if let p = downloads.songInfoWriteProgress {
            writeProgressRow(title: "正在写回歌曲信息", progress: p,
                             onStop: { downloads.cancelSongInfoWrite() })
        } else if let p = downloads.fileStateScanProgress {
            writeProgressRow(title: "正在检查文件对齐", progress: p, onStop: nil)
        }
    }

    private func writeProgressRow(title: String,
                                  progress p: DownloadManager.SongInfoWriteProgress,
                                  onStop: (() -> Void)?) -> some View {
        HStack(spacing: Tokens.Spacing.xs) {
            ProgressView().scaleEffect(0.8)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(title) \(min(p.done + 1, p.total))/\(p.total)")
                    .font(.footnote.weight(.semibold))
                Text(p.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let onStop {
                Button("停止", action: onStop)
                    .font(.footnote)
                    .buttonStyle(.press)
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.vertical, Tokens.Spacing.xs)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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

                songInfoWriteBanner
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
                                // 第 47 轮（老板 2026-11-21 截屏：一行两个红色垃圾桶）：
                                // 这里本来还有一份 `.swipeActions`，和 `DownloadRowActions` 里那份重复，
                                // 两份都被 SwiftUI 画了出来。现在左滑按钮**只在 `DownloadRowActions` 里定义一次**。
                                // 第 42 轮：**去掉** `.id(uuidString)`。
                                // 行本身就是 `ForEach(finished)` 的元素，identity 已经是 `item.id`；
                                // 再挂一层 String id 等于每行每帧多一次身份重算（真机上这层很贵）。
                                // `ScrollViewReader.scrollTo` 直接认元素 id（UUID），见下面的「定位」。
                        }
                    } header: {
                        sectionHeader(finishedHeaderText)
                    }
                }

                // 2026-11-23：筛着的这位歌手已经一首都没有了（删光了 / 改了歌手名）——
                // 说清楚，别让人对着一片空白以为歌丢了。`revision` 变化时也会自动退回「全部」。
                if artistFilter != nil,
                   paged.ongoing.isEmpty, paged.failed.isEmpty, paged.finished.isEmpty {
                    Text("这位歌手名下已经没有已下载的歌了。点上面的「全部」看整个库。")
                        .font(FontRole.metadata)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.Spacing.pageMargin)
                        .padding(.vertical, Tokens.Spacing.m)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
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
                // 第 42 轮：首帧挂完，下一拍开始分块补行（并给这几行挂上左滑）
                DispatchQueue.main.async { armVisibleRows() }
                scheduleFill()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: listBottomClearance)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // 批量操作条浮在**迷你条上沿**：迷你条是父视图的 overlay，
            // 直接把操作条放 safeAreaInset 里会被它盖住（下载页经常在播歌）。
            .overlay(alignment: .bottom) {
                if batchBarVisible {
                    batchBar
                        .padding(.bottom, CGFloat(MiniPlayerMetrics.batchBarBottomInset(
                            playing: player.hasCurrentSong)))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(Tokens.Motion.stateChange, value: batchBarVisible)
            .locateToast(locator.toast)
            // 第 48/49 轮：写回结果；第 51 轮：对齐检查结果也走这一个框（一项都不许吞）
            .alert(activeReport?.title ?? "结果", isPresented: Binding(
                get: { activeReport != nil },
                set: { if !$0 { clearReports() } })) {
                Button("好") { clearReports() }
                if !downloads.lastUnresolved.isEmpty {
                    Button("查看明细（\(downloads.lastUnresolved.count) 首）") {
                        clearReports()
                        // alert 自己要点一下才消失，等它退场再弹 sheet
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showUnresolved = true
                        }
                    }
                }
            } message: {
                Text(activeReport?.message ?? "")
            }
            // 第 52 轮：未对齐名单（可复制给开发、可只重跑这些）
            .sheet(isPresented: $showUnresolved) {
                UnresolvedListSheet()
                    .environmentObject(downloads)
            }
            // 2026-11-22：存储自检（空间被谁占了 / 三类可安全删除的残留）
            .sheet(isPresented: $showStorageAudit) {
                StorageAuditSheet()
                    .environmentObject(downloads)
            }
            // 2026-11-23：全部歌手（这个库可能有 300+ 位，靠横条翻不现实）
            .sheet(isPresented: $showArtistPicker) {
                ArtistPickerSheet(groups: artistGroups,
                                  total: artistTotalCount,
                                  selected: artistFilter) { name in
                    showArtistPicker = false
                    setArtist(name)
                }
            }
            // 2026-11-27（老板）：搜索框要**滚动时常驻**，不能一滑就被原生搜索栏收走。
        // `.navigationBarDrawer(displayMode: .always)` 是系统自带的"常驻"模式——
        // 不另造输入框（本页原有防抖过滤/歌手筛选/首帧分批一概不动）。
        .searchable(text: $query, prompt: "搜歌名 / 歌手 / 专辑 / 文件名",
                    placement: .navigationBarDrawer(displayMode: .always))
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
                            locateNowPlaying(proxy: proxy)
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
        // 筛了歌手就把歌手名放进分区标题：滚过头部之后仍然知道"现在只看的是谁"
        let scope = artistFilter.map { "\($0)" } ?? "已下载"
        return shown < finished.count
            ? "\(scope)（\(finished.count) · 已显示 \(shown)）"
            : "\(scope)（\(finished.count)）"
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
            if !appliedQueryKey.isEmpty {
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

    /// 只给"真的要动手的行"挂左滑按钮（第 47 轮：长按菜单已下线，这里只剩左滑）。
    ///
    /// **不变式（第 47 轮补的账）**：`armed` 必须恒等于 `paged.allIDs`（当前真正渲染的那些行）。
    /// 以前它只靠三个调用点（`.onAppear` / `fillStep` / `loadMore`）喂，
    /// 而 `revealRowForCurrentSong()`（「定位」）会把 `visibleLimit` 撑到几百行**却不 arm**——
    /// 老板 21:16 录屏里「第 1–6 行有菜单、第 7 行往后按住 1.5 秒也没反应」就是这么来的
    /// （8 行预算里 2 行给了失败区，首帧只 arm 到 6 首；剩下都能显示、都没挂交互）。
    /// 现在多一条兜底：`visibleLimit` 一变就 arm（见 body 里的 `.onChange(of: visibleLimit)`），
    /// 任何"行数涨了"的路径都不会漏。
    private func armVisibleRows() {
        let next = armed.union(DownloadListPaging.renderedIDs(ongoing: ongoing, failed: failed,
                                                              finished: finished,
                                                              limit: visibleLimit))
        if next.count != armed.count { armed = next }
    }

    /// 行级「露脸即挂左滑」（2026-11-22 老板：新下的歌立刻横拉没反应，过一会儿才行）。
    ///
    /// 根因：`armed` 只由 `.onAppear`（列表级）/ `visibleLimit` 变化 / `fillStep` / `loadMore`
    /// 这几条路径喂。而**下载完成**这件事：`items` 只是把条目从 `ongoing` 挪到 `finished`，
    /// `items.count` 不变、`visibleLimit` 也不变 —— 上面四条一条都不触发，
    /// 于是新行明明画出来了，`armed` 里却没有它 → `DownloadRowActions` 走 `enabled == false`
    /// 那一支，横拉没有任何反应。要等到下一次 arm（切走再回来 / 继续加载 / 定位）才"突然又能拉"。
    ///
    /// 现在每行自己在 `onAppear` 里排进 `pendingArm`，下一拍合并成**一次**状态变更再挂上：
    /// 既覆盖"新行出现"，也不会因为一屏几十行各写一次 `armed` 而抖。
    private func armOnAppear(_ id: UUID) {
        guard !armed.contains(id) else { return }
        pendingArm.insert(id)
        guard !armFlushScheduled else { return }
        armFlushScheduled = true
        DispatchQueue.main.async {
            armFlushScheduled = false
            let batch = pendingArm
            pendingArm.removeAll()
            guard !batch.isEmpty else { return }
            armed.formUnion(batch)
        }
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

    // MARK: 「定位到正在播放」（2026-11-23 修：以前滚到镜像行 / 越界后干脆不滚）

    /// 点一下「定位」：该切筛选就切、该撑行数就撑，最后滚到正在播放那一行并闪一下。
    ///
    /// 两个真机 bug（2026-11-23 20:57 录屏，"筛选切回全部了，但没滚过去"）：
    ///   ① `songs` 用的是 `downloads.completedSongs`（全库 + 落库顺序），`rowIDs` 用的是
    ///      `finished`（显示顺序 + 已筛选）—— 下标在两套顺序之间搬运，顺序相反时滚到**镜像行**，
    ///      筛了歌手后长度还不同，越界后 `scrollTo` 静默空转。现在两边只从 `ListLocate.pair` 出。
    ///   ② 清筛选与"撑行数 + 滚"挤在同一拍：`onChange(of: artistFilter)` 会把分页打回首帧，
    ///      刚撑开的行又没了，目标行根本没被建出来 → 滚不动。现在清完**下一拍**再滚。
    private func locateNowPlaying(proxy: ScrollViewProxy) {
        guard let current = player.currentSong else {
            locator.notice("还没有在播放的歌")
            return
        }

        // ① 筛着别的歌手：先退回「全部」，下一拍再滚（理由见方法注释第 ②）
        if let artist = artistFilter,
           DownloadArtistFilter.artistKey(current.singer) != artist {
            // 这首压根不在下载里：切回全部也滚不到，别白清掉用户正在用的筛选，只说一句实话
            guard ListLocate.index(of: current, in: downloads.completedSongs) != nil else {
                locator.notice("《\(current.name)》不在下载里")
                return
            }
            artistFilter = nil
            DispatchQueue.main.async { self.locateNowPlaying(proxy: proxy) }
            return
        }

        // ② 行可能还没被建出来（分页在首帧）：先把 limit 撑到那一行，再滚（下一帧才有这行）
        let revealed = revealRowForCurrentSong()
        let scrollToCurrent = {
            // ③ 两列同源同序：显示顺序（新→老），而且就是当前筛选之后的那一份
            let pair = ListLocate.pair(finished)
            locator.locate(current: current,
                           songs: pair.songs,
                           rowIDs: pair.rowIDs,
                           scroll: { id in proxy.scrollTo(id, anchor: .center) })
        }
        if revealed {
            DispatchQueue.main.async(execute: scrollToCurrent)
        } else {
            scrollToCurrent()
        }
    }

    // MARK: 多选（2026-11-21 老板：多选按钮 + 全选 + 批量删除）

    /// 当前可见（受搜索过滤）的全部行 id —— 「全选」只作用于看得见的这些
    private var visibleIDs: [UUID] { (ongoing + failed + finished).map(\.id) }

    private var allSelected: Bool {
        BatchSelection.isAllSelected(picked: picked, visible: visibleIDs)
    }

    /// 处理栏出不出现：多选态**且至少选了一首**（2026-11-23 老板口径，见 `BatchSelection.isBarVisible`）
    private var batchBarVisible: Bool {
        BatchSelection.isBarVisible(selectMode: selectMode, pickedCount: picked.count)
    }

    /// 列表滚到底时该让出的高度：迷你条 + 处理栏（两条是叠着的，不重叠）。
    ///
    /// 以前这里恒等于 `MiniPlayerClearance`（只算迷你条），处理栏一出现就压在最后一条歌上；
    /// 现在把处理栏也算进来，滚到底最后一条正好停在上沿（与 r63"严丝合缝"同一口径）。
    private var listBottomClearance: CGFloat {
        let playing = player.hasCurrentSong
        let base = CGFloat(MiniPlayerMetrics.listBottomInset(playing: playing))
        guard batchBarVisible else { return base }
        return max(base,
                   CGFloat(MiniPlayerMetrics.batchBarBottomInset(playing: playing)
                           + MiniPlayerMetrics.batchBarHeight))
    }

    /// 底部批量操作条（2026-11-23 老板口径）
    ///
    /// 老板原话："点击多选后，还没选歌的时候不要出现那个处理栏，至少选中一条歌之后再出现；
    /// 其次处理栏我希望跟播放悬浮栏严丝合缝（如果播放栏显示的话），
    /// 当没有播放歌曲的时候我希望处理栏和底层栏严丝合缝。"
    ///
    /// 所以：
    ///   · 出现条件 = `batchBarVisible`（没选歌时整条不挂）；
    ///   · 横向内缩量与迷你条**完全一致**（`Spacing.xs`）——两条同宽，边上才没有台阶；
    ///   · 底边贴到迷你条卡片上沿 / 底层栏上沿（`batchBarBottomInset`），底两角不圆、
    ///     顶两角用卡片圆角 —— 读起来是"迷你条上面长出来的一条"，不是浮在空中的灰带；
    ///   · 底色换成和迷你条同一块 `paperElevated`（原来是半透明材质，底下滚过的歌会透上来）；
    ///   · 高度固定在 `batchBarHeight`，和列表让出的高度共用同一个数。
    private var batchBar: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Text("已选 \(picked.count) 首")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, Tokens.Spacing.xs)
            Spacer(minLength: 0)
            // 第 44 轮：批量编辑（只改歌手/专辑；歌名与封面不批量）
            Button {
                showBatchEdit = true
            } label: {
                Label("编辑", systemImage: "pencil")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, Tokens.Spacing.m)
                    .frame(minHeight: Tokens.Spacing.minTapTarget)
            }
            .buttonStyle(.press)
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
            .padding(.trailing, Tokens.Spacing.xs)
        }
        // 高度用 min/max 一起钉死：`.frame(maxWidth:)` 与 `.frame(height:)` 叠着写时，
        // 底色是画在**内层**那个 frame 上的，而它只有 HStack 的 44 高 —— 上下会各露 4pt 透明缝。
        .frame(maxWidth: .infinity,
               minHeight: CGFloat(MiniPlayerMetrics.batchBarHeight),
               maxHeight: CGFloat(MiniPlayerMetrics.batchBarHeight))
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: Tokens.Radius.card,
                                                      bottomLeading: 0,
                                                      bottomTrailing: 0,
                                                      topTrailing: Tokens.Radius.card),
                                   style: .continuous)
                .fill(Tokens.Palette.paperElevated)
        )
        // 与迷你条卡片同一条左右边线
        .padding(.horizontal, Tokens.Spacing.xs)
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
                    Text(headerSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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

            artistFilterBar
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.vertical, Tokens.Spacing.m)
    }

    // MARK: 歌手筛选条（2026-11-23）

    /// 横滑的一排歌手胶囊：`全部` + 条数最多的前 12 位 + `全部歌手`。
    ///
    /// 为什么是"前 12 位 + 全部歌手"而不是把所有歌手都铺开：这个库 664 首、可能有 300+ 位歌手，
    /// 全铺开就是一条几百个胶囊的长龙，反而找不到。常听的那几位一定在头部（按条数降序）。
    private var artistFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.xs) {
                artistChip(name: nil, title: "全部", count: artistTotalCount)
                ForEach(chipGroups) { group in
                    artistChip(name: group.name, title: group.name, count: group.count)
                }
                Button {
                    showArtistPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text("全部歌手")
                            .font(.footnote)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: Tokens.Spacing.minTapTarget)
                    .background(Capsule().fill(Tokens.Palette.paperElevated))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                }
                .buttonStyle(.press)
                .accessibilityLabel("全部歌手，共 \(artistGroups.count) 位")
            }
            // 内边距放在**滚动内容**上：这样第一个胶囊跟页面正文对齐，
            // 而滑到最后一个时能一路滑到屏幕边缘（横滑条常见做法）。
            .padding(.horizontal, Tokens.Spacing.pageMargin)
        }
        // 横滑条贴到页面左右边缘（外面那层 header 已经加过页边距，这里抵掉）
        .padding(.horizontal, -Tokens.Spacing.pageMargin)
    }

    /// 单个歌手胶囊（`name == nil` 就是「全部」）
    private func artistChip(name: String?, title: String, count: Int) -> some View {
        let active = artistFilter == name
        return Button {
            setArtist(name)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.footnote.weight(active ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(active ? Color.white.opacity(0.85) : Color.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: Tokens.Spacing.minTapTarget)
            .background(
                Capsule().fill(active ? Tokens.Palette.vermilion : Tokens.Palette.paperElevated)
            )
            .overlay(
                Capsule().strokeBorder(
                    active ? Color.clear : Color.primary.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(.press)
        .accessibilityLabel(name.map { "\($0)，\(count) 首" } ?? "全部歌手，\(count) 首")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    /// 切换歌手筛选：**顺手把分页打回首帧**。
    ///
    /// 不打回的话，上一轮为「全部」补到 400 行的 `visibleLimit` 会原样带过来，
    /// 筛成 20 首之后仍然一次建 20 行（无所谓），但反过来从"某歌手"切回"全部"时
    /// 会把上一次的 400 行预算直接套上——首帧就建 400 行，正是第 41/42 轮花了几版才压掉的那种卡。
    private func setArtist(_ name: String?) {
        guard artistFilter != name else { return }
        artistFilter = name
        visibleLimit = DownloadListPaging.firstFrame
        fillScheduled = false
        scheduleFill()
    }

    /// 头顶那行小字：筛了歌手就把名字和总时长顶上（"周杰伦 · 37 首 · 2 小时 41 分 · 486 MB"）
    private var headerSummary: String {
        var parts: [String] = []
        if let artistFilter { parts.append(artistFilter) }
        parts.append("\(finished.count) 首")
        let seconds = scopeSeconds
        if seconds > 0 { parts.append(durationText(seconds)) }
        parts.append(sizeText(scopeBytes))
        if paged.hasMore { parts.append("已显示 \(paged.shown)") }
        return parts.joined(separator: " · ")
    }

    /// 当前筛选范围里的字节数（未筛选时跟原来一样算全库）
    private var scopeBytes: Int64 {
        artistFilter == nil ? totalBytes : finished.reduce(0) { $0 + $1.totalBytes }
    }

    private var scopeSeconds: Int {
        finished.reduce(0) { $0 + max(0, $1.song.durationSec) }
    }

    private func durationText(_ seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时" }
        return "\(max(1, m)) 分钟"
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
                // 2026-11-23：筛着歌手时，点一首歌之后的下一首也留在这个人身上
                //（与「播放全部」同一口径——筛了谁就是"只听这位歌手"）
                let queue = scopeSongs
                if let index = queue.firstIndex(where: { $0.id == item.song.id }) {
                    player.play(queue: queue, startAt: index)
                } else {
                    player.playSingle(item.song)
                }
                router.showPlayer = true
            }
        } label: {
            DownloadRow(item: item,
                        // 第 46 轮（老板 2026-11-21）：下载页**不放红心**——这一页是"我下载了什么"，
                        // 收藏在「我的收藏」和搜索/榜单里做。顺手把行右侧那个内嵌按钮去掉，
                        // 副行的「歌手 · 专辑」也能多出一点宽度。
                        isSelected: selectMode ? picked.contains(item.id) : nil)
                .padding(.horizontal, Tokens.Spacing.pageMargin)
        }
        .buttonStyle(.rowPress)
        // 2026-11-22：行一露脸就排队挂左滑（不等列表级 arm 的下一次触发）。
        .onAppear { armOnAppear(item.id) }
        // 第 42 轮：左滑按钮只在"露过脸的行"（`armed`）上挂 —— 80 行就是 80 份交互修饰符，
        // 而真正会被左滑的只有看得见的那些。
        // 第 47 轮：`armed` 现在由 `.onChange(of: visibleLimit)` 兜底（见 body），
        // 恒等于 `paged.allIDs`，所以"能看见的行"就一定有左滑，不会再有"这行能、下一行不能"。
        .modifier(DownloadRowActions(itemID: item.id, enabled: interactive, onDelete: { id in
            downloads.remove(itemID: id, deleteFile: true)
        }, onEdit: { id in
            editingItem = downloads.items.first(where: { $0.id == id })
        }))
        // 2026-11-23：定位成功那一行闪一下。以前这一页**根本没挂**这个修饰符
        //（其它 8 个列表页都有），所以就算滚对了也看不出"定到哪了"。
        .locatedFlash(active: locator.isHighlighted(item.song))
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
            // 多选态：点整行 = 勾选/取消（平时这一行没有点击行为，只有左滑）
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

    /// 「播放全部 / 随机」的作用范围 = **当前筛选范围**（2026-11-23）。
    ///
    /// 没筛歌手时跟以前完全一样（全库）；筛了某位歌手，这两个键就变成
    /// "把这位歌手下载的歌全放一遍"——老板要的正是这件事，不用再回长列表里一首首点。
    ///
    /// 2026-11-24（老板）：「新下载的歌显示在最上面，但列表循环时却倒着放上一首」。
    /// 根因：列表排序只做在展示层（`newestFirst`），播放队列却用的是落库顺序
    /// （`DownloadManager.completedSongs`，最老的在前）—— 两边顺序相反。
    /// 现在队列**直接用展示顺序**（同样按 `newestFirst`），不分页、不受首屏限制，
    /// 所以"看到的第几首"就是"循环时的第几首"。
    private var scopeSongs: [Song] {
        let completed = downloads.items.filter { $0.status == .completed }
        let scoped = DownloadArtistFilter.filter(completed, artist: artistFilter)
        return DownloadItem.newestFirst(scoped).map(\.song)
    }

    private func playAll(shuffle: Bool) {
        let songs = scopeSongs
        guard !songs.isEmpty else { return }
        if shuffle {
            // 抽一首直接起播，不弹播放页（停在下载页看底部悬浮条）
            player.replaceQueue(songs, shuffle: true)
            return
        }
        player.play(queue: songs, startAt: 0)
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
/// 功能：点整行起播（整列排队）、多选勾选圈。
///
/// 第 46 轮（老板 2026-11-21）：**红心去掉** —— "下载页的所有歌曲不需要放置爱心、收藏功能"。
/// 这一页只负责"我下载了什么"；收藏入口留在「我的收藏」/ 搜索 / 榜单 / 歌手页。
private struct DownloadRow: View {

    let item: DownloadItem
    let isSelected: Bool?

    /// 副行 = **歌手 · 专辑**（第 44 轮 B6：跟全 App 其它列表一致）。    ///
    /// 以前这里写的是「本地导入 · 无损 FLAC · 27.3 MB」，占了歌手的位置 —— 老板看图后的原话是
    /// "歌手显示本地导入、专辑显示无损 FLAC"，实际是信息位错位，不是数据被写脏。
    /// 音质/大小改到右侧小字（`qualityLine`），来源只留一个「本地」胶囊感的细字。
    /// 右侧显示的时长：列表上写的那个（跟接口/文件元数据一致）。
    ///
    /// 2026-11-23 修复：以前这里优先显示"我们自己标定的实测时长"，那套数已经删掉了——
    /// 进度条和列表现在都只用播放器/文件自己的值，不再有两把尺子。
    private var displayDurationText: String {
        item.song.durationText
    }

    private var artistLine: String {
        let singer = item.song.singer.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = item.song.album.trimmingCharacters(in: .whitespacesAndNewlines)
        if singer.isEmpty && album.isEmpty { return "未知歌手" }
        if album.isEmpty { return singer }
        if singer.isEmpty { return album }
        return "\(singer) · \(album)"
    }

    /// 落盘这一份的**实测码率**：体积 ÷ 时长。算不出就回 0（行上只写档位名）。
    private var measuredKbps: Int64 {
        let dur = item.song.durationSec
        guard dur > 0, item.totalBytes > 0 else { return 0 }
        return item.totalBytes * 8 / Int64(dur) / 1000
    }

    /// 右侧小字：`无损 FLAC · 27.3 MB`（本地导入再加个"本地"前缀，信息不丢）
    private var qualityLine: String {
        let head = item.origin == "import" ? "本地 · " : ""
        // 2026-11-26（老板 ⑧）：档位名要带实测码率。以前这里只写「标准 128k · 2.6 MB」，
        // 而实际存下来的是 96kbps，看起来就是虚标。
        return "\(head)\(item.quality.labeled(kbps: measuredKbps)) · \(item.sizeText)"
    }

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            if let isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isSelected
                                     ? Tokens.Palette.vermilion : Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }

            SongArtwork(song: item.song, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.song.name)
                    .font(FontRole.songTitle)
                    .lineLimit(1)
                Text(artistLine)
                    .font(FontRole.songSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // 第 45 轮（老板：改完信息"专辑还是看不到"）：右侧那串 `本地 · 无损 FLAC · 27.3 MB`
            // 没有宽度上限，会把「歌手 · 专辑」挤成 `40mP miri · …`。左列是歌的**身份**，
            // 该优先拿宽度；右侧放不下时自己截断（音质/大小仍可读个大概）。
            .layoutPriority(1)

            Spacer(minLength: Tokens.Spacing.xs)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 3) {
                    // 第 51 轮 A 方案：文件里的标签与列表是否一致（点它之前先「检查文件对齐」）
                    if let state = item.fileState {
                        FileStateDot(state: state)
                    }
                    // 2026-11-23：时长显示**实测值优先**（老板："所有歌都要真实准确的数字"）。
                    // 元数据可能是错的（《半岛铁盒》元数据 5:19、真实 5:32），显示两套数字就是"对不上"。
                    Text(displayDurationText)
                        .font(FontRole.metadata)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
                Text(qualityLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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

/// 未对齐名单（第 52 轮）：每首一行「歌名 + 原因 + 字段明细」——
/// 可以整段复制发给开发，也可以**只重跑这些**（不再全库 662 首重来）。
private struct UnresolvedListSheet: View {

    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(downloads.lastUnresolved) { issue in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.name)
                                .font(FontRole.songTitle)
                                .lineLimit(1)
                            Text(issue.reason.isEmpty ? "没对齐" : issue.reason)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                            Text(issue.fields)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                } footer: {
                    Text("「只重跑这些」只动上面 \(downloads.lastUnresolved.count) 首，不碰其它歌。"
                         + "字段明细里 ok=一致 · differs=旧值 · missing=没写进去 · empty=本来就没有。")
                }
            }
            .navigationTitle("未对齐 \(downloads.lastUnresolved.count) 首")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        copyAll()
                    } label: {
                        Label(copied ? "已复制" : "复制",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button("只重跑这些") {
                        _ = downloads.retryUnresolvedSongInfo()
                        dismiss()
                    }
                }
            }
        }
    }

    private func copyAll() {
        let text = downloads.lastUnresolved
            .map { "\($0.name)\t\($0.reason)\t\($0.fields)" }
            .joined(separator: "\n")
        UIPasteboard.general.string = text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// 文件对齐状态的小圆点（第 51 轮 A 方案）。
///
/// 只做一件事：把 `SongFileState` 变成一个**不用解释**的视觉信号 ——
/// 绿 = 文件里已经是这一套、灰 = 只有旁车、橙 = 连图都没有、淡灰点 = 这个容器写不了标签。
/// 文案在无障碍标签里（VoiceOver 会读"文件已对齐 / 只在旁车…"）。
private struct FileStateDot: View {
    let state: SongFileState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .accessibilityLabel(DownloadCompanion.FileTruth.label(state))
    }

    private var color: Color {
        switch state {
        case .inSync: return Color.green.opacity(0.85)
        case .sidecarOnly: return Color.secondary.opacity(0.55)
        case .missing: return Color.orange.opacity(0.9)
        case .unsupported: return Color.secondary.opacity(0.25)
        case .fileMissing: return Color.red.opacity(0.85)
        }
    }
}

/// 左滑按钮（删除 + 歌曲信息）：只有"露过脸"的行才挂（`enabled`）。
/// 没挂上的行照样能点、能看，只是暂时没有左滑 —— 行第一次出现的那一拍就会把 `enabled` 打开。
///
/// 第 47 轮（老板 2026-11-21，两个 bug 一起收）：
///   · **长按菜单下线**。它以前挂在这个 modifier 里，而它只在 `armed` 覆盖到的前几行有效
///     （老板 21:16 的录屏：第 1–6 行长按出菜单，第 7 行往后按住 1.5 秒也只有高亮），
///     观感就是"有的歌能改、有的歌不能"。改成显式按钮后不再依赖长按。
///   · **删除只留一个**。这里以前和 `ForEach` 里那份 `.swipeActions` 重复，一行滑出两个垃圾桶。
///   · 「歌曲信息」占删除键的**左边**（顺序在 `DownloadRowSwipe.trailingOrder` 里定义一次）。
// MARK: - 下载页搜索缓存（2026-11-22：663 首时"每输入一个字母就卡"）

/// 下载页「全表过滤 + 排序」的缓存：**同一帧只算一次**，并且每首歌的可搜索串只归一化一次。
///
/// 为什么必须有（老板："下载 tab 歌曲很多的时候，搜索没输入一个字母就开始卡"）：
///   · `ongoing / finished / failed` 这三个 computed 在 body 里会被求值好几次
///     （分页、表头文案、全选、arm、定位…），每一次都是"全表 N 首 × 4 个字段"的
///     繁简映射 + 两次正则 + 再 filter 一遍 + 再 sort 一遍；
///   · 敲一下键 = 把上面这套跑好几遍。663 首时就是几千次归一化，主线程直接被占住。
/// 现在按 `(items 的 revision, 生效的搜索词)` 缓存整批结果，不匹配才重算；
/// 每首歌的归一化串单独缓存（元数据被改过才重算），所以连续敲字只付 N 次 `contains`。
///
/// `revision` 由 `DownloadManager.items.didSet` 递增 —— 所以"下载完成"这种**条数不变**
/// 的变更也会让缓存失效（只按 count 判会漏）。
final class DownloadsSearchCache {

    private var cacheKey = ""
    private var ongoingItems: [DownloadItem] = []
    private var finishedItems: [DownloadItem] = []
    private var failedItems: [DownloadItem] = []
    /// `item.id` → (签名, 可搜索串)；签名发现"这首歌的元数据被改过"
    private var blobs: [UUID: (signature: String, blob: String)] = [:]
    /// `item.id` → (歌手签名, 歌手归并键)。2026-11-23 加歌手筛选时一并缓存：
    /// 筛一次就等于把所有 664 首的歌手各归一化一次，不缓存的话每帧都要重来一遍。
    private var artistKeys: [UUID: (signature: String, key: String)] = [:]

    func lists(items: [DownloadItem], revision: Int, query: String, artist: String? = nil)
        -> (ongoing: [DownloadItem], finished: [DownloadItem], failed: [DownloadItem]) {
        let key = "\(revision)|\(query)|\(artist ?? "")"
        if key == cacheKey {
            return (ongoingItems, finishedItems, failedItems)
        }
        let q = query.isEmpty ? "" : LibrarySearch.key(query)
        var ongoing: [DownloadItem] = []
        var finished: [DownloadItem] = []
        var failed: [DownloadItem] = []
        ongoing.reserveCapacity(8)
        finished.reserveCapacity(items.count)
        failed.reserveCapacity(8)
        for item in items {
            // 先按歌手筛（一次字典查 + 一次字符串比较），再走可搜索串
            if let artist, artistKey(for: item) != artist { continue }
            if !q.isEmpty, !LibrarySearch.matches(blob: blob(for: item), key: q) { continue }
            switch item.status {
            case .downloading, .pending: ongoing.append(item)
            case .completed: finished.append(item)
            case .failed, .cancelled: failed.append(item)
            }
        }
        cacheKey = key
        ongoingItems = ongoing
        // 2026-11-22（老板录屏）：新下载的放最上面。只倒序展示，不动落库顺序。
        finishedItems = DownloadItem.newestFirst(finished)
        failedItems = DownloadItem.newestFirst(failed)
        return (ongoingItems, finishedItems, failedItems)
    }

    /// 一首歌的可搜索串（缓存；元数据变了才重算）
    func blob(for item: DownloadItem) -> String {
        let signature = item.fileName + "\u{1}" + item.song.name + "\u{1}"
            + item.song.singer + "\u{1}" + item.song.album
        if let hit = blobs[item.id], hit.signature == signature { return hit.blob }
        let blob = LibrarySearch.blob(song: item.song, fileName: item.fileName)
        blobs[item.id] = (signature, blob)
        return blob
    }

    /// 这首歌的歌手归并键（缓存；只有 `singer` 变了才重算）
    func artistKey(for item: DownloadItem) -> String {
        let signature = item.song.singer
        if let hit = artistKeys[item.id], hit.signature == signature { return hit.key }
        let key = DownloadArtistFilter.artistKey(item.song.singer)
        artistKeys[item.id] = (signature, key)
        return key
    }
}

// MARK: - 下载页歌手聚合缓存（2026-11-23）

/// 歌手清单**每换一次库只算一次**。
///
/// 为什么不能直接算：`artistGroups` 会被 body 求值好几次（筛选条、头部小字、全部歌手页），
/// 每次都跑 664 首的字符串归一化 + 分组排序的话，就是 11-22 那次"每敲一个字母就卡"的翻版。
/// `revision` 由 `DownloadManager.items.didSet` 递增，连"下载完成但条数没变"也会让它失效。
final class DownloadsArtistIndex {

    private var cachedRevision = -1
    private var cached: [DownloadArtistGroup] = []

    func groups(items: [DownloadItem], revision: Int) -> [DownloadArtistGroup] {
        if revision == cachedRevision { return cached }
        cached = DownloadArtistFilter.groups(items)
        cachedRevision = revision
        return cached
    }
}

// MARK: - 「全部歌手」选择页（2026-11-23）

/// 这个库可能有 300+ 位歌手，横条上只放前 12 位；剩下的在这里搜/挑。
private struct ArtistPickerSheet: View {

    let groups: [DownloadArtistGroup]
    let total: Int
    let selected: String?
    let onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matched: [DownloadArtistGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return groups }
        let key = LibrarySearch.key(q)
        return groups.filter { LibrarySearch.key($0.name).contains(key) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(name: nil, title: "全部歌手", count: total)
                }
                Section("歌手（\(groups.count) 位）") {
                    ForEach(matched) { group in
                        row(name: group.name, title: group.name,
                            count: group.count, seconds: group.seconds)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "搜歌手名")
            .navigationTitle("按歌手筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func row(name: String?, title: String, count: Int, seconds: Int = 0) -> some View {
        Button {
            onPick(name)
            dismiss()
        } label: {
            HStack(spacing: Tokens.Spacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .lineLimit(1)
                    if seconds > 0 {
                        Text(ArtistPickerSheet.durationText(seconds))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Text("\(count) 首")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if selected == name {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.vermilion)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(seconds > 0
            ? "\(title)，\(count) 首，\(ArtistPickerSheet.durationText(seconds))"
            : "\(title)，\(count) 首")
    }

    private static func durationText(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时" }
        return "\(max(1, m)) 分钟"
    }
}

private struct DownloadRowActions: ViewModifier {

    let itemID: UUID
    let enabled: Bool
    let onDelete: (UUID) -> Void
    /// 第 47 轮：编辑入口从长按菜单改成左滑「歌曲信息」按钮。
    let onEdit: (UUID) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .swipeActions(edge: .trailing) {
                    ForEach(DownloadRowSwipe.trailingOrder, id: \.self) { action in
                        switch action {
                        case .delete:
                            Button(role: .destructive) {
                                onDelete(itemID)
                            } label: {
                                Label(action.title, systemImage: action.symbol)
                            }
                        case .edit:
                            Button {
                                onEdit(itemID)
                            } label: {
                                Label(action.title, systemImage: action.symbol)
                            }
                            // 灰色而不是红色：和右边那个真删除拉开距离（一对红块正是重复按钮的观感来源）
                            .tint(Color.gray)
                        }
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

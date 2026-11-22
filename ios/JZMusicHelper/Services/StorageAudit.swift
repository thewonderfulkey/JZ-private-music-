import Foundation

// MARK: - 存储自检（2026-11-22 老板："空间从 20 多 G 变成 40 多 G，我找不到多余的文件"）
//
// 背景：老板 iPhone 里「JZ 音乐」占 44.96 GB，而下载页自己算出来只有 664 首 / 26.5 GB。
// 差的那 18 GB **一定还在 App 容器里**（iOS 只统计容器），但它不属于任何一条下载记录 ——
// 也就是"孤儿文件"或"临时残留"，而这两类在「文件」App 里都不显眼：
//   · `Documents/ImportStaging/`：导入时抢进来的暂存副本，进程被杀就留在那儿（名字是英文，容易被忽略）；
//   · `.tags-xxx.flac` / `.embed-xxx.m4a`：写标签时的临时文件（点开头 = 隐藏，Files 里看不见）；
//   · `Documents/Inbox/`：别的 App「用 JZ 音乐打开」送来的副本；
//   · Music 里没有任何记录指向的音频（早期导入/改名/重导之后的老副本）。
//
// 这个文件只做两件事：**量出来**、**给出可安全删除的那几类**。真正的删除在 View 里由用户点头。
//
// 为什么不用 `URLSession` / 后台队列：枚举只读元数据（不读文件内容），3000 个文件也就一两秒，
// 放到 `Task.detached` 里跑，别占主线程。
/// 一次自检的结果
struct StorageAuditReport {
    struct Section: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let files: Int
    }

    struct FileEntry: Identifiable {
        let id: String        // 绝对路径
        let name: String      // 文件名
        let bytes: Int64
        let url: URL
    }

    var sections: [Section] = []
    /// 记录里加起来多少字节 / 多少首（跟磁盘对账用）
    var libraryBytes: Int64 = 0
    var libraryCount: Int = 0
    /// Music 里没人认领的音频
    var orphans: [FileEntry] = []
    /// 写标签留下的隐藏临时文件（含 .embed-）
    var tempArtifacts: [FileEntry] = []
    /// 导入暂存目录里还剩多少
    var stagingBytes: Int64 = 0
    var stagingFiles: Int = 0
    var stagingPath: String = ""

    /// `tmp` 里**早于 1 小时**的文件（系统临时目录：文档选择器把选中文件抄进来，
    /// 抢完之后我们只删自己成功抢完的那份；中途取消/预算用完，副本就留在这里）。
    /// 只列 1 小时前的：正在跑的后台下载临时文件不能碰。
    var staleTmpFiles: [FileEntry] = []

    /// 「文件」App 的废纸篓（`Documents/.Trash`）。**这是 2026-11-22 那次 18 GB 的真凶**：
    /// 在「文件」App 里删掉 JZ 音乐目录下的东西时，Files 会把它挪进这里，而不是真删；
    /// 而 Files 的浏览页**看不到** `.Trash`（点开头），iOS 却照样算进 App 占用。
    var trashBytes: Int64 = 0
    var trashFiles: Int = 0
    var trashURL: URL?

    var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.bytes } }
    var tempBytes: Int64 { tempArtifacts.reduce(0) { $0 + $1.bytes } }

    /// 容器里所有分区的合计（约等于 iOS「设置」里看到的那个数）。
    /// 导入暂存不单列成一行（界面里有它自己那节），但字节要算进来，否则总数会偏小。
    var totalBytes: Int64 { sections.reduce(0) { $0 + $1.bytes } + stagingBytes }

    /// **音频**（`Music/` 里那些歌本身）合计 —— 只有这一块应该和"记录合计"对得上
    var audioBytes: Int64 = 0
    var audioFiles: Int = 0

    /// 旁车与其它 = 磁盘合计 − 音频合计：封面、歌词、配置 json、诊断日志、Library 缓存、tmp。
    /// 2026-11-22 第二次对账：这 232 MB 全在这一格里，全是**正常开销**，不是垃圾。
    var overheadBytes: Int64 { max(0, totalBytes - audioBytes) }

    /// 真正要警惕的只有这一条：**音频比记录多**（说明 Music 里有没人认领的歌）。
    var audioWasteBytes: Int64 { max(0, audioBytes - libraryBytes) }

    /// 旧口径（保留给文案）：磁盘比记录多出来的全部
    var wasteBytes: Int64 { max(0, totalBytes - libraryBytes) }
}

enum StorageAudit {

    /// 跑一次自检（后台线程；枚举只读元数据）
    static func run(items: [DownloadItem]) async -> StorageAuditReport {
        await Task.detached(priority: .userInitiated) { () -> StorageAuditReport in
            var report = StorageAuditReport()
            report.libraryCount = items.count
            report.libraryBytes = items.reduce(0) { $0 + $1.totalBytes }

            let fm = FileManager.default
            let docs = DownloadLocation.documentsDirectory()
            let music = DownloadLocation.musicDirectory()
            let root = DownloadLocation.currentDirectory()
            let staging = DownloadManager.importStagingDirectory()

            // ① 分区：**先把三块拆开**（音频 / 封面 / 歌词），再算下载根里剩下的散落。
            //
            // 2026-11-22 第二次对账（老板："清完还剩 232.9 MB 既不是缓存也不是 trash"）：
            // 旧口径把"整个下载目录"当成音频去和记录比，于是封面/歌词旁车也被算成"未认领"；
            // 再加 Library（缓存/数据库）、配置 json、诊断日志，232 MB 全在里面 —— 全是正常开销。
            // 现在只让 **音频 vs 记录** 对账，其余单列"旁车与其它"。
            var seen = Set<String>()
            @discardableResult
            func addSection(_ title: String, _ url: URL) -> (Int64, Int) {
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { return (0, 0) }
                let (bytes, files) = measure(url)
                report.sections.append(.init(id: path, title: title, bytes: bytes, files: files))
                return (bytes, files)
            }

            let lyrics = DownloadLocation.lyricsDirectory()
            let covers = DownloadLocation.coverDirectory()
            let (rootTotal, _) = measure(root)
            let audio = addSection("音频（Music）", music)
            report.audioBytes = audio.0
            report.audioFiles = audio.1
            let cover = addSection("封面（Cover）", covers)
            let lyric = addSection("歌词（Lyrics）", lyrics)
            let restOfRoot = max(0, rootTotal - audio.0 - cover.0 - lyric.0)
            if restOfRoot > 1_000_000 {
                report.sections.append(.init(id: root.path + "#rest", title: "下载目录里其它文件",
                                             bytes: restOfRoot, files: 0))
            }
            // 根目录里散落的东西也算进来，别"看不见就当没有"
            if let loose = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: []) {
                for url in loose where !isDirectory(url) {
                    let seg = url.lastPathComponent
                    seen.insert(url.standardizedFileURL.path)   // 避免下面按目录再算一遍
                    report.sections.append(.init(id: url.path, title: "根目录散落：\(seg)",
                                                 bytes: size(of: url), files: 1))
                }
                for url in loose where isDirectory(url) {
                    let path = url.standardizedFileURL.path
                    if path == root.standardizedFileURL.path || path == staging.standardizedFileURL.path {
                        continue
                    }
                    addSection(displayName(for: url.lastPathComponent), url)
                }
            }
            addSection("Library（缓存 / 偏好 / 数据库）",
                       URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library"))
            addSection("tmp（系统临时）",
                       URL(fileURLWithPath: NSTemporaryDirectory()))

            // ② 导入暂存
            let stagingCount = countFiles(staging)
            report.stagingFiles = stagingCount.files
            report.stagingBytes = stagingCount.bytes
            report.stagingPath = staging.path

            // ③ 孤儿音频：Music 里没有记录认领的
            let referenced = StorageAuditRules.referencedNames(items)
            if let files = try? fm.contentsOfDirectory(at: music, includingPropertiesForKeys: nil,
                                                       options: []) {
                for url in files where StorageAuditRules.isOrphan(fileName: url.lastPathComponent,
                                                                 referenced: referenced) {
                    report.orphans.append(.init(id: url.path, name: url.lastPathComponent,
                                                bytes: size(of: url), url: url))
                }
                report.orphans.sort { $0.bytes > $1.bytes }
            }

            // ③.5 「文件」App 的废纸篓（Documents/.Trash）—— 2026-11-22 那次 18 GB 的真凶：
            // 在「文件」App 里删 JZ 音乐目录下的东西，Files 是把它挪进这里（不是真删），
            // 而 Files 的浏览页看不到这个点开头的目录。
            let trash = docs.appendingPathComponent(".Trash", isDirectory: true)
            if fm.fileExists(atPath: trash.path) {
                let m = countFiles(trash)
                report.trashBytes = m.bytes
                report.trashFiles = m.files
                report.trashURL = trash
            }

            // ④ 写标签留下的隐藏临时文件（全容器找一遍，含子目录）
            if let en = fm.enumerator(at: docs, includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsPackageDescendants]) {
                for case let url as URL in en
                where StorageAuditRules.isTagTempArtifact(url.lastPathComponent) {
                    report.tempArtifacts.append(.init(id: url.path, name: url.lastPathComponent,
                                                      bytes: size(of: url), url: url))
                }
            }
            report.tempArtifacts.sort { $0.bytes > $1.bytes }

            // ⑤ tmp 里 1 小时前的残留（文档选择器抄进来的副本是最大的一类）
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            let cutoff = Date().addingTimeInterval(-3600)
            if let en = fm.enumerator(at: tmp,
                                      includingPropertiesForKeys: [.isRegularFileKey,
                                                                   .contentModificationDateKey],
                                      options: [.skipsPackageDescendants]) {
                for case let url as URL in en {
                    let v = try? url.resourceValues(forKeys: [.isRegularFileKey,
                                                              .contentModificationDateKey])
                    guard v?.isRegularFile == true else { continue }
                    guard let modified = v?.contentModificationDate, modified < cutoff else { continue }
                    report.staleTmpFiles.append(.init(id: url.path, name: url.lastPathComponent,
                                                      bytes: size(of: url), url: url))
                }
            }
            report.staleTmpFiles.sort { $0.bytes > $1.bytes }
            return report
        }.value
    }

    // MARK: - 删除（都由 View 明确点头后才调用）

    /// 删掉列出来的文件，返回释放的字节
    @discardableResult
    static func delete(_ entries: [StorageAuditReport.FileEntry]) -> Int64 {
        var freed: Int64 = 0
        let fm = FileManager.default
        for entry in entries {
            let before = size(of: entry.url)
            if (try? fm.removeItem(at: entry.url)) != nil { freed += before }
        }
        return freed
    }

    /// 清空「文件」App 的废纸篓（`Documents/.Trash`），返回释放的字节。
    ///
    /// 安全性：这里躺着的都是**用户已经删过**的东西（Files 只是把它挪进废纸篓，没有真删）。
    /// 我们自己的代码从来不用废纸篓（`removeItem` 是直接 unlink），所以清它不会碰到在用文件。
    @discardableResult
    static func clearTrash() -> Int64 {
        let trash = DownloadLocation.documentsDirectory()
            .appendingPathComponent(".Trash", isDirectory: true)
        let before = countFiles(trash).bytes
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: trash, includingPropertiesForKeys: nil) else { return 0 }
        for f in files { try? FileManager.default.removeItem(at: f) }
        return max(0, before - countFiles(trash).bytes)
    }

    /// 清空导入暂存（只删这个目录里的东西，不动别的）
    @discardableResult
    static func clearStaging() -> Int64 {
        let dir = DownloadManager.importStagingDirectory()
        let before = countFiles(dir).bytes
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                     includingPropertiesForKeys: nil) else {
            return 0
        }
        for f in files { try? FileManager.default.removeItem(at: f) }
        return max(0, before - countFiles(dir).bytes)
    }

    // MARK: - 内部

    private static func displayName(for folder: String) -> String {
        switch folder {
        case "ImportStaging": return "导入暂存（ImportStaging）"
        case "Inbox": return "其他 App 送来（Inbox）"
        case "诊断": return "诊断日志"
        case ".Trash": return "「文件」App 废纸篓（.Trash）"
        default: return folder
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private static func size(of url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        if let allocated = v?.totalFileAllocatedSize { return Int64(allocated) }
        return Int64(v?.fileSize ?? 0)
    }

    /// 一个目录/文件的总字节与文件数（递归，只读元数据）
    private static func measure(_ url: URL) -> (bytes: Int64, files: Int) {
        guard isDirectory(url) else { return (size(of: url), 1) }
        return countFiles(url)
    }

    private static func countFiles(_ dir: URL) -> (bytes: Int64, files: Int) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir,
                                     includingPropertiesForKeys: [.isRegularFileKey,
                                                                  .totalFileAllocatedSizeKey,
                                                                  .fileSizeKey],
                                     options: [.skipsPackageDescendants]) else { return (0, 0) }
        var bytes: Int64 = 0
        var files = 0
        for case let url as URL in en {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey,
                                                      .totalFileAllocatedSizeKey,
                                                      .fileSizeKey])
            guard v?.isRegularFile == true else { continue }
            files += 1
            if let allocated = v?.totalFileAllocatedSize {
                bytes += Int64(allocated)
            } else {
                bytes += Int64(v?.fileSize ?? 0)
            }
        }
        return (bytes, files)
    }
}

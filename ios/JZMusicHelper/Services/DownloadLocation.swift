import Foundation

// MARK: - 下载保存位置
//
// 第四十轮（老板："关于下载，把保存位置改为可配置即可"）。
//
// 口径：
//   · **默认**还是 App 自己的 `Documents/Music`（「文件 › JZ 音乐 › 音乐」可见，靠 Info.plist 的
//     `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`）。这条路径一个字没改，
//     升级后老用户看到的行为完全一样；`downloads.json` 里存的是绝对路径，旧文件不动。
//   · 用户可以在「文件」App 里**另选一个文件夹**（iCloud Drive、我的 iPhone 下的目录都行），
//     这里存一条安全书签（security-scoped bookmark）。iOS 上安全书签只对系统选择器返回的 URL
//     有效，所以只能"选"，不能让用户手打路径。
//   · 书签解不开 / 目录被删被移走 → 自动退回默认目录，不崩、不往坏路径里写。
//   · 外部目录要一直"开着访问"：下载完成后落盘、旁车（.lrc/.jpg）写入、播放本地文件、
//     删除都已在这个作用域之外，所以这里**按目录**记住已打开的作用域，进程内只开一次、不开不换。
//     （Apple 的文档式 App 也是这个口径：拿到的文件夹权限在 App 生命周期内保持。）
//
// 为什么所有读写都走 UserDefaults 而不是 `SettingsStore`：DownloadManager 的落盘发生在
// URLSession 的 delegate 队列，直接读 `@Observable` 的 store 会跨线程碰 UI 状态；
// 这里的两个键谁都能读，线程安全。
enum DownloadLocation {

    /// 默认文件夹名。**磁盘上就是 `Documents/Music`**（老版本一直用它，改了就找不到旧下载），
    /// 「文件」App 里看到的那一层名字也是它，所以界面文案直接用它，不另起中文名——
    /// 以前界面写"下载"、磁盘其实是 `Music`，用户去文件里找会对不上。
    static let defaultFolderName = DownloadPathRules.defaultFolderName

    /// 用户自选目录的安全书签
    static let bookmarkKey = "download_folder_bookmark"

    /// 用户自选目录的显示名（「文件」App 里看到的那一层名字）
    static let folderNameKey = "download_folder_name"

    private static let scopeLock = NSLock()
    /// 本次运行里已经打开过作用域的外部目录（路径 → 已开）
    private static var openScopes: Set<String> = []

    // MARK: 默认目录

    static func defaultDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(defaultFolderName, isDirectory: true)
    }

    // MARK: 书签

    /// 从「文件」App 选出来的 URL 建一条长期书签（必须在 `startAccessing` 作用域内调用）
    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// 解开书签并确认目录还在；`nil` = 这条书签作废（调用方退回默认目录）
    static func resolve(bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        // stale 先照用：旧书签指向的目录往往还在，下一次 `currentDirectory()` 时不重建；
        // 真正的重建时机是用户重新选一次（选完就覆盖旧书签）。
        return url
    }

    // MARK: 当前生效目录

    /// 当前该往哪存：自选目录优先，解不开就退回默认。
    /// 目录不存在会顺手建出来（外部目录建失败会继续往上抛给调用方 → 退回默认）。
    static func currentDirectory() -> URL {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey),
           let external = resolve(bookmark: data) {
            openScope(at: external)
            return external
        }
        return ensureDefaultDirectory()
    }

    /// 当前保存位置的显示名（设置页 / 下载页的面包屑）
    static var currentLabel: String {
        if let name = UserDefaults.standard.string(forKey: folderNameKey), !name.isEmpty {
            return name
        }
        return defaultFolderName
    }

    /// 当前是不是"用户自选的外部目录"
    static var isCustomFolder: Bool {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return false }
        return resolve(bookmark: data) != nil
    }

    // MARK: 路径文案（设置页要"完整路径"，不是只有一个文件夹名）

    /// 默认位置的面包屑（文案规则在 `DownloadPathRules`，CI 有条断言钉着）
    static var defaultPathText: String {
        DownloadPathRules.defaultPathText
    }

    /// 用户已保存的自选目录（解不开就是 nil，不建目录、不产生副作用）
    static func savedCustomDirectory() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        return resolve(bookmark: data)
    }

    /// 当前保存位置的面包屑（设置页那一行显示的就是它）
    ///
    /// 老板第二轮反馈："设置页面显示的只有一个 Music，我要把完整的路径显示出来，像之前版本一样"——
    /// 所以这里给的是**从「文件」App 根往下的一整条**，不是一个 `lastPathComponent`。
    static var currentPathText: String {
        guard let custom = savedCustomDirectory() else { return defaultPathText }
        return breadcrumb(for: custom)
    }

    /// 当前保存位置的绝对路径（给想确认"到底在磁盘哪"的人；设置页用一行小字显示）
    static var currentAbsolutePathText: String {
        savedCustomDirectory()?.path ?? defaultDirectory().path
    }

    /// URL → 「文件」App 里看到的那种面包屑（纯字符串规则见 `DownloadPathRules.breadcrumb`）
    static func breadcrumb(for url: URL) -> String {
        DownloadPathRules.breadcrumb(path: url.standardizedFileURL.path)
    }

    // MARK: 安全作用域

    /// 给外部目录打开一次作用域（进程内同一个目录只开一次；默认目录是 App 沙盒内，直接跳过）
    static func openScope(at directory: URL) {
        guard !isInsideAppContainer(directory) else { return }
        let path = directory.standardizedFileURL.path
        scopeLock.lock()
        let already = openScopes.contains(path)
        if !already { openScopes.insert(path) }
        scopeLock.unlock()
        if !already { _ = directory.startAccessingSecurityScopedResource() }
    }

    /// 给某个已下载文件所在的目录打开作用域（播放/删除本地文件前调用）
    static func openScope(forFile fileURL: URL) {
        openScope(at: fileURL.deletingLastPathComponent())
    }

    /// 真写一次再删掉：确认这个目录**现在就能写**。
    ///
    /// 为什么必须试：安全书签能解开、目录也存在，但某些云盘/别的 App 的容器是只读的——
    /// 不试的话要等下一次下载失败（"文件写入失败"）才发现，正是老板这次"选了半天、什么都没变"的观感。
    static func isWritable(_ directory: URL) -> Bool {
        let probe = directory.appendingPathComponent(".jz-write-test-\(UUID().uuidString)")
        let created = FileManager.default.createFile(atPath: probe.path, contents: Data("ok".utf8))
        guard created else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    // MARK: 内部

    private static func ensureDefaultDirectory() -> URL {
        let dir = defaultDirectory()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func isInsideAppContainer(_ url: URL) -> Bool {
        let home = NSHomeDirectory()
        return url.standardizedFileURL.path.hasPrefix(home)
    }
}

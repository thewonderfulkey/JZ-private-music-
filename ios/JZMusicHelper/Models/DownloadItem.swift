import Foundation

// MARK: - 可用的流地址（一个后端解析出的结果）
/// directId=true：按歌曲平台 ID 直连解析（QQ mid / 网易 id），身份可靠；
/// false：搜索式取流（按歌名+歌手重新搜索），需配合身份校验。
/// kbps / totalBytes 是取流阶段 Range 探测到的**真实**值，下载前就能按「容器 + 体积」预校验档位。
struct StreamSource: Identifiable, Codable, Hashable, Sendable {
    let url: String
    let backendName: String
    let platform: MusicPlatform
    let quality: QualityLevel
    let format: String
    let note: String
    var directId: Bool = false
    var kbps: Int64 = 0
    var totalBytes: Int64 = 0
    /// 取流探测时服务端是否支持 Range（206 或带 Content-Range）。
    /// nil = 老数据/没探测（解码兼容：Optional 缺键不报错）。
    var rangeOK: Bool? = nil

    var id: String { "\(platform.rawValue)_\(backendName)_\(quality.rawValue)" }

    /// 码率（kbps）：总字节 × 8 ÷ 时长；任一为 0 时回 0（表示算不出）
    static func kbps(totalBytes: Int64, durationSec: Int) -> Int64 {
        guard durationSec > 0, totalBytes > 0 else { return 0 }
        return totalBytes * 8 / Int64(durationSec) / 1000
    }
}

// MARK: - 下载状态
enum DownloadStatus: String, Codable {
    case pending
    case downloading
    case completed
    case failed
    case cancelled
}

// MARK: - 下载条目
struct DownloadItem: Identifiable, Codable, Hashable {
    let id: UUID
    let song: Song
    let streamURL: String
    let backendName: String
    /// 标注档位。落盘后会按实测结果改写（例：接口说有损，文件其实是 320k mp3），所以是 var。
    var quality: QualityLevel
    var fileName: String
    var localPath: String?
    var status: DownloadStatus
    var progress: Double
    var receivedBytes: Int64
    var totalBytes: Int64
    /// 取流阶段用 Range 探到的**预期**体积；落盘后拿它做 95% 完整性校验。
    /// 可选类型是为了兼容旧记录（downloads.json 里没有这个键，解码不能失败）。
    var expectedBytes: Int64?
    var createdAt: Date
    var finishedAt: Date?
    var errorMessage: String?
    /// 落盘实测与标注档位不一致时的说明（例：标着无损，文件其实是 320k mp3）。
    /// 可选类型：旧记录没有这个键，解码不能失败。
    var actualNote: String?
    /// 歌词/封面补料结果（例："已内嵌歌词+封面" / "歌词封面已存旁车"）。
    /// 下载完成后的异步补料会回填它，下载列表据此能看出"词和图到底有没有跟着歌走"。
    /// 可选类型：旧 downloads.json 没有这个键，解码不能失败。
    var companionsNote: String?
    /// 来源：nil/"download" = 联网下载；"import" = 用户导入的本地文件。
    /// 可选类型：旧 downloads.json 没有这个键，解码不能失败。
    var origin: String?
    /// 导入文件的 SHA-256（同文件判重用；下载记录暂时为 nil）
    var contentHash: String?

    init(id: UUID = UUID(),
         song: Song,
         streamURL: String,
         backendName: String,
         quality: QualityLevel,
         fileName: String = "",
         localPath: String? = nil,
         status: DownloadStatus = .pending,
         progress: Double = 0,
         receivedBytes: Int64 = 0,
         totalBytes: Int64 = 0,
         expectedBytes: Int64? = nil,
         createdAt: Date = Date(),
         finishedAt: Date? = nil,
         errorMessage: String? = nil,
         actualNote: String? = nil,
         companionsNote: String? = nil,
         origin: String? = nil,
         contentHash: String? = nil) {
        self.id = id
        self.song = song
        self.streamURL = streamURL
        self.backendName = backendName
        self.quality = quality
        self.fileName = fileName
        self.localPath = localPath
        self.status = status
        self.progress = progress
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.expectedBytes = expectedBytes
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.actualNote = actualNote
        self.companionsNote = companionsNote
        self.origin = origin
        self.contentHash = contentHash
    }

    var progressText: String {
        guard totalBytes > 0 else { return "--%" }
        return String(format: "%.0f%%", progress * 100)
    }

    var sizeText: String {
        ByteText.human(totalBytes)
    }
}

// MARK: - 批量选择（2026-11-21 老板：下载 tab 要多选 + 全选 + 批量删除）

/// 多选的纯逻辑：只决定"全选按钮该做什么"和"结果集合长什么样"，
/// 方便在 CI 里钉断言（视图里只剩调用）。
enum BatchSelection {

    /// 当前可见的行是不是**已经全选**（决定按钮显示「全选」还是「取消全选」）
    static func isAllSelected(picked: Set<UUID>, visible: [UUID]) -> Bool {
        guard !visible.isEmpty else { return false }
        return visible.allSatisfy { picked.contains($0) }
    }

    /// 点「全选 / 取消全选」之后的新集合：
    /// 已经全选 → 只把这些可见的移出（不动搜索过滤掉的其它选择）；
    /// 否则 → 并入全部可见项（保留已选的其它项，翻页/搜索后不会丢）。
    static func togglingAll(picked: Set<UUID>, visible: [UUID]) -> Set<UUID> {
        if isAllSelected(picked: picked, visible: visible) {
            return picked.subtracting(visible)
        }
        return picked.union(visible)
    }

    /// 单行点一下：有则去掉，无则加上
    static func toggling(_ picked: Set<UUID>, _ id: UUID) -> Set<UUID> {
        picked.contains(id) ? picked.subtracting([id]) : picked.union([id])
    }

    /// 只保留还在列表里的（删除/导入后清理残留选择，避免"删了看不见的东西"）
    static func pruning(_ picked: Set<UUID>, visible: [UUID]) -> Set<UUID> {
        picked.intersection(visible)
    }
}

// MARK: - 体积文案（2026-11-21 老板：> 1GB 用 GB，< 1GB 用 MB，< 1MB 再降级，升级同理）

/// 一处统一的"人看的体积"：自动选档位，不再到处写 `%.1f MB`。
///
/// 老板原话："把下载那里的内存显示改为 GB 单位，一旦大于 1GB 就用 GB 单位，小于的话用 MB，
/// 小于 1MB 再降级用更小的单位，升级同理。"
/// 用 1000 进制（和 iOS「设置 › 通用 › iPhone 储存空间」一致，也和以前下载页的 MB 口径一致）。
enum ByteText {

    /// 档位：≥1GB → GB；≥1MB → MB；≥1KB → KB；否则 B。
    /// 小数位：GB 两位（1.25 GB）、MB 一位（8.2 MB）、KB 与 B 取整 —— 一眼能读，不拖一串 0。
    static func human(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let value = Double(bytes)
        if value >= 1_000_000_000 { return trim(String(format: "%.2f", value / 1_000_000_000)) + " GB" }
        if value >= 1_000_000 { return trim(String(format: "%.1f", value / 1_000_000)) + " MB" }
        if value >= 1_000 { return String(format: "%.0f", value / 1_000) + " KB" }
        return "\(bytes) B"
    }

    /// 去掉 `1.00` 这种多余的 0（GB 档只有一位小数时不显示两位）
    private static func trim(_ s: String) -> String {
        var out = s
        while out.contains("."), out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }
}

// MARK: - 下载页分页（第 41 轮：首屏只建 N 行，滚到底继续加载）
//
// 老板 2026-11-21：本地导入到几百上千首后，点「下载」Tab 要卡 2–3 秒。
// 查下来卡的**不是数据**（662 条全量解码 9.6ms、6 遍全量扫描 0.3ms、662 次 firstIndex 0.4ms，
// 都是本机微基准实测），而是**整页 900+ 行视图一次性建起来**。
// 所以首帧只建一页，滚到底再加一页。
//
// 口径（视图与断言共用，别再在视图里各写一套）：
//   · 显示顺序与页面一致：正在下载 → 失败 → 已下载；
//   · **正在下载永远全显示**（在飞的就几首，藏起来等于看不见进度）；
//   · 失败区最多占预算的 1/4（第一屏至少给 20 条，方便直接重试），其余给已下载——
//     否则 245 条失败的旧记录会把 662 首已下载整片挤出首屏；
//   · `total` 是"全展开会有多少行"，`shown` 是"这次建了多少行"，`hidden` 是差值。
struct DownloadPageSlices: Equatable {
    var ongoing: [DownloadItem]
    var failed: [DownloadItem]
    var finished: [DownloadItem]
    var shown: Int
    var total: Int

    var hasMore: Bool { shown < total }
    var hidden: Int { max(0, total - shown) }
}

enum DownloadListPaging {

    /// 首屏行数（老板要的 60–80 行档位）
    static let firstPage = 80
    /// 每次「继续加载」/滚到底追加的行数
    static let pageStep = 80

    /// 失败区这一屏给多少条：预算的 1/4，第一屏至少 20 条，但不超过实际失败数。
    static func failedQuota(budget: Int, failedCount: Int) -> Int {
        guard budget > 0, failedCount > 0 else { return 0 }
        let share = max(budget / 4, min(20, budget))
        return min(failedCount, share)
    }

    static func slices(ongoing: [DownloadItem],
                       failed: [DownloadItem],
                       finished: [DownloadItem],
                       limit: Int) -> DownloadPageSlices {
        let budget = max(0, limit)

        // 正在下载：不受分页限制，但先吃掉预算
        let o = ongoing

        let f: [DownloadItem]
        let d: [DownloadItem]
        let remaining = max(0, budget - o.count)
        if remaining > 0 {
            f = Array(failed.prefix(failedQuota(budget: remaining, failedCount: failed.count)))
            d = Array(finished.prefix(max(0, remaining - f.count)))
        } else {
            f = []
            d = []
        }

        return DownloadPageSlices(ongoing: o, failed: f, finished: d,
                                  shown: o.count + f.count + d.count,
                                  total: ongoing.count + failed.count + finished.count)
    }

    /// 下一次的 limit（点「继续加载」或滚到底时）
    static func nextLimit(_ current: Int, total: Int) -> Int {
        min(max(0, total), max(0, current) + pageStep)
    }
}

// MARK: - 目录索引（一次列目录，别每首歌都列一遍）

/// 第 41 轮 P1-1：`findExistingAudioFile` 原来"每首一次 `contentsOfDirectory`"，
/// 662 首就是 662 次全目录列举（本机微基准：单次 3.4ms → 合计 2278ms）。
/// 折成「基名 → 同名文件列表」后，找一首歌只是一次字典查询。
enum DownloadFileIndex {

    /// 目录里的文件名清单 → 索引。键是去掉扩展名的基名。
    static func build(names: [String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        out.reserveCapacity(names.count)
        for name in names {
            let base = (name as NSString).deletingPathExtension
            out[base, default: []].append(name)
        }
        return out
    }

    /// 记录里的 `fileName` 在索引里找同名文件：先精确同名，再退到「同基名」。
    /// （扩展名被换过、或 .flac/.m4a 两份都在时，精确那条优先；多个同基名按名字排序取第一个，保证可断言。）
    static func match(fileName: String, in index: [String: [String]]) -> String? {
        guard !fileName.isEmpty else { return nil }
        let base = (fileName as NSString).deletingPathExtension
        guard let candidates = index[base], !candidates.isEmpty else { return nil }
        if candidates.contains(fileName) { return fileName }
        return candidates.sorted().first
    }
}

// MARK: - 缓存签名（第 41 轮 P0-4：按 id 失效，不再全清）

/// 以前 `items` 任何变化（哪怕只是下载进度 +1%）都 `removeAll()` 两个缓存，
/// 下载页每行隔一秒就重新走一次「线性找记录 + stat 磁盘」。
/// 用一个便宜的签名判断"这条记录的本地状态到底变没变"：
///   · 进度 / 字节数变化 → 签名不变 → 缓存保留；
///   · 状态、本地路径、文件名变了 → 只摘掉这一首。
struct DownloadCacheSignature: Equatable {
    var songID: String
    var status: DownloadStatus
    var localPath: String?
    var fileName: String

    init(songID: String, status: DownloadStatus, localPath: String?, fileName: String) {
        self.songID = songID
        self.status = status
        self.localPath = localPath
        self.fileName = fileName
    }

    init(_ item: DownloadItem) {
        self.init(songID: item.song.id,
                  status: item.status,
                  localPath: item.localPath,
                  fileName: item.fileName)
    }
}

// MARK: - 行状态（第 41 轮 P0-3：渲染路径零磁盘）

/// 一行下载记录的"本地事实"：音频在哪、旁车封面在哪。
/// 由 `DownloadManager` 在后台按一次目录列举算好，视图/播放链只读它，不再逐行 stat/列目录。
/// nil 一律表示"没有"，与 `localFileURL` / `localCoverURL` 的返回口径一致。
struct DownloadRowFacts: Equatable {
    var filePath: String?
    var coverPath: String?
}

// MARK: - 搜索历史条目
struct SearchHistoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let keyword: String
    let createdAt: Date

    init(id: UUID = UUID(), keyword: String, createdAt: Date = Date()) {
        self.id = id
        self.keyword = keyword
        self.createdAt = createdAt
    }
}

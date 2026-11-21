// r168 迷你自测（2026-11-21 v2.4.52）：下载 Tab 首屏卡顿六项修复
//
// 老板实证：662 首已下载（26.47 GB）+ 245 条失败记录时，点「下载」Tab 卡 2–3 秒；
// 录屏里"点下载那一瞬间底部按钮会变小一下"。
// 本机微基准（.build/bench_download_tab.swift，Swift 6.0.3 Linux，N=662）：
//   全量解码 9.6ms / 6 遍全量扫描 0.3ms / 662 次 firstIndex 0.4ms / 662 次 stat 0.3ms
//   —— 数据层全部毫秒级；**唯一到秒级的是"每首列一次目录"：662 × 3.4ms = 2278ms**。
//
// 本文件钉住这轮新增的三块纯逻辑：
//   ① 分页预算（首屏 80 行、失败区最多 1/4、正在下载全显示）
//   ② 目录索引（一次列目录，精确同名优先，退到同基名）
//   ③ 缓存签名（进度变化不清缓存；状态/路径/文件名变化才清）
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func dlItem(_ i: Int, status: DownloadStatus = .completed,
            path: String? = "/tmp/x.flac") -> DownloadItem {
    DownloadItem(song: Song(platform: .qq, platformID: "s\(i)", name: "第\(i)首",
                            singer: "歌手\(i % 7)", album: "专辑", duration: 240, picURL: nil),
                 streamURL: "file:///\(i).flac",
                 backendName: "import",
                 quality: .lossless,
                 fileName: "歌手\(i % 7) - 第\(i)首.flac",
                 localPath: path,
                 status: status,
                 totalBytes: 40_000_000,
                 origin: "import")
}

print("— 分页预算（P0-2：首屏只建 80 行）")
check("首屏 80 / 步长 80", DownloadListPaging.firstPage == 80 && DownloadListPaging.pageStep == 80)

let finished662 = (0..<662).map { dlItem($0) }
let one = DownloadListPaging.slices(ongoing: [], failed: [], finished: finished662, limit: 80)
check("662 首只建 80 行", one.finished.count == 80 && one.shown == 80)
check("总数仍报全量 662", one.total == 662)
check("还有 582 首没显示", one.hasMore && one.hidden == 582)

let all = DownloadListPaging.slices(ongoing: [], failed: [], finished: finished662, limit: 10_000)
check("limit 够大时全展开（不丢歌）", all.finished.count == 662 && !all.hasMore && all.hidden == 0)

let failed245 = (0..<245).map { dlItem($0, status: .failed, path: nil) }
let mixed = DownloadListPaging.slices(ongoing: Array(finished662.prefix(5)), failed: failed245,
                                      finished: finished662, limit: 80)
check("失败区只占 1/4（20 条）", mixed.failed.count == 20)
check("已下载还能露 55 条（不被失败区挤出首屏）", mixed.finished.count == 55)
check("正在下载永远全显示", mixed.ongoing.count == 5)
check("一屏仍受预算约束", mixed.shown == 80 && mixed.total == 5 + 245 + 662)
check("失败区不足配额按实际给", DownloadListPaging.failedQuota(budget: 80, failedCount: 3) == 3)
check("预算为 0 不给失败区", DownloadListPaging.failedQuota(budget: 0, failedCount: 10) == 0)

check("继续加载 80 → 160", DownloadListPaging.nextLimit(80, total: 662) == 160)
check("继续加载不越界", DownloadListPaging.nextLimit(640, total: 662) == 662)
check("到底了不再涨", DownloadListPaging.nextLimit(662, total: 662) == 662)
let empty = DownloadListPaging.slices(ongoing: [], failed: [], finished: [], limit: 80)
check("空列表：无更多、hidden 不为负", !empty.hasMore && empty.hidden == 0 && empty.shown == 0)

print("— 目录索引（P1-1：把 662 次列目录压成 1 次）")
let index = DownloadFileIndex.build(names: ["晴天.flac", "晴天.m4a", "七里香.mp3"])
check("同基名两份都进索引", index["晴天"]?.count == 2)
check("精确同名优先", DownloadFileIndex.match(fileName: "晴天.m4a", in: index) == "晴天.m4a")
check("扩展名变了按基名找", DownloadFileIndex.match(fileName: "晴天.wav", in: index) == "晴天.flac")
check("找不到就是没有", DownloadFileIndex.match(fileName: "发如雪.flac", in: index) == nil)
check("空文件名直接 nil", DownloadFileIndex.match(fileName: "", in: index) == nil)
check("空目录不炸", DownloadFileIndex.build(names: []).isEmpty)
check("662 个文件名建索引不重不漏", DownloadFileIndex.build(names: (0..<662).map { "歌手\($0 % 7) - 第\($0)首.flac" }).count == 662)

print("— 缓存按 id 失效（P0-4：进度不再清缓存）")
let base = dlItem(1)
var progressed = base
progressed.progress = 0.87
progressed.receivedBytes = 12_345
check("只是进度变了 → 签名不变", DownloadCacheSignature(base) == DownloadCacheSignature(progressed))

var failedItem = base
failedItem.status = .failed
check("状态变了 → 签名变", DownloadCacheSignature(base) != DownloadCacheSignature(failedItem))

var movedItem = base
movedItem.localPath = "/tmp/y.flac"
check("本地路径变了 → 签名变", DownloadCacheSignature(base) != DownloadCacheSignature(movedItem))

var renamed = base
renamed.fileName = "别的名字.flac"
check("文件名变了 → 签名变", DownloadCacheSignature(base) != DownloadCacheSignature(renamed))

let otherSong = DownloadItem(song: Song(platform: .qq, platformID: "zz", name: "另一首",
                                        singer: "别人", album: "", duration: 100, picURL: nil),
                             streamURL: "x", backendName: "import", quality: .lossless,
                             status: .completed)
check("不同歌 → 签名不同", DownloadCacheSignature(base) != DownloadCacheSignature(otherSong))

print("\n通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    print("失败项：" + fail.joined(separator: " | "))
    exit(1)
}
print("全部通过")
exit(0)

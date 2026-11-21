// r169 迷你自测（2026-11-21 v2.4.53）：下载 Tab「首帧 8 行 + 分块补行」
//
// 真机 perf.log（老板 16:30 的诊断.zip，v2.4.52 六次）：
//   tab=downloads t0→t1=813 t0→t3=814 rows=80 file=0次/0ms fallback=0次 art=5次 maxGap=952ms
//   tab=downloads t0→t1=598 ... maxGap=787
//   tab=downloads t0→t1=573 ... maxGap=676
//   tab=downloads t0→t1=554 ... maxGap=697
//   tab=downloads t0→t1=604 ... maxGap=805
//   tab=downloads t0→t1=507 ... maxGap=724
// 结论：耗时全在"页面插入 + 首屏行构建"（80 行 ≈ 507–813ms ≈ 7–10ms/行），
// 磁盘/封面/列目录已被排除（file=0 / fallback=0）。
// 所以这一版把首帧压到 8 行，之后分块补到 80，并把「继续加载」从 80 降到 24。
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

print("— 首帧 8 行（P0：真机 80 行要 507–813ms）")
check("首帧 8 行", DownloadListPaging.firstFrame == 8)
check("补行目标 80", DownloadListPaging.fillTarget == 80)
check("每拍 4 行", DownloadListPaging.fillChunk == 4)

let finished662 = (0..<662).map { dlItem($0) }
let first = DownloadListPaging.slices(ongoing: [], failed: [], finished: finished662,
                                      limit: DownloadListPaging.firstFrame)
check("首帧只建 8 行（不是 80）", first.finished.count == 8 && first.shown == 8)
check("总数仍报全量", first.total == 662)

print("— 分块补行：8 → 12 → … → 80，不越界、不回退")
var limit = 8
var steps = 0
var monotonic = true
while limit < 80 {
    let next = DownloadListPaging.nextFillLimit(limit, target: 80)
    if next <= limit { monotonic = false }
    limit = next
    steps += 1
    if steps > 100 { break }
}
check("补到 80 需要 18 拍（每拍 4 行）", steps == 18)
check("全程单调递增且严格到 80", monotonic && limit == 80)
check("到目标后不再涨", DownloadListPaging.nextFillLimit(80, target: 80) == 80)
check("76 → 80（不越过目标）", DownloadListPaging.nextFillLimit(76, target: 80) == 80)

print("— 「继续加载」步长 24（原来是 80）")
check("步长 24", DownloadListPaging.pageStep == 24)
check("首屏上限仍 80", DownloadListPaging.firstPage == 80)
check("8 → 32", DownloadListPaging.nextLimit(8, total: 662) == 32)
check("56 → 80", DownloadListPaging.nextLimit(56, total: 662) == 80)
check("640 → 662（不越界）", DownloadListPaging.nextLimit(640, total: 662) == 662)
check("到底不再涨", DownloadListPaging.nextLimit(662, total: 662) == 662)

print("— 失败区配额：首帧 8 行时不能让失败把歌全挤掉")
let failed245 = (0..<245).map { dlItem($0, status: .failed, path: nil) }
check("budget 80 → 失败 20 条", DownloadListPaging.failedQuota(budget: 80, failedCount: 245) == 20)
check("budget 8 → 失败只 2 条", DownloadListPaging.failedQuota(budget: 8, failedCount: 245) == 2)
check("budget 4 → 至少 1 条失败", DownloadListPaging.failedQuota(budget: 4, failedCount: 245) == 1)
check("预算 0 不给失败", DownloadListPaging.failedQuota(budget: 0, failedCount: 245) == 0)
check("没有失败就不占预算", DownloadListPaging.failedQuota(budget: 80, failedCount: 0) == 0)

let mixedFirst = DownloadListPaging.slices(ongoing: [], failed: failed245,
                                           finished: finished662, limit: 8)
check("首帧 8 行 = 2 失败 + 6 已下载（歌还在）",
      mixedFirst.failed.count == 2 && mixedFirst.finished.count == 6 && mixedFirst.shown == 8)

print("\n通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    print("失败项：" + fail.joined(separator: " | "))
    exit(1)
}
print("全部通过")
exit(0)

// r174 迷你自测（2026-11-21 v2.4.57 / 235）：两个 bug 一起收
//   ① 老板 21:16 录屏：**部分歌曲长按唤不出「编辑歌曲信息」**（第 1–6 行能，第 7 行往后不能）
//      → 根因不是歌曲，是行：左滑/长按只挂在 `armed` 上，而「定位」撑开 visibleLimit 时不 arm。
//      → 这轮改成显式左滑按钮 + `.onChange(of: visibleLimit)` 兜底 arm。
//   ② 老板 21:35 截屏：**一行左滑出现两个红色垃圾桶**（同一行挂了两份 `.swipeActions`）
//      → 现在顺序与文案只在 `DownloadRowSwipe` 定义一次。
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func item(_ i: Int, status: DownloadStatus = .completed,
          path: String? = "/tmp/x.flac") -> DownloadItem {
    DownloadItem(song: Song.make(platform: .qq, platformID: "q\(i)",
                                 name: "第\(i)首", singer: "歌手\(i % 7)",
                                 album: "", duration: 240, picURL: nil),
                 streamURL: "file:///\(i).flac",
                 backendName: "import",
                 quality: .lossless,
                 fileName: "歌手\(i % 7) - 第\(i)首.flac",
                 localPath: path,
                 status: status,
                 totalBytes: 40_000_000,
                 origin: "import")
}

let finished662 = (0..<662).map { item($0) }
let failed245 = (0..<245).map { item($0, status: .failed, path: nil) }

print("— 左滑按钮：一个删除键 + 歌曲信息在左边")
check("尾侧顺序 [.delete, .edit]（删除贴右边缘）",
      DownloadRowSwipe.trailingOrder == [.delete, .edit],
      "\(DownloadRowSwipe.trailingOrder)")
check("只有一个删除键",
      DownloadRowSwipe.trailingOrder.filter { $0 == .delete }.count == 1)
check("歌曲信息 = 声明序第 2 个（落在删除键左边）",
      DownloadRowSwipe.trailingOrder.last == .edit)
check("只有删除是破坏性",
      DownloadRowSwipe.delete.isDestructive && !DownloadRowSwipe.edit.isDestructive)
check("文案/图标", DownloadRowSwipe.delete.title == "删除"
      && DownloadRowSwipe.delete.symbol == "trash"
      && DownloadRowSwipe.edit.title == "歌曲信息"
      && DownloadRowSwipe.edit.symbol == "pencil")
check("动作不重复", Set(DownloadRowSwipe.trailingOrder).count == 2)

print("— arm 的账：首帧 8 行预算里，失败区先吃掉 2 行")
let first = DownloadListPaging.slices(ongoing: [], failed: failed245,
                                      finished: finished662, limit: 8)
check("首帧 = 失败 2 + 已下载 6",
      first.failed.count == 2 && first.finished.count == 6,
      "failed=\(first.failed.count) finished=\(first.finished.count)")
let armed8 = DownloadListPaging.renderedIDs(ongoing: [], failed: failed245,
                                            finished: finished662, limit: 8)
check("arm 目标 = 首帧渲染的 8 行", armed8.count == 8, "\(armed8.count)")
check("首帧已下载只 arm 到 6 首（第 7 首起就是老板说的「部分歌曲」）",
      Set(first.finished.map(\.id)).count == 6,
      "\(Set(first.finished.map(\.id)).count)")

print("— 定位把 limit 撑到 104：显示 84 首，但 arm 只许变大")
let wide = DownloadListPaging.renderedIDs(ongoing: [], failed: failed245,
                                          finished: finished662, limit: 104)
let paged = DownloadListPaging.slices(ongoing: [], failed: failed245,
                                      finished: finished662, limit: 104)
check("104 行 = 26 条失败（1/4 配额）+ 78 首已下载",
      paged.failed.count == 26 && paged.finished.count == 78,
      "failed=\(paged.failed.count) finished=\(paged.finished.count)")
let failed20 = (0..<20).map { item($0, status: .failed, path: nil) }
let boss = DownloadListPaging.slices(ongoing: [], failed: failed20,
                                     finished: finished662, limit: 104)
check("104 行预算 + 20 条失败 → 已下载正好 84（= 老板截屏上的「已显示 84」）",
      boss.failed.count == 20 && boss.finished.count == 84,
      "failed=\(boss.failed.count) finished=\(boss.finished.count)")
check("renderedIDs = slices 的全部 id（arm 与渲染同源）", paged.allIDs == wide)
check("旧行一个不丢（arm 只增不减）", armed8.isSubset(of: wide))
let mid = DownloadListPaging.renderedIDs(ongoing: [], failed: failed245,
                                        finished: finished662, limit: 32)
check("limit 32 的行都在 104 里（单调）", mid.isSubset(of: wide))
check("arm 之后 84 首全都可左滑（不是只有前 6 首）",
      Set(boss.finished.map(\.id)).isSubset(of: DownloadListPaging.renderedIDs(
          ongoing: [], failed: failed20, finished: finished662, limit: 104)))

print("")
print(fail.isEmpty ? "全部通过：\(pass) 条" : "失败 \(fail.count) 条 / 通过 \(pass) 条")
for f in fail { print("  ✗ \(f)") }
exit(fail.isEmpty ? 0 : 1)

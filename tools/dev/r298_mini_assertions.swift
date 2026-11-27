// r298 迷你自测（2026-11-27 真机 bug）：搜不到时头部（含搜索框）不许消失
import Foundation

var pass = 0
var fail: [String] = []
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

check("有数据 → 头部（标题/播放/搜索）必须渲染", SongListRules.showsChrome(totalCount: 162))
check("真的一首都没有 → 才允许整页空态",
      SongListRules.trulyEmpty(totalCount: 0) && !SongListRules.showsChrome(totalCount: 0))

check("搜「zh」没命中 → 列表区提示（不是整页空态）",
      SongListRules.noMatch(totalCount: 162, shownCount: 0, query: "zh"))
check("搜索词全是空格 → 不算没命中",
      !SongListRules.noMatch(totalCount: 162, shownCount: 0, query: "  "))
check("有命中 → 不算没命中",
      !SongListRules.noMatch(totalCount: 162, shownCount: 3, query: "晴"))
check("本页真没数据 → 不算没命中（走整页空态）",
      !SongListRules.noMatch(totalCount: 0, shownCount: 0, query: "zh"))

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  失败：\(f)") }
    exit(1)
}

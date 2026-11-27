// r299 迷你自测（2026-11-27 老板纠正）：提交式搜索 4 条契约
import Foundation

var pass = 0
var fail: [String] = []
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func s(_ name: String, _ singer: String, _ id: String) -> Song {
    Song.make(platform: .kuwo, platformID: id, name: name, singer: singer, album: "",
              duration: 200, picURL: nil)
}
let pool = [s("晴天", "周杰伦", "1"), s("稻香", "周杰伦", "2")]

var st = ListSearchState()
check("初始无筛选", !st.isFiltering && st.committed.isEmpty)

st.typed = "zh"
check("① 输入未提交 → 不筛选", !st.isFiltering)
check("① 输入未提交 → 列表不变", SongListFilter.filter(pool, query: st.committed).count == 2)

st.submit()
check("② 回车后 → 进入筛选", st.isFiltering && st.committed == "zh")
check("② 回车后 → 无命中即空", SongListFilter.filter(pool, query: st.committed).isEmpty)

check("③ 空结果 → 头部/搜索框仍存在",
      SongListRules.showsChrome(totalCount: pool.count)
        && SongListRules.noMatch(totalCount: pool.count, shownCount: 0, query: st.committed))

st.clear()
check("④ 清除后 → 两段都空", st.typed.isEmpty && st.committed.isEmpty)
check("④ 清除后 → 恢复全量", SongListFilter.filter(pool, query: st.committed).count == 2)

st.typed = "稻香"
st.submit()
check("回车「稻香」→ 只剩 1 首", SongListFilter.filter(pool, query: st.committed).count == 1)

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty { for f in fail { print("  失败：\(f)") }; exit(1) }

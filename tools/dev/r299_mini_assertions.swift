// r299 迷你自测（2026-11-27 老板最终口径）：**实时过滤** + 永远能清除 + 空结果搜索框仍在
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

// ① 实时：只改 input，过滤立刻生效（不需要回车）
st.typed = "zzz"
check("① 敲 zzz → 实时进入筛选（不用回车）", st.isFiltering && st.committed == "zzz")
check("① 敲 zzz → 列表实时为空", SongListFilter.filter(pool, query: st.committed).isEmpty)
check("① 空结果时头部/搜索框仍在",
      SongListRules.showsChrome(totalCount: pool.count)
        && SongListRules.noMatch(totalCount: pool.count, shownCount: 0, query: st.committed))

// ② 清除 → 恢复全量
st.clear()
check("② 清除后 → 输入框与过滤都空", st.typed.isEmpty && st.committed.isEmpty)
check("② 清除后 → 恢复全量", SongListFilter.filter(pool, query: st.committed).count == 2)

// 实时命中：边打边缩
st.typed = "稻"
check("实时「稻」→ 只剩 1 首", SongListFilter.filter(pool, query: st.committed).count == 1)
st.typed = "稻香"
check("实时「稻香」→ 仍是 1 首", SongListFilter.filter(pool, query: st.committed).count == 1)

// ③ 有结果时滚动仍可见：头部常驻规则（吸顶由 pinnedViews 保证，规则层面 = showsChrome）
check("③ 有结果时头部/搜索框显示", SongListRules.showsChrome(totalCount: pool.count))

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty { for f in fail { print("  失败：\(f)") }; exit(1) }

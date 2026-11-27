// r297 迷你自测（2026-11-27）：歌曲集合页本页搜索 + 计数文案
import Foundation

var pass = 0
var fail: [String] = []
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}
func s(_ name: String, _ singer: String, _ album: String = "", _ id: String = "x") -> Song {
    Song.make(platform: .kuwo, platformID: id, name: name, singer: singer, album: album,
              duration: 200, picURL: nil)
}

let pool = [s("晴天", "周杰伦", "叶惠美", "1"), s("稻香", "周杰伦", "魔杰座", "2"),
            s("七里香", "周杰伦", "七里香", "3"), s("起风了", "买辣椒也用券", "", "4")]

check("空查询 = 全部", SongListFilter.filter(pool, query: "").count == 4)
check("按歌名命中", SongListFilter.filter(pool, query: "晴").map(\.platformID) == ["1"])
check("按歌手命中", SongListFilter.filter(pool, query: "周杰伦").count == 3)
check("按专辑命中", SongListFilter.filter(pool, query: "魔杰座").map(\.platformID) == ["2"])
check("没命中给空", SongListFilter.filter(pool, query: "不存在").isEmpty)
check("Live 版也能被「晴」搜到", SongListFilter.matches(s("晴天 (Live)", "周杰伦"), query: "晴"))

print("— 计数文案（老板：无搜索词时不显示）")
check("无搜索词 → nil", SongListFilter.filteredMetaText(shown: 4, total: 4, query: "") == nil)
check("纯空格搜索词 → nil", SongListFilter.filteredMetaText(shown: 4, total: 4, query: "   ") == nil)
check("有搜索词 → 筛选后文案",
      SongListFilter.filteredMetaText(shown: 1, total: 4, query: "晴")
        == "共 1 首（筛选后 · 全部 4 首）",
      SongListFilter.filteredMetaText(shown: 1, total: 4, query: "晴") ?? "nil")

print("— 包装类型（歌单条目）")
let releases = pool.map { KuwoPlaylist.Release(song: $0, releaseDate: "") }
check("filterItems 生效", SongListFilter.filterItems(releases, query: "稻香") { $0.song }.count == 1)
check("filterItems 空查询给全部", SongListFilter.filterItems(releases, query: "") { $0.song }.count == 4)

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  失败：\(f)") }
    exit(1)
}

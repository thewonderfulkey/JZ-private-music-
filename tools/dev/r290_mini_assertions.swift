// r290 迷你自测（2026-11-27）：歌手页「显示更多」
//
// 老板："周杰伦 1706 首，但只显示几十首……想在底部给一个显示更多，加载与上面不重复的歌。"
// 实测（本机 artistid=336）：data.total=1706，pn=1 / pn=2 返回不同的歌 → 接口本来就支持翻页。
import Foundation

var pass = 0
var fail: [String] = []
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}
func rel(_ rid: String) -> KuwoPlaylist.Release {
    KuwoPlaylist.Release(song: Song.make(platform: .kuwo, platformID: rid, name: "歌\(rid)",
                                         singer: "周杰伦", album: "", duration: 200, picURL: nil),
                         releaseDate: "")
}

print("— 还有没有更多")
check("50 / 1706 还有更多", ArtistPaging.hasMore(shown: 50, total: 1706))
check("1706 / 1706 到底了", !ArtistPaging.hasMore(shown: 1706, total: 1706))
check("接口没给总数也给按钮（不能被缺字段锁死）", ArtistPaging.hasMore(shown: 50, total: 0))
check("空列表不显示按钮", !ArtistPaging.hasMore(shown: 0, total: 1706))

print("— 进度文案")
check("带总数", ArtistPaging.progressText(shown: 50, total: 1706) == "已显示 50 / 1706",
      ArtistPaging.progressText(shown: 50, total: 1706))
check("无总数", ArtistPaging.progressText(shown: 300, total: 0) == "已显示 300 首",
      ArtistPaging.progressText(shown: 300, total: 0))

print("— 追加去重")
let first = [rel("1"), rel("2"), rel("3")]
let merged = ArtistPaging.appendUnique(first, adding: [rel("3"), rel("4")])
check("重复只留一条", merged.map(\.song.platformID) == ["1", "2", "3", "4"],
      "\(merged.map(\.song.platformID))")
check("同顺序保持", merged.first?.song.platformID == "1")
check("这一页全是旧的", ArtistPaging.addedNothing(first, adding: [rel("1"), rel("2")]))
check("这一页有新的", !ArtistPaging.addedNothing(first, adding: [rel("2"), rel("4")]))

print("— 接口解析（真实响应形状）")
let json: [String: Any] = ["code": 200, "data": [
    "total": 1706,
    "list": [[
        "rid": 3360001, "name": "晴天", "artist": "周杰伦", "album": "叶惠美",
        "duration": 269, "releasedate": "2003-07-31"
    ], [
        "rid": "3360002", "name": "稻香", "artist": "周杰伦", "album": "魔杰座",
        "duration": 223
    ]]
]]
if let page = KuwoArtist.parseSongsPage(json) {
    check("总数解析出来", page.total == 1706, "\(page.total)")
    check("两首都在", page.items.count == 2)
    check("rid 解析对", page.items.first?.song.platformID == "3360001")
    check("字符串 rid 也认", page.items.last?.song.platformID == "3360002")
} else {
    check("解析出 SongsPage", false, "nil")
}
check("空响应给 nil", KuwoArtist.parseSongsPage([:]) == nil)
check("code 非 200 给 nil", KuwoArtist.parseSongsPage(["code": 403, "data": [:]]) == nil)

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  失败：\(f)") }
    exit(1)
}

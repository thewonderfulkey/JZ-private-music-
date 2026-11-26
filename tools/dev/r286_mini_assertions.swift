// r286 迷你自测（2026-11-27）：网易发现源"取歌端点"口径
//
// 背景：`api/playlist/detail?id=`（v1）实测已回 0 首；能取到曲目的是
// `api/v3/playlist/detail?id=&n=`，且字段名不同（dt / ar / al）。
// 这条断言钉住三件事：
//   ① v3 形状能解析（时长/歌手/专辑/封面）
//   ② v1 老形状不能因为改口径弄坏（端点兜底还用得到）
//   ③ 歌单页要拿到名字 + 封面 + 曲目；空响应给 nil，不给"空歌单页"
//
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在歌词解密那节中止。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 网易取歌：v3 形状（dt/ar/al）")
let v3: [String: Any] = ["playlist": [
    "name": "热歌榜",
    "coverImgUrl": "http://c/hot.jpg",
    "tracks": [[
        "id": 3453304463,
        "name": "降温",
        "ar": [["name": "Zzh"]],
        "al": ["name": "降温", "picUrl": "http://p/v3.jpg"],
        "dt": 199229
    ]]
]]
let songs = NeteaseDiscover.parseChartSongs(v3)
check("v3 曲目解析出 1 首", songs.count == 1)
check("v3 时长取 dt（199229ms → 199s）", songs.first?.durationSec == 199,
      "\(songs.first?.durationSec ?? -1)")
check("v3 歌手取 ar", songs.first?.singer == "Zzh", songs.first?.singer ?? "nil")
check("v3 专辑取 al", songs.first?.album == "降温", songs.first?.album ?? "nil")
check("v3 封面取 al.picUrl", (songs.first?.picURL ?? "").contains("v3.jpg"),
      songs.first?.picURL ?? "nil")
check("v3 平台标成网易", songs.first?.platform == .netease)

print("— v1 老形状不能弄坏")
let v1: [String: Any] = ["playlist": ["tracks": [[
    "id": 186016, "name": "晴天",
    "artists": [["name": "周杰伦"]],
    "album": ["name": "叶惠美", "picUrl": "http://p/1.jpg"],
    "duration": 269000
]]]]
let v1Songs = NeteaseDiscover.parseChartSongs(v1)
check("v1 曲目解析出 1 首", v1Songs.count == 1)
check("v1 时长取 duration", v1Songs.first?.durationSec == 269,
      "\(v1Songs.first?.durationSec ?? -1)")
check("v1 歌手取 artists", v1Songs.first?.singer == "周杰伦")

print("— 歌单页（BANNER 的落点）")
let page = NeteaseDiscover.parseTrackPage(v3)
check("歌单页拿到名字", page?.name == "热歌榜", page?.name ?? "nil")
check("歌单页拿到封面", (page?.cover ?? "").contains("hot.jpg"), page?.cover ?? "nil")
check("歌单页有曲目且可见", (page?.songs.count ?? 0) == 1
      && DiscoverMergeRules.isVisible(page?.songs ?? []))

print("— 脏数据与边界")
let bigID: [String: Any] = ["playlist": ["tracks": [[
    "id": "18478568150", "name": "小天才", "ar": [], "al": [:], "dt": 100000
]]]]
check("字符串 id 也能解析（真实榜 id 已到 1.8e10）",
      NeteaseDiscover.parseChartSongs(bigID).first?.platformID == "18478568150",
      NeteaseDiscover.parseChartSongs(bigID).first?.platformID ?? "nil")
check("没有歌名的曲目被丢掉",
      NeteaseDiscover.parseChartSongs(["playlist": ["tracks": [["id": 1, "dt": 1000]]]]).isEmpty)
check("空 playlist → 没有歌单页", NeteaseDiscover.parseTrackPage([:]) == nil)
check("空 tracks → 0 首", NeteaseDiscover.parseChartSongs(["playlist": [:]]).isEmpty)
check("limit 生效", (NeteaseDiscover.parseTrackPage(v3, limit: 0)?.songs.count ?? -1) == 0)

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  失败：\(f)") }
    exit(1)
}

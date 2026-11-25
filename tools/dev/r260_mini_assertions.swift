// r260 迷你自测（2026-11-25 v2.4.119）：网易官方取流
//   事故：《众》"在线放不出来、却能下载"。第三方全空，但**网易自己的** player/url 一直有
//   320k mp3（8,620,845 B）和 FLAC（47,977,837 B）——我们从来没问过它。
//   坑：ids 必须 %5B…%5D，裸方括号会让 URL(string:) 返回 nil。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 网易官方 player/url")
check("档位 → br",
      NeteasePlayerAdapter.brParam(.lossless) == 999_000
      && NeteasePlayerAdapter.brParam(.high) == 320_000
      && NeteasePlayerAdapter.brParam(.standard) == 128_000)

let u = NeteasePlayerAdapter.url(ids: "1865532803", br: 320_000)
check("ids 用 %5B/%5D 包起来", u.contains("%5B1865532803%5D"), u)
check("URL(string:) 能解析（裸方括号会 nil）", URL(string: u) != nil, u)
check("br 参数真的进了 query", u.contains("br=320000"), u)

let real: [String: Any] = ["code": 200,
                           "data": [["url": "http://m10.music.126.net/a.mp3",
                                     "type": "mp3", "size": 8_620_845, "br": 320_000]]]
check("现行形状 data[0].url",
      NeteasePlayerAdapter.streamURL(from: real) == "http://m10.music.126.net/a.mp3",
      NeteasePlayerAdapter.streamURL(from: real))
check("url 为 null → 空串",
      NeteasePlayerAdapter.streamURL(from: ["code": 200, "data": [["url": NSNull()]]]).isEmpty)
check("没有 data → 空串", NeteasePlayerAdapter.streamURL(from: ["code": 200]).isEmpty)

print("— 注册表里排在本歌其它网易后端之前")
let neteaseBackends = SourceRegistry.all.filter { $0.platform == .netease }.map(\.name)
check("网易官方已注册", neteaseBackends.contains("网易官方"), neteaseBackends.joined(separator: "/"))
check("它排在 gdstudio 之前",
      (neteaseBackends.firstIndex(of: "网易官方") ?? 99) < (neteaseBackends.firstIndex(of: "gdstudio 网易") ?? -1),
      neteaseBackends.joined(separator: "/"))

print("")
print("PASS=\(pass) FAIL=\(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  ✗ \(f)") }
    exit(1)
}

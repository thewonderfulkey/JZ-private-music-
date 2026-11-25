// r259 迷你自测（2026-11-25 v2.4.118）：oiapi 响应形状
//   事故：v2.4.117 之后《众》彻底没源——oiapi 是它唯一的源，而这条通道从接进来起
//   就因为"只认 data 是数组"而一次都没成功过（真实响应是 data.items[]）。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— oiapi 响应形状")

let real: [String: Any] = ["code": 0,
                           "data": ["items": [["name": "众", "id": 1_865_532_803,
                                               "url": "http://m8.music.126.net/a.m4a"]]]]
check("现行形状 data.items[0].url",
      OiapiNeteaseAdapter.streamURL(from: real) == "http://m8.music.126.net/a.m4a",
      OiapiNeteaseAdapter.streamURL(from: real))

let legacyArray: [String: Any] = ["code": 0, "data": [["url": "http://x/y.mp3"]]]
check("老形状 data[0].url 仍然认",
      OiapiNeteaseAdapter.streamURL(from: legacyArray) == "http://x/y.mp3",
      OiapiNeteaseAdapter.streamURL(from: legacyArray))

let rootURL: [String: Any] = ["code": 0, "url": "http://x/z.mp3", "data": [String: Any]()]
check("根上的 url 也认", OiapiNeteaseAdapter.streamURL(from: rootURL) == "http://x/z.mp3",
      OiapiNeteaseAdapter.streamURL(from: rootURL))

let nullURL: [String: Any] = ["code": 0, "data": ["items": [["name": "晴天", "url": NSNull()]]]]
check("url 为 null → 空串", OiapiNeteaseAdapter.streamURL(from: nullURL).isEmpty,
      OiapiNeteaseAdapter.streamURL(from: nullURL))

let emptyItems: [String: Any] = ["code": 0, "data": ["items": [Any]()]]
check("items 空 → 空串", OiapiNeteaseAdapter.streamURL(from: emptyItems).isEmpty)
check("什么都没有 → 空串", OiapiNeteaseAdapter.streamURL(from: [:]).isEmpty)

// 顺带回归：这一轮的身份闸不能被这次改动带回去
func song(_ p: MusicPlatform, _ name: String, _ singer: String,
          album: String = "", dur: Int = 0, id: String) -> Song {
    Song.make(platform: p, platformID: id, name: name, singer: singer,
              album: album, duration: Double(dur), picURL: nil)
}
print("— 身份闸回归（v2.4.117 的口径）")
let zhong = song(.netease, "众", "黄霄雲", album: "众", dur: 215, id: "ne_zhong")
let ceyan = song(.qq, "侧脸", "黄霄雲", album: "侧脸", dur: 217, id: "qq_ceyan")
let zhongQQ = song(.qq, "众", "黄霄雲", album: "众", dur: 215, id: "qq_zhong")
check("众 vs 侧脸 → 拒", !NameMatch.sameRecording(src: zhong, cand: ceyan))
check("众 vs 众（另一平台）→ 过", NameMatch.sameRecording(src: zhong, cand: zhongQQ))

print("")
print("PASS=\(pass) FAIL=\(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  ✗ \(f)") }
    exit(1)
}

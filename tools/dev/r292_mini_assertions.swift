// r292 迷你自测（2026-11-27）：发现页双源（最新单曲交替合并 / 热门第二行）
import Foundation

var pass = 0
var fail: [String] = []
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}
func rel(_ p: MusicPlatform, _ name: String, _ singer: String, _ id: String,
         date: String = "") -> KuwoPlaylist.Release {
    KuwoPlaylist.Release(song: Song.make(platform: p, platformID: id, name: name, singer: singer,
                                         album: "", duration: 200, picURL: nil),
                         releaseDate: date)
}

check("网易榜 id 是实测值",
      DiscoverSourceIDs.neteaseHotChartID == "3778678"
        && DiscoverSourceIDs.neteaseNewChartID == "3779629")
check("露出条数 21 / 12",
      DiscoverSourceIDs.hotRowLimit == 21 && DiscoverSourceIDs.latestRowLimit == 12)

let kuwo = [rel(.kuwo, "晴天", "周杰伦", "k1", date: "2026-11-26"),
            rel(.kuwo, "七里香", "周杰伦", "k2", date: "2026-11-25")]
let netease = [Song.make(platform: .netease, platformID: "n1", name: "稻香", singer: "周杰伦",
                         album: "", duration: 223, picURL: nil),
               Song.make(platform: .netease, platformID: "n2", name: "青花瓷", singer: "周杰伦",
                         album: "", duration: 238, picURL: nil)]

let row = DiscoverLatestRules.latestRow(kuwo: kuwo, netease: netease)
check("交替 A1,B1,A2,B2", row.map(\.song.platformID) == ["k1", "n1", "k2", "n2"],
      "\(row.map(\.song.platformID))")
check("酷我保留发行日", row.first?.releaseDate == "2026-11-26" && row.first?.shortDate == "11-26")
check("网易没有日期就留空", row.first(where: { $0.song.platform == .netease })?.releaseDate == "")

let dup = DiscoverLatestRules.latestRow(
    kuwo: [rel(.kuwo, "晴天", "周杰伦", "k1")],
    netease: [Song.make(platform: .netease, platformID: "n9", name: "晴天", singer: "周杰伦",
                        album: "", duration: 269, picURL: nil)])
check("跨源同一首只留一条且保留酷我", dup.count == 1 && dup[0].song.platform == .kuwo)

check("一家为空照常显示另一家",
      DiscoverLatestRules.latestRow(kuwo: [], netease: netease).count == 2
        && DiscoverLatestRules.latestRow(kuwo: kuwo, netease: []).count == 2)
check("两家都空 → 空", DiscoverLatestRules.latestRow(kuwo: [], netease: []).isEmpty)
check("limit 生效", DiscoverLatestRules.latestRow(kuwo: kuwo, netease: netease, limit: 3).count == 3)
check("limit 0 不崩", DiscoverLatestRules.latestRow(kuwo: kuwo, netease: netease, limit: 0).isEmpty)

let big = (1...40).map { Song.make(platform: .netease, platformID: "h\($0)", name: "歌\($0)",
                                   singer: "x", album: "", duration: 200, picURL: nil) }
check("第二行最多 21", DiscoverLatestRules.hotRow(big).count == 21)
check("不足 21 原样给", DiscoverLatestRules.hotRow(Array(big.prefix(5))).count == 5)

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  失败：\(f)") }
    exit(1)
}

// 下载页「按歌手筛选」迷你自测（2026-11-23）
//   ① 歌手归并键只做空白归一：不拆合唱、不取第一歌手、不做繁简（老板："名字都是对的，人工改过"）
//   ② 聚合只数「已下载」：在飞 / 失败不进歌手清单；条数降序，顺序稳定
//   ③ 筛选：nil = 全部；命中歌手 / 命中「未知歌手」；库里没有的歌手 = 空
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止，
// 而这段断言在文件末尾，永远跑不到。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func item(_ name: String, _ singer: String, dur: Int = 240, id: String,
          status: DownloadStatus = .completed) -> DownloadItem {
    let song = Song(platform: .local, platformID: "song_\(id)", name: name, singer: singer,
                    album: "", duration: Double(dur), picURL: nil)
    return DownloadItem(song: song, streamURL: "file:///\(name)", backendName: "本地导入",
                        quality: .lossless, fileName: "\(name).flac",
                        localPath: "/x/\(name).flac", status: status,
                        totalBytes: 8_000_000, createdAt: Date(timeIntervalSince1970: 1))
}

print("\n— ① 歌手归并键（只有空白归一）")
check("全角空格 / 不间断空格被压成普通空格",
      DownloadArtistFilter.artistKey("周杰伦\u{3000} \u{00A0}") == "周杰伦",
      DownloadArtistFilter.artistKey("周杰伦\u{3000} \u{00A0}"))
check("中间多个空格压成一个",
      DownloadArtistFilter.artistKey("Adele  Adkins") == "Adele Adkins")
check("只有空白 → 未知歌手",
      DownloadArtistFilter.artistKey("   ") == DownloadArtistFilter.unknownArtist)
check("零宽字符不会造出第二个歌手",
      DownloadArtistFilter.artistKey("周杰伦\u{200B}") == DownloadArtistFilter.artistKey("周杰伦"))
check("合唱名原样保留", DownloadArtistFilter.artistKey("周杰伦&袁咏琳") == "周杰伦&袁咏琳")
check("合唱不被并进单人歌手",
      DownloadArtistFilter.artistKey("周杰伦&袁咏琳") != DownloadArtistFilter.artistKey("周杰伦"))

print("\n— ② 聚合")
let items = [
    item("晴天", "周杰伦", dur: 269, id: "a"),
    item("七里香", "周杰伦", dur: 299, id: "b"),
    item("夜曲", "周杰伦", dur: 226, id: "c"),
    item("小酒窝", "林俊杰、蔡卓妍", dur: 231, id: "d"),
    item("江南", "林俊杰", dur: 268, id: "e"),
    item("没歌手", "", id: "f"),
    item("正在下的", "周杰伦", id: "g", status: .downloading),
    item("失败的", "周杰伦", id: "h", status: .failed),
]
let groups = DownloadArtistFilter.groups(items)
let jay = groups.first { $0.name == "周杰伦" }
check("只数已下载（在飞 / 失败不进歌手清单）", jay?.count == 3, "count=\(jay?.count ?? -1)")
check("空歌手归到「未知歌手」",
      groups.contains { $0.name == DownloadArtistFilter.unknownArtist && $0.count == 1 })
check("合唱是独立一项，不并进「林俊杰」",
      groups.contains { $0.name == "林俊杰、蔡卓妍" && $0.count == 1 }
        && groups.first { $0.name == "林俊杰" }?.count == 1)
check("条数降序（周杰伦第一）", groups.first?.name == "周杰伦", groups.first?.name ?? "—")
check("总时长按首累计", jay?.seconds == 269 + 299 + 226, "\(jay?.seconds ?? -1)")
check("两次调用顺序完全一致", DownloadArtistFilter.groups(items).map(\.name) == groups.map(\.name))
print("     歌手清单：" + groups.map { "\($0.name)(\($0.count))" }.joined(separator: "、"))

print("\n— ③ 筛选")
check("nil = 全部，一条不动", DownloadArtistFilter.filter(items, artist: nil).count == items.count)
// 注意：`filter` 只按歌手筛，**不按状态筛** —— 分区（正在下载 / 失败 / 已下载）是列表层的事。
// 所以同一位歌手正在下的、失败的也会一起留下（筛了歌手就该只看这位歌手的一切状态）。
check("只留这位歌手（含在飞 / 失败，分区是列表层的事）",
      DownloadArtistFilter.filter(items, artist: "周杰伦").map { $0.song.name }
        == ["晴天", "七里香", "夜曲", "正在下的", "失败的"])
check("只留已下载时：条数与聚合里的 count 对得上",
      DownloadArtistFilter.filter(items, artist: "周杰伦")
        .filter { $0.status == .completed }.count == jay?.count)
check("能命中「未知歌手」",
      DownloadArtistFilter.filter(items, artist: DownloadArtistFilter.unknownArtist).count == 1)
check("库里没有的歌手 = 空", DownloadArtistFilter.filter(items, artist: "邓紫棋").isEmpty)
check("contains：删光后能退回「全部」",
      DownloadArtistFilter.contains("周杰伦", in: items)
        && !DownloadArtistFilter.contains("邓紫棋", in: items))

print("\n— ④ 定位配对（2026-11-23 真机：筛选切回全部了，但没滚过去）")
let pair = ListLocate.pair(items)
check("songs 与 rowIDs 同长", pair.songs.count == items.count && pair.rowIDs.count == items.count)
check("第 i 个 song 就是第 i 行（顺序原样搬运）",
      pair.songs == items.map(\.song) && pair.rowIDs == items.map(\.id))
if let idx = ListLocate.index(of: items[4].song, in: pair.songs) {
    check("算出的下标能取到同一行（不错位）", pair.rowIDs[idx] == items[4].id, "idx=\(idx)")
} else {
    check("算出的下标能取到同一行（不错位）", false, "没找到下标")
}
let reversed = Array(items.reversed())
let pairRev = ListLocate.pair(reversed)
check("反序输入两列一起反，不自己排序",
      pairRev.rowIDs == reversed.map(\.id) && pairRev.songs == reversed.map(\.song))
let jayOnly = DownloadArtistFilter.filter(items, artist: "周杰伦")
let pairJay = ListLocate.pair(jayOnly)
check("筛选后的子集两列同样对齐",
      pairJay.rowIDs.count == jayOnly.count
        && pairJay.songs.map(\.name) == jayOnly.map { $0.song.name })

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  ✗ \(f)") }
    exit(1)
}
print("全部通过")
exit(0)

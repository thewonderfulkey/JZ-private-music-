// v2.4.72（第 57 轮）迷你自测：只跑本轮新增的纯函数口径。
// 本轮两件：
//   ① 下载列表「新的在最上面」—— `DownloadItem.newestFirst`
//   ② 起播不再中途换源（开头卡顿）—— `DownloadResolver.bestForStart` / `startWindow`
// 用法：bash tools/dev/run_mini_assertions.sh tools/dev/r189_mini_assertions.swift
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func song(_ platform: MusicPlatform, _ name: String, _ singer: String,
          dur: Int = 269, id: String) -> Song {
    Song(platform: platform, platformID: id, name: name, singer: singer,
         album: "", duration: Double(dur), picURL: nil)
}

print("— 下载列表顺序：新的在最上面（老板 17:36 录屏）")

func item(_ name: String, _ sec: TimeInterval) -> DownloadItem {
    DownloadItem(song: song(.qq, name, "歌手", id: "s_\(name)"),
                 streamURL: "file:///\(name).flac", backendName: "import",
                 quality: .lossless, fileName: "\(name).flac",
                 status: .completed, totalBytes: 1_000,
                 createdAt: Date(timeIntervalSince1970: sec))
}

let old = item("老歌", 100)
let mid = item("中间", 200)
let new = item("新歌", 300)
check("新的排最前", DownloadItem.newestFirst([old, mid, new]).map(\.song.name) == ["新歌", "中间", "老歌"],
      "\(DownloadItem.newestFirst([old, mid, new]).map(\.song.name))")
check("落库顺序打乱也一样", DownloadItem.newestFirst([mid, new, old]).map(\.song.name) == ["新歌", "中间", "老歌"])
check("空列表不炸", DownloadItem.newestFirst([]).isEmpty)

let batchA = item("A", 500), batchB = item("B", 500), batchC = item("C", 500)
check("同一秒的：后入的先显示",
      DownloadItem.newestFirst([batchA, batchB, batchC]).map(\.song.name) == ["C", "B", "A"])
check("同一秒的：重复调用顺序稳定",
      DownloadItem.newestFirst([batchA, batchB, batchC]).map(\.id)
        == DownloadItem.newestFirst([batchA, batchB, batchC]).map(\.id))

print("— 起播挑选：够档立刻起播，起播后不再换源")

func src(_ kbps: Int64, _ backend: String) -> StreamSource {
    StreamSource(url: "https://x/\(backend)", backendName: backend, platform: .kugou,
                 quality: .high, format: "mp3", note: "",
                 kbps: kbps, totalBytes: 10_000_000)
}
func cand(_ s: StreamSource, ms: Int) -> DownloadResolver.Candidate {
    DownloadResolver.Candidate(
        song: song(.kugou, "下一个天亮", "我的音乐调频", id: "kg_x"),
        source: s, elapsedMs: ms,
        score: DownloadResolver.Score(tier: DownloadResolver.tierOf(s), version: 300,
                                      duration: 100, reliable: 90, ms: ms))
}
let k128 = src(128, "酷狗官方")
let k320 = src(321, "星海酷狗")
let k256 = src(256, "某后端")

check("320 压过先到的 128",
      DownloadResolver.bestForStart([cand(k128, ms: 200), cand(k320, ms: 900)])?.source.backendName == "星海酷狗",
      "\(DownloadResolver.bestForStart([cand(k128, ms: 200), cand(k320, ms: 900)])?.source.backendName ?? "nil")")
check("只有 128 时就用 128", DownloadResolver.bestForStart([cand(k128, ms: 200)])?.source.kbps == 128)
check("同档取码率更高的", DownloadResolver.bestForStart([cand(k256, ms: 300), cand(k320, ms: 800)])?.source.kbps == 321)
check("同档同码率取更快的", DownloadResolver.bestForStart([cand(k320, ms: 900), cand(k320, ms: 400)])?.elapsedMs == 400)
check("一条都没有 → nil", DownloadResolver.bestForStart([]) == nil)
check("起播窗口 1.6s、够档门槛 700",
      DownloadResolver.startWindow == 1.6 && DownloadResolver.startGoodEnoughTier == 700,
      "\(DownloadResolver.startWindow) / \(DownloadResolver.startGoodEnoughTier)")
check("128k 不够档", DownloadResolver.tierOf(k128) < DownloadResolver.startGoodEnoughTier)
check("320k 够档", DownloadResolver.tierOf(k320) >= DownloadResolver.startGoodEnoughTier)

print("")
print(fail.isEmpty ? "全部通过：\(pass) 条" : "失败 \(fail.count) 条：\(fail.joined(separator: " / "))")
exit(fail.isEmpty ? 0 : 1)

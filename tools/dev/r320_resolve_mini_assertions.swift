// r320 迷你自测（2026-11-28）：识曲主结果的时长闸门
// 本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在歌词解密那节中止；这里只跑本轮新增断言。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func fixSong(_ id: String, _ name: String, _ dur: Double,
             _ singer: String = "周杰伦", _ album: String = "十一月的萧邦") -> Song {
    Song(platform: .kugou, platformID: id, name: name, singer: singer,
         album: album, duration: dur, picURL: nil)
}

let cand = RecognizeCandidate(title: "夜曲", artist: "周杰伦",
                              album: "十一月的萧邦", durationSec: 226,
                              source: RecognizeScore.sourceKugou,
                              rank: 0, isOriginal: 1)
let clip = fixSong("clip", "夜曲 - A35", 108)
let real = fixSong("real", "夜曲", 226)

print("— 识曲主结果：时长闸门")
check("1:48 剪辑不选", RecognizeResolveRules.pick(from: [clip], candidate: cand) == nil)
check("3:46 正版选它",
      RecognizeResolveRules.pick(from: [clip, real], candidate: cand)?.id == real.id)
check("差 4s 仍选",
      RecognizeResolveRules.pick(from: [fixSong("near", "夜曲", 222)], candidate: cand)?.id == "kugou_near")
check("差 6s 不选",
      RecognizeResolveRules.pick(from: [fixSong("far", "夜曲", 232)], candidate: cand) == nil)
check("未知时长不硬拒",
      RecognizeResolveRules.pick(from: [fixSong("unknown", "夜曲", 0)], candidate: cand)?.id == "kugou_unknown")

print("通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty { exit(1) }

// r321 迷你自测（2026-11-29）：识曲主结果的歌手硬闸 + title-only 合并 + 翻唱标签
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

print("— v2.4.139 时长闸门（回归）")
let nightCand = RecognizeCandidate(title: "夜曲", artist: "周杰伦",
                                   album: "十一月的萧邦", durationSec: 226,
                                   source: RecognizeScore.sourceKugou,
                                   rank: 0, isOriginal: 1)
let nightClip = fixSong("clip", "夜曲 - A35", 108)
let nightReal = fixSong("real", "夜曲", 226)
check("1:48 剪辑不选", RecognizeResolveRules.pick(from: [nightClip], candidate: nightCand) == nil)
check("3:46 正版选它",
      RecognizeResolveRules.pick(from: [nightClip, nightReal], candidate: nightCand)?.id == nightReal.id)
check("差 4s 仍选",
      RecognizeResolveRules.pick(from: [fixSong("near", "夜曲", 222)], candidate: nightCand)?.id == "kugou_near")
check("差 6s 不选",
      RecognizeResolveRules.pick(from: [fixSong("far", "夜曲", 232)], candidate: nightCand) == nil)
check("未知时长不硬拒",
      RecognizeResolveRules.pick(from: [fixSong("unknown", "夜曲", 0)], candidate: nightCand)?.id == "kugou_unknown")

print("— v2.4.140 歌手硬闸 + title-only 版本")
let coverCand = RecognizeCandidate(title: "5:20AM(活凤版)", artist: "礼崩乐不坏",
                                   album: "5:20AM(活凤版)", durationSec: 193,
                                   source: RecognizeScore.sourceNetease,
                                   rank: 0, isOriginal: 0)
let otherCover = fixSong("other", "5:20AM (河南话原版)", 191, "夜晚助眠屋", "5:20AM")
let sameCover = fixSong("same", "5:20AM(活凤版)", 193, "礼崩乐不坏", "5:20AM(活凤版)")
check("归一化歌名相同但歌手不同：不选",
      RecognizeResolveRules.pick(from: [otherCover], candidate: coverCand) == nil)
check("同歌手同版本：选它",
      RecognizeResolveRules.pick(from: [otherCover, sameCover], candidate: coverCand)?.id == "kugou_same")

let primaryCover = fixSong("m1", "潮汐", 178, "小青芽", "ACG 合辑")
let broadOriginal = fixSong("m2", "潮汐 (Natural)", 212, "安苏羽、傅梦彤", "潮汐")
let broadDup = fixSong("m3", "潮汐", 178, "小青芽", "ACG 合辑")
let merged = RecognizeResolveRules.mergeSearchResults(primary: [primaryCover],
                                                      broad: [broadOriginal, broadDup])
check("title-only 合并：同一条录音去重", merged.count == 2, "\(merged.count)")
check("title-only 合并：原唱被捞进来", merged.contains { $0.singer.contains("安苏羽") })
check("合辑专辑标翻唱/版本",
      StudioPick.isCoverLike(title: "潮汐", album: "ACG 合辑"))
check("括号版本标翻唱/版本",
      StudioPick.isCoverLike(title: "5:20AM(活凤版)", album: "5:20AM(活凤版)"))
check("正常录音室不标",
      !StudioPick.isCoverLike(title: "夜曲", album: "十一月的萧邦"))

print("通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty { exit(1) }

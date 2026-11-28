// r317 迷你自测（2026-11-28）：BANNER 韩语歌单《BABY ANGEL》被跳过
//
// 验证两件事：
//   ① 身份闸的「歌手译名桥」：林娜琏 vs NAYEON (TWICE)，歌名+专辑一致 → 认；
//      并且不能把《众》/《侧脸》那类放回来。
//   ② 诊断分三态：搜索空 / 闸全丢 / 候选有但腿全空，各有各的话。
import Foundation

var passed = 0
var failed = 0

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { passed += 1; print("  ✓ \(name)") }
    else { failed += 1; print("  ✗ \(name)  ← \(extra)") }
}

print("— 身份闸：外文歌手译名 vs 原名")

let src = Song.make(platform: .netease, platformID: "3462919608",
                    name: "BABY ANGEL", singer: "林娜琏", album: "NA-sty",
                    duration: 135, picURL: nil)
let yaohu = Song.make(platform: .kuwo, platformID: "yaohu:1",
                      name: "BABY ANGEL", singer: "NAYEON (TWICE)", album: "NA-sty",
                      duration: 0, picURL: nil)

check("真机那一对要认（歌名+专辑一致，歌手译名不同）",
      NameMatch.sameRecording(src: src, cand: yaohu))
check("桥本身成立", NameMatch.singerMismatchBridgedByTitle(src: src, cand: yaohu))
check("歌手对得上时桥不成立（不放行理由唯一）",
      !NameMatch.singerMismatchBridgedByTitle(
        src: src,
        cand: Song.make(platform: .qq, platformID: "q0", name: "BABY ANGEL",
                        singer: "林娜琏", album: "NA-sty", duration: 135, picURL: nil)))

let coverOtherAlbum = Song.make(platform: .qq, platformID: "q1", name: "BABY ANGEL",
                                singer: "某翻唱歌手", album: "翻唱合集",
                                duration: 135, picURL: nil)
check("同名同时长但专辑不同 → 不收（翻唱）",
      !NameMatch.sameRecording(src: src, cand: coverOtherAlbum))

let noAlbum = Song.make(platform: .netease, platformID: "n2", name: "BABY ANGEL",
                        singer: "林娜琏", album: "", duration: 135, picURL: nil)
let noAlbumFar = Song.make(platform: .qq, platformID: "q2", name: "BABY ANGEL",
                           singer: "NAYEON", album: "", duration: 139, picURL: nil)
let noAlbumNear = Song.make(platform: .qq, platformID: "q3", name: "BABY ANGEL",
                            singer: "NAYEON", album: "", duration: 135, picURL: nil)
check("两边都没专辑、时长差 4s → 不收",
      !NameMatch.sameRecording(src: noAlbum, cand: noAlbumFar))
check("两边都没专辑、时长一致 → 收", NameMatch.sameRecording(src: noAlbum, cand: noAlbumNear))

let live = Song.make(platform: .qq, platformID: "q4", name: "BABY ANGEL (Live)",
                     singer: "NAYEON (TWICE)", album: "NA-sty", duration: 135, picURL: nil)
check("Live 版照样拦（版本类在歌手之前）", !NameMatch.sameRecording(src: src, cand: live))

let zhong = Song.make(platform: .netease, platformID: "z1", name: "众", singer: "黄霄雲",
                      album: "众", duration: 215.5, picURL: nil)
let ceLian = Song.make(platform: .qq, platformID: "z2", name: "侧脸", singer: "黄霄雲",
                       album: "侧脸", duration: 217.8, picURL: nil)
check("防回归：众 ≠ 侧脸", !NameMatch.sameRecording(src: zhong, cand: ceLian))

let sameAlbumOtherSong = Song.make(platform: .qq, platformID: "z3", name: "侧脸",
                                   singer: "黄霄雲", album: "众", duration: 217.8, picURL: nil)
check("防回归：同名专辑里的另一首也不收",
      !NameMatch.sameRecording(src: zhong, cand: sameAlbumOtherSong))

// 歌手包含关系照旧（QQ 的「娜琏 (나연)」走的是老通道，不靠新桥）
let qqNayeon = Song.make(platform: .qq, platformID: "q9", name: "BABY ANGEL",
                         singer: "娜琏 (나연)", album: "", duration: 135, picURL: nil)
check("QQ 的「娜琏 (나연)」仍然靠歌手包含关系过闸",
      NameMatch.sameRecording(src: src, cand: qqNayeon))

print("— 诊断三分：搜索空 / 闸全丢 / 腿全空")
check("搜索空 → 不会赖给身份闸",
      SameSongCrossResolver.emptyDiagnostic(.init()).contains("一条都没回来"))
var gateDropped = SameSongCrossResolver.CandidateSet()
gateDropped.rawCount = 7
gateDropped.gateDropped = ["BABY ANGEL/NAYEON (TWICE)/135s"]
let gateText = SameSongCrossResolver.emptyDiagnostic(gateDropped)
check("闸全丢 → 报条数 + 被丢样本",
      gateText.contains("7 条") && gateText.contains("身份闸全丢"))
var uploader = SameSongCrossResolver.CandidateSet()
uploader.rawCount = 5
uploader.uploaderSinger = true
uploader.uploaderDropped = ["晴天|269s"]
check("歌手是上传者 → 单独说",
      SameSongCrossResolver.emptyDiagnostic(uploader).contains("上传者"))

print("\n通过 \(passed) / 失败 \(failed)")
if failed > 0 { exit(1) }

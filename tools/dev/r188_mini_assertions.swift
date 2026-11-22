// v2.4.71（第 56 轮）迷你自测：只跑本轮新增的纯函数口径。
// 本轮：候选身份闸加一道「歌手是频道号/上传者 → 只认歌名一致」，
// 修《下一个天亮》(我的音乐调频) 播放中串成《怎么会狠心伤害我》那个 bug。
// 为什么单独编：本机 WSL 的 zlib 桩会在官方 SelfTest 的"歌词解密"那节中止，后面几节跑不到。
// 用法：bash tools/dev/run_mini_assertions.sh tools/dev/r188_mini_assertions.swift
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

print("— 真实案例：《下一个天亮》/ 我的音乐调频（录屏里串成《怎么会狠心伤害我》）")

let pl = song(.kugou, "下一个天亮", "我的音乐调频", dur: 263, id: "kg_27e25b70")
let siblingExact = song(.kuwo, "怎么会狠心伤害我", "我的音乐调频", dur: 263, id: "kw_347079287")
let siblingEdge = song(.kuwo, "简单爱", "我的音乐调频", dur: 267, id: "kw_442871468")
let siblingFar = song(.kuwo, "心锁", "我的音乐调频", dur: 255, id: "kw_347075531")
let realCover = song(.netease, "下一个天亮", "郭静", dur: 266, id: "ne_233882")
let pool = [siblingExact, siblingEdge, siblingFar, realCover]

check("老口径确实放行（歌手同 + 时长差 0）",
      SameSongCrossResolver.sameSong(src: pl, cand: siblingExact))
check("池子里歌名一首都没对上 → 认作频道号/上传者",
      NameMatch.looksLikeUploader(pl, among: pool))
check("收紧后：同上传者的别的歌（263s，差 0）→ 拒",
      !SameSongCrossResolver.sameSong(src: pl, cand: siblingExact, uploaderLike: true))
check("收紧后：同上传者的别的歌（267s，差 4s）→ 拒",
      !SameSongCrossResolver.sameSong(src: pl, cand: siblingEdge, uploaderLike: true))
check("收紧后：时长差 8s 的照旧被老口径拒",
      !SameSongCrossResolver.sameSong(src: pl, cand: siblingFar, uploaderLike: true))
check("收紧后：真同曲换个平台（歌名一致）→ 通过",
      SameSongCrossResolver.sameSong(
        src: pl,
        cand: song(.kuwo, "下一个天亮", "我的音乐调频", dur: 263, id: "kw_nd"),
        uploaderLike: true))

print("— 不许误伤真人歌手")

let jay = song(.qq, "晴天", "周杰伦", dur: 269, id: "qq_qt")
let jayPool = [jay,
               song(.kugou, "夜曲", "周杰伦", dur: 226, id: "kg_yq"),
               song(.kugou, "七里香", "周杰伦", dur: 299, id: "kg_qlx"),
               song(.kuwo, "晴天", "周杰伦", dur: 269, id: "kw_qt")]
check("真人歌手（他自己的歌在池子里）→ 不算频道号",
      !NameMatch.looksLikeUploader(jay, among: jayPool))
check("真人歌手不收严：歌名不同也照旧通过",
      SameSongCrossResolver.sameSong(
        src: jay,
        cand: song(.netease, "晴天 (周杰伦)", "周杰伦", dur: 269, id: "ne_qt"),
        uploaderLike: false))

print("— 不许误伤译名案（2026-11-19 口径）")

let krSrc = song(.qq, "恋爱的条件", "BESTie (베스티)", dur: 194, id: "kr_src")
let krCand = song(.netease, "연애의 조건 (Love Options)", "BESTie", dur: 194, id: "kr_ne")
let krPool = [krCand, song(.kuwo, "연애의 조건 (Inst.)", "BESTie", dur: 192, id: "kr_inst")]
check("译名案：去重后只有 1 个歌名 → 不算频道号",
      !NameMatch.looksLikeUploader(krSrc, among: krPool))
check("译名案：照旧判为同一首",
      SameSongCrossResolver.sameSong(src: krSrc, cand: krCand, uploaderLike: false))

print("— 边界：两首对不上就算不上频道号（阈值 3）")
let twoOnly = [siblingExact, siblingEdge]
check("只有 2 个不同歌名 → 不认作频道号（宁漏不误）",
      !NameMatch.looksLikeUploader(pl, among: twoOnly))

print("")
print(fail.isEmpty ? "全部通过：\(pass) 条" : "失败 \(fail.count) 条：\(fail.joined(separator: " / "))")
exit(fail.isEmpty ? 0 : 1)

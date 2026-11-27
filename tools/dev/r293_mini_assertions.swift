// r293 迷你自测（2026-11-27）：封面「原曲兜底」+ 变速条目的播放兜底
//
// 老板截屏：《烟火里的尘埃 0.8x》/「你是我的救赎」——① 没有封面；② 点播被跳过。
// 同一个病根：这类型条目的「歌手」是上传者/改编者，与任何平台的歌都对不上，
// 而封面链与播放链的身份闸都要求"歌手有交集"。
import Foundation

var pass = 0
var fail: [String] = []
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 削尾巴")
check("0.8x 尾巴", CoverFallbackRules.baseTitle("烟火里的尘埃 0.8x") == "烟火里的尘埃",
      CoverFallbackRules.baseTitle("烟火里的尘埃 0.8x"))
check("括号里的 0.8x", CoverFallbackRules.baseTitle("烟火里的尘埃（0.8x）") == "烟火里的尘埃")
check("1.25x", CoverFallbackRules.baseTitle("晴天 1.25x") == "晴天")
check("0.8 倍速", CoverFallbackRules.baseTitle("晴天 0.8 倍速") == "晴天")
check("slowed", CoverFallbackRules.baseTitle("晴天 (slowed)") == "晴天")
check("sped up", CoverFallbackRules.baseTitle("晴天 sped up") == "晴天")
check("dj版", CoverFallbackRules.baseTitle("晴天 dj版") == "晴天")
check("伴奏", CoverFallbackRules.baseTitle("晴天（伴奏）") == "晴天")
check("翻唱", CoverFallbackRules.baseTitle("晴天 翻唱") == "晴天")
check("没有尾巴原样返回", CoverFallbackRules.baseTitle("晴天") == "晴天")
check("整名就是标记 → 放弃", CoverFallbackRules.baseTitle("0.8x").isEmpty)

print("— 封面兜底接受条件")
check("正文对得上就收（不要求歌手）",
      CoverFallbackRules.acceptsBaseCover(originalName: "烟火里的尘埃 0.8x",
                                          candidateName: "烟火里的尘埃"))
check("Live 版封面也收",
      CoverFallbackRules.acceptsBaseCover(originalName: "烟火里的尘埃 0.8x",
                                          candidateName: "烟火里的尘埃 (Live)"))
check("歌名不同不收",
      !CoverFallbackRules.acceptsBaseCover(originalName: "烟火里的尘埃 0.8x",
                                           candidateName: "烟火"))
check("太短不兜底",
      !CoverFallbackRules.acceptsBaseCover(originalName: "众 0.8x", candidateName: "众"))
check("繁简差异照样认",
      CoverFallbackRules.acceptsBaseCover(originalName: "煙火里的塵埃 0.8x",
                                          candidateName: "烟火里的尘埃"))

print("— 播放兜底（同一病根）")
check("有尾巴才允许",
      SameSongCrossResolver.variantAccepts(originalName: "烟火里的尘埃 0.8x",
                                           candidateName: "烟火里的尘埃"))
check("没尾巴不许（守住原身份闸）",
      !SameSongCrossResolver.variantAccepts(originalName: "晴天", candidateName: "晴天"))
check("歌名对不上不许",
      !SameSongCrossResolver.variantAccepts(originalName: "烟火里的尘埃 0.8x",
                                            candidateName: "烟火"))
check("太短不许",
      !SameSongCrossResolver.variantAccepts(originalName: "众 0.8x", candidateName: "众"))
check("Live 版也认",
      SameSongCrossResolver.variantAccepts(originalName: "烟火里的尘埃 0.8x",
                                           candidateName: "烟火里的尘埃 (Live)"))

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  失败：\(f)") }
    exit(1)
}

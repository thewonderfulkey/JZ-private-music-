// r2k4d54 迷你自测（2026-11-21 v2.4.54）：导入歌元数据匹配
//   ① A/B 两解（文件名拆反时能救回来）
//   ② 打分与阈值边界（0.85 / 0.60）
//   ③ 硬闸门（不同歌手 / 时长差 >8s 直接拒，绝不错配）
//   ④ 字段锁（手填的字段不被自动匹配覆盖）
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func song(_ name: String, _ singer: String, album: String = "", dur: Double = 240,
          id: String = "x1", source: MetaSource = .filenameGuess,
          locked: [MetaField] = [], platform: MusicPlatform = .local) -> Song {
    Song.make(platform: platform, platformID: id, name: name, singer: singer, album: album,
              duration: dur, picURL: nil)
        .with(meta: MetaProvenance(source: source, locked: locked))
}

print("— 解释：A/B 两解只在「文件名推测」时才对调")
let swappedSong = song("Avril Lavigne", "When You're Gone")          // 拆反的样子
check("文件名推测 → 两解", MetadataMatcher.queries(for: swappedSong).count == 2)
check("标签来源 → 只有一解（不怀疑标签）",
      MetadataMatcher.queries(for: song("Avril Lavigne", "When You're Gone", source: .tag)).count == 1)
check("网络搜来的歌（meta=nil）也不对调",
      MetadataMatcher.queries(for: Song.make(platform: .qq, platformID: "n1", name: "A",
                                             singer: "B", album: "", duration: 1,
                                             picURL: nil)).count == 1)
check("单段文件名（无歌手）→ 一解",
      MetadataMatcher.queries(for: song("炎", "")).count == 1)

print("— 打分")
check("歌名完全相等 = 1.0", MetadataMatcher.titleScore("到此为止", "到此为止") == 1.0)
check("核心名相同（版本不同）= 0.85", MetadataMatcher.titleScore("七里香", "七里香 (Live)") == 0.85)
check("歌手片段相等 = 1.0", MetadataMatcher.artistScore("徐佳莹", "徐佳莹/某某") == 1.0)
check("歌手完全无关 = 0", MetadataMatcher.artistScore("徐佳莹", "周杰伦") == 0)
check("时长差 3s 满分", MetadataMatcher.durationScore(240, 243) == 1.0)
check("时长差 6s 半分", MetadataMatcher.durationScore(240, 246) == 0.5)
check("时长差 20s 零分", MetadataMatcher.durationScore(240, 260) == 0)

print("— 阈值边界（老板拍板：≥0.85 自动 / 0.6–0.85 确认 / <0.6 拒）")
check("0.85 → auto", MetadataMatcher.verdict(for: 0.85) == .auto)
check("0.849 → confirm", MetadataMatcher.verdict(for: 0.849) == .confirm)
check("0.60 → confirm", MetadataMatcher.verdict(for: 0.60) == .confirm)
check("0.599 → reject", MetadataMatcher.verdict(for: 0.599) == .reject)

print("— 硬闸门：错配比缺失更糟")
let perfect = song("到此为止", "徐佳莹", album: "理想人生", dur: 220, id: "qq1")
let sameNameOtherSinger = song("到此为止", "某某某", album: "别的一张", dur: 221, id: "qq2")
let longDelta = song("到此为止", "徐佳莹", album: "理想人生", dur: 260, id: "qq3")
check("歌名对 + 歌手对 + 时长 1s 差 → 选它",
      MetadataMatcher.pick(song: perfect, candidates: [perfect]).verdict == .auto)
check("同歌名但不同歌手 → 拒",
      MetadataMatcher.pick(song: perfect, candidates: [sameNameOtherSinger]).verdict == .reject)
check("歌手对但时长差 40s（另一个录音）→ 拒",
      MetadataMatcher.pick(song: perfect, candidates: [longDelta]).verdict == .reject)

print("— 拆反能救回来（Avril 那行）")
let avrils = song("Avril Lavigne", "When You're Gone", dur: 240, id: "imp_avril")
let avrilHit = song("When You're Gone", "Avril Lavigne", album: "The Best Damn Thing",
                    dur: 240, id: "qq_avril", source: .tag, platform: .qq)
let out = MetadataMatcher.pick(song: avrils, candidates: [avrilHit])
check("A/B 两解命中 → auto", out.verdict == .auto, "\(out.verdict) \(out.detail)")
check("命中的是「对调后」那解", out.swapped)
check("最高分 ≥0.85", (out.best?.score ?? 0) >= 0.85, "\(out.best?.score ?? 0)")

print("— 写回：locked 字段一个都不许动")
var manual = song("到此为止", "徐佳莹", album: "", dur: 220, id: "imp_2", source: .manual,
                  locked: [.singer])
let matched = MatchedMetadata(name: "到此为止", singer: "别人", album: "理想人生",
                              picURL: "https://example.com/c.jpg", platform: .qq,
                              platformID: "qq9", score: 0.93)
let merged = MetadataMatcher.merge(into: manual, matched: matched)
check("歌手被锁 → 保持手填值", merged.singer == "徐佳莹", merged.singer)
check("专辑未锁 → 采用匹配值", merged.album == "理想人生", merged.album)
check("封面未锁 → 采用匹配值", merged.picURL == "https://example.com/c.jpg")
check("命中 id 记下来了（给取词用）", merged.meta?.matchedID == "qq9")
check("锁定非空 → 出处算 manual", merged.meta?.source == .manual)

print("— 手动编辑：只改歌手时歌名/专辑保留、封面标 stale")
let edited = MetadataMatcher.applyingManualEdit(to: perfect, name: perfect.name,
                                                singer: "徐佳莹改", album: perfect.album,
                                                cover: nil)
check("歌手改成手填值", edited.singer == "徐佳莹改")
check("歌名没动（也没被锁）", edited.name == "到此为止" && edited.meta?.locked.contains(.name) == false)
check("专辑保留", edited.album == "理想人生")
check("改了歌手 → 封面标 stale", edited.meta?.coverStale == true)
check("锁定字段 = 歌手", edited.meta?.locked == [.singer], "\(edited.meta?.locked ?? [])")
check("出处 = manual", edited.meta?.source == .manual)

print("— 换封面 → 代次 +1（三处缓存判重都靠它）")
let before = perfect.coverRevision
let after = MetadataMatcher.markingCoverChanged(perfect).coverRevision
check("coverRevision +1", after == before + 1, "\(before) → \(after)")

print("— 恢复自动：解锁 + 清命中")
let reset = MetadataMatcher.resettingToAuto(merged)
check("锁清空", reset.meta?.locked.isEmpty == true)
check("命中 id 清空", reset.meta?.matchedID == nil)
check("出处回到 unmatched", reset.meta?.source == .unmatched)

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  FAIL: \(f)") }
    exit(1)
}
exit(0)

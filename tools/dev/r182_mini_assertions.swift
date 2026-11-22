// v2.4.65（第 55 轮）迷你自测：只跑本轮新增的纯函数 + 常量口径。
// 为什么单独编：本机 WSL 的 zlib 桩会在官方 SelfTest 的"歌词解密"那节中止，后面几节跑不到。
// 用法：bash tools/dev/run_mini_assertions.sh tools/dev/r182_mini_assertions.swift
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 取词名清洗：老板库里 5 首「歌名就是文件名」")

let a = LyricSearchQuery.apply(title: "寒鸦少年-华晨宇-wy_1305366556", singer: "")
check("寒鸦少年：剥站点 ID、补歌手", a.title == "寒鸦少年" && a.artist == "华晨宇", "\(a.title) / \(a.artist)")
check("寒鸦少年：报告改过", a.changed)

let b = LyricSearchQuery.apply(title: "水星记-郭顶-wy_441491828", singer: "")
check("水星记", b.title == "水星记" && b.artist == "郭顶", "\(b.title) / \(b.artist)")

let c = LyricSearchQuery.apply(title: "我们俩-郭顶-wy_85571", singer: "")
check("我们俩", c.title == "我们俩" && c.artist == "郭顶", "\(c.title) / \(c.artist)")

let d = LyricSearchQuery.apply(title: "烟火里的尘埃-华晨宇-wy_29004400", singer: "")
check("烟火里的尘埃", d.title == "烟火里的尘埃" && d.artist == "华晨宇", "\(d.title) / \(d.artist)")

let e = LyricSearchQuery.apply(title: "溺火-特污兔-Dirtyrabbit2", singer: "特污兔")
check("溺火：歌手段 + 上传者尾巴", e.title == "溺火" && e.artist == "特污兔", "\(e.title) / \(e.artist)")

let e2 = LyricSearchQuery.apply(title: "溺火-特污兔-Dirtyrabbit2", singer: "")
check("溺火：歌手为空也能认出中段", e2.title == "溺火" && e2.artist == "特污兔", "\(e2.title) / \(e2.artist)")

let f = LyricSearchQuery.apply(title: "Converted with FlexClip 【SUNO V5】庞麦郎-我的滑板鞋-黑人福音R&B",
                               singer: "SUNO V5")
check("剪辑前缀不带进搜索", !f.title.contains("Converted with FlexClip"), f.title)

print("— 不许误伤正常歌名")
for (t, s) in [("晴天", "周杰伦"),
               ("Sukidayo -Hyakkai No Koukai- (English Version)", "Che'Nelle"),
               ("Mood (Remix|Explicit)", "24kGoldn/Justin Bieber"),
               ("ピースサイン (V字手势)", "米津玄師"),
               ("海屿你-remix", "大头针"),
               ("aLIEz", "澤野弘之")] {
    let r = LyricSearchQuery.apply(title: t, singer: s)
    check("不改：\(t)", r.title == t && r.artist == s, "\(r.title) / \(r.artist)")
}

print("— 补全重试口径")
check("最多 12 次", CompanionRetryRules.maxAttempts == 12, "\(CompanionRetryRules.maxAttempts)")
check("退避覆盖到 1 小时", CompanionRetryRules.backoff.count >= 7)
check("退避单调不减",
      zip(CompanionRetryRules.backoff, CompanionRetryRules.backoff.dropFirst())
          .allSatisfy { $0 <= $1 })
check("第 3 次之后还有额度", CompanionRetryRules.shouldRetry(attempt: 3))
check("第 12 次后收手", !CompanionRetryRules.shouldRetry(attempt: 12))
check("放弃后有 1 小时冷却", CompanionRetryRules.cooldownAfterGivingUp == 3600,
      "\(CompanionRetryRules.cooldownAfterGivingUp)")

print("— 词头自证（第 57 轮）")
check("海屿你 278/288 → 收", LddcMatch.headerDurationOK(targetSec: 278, declaredSec: 288))
check("溺火 166/195 → 不收", !LddcMatch.headerDurationOK(targetSec: 166, declaredSec: 195))
check("8% 边界算过", LddcMatch.headerDurationOK(targetSec: 100, declaredSec: 108))
check("超 8% 不收", !LddcMatch.headerDurationOK(targetSec: 100, declaredSec: 109))
check("没 total 不算证据", !LddcMatch.headerDurationOK(targetSec: 278, declaredSec: 0))
let near = LddcMatch.nearMissPool(
    queryTitle: "海屿你", targetSec: 278,
    candidates: [(title: "海屿你", durationSec: 288),
                 (title: "海屿你", durationSec: 190),
                 (title: "海屿你 (Live)", durationSec: 280),
                 (title: "另一首", durationSec: 279)])
check("第二池只放同名同版本、差 ≤25% 的", near == [0], "\(near)")
let near2 = LddcMatch.nearMissPool(
    queryTitle: "우주를 줄게", targetSec: 213,
    candidates: [(title: "우주를 줄게", durationSec: 213),
                 (title: "우주를 줄게 (Radio Edit)", durationSec: 202)])
check("时长一致但歌手字段对不上的也进第二池", near2 == [0], "\(near2)")

print("— 纯音乐识别（第 57 轮）")
let instCands = [(title: "溺火 (Vocal Version)", durationSec: 195),
                 (title: "溺火 (氛围纯音乐)", durationSec: 161)]
check("溺火 166s 最接近纯音乐版 → 判纯音乐",
      LddcMatch.closestIsInstrumental(queryTitle: "溺火", targetSec: 166, candidates: instCands))
check("只有人声版 → 不判纯音乐",
      !LddcMatch.closestIsInstrumental(queryTitle: "溺火", targetSec: 166,
                                       candidates: [(title: "溺火 (Vocal Version)", durationSec: 195)]))

print("\nRESULT: \(pass) passed, \(fail.count) failed")
if !fail.isEmpty { exit(1) }

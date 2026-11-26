// 探针（2026-11-27）：为什么《蓄势 ~GEAR UP~》跨平台搜到了却 still 无源
// 事实：网易源 id=4920985「蓄势 ~GEAR UP~ / 采风乐坊 / 142.8s」；
//      QQ mid=002OlB7d1uMgtF「蓄勢 ～ GEAR UP ～ / 采风乐坊 / 142s」；
//      酷狗 hash=a3b29a67…「蓄勢 ～ GEAR UP ～ / 采风乐坊 / 142s」。
// 只要身份闸拒了这两条，播放器就会"跳过"这首歌。
import Foundation

func s(_ name: String, _ singer: String, _ dur: Double, _ plat: MusicPlatform, _ id: String) -> Song {
    Song.make(platform: plat, platformID: id, name: name, singer: singer,
              album: "太鼓の達人 オリジナルサウンドトラック「ドンダフル!」",
              duration: dur, picURL: nil)
}

let src = s("蓄势 ~GEAR UP~", "采风乐坊", 142.813, .netease, "4920985")
let qq = s("蓄勢 ～ GEAR UP ～", "采风乐坊", 142, .qq, "002OlB7d1uMgtF")
let kg = s("蓄勢 ～ GEAR UP ～", "采风乐坊", 142, .kugou, "a3b29a67badbaf0a30ad7915ac8cdf46")

print("源  :", src.name, "| norm =", NameMatch.normTitle(src.name), "| key =", FavoriteRules.titleKey(src.name))
print("QQ  :", qq.name, "| norm =", NameMatch.normTitle(qq.name), "| key =", FavoriteRules.titleKey(qq.name))
print("酷狗:", kg.name, "| norm =", NameMatch.normTitle(kg.name), "| key =", FavoriteRules.titleKey(kg.name))
print("")
print("normTitle 相等？         ", NameMatch.normTitle(src.name) == NameMatch.normTitle(qq.name))
print("titleKey 相等？          ", FavoriteRules.titleKey(src.name) == FavoriteRules.titleKey(qq.name))
print("titleSimilarity(原始串)  ", FavoriteRules.titleSimilarity(src.name, qq.name))
print("titleSimilarity(键)      ", FavoriteRules.titleSimilarity(FavoriteRules.titleKey(src.name),
                                                             FavoriteRules.titleKey(qq.name)))
print("titleEvidence(src,qq)    ", String(describing: NameMatch.titleEvidence(src.name, qq.name)))
print("titleEvidence(src,kg)    ", String(describing: NameMatch.titleEvidence(src.name, kg.name)))
print("sameRecording(src, qq)   ", NameMatch.sameRecording(src: src, cand: qq))
print("sameRecording(src, kg)   ", NameMatch.sameRecording(src: src, cand: kg))
print("identityRank(src, qq)    ", NameMatch.identityRank(src: src, cand: qq))
print("")
print("— 回归对照（这些必须仍旧判成'不是同一首'）—")
let zhong = s("众", "黄霄雲", 215.5, .netease, "A")
let celian = s("侧脸", "黄霄雲", 217.8, .kuwo, "B")
print("众 vs 侧脸 sameRecording:", NameMatch.sameRecording(src: zhong, cand: celian))
let qingtian = s("晴天", "周杰伦", 269, .kuwo, "C")
let qingtianLive = s("晴天 (Live)", "周杰伦", 269, .netease, "D")
print("晴天 vs 晴天(Live)      :", NameMatch.sameRecording(src: qingtian, cand: qingtianLive))
let yue = s("发如雪", "周杰伦", 299, .kuwo, "E")
let yueLang = s("发如雪 (粤语版)", "常颖杰", 299, .netease, "F")
print("发如雪 vs 粤语版        :", NameMatch.sameRecording(src: yue, cand: yueLang))
let rain = s("雨过天晴", "周杰伦", 269, .netease, "G")
print("晴天 vs 雨过天晴        :", NameMatch.sameRecording(src: qingtian, cand: rain))

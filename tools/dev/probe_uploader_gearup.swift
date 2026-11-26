// 探针 2（2026-11-27）：复现"跨平台候选被全部丢光"的那条链
//
// 事实（2026-11-27 实测搜索接口，关键词「蓄势 ~GEAR UP~ 采风乐坊」）：
//   QQ   : 蓄勢 ～ GEAR UP ～ / 采风乐坊 / 142s ; 蛻変~transformation~ ; 綻放~blooming ; 春遊 ～happy excursion～
//   酷狗 : 蓄勢 ～ GEAR UP ～ / 采风乐坊 / 142s ; 蛻変~transformation~ ; 绽放 ~Blooming~
// 池子里同一歌手挂着 ≥3 首互不相同的歌，而源歌名「蓄势 ~GEAR UP~」与「蓄勢 ～ GEAR UP ～」在
// normTitle 下**不相等**（繁简/全角）→ looksLikeUploader 会误判成"频道号/上传者" →
// sameSong(uploaderLike:true) 要求歌名严格归一化相等 → 唯一能播的那两条被丢掉 → 播放器"跳过"。
import Foundation

func s(_ name: String, _ singer: String, _ dur: Double, _ plat: MusicPlatform, _ id: String) -> Song {
    Song.make(platform: plat, platformID: id, name: name, singer: singer,
              album: dur > 0 ? "太鼓の達人 オリジナルサウンドトラック「ドンダフル!」" : "",
              duration: dur, picURL: nil)
}

let src = s("蓄势 ~GEAR UP~", "采风乐坊", 142.813, .netease, "4920985")
let pool: [Song] = [
    s("蓄勢 ～ GEAR UP ～", "采风乐坊", 142, .qq, "002OlB7d1uMgtF"),
    s("蓄勢 ～ GEAR UP ～", "采风乐坊", 142, .kugou, "A3B29A67BADBAF0A30AD7915AC8CDF46"),
    s("蛻変~transformation~", "采风乐坊", 132, .qq, "002yBNLw29TKuQ"),
    s("綻放~blooming", "采风乐坊", 133, .qq, "003TQwt21AkRzc"),
    s("春遊 ～happy excursion～", "采风乐坊", 132, .qq, "001nERsQ0mqHO1"),
    s("季曲 ~Seasons of Asia~", "采风乐坊", 153, .qq, "003xxxx"),
]

let uploaderLike = NameMatch.looksLikeUploader(src, among: pool)
print("池子大小:", pool.count)
print("looksLikeUploader →", uploaderLike, "（true = 被误判成频道号/上传者）")
print("")
print("逐条：titleMatches / sameRecording / sameSong(uploaderLike)")
for c in pool {
    let tm = NameMatch.titleMatches(src.name, c.name)
    let sr = NameMatch.sameRecording(src: src, cand: c)
    let ss = SameSongCrossResolver.sameSong(src: src, cand: c, uploaderLike: uploaderLike)
    print(String(format: "  %-24@ %@ | titleMatches=%@ sameRecording=%@ sameSong=%@",
                 c.name as NSString, c.platform.rawValue as NSString,
                 (tm ? "T" : "F") as NSString, (sr ? "T" : "F") as NSString, (ss ? "T" : "F") as NSString))
}
print("")
print("— 归一化键对照 —")
print("  normTitle(src) =", NameMatch.normTitle(src.name), "| key =", FavoriteRules.titleKey(src.name))
print("  normTitle(qq)  =", NameMatch.normTitle(pool[0].name), "| key =", FavoriteRules.titleKey(pool[0].name))
print("  titleKey 相等  =", FavoriteRules.titleKey(src.name) == FavoriteRules.titleKey(pool[0].name))

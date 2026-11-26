// r287 迷你自测（2026-11-27）：繁简/全角歌名被跨平台闸误杀（真机《蓄势 ~GEAR UP~》被跳过）
//
// 真机事实：网易对 4920985 回 code=404/url=null（版权不可播），本平台 5 条腿全灭；
// QQ mid=002OlB7d1uMgtF 与酷狗 hash=A3B29A67… 都是「蓄勢 ～ GEAR UP ～ / 采风乐坊 / 142s」。
// 身份层用 normTitle 比歌名，不认繁简与全角 ～ → 两条候选被"上传者收紧"丢掉 → 整首无源 → 播放器跳过。
import Foundation

var pass = 0
var fail: [String] = []
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}
func s(_ name: String, _ singer: String, _ dur: Double, _ plat: MusicPlatform, _ id: String,
       album: String = "太鼓の達人 オリジナルサウンドトラック「ドンダフル!」") -> Song {
    Song.make(platform: plat, platformID: id, name: name, singer: singer,
              album: album, duration: dur, picURL: nil)
}

let src = s("蓄势 ~GEAR UP~", "采风乐坊", 142.813, .netease, "4920985")
let qq = s("蓄勢 ～ GEAR UP ～", "采风乐坊", 142, .qq, "002OlB7d1uMgtF")
let kg = s("蓄勢 ～ GEAR UP ～", "采风乐坊", 142, .kugou, "A3B29A67BADBAF0A30AD7915AC8CDF46")

print("— 归一化")
check("全角 ～ 与半角 ~ 折平（NFKC）",
      NameMatch.normTitle("A ～B～") == NameMatch.normTitle("A ~B~"), NameMatch.normTitle("A ～B～"))
check("身份键把繁体折成简体", NameMatch.identityKey("蓄勢") == NameMatch.identityKey("蓄势"))
check("繁简不同的同一首：titleMatches 认得出", NameMatch.titleMatches(src.name, qq.name))

print("— 这个 bug 的直接断言")
check("歌名证据 = exact", NameMatch.titleEvidence(src.name, qq.name) == .exact,
      String(describing: NameMatch.titleEvidence(src.name, qq.name)))
check("同曲闸放行 QQ 候选", NameMatch.sameRecording(src: src, cand: qq))
check("同曲闸放行酷狗候选", NameMatch.sameRecording(src: src, cand: kg))
check("身份等级回到 1", NameMatch.identityRank(src: src, cand: qq) == 1)

let pool: [Song] = [qq, kg,
                    s("蛻変~transformation~", "采风乐坊", 132, .qq, "m1"),
                    s("綻放~blooming", "采风乐坊", 133, .qq, "m2"),
                    s("春遊 ～happy excursion～", "采风乐坊", 132, .qq, "m3")]
check("池子里有这首 → 不能判成频道号", !NameMatch.looksLikeUploader(src, among: pool))
check("上传者收紧下：同一首仍放行",
      SameSongCrossResolver.sameSong(src: src, cand: qq, uploaderLike: true))
check("上传者收紧下：别的歌仍被拒",
      !SameSongCrossResolver.sameSong(src: src,
                                      cand: s("蛻変~transformation~", "采风乐坊", 132, .qq, "m1"),
                                      uploaderLike: true))

print("— 防回归（历史事故的四条硬口径）")
let zhong = s("众", "黄霄雲", 215.5, .netease, "z1", album: "")
let celian = s("侧脸", "黄霄雲", 217.8, .kuwo, "z2", album: "")
check("众 ≠ 侧脸", !NameMatch.sameRecording(src: zhong, cand: celian))
let qing = s("晴天", "周杰伦", 269, .kuwo, "q1", album: "叶惠美")
let qingLive = s("晴天 (Live)", "周杰伦", 269, .netease, "q2", album: "叶惠美")
check("晴天 ≠ 晴天(Live)", !NameMatch.sameRecording(src: qing, cand: qingLive))
let yue = s("发如雪", "周杰伦", 299, .kuwo, "y1", album: "十一月的萧邦")
let yueCanto = s("发如雪 (粤语版)", "常颖杰", 299, .netease, "y2", album: "十一月的萧邦")
check("发如雪 ≠ 粤语版", !NameMatch.sameRecording(src: yue, cand: yueCanto))
let zhuanji = s("众", "黄霄雲", 215.5, .netease, "z3", album: "众")
let yiMing = s("Side Face", "黄霄雲", 216.0, .kuwo, "z4", album: "众")
check("译名仍走专辑+≤1s 通道", NameMatch.sameRecording(src: zhuanji, cand: yiMing))

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  失败：\(f)") }
    exit(1)
}

// r149 迷你自测（2026-11-21）：收藏去重口径
//
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止，
// 后面几节根本跑不到。这里用同一批 selftest-flat 源文件、只替换 main。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func song(_ p: MusicPlatform, _ name: String, _ singer: String, dur: TimeInterval,
          id: String, pic: String? = nil) -> Song {
    Song.make(platform: p, platformID: id, name: name, singer: singer,
              album: "叶惠美", duration: dur, picURL: pic)
}

print("— 同一条录音：跨平台同曲要合并")
let kuwo = song(.kuwo, "晴天", "周杰伦", dur: 269, id: "228908", pic: "https://img/kuwo.jpg")
let kugou = song(.kugou, "晴天", "周杰伦", dur: 269, id: "B3A52A7A958BF0AED0EBFBA2E9A818B7")
let qq = song(.qq, "晴天", "周杰伦", dur: 269, id: "0039MnYb0qxYhV")
check("酷我 vs 酷狗 → 同一条", FavoriteRules.isSameRecording(kuwo, kugou))
check("酷我 vs QQ → 同一条", FavoriteRules.isSameRecording(kuwo, qq))
check("同 id → 同一条", FavoriteRules.isSameRecording(kuwo, kuwo))
check("对称", FavoriteRules.isSameRecording(kugou, kuwo))

print("— 不能合并的（准确性优先）")
check("翻唱（同名不同歌手）不合并",
      !FavoriteRules.isSameRecording(kuwo, song(.kugou, "晴天", "某翻唱歌手", dur: 269, id: "c1")))
check("Live 版不并进录音室",
      !FavoriteRules.isSameRecording(kuwo, song(.kugou, "晴天 (Live)", "周杰伦", dur: 279, id: "l1")))
check("Live 时长相同也不合并（版本类不同）",
      !FavoriteRules.isSameRecording(kuwo, song(.kugou, "晴天 (Live)", "周杰伦", dur: 269, id: "l2")))
check("时长差 30s 不合并",
      !FavoriteRules.isSameRecording(kuwo, song(.kugou, "晴天", "周杰伦", dur: 299, id: "g1")))
check("同歌手不同歌不合并",
      !FavoriteRules.isSameRecording(kuwo, song(.kugou, "夜曲", "周杰伦", dur: 226, id: "n1")))
check("钢琴版不合并",
      !FavoriteRules.isSameRecording(kuwo, song(.kugou, "晴天 (钢琴版)", "周杰伦", dur: 269, id: "p1")))

print("— 时长未知时退回歌名口径")
check("时长 0 + 歌名歌手一致 → 合并",
      FavoriteRules.isSameRecording(kuwo, song(.netease, "晴天", "周杰伦", dur: 0, id: "nd1")))
check("时长 0 + 译名不同 → 不合并",
      !FavoriteRules.isSameRecording(song(.qq, "연애의 조건", "BESTie", dur: 0, id: "k1"),
                                     song(.netease, "恋爱的条件", "BESTie", dur: 0, id: "k2")))

print("— duplicateIndex / merge")
let list = [kuwo, song(.kugou, "夜曲", "周杰伦", dur: 226, id: "n2")]
check("找到同曲那一行", FavoriteRules.duplicateIndex(of: kugou, in: list) == 0)
check("不同歌返回 nil",
      FavoriteRules.duplicateIndex(of: song(.qq, "稻香", "周杰伦", dur: 223, id: "d1"), in: list) == nil)
let merged = FavoriteRules.merge(existing: kuwo, incoming: kugou)
check("合并后 id 不变（不偷换音源）", merged.id == kuwo.id, merged.id)
check("已有封面不被覆盖", merged.picURL == kuwo.picURL, merged.picURL ?? "nil")
let noPic = song(.kuwo, "夜曲", "周杰伦", dur: 226, id: "np")
let withPic = song(.kugou, "夜曲", "周杰伦", dur: 226, id: "wp", pic: "https://img/kg.jpg")
check("没封面时用新来的补", FavoriteRules.merge(existing: noPic, incoming: withPic).picURL == "https://img/kg.jpg")
check("时长为 0 时用新来的补",
      FavoriteRules.merge(existing: song(.qq, "稻香", "周杰伦", dur: 0, id: "z1"),
                          incoming: song(.kugou, "稻香", "周杰伦", dur: 223, id: "z2")).duration > 0)

print("— 历史清理")
let live = song(.kugou, "晴天 (Live)", "周杰伦", dur: 279, id: "live1")
let res = FavoriteRules.dedupe([kuwo, kugou, qq, song(.kugou, "夜曲", "周杰伦", dur: 226, id: "n3"), live])
check("三条同曲合成一条（共 3 行）", res.songs.count == 3, "\(res.songs.count)")
check("合并计数 2", res.merged == 2, "\(res.merged)")
check("保留最先出现的那条", res.songs.first?.id == kuwo.id)
check("Live 仍单独保留", res.songs.contains { $0.id == live.id })

print("— 标题带括号 / 差几个字 / 繁简（不同平台的同一首，要合并）")
check("繁简：後來 vs 后来 → 合并",
      FavoriteRules.isSameRecording(song(.kuwo, "後來", "刘若英", dur: 314, id: "t1"),
                                     song(.qq, "后来", "刘若英", dur: 314, id: "t2")))
check("括号说明：晴天 vs 晴天 (原唱 周杰伦) → 合并",
      FavoriteRules.isSameRecording(song(.kuwo, "晴天", "周杰伦", dur: 269, id: "b1"),
                                     song(.netease, "晴天 (原唱 周杰伦)", "周杰伦", dur: 269, id: "b2")))
check("差一个字：这世界那么多人 vs 这世界这么多人 → 合并",
      FavoriteRules.isSameRecording(song(.kuwo, "这世界那么多人", "莫文蔚", dur: 265, id: "c1"),
                                     song(.qq, "这世界这么多人", "莫文蔚", dur: 265, id: "c2")))
check("空格/全角括号也归一到同一个键",
      FavoriteRules.titleKey("晴天（原唱 周杰伦）") == FavoriteRules.titleKey("晴天"))

print("— 放行有底线：像但不是同一首，不能并")
check("爱情 vs 爱情转移（短名不做模糊）→ 不合并",
      !FavoriteRules.isSameRecording(song(.qq, "爱情", "陈奕迅", dur: 240, id: "d1"),
                                     song(.qq, "爱情转移", "陈奕迅", dur: 240, id: "d2")))
check("晴天 vs 情天（两字名差一字）→ 不合并",
      !FavoriteRules.isSameRecording(song(.kuwo, "晴天", "周杰伦", dur: 269, id: "e1"),
                                     song(.qq, "情天", "周杰伦", dur: 269, id: "e2")))
check("相似标题但时长差 5s（模糊口径 ±2s）→ 不合并",
      !FavoriteRules.isSameRecording(song(.kuwo, "这世界那么多人", "莫文蔚", dur: 265, id: "f1"),
                                     song(.qq, "这世界这么多人", "莫文蔚", dur: 270, id: "f2")))
check("相似标题 + 一边时长未知（要求 ≥0.9）→ 不合并",
      !FavoriteRules.isSameRecording(song(.kuwo, "这世界那么多人", "莫文蔚", dur: 265, id: "g1"),
                                     song(.netease, "这世界这么多人", "莫文蔚", dur: 0, id: "g2")))
check("标题完全相同 + 一边时长未知 → 合并",
      FavoriteRules.isSameRecording(song(.kuwo, "晴天", "周杰伦", dur: 269, id: "h1"),
                                     song(.netease, "晴天", "周杰伦", dur: 0, id: "h2")))

check("历史里繁简两条也被清掉",
      FavoriteRules.dedupe([song(.kuwo, "後來", "刘若英", dur: 314, id: "h1"),
                            song(.qq, "后来", "刘若英", dur: 314, id: "h2")]).merged == 1)
check("历史里差一个字的两条也被清掉",
      FavoriteRules.dedupe([song(.kuwo, "这世界那么多人", "莫文蔚", dur: 265, id: "h3"),
                            song(.qq, "这世界这么多人", "莫文蔚", dur: 265, id: "h4")]).merged == 1)

print("— 文件级指纹：字节相等才算同一个文件")
func fp(_ bytes: Int64, _ dur: Int, _ kbps: Int64 = 320) -> FavoriteFingerprint {
    FavoriteFingerprint(bytes: bytes, durationSec: dur, kbps: kbps,
                        capturedAt: Date(timeIntervalSince1970: 0))
}
check("同字节 → 同文件", FavoriteIdentity.isSameFile(fp(10_792_943, 269), fp(10_792_943, 269)))
check("字节差 1 → 不合", !FavoriteIdentity.isSameFile(fp(10_792_943, 269), fp(10_792_944, 269)))
check("时长差 1s 仍算", FavoriteIdentity.isSameFile(fp(10_792_943, 269), fp(10_792_943, 270)))
check("时长差 5s 不算", !FavoriteIdentity.isSameFile(fp(10_792_943, 269), fp(10_792_943, 274)))
check("占位提示音不可用", !FavoriteIdentity.isUsable(bytes: 181_521, durationSec: 269))
check("两个占位不会互判", !FavoriteIdentity.isSameFile(fp(181_521, 269), fp(181_521, 269)))
check("171KB 残片不可用", !FavoriteIdentity.isUsable(bytes: 171_072, durationSec: 11))
check("真 320k 可用", FavoriteIdentity.isUsable(bytes: 10_792_943, durationSec: 269))
check("时长 0 不可用", !FavoriteIdentity.isUsable(bytes: 10_792_943, durationSec: 0))

print("— 灰区复核：什么才值得让用户看一眼")
func gs(_ p: MusicPlatform, _ name: String, _ singer: String, dur: TimeInterval, id: String) -> Song {
    Song.make(platform: p, platformID: id, name: name, singer: singer, album: "",
              duration: dur, picURL: nil)
}
func gfp(_ bytes: Int64, _ kbps: Int64) -> FavoriteFingerprint {
    FavoriteFingerprint(bytes: bytes, durationSec: 269, kbps: kbps,
                        capturedAt: Date(timeIntervalSince1970: 0))
}
let gbase = gs(.kuwo, "晴天", "周杰伦", dur: 269, id: "g1")
check("同名同歌手时长差 11s → 灰区",
      FavoriteReview.isGreyPair(gbase, gs(.qq, "晴天", "周杰伦", dur: 258, id: "g2")))
check("一级不合并它", !FavoriteRules.isSameRecording(gbase, gs(.qq, "晴天", "周杰伦", dur: 258, id: "g2")))
check("时长差 40s → 不是灰区", !FavoriteReview.isGreyPair(gbase, gs(.qq, "晴天", "周杰伦", dur: 309, id: "g3")))
check("不同歌手 → 不是灰区", !FavoriteReview.isGreyPair(gbase, gs(.qq, "晴天", "某翻唱", dur: 269, id: "g4")))
check("Live → 不是灰区", !FavoriteReview.isGreyPair(gbase, gs(.qq, "晴天 (Live)", "周杰伦", dur: 269, id: "g5")))
check("相似度 0.67 → 灰区",
      FavoriteReview.isGreyPair(gs(.kuwo, "我的天空", "南征北战", dur: 200, id: "g7"),
                                gs(.qq, "我的天空啊呀", "南征北战", dur: 200, id: "g8")))
let ga = gs(.kuwo, "晴天", "周杰伦", dur: 269, id: "qa")
let gb = gs(.kugou, "晴天", "周杰伦", dur: 269, id: "qb")
check("合并留 320k", FavoriteReview.preferred(ga, gb,
      fingerprints: [ga.id: gfp(3_000_000, 128), gb.id: gfp(10_000_000, 320)]).id == gb.id)
check("同码率比体积", FavoriteReview.preferred(ga, gb,
      fingerprints: [ga.id: gfp(9_000_000, 320), gb.id: gfp(10_000_000, 320)]).id == gb.id)
check("都没指纹留先出现的", FavoriteReview.preferred(ga, gb, fingerprints: [:]).id == ga.id)
check("pairKey 顺序无关", FavoriteReview.pairKey(ga, gb) == FavoriteReview.pairKey(gb, ga))

print("— 本地导入：文件名 / 基名 / 搜索")
let pa = ImportRules.parseFileName("01 - 周杰伦 - 晴天.mp3")
check("音轨号 + 歌手 - 歌名", pa.title == "晴天" && pa.artist == "周杰伦")
let pb = ImportRules.parseFileName("晴天.mp3")
check("只有歌名 → 歌手留空", pb.title == "晴天" && pb.artist.isEmpty && !pb.confident)
check("数字开头不是音轨号", ImportRules.parseFileName("2002年的第一场雪.mp3").title.hasPrefix("2002年"))
check("ape 不导入", !ImportRules.isPlayable(extension: "ape"))
check("撞基名加 (2)", ImportRules.uniqueBaseName("周杰伦 - 晴天", taken: ["周杰伦 - 晴天"]) == "周杰伦 - 晴天 (2)")
let qs = Song.make(platform: .local, platformID: "imp_1", name: "晴天", singer: "周杰伦",
                   album: "叶惠美", duration: 269, picURL: nil)
check("按歌名搜到", LibrarySearch.rank(song: qs, fileName: "周杰伦 - 晴天.mp3", query: "晴天") >= 2)
check("按歌手搜到", LibrarySearch.rank(song: qs, fileName: nil, query: "周杰伦") >= 1)
check("搜不到 = 0", LibrarySearch.rank(song: qs, fileName: nil, query: "夜曲") == 0)
check("繁简可搜", LibrarySearch.rank(
      song: Song.make(platform: .local, platformID: "imp_2", name: "后来", singer: "刘若英",
                      album: "", duration: 314, picURL: nil),
      fileName: nil, query: "後來") >= 2)

print("— 收藏去重：长副标题（包含关系）")
func hs(_ p: MusicPlatform, _ name: String, _ singer: String, dur: TimeInterval, id: String,
        album: String = "哎呦，不错哦") -> Song {
    Song.make(platform: p, platformID: id, name: name, singer: singer, album: album,
              duration: dur, picURL: nil)
}
let hq = hs(.qq, "手写的从前", "周杰伦", dur: 297, id: "h1")
let hk = hs(.kuwo, "手写的从前-优酸乳为爱告白广告曲", "周杰伦", dur: 297, id: "h2")
check("短标题被包含 → 合并", FavoriteRules.isSameRecording(hq, hk))
check("专辑不同 → 不合并", !FavoriteRules.isSameRecording(
      hq, hs(.kuwo, "手写的从前-优酸乳为爱告白广告曲", "周杰伦", dur: 297, id: "h3", album: "别的")))
check("时长差 30s → 不合并", !FavoriteRules.isSameRecording(
      hq, hs(.kuwo, "手写的从前-优酸乳为爱告白广告曲", "周杰伦", dur: 327, id: "h4")))
check("三字名不做包含", !FavoriteRules.isSameRecording(
      hs(.qq, "七里香", "周杰伦", dur: 299, id: "p1"),
      hs(.kuwo, "七里香花开", "周杰伦", dur: 299, id: "p2")))
check("两字名不做包含", !FavoriteRules.isSameRecording(
      hs(.qq, "爱情", "陈奕迅", dur: 240, id: "l1"),
      hs(.kuwo, "爱情转移", "陈奕迅", dur: 240, id: "l2")))

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  FAIL: \(f)") }
    exit(1)
}
exit(0)

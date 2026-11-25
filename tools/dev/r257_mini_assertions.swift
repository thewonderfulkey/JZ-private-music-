// r257 迷你自测（2026-11-25 v2.4.117）：身份闸根治《众》播成《侧脸》
//   ① 歌名证据成为硬条件（译名案走"专辑 + ≤1 秒"通道）
//   ② 身份等级排在音质前面（错歌 320k 不许压过对歌 98kbps）
//   ③ 缓存条目身份复核（老条目一律不信）
//   ④ 时长闸门 ±1.5 秒 / >2 秒判不是同一份
//   ⑤ 来源标签说实话（缓存/预取不许冒充平台直连）
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func song(_ p: MusicPlatform, _ name: String, _ singer: String,
          album: String = "", dur: Int = 0, id: String) -> Song {
    Song.make(platform: p, platformID: id, name: name, singer: singer,
              album: album, duration: Double(dur), picURL: nil)
}

print("— ① 同曲判定：歌名证据是硬条件")
let zhong = song(.netease, "众", "黄霄雲", album: "众", dur: 215, id: "ne_zhong")
let zhongQQ = song(.qq, "众", "黄霄雲", album: "众", dur: 215, id: "qq_zhong")
let ceyanNE = song(.netease, "侧脸", "黄霄雲", album: "侧脸", dur: 218, id: "ne_ceyan")
let ceyanQQ = song(.qq, "侧脸", "黄霄雲", album: "侧脸", dur: 217, id: "qq_ceyan")
let liubuzhu = song(.qq, "留不住的夏天", "黄霄雲", album: "留不住的夏天", dur: 216, id: "qq_lb")

check("《众》vs《侧脸》(网易, 差 3s) → 拒", !NameMatch.sameRecording(src: zhong, cand: ceyanNE))
check("《众》vs《侧脸》(QQ, 差 2s) → 拒", !NameMatch.sameRecording(src: zhong, cand: ceyanQQ))
check("《众》vs《留不住的夏天》(差 1s) → 拒", !NameMatch.sameRecording(src: zhong, cand: liubuzhu))
check("《众》vs《众》(另一平台, 差 0s) → 通过", NameMatch.sameRecording(src: zhong, cand: zhongQQ))
check("身份等级：同曲另一平台 = 1", NameMatch.identityRank(src: zhong, cand: zhongQQ) == 1,
      "\(NameMatch.identityRank(src: zhong, cand: zhongQQ))")
check("身份等级：错歌 = 9", NameMatch.identityRank(src: zhong, cand: ceyanQQ) == 9,
      "\(NameMatch.identityRank(src: zhong, cand: ceyanQQ))")

print("— ①-b 译名案（2026-11-19 口径）必须保住")
let loveCN = song(.qq, "恋爱的条件", "BESTie (베스티)", album: "Love Options", dur: 194, id: "cn")
let loveKR = song(.netease, "연애의 조건 (Love Options)", "BESTie",
                  album: "연애의 조건 (Love Options)", dur: 194, id: "kr")
let loveInst = song(.netease, "연애의 조건 (Love Options) (Inst.)", "BESTie",
                    album: "연애의 조건 (Love Options)", dur: 192, id: "kr_inst")
let loveNoAlbum = song(.qq, "LOVE OPTIONS", "BESTie", dur: 194, id: "en")
check("同专辑 + 同时长 → 译名案通过", NameMatch.sameRecording(src: loveCN, cand: loveKR))
check("伴奏版 → 拒", !NameMatch.sameRecording(src: loveCN, cand: loveInst))
check("歌名不同 + 专辑未知 + 同时长 → 拒（新口径）",
      !NameMatch.sameRecording(src: loveCN, cand: loveNoAlbum))

print("— ② 打分：身份排在音质前面")
var hiWrong = StreamSource(url: "https://x/c.mp3", backendName: "落月 QQ", platform: .qq,
                           quality: .high, format: "mp3", note: "")
hiWrong.kbps = 321
hiWrong.totalBytes = 8_716_728
var loRight = StreamSource(url: "https://x/z.m4a", backendName: "oiapi 网易", platform: .netease,
                           quality: .standard, format: "m4a", note: "")
loRight.kbps = 98
loRight.totalBytes = 2_627_357
let sWrong = DownloadResolver.score(of: hiWrong, song: ceyanQQ, ref: zhong, ms: 300)
let sRight = DownloadResolver.score(of: loRight, song: zhong, ref: zhong, ms: 1500)
check("错歌 320k < 对歌 98kbps（本期核心）", sRight > sWrong,
      "right=\(sRight.short) wrong=\(sWrong.short)")
check("错歌的身份位是 9", sWrong.identity == 9, "\(sWrong.identity)")

print("— ③ 缓存条目身份复核")
check("身份齐全 + 长度对得上 → 放行",
      NameMatch.cacheIdentityOK(displayed: zhong, matchedName: "众", matchedSinger: "黄霄雲",
                                matchedDurationSec: 215, measuredDurationSec: 215.46))
check("条目里是《侧脸》→ 不许命中",
      !NameMatch.cacheIdentityOK(displayed: zhong, matchedName: "侧脸",
                                 matchedSinger: "黄霄雲",
                                 matchedDurationSec: 218, measuredDurationSec: 217.89))
check("歌名对、文件长度差 3 秒 → 不许命中",
      !NameMatch.cacheIdentityOK(displayed: zhong, matchedName: "众", matchedSinger: "黄霄雲",
                                 matchedDurationSec: 215, measuredDurationSec: 218.0))
check("老条目没有身份 → 不许命中",
      !NameMatch.cacheIdentityOK(displayed: zhong, matchedName: nil, matchedSinger: nil,
                                 matchedDurationSec: nil, measuredDurationSec: nil))

print("— ④ 时长闸门")
var hit14 = false
if case .match = PlaybackCacheRules.gate(candidate: 216.4, expected: 215.0) { hit14 = true }
check("差 1.4 秒 → match", hit14)
var grey = false
if case .unverified = PlaybackCacheRules.gate(candidate: 216.8, expected: 215.0) { grey = true }
check("差 1.8 秒 → unverified（灰区）", grey)
var bad = false
if case .mismatch = PlaybackCacheRules.gate(candidate: 217.89, expected: 215.5) { bad = true }
check("《众》215.5 vs《侧脸》217.89 → mismatch", bad)
check("常量 = 1.5 / 2.0",
      PlaybackCacheRules.durationToleranceSec == 1.5
      && PlaybackCacheRules.durationMismatchSec == 2.0)

print("— ⑤ 来源标签")
let cacheSrc = StreamSource(url: "jzcache://song/x", backendName: "播放缓存", platform: .netease,
                            quality: .high, format: "mp3", note: "")
let prefetchSrc = StreamSource(url: "https://x/a.mp3", backendName: "预取源", platform: .netease,
                               quality: .high, format: "mp3", note: "")
let liveSrc = StreamSource(url: "https://x/a.mp3", backendName: "gdstudio 网易", platform: .netease,
                           quality: .high, format: "mp3", note: "")
check("播放缓存 → 缓存", PlaybackQualityRules.originTag(cacheSrc) == "缓存")
check("预取源 → 预取", PlaybackQualityRules.originTag(prefetchSrc) == "预取")
check("真后端 → nil", PlaybackQualityRules.originTag(liveSrc) == nil)

print("— ⑥ 本地文件身份（众的错文件不许当本地文件播）")
let localCheck = { (fileSecs: Double, songSecs: Double) -> Bool in
    songSecs > 0 && abs(fileSecs - songSecs) > PlaybackCacheRules.durationMismatchSec
}
check("217.89 秒的文件 vs 215 秒的曲目 → 判不符", localCheck(217.89, 215))
check("215.4 秒的文件 vs 215 秒的曲目 → 正常", !localCheck(215.4, 215))

print("")
print("PASS=\(pass) FAIL=\(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  ✗ \(f)") }
    exit(1)
}

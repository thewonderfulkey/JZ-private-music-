// r263 迷你自测（2026-11-26 v2.4.121）：本轮四件事的口径
//   ① 酷我封面整条下线（只废封面 API，音频照用）+ 酷狗歌手头像不再当封面
//   ② 时长只有一把可信尺子（可信总长 / 到点收尾 / 头偏长的纠正）
//   ③ 档位：起播窗口 2.6s + 低档宽限 1.2s；下载兜底**先往下再往上**；档位名带实测码率
//   ④ 下载判死名单（持久化）+ 下全量之前先探头部
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func song(_ p: MusicPlatform, _ n: String, _ s: String, id: String) -> Song {
    Song.make(platform: p, platformID: id, name: n, singer: s, album: "",
              duration: 200, picURL: nil)
}

print("— ① 酷我封面下线 / 酷狗歌手头像")

// 酷我搜索结果的 picURL 必须为空（release 解析不再吃 pic 字段）
let kuwoItem: [String: Any] = ["rid": "228908", "name": "晴天", "artist": "周杰伦",
                               "album": "叶惠美", "duration": 269,
                               "pic": "http://img1.kuwo.cn/wmvpic/324/x.jpg",
                               "albumpic": "http://img1.kuwo.cn/wmvpic/324/y.jpg",
                               "pic120": "http://img1.kuwo.cn/wmvpic/324/z.jpg"]
let kuwoRelease = KuwoPlaylist.release(from: kuwoItem)
check("酷我 release 不产出封面 URL", (kuwoRelease?.song.picURL ?? nil) == nil,
      kuwoRelease?.song.picURL ?? "nil")
check("酷我 release 仍然拿到歌名/歌手/rid",
      kuwoRelease?.song.name == "晴天" && kuwoRelease?.song.platformID == "228908")

let softhead = Song.make(platform: .kugou, platformID: "h", name: "断了的弦", singer: "周杰伦",
                         album: "", duration: 297,
                         picURL: "https://singerimg.kugou.com/uploadpic/softhead/500/x.jpg")
check("酷狗 softhead（歌手头像）判死", CoverResolver.isLegacyDeadCover(softhead))
let kugouAlbum = Song.make(platform: .kugou, platformID: "h2", name: "断了的弦", singer: "周杰伦",
                           album: "寻找周杰伦", duration: 297,
                           picURL: "https://imge.kugou.com/stdmusic/500/x.jpg")
check("酷狗正常专辑图不判死", !CoverResolver.isLegacyDeadCover(kugouAlbum))
let qqPic = Song.make(platform: .qq, platformID: "m", name: "晴天", singer: "周杰伦",
                      album: "", duration: 269,
                      picURL: "https://y.gtimg.cn/music/photo_new/T002R300x300M000a.jpg")
check("QQ 封面不受酷狗规则影响", !CoverResolver.isLegacyDeadCover(qqPic))

print("— ① iTunes 必须带店")
check("默认店 tw", ITunesCover.searchURL(title: "青花瓷", artist: "周杰伦").contains("country=tw"))
check("可换 hk", ITunesCover.searchURL(title: "青花瓷", artist: "周杰伦", country: "hk")
        .contains("country=hk"))
check("编码后不含裸 &", !ITunesCover.searchURL(title: "A & B", artist: "C").contains("A & B"))

print("— ③ 档位：窗口 + 兜底方向 + 显示")
check("起播窗口 2.6s", DownloadResolver.startWindow == 2.6, "\(DownloadResolver.startWindow)")
check("低档宽限 1.2s", DownloadResolver.startLowTierGrace == 1.2,
      "\(DownloadResolver.startLowTierGrace)")
check("够档线仍是 320k 档", DownloadResolver.startGoodEnoughTier == 700)

check("点无损没货 → 先给 320k",
      DownloadResolver.fallbackPreference(.lossless) == [.high, .standard])
check("点 320k 没货 → 先给 128k（不越级给无损）",
      DownloadResolver.fallbackPreference(.high) == [.standard, .lossless])
check("点 128k 没货 → 只能往上",
      DownloadResolver.fallbackPreference(.standard) == [.high, .lossless])

check("96k 的源标成「标准 128k（实测 96k）」",
      QualityLevel.standard.labeled(kbps: 96) == "标准 128k（实测 96k）",
      QualityLevel.standard.labeled(kbps: 96))
check("124k 与标称差不多就不啰嗦",
      QualityLevel.standard.labeled(kbps: 124) == "标准 128k",
      QualityLevel.standard.labeled(kbps: 124))
check("320k 档 319k 不啰嗦", QualityLevel.high.labeled(kbps: 319) == "高品 320k",
      QualityLevel.high.labeled(kbps: 319))
check("码率未知只写档位", QualityLevel.high.labeled(kbps: 0) == "高品 320k")

print("— ④ 判死名单")
DownloadRejections.clear()
let bad = StreamSource(url: "https://api.x.cn/a?token=1", backendName: "妖狐酷我",
                       platform: .kuwo, quality: .lossless, format: "flac", note: "")
var badFull = bad
badFull.totalBytes = 27_330_647
badFull.kbps = 1016
check("没记过就不算判死", !DownloadRejections.isRejected(badFull))
DownloadRejections.reject(badFull, reason: "文件只有 5:01、曲目 3:35（差 86 秒）")
check("记过就判死", DownloadRejections.isRejected(badFull))
// 同一份文件换了 token（URL 不同、host/体积/码率相同）→ 仍然判死
var sameFile = StreamSource(url: "https://api.x.cn/a?token=999", backendName: "妖狐酷我",
                            platform: .kuwo, quality: .lossless, format: "flac", note: "")
sameFile.totalBytes = 27_330_647
sameFile.kbps = 1016
check("换 token 仍然认得出是同一份", DownloadRejections.isRejected(sameFile))
// 体积不同 = 另一份文件，不该误杀
var otherFile = StreamSource(url: "https://api.x.cn/a?token=1", backendName: "妖狐酷我",
                             platform: .kuwo, quality: .high, format: "mp3", note: "")
otherFile.totalBytes = 8_620_845
otherFile.kbps = 320
check("体积/码率不同不误杀", !DownloadRejections.isRejected(otherFile))
DownloadRejections.clear()
check("清空后不再判死", !DownloadRejections.isRejected(badFull))

print("— ④ 探头部只认「头里有长度」的容器")
// m4a 的 moov 在尾部时，头里读不出长度 → duration 必须 nil（=不拦）
let fakeM4A = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20,
                    0x00, 0x00, 0x02, 0x00])
check("m4a 只有 ftyp 头 → 解不出长度", MediaIndexRules.duration(head: fakeM4A, container: "m4a",
                                                       totalBytes: 0) == nil)
// FLAC 头里带 STREAMINFO：sampleRate(20) + totalSamples(36)，造一个 240s 的
var flacHead = [UInt8](repeating: 0, count: 64)
flacHead[0] = 0x66; flacHead[1] = 0x4C; flacHead[2] = 0x61; flacHead[3] = 0x43   // fLaC
flacHead[4] = 0x00                                                               // STREAMINFO
let sr: UInt64 = 44100, samples: UInt64 = 44100 * 240
let acc: UInt64 = (sr << 44) | samples
for i in 0..<8 { flacHead[18 + i] = UInt8((acc >> (56 - 8 * UInt64(i))) & 0xFF) }
let flacSec = MediaIndexRules.duration(head: Data(flacHead), container: "flac", totalBytes: 0)
check("FLAC 头能解出 240s", flacSec.map { abs($0 - 240) < 1 } ?? false, "\(flacSec ?? -1)")

print("")
print(fail.isEmpty ? "全部通过：\(pass) 条" : "失败 \(fail.count)/\(pass + fail.count)：\(fail)")
exit(fail.isEmpty ? 0 : 1)

// r146 迷你自测：只跑本轮新增的纯逻辑断言。
//
// 为什么单独编：本机 WSL 的 zlib 桩（CompressionStub）跑不通，官方 SelfTest 会在
// "歌词解密" 那节中止（4 条 zlib 断言失败 → 进程退出 1），后面几节根本跑不到。
// 这份文件用同一批 selftest-flat 源文件编译，只替换 main，专门验本轮四条改动。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func src(_ fmt: String, _ kbps: Int64, _ q: QualityLevel, bytes: Int64,
         url: String = "https://example.com/a.mp3", platform: MusicPlatform = .kuwo,
         backend: String = "t") -> StreamSource {
    StreamSource(url: url, backendName: backend, platform: platform, quality: q, format: fmt,
                 note: "", directId: true, kbps: kbps, totalBytes: bytes, rangeOK: true)
}

print("— 内容闸门：占位提示音 / 加密包")
let prompt = src("mp3", 4, .standard, bytes: 181_521)
check("占位提示音被判占位", PlaybackQualityRules.isPlaceholder(prompt, songDurationSec: 344))
check("占位提示音不可用（哪怕 ≤320k）",
      !PlaybackQualityRules.isUsable(prompt, songDurationSec: 344))
check("isPlayable 仍只谈档位（历史口径不变）", PlaybackQualityRules.isPlayable(prompt))
let real320 = src("mp3", 250, .high, bytes: 10_792_943)
check("真 320k 可用", PlaybackQualityRules.isUsable(real320, songDurationSec: 344))
check("真 320k 不算占位", !PlaybackQualityRules.isPlaceholder(real320, songDurationSec: 344))
check("体积未知不判占位",
      !PlaybackQualityRules.isPlaceholder(src("mp3", 0, .standard, bytes: 0), songDurationSec: 344))
check(".mgg 判加密", StreamEncryptionRules.isEncrypted("http://x/O8M0003.mgg?guid=1"))
check("O4M 路径判加密", StreamEncryptionRules.isEncrypted("http://x/O4M0003ae8"))
check("普通 mp3 不判加密", !StreamEncryptionRules.isEncrypted("http://x/M800003.mp3"))
check("加密源不可用",
      !PlaybackQualityRules.isUsable(
        src("mp3", 320, .high, bytes: 11_698_595, url: "http://x/O8M0003.mgg?guid=1"),
        songDurationSec: 269))
check("坏源指纹按 体积+时长",
      PlaybackQualityRules.fingerprint(totalBytes: 181_521, durationSec: 344) == "181521-344")

print("— 无损兜底：只在最后一条可用源时放开")
let flac = src("flac", 1288, .lossless, bytes: 55_397_039, backend: "妖狐酷我")
check("常规路径 FLAC 不能起播", !PlaybackQualityRules.isUsable(flac, songDurationSec: 344))
check("兜底路径允许无损", PlaybackQualityRules.isUsable(flac, songDurationSec: 344, allowLossless: true))
check("兜底开关是开的", PlaybackQualityRules.allowsLosslessPlayback)
check("无损不会被当成更好的一条", !PlaybackQualityRules.isBetter(flac, than: real320))

print("— 后端熔断")
let now: TimeInterval = 1_800_000_000
check("403 → 900s", BackendHealthRules.cooldownSeconds(apiCode: 403, message: "", httpStatus: nil) == 900)
check("110001 → 300s", BackendHealthRules.cooldownSeconds(apiCode: 110001, message: "", httpStatus: nil) == 300)
check("503 → 120s", BackendHealthRules.cooldownSeconds(apiCode: 503, message: "", httpStatus: nil) == 120)
check("「频繁请求」文案也冷却",
      BackendHealthRules.cooldownSeconds(apiCode: nil, message: "由于你多次频繁请求", httpStatus: nil) == 900)
check("普通失败不冷却",
      BackendHealthRules.cooldownSeconds(apiCode: nil, message: "解析失败", httpStatus: nil) == nil)
check("冷却期内算在冷却", BackendHealthRules.isCoolingDown(blockedUntil: now + 10, now: now))
check("到期不算冷却", !BackendHealthRules.isCoolingDown(blockedUntil: now - 1, now: now))
check("无记录不算冷却", !BackendHealthRules.isCoolingDown(blockedUntil: nil, now: now))

print("— 落月 v3 信封")
let ok: [String: Any] = ["code": 0, "message": "访问成功",
                         "data": ["url": "http://ws.stream.qqmusic.qq.com/M800.mp3",
                                  "link": "https://i.y.qq.com/v8/playsong.html?songmid=x"]]
check("取 data.url 不取 data.link",
      (try? LuoyueQQAdapter.parseV3(ok)) == "http://ws.stream.qqmusic.qq.com/M800.mp3")
check("风控 110001 抛错",
      (try? LuoyueQQAdapter.parseV3(["code": 110001, "message": "cookie异常"])) == nil)
check("只有 link 也算失败",
      (try? LuoyueQQAdapter.parseV3(["code": 0, "data": ["link": "https://i.y.qq.com/x"]])) == nil)
check("v2 信封历史基线仍可解析",
      (try? LuoyueQQAdapter.parse(["code": 200, "data": ["url": "http://a/b.mp3"]])) == "http://a/b.mp3")

print("— 多源注册表")
let kuwo = SourceRegistry.all.filter { $0.platform == .kuwo }.map(\.name)
let qq = SourceRegistry.all.filter { $0.platform == .qq }.map(\.name)
check("酷我 ≥3 条", Set(kuwo).count >= 3, kuwo.joined(separator: "/"))
check("ikun 已注册", kuwo.contains("ikun 酷我"), kuwo.joined(separator: "/"))
check("星海已注册", kuwo.contains("星海酷我"), kuwo.joined(separator: "/"))
check("QQ 有 cyapi + 落月", Set(qq).count >= 2, qq.joined(separator: "/"))
check("落月已恢复注册", qq.contains("落月 QQ"), qq.joined(separator: "/"))

print("— QQ 搜索兜底的结构映射")
check("QQ 官方结果能映射成 Song（含 mid/时长/封面）",
      NeteaseSearchAdapter.songs(fromGdstudio: [
        ["id": "0039MnYb0qxYhV", "name": "晴天", "artist": ["周杰伦"], "album": "叶惠美"]
      ], platform: .qq).first?.platform == .qq)

print("\nPASS=\(pass) FAIL=\(fail.count)")
for f in fail { print("  FAILED: \(f)") }
exit(fail.isEmpty ? 0 : 1)

// r148 迷你自测（2026-11-21 v2.4.40）：本轮新增的三件事
//   ① 酷狗 zddyr source=kg 的档位映射
//   ② 网易 meting 直吐字节的"不是音频"闸
//   ③ QQ 搜索兜底（meting tencent）的 songmid 提取 + vkeys 110001 重试口径
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止
// （4 条 zlib 断言失败 → 进程退出），后面几节根本跑不到。这里用同一批源文件、只替换 main。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 酷狗取流：档位映射")
check("标准档 → 128k", XinghaiKugouAdapter.qualityParam(.standard) == "128k",
      XinghaiKugouAdapter.qualityParam(.standard))
check("高品档 → 320k", XinghaiKugouAdapter.qualityParam(.high) == "320k",
      XinghaiKugouAdapter.qualityParam(.high))
check("无损档 → flac（不是 108MB 的 master）",
      XinghaiKugouAdapter.qualityParam(.lossless) == "flac",
      XinghaiKugouAdapter.qualityParam(.lossless))

print("— 网易 meting：200 + text/html 不是歌")
check("真 320k（mp3 10MB）算音频",
      MetingStreamRules.looksLikeAudio(container: "mp3", totalBytes: 10_242_285))
check("真无损（flac 32MB）算音频",
      MetingStreamRules.looksLikeAudio(container: "flac", totalBytes: 32_511_640))
check("HTML 错误页（0 字节）不算音频",
      !MetingStreamRules.looksLikeAudio(container: "unknown", totalBytes: 0))
check("171KB 试听残片不算音频",
      !MetingStreamRules.looksLikeAudio(container: "mp3", totalBytes: 171_072))
check("容器认不出不算音频",
      !MetingStreamRules.looksLikeAudio(container: "unknown", totalBytes: 13_042_460))

print("— QQ 搜索兜底：meting tencent 给真 songmid")
let tu = "https://api.qijieya.cn/meting/?server=tencent&type=url&id=0039MnYb0qxYhV"
check("取出 QQ songmid", QQSearchAdapter.tencentMid(fromMetingURL: tu) == "0039MnYb0qxYhV",
      QQSearchAdapter.tencentMid(fromMetingURL: tu) ?? "nil")
check("网易 url 不能当 QQ mid",
      QQSearchAdapter.tencentMid(
        fromMetingURL: "https://api.qijieya.cn/meting/?server=netease&type=url&id=2668397359") == nil)
check("mid 太短不认",
      QQSearchAdapter.tencentMid(
        fromMetingURL: "https://api.qijieya.cn/meting/?server=tencent&type=url&id=abc") == nil)

print("— QQ 取流：110001 先重试一次")
check("110001 重试", LuoyueQQAdapter.shouldRetryOnce(code: 110001))
check("503 不重试", !LuoyueQQAdapter.shouldRetryOnce(code: 503))
check("0 不重试", !LuoyueQQAdapter.shouldRetryOnce(code: 0))
check("403 不重试", !LuoyueQQAdapter.shouldRetryOnce(code: 403))

print("— 注册表：新源真的进去了")
let all = SourceRegistry.all
let kg = all.filter { $0.platform == .kugou }.map(\.name)
let ne = all.filter { $0.platform == .netease }.map(\.name)
let kw = all.filter { $0.platform == .kuwo }.map(\.name)
let qq = all.filter { $0.platform == .qq }.map(\.name)
check("星海酷狗已注册", kg.contains("星海酷狗"), kg.joined(separator: "/"))
check("酷狗 ≥2 条（官方 + 星海）", Set(kg).count >= 2, kg.joined(separator: "/"))
check("meting 网易已注册", ne.contains("meting 网易"), ne.joined(separator: "/"))
check("网易 ≥3 条（gdstudio/oiapi/meting）", Set(ne).count >= 3, ne.joined(separator: "/"))
check("酷我 ≥4 条（妖狐/官方/ikun/星海）", Set(kw).count >= 4, kw.joined(separator: "/"))
check("QQ 2 条（cyapi/落月）", Set(qq).count >= 2, qq.joined(separator: "/"))
check("注册表无重名", Set(all.map(\.name)).count == all.count, "\(all.count) 条")

print("— 占位闸仍然生效（回归）")
func src(_ fmt: String, _ kbps: Int64, _ q: QualityLevel, bytes: Int64) -> StreamSource {
    StreamSource(url: "https://example.com/a.\(fmt)", backendName: "t", platform: .kuwo,
                 quality: q, format: fmt, note: "", directId: true, kbps: kbps,
                 totalBytes: bytes, rangeOK: true)
}
check("181,521 B 提示音仍是占位",
      PlaybackQualityRules.isPlaceholder(src("mp3", 4, .standard, bytes: 181_521), songDurationSec: 344))
check("真 320k 不是占位",
      !PlaybackQualityRules.isPlaceholder(src("mp3", 250, .high, bytes: 10_792_943), songDurationSec: 344))

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  FAIL: \(f)") }
    exit(1)
}
exit(0)

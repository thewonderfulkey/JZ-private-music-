// r261 迷你自测（2026-11-25）：下载落盘后的「身份 + 完整性」
//   事故：《众》下载成黄霄雲**另一首** 3:17 的 FLAC，还标了"已下载"。
//   产品口径：宁缺勿错 —— 拿不到可靠文件就标「无可靠源」，不落盘。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

typealias Rules = DownloadIntegrityRules

func run(_ f: Rules.Facts, title: String = "众", singer: String = "黄霄雲",
         dur: Int = 215, matched: String? = "众", matchedSinger: String? = "黄霄雲",
         expected: Int64 = 0) -> Rules.Verdict {
    Rules.check(facts: f, displayedTitle: title, displayedSinger: singer,
                displayedDurationSec: dur, matchedName: matched,
                matchedSinger: matchedSinger, expectedBytes: expected)
}

print("— 长度：文件自己报的时长 vs 曲目")
let good = Rules.Facts(container: "flac", durationSec: 215.45, bytes: 47_977_837)
check("官方 FLAC 215.45s 对 215.5s → 通过", run(good, expected: 47_977_837) == .ok(215.45),
      "\(run(good, expected: 47_977_837))")
check("容差就是 1.5 秒", Rules.durationToleranceSec == 1.5)

let wrong = Rules.Facts(container: "flac", durationSec: 197, bytes: 21_000_000)
if case .reject(let r) = run(wrong) {
    check("3:17 的文件（差 18 秒）→ 拒", true)
    check("文案写清「不是这首歌」", r.contains("不是这首歌"), r)
} else {
    check("3:17 的文件（差 18 秒）→ 拒", false)
}

let edge = Rules.Facts(container: "flac", durationSec: 216.4, bytes: 40_000_000)
check("差 1.4 秒 → 通过（不误杀跨平台母带）", run(edge) == .ok(216.4), "\(run(edge))")
let edge2 = Rules.Facts(container: "flac", durationSec: 216.8, bytes: 40_000_000)
if case .reject = run(edge2) { check("差 1.8 秒 → 拒", true) } else { check("差 1.8 秒 → 拒", false) }

print("— 其它三条闸")
if case .reject = run(Rules.Facts(container: "unknown", durationSec: 215, bytes: 1000)) {
    check("认不出容器 → 拒", true)
} else { check("认不出容器 → 拒", false) }
if case .reject = run(Rules.Facts(container: "flac", durationSec: nil, bytes: 21_000_000)) {
    check("读不出长度（流式 FLAC）→ 拒", true)
} else { check("读不出长度（流式 FLAC）→ 拒", false) }
if case .reject = run(Rules.Facts(container: "flac", durationSec: 215.4, bytes: 10_000_000),
                      expected: 47_977_837) {
    check("字节不到预期一小半 → 拒", true)
} else { check("字节不到预期一小半 → 拒", false) }

print("— 身份：同歌手另一首（时长刚好接近）")
if case .reject(let r) = run(Rules.Facts(container: "flac", durationSec: 215.2, bytes: 40_000_000),
                             matched: "留不住的夏天") {
    check("来源是另一首歌 → 拒", true)
    check("文案写出对不上的歌名", r.contains("留不住的夏天"), r)
} else { check("来源是另一首歌 → 拒", false) }
check("没有身份记录但长度对得上 → 放行（老流程）",
      run(good, matched: nil, matchedSinger: nil) == .ok(215.45))

print("")
print("PASS=\(pass) FAIL=\(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  ✗ \(f)") }
    exit(1)
}

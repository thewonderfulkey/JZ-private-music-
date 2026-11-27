// r291 探针（2026-11-27）：开屏时间轴的"静止空档"到底在哪一段
// 输出：最长静止窗（秒/起止）+ 逐 16ms 的活动量，便于对准是哪一拍。
import Foundation

var pass = 0
var fail: [String] = []
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 关键帧（新曲线）")
for ms in [0, 16, 32, 64, 96, 160, 240, 340, 400, 580, 660, 800, 1040, 1300, 1460] {
    let s = SplashTimeline.snapshot(at: Double(ms) / 1000)
    print(String(format: "  %4dms  opacity=%.3f band=%.3f cupL=%.3f cupR=%.3f wave1=%.3f thump=%.3f",
                 ms, s.entrance, s.band, s.cupLeft, s.cupRight, s.wave1, s.thump))
}

print("\n— 静止窗定位（dt=1/120，阈值 0.25 与 CI 同口径）")
let dt = 1.0 / 120
var runStart = -1.0
var best: (start: Double, len: Double) = (0, 0)
var t = dt
while t <= SplashTimeline.total + 1e-9 {
    let d = SplashTimeline.motionDelta(from: SplashTimeline.snapshot(at: t - dt),
                                       to: SplashTimeline.snapshot(at: t))
    if d < 0.25 {
        if runStart < 0 { runStart = t - dt }
        let len = t - runStart
        if len > best.len { best = (runStart, len) }
    } else {
        runStart = -1
    }
    t += dt
}
print(String(format: "  最长静止窗：%.3fs 起，持续 %.3fs = %.0fms",
             best.start, best.len, best.len * 1000))
print(String(format: "  全片最长静止（API）：%.0fms", SplashTimeline.longestStillWindow() * 1000))

print("\n— 活动量曲线（每 33ms，看哪些位置偏空）")
var last = SplashTimeline.snapshot(at: 0)
var tt = 1.0 / 30
while tt <= SplashTimeline.total + 1e-9 {
    let s = SplashTimeline.snapshot(at: tt)
    let d = SplashTimeline.motionDelta(from: last, to: s)
    let bar = String(repeating: "#", count: min(48, Int(d * 8)))
    print(String(format: "  %5.2fs  %6.3f  %@%@", tt, d, bar, d < 0.25 ? "  ← 空档" : ""))
    last = s
    tt += 1.0 / 30
}

print("\n— 断言")
check("起手 64ms 不透明度 ≤ 15%", SplashTimeline.snapshot(at: 0.064).entrance <= 0.15,
      String(format: "%.3f", SplashTimeline.snapshot(at: 0.064).entrance))
check("起手 160ms 不到一半", SplashTimeline.snapshot(at: 0.16).entrance < 0.5,
      String(format: "%.3f", SplashTimeline.snapshot(at: 0.16).entrance))
check("入场结束即满", SplashTimeline.snapshot(at: SplashTimeline.entrance.end + 0.02).entrance > 0.99)
check("全片最长静止 < 50ms（<2 帧）", SplashTimeline.longestStillWindow() < 0.05,
      String(format: "%.0fms", SplashTimeline.longestStillWindow() * 1000))

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  失败：\(f)") }
    exit(1)
}

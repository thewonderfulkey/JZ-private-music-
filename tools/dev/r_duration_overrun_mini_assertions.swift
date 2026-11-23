// 总长与越界迷你自测（2026-11-23）
//   老板《半岛铁盒》：拖动进度条之后"跟时间条对不上，明明都唱完了还在唱"。
//   量出来：本地 FLAC 的容器声明 5:19，实际能解出 ≥5:32 —— 进度条按声明走，提前 13 秒到头。
//   r66 的兜底是"每拍把 duration +0.5"，它就是这个症状的来源；现在改成"确认越界 → 当播完 + 记住真实长度"。
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止，这段在文件末尾跑不到。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("\n— 起播总长 initialDuration(metadata:measured:)")
check("没量过就用元数据", TrackDurationRules.initialDuration(metadata: 319, measured: nil) == 319)
check("量到的更长就用量到的", TrackDurationRules.initialDuration(metadata: 319, measured: 332) == 332)
check("量到的更短不缩水", TrackDurationRules.initialDuration(metadata: 319, measured: 300) == 319)
check("元数据 NaN 不崩", TrackDurationRules.initialDuration(metadata: .nan, measured: 200) == 200)

print("\n— 越界 isOverrun(currentTime:duration:)")
check("等于总长不算", !TrackDurationRules.isOverrun(currentTime: 319, duration: 319))
check("超 1 秒在余量内不算", !TrackDurationRules.isOverrun(currentTime: 320, duration: 319))
check("超 2 秒以上才算", TrackDurationRules.isOverrun(currentTime: 321.5, duration: 319))
check("总长 0 永远不算", !TrackDurationRules.isOverrun(currentTime: 30, duration: 0))
check("录屏那一帧（声明 319 / 位置 321.5）确实判越界",
      TrackDurationRules.isOverrun(currentTime: 321.5, duration: 319))

print("\n— 记录真实长度 measuredDuration")
check("留 0.5 秒余量", TrackDurationRules.measuredDuration(currentTime: 321.5) == 322)
check("非法位置给 0", TrackDurationRules.measuredDuration(currentTime: .nan) == 0)

print("\n— 拖动目标 seekTarget(fraction:duration:)")
check("拖到最右端留 0.5 秒", TrackDurationRules.seekTarget(fraction: 1, duration: 319) == 318.5)
check("拖到中间按比例", TrackDurationRules.seekTarget(fraction: 0.5, duration: 319) == 159.5)
check("拖到最左是 0", TrackDurationRules.seekTarget(fraction: -1, duration: 319) == 0)
check("越界拖动不超总长-0.5", TrackDurationRules.seekTarget(fraction: 2, duration: 319) == 318.5)

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  ✗ \(f)") }
    exit(1)
}
print("全部通过")
exit(0)

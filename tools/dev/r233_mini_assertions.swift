// r233 迷你自测（2026-11-24 v2.4.100）：页头「随机」抽一首起播
//   ① 候选必须排除正在播的那首（用 id 判，不是下标）
//   ② 每个候选都抽得到（等概率：随机数铺满就铺满全部候选）
//   ③ 连点多次每次都换一首
//   ④ 边界：只有一首 / 同一首重复出现 / 空列表
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 老板报的现象：七个页面点「随机」都放第一首，再点又回到那一首")
let ids = ["a", "b", "c", "d", "e"]
var seen = Set<Int>()
for r in 0..<4 {
    if let i = ShuffleStart.index(ids: ids, currentID: "c", randomIn: { _ in r }) {
        seen.insert(i)
    }
}
check("正在播 c(2) 时，候选铺满 a,b,d,e", seen == [0, 1, 3, 4], "seen=\(seen.sorted())")
check("永远不抽到正在播的那首", !seen.contains(2))

print("— 第一次点（没有在播的）：整份列表都是候选")
check("随机数 0 → 第 0 首", ShuffleStart.index(ids: ids, currentID: nil, randomIn: { _ in 0 }) == 0)
check("随机数 4 → 第 4 首", ShuffleStart.index(ids: ids, currentID: nil, randomIn: { _ in 4 }) == 4)

print("— 连点多次：每次都要换")
var current = "a"
var picks: [String] = []
for r in [0, 1, 2, 3, 0] {
    guard let i = ShuffleStart.index(ids: ids, currentID: current, randomIn: { _ in r }) else {
        check("随机起播不该返回 nil", false)
        break
    }
    current = ids[i]
    picks.append(current)
}
check("连点五次，相邻两次都不同", picks.count == 5 &&
      zip(picks, picks.dropFirst()).allSatisfy { pair in pair.0 != pair.1 }, "picks=\(picks)")
check("第一次就换掉了起点的 a", picks.first != "a", "first=\(String(describing: picks.first))")

print("— 边界")
check("只有一首就是它",
      ShuffleStart.index(ids: ["x"], currentID: "x", randomIn: { _ in 0 }) == 0)
check("没在播、只有一首也是它",
      ShuffleStart.index(ids: ["x"], currentID: nil, randomIn: { _ in 0 }) == 0)
check("同一首重复两次也排除（a,b,b,c 在播 b → 抽到 c）",
      ShuffleStart.index(ids: ["a", "b", "b", "c"], currentID: "b", randomIn: { _ in 1 }) == 3)
check("整份都是同一首：只能给它（不能 nil）",
      ShuffleStart.index(ids: ["b", "b"], currentID: "b", randomIn: { _ in 0 }) == 0)
check("空列表：没有起播下标",
      ShuffleStart.index(ids: [], currentID: nil, randomIn: { _ in 0 }) == nil)

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  FAIL: \(f)") }
    exit(1)
}
exit(0)

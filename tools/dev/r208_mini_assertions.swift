// r208 迷你自测（2026-11-23 v2.4.85）：下载页「多选处理栏」出现时机 + 与两条底栏的接缝
//   ① 还没选歌时处理栏不出现（老板：至少选中一条再出现）
//   ② 在播歌时贴迷你条卡片上沿（56），没播歌时贴底层栏上沿（0，不再留 24）
//   ③ 高度口径统一：处理栏 52 = 44 可点 + 上下各 4；两条叠起来 56+52=108
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 处理栏出现时机（BatchSelection.isBarVisible）")
check("多选态 + 一首没选 → 不出现", !BatchSelection.isBarVisible(selectMode: true, pickedCount: 0))
check("多选态 + 选 1 首 → 出现", BatchSelection.isBarVisible(selectMode: true, pickedCount: 1))
check("多选态 + 选 3 首 → 出现", BatchSelection.isBarVisible(selectMode: true, pickedCount: 3))
check("非多选态（哪怕有残留选择）→ 不出现",
      !BatchSelection.isBarVisible(selectMode: false, pickedCount: 2))
check("脏计数（-1）也不出现", !BatchSelection.isBarVisible(selectMode: true, pickedCount: -1))
check("取消最后一首（1 → 0）→ 收起",
      BatchSelection.isBarVisible(selectMode: true, pickedCount: 1)
      && !BatchSelection.isBarVisible(selectMode: true, pickedCount: 0))

print("— 接缝口径（MiniPlayerMetrics）")
check("迷你条卡片上沿 = 56（= Tokens.Size.miniPlayerHeight）", MiniPlayerMetrics.barCardTop == 56,
      "\(MiniPlayerMetrics.barCardTop)")
check("底衬不再比卡片高：barHeight - barCardTop = 8（留给列表的呼吸）",
      MiniPlayerMetrics.barHeight - MiniPlayerMetrics.barCardTop == 8,
      "\(MiniPlayerMetrics.barHeight - MiniPlayerMetrics.barCardTop)")
check("在播歌：处理栏底边 = 56（贴卡片上沿）",
      MiniPlayerMetrics.batchBarBottomInset(playing: true) == 56,
      "\(MiniPlayerMetrics.batchBarBottomInset(playing: true))")
check("没播歌：处理栏底边 = 0（贴底层 Tab 栏上沿）",
      MiniPlayerMetrics.batchBarBottomInset(playing: false) == 0,
      "\(MiniPlayerMetrics.batchBarBottomInset(playing: false))")
check("处理栏高度 = 52（44 可点 + 4 + 4）", MiniPlayerMetrics.batchBarHeight == 52,
      "\(MiniPlayerMetrics.batchBarHeight)")
check("在播歌时列表该让出 56 + 52 = 108（两条不重叠、不压住最后一条）",
      MiniPlayerMetrics.batchBarBottomInset(playing: true) + MiniPlayerMetrics.batchBarHeight == 108,
      "\(MiniPlayerMetrics.batchBarBottomInset(playing: true) + MiniPlayerMetrics.batchBarHeight)")
check("没播歌时列表该让出 52（比原来的 24 呼吸多出处理栏）",
      max(MiniPlayerMetrics.listBottomInset(playing: false), MiniPlayerMetrics.batchBarHeight) == 52,
      "\(max(MiniPlayerMetrics.listBottomInset(playing: false), MiniPlayerMetrics.batchBarHeight))")

print("— 老板截图里的那条缝：不再出现在 56 之上")
// 旧口径：处理栏底边 = listBottomInset(playing) = 64，卡片上沿 = 56 → 中间 8pt 露出列表。
check("旧口径会漏 8pt（64 - 56），新口径 0",
      MiniPlayerMetrics.listBottomInset(playing: true) - MiniPlayerMetrics.barCardTop == 8
      && MiniPlayerMetrics.batchBarBottomInset(playing: true) - MiniPlayerMetrics.barCardTop == 0,
      "\(MiniPlayerMetrics.batchBarBottomInset(playing: true) - MiniPlayerMetrics.barCardTop)")

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  FAIL: \(f)") }
    exit(1)
}
exit(0)

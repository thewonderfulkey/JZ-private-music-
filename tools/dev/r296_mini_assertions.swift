// r296 迷你自测（2026-11-27）：滑动时不许触发点击反馈
import Foundation

var pass = 0
var fail: [String] = []
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

check("按下且没在拖 → 亮", PressFeedbackRules.showsHighlight(pressed: true, panning: false))
check("按下但在拖 → 不亮", !PressFeedbackRules.showsHighlight(pressed: true, panning: true))
check("没按下 → 不亮", !PressFeedbackRules.showsHighlight(pressed: false, panning: false)
                        && !PressFeedbackRules.showsHighlight(pressed: false, panning: true))

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  失败：\(f)") }
    exit(1)
}

// r166 迷你自测（2026-11-21 v2.4.50）：下载 tab 多选
//   老板："加一个可以多选的按钮，支持批量处理，多选后支持全选进行删除等操作"
//   视图只管画，勾选逻辑在 `BatchSelection` —— 这里钉住语义。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

let a = UUID(), b = UUID(), c = UUID(), other = UUID()

print("— 全选判定")
check("空列表不算全选", !BatchSelection.isAllSelected(picked: [], visible: []))
check("全选上为真", BatchSelection.isAllSelected(picked: [a, b], visible: [a, b]))
check("少一个为假", !BatchSelection.isAllSelected(picked: [a], visible: [a, b]))
check("有别人不影响（只看可见的）",
      BatchSelection.isAllSelected(picked: [a, b, other], visible: [a, b]))

print("— 全选 / 取消全选")
check("没全选 → 并入可见",
      BatchSelection.togglingAll(picked: [c], visible: [a, b]) == [a, b, c])
check("已全选 → 只移除可见（不动搜索过滤掉的选择）",
      BatchSelection.togglingAll(picked: [a, b, other], visible: [a, b]) == [other])
check("空可见 + 空选择 → 还是空",
      BatchSelection.togglingAll(picked: [], visible: []).isEmpty)

print("— 单行勾选")
check("没选 → 加上", BatchSelection.toggling([a], b) == [a, b])
check("已选 → 去掉", BatchSelection.toggling([a, b], a) == [b])
check("空集合点一下", BatchSelection.toggling([], a) == [a])

print("— 清理残留（删完/搜索过滤后）")
check("只保留还看得见的", BatchSelection.pruning([a, b, c], visible: [a, c]) == [a, c])
check("全没了 → 空", BatchSelection.pruning([a, b], visible: []).isEmpty)

print("")
print("PASS=\(pass) FAIL=\(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  ✗ \(f)") }
    exit(1)
}

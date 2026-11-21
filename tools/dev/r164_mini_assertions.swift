// r164 迷你自测（2026-11-21 v2.4.47）：导入结果文案
//   老板问"为什么有些歌导不进去" → 弹窗里要写明扩展名汇总与原因，
//   所以这两条纯逻辑必须有断言钉住（`ape` 全拒才能说"导进来也是无声"）。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 扩展名汇总")
check("去重 + 小写 + 排序", ImportRules.extensionSummary(["a.wma", "b.APE", "c.ape"]) == "ape/wma",
      ImportRules.extensionSummary(["a.wma", "b.APE", "c.ape"]))
check("空列表 → 未知", ImportRules.extensionSummary([]) == "未知")
check("没有扩展名 → 未知", ImportRules.extensionSummary(["README", "Makefile"]) == "未知")
check("混杂：有扩展名的照列", ImportRules.extensionSummary(["a.mp3", "README"]) == "mp3")

print("— 判定'系统没解码器'（只有这种才说'导进来也是无声'）")
check("ape+wma 全是系统不支持的", ImportRules.hasOnlyUndecodableExtensions(["a.ape", "b.wma"]))
check("有一个 mp3 就不能那么说",
      !ImportRules.hasOnlyUndecodableExtensions(["a.ape", "b.mp3"]))
check("认不出的扩展名（可能是加密包）不算",
      !ImportRules.hasOnlyUndecodableExtensions(["a.lexClip"]))
check("空列表不算", !ImportRules.hasOnlyUndecodableExtensions([]))
check("大写也算", ImportRules.hasOnlyUndecodableExtensions(["A.APE"]))

print("")
print("PASS=\(pass) FAIL=\(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  ✗ \(f)") }
    exit(1)
}

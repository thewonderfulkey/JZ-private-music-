// r167 迷你自测（2026-11-21 v2.4.51）：导入"先抢再解析"
//
// 事故实证（诊断/import.log）：全选 664 首（27 GB），崩点固定在第 59 秒；
// 崩点前 444/419 首 0 失败，崩点后 219/244 首全失败；系统原话"未能打开文件…因为它不存在"；
// 设备当时还剩 303 GB。根因是系统选择器 asCopy 的副本放在 App 的 tmp 里，
// iOS 约 1 分钟后清掉 → 后面的 URL 全指向空气。
//
// 本文件钉住"抢取阶段"的纯逻辑：时间预算、ENOENT 判定、停下条件、文案、暂存目录隐藏。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 时间预算与停止条件")
check("预算就是 40 秒（别被改大，改大就踩到系统清理线）", ImportGrabRules.grabBudget == 40)
check("连续 5 个不存在才停", ImportGrabRules.consecutiveMissingAbort == 5)
check("39.9 秒还在预算内 → 继续抢",
      !ImportGrabRules.shouldStopGrabbing(elapsed: 39.9, consecutiveMissing: 0))
check("正好 40 秒 → 停", ImportGrabRules.shouldStopGrabbing(elapsed: 40, consecutiveMissing: 0))
check("75 秒 → 停", ImportGrabRules.shouldStopGrabbing(elapsed: 75, consecutiveMissing: 0))
check("连续 4 个不存在 → 还没到线",
      !ImportGrabRules.shouldStopGrabbing(elapsed: 10, consecutiveMissing: 4))
check("连续 5 个不存在 → 认定 tmp 被清，停",
      ImportGrabRules.shouldStopGrabbing(elapsed: 10, consecutiveMissing: 5))

print("— ENOENT 判定（按错误码，不按系统语言文案）")
check("NSFileNoSuchFileError(4) = 不存在",
      ImportGrabRules.isMissingFile(domain: "NSCocoaErrorDomain", code: 4))
check("NSFileReadNoSuchFileError(260) = 不存在",
      ImportGrabRules.isMissingFile(domain: "NSCocoaErrorDomain", code: 260))
check("EACCES(257) 不算不存在（那是权限问题，别混）",
      !ImportGrabRules.isMissingFile(domain: "NSCocoaErrorDomain", code: 257))
check("别的 domain 不算", !ImportGrabRules.isMissingFile(domain: "NSURLErrorDomain", code: 4))

print("— 报告文案（说人话 + 给下一步）")
let sum = ImportGrabRules.missedSummary(245)
check("摘要写清数量", sum.contains("245"))
check("摘要写清原因（临时副本）", sum.contains("临时副本"))
let early = ImportGrabRules.missedReason(count: 12, abortedEarly: true)
check("提前停下 → 建议分批 150 首以内", early.contains("150"))
check("提前停下 → 带上数量", early.contains("12"))
let late = ImportGrabRules.missedReason(count: 7, abortedEarly: false)
check("预算用完 → 也要说清已取到的都进来了", late.contains("已取到"))
check("预算用完 → 带上数量", late.contains("7"))

print("— 暂存目录不能被当成歌")
check("ImportStaging 在导入浏览器里隐藏", ImportRules.browserHides(name: "ImportStaging"))
check("浏览器判成 other（不出现在列表）",
      ImportRules.browserKind(name: "ImportStaging", isDirectory: true) == .other)
check("诊断目录照旧隐藏", ImportRules.browserHides(name: "诊断"))
check("用户自己的文件夹不隐藏", !ImportRules.browserHides(name: "我的歌"))
check("隐藏名单里确实有 ImportStaging（与 DownloadManager.importStagingFolderName 同字面量）",
      ImportRules.browserHiddenNames.contains("ImportStaging"))

print("")
print("PASS=\(pass) FAIL=\(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  ✗ \(f)") }
    exit(1)
}

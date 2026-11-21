// r163 迷你自测（2026-11-21 v2.4.46）：本轮只改了"导入入口"的纯逻辑部分
//   ① 内置导入浏览器：哪些条目显示 / 哪类能选（`ImportRules.BrowserKind`）
//   ② 浏览器排序：文件夹在前、`02 - x` 排在 `10 - y` 前（纯 String < 会排反）
//   ③ 隐藏名单：`诊断` 与隐藏文件不列（`Inbox` 要列 —— 别的 App 送来的文件落在那里）
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 内置浏览器：条目分类")
check("mp3 能选", ImportRules.browserKind(name: "a.mp3", isDirectory: false) == .audio)
check("大写 M4A 也能选", ImportRules.browserKind(name: "A.M4A", isDirectory: false) == .audio)
check("flac 能选", ImportRules.browserKind(name: "晴天.flac", isDirectory: false) == .audio)
check("文件夹是 folder", ImportRules.browserKind(name: "我的歌", isDirectory: true) == .folder)
check("ape 看得见但选不了", ImportRules.browserKind(name: "a.ape", isDirectory: false) == .unsupported)
check("wma 看得见但选不了", ImportRules.browserKind(name: "a.wma", isDirectory: false) == .unsupported)
check("lrc 不显示", ImportRules.browserKind(name: "a.lrc", isDirectory: false) == .other)
check("jpg 不显示", ImportRules.browserKind(name: "cover.jpg", isDirectory: false) == .other)
check("无扩展名不显示", ImportRules.browserKind(name: "README", isDirectory: false) == .other)

print("— 内置浏览器：隐藏名单")
check("诊断目录隐藏", ImportRules.browserHides(name: "诊断"))
check("隐藏文件隐藏", ImportRules.browserHides(name: ".DS_Store"))
check("Inbox 要显示（别的 App 送来的文件）", !ImportRules.browserHides(name: "Inbox"))
check("普通文件夹不隐藏", !ImportRules.browserHides(name: "Download"))
check("空名隐藏", ImportRules.browserHides(name: ""))

print("— 内置浏览器：排序")
check("文件夹排在文件前",
      ImportRules.browserComesBefore("zzz", true, "aaa.mp3", false))
check("文件不会排到文件夹前",
      !ImportRules.browserComesBefore("aaa.mp3", false, "zzz", true))
check("02 排在 10 前（不是字典序）",
      ImportRules.browserComesBefore("02 - a.mp3", false, "10 - b.mp3", false),
      "localizedStandardCompare 没生效")
check("排序是反对称的（a 在 b 前 ⇒ b 不在 a 前）",
      ImportRules.browserComesBefore("02 - a.mp3", false, "10 - b.mp3", false)
      != ImportRules.browserComesBefore("10 - b.mp3", false, "02 - a.mp3", false))
check("同名不算'在前'（比较函数对相等元素必须返回 false，否则排序崩）",
      !ImportRules.browserComesBefore("x", false, "x", false))

print("— 体积文案")
check("0 字节不显示体积", ImportRules.browserSizeText(0) == "")
check("负数不显示体积", ImportRules.browserSizeText(-5) == "")
check("正常体积有内容", !ImportRules.browserSizeText(10_242_285).isEmpty,
      ImportRules.browserSizeText(10_242_285))

print("")
print("PASS=\(pass) FAIL=\(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  ✗ \(f)") }
    exit(1)
}

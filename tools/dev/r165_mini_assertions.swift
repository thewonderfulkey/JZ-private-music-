// r165 迷你自测（2026-11-21 v2.4.48）：体积档位文案
//   老板："把下载那里的内存显示改为 GB 单位，一旦大于 1GB 就用 GB，小于用 MB，
//          小于 1MB 再降级，升级同理。"
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 档位：GB / MB / KB / B")
check("1.5 GB", ByteText.human(1_500_000_000) == "1.5 GB", ByteText.human(1_500_000_000))
check("正好 1GB 就走 GB", ByteText.human(1_000_000_000) == "1 GB", ByteText.human(1_000_000_000))
check("999.9MB 还是 MB", ByteText.human(999_900_000) == "999.9 MB", ByteText.human(999_900_000))
check("8.2 MB", ByteText.human(8_200_000) == "8.2 MB", ByteText.human(8_200_000))
check("正好 1MB 走 MB", ByteText.human(1_000_000) == "1 MB", ByteText.human(1_000_000))
check("999KB 走 KB", ByteText.human(999_000) == "999 KB", ByteText.human(999_000))
check("512KB", ByteText.human(512_000) == "512 KB", ByteText.human(512_000))
check("正好 1KB 走 KB", ByteText.human(1_000) == "1 KB", ByteText.human(1_000))
check("999B 走 B", ByteText.human(999) == "999 B", ByteText.human(999))
check("0 给 0 MB（不是空白）", ByteText.human(0) == "0 MB", ByteText.human(0))

print("— 不能出现 1.00 GB / 10.0 MB 这种尾巴")
check("GB 整数不带 .00", !ByteText.human(2_000_000_000).contains(".00"),
      ByteText.human(2_000_000_000))
check("MB 整数不带 .0", !ByteText.human(10_000_000).contains(".0"),
      ByteText.human(10_000_000))
check("GB 两位小数保留", ByteText.human(1_250_000_000) == "1.25 GB", ByteText.human(1_250_000_000))

print("— 与下载页原来口径一致（1MB 以上不会再出现空字符串）")
check("旧实现 <1MB 返回空串，新实现给 KB", ByteText.human(500_000) == "500 KB",
      ByteText.human(500_000))

print("")
print("PASS=\(pass) FAIL=\(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  ✗ \(f)") }
    exit(1)
}

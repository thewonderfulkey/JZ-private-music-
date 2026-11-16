"""静态检查手写 pbxproj：括号是否平衡、引用的对象是否都存在、target 的关键字段是否齐。

为什么要有它：这台开发机没有 Xcode，`xcodebuild` 只在 CI 上跑；而 pbxproj 写错时
xcodebuild 的报错往往很含糊（"Cycle inside" / "target has no product"）。这个脚本
把能离线判定的部分先判掉，省掉一轮 4 分钟的 CI。

用法（仓库根目录）：
    python tools/ios/check_pbxproj.py
退出码 0 = 通过。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

PBX = Path("ios/JZMusicHelper.xcodeproj/project.pbxproj")

ID_RE = re.compile(r"\b([A-Z][0-9A-F]{23})\b")
DEF_RE = re.compile(r"^\t\t([A-Z][0-9A-F]{23})(?: /\*[^*]*\*/)? = \{", re.M)


def main() -> int:
    src = PBX.read_text(encoding="utf-8")
    problems: list[str] = []

    # ① 括号平衡（pbxproj 只有花括号与圆括号）
    for open_ch, close_ch in (("{", "}"), ("(", ")")):
        if src.count(open_ch) != src.count(close_ch):
            problems.append(f"括号不平衡：{open_ch}{src.count(open_ch)} vs {close_ch}{src.count(close_ch)}")

    # ② 定义 vs 引用
    defined = set(DEF_RE.findall(src))
    referenced = set(ID_RE.findall(src))
    missing = sorted(referenced - defined)
    if missing:
        problems.append("被引用但没有定义的对象：" + ", ".join(missing))

    # ③ 没被任何地方引用的定义（多半是脚本漏挂）
    unused = sorted(defined - referenced)
    if unused:
        problems.append("定义了但没人引用（可能是漏挂）：" + ", ".join(unused))

    # ④ 每个 native target 的必填字段
    targets = re.findall(
        r"([A-Z][0-9A-F]{23}) /\* ([^*]+) \*/ = \{\s*\n\s*isa = PBXNativeTarget;(.*?)\n\t\t\};",
        src, flags=re.S)
    if not targets:
        problems.append("一个 PBXNativeTarget 都没找到")
    for tid, name, body in targets:
        for field in ("buildConfigurationList", "buildPhases", "productReference", "productType"):
            if field not in body:
                problems.append(f"target {name} 缺字段 {field}")
        for ref in re.findall(r"([A-Z][0-9A-F]{23})", body):
            if ref not in defined:
                problems.append(f"target {name} 的 {ref} 未定义")

    # ⑤ 每个 build phase 至少被一个 target 引用
    phases = set(re.findall(
        r"([A-Z][0-9A-F]{23}) /\* [^*]* \*/ = \{\s*\n\s*isa = PBX(?:Sources|Frameworks|Resources|CopyFiles)BuildPhase;", src))
    referenced_in_targets = set()
    for _, _, body in targets:
        referenced_in_targets.update(re.findall(r"([A-Z][0-9A-F]{23})", body))
    orphan = sorted(phases - referenced_in_targets)
    if orphan:
        problems.append("build phase 没挂到任何 target：" + ", ".join(orphan))

    if problems:
        print("❌ 检查未通过：")
        for p in problems:
            print("  -", p)
        return 1

    print(f"✅ pbxproj 检查通过：{len(defined)} 个对象，{len(targets)} 个 target")
    for tid, name, _ in targets:
        print(f"   · {name} ({tid})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

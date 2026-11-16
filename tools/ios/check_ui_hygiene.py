"""UI 卫生检查（P5 打磨的门禁）。

这台机器没有 Xcode / 模拟器，Dynamic Type 与无障碍只能靠"规则 + 人工装机"两头夹。
这里只抓两类**能静态判定、而且一定会出问题**的写法：

R1 硬编码字号只能用在图标上：`Text(...)` 用 `.font(.system(size:))` 不会跟随 Dynamic Type，
   最大档（AX5）时别人的字号都放大了，它还是死的。
R2 含文字的块不许用固定高度：`.frame(height: 60)` 这类会在 AX5 下把两行字截掉，必须用 `minHeight`。
   （图标按钮 44×44、渐变遮罩 64 这类没有文字的块不受影响。）

VoiceOver 的覆盖度没法静态判，靠 docs/ios/IOS-POLISH.md 里的逐页清单人工过。

用法（仓库根目录）：python tools/ios/check_ui_hygiene.py
退出码 0 = 通过。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

VIEW_DIRS = [Path("ios/JZMusicHelper/Views"), Path("ios/JZWidgets")]
TEXT_LINE_LIMIT = 8


def swift_files() -> list[Path]:
    out: list[Path] = []
    for d in VIEW_DIRS:
        if d.exists():
            out.extend(sorted(d.rglob("*.swift")))
    return out


def main() -> int:
    problems: list[str] = []

    for path in swift_files():
        lines = path.read_text(encoding="utf-8").splitlines()

        for i, line in enumerate(lines):
            # R1 硬编码字号只允许在图标上
            if ".font(.system(size:" in line:
                window = "\n".join(lines[max(0, i - 3): i + 1])
                if "Image(systemName:" not in window and "Image(uiImage:" not in window:
                    problems.append(
                        f"{path}:{i+1} 文本用了硬编码字号（不跟随 Dynamic Type）：{line.strip()}")

            # R2 含文字的块不许固定高度
            m = re.search(r"\.frame\(height:\s*([0-9]+)\)", line)
            if not m:
                continue
            height = int(m.group(1))
            if height < 30:
                continue
            window = "\n".join(lines[max(0, i - TEXT_LINE_LIMIT): i + 1])
            if "Text(" in window:
                problems.append(
                    f"{path}:{i+1} 含文字的块用了固定高度 {height}（AX5 会截断，改 minHeight）：{line.strip()}")

    if problems:
        print("❌ UI 卫生检查未通过：")
        for p in problems:
            print("  -", p)
        return 1

    print(f"✅ UI 卫生检查通过：{len(swift_files())} 个界面文件")
    return 0


if __name__ == "__main__":
    sys.exit(main())

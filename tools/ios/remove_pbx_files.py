"""从手写 pbxproj 里移除若干 Swift 文件（与 add_pbx_files.py 配对）。

用法：
    python tools/ios/remove_pbx_files.py MainTabView.swift PlayerManager.swift
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

PBX = Path("ios/JZMusicHelper.xcodeproj/project.pbxproj")


def main(argv: list[str]) -> int:
    names = [a for a in argv[1:] if a.endswith(".swift")]
    if not names:
        print(__doc__)
        return 2

    src = PBX.read_text(encoding="utf-8")
    removed = []
    for name in names:
        # 找到该文件的 fileRef（F...）与 buildFile（B...）
        f_matches = re.findall(rf"^\t\t(F[0-9A-F]{{23}}) /\* {re.escape(name)} \*/ = \{{isa = PBXFileReference",
                               src, flags=re.M)
        if not f_matches:
            print(f"⚠ {name}: pbxproj 里没有它的 FileReference（可能已删过）")
            continue
        f_id = f_matches[0]
        b_ids = re.findall(
            rf"^\t\t(B[0-9A-F]{{23}}) /\* {re.escape(name)} in Sources \*/ = \{{isa = PBXBuildFile; fileRef = {f_id}",
            src, flags=re.M)
        b_id = b_ids[0] if b_ids else None

        # 1) 删定义行
        src = re.sub(rf"^\t\t{f_id} /\* {re.escape(name)} \*/ = \{{isa = PBXFileReference[^\n]*\n", "",
                     src, flags=re.M)
        if b_id:
            src = re.sub(rf"^\t\t{b_id} /\* {re.escape(name)} in Sources \*/ = \{{isa = PBXBuildFile[^\n]*\n", "",
                         src, flags=re.M)
        # 2) 删分组 children 与 Sources phase 里的引用行
        src = re.sub(rf"^\t\t\t\t{f_id} /\* {re.escape(name)} \*/,\n", "", src, flags=re.M)
        if b_id:
            src = re.sub(rf"^\t\t\t\t{b_id} /\* {re.escape(name)} in Sources \*/,\n", "", src, flags=re.M)

        removed.append(name)

    # 自检：被删的名字不应再出现
    for name in removed:
        if name in src:
            print(f"❌ {name} 仍有残留引用")
            return 1

    PBX.write_text(src, encoding="utf-8")
    print("✓ 已移除：" + ", ".join(removed) if removed else "没有需要移除的")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

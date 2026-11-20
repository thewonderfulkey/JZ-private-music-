#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""出包闸：**包内主二进制必须与上一版不同**。

为什么要有这一步（2026-11-21 的真实事故）：
  v2.4.39 的 r146（`34fcf43`）与 r147（`5841733`）两个包发到群里，老板装完还是
  "播占位提示音、周杰伦没恢复"。查下来：这两个 IPA 里的 `Payload/.../JZMusicHelper`
  与 v2.4.38 的 r145 **sha256 完全一样**（`35b718132347121c…`）——因为那两个 commit
  一行 Swift 都没改，只改了 CHANGELOG 和 pbxproj 的版本号。
  现有的 `check_ipa_version.py` 只校验"包内版本号对不对"，所以一路绿灯。

这个脚本补的就是那一刀：拿新包的主二进制哈希，和 `releases/` 里所有历史包逐个比，
一旦相同就直接失败，报清楚"版本号变了但代码没进包"。

用法（CI 里紧跟"校验插件已嵌入"之后）：
    python3 tools/ios/check_ipa_identity.py --new out/JZ-Music-xxx.ipa --against 'releases/*.ipa'

退出码：0 = 通过（或没有可比的历史包）；1 = 二进制与历史包相同（修复没进包）。
"""
import argparse
import glob
import hashlib
import os
import sys
import zipfile

BINARY_SUFFIX = "/JZMusicHelper"


def binary_sha256(ipa_path):
    """取 IPA 里主可执行文件的 sha256；取不到返回 (None, None)。"""
    try:
        with zipfile.ZipFile(ipa_path) as z:
            names = [n for n in z.namelist()
                     if n.startswith("Payload/") and n.endswith(BINARY_SUFFIX)]
            if not names:
                return None, None
            data = z.read(names[0])
            return hashlib.sha256(data).hexdigest(), len(data)
    except (zipfile.BadZipFile, OSError) as e:
        print("  ! 读不了 %s：%s" % (os.path.basename(ipa_path), e))
        return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--new", required=True, help="本次构建出来的 IPA")
    ap.add_argument("--against", default="releases/*.ipa",
                    help="历史包 glob（默认 releases/*.ipa）")
    args = ap.parse_args()

    if not os.path.isfile(args.new):
        print("::error::找不到新包：%s" % args.new)
        return 1

    new_hash, new_size = binary_sha256(args.new)
    if not new_hash:
        print("::error::新包里没有 Payload/**/JZMusicHelper，无法做身份校验")
        return 1
    print("新包  %-52s %s  %s B" % (os.path.basename(args.new), new_hash[:16], new_size))

    old = [p for p in sorted(glob.glob(args.against))
           if os.path.abspath(p) != os.path.abspath(args.new)]
    if not old:
        print("没有可比的历史包（%s），跳过。" % args.against)
        return 0

    same = []
    for p in old:
        h, size = binary_sha256(p)
        if not h:
            continue
        mark = "  ← 与新包相同" if h == new_hash else ""
        print("历史  %-52s %s  %s B%s" % (os.path.basename(p), h[:16], size, mark))
        if h == new_hash:
            same.append(p)

    if same:
        print("\n::error::包内二进制与下列历史包完全相同 —— 版本号变了，但代码没进包：")
        for p in same:
            print("  - %s" % os.path.basename(p))
        print("常见原因：①改了 Swift 但没 commit；②commit 只带了 docs/版本号；"
              "③CI 拉到的 commit 不含这次修复。")
        print("处理：确认 git status 干净、`git show --stat <sha> -- ios/` 非空，再重出。")
        return 1

    print("\n✅ 包内二进制与所有历史包不同（这一版真的带了新代码）")
    return 0


if __name__ == "__main__":
    sys.exit(main())

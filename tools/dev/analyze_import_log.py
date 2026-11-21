#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""读 iPhone 发回来的「诊断.zip」里的 import.log，做导入失败归因汇总。

用法：
    python tools/dev/analyze_import_log.py <解压后的诊断目录> [--full]

输出每一轮导入的：起止时间、崩点（第一条失败的时刻与已跑秒数）、失败/不支持/复制失败条数、
两轮失败集合的重合关系、以及失败名单（--full 打全）。只读，不改任何东西。
"""
import collections
import os
import re
import sys

TS = re.compile(r"^(\d\d-\d\d \d\d:\d\d:\d\d) (.*)$")


def to_sec(ts: str) -> int:
    return int(ts[6:8]) * 3600 + int(ts[9:11]) * 60 + int(ts[12:14])


def load(path):
    runs, cur = [], None
    for ln in open(path, encoding="utf-8", errors="replace"):
        m = TS.match(ln.strip())
        if not m:
            continue
        ts, body = m.groups()
        if body.startswith("import: 开始"):
            cur = {"start": ts, "fail": [], "unsup": [], "copy": [], "end": None}
            runs.append(cur)
        elif body.startswith("import: 结束") and cur:
            cur["end"], cur["summary"] = ts, body.split("→ ")[-1]
            cur = None
        elif cur is not None:
            if body.startswith("import: 读不出元数据/时长 · "):
                cur["fail"].append((ts, body.split(" · ", 1)[1]))
            elif body.startswith("import: 不支持 · "):
                cur["unsup"].append((ts, body.split(" · ", 1)[1]))
            elif body.startswith("import: 复制失败 · "):
                cur["copy"].append((ts, body.split(" · ", 1)[1]))
    return runs


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    if os.path.isdir(path):
        path = os.path.join(path, "import.log")
    full = "--full" in sys.argv
    runs = [r for r in load(path) if r["fail"] or r["unsup"] or r["copy"]]

    big = []
    for i, r in enumerate(runs, 1):
        lost = len(r["fail"]) + len(r["copy"])
        print(f"\n轮 {i}: {r['start']} → {r['end']}  （{to_sec(r['end']) - to_sec(r['start'])} 秒）")
        print(f"  汇总: {r['summary']}")
        print(f"  读不出 {len(r['fail'])} · 复制失败 {len(r['copy'])} · 不支持 {len(r['unsup'])}")
        if r["fail"] or r["copy"]:
            first = min([t for t, _ in r["fail"] + r["copy"]])
            print(f"  崩点: 第 {to_sec(first) - to_sec(r['start'])} 秒（{first}）出现第一条失败")
            c = collections.Counter(t[:5] for t, _ in r["fail"] + r["copy"])
            print("  失败按分钟:", dict(sorted(c.items())))
        for t, n in r["copy"]:
            print(f"  [复制失败] {t} {n}")
        for t, n in r["unsup"]:
            print(f"  [不支持]   {t} {n}")
        if len(r["fail"]) > 30:
            big.append(r)

    if len(big) >= 2:
        a = [n for _, n in big[-2]["fail"]]
        b = [n for _, n in big[-1]["fail"]]
        sa, sb = set(a), set(b)
        print(f"\n最后两轮的失败集合: 前一轮 {len(sa)} 首 / 后一轮 {len(sb)} 首")
        print(f"  两轮都失败 {len(sa & sb)} · 只前一轮 {len(sa - sb)} · 只后一轮 {len(sb - sa)}")
        only_new = sorted(sb - sa)
        if only_new:
            print("  只后一轮失败的样本:", only_new[:10])

    if full and big:
        print("\n=== 最后一轮失败名单（全部）===")
        for _, n in big[-1]["fail"]:
            print("   ", n)
    return 0


if __name__ == "__main__":
    sys.exit(main())

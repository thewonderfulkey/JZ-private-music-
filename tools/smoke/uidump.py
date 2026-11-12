# -*- coding: utf-8 -*-
"""解析 uiautomator dump 的 XML：按文字找元素、判断文案是否存在、算点击中心。

用法：
  python uidump.py --file ui.xml --list                 # 列出所有有文字的节点
  python uidump.py --file ui.xml --has "听歌识曲"        # 存在则 exit 0，否则 1
  python uidump.py --file ui.xml --center "设置"         # 打印 "x,y"（最接近的匹配）
  python uidump.py --file ui.xml --any "首页,识曲,收藏"   # 任一存在则 exit 0
"""
import argparse
import re
import sys
import xml.etree.ElementTree as ET

BOUNDS = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")


def nodes(path):
    tree = ET.parse(path)
    out = []
    for n in tree.iter("node"):
        t = (n.get("text") or "").strip()
        d = (n.get("content-desc") or "").strip()
        label = t or d
        m = BOUNDS.match(n.get("bounds") or "")
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        out.append({"text": label, "x1": x1, "y1": y1, "x2": x2, "y2": y2,
                    "cx": (x1 + x2) // 2, "cy": (y1 + y2) // 2,
                    "clickable": n.get("clickable") == "true"})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--has", default="")
    ap.add_argument("--any", default="")
    ap.add_argument("--center", default="")
    args = ap.parse_args()

    ns = nodes(args.file)

    if args.list:
        for n in ns:
            if n["text"]:
                print(f'{n["text"]!r:40} center=({n["cx"]},{n["cy"]}) clickable={n["clickable"]}')
        return 0

    if args.has:
        ok = any(args.has in n["text"] for n in ns if n["text"])
        print("FOUND" if ok else "MISSING", args.has)
        return 0 if ok else 1

    if args.any:
        wanted = [w.strip() for w in args.any.split(",") if w.strip()]
        found = [w for w in wanted if any(w in n["text"] for n in ns if n["text"])]
        print("FOUND", ",".join(found) if found else "-", f"({len(found)}/{len(wanted)})")
        return 0 if len(found) == len(wanted) else 1

    if args.center:
        cands = [n for n in ns if n["text"] and args.center in n["text"]]
        if not cands:
            print("MISSING", args.center)
            return 1
        # 优先选可点击的、面积最小的（更接近目标控件本身）
        cands.sort(key=lambda n: (not n["clickable"], (n["x2"] - n["x1"]) * (n["y2"] - n["y1"])))
        print(f'{cands[0]["cx"]},{cands[0]["cy"]}')
        return 0

    print("no action", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

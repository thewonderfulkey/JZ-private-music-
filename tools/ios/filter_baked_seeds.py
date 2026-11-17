"""给生成的 BakedSeedSongs.swift 做一次"可信度过滤"：剔除专辑名带 live/演唱会/现场/伴奏/纯音乐 等
标记的条目（这些不是原版，时长会差几十秒）。剔除的键会回落到运行时搜索。

用法：python tools/ios/filter_baked_seeds.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "ios/JZMusicHelper/Models/BakedSeedSongs.swift"

BAD = ("live", "演唱会", "现场", "concert", "伴奏", "纯音乐", "ktv", "dj", "remix",
       "翻唱", "cover", "片段", "铃声", "演奏", "karaoke", "inst", "加速", "慢速", "钢琴")


def main() -> int:
    text = OUT.read_text(encoding="utf-8")
    lines = text.splitlines()
    kept, dropped = [], []
    for line in lines:
        m = re.match(r'\s*"([^"]+\|[^"]+)": Item\(.*?album: "([^"]*)".*', line)
        if m:
            key, album = m.group(1), m.group(2).lower()
            if any(b in album for b in BAD):
                dropped.append(f"{key}  ← album={m.group(2)}")
                continue
        kept.append(line)
    OUT.write_text("\n".join(kept) + "\n", encoding="utf-8")
    print(f"剔除 {len(dropped)} 条（非原版专辑）：")
    for d in dropped:
        print("  ", d)
    print("剩余条目:", sum(1 for line in kept if re.match(r'\s*"[^"]+\|[^"]+": Item\(', line)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""给生成的 BakedSeedSongs.swift 做一次"可信度过滤"。

两条硬规则（宁缺毋滥——写死的数据错一首，封面/专辑/时长全错）：
  1. **歌手必须对得上**：条目的 singer 里要能找到种子写的歌手（否则就是别人的翻唱/同名歌，
     例如"晴天|周杰伦"被配成"金布袋"、"隐形的翅膀|张韶涵"被配成"小刚"）；
  2. **专辑不能是 live/演唱会/伴奏/KTV/纯音乐/DJ** 这类非原版。

用法：python tools/ios/filter_baked_seeds.py

⚠️ 但注意：过滤只能事后补救，治本的是生成器里 `pick()` 必须强制歌手匹配（已同步修）。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "ios/JZMusicHelper/Models/BakedSeedSongs.swift"

BAD_ALBUM = ("live", "演唱会", "现场", "concert", "伴奏", "纯音乐", "ktv", "dj", "remix",
             "翻唱", "cover", "片段", "铃声", "演奏", "karaoke", "inst", "加速", "慢速", "钢琴",
             "车载", "酒吧")

# 预置池里最短的原版也在 2 分钟以上；低于这个就是片段/铃声
MIN_DURATION = 120


def norm(s: str) -> str:
    s = (s.replace("&nbsp;", " ").replace("&amp;", "&").replace("&apos;", "'")
          .replace("\\u0026", "&"))
    return re.sub(r"[\s\-_·、,，.。()（）\[\]【】《》'\"!?！？~&]", "", s).lower()


def name_tokens(s: str) -> list[str]:
    """把歌手串拆成"可比较的名字单位"。

    中文名字用 ≥2 个汉字的片段（"张碧晨 杨宗纬" → 张碧晨 / 杨宗纬），
    英文名用 ≥3 个字母的词（"Ed Sheeran" → ed / sheeran）。
    这样多歌手不会因为顺序不同被误杀，也不会让 "Celine Dion vs Richard Clayderman" 混过去。
    """
    s = (s.replace("&nbsp;", " ").replace("&amp;", "&").replace("&apos;", "'")
          .replace("\\u0026", "&").replace("\\\\", "\\"))
    cjk = re.findall(r"[\u4e00-\u9fff]{2,}", s)
    latin = [w for w in re.findall(r"[A-Za-z]{3,}", s)]
    return [norm(t) for t in cjk + latin]


def singer_ok(seed_singer: str, item_singer: str) -> bool:
    item_n = norm(item_singer)
    tokens = name_tokens(seed_singer)
    if not tokens:
        return norm(seed_singer) in item_n
    return all(t in item_n for t in tokens)


def main() -> int:
    text = OUT.read_text(encoding="utf-8")
    kept, dropped = [], []
    for line in text.splitlines():
        m = re.match(r'\s*"([^"]+)\|([^"]+)": Item\(.*?singer: "([^"]*)".*?album: "([^"]*)".*?duration: (\d+),.*', line)
        if m:
            seed_singer, item_singer, album, dur = m.group(2), m.group(3), m.group(4), int(m.group(5))
            if not singer_ok(seed_singer, item_singer):
                dropped.append(f"{m.group(1)}|{seed_singer}  ← 歌手对不上：{item_singer}")
                continue
            if any(b in album.lower() for b in BAD_ALBUM):
                dropped.append(f"{m.group(1)}|{seed_singer}  ← 非原版专辑：{album}")
                continue
            # 片段/铃声这类在 r.s 里会以很短时长出现（"十年"曾配到 60 秒的一条）
            if dur < MIN_DURATION:
                dropped.append(f"{m.group(1)}|{seed_singer}  ← 时长只有 {dur}s，像片段")
                continue
        kept.append(line)
    OUT.write_text("\n".join(kept) + "\n", encoding="utf-8")
    print(f"剔除 {len(dropped)} 条：")
    for d in dropped:
        print("  ", d)
    remaining = sum(1 for line in kept if re.match(r'\s*"[^"]+\|[^"]+": Item\(', line))
    print("剩余条目:", remaining)
    return 0


if __name__ == "__main__":
    sys.exit(main())

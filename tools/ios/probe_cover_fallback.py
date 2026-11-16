# -*- coding: utf-8 -*-
"""验证封面兜底规则：本平台没封面时，用「同歌名 + 同歌手」去 QQ 严格匹配复用其封面。

对应 Android `CoverResolver.kt` 的口径：
  只用 QQ 搜索（10 条）；要求 歌名完全相等（忽略大小写）**且** 歌手任一片段相等；命中才用，否则返回 null。
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools", "ios"))
os.environ.setdefault("no_proxy", "*")

from probe_network import search_kuwo, search_qq, http_range  # noqa: E402


def singer_parts(s: str) -> list[str]:
    return [p.strip() for p in s.split("/") if p.strip()]


def strict_match(target: dict, candidates: list[dict]) -> dict | None:
    """歌名完全相等 + 歌手任一片段相等（与 Android CoverResolver 一致）"""
    for c in candidates:
        if not c.get("pic"):
            continue
        if c["name"].strip().lower() != target["name"].strip().lower():
            continue
        if any(x.lower() in {y.lower() for y in singer_parts(target["singer"])}
               for x in singer_parts(c["singer"])):
            return c
    return None


def main() -> int:
    print("=== 封面兜底：酷我无封面的歌 → QQ 严格匹配 ===")
    ok = 0
    tested = 0
    for kw in ["起风了", "晴天", "夜曲", "孤勇者"]:
        try:
            kuwo = search_kuwo(kw, 10)
        except Exception as e:  # noqa: BLE001
            print(f"  {kw}: 酷我搜索失败 {e}")
            continue
        for song in kuwo[:3]:
            if song.get("pic"):
                continue          # 有封面就不走兜底
            tested += 1
            try:
                cands = search_qq(f"{song['name']} {song['singer']}".strip(), 10)
            except Exception as e:  # noqa: BLE001
                print(f"  {song['name']} / {song['singer']}: QQ 搜索失败 {e}")
                continue
            hit = strict_match(song, cands)
            if not hit:
                print(f"  {song['name']} / {song['singer']}: ✗ QQ 无严格匹配（{len(cands)} 条候选）")
                continue
            probe = http_range(hit["pic"])
            ok += 1
            print(f"  {song['name']} / {song['singer']}: ✓ {probe.get('status')} "
                  f"{probe.get('contentType')} ← {hit['pic'][:64]}")
    print(f"\n无封面样本 {tested} 条，兜底成功 {ok} 条")
    return 0


if __name__ == "__main__":
    sys.exit(main())

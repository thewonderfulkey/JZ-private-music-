"""从 Android 的 TraditionalMap.kt 生成 Swift 版繁→简映射。

为什么不手抄：这张表是 zhconv 词典导出的 4000+ 组逐字映射，手抄必然出错；
而它决定"歌词显示成简体还是繁体"，错了不会崩，只会整首歌词看着别扭。

用法：
    python tools/ios/gen_traditional_map.py
输出：
    ios/JZMusicHelper/Services/TraditionalMap.swift
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

SRC = Path("android/app/src/main/java/com/jz/musichelper/network/TraditionalMap.kt")
DST = Path("ios/JZMusicHelper/Services/TraditionalMap.swift")


def extract(name: str, text: str) -> str:
    m = re.search(rf'val {name}\s*=\s*"((?:[^"\\]|\\.)*)"', text, re.S)
    if not m:
        raise SystemExit(f"找不到 {name}")
    raw = m.group(1)
    # Kotlin 字符串里的转义（\\ \" 等）；这张表实际是纯汉字，只要还原 \" 与 \\
    return raw.replace('\\"', '"').replace("\\\\", "\\")


def main() -> int:
    if not SRC.exists():
        print(f"❌ 找不到 {SRC}")
        return 2
    text = SRC.read_text(encoding="utf-8")
    trad = extract("TRAD", text)
    simp = extract("SIMP", text)
    if len(trad) != len(simp):
        print(f"❌ 两张表长度不一致：{len(trad)} vs {len(simp)}")
        return 1

    def chunk(s: str, size: int = 40) -> str:
        # 按字符数切块，拼成多行字符串，避免一行几 KB
        parts = [s[i:i + size] for i in range(0, len(s), size)]
        return "\n".join(f'        "{p}" +' for p in parts).rstrip(" +")

    body = f'''import Foundation

// MARK: - 繁 → 简（歌词本地化）
//
// 与 Android `TradToSimpMap` 同源同表（zhconv 词典导出的逐字映射，{len(trad)} 组）。
// 本文件由 `tools/ios/gen_traditional_map.py` 从
// `android/app/src/main/java/com/jz/musichelper/network/TraditionalMap.kt` 生成——**不要手改**，
// 改 Android 那张表后重新生成即可。
//
// 为什么需要它：酷我 / 酷狗给的歌词常是繁体（粤语、台版发行），同一首歌在两端显示不一致很难看。
// 只做逐字映射，不做词组级转换（zhconv 的词组表没带过来），对歌词场景够用。
enum TradToSimpMap {{

    private static let trad = {chunk(trad)}

    private static let simp = {chunk(simp)}

    /// 懒加载的逐字映射表（只在第一次用到时建一次）
    private static let table: [Character: Character] = {{
        var map: [Character: Character] = [:]
        map.reserveCapacity(trad.count)
        for (a, b) in zip(trad, simp) where a != b {{
            map[a] = b
        }}
        return map
    }}()

    static var pairCount: Int {{ table.count }}

    /// 繁体转简体（逐字；表里没有的字原样保留）
    static func toSimplified(_ text: String) -> String {{
        guard !text.isEmpty else {{ return text }}
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {{
            if let mapped = table[ch] {{ out.append(mapped) }} else {{ out.append(ch) }}
        }}
        return out
    }}
}}
'''
    DST.parent.mkdir(parents=True, exist_ok=True)
    DST.write_text(body, encoding="utf-8")
    print(f"✓ 写入 {DST}（{len(trad)} 组，{len(body)} 字节）")
    return 0


if __name__ == "__main__":
    sys.exit(main())

# -*- coding: utf-8 -*-
"""重试抓一份**真实** QQ QRC 样本（该接口对本机 IP 限流，成功是间歇性的）。

成功后写 .build/lyrics-fixtures/qrc.real.hex 与 qrc.real.expect，供 gen_lyrics_fixtures.py 编进 Swift 断言。
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools", "ios"))
os.environ.setdefault("no_proxy", "*")

from probe_lyrics import qq_lyrics, qrc_decrypt, qrc_to_lines  # noqa: E402

OUT = Path(".build/lyrics-fixtures")
ATTEMPTS = [("稻香", "周杰伦"), ("晴天", "周杰伦"), ("夜曲", "周杰伦"), ("稻香", "周杰伦"),
            ("晴天", "周杰伦"), ("夜曲", "周杰伦"), ("稻香", "周杰伦"), ("晴天", "周杰伦")]


def main() -> int:
    for i, (title, artist) in enumerate(ATTEMPTS, 1):
        print(f"[{i}/{len(ATTEMPTS)}] QQ {title} / {artist} …", end=" ", flush=True)
        qq, err = qq_lyrics(title, artist)
        if err:
            print(f"✗ {err}")
            time.sleep(15)
            continue
        plain = qrc_decrypt(qq["hex"])
        lines = qrc_to_lines(plain)
        if not lines:
            print("✗ 解密出 0 行")
            time.sleep(15)
            continue
        print(f"✓ lines={len(lines)} words_first={len(lines[0]['words'])}")
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / "qrc.real.hex").write_text(qq["hex"], encoding="utf-8")
        (OUT / "qrc.real.expect").write_text(json.dumps(
            {"lines": len(lines), "first": lines[0]["text"],
             "words": len(lines[0]["words"]), "title": title},
            ensure_ascii=False), encoding="utf-8")
        print(f"已写入 {OUT}/qrc.real.hex（{len(qq['hex'])} 字符）")
        print(f"  首行：[{lines[0]['timeMs']}] {lines[0]['text'][:40]}")
        return 0
    print("8 次都没抢到（接口限流），稍后再试或换网络")
    return 1


if __name__ == "__main__":
    sys.exit(main())

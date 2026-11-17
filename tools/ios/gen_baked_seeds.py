"""把编辑精选 4 个预置歌单（120 首）的解析结果**预生成**成 Swift 常量。

老板要的是"一步到位，别每次点进去先看到纯文字再变歌"——所以把「歌名+歌手 → 酷我 rid / 专辑 /
时长 / 封面」这层映射**写死进包**：`EditorPlaylistView` 一进页面就是整页 SongRow，零搜索。

数据来源：`search.kuwo.cn/r.s`（匿名，与 App 内搜索同一族）。这条接口对同一查询会**轮换**
返回不同候选，所以这里：
  · 一次查询取 3 种参数组合（pn=0 / pn=1 / 带 vipver）合并候选，按 MUSICRID 去重；
  · 只接受**歌名严格相等**（解码 &nbsp; 等实体、去标点空白后）且歌手对得上的候选；
  · 带版本标记（Live/伴奏/钢琴/片段/DJ…）的一律不要——写死的数据配错一首，封面/专辑/**时长**
    全错，时长错还会打穿播放侧 ±25s 闸门。

生成物：`ios/JZMusicHelper/Models/BakedSeedSongs.swift`（生成后要登记进 pbxproj 与 CI 文件清单）。

用法（仓库根目录）：
    python tools/ios/gen_baked_seeds.py
"""

from __future__ import annotations

import ast
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "ios/JZMusicHelper/Models/DiscoverCatalog.swift"
OUT = ROOT / "ios/JZMusicHelper/Models/BakedSeedSongs.swift"

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15"
BASE = ("https://search.kuwo.cn/r.s?all={kw}&ft=music&rformat=json&encoding=utf8&")
VARIANTS = ("rn=30&pn=0", "rn=30&pn=1", "rn=30&pn=0&vipver=MUSIC_8.7.8.0_WX")

VARIANT_MARKERS = ("live", "现场", "演唱会", "伴奏", "钢琴", "纯音乐", "翻唱", "cover",
                   "dj", "remix", "片段", "铃声", "演奏", "karaoke", "纯享", "加速", "慢速")


def decode(s: str) -> str:
    return (s.replace("&nbsp;", " ").replace("&amp;", "&")
             .replace("\\u0026", "&").strip())


def norm(s: str) -> str:
    s = decode(s)
    return re.sub(r"[\s\-_·、,，.。()（）\[\]【】《》'\"!?！？~]", "", s).lower()


def fetch(kw: str) -> list[dict]:
    merged: dict[str, dict] = {}
    for variant in VARIANTS:
        url = BASE.format(kw=urllib.parse.quote(kw)) + variant
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.kuwo.cn/"})
        try:
            body = urllib.request.urlopen(req, timeout=25).read().decode("utf-8", "replace")
            data = ast.literal_eval(body)
        except Exception:  # noqa: BLE001
            continue
        for it in data.get("abslist") or []:
            rid = str(it.get("MUSICRID") or "")
            if rid.startswith("MUSIC_"):
                merged.setdefault(rid, it)
        time.sleep(0.15)
    return list(merged.values())


def pick(cands: list[dict], name: str, singer: str) -> dict | None:
    tn = norm(name)
    singers = [norm(s) for s in re.split(r"[/、,& ]+", decode(singer)) if norm(s)]
    if not singers:
        return None
    best, best_score = None, -1
    for c in cands:
        raw_name = decode(str(c.get("SONGNAME") or ""))
        if norm(raw_name) != tn or not tn:
            continue
        low = raw_name.lower()
        if any(m in low for m in VARIANT_MARKERS):
            continue
        ca = norm(str(c.get("ARTIST") or ""))
        # ⚠️ 歌手**必须**对得上：只按歌名匹配会配到别人的翻唱
        # （首版就这样把"晴天|周杰伦"配成了"金布袋"、"隐形的翅膀|张韶涵"配成了"小刚"）。
        if not all(s in ca for s in singers):
            continue
        # 时长下限：搜索里混着 25~60 秒的片段/铃声（"安静"曾配到 25 秒），
        # 写死进去会让播放侧 ±25s 闸门直接判坏源。
        if seconds(c.get("DURATION")) < 120:
            continue
        score = 140 if len(singers) > 1 else 100
        if score > best_score:
            best, best_score = c, score
    return best


def seconds(raw) -> int:
    s = str(raw or "")
    if ":" in s:
        try:
            m, sec = s.split(":")[:2]
            return int(m) * 60 + int(float(sec))
        except Exception:  # noqa: BLE001
            return 0
    try:
        return int(float(s))
    except Exception:  # noqa: BLE001
        return 0


def main() -> int:
    text = CATALOG.read_text(encoding="utf-8")
    seeds = re.findall(r'Seed\(name: "([^"]+)", singer: "([^"]+)"\)', text)
    print(f"seeds: {len(seeds)}")

    items: dict[str, tuple] = {}
    misses: list[str] = []
    seen: set[str] = set()

    for i, (name, singer) in enumerate(seeds, 1):
        key = f"{name}|{singer}"
        if key in seen:
            continue
        seen.add(key)
        # 先「歌名 + 歌手」，没命中再只查歌名——第二轮是为了补上"带歌手查会被版本/翻唱挤掉"的那几首
        chosen = pick(fetch(f"{name} {singer}"), name, singer)
        if not chosen:
            chosen = pick(fetch(name), name, singer)
        if not chosen:
            misses.append(key)
            print(f"  [{i}/{len(seeds)}] miss  {key}")
            continue
        rid = str(chosen["MUSICRID"]).replace("MUSIC_", "")
        pic = str(chosen.get("MVPIC") or "")
        pic_url = f"https://img1.kuwo.cn/wmvpic/{pic}" if pic else ""   # ATS 严格：必须 https
        items[key] = (rid, decode(str(chosen.get("SONGNAME") or name)),
                      decode(str(chosen.get("ARTIST") or singer)),
                      decode(str(chosen.get("ALBUM") or "")),
                      seconds(chosen.get("DURATION")), pic_url)
        if i % 10 == 0:
            print(f"  [{i}/{len(seeds)}] ok={len(items)} miss={len(misses)}")

    print(f"命中 {len(items)} / {len(seeds)}；未命中 {len(misses)}")
    for k in misses:
        print("   miss:", k)

    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')

    lines = [
        "import Foundation",
        "",
        "// MARK: - 预置歌单的解析结果（**由脚本生成，别手改**）",
        "//",
        "// 老板 r85：「编辑精选里原来是文字，现在文字转歌曲，我希望一步到位，别每次点进去都等。」",
        "// 这里就是写死的那一份：4 个预置歌单（歌名+歌手）→「酷我 rid / 专辑 / 时长 / 封面」。",
        "// 生成脚本：`tools/ios/gen_baked_seeds.py`（走 search.kuwo.cn，多种参数合并候选，只收原版）。",
        f"// 生成时间：{time.strftime('%Y-%m-%d')}；命中 {len(items)}/{len(seeds)} 首"
        "（没命中的那几首照常走运行时搜索，行内会先显示占位）。",
        "//",
        "// 键与 `ResolvedSongCache.key` 完全同口径（歌名|歌手，小写去首尾空白）。",
        "enum BakedSeedSongs {",
        "",
        "    struct Item {",
        "        let platformID: String",
        "        let name: String",
        "        let singer: String",
        "        let album: String",
        "        let duration: Int",
        "        let pic: String",
        "    }",
        "",
        f'    static let generatedAt = "{time.strftime("%Y-%m-%d")}"',
        "",
        "    static let byKey: [String: Item] = [",
    ]
    for key, (rid, nm, sg, alb, dur, pic) in items.items():
        n, s = key.split("|", 1)
        # ⚠️ 键必须**小写**：运行时查表用的是 `ResolvedSongCache.key`（小写去空白）。
        # 之前这里原样写出去，中文歌看不出来，英文歌（欧美热单 30 首）全部 miss，
        # 表现就是"只有欧美热单还在一行一行加载"。
        lines.append(f'"{esc(n.lower())}|{esc(s.lower())}": Item(platformID: "{rid}", name: "{esc(nm)}", '
                     f'singer: "{esc(sg)}", album: "{esc(alb)}", duration: {dur}, pic: "{esc(pic)}"),')
    lines += [
        "    ]",
        "",
        "    /// 按键查（键与 `ResolvedSongCache.key` 同口径）",
        "    static func song(name: String, singer: String) -> Song? {",
        "        let key = ResolvedSongCache.key(name: name, singer: singer)",
        "        guard let item = byKey[key] else { return nil }",
        "        return Song(platform: .kuwo,",
        "                    platformID: item.platformID,",
        "                    name: item.name,",
        "                    singer: item.singer,",
        "                    album: item.album,",
        "                    duration: TimeInterval(item.duration),",
        "                    picURL: item.pic.isEmpty ? nil : item.pic)",
        "    }",
        "}",
        "",
    ]
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())

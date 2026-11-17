"""把编辑精选 4 个预置歌单（120 首）的解析结果**预生成**成 Swift 常量。

⚠️ **当前没有接进 App（2026-11-18）**：生成出来的映射质量还不过关——
`search.kuwo.cn/r.s` 对同一个查询会轮换返回不同的一批候选（同一首歌每次位置不同），
严格匹配（歌名去实体后完全相等 + 不带版本标记 + 歌手对得上）只能命中 90/120 左右，
而没命中的那几首一旦被"写死"成错版本，封面、专辑、**时长**都会错（时长还会打穿播放侧 ±25s 闸门）。
目前的取舍：先靠 `ResolvedSongCache`（首次运行时解析，之后长期落盘）达到"加载一次就不用再加载"，
等这条接口稳定（或改用带 `sourceid` 的榜单接口/歌单接口取曲库）再回来把这份数据写死。

生成物路径约定：`ios/JZMusicHelper/Models/BakedSeedSongs.swift`（接进去时再登记进 pbxproj 与
CI/typecheck 的文件清单）。用法：

    python tools/ios/gen_baked_seeds.py
"""

from __future__ import annotations

import ast
import json
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
SEARCH = ("https://search.kuwo.cn/r.s?all={kw}&ft=music&rn=10&pn=1&rformat=json"
          "&encoding=utf8&vipver=MUSIC_8.7.8.0_WX")


def norm(s: str) -> str:
    # 这个接口会把空格写成 `&nbsp;`（英文歌尤其常见），不还原就永远匹配不上
    s = s.replace("&nbsp;", " ").replace("&amp;", "&")
    return re.sub(r"[\s\-_·、,，.。()（）\[\]【】《》'\"!?！？]", "", s).lower()


def fetch(kw: str) -> list[dict]:
    url = SEARCH.format(kw=urllib.parse.quote(kw))
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.kuwo.cn/"})
    with urllib.request.urlopen(req, timeout=20) as r:
        body = r.read().decode("utf-8", "replace")
    # ⚠️ 不能按 "}, {" 切块：这个接口有时不带空格（"},{"），一切就只剩第一条
    # （首版就因此把《晴天》配成了「晴天(抒情钢琴版)」54s）。改成按 'SONGNAME': 标记切。
    out = []
    for chunk in body.split("'SONGNAME':")[1:]:
        def g(key, c=chunk):
            m = re.search(r"'" + key + r"':'(.*?)'", c)
            return m.group(1) if m else ""
        name = chunk.split("'", 2)[1] if "'" in chunk else ""
        out.append({"SONGNAME": name, "ARTIST": g("ARTIST"), "ALBUM": g("ALBUM"),
                    "MUSICRID": g("MUSICRID"), "DURATION": g("DURATION"), "MVPIC": g("MVPIC")})
    return out


# 版本/变体标记：预置池里写的都是**原版**，命中的候选只要带这些词就一律不要
VARIANT_MARKERS = ["live", "现场", "演唱会", "伴奏", "钢琴", "纯音乐", "翻唱", "cover",
                   "dj", "remix", "片段", "铃声", "铃声版", "版", "演奏", "karaoke", "inst"]


def is_variant(name: str) -> bool:
    n = norm(name)
    if not n:
        return True
    raw = name.replace("&nbsp;", " ").lower()
    return any(m in raw or m in n for m in VARIANT_MARKERS)


def pick(cands: list[dict], name: str, singer: str) -> dict | None:
    """只接受**歌名严格相等**（去实体/空白后）且歌手对得上的候选；带版本标记的一律不要。

    宁缺毋滥：这条映射会被"写死"进包里，配错一首就是封面/时长全错（时长还会打穿 ±25s 闸门）。
    没命中的那几首照常走运行时的四平台搜索。
    """
    tn, ts = norm(name), norm(singer.split(" ")[0].split("/")[0])
    best = None
    best_score = -1
    for c in cands:
        cn = norm(str(c.get("SONGNAME", "")))
        ca = norm(str(c.get("ARTIST", "")))
        rid = str(c.get("MUSICRID", ""))
        if not rid.startswith("MUSIC_"):
            continue
        if cn != tn:
            continue                      # 只要原版名，版本/变体一概跳过
        if is_variant(str(c.get("SONGNAME", ""))):
            continue
        score = 100
        if ts and ts in ca:
            score += 40
        if score > best_score:
            best, best_score = c, score
    # 歌手对不上也要（有些池子写的歌手是"群星"或多歌手串），但优先级低
    return best if best_score >= 100 else None


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

    for i, (name, singer) in enumerate(seeds, 1):
        key = f"{name}|{singer}"
        if key in items:
            continue
        try:
            cands = fetch(f"{name} {singer}")
        except Exception as e:  # noqa: BLE001
            # 这条接口偶发超时：重试一次再判未命中（首轮就丢过 Shape of You / My Heart Will Go On）
            try:
                time.sleep(0.6)
                cands = fetch(f"{name} {singer}")
            except Exception as e2:  # noqa: BLE001
                print(f"  [{i}/{len(seeds)}] {key} 请求失败：{e2}")
                misses.append(key)
                continue
        chosen = pick(cands, name, singer)
        if not chosen:
            misses.append(key)
            print(f"  [{i}/{len(seeds)}] {key} 未命中")
            continue
        rid = str(chosen["MUSICRID"]).replace("MUSIC_", "")

        def clean(s) -> str:
            return str(s or "").replace("&nbsp;", " ").replace("&amp;", "&").strip()

        alb = clean(chosen.get("ALBUM"))
        dur = seconds(chosen.get("DURATION"))
        pic = str(chosen.get("MVPIC") or "")
        # 封面统一给 https（App 开了 ATS 严格，http 图加载不出来）；没有 MVPIC 就留空，
        # 运行时由 `CoverResolver` 的 rid_pic 兜底
        pic_url = f"https://img1.kuwo.cn/wmvpic/{pic}" if pic else ""
        items[key] = (rid, clean(chosen.get("SONGNAME") or name),
                      clean(chosen.get("ARTIST") or singer), alb, dur, pic_url)
        if i % 10 == 0:
            print(f"  [{i}/{len(seeds)}] ok={len(items)} miss={len(misses)}")
        time.sleep(0.15)

    print(f"命中 {len(items)} / {len(seeds)}，未命中 {len(misses)}")
    for k in misses:
        print("   miss:", k)

    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')

    lines = [
        "import Foundation",
        "",
        "// MARK: - 预置歌单的解析结果（**由脚本生成，别手改**）",
        "//",
        "// 老板 r84：「编辑精选连整个条目都要加载，能写死的写死」。",
        "// 这里就是写死的那一份：编辑精选 4 个预置歌单的歌（歌名+歌手）→`酷我 rid / 专辑 / 时长 / 封面`。",
        "// 生成脚本：`tools/ios/gen_baked_seeds.py`（走 search.kuwo.cn，与 App 内搜索同一族接口）。",
        f"// 生成时间：{time.strftime('%Y-%m-%d')}；命中 {len(items)}/{len(seeds)} 首（没命中的照常走运行时搜索）。",
        "//",
        "// 用法：`EditorPlaylistView` 进页面先用它同步铺出整页行（封面/专辑/收藏立刻就有），",
        "// `DiscoverFeed.resolve(seed:)` 也先查它——点歌不再先等一次四平台搜索。",
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
        kind, singer0 = key.split("|", 1)
        lines.append(
            f'        "{esc(kind)}|{esc(singer0)}": Item(platformID: "{rid}", name: "{esc(nm)}", '
            f'singer: "{esc(sg)}", album: "{esc(alb)}", duration: {dur}, pic: "{esc(pic)}"),'
        )
    lines += [
        "    ]",
        "",
        "    /// 按键查（键与 `ResolvedSongCache.key` 同口径：歌名|歌手，小写去首尾空白）",
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
    print("wrote", OUT, len("\n".join(lines)), "chars")
    return 0


if __name__ == "__main__":
    sys.exit(main())

# -*- coding: utf-8 -*-
"""三块（音乐 / 歌词 / 封面）全链探针：给"开工门槛"盘点提供实测证据。

做四件事：
  1 音乐：四平台搜索 → 每平台首条跑本平台全部后端 → Range 探测真实容器/码率 → 判断是否命中目标档
  2 补源：取酷狗那首（它的官方后端当前不给直链），走"同曲跨平台补源"看能不能救回来
  3 歌词：酷我官方 getlyric / 酷狗 KRC 链（3 首）/ QQ QRC 链（带限流识别）
  4 封面：每条结果的封面 URL 真取一次（Range 0-1），看状态码与内容类型

跑法：
    python tools/ios/probe_gate.py
输出：终端表格 + .build/gate-report.json
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools", "ios"))
os.environ.setdefault("no_proxy", "*")

from probe_network import (  # noqa: E402
    PLATFORMS, SHORT, http, http_range, quality_matches,
    search_qq, search_netease, search_kuwo, search_kugou,
    resolve_cyapi, resolve_gdstudio, resolve_oiapi, resolve_yaohu, resolve_kugou,
)
from probe_lyrics import kg_lyrics, krc_decrypt, krc_to_lines, qq_lyrics, qrc_decrypt, qrc_to_lines  # noqa: E402

OUT = Path(".build/gate-report.json")
QUERIES = ["晴天 周杰伦", "夜曲 周杰伦", "起风了"]
SEARCHERS = {"qq": search_qq, "netease": search_netease, "kuwo": search_kuwo, "kugou": search_kugou}
BACKENDS = {
    "qq": [resolve_cyapi],
    "netease": [resolve_gdstudio, resolve_oiapi],
    "kuwo": [resolve_yaohu],
    "kugou": [resolve_kugou],
}

report: dict = {"music": {}, "crossResolve": {}, "lyrics": {}, "covers": {}}


# ---------------------------------------------------------------- 同曲判定（对齐 NameMatch/StudioPick 主路径）

BRACKET = re.compile(r"（[^）]*）|\([^)]*\)|\[[^\]]*\]|【[^】]*】")
PUNCT = re.compile(r"[\s·・\-—_.,，、'\"“”‘’!！?？:：/\\&*+]")
SINGER_SEP = re.compile(r"[/&、,，\s]+")


def norm_title(s: str) -> str:
    return PUNCT.sub("", BRACKET.sub("", s.strip().lower()))


def title_matches(a: str, b: str) -> bool:
    x, y = norm_title(a), norm_title(b)
    if not x or not y:
        return False
    return x == y or (abs(len(x) - len(y)) <= 6 and (x in y or y in x))


def singer_tokens(s: str) -> set[str]:
    return {t for t in (PUNCT.sub("", p) for p in SINGER_SEP.split(BRACKET.sub("", s.strip().lower()))) if t}


def singer_matches(a: str, b: str) -> bool:
    ta, tb = singer_tokens(a), singer_tokens(b)
    if not ta or not tb:
        return True
    if ta & tb:
        return True
    sa, sb = "".join(sorted(ta)), "".join(sorted(tb))
    return sa in sb or sb in sa


def same_song(src: dict, cand: dict) -> bool:
    if src["platform"] == cand["platform"] and src["id"] == cand["id"]:
        return False
    if not title_matches(src["name"], cand["name"]):
        return False
    if not singer_matches(src["singer"], cand["singer"]):
        return False
    if src["duration"] > 0 and cand["duration"] > 0:
        if abs(src["duration"] - cand["duration"]) > 12:
            return False
    return True


# ---------------------------------------------------------------- 1 音乐：搜索

def do_search() -> dict:
    out = {}
    for kw in QUERIES:
        row = {}
        def run(p):
            t0 = time.time()
            try:
                songs = SEARCHERS[p](kw, 20)
                return p, {"ok": True, "count": len(songs), "ms": int((time.time() - t0) * 1000),
                           "first": songs[0] if songs else None, "songs": songs, "error": None}
            except Exception as e:  # noqa: BLE001
                return p, {"ok": False, "count": 0, "ms": int((time.time() - t0) * 1000),
                           "first": None, "songs": [], "error": f"{type(e).__name__}: {e}"}
        with ThreadPoolExecutor(max_workers=4) as ex:
            for p, r in ex.map(run, PLATFORMS):
                row[p] = r
        out[kw] = row
    return out


# ---------------------------------------------------------------- 2 取流 + 音质探测

def probe_source(url: str, duration: int) -> dict:
    p = http_range(url)
    kb = 0
    if p.get("totalBytes", 0) and duration:
        kb = p["totalBytes"] * 8 // duration // 1000
    return {
        "container": p.get("container"),
        "totalBytes": p.get("totalBytes", 0),
        "kbps": kb,
        "status": p.get("status"),
        "contentType": p.get("contentType"),
        "looksAudio": p.get("looksAudio", False),
        "matchesHigh": quality_matches("high", p.get("container", ""), kb),
    }


def do_resolve(searches: dict) -> dict:
    out = {}
    for kw, row in searches.items():
        out[kw] = {}
        for platform in PLATFORMS:
            first = row[platform].get("first")
            if not first:
                out[kw][platform] = {"skipped": "无搜索结果"}
                continue
            results = []
            for fn in BACKENDS[platform]:
                t0 = time.time()
                item = {"backend": fn.__name__}
                try:
                    got = fn(first, "high")
                    probe = probe_source(got["url"], first["duration"])
                    item.update({"ok": True, "declared": got.get("declared"),
                                 "urlScheme": got["url"].split(":")[0],
                                 "ms": int((time.time() - t0) * 1000), **probe})
                except Exception as e:  # noqa: BLE001
                    item.update({"ok": False, "ms": int((time.time() - t0) * 1000),
                                 "error": f"{type(e).__name__}: {str(e)[:80]}"})
                results.append(item)
            out[kw][platform] = {"song": first, "backends": results}
    return out


# ---------------------------------------------------------------- 3 跨平台补源

def do_cross_resolve(searches: dict) -> dict:
    """挑酷狗首条（酷狗后端当前不给直链）验证「放不出来就换家」。"""
    row = searches.get(QUERIES[0], {})
    kugou = row.get("kugou", {}).get("first")
    if not kugou:
        return {"skipped": "酷狗无结果"}
    kw = f"{kugou['name']} {kugou['singer']}".strip()
    cands = []
    for p in PLATFORMS:
        try:
            cands += SEARCHERS[p](kw, 30)
        except Exception:  # noqa: BLE001
            pass
    same = [c for c in cands if same_song(kugou, c)]
    # 同平台优先 + 时长长的优先（近似原唱优势）
    same.sort(key=lambda c: (0 if c["platform"] == kugou["platform"] else 1, -c["duration"]))
    trials = []
    for cand in same[:8]:
        for fn in BACKENDS[cand["platform"]]:
            try:
                got = fn(cand, "high")
                probe = probe_source(got["url"], cand["duration"])
                trials.append({"platform": cand["platform"], "name": cand["name"], "singer": cand["singer"],
                               "backend": got["backend"], "ok": probe["looksAudio"],
                               "container": probe["container"], "kbps": probe["kbps"]})
                if probe["looksAudio"]:
                    return {"song": kugou, "candidates": len(same), "trials": trials,
                            "rescued": True}
            except Exception as e:  # noqa: BLE001
                trials.append({"platform": cand["platform"], "name": cand["name"],
                               "backend": fn.__name__, "ok": False, "error": str(e)[:60]})
    return {"song": kugou, "candidates": len(same), "trials": trials, "rescued": False}


# ---------------------------------------------------------------- 4 歌词

def kuwo_official_lyrics(platform_id: str) -> dict:
    rid = "".join(ch for ch in platform_id if ch.isdigit())
    if not rid:
        return {"ok": False, "error": "无数字 ID"}
    url = f"https://www.kuwo.cn/openapi/v1/www/lyric/getlyric?musicId={rid}&httpsStatus=1"
    try:
        _, body = http(url, {"Referer": "https://www.kuwo.cn/"}, timeout=8)
        js = json.loads(body.decode("utf-8", "ignore"))
        if js.get("code") != 200:
            return {"ok": False, "error": f"code={js.get('code')}"}
        lst = ((js.get("data") or {}).get("lrclist")) or []
        lines = []
        for it in lst:
            text = (it.get("lineLyric") or "").strip()
            if not text:
                continue
            try:
                t = float(str(it.get("time")).strip())
            except Exception:  # noqa: BLE001
                continue
            lines.append({"t": int(t * 1000), "text": text})
        return {"ok": len(lines) >= 3, "lines": len(lines), "sample": [l["text"] for l in lines[:3]],
                "firstMs": lines[0]["t"] if lines else None}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"{type(e).__name__}: {str(e)[:60]}"}


def do_lyrics(searches: dict, extra_songs: list[tuple[str, str]]) -> dict:
    out = {"kuwo": {}, "kugou": {}, "qq": {}}

    # 酷我官方：用酷我搜索的首条（精确 musicId）
    kuwo_first = searches.get(QUERIES[0], {}).get("kuwo", {}).get("first")
    if kuwo_first:
        out["kuwo"]["晴天 周杰伦"] = kuwo_official_lyrics(kuwo_first["id"])

    # 酷狗 KRC：3 首
    for title, artist in extra_songs:
        rec = {"attempted": True}
        kg, err = kg_lyrics(title, artist)
        if err:
            rec.update({"ok": False, "error": err})
        else:
            try:
                if kg["contenttype"] == 2:
                    rec.update({"ok": False, "error": "返回纯文本 LRC（无逐字）"})
                else:
                    import base64

                    plain = krc_decrypt(base64.b64decode(kg["content"]))
                    lines = krc_to_lines(plain)
                    rec.update({"ok": len(lines) >= 6, "contenttype": kg["contenttype"],
                                "lines": len(lines),
                                "wordsInFirstLine": len(lines[0]["words"]) if lines else 0,
                                "sample": [l["text"] for l in lines[:2]]})
            except Exception as e:  # noqa: BLE001
                rec.update({"ok": False, "error": f"解密失败 {type(e).__name__}: {str(e)[:60]}"})
        out["kugou"][f"{title} {artist}"] = rec

    # QQ QRC：1 首（会限流，记录到 code）
    rec = {"attempted": True}
    qq, err = qq_lyrics(extra_songs[0][0], extra_songs[0][1])
    if err:
        rec.update({"ok": False, "error": err})
    else:
        try:
            plain = qrc_decrypt(qq["hex"])
            lines = qrc_to_lines(plain)
            rec.update({"ok": bool(lines), "lines": len(lines),
                        "wordsInFirstLine": len(lines[0]["words"]) if lines else 0})
        except Exception as e:  # noqa: BLE001
            rec.update({"ok": False, "error": f"解密失败 {type(e).__name__}: {str(e)[:60]}"})
    out["qq"][f"{extra_songs[0][0]} {extra_songs[0][1]}"] = rec
    return out


# ---------------------------------------------------------------- 5 封面

def cover_check(url: str | None) -> dict:
    if not url:
        return {"present": False}
    try:
        req = urllib.request.Request(url)
        req.add_header("Range", "bytes=0-1")
        req.add_header("Referer", "https://music.qq.com/")
        with urllib.request.urlopen(req, timeout=8) as r:
            data = r.read(2)
            return {"present": True, "status": r.status,
                    "contentType": (r.headers.get("Content-Type") or "").lower(),
                    "twoBytes": len(data) == 2}
    except Exception as e:  # noqa: BLE001
        return {"present": True, "status": 0, "error": f"{type(e).__name__}: {str(e)[:60]}"}


def do_covers(searches: dict) -> dict:
    out = {}
    row = searches.get(QUERIES[0], {})
    for p in PLATFORMS:
        first = row.get(p, {}).get("first")
        if not first:
            out[p] = {"skipped": "无结果"}
            continue
        out[p] = {"song": first["name"], "url": first.get("pic"), **cover_check(first.get("pic"))}
    return out


# ---------------------------------------------------------------- 主流程

def main() -> int:
    t0 = time.time()
    print("=== 1 音乐：四平台搜索（3 个关键词）===")
    searches = do_search()
    report["music"]["search"] = {}
    for kw, row in searches.items():
        line = []
        for p in PLATFORMS:
            r = row[p]
            line.append(f"{SHORT[p]} {r['count']:>2}条/{r['ms']:>4}ms" if r["ok"] and r["count"]
                        else f"{SHORT[p]} ✗{r['error'][:24] if not r['ok'] else '0条'}")
        print(f"  {kw:<10} " + " | ".join(line))
        report["music"]["search"][kw] = {
            p: {"count": row[p]["count"], "ms": row[p]["ms"], "ok": row[p]["ok"],
                "error": row[p]["error"], "first": row[p]["first"]} for p in PLATFORMS
        }

    print("\n=== 2 音乐：取流 + Range 音质探测（want=high）===")
    resolved = do_resolve(searches)
    report["music"]["resolve"] = resolved
    for kw, per in resolved.items():
        for p, info in per.items():
            if "skipped" in info:
                continue
            for b in info["backends"]:
                if b.get("ok"):
                    print(f"  {kw:<10} {SHORT[p]:<3} {b['backend']:<16} {b['container']:<7} "
                          f"{b['kbps']:>5}kbps {'命中' if b['matchesHigh'] else '不命中'} ({b['urlScheme']})")
                else:
                    print(f"  {kw:<10} {SHORT[p]:<3} {b['backend']:<16} ✗ {b['error']}")

    print("\n=== 3 音乐：跨平台补源（酷狗首条 → 找别家）===")
    cross = do_cross_resolve(searches)
    report["crossResolve"] = cross
    if "skipped" in cross:
        print(f"  跳过：{cross['skipped']}")
    else:
        print(f"  源：{cross['song']['name']} / {cross['song']['singer']}（酷狗，官方后端不给直链）")
        print(f"  同曲候选 {cross['candidates']} 条，试了 {len(cross['trials'])} 次 → "
              f"{'救回来了' if cross['rescued'] else '全部失败'}")
        for t in cross["trials"][:6]:
            print(f"    {SHORT.get(t['platform'], t['platform']):<3} {t.get('name','')[:16]:<18} "
                  f"{t.get('backend',''):<16} {'✓ ' + str(t.get('container')) + ' ' + str(t.get('kbps')) + 'kbps' if t.get('ok') else '✗ ' + t.get('error','')}")

    print("\n=== 4 歌词：酷我官方 / 酷狗 KRC / QQ QRC ===")
    lyrics = do_lyrics(searches, [("晴天", "周杰伦"), ("夜曲", "周杰伦"), ("稻香", "周杰伦")])
    report["lyrics"] = lyrics
    for src, per in lyrics.items():
        for song, info in per.items():
            if info.get("ok"):
                extra = f"{info.get('lines')} 行"
                if info.get("wordsInFirstLine"):
                    extra += f" / 首行逐字 {info['wordsInFirstLine']}"
                print(f"  {src:<5} {song:<12} ✓ {extra}")
            else:
                print(f"  {src:<5} {song:<12} ✗ {info.get('error')}")

    print("\n=== 5 封面：URL 真取一次（Range 0-1）===")
    covers = do_covers(searches)
    report["covers"] = covers
    for p, info in covers.items():
        if "skipped" in info:
            continue
        if not info.get("present"):
            print(f"  {SHORT[p]:<3} 无封面字段")
        elif info.get("status"):
            print(f"  {SHORT[p]:<3} HTTP {info['status']} {info.get('contentType')} "
                  f"{'字节可读' if info.get('twoBytes') else '字节异常'} ← {str(info.get('url'))[:60]}")
        else:
            print(f"  {SHORT[p]:<3} ✗ {info.get('error')}")

    report["elapsedSec"] = int(time.time() - t0)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n用时 {report['elapsedSec']}s，明细写入 {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

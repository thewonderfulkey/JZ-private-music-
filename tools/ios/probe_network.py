#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
iOS 网络层协议探针（与 Android v2.1.95 同一套接口口径）

用途：把 Android 侧 search / resolve 用到的**全部 HTTP 接口**按原样跑一遍，
      输出「能不能通 / 返回几条 / 真实容器 / 真实码率」，作为 iOS Swift 移植的对照基线。

为什么需要它：这台机器没有 Swift 工具链，Swift 的编译交给 GitHub Actions 的 macos runner；
但"接口还能不能用、返回结构变没变"必须在本地先证一遍——否则移植完也只是一堆没验证过的 URL。

跑法：
    python tools/ios/probe_network.py                 # 默认查「晴天 周杰伦」
    python tools/ios/probe_network.py "夜曲 周杰伦"
    python tools/ios/probe_network.py "晴天 周杰伦" --json

退出码：0 = 至少一个搜索平台通 + 至少一个后端给出可用音频；2 = 不满足。
"""
from __future__ import annotations

import json
import os
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# 绕过系统代理：GitHub 的 webhook/接口走直连
os.environ.setdefault("no_proxy", "*")
os.environ.setdefault("NO_PROXY", "*")

MOBILE_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
)
ACCEPT = "application/json, text/javascript, */*; q=0.01"
PLATFORMS = ["kuwo", "qq", "netease", "kugou"]
SHORT = {"kuwo": "酷我", "qq": "QQ", "netease": "网易", "kugou": "酷狗"}


def http(url: str, headers: dict | None = None, timeout: float = 12.0) -> tuple[int, bytes]:
    req = urllib.request.Request(url)
    req.add_header("User-Agent", MOBILE_UA)
    req.add_header("Accept", ACCEPT)
    req.add_header("Referer", "https://music.qq.com/")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        return resp.status, resp.read()


def http_range(url: str, timeout: float = 8.0) -> dict:
    """Range 探测：真实容器 + 总字节（与 Android StreamVerifier 同口径）。"""
    req = urllib.request.Request(url)
    req.add_header("Range", "bytes=0-4095")
    req.add_header("User-Agent", MOBILE_UA)
    req.add_header("Referer", "https://music.qq.com/")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            ct = (resp.headers.get("Content-Type") or "").lower()
            cr = resp.headers.get("Content-Range") or ""
            total = 0
            if "/" in cr:
                tail = cr.rsplit("/", 1)[1]
                total = int(tail) if tail.isdigit() else 0
            if total == 0:
                cl = resp.headers.get("Content-Length")
                total = int(cl) if (cl or "").isdigit() else 0
            head = resp.read(16)
            return {
                "status": resp.status,
                "contentType": ct,
                "totalBytes": total,
                "container": sniff_head(head),
                "looksAudio": ct.startswith("audio/") or "octet-stream" in ct
                or sniff_head(head) != "unknown",
            }
    except Exception as e:  # noqa: BLE001
        return {"status": 0, "error": f"{type(e).__name__}: {e}", "looksAudio": False}


def sniff_head(b: bytes) -> str:
    """前 16 字节判容器，与 Android StreamVerifier.sniffHead 完全一致。"""

    def at(i: int) -> int:
        return b[i] if len(b) > i else 0

    def eq(c: str, i: int) -> bool:
        return at(i) == ord(c)

    if len(b) >= 4 and eq("f", 0) and eq("L", 1) and eq("a", 2) and eq("C", 3):
        return "flac"
    if len(b) >= 4 and eq("O", 0) and eq("g", 1) and eq("g", 2) and eq("S", 3):
        return "ogg"
    if len(b) >= 8 and eq("f", 4) and eq("t", 5) and eq("y", 6) and eq("p", 7):
        return "m4a"
    if len(b) >= 3 and eq("I", 0) and eq("D", 1) and eq("3", 2):
        return "mp3"
    if len(b) >= 2 and at(0) == 0xFF and at(1) in (0xFB, 0xF3, 0xF2, 0xFA):
        return "mp3"
    if len(b) >= 4 and eq("R", 0) and eq("I", 1) and eq("F", 2) and eq("F", 3):
        return "wav"
    return "unknown"


def kbps(total: int, duration: int) -> int:
    if duration > 0 and total > 0:
        return total * 8 // duration // 1000
    return 0


def quality_matches(want: str, container: str, kb: int) -> bool:
    """与 Android QualityFacts.matches 一致。"""
    lossless = container in ("flac", "wav")
    if want == "lossless":
        return lossless or kb >= 600
    if want == "high":
        return (not lossless) and 256 <= kb <= 600
    if want == "standard":
        return (not lossless) and 48 <= kb <= 255
    return False


# ---------------------------------------------------------------- 搜索适配器


def search_qq(kw: str, limit: int = 20) -> list[dict]:
    url = (
        "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
        f"?p=1&n={limit}&w={urllib.parse.quote(kw)}&format=json"
    )
    _, body = http(url, {"Referer": "https://y.qq.com/"})
    j = json.loads(body.decode("utf-8", "ignore"))
    lst = ((j.get("data") or {}).get("song") or {}).get("list") or []
    out = []
    for it in lst:
        mid = it.get("songmid") or ""
        name = it.get("songname") or ""
        if not mid or not name:
            continue
        singers = "/".join(s.get("name", "") for s in (it.get("singer") or []))
        album_mid = it.get("albummid") or ""
        out.append(
            {
                "platform": "qq",
                "id": mid,
                "name": name,
                "singer": singers,
                "album": it.get("albumname") or "",
                "duration": int(it.get("interval") or 0),
                "pic": f"https://y.gtimg.cn/music/photo_new/T002R300x300M000{album_mid}.jpg"
                if album_mid
                else None,
            }
        )
    return out


def search_netease(kw: str, limit: int = 20) -> list[dict]:
    url = (
        "https://music.163.com/api/search/get"
        f"?s={urllib.parse.quote(kw)}&type=1&offset=0&limit={limit}"
    )
    _, body = http(url, {"Referer": "https://music.163.com/"})
    j = json.loads(body.decode("utf-8", "ignore"))
    if j.get("code") != 200:
        raise RuntimeError(f"netease code={j.get('code')}")
    lst = ((j.get("result") or {}).get("songs")) or []
    out = []
    for it in lst:
        sid = it.get("id")
        name = it.get("name") or ""
        if not sid or not name:
            continue
        artists = "/".join(a.get("name", "") for a in (it.get("artists") or []))
        album = ((it.get("album") or {}).get("name")) or ""
        out.append(
            {
                "platform": "netease",
                "id": str(sid),
                "name": name,
                "singer": artists,
                "album": album,
                "duration": int((it.get("duration") or 0) / 1000),
                "pic": None,
            }
        )
    # v2.1.94：song/detail 批量补封面（20 首一次）
    if out:
        ids = ",".join(s["id"] for s in out[:20])
        try:
            _, b2 = http(
                f"https://music.163.com/api/song/detail?ids=[{ids}]",
                {"Referer": "https://music.163.com/"},
            )
            detail = json.loads(b2.decode("utf-8", "ignore")).get("songs") or []
            pics = {}
            for d in detail:
                p = ((d.get("album") or {}).get("picUrl")) or ""
                if p:
                    pics[str(d.get("id"))] = p
            for s in out:
                if not s["pic"] and s["id"] in pics:
                    s["pic"] = pics[s["id"]]
        except Exception:  # noqa: BLE001
            pass
    return out


_KUWO_BRACKET_QUOTE = re.compile(r"'([^']*)':\s*'((?:[^'\\]|\\.)*)'")


def _kuwo_split_top_level(s: str) -> list[str]:
    inner = s[1:-1] if s.startswith("[") and s.endswith("]") else s
    depth = 0
    in_quote = False
    escaped = False
    cur = []
    chunks = []
    for ch in inner:
        if in_quote:
            cur.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == "'":
                in_quote = False
            continue
        if ch == "'":
            in_quote = True
            cur.append(ch)
        elif ch in "[{":
            depth += 1
            cur.append(ch)
        elif ch in "]}":
            depth -= 1
            cur.append(ch)
        elif ch == ",":
            if depth == 0:
                c = "".join(cur)
                if c.strip():
                    chunks.append(c)
                cur = []
            else:
                cur.append(ch)
        else:
            cur.append(ch)
    if "".join(cur).strip():
        chunks.append("".join(cur))
    return chunks


def _kuwo_parse_dict(text: str) -> dict | None:
    t = text.strip()
    if not (t.startswith("{") and t.endswith("}")):
        return None
    inner = t[1:-1]
    d = {}
    for m in _KUWO_BRACKET_QUOTE.finditer(inner):
        k = m.group(1)
        v = m.group(2).replace("\\'", "'")
        for a, b in (
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&quot;", '"'),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
        ):
            v = v.replace(a, b)
        d[k] = v
    return d or None


def _kuwo_duration(s: str) -> int:
    t = (s or "").strip()
    if not t:
        return 0
    if t.isdigit():
        v = int(t)
        return v if 1 <= v <= 36000 else 0
    parts = t.split(":")
    try:
        if len(parts) == 2:
            return int(parts[0]) * 60 + int(parts[1])
        if len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
    except ValueError:
        return 0
    return 0


KUWO_VARIANTS = [
    "伴奏", "ktv", "现场", "dj", "live", "翻唱", "纯音乐", "钢琴",
    "remix", "串烧", "mv版", "合唱", "网友改编", "咚鼓",
]


def search_kuwo(kw: str, limit: int = 20) -> list[dict]:
    rn = min(limit, 50)
    url = (
        "https://search.kuwo.cn/r.s"
        f"?all={urllib.parse.quote(kw)}&ft=music&rn={rn}&pn=1&rformat=json&encoding=utf8"
        "&vipver=MUSIC_8.7.8.0_WX"
    )
    _, body = http(url, {"Referer": "https://www.kuwo.cn/"})
    text = body.decode("utf-8", "ignore")
    idx = text.find("'abslist'")
    if idx < 0:
        return []
    rest = text[idx:]
    open_i = rest.find("[")
    close_i = rest.rfind("]")
    if open_i < 0 or close_i <= open_i:
        return []
    records = [d for d in (_kuwo_parse_dict(c) for c in _kuwo_split_top_level(rest[open_i : close_i + 1])) if d]
    loose = lambda s: re.sub(r"\s+", " ", s.lower()).strip()  # noqa: E731

    # 相关性过滤（与 iOS 版 KuwoParser.relevantRecords 一致；Android v2.1.95 是"整串做子串"，
    # 两词查询必然 0 条 —— 2026-11-16 实测「晴天 周杰伦」旧口径 0 条 / 全词 14 条）
    tokens = [t for t in loose(kw).split(" ") if t]

    def haystack(item: dict) -> str:
        return loose((item.get("SONGNAME") or item.get("NAME") or "") + " " + (item.get("ARTIST") or ""))

    if tokens:
        all_tokens = [r for r in records if all(t in haystack(r) for t in tokens)]
        any_token = [r for r in records if any(t in haystack(r) for t in tokens)]
        records = all_tokens if all_tokens else any_token

    songs, variants = [], []
    for item in records:
        name = (item.get("SONGNAME") or item.get("NAME") or "").strip()
        rid = (item.get("MUSICRID") or "").replace("MUSIC_", "")
        if not name or not rid:
            continue
        artist = item.get("ARTIST") or ""
        mvpic = (item.get("MVPIC") or "").strip().lstrip("/")
        song = {
            "platform": "kuwo",
            "id": rid,
            "name": name,
            "singer": artist,
            "album": item.get("ALBUM") or "",
            "duration": _kuwo_duration(item.get("DURATION") or ""),
            "pic": f"https://img1.kuwo.cn/wmvpic/{mvpic}" if mvpic else None,
        }
        (variants if any(v in name.lower() for v in KUWO_VARIANTS) else songs).append(song)
    return songs if songs else variants


def search_kugou(kw: str, limit: int = 20) -> list[dict]:
    url = (
        "https://mobiles.kugou.com/api/v3/search/song"
        f"?format=json&keyword={urllib.parse.quote(kw)}&page=1&pagesize={limit}&showtype=1"
    )
    _, body = http(url, {"Referer": "https://www.kugou.com/"})
    j = json.loads(body.decode("utf-8", "ignore"))
    lst = ((j.get("data") or {}).get("info")) or []
    out = []
    for it in lst:
        h = it.get("hash") or ""
        name = it.get("songname") or ""
        if not h or not name:
            continue
        cover = ((it.get("trans_param") or {}).get("union_cover")) or ""
        pic = cover.replace("{size}", "500").replace("http://", "https://") if cover else None
        out.append(
            {
                "platform": "kugou",
                "id": h,
                "name": name,
                "singer": it.get("singername") or "",
                "album": it.get("album_name") or "",
                "duration": int(it.get("duration") or 0),
                "pic": pic,
            }
        )
    return out


SEARCHERS = {
    "qq": search_qq,
    "netease": search_netease,
    "kuwo": search_kuwo,
    "kugou": search_kugou,
}


# ---------------------------------------------------------------- 取流后端


def resolve_cyapi(song: dict, want: str) -> dict:
    url = (
        "https://cyapi.top/API/qq_music.php"
        "?apikey=1ffdf5733f5d538760e63d7e46ba17438d9f7b9dfc18c51be1109386fd74c3a1"
        f"&type=json&mid={song['id']}"
    )
    _, body = http(url, {"Referer": "https://y.qq.com/"}, timeout=12)
    stream = json.loads(body.decode("utf-8", "ignore")).get("url") or ""
    if not stream:
        raise RuntimeError("cyapi 未返回 URL")
    return {"backend": "cyapi QQ", "directId": True, "url": stream, "declared": None}


def resolve_gdstudio(song: dict, want: str) -> dict:
    br = {"standard": "128", "high": "320", "lossless": "740"}[want]
    url = (
        "https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest"
        "&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease"
        f"&id={song['id']}&br={br}"
    )
    _, body = http(url, {"User-Agent": "LX-Music-Mobile"}, timeout=12)
    stream = json.loads(body.decode("utf-8", "ignore")).get("url") or ""
    if not stream:
        raise RuntimeError("gdstudio 未返回 URL")
    return {"backend": "gdstudio 网易", "directId": True, "url": stream, "declared": br}


def resolve_oiapi(song: dict, want: str) -> dict:
    level = {"standard": "standard", "high": "exhigh", "lossless": "lossless"}[want]
    url = (
        "https://oiapi.net/api/Music_163?key=oiapi-ef6133b7-ac2f-dc7d-878c-d3e207a82575"
        f"&type=json&level={level}&n=1&id={song['id']}"
    )
    _, body = http(url, timeout=12)
    j = json.loads(body.decode("utf-8", "ignore"))
    if j.get("code") != 0:
        raise RuntimeError(f"oiapi code={j.get('code')}")
    stream = ""
    data = j.get("data")
    if isinstance(data, list) and data:
        stream = data[0].get("url") or ""
    if not stream:
        stream = j.get("url") or ""
    if not stream:
        raise RuntimeError("oiapi 未返回 URL")
    return {"backend": "oiapi 网易", "directId": True, "url": stream, "declared": level}


def resolve_yaohu(song: dict, want: str) -> dict:
    key = (song["name"] + song["singer"]).strip()
    url = (
        "https://api.yaohud.cn/api/music/kuwo"
        f"?key=nvgKtvzw7CFSNFrDhA6&action=search&msg={urllib.parse.quote(key)}&n=1"
    )
    _, body = http(url, {"X-Client-Software": "lx"}, timeout=12)
    j = json.loads(body.decode("utf-8", "ignore"))
    if j.get("code") != 200:
        raise RuntimeError(f"妖狐 code={j.get('code')} msg={j.get('msg')}")
    data = j.get("data") or {}
    vm = data.get("vipmusic") or {}
    stream = vm.get("url") or ""
    if not stream:
        raise RuntimeError("妖狐未返回 URL")
    return {
        "backend": "妖狐酷我",
        "directId": False,
        "url": stream,
        "declared": vm.get("level"),
        "respTitle": data.get("songtitle") or data.get("name") or "",
        "respSinger": data.get("songname") or "",
    }


def resolve_kugou(song: dict, want: str) -> dict:
    url = f"https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash={song['id']}"
    _, body = http(url, {"Referer": "https://m.kugou.com/"}, timeout=12)
    j = json.loads(body.decode("utf-8", "ignore"))
    stream = j.get("url") or ""
    if not stream:
        raise RuntimeError(f"酷狗未返回 URL（errcode={j.get('errcode')}）")
    return {"backend": "酷狗官方", "directId": False, "url": stream, "declared": None}


BACKENDS = {
    "qq": [resolve_cyapi],
    "netease": [resolve_gdstudio, resolve_oiapi],
    "kuwo": [resolve_yaohu],
    "kugou": [resolve_kugou],
}


# ---------------------------------------------------------------- 主流程


def main() -> int:
    kw = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "晴天 周杰伦"
    want = "high"
    as_json = "--json" in sys.argv

    report: dict = {"keyword": kw, "want": want, "search": {}, "resolve": []}
    t0 = time.time()

    def run_search(p: str):
        start = time.time()
        try:
            songs = SEARCHERS[p](kw, 20)
            return p, {"ok": True, "count": len(songs), "ms": int((time.time() - start) * 1000),
                       "songs": songs, "error": None}
        except Exception as e:  # noqa: BLE001
            return p, {"ok": False, "count": 0, "ms": int((time.time() - start) * 1000),
                       "songs": [], "error": f"{type(e).__name__}: {e}"}

    with ThreadPoolExecutor(max_workers=4) as ex:
        for p, r in ex.map(run_search, PLATFORMS):
            report["search"][p] = r

    print(f"\n=== 搜索「{kw}」（每平台 limit=20，单平台 12s 超时，并发）===")
    for p in PLATFORMS:
        r = report["search"][p]
        head = f"{SHORT[p]:<3} {r['ms']:>5}ms  {r['count']:>2} 条"
        if not r["ok"]:
            print(f"  {head}  ✗ {r['error']}")
            continue
        top = r["songs"][0] if r["songs"] else None
        extra = f"  首条: {top['name']} / {top['singer']} / {top['album']} / {top['duration']}s" if top else ""
        print(f"  {head}  ✓{extra}")

    # 每平台取首条，跑它自己的后端
    jobs = []
    for p in PLATFORMS:
        songs = report["search"][p]["songs"]
        if songs:
            jobs.append((p, songs[0]))

    def run_resolve(job):
        p, song = job
        rows = []
        for fn in BACKENDS[p]:
            start = time.time()
            try:
                got = fn(song, want)
            except Exception as e:  # noqa: BLE001
                rows.append({"platform": p, "backend": fn.__name__, "ok": False,
                             "ms": int((time.time() - start) * 1000),
                             "error": f"{type(e).__name__}: {e}"})
                continue
            probe = http_range(got["url"])
            kb = kbps(probe.get("totalBytes", 0), song["duration"])
            rows.append({
                "platform": p, "backend": got["backend"], "ok": bool(probe.get("looksAudio")),
                "ms": int((time.time() - start) * 1000),
                "directId": got["directId"], "declared": got.get("declared"),
                "container": probe.get("container"), "kbps": kb,
                "totalBytes": probe.get("totalBytes"), "contentType": probe.get("contentType"),
                "matchesWant": quality_matches(want, probe.get("container", ""), kb),
                "song": song["name"], "error": None if probe.get("looksAudio") else str(probe),
            })
        return rows

    for rows in [run_resolve(j) for j in jobs]:
        report["resolve"].extend(rows)

    print(f"\n=== 取流（want={want}，每后端 12s，Range 探测真实容器/码率）===")
    for r in report["resolve"]:
        if not r.get("ok"):
            print(f"  {SHORT.get(r['platform'], r['platform']):<3} {r['backend']:<14} ✗ {r.get('error')}")
            continue
        mark = "命中" if r["matchesWant"] else "不命中"
        print(
            f"  {SHORT.get(r['platform'], r['platform']):<3} {r['backend']:<14} ✓ "
            f"{r['container']:<7} {r['kbps']:>5}kbps {r['totalBytes'] / 1e6:>6.2f}MB "
            f"{r['ms']:>5}ms  {mark}（自报 {r['declared']}）"
        )

    ok_search = any(v["ok"] and v["count"] > 0 for v in report["search"].values())
    ok_resolve = any(r.get("ok") for r in report["resolve"])
    report["summary"] = {
        "searchOK": ok_search,
        "resolveOK": ok_resolve,
        "elapsedMs": int((time.time() - t0) * 1000),
        "platformsWithResults": [p for p in PLATFORMS if report["search"][p]["count"] > 0],
        "backendsOK": [r["backend"] for r in report["resolve"] if r.get("ok")],
    }
    print(f"\n小结：{report['summary']}")

    if as_json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if (ok_search and ok_resolve) else 2


if __name__ == "__main__":
    sys.exit(main())

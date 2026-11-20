#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""周杰伦曲目在「所有候选通道」上的实况矩阵（2026-11-21）。

目的：老板要「准确性第一、失败自动跳过」。所以先钉死两件事：
  1. 哪些通道对周杰伦能拿到**整首真文件**（不是 181,521 B 提示音）
  2. 哪些通道会失败、失败得多快（决定"跳过"代价）

通道：
  酷我 anti.s（现主链，已知可能给提示音）/ ikun(wwwweb source=kw) / 星海(zddyr source=kw)
  酷狗 zddyr source=kg（128k/320k/flac）—— 项目里目前没有酷狗取流
  QQ cyapi / QQ 落月(vkeys) / QQ soso 搜索延迟
  网易 gdstudio（周杰伦在网易无版权，预期失败，作对照）
输出：tools/probes/out/jay_matrix_2026_11_21.json
"""
import json
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"}
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "jay_matrix_2026_11_21.json")
PLACEHOLDER_BYTES = 181_521
_last = {}


def _throttle(url, gap=1.0):
    host = urllib.parse.urlparse(url).netloc
    wait = gap - (time.time() - _last.get(host, 0))
    if wait > 0:
        time.sleep(wait)
    _last[host] = time.time()


def req(url, headers=None, rng="bytes=0-2047", timeout=15, body=None, method=None):
    h = dict(UA)
    h.update(headers or {})
    if rng:
        h["Range"] = rng
    _throttle(url)
    t0 = time.time()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=h, data=body, method=method),
                                    timeout=timeout, context=CTX) as r:
            data = r.read() if rng is None else r.read(4096)
            return {"status": r.status, "ms": int((time.time() - t0) * 1000),
                    "headers": {k.lower(): v for k, v in r.headers.items()},
                    "body": data, "final_url": r.geturl()}
    except urllib.error.HTTPError as e:
        return {"status": e.code, "ms": int((time.time() - t0) * 1000),
                "headers": {k.lower(): v for k, v in e.headers.items()},
                "body": e.read(1024), "final_url": url}
    except Exception as e:  # noqa: BLE001
        return {"status": -1, "ms": int((time.time() - t0) * 1000), "headers": {},
                "body": str(e).encode()[:200], "final_url": url}


def jbody(r):
    try:
        return json.loads(r["body"].decode("utf-8", "ignore"))
    except Exception:  # noqa: BLE001
        return {}


def total(h):
    cr = h.get("content-range", "")
    if "/" in cr:
        try:
            return int(cr.rsplit("/", 1)[1])
        except ValueError:
            pass
    try:
        return int(h.get("content-length", "0") or 0)
    except ValueError:
        return 0


def magic(b):
    if b[:4] == b"fLaC":
        return "flac"
    if b[:3] == b"ID3":
        return "mp3"
    if b[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2", b"\xff\xfa"):
        return "mp3"
    if b[4:8] == b"ftyp":
        return "m4a"
    return "?" + b[:6].hex()


def verdict(tb, m):
    if tb == PLACEHOLDER_BYTES:
        return "占位提示音(181,521B)"
    if tb == 0:
        return "无体积"
    if m in ("mp3", "flac", "m4a"):
        return "真音频"
    return "容器可疑"


SONGS = ["晴天", "夜曲", "稻香"]
out = {"generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "songs": [], "qq_latency": []}

# ---------- 素材：三家搜索拿 id ----------
def kw_search(kw):
    u = ("https://search.kuwo.cn/r.s?client=kt&pn=0&rn=5&all=%s&vipver=11.1.6.2"
         "&ft=music&encoding=utf8&rformat=json&mobi=1" % urllib.parse.quote(kw))
    j = jbody(req(u, {"Referer": "https://www.kuwo.cn/"}, rng=None))
    lst = j.get("abslist") or []
    if not lst:
        return None
    it = lst[0]
    return {"rid": str(it.get("MUSICRID", "")).replace("MUSIC_", ""),
            "name": it.get("SONGNAME"), "singer": it.get("ARTIST")}


def kg_search(kw):
    u = ("https://songsearch.kugou.com/song_search_v2?keyword=%s&page=1&pagesize=3"
         "&platform=WebFilter&userid=0&clientver=2000&iscorrection=1&privilege_filter=0"
         % urllib.parse.quote(kw))
    j = jbody(req(u, {"Referer": "https://www.kugou.com/"}, rng=None))
    lst = ((j.get("data") or {}).get("lists") or [])
    if not lst:
        return None
    it = lst[0]
    return {"hash": it.get("FileHash"), "name": it.get("SongName"),
            "singer": it.get("SingerName"), "duration": it.get("Duration")}


def qq_search(kw):
    u = ("https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=%s&format=json&n=3&p=1"
         % urllib.parse.quote(kw))
    j = jbody(req(u, {"Referer": "https://y.qq.com/"}, rng=None))
    lst = (((j.get("data") or {}).get("song") or {}).get("list") or [])
    if not lst:
        return None
    it = lst[0]
    return {"mid": it.get("songmid"), "name": it.get("songname"),
            "singer": "/".join(s.get("name", "") for s in it.get("singer") or [])}


for song in SONGS:
    entry = {"song": song, "channels": {}}
    kw = kw_search(song + " 周杰伦")
    kg = kg_search(song + " 周杰伦")
    qq = qq_search(song + " 周杰伦")
    entry["ids"] = {"kuwo": kw, "kugou": kg, "qq": qq}

    # ① 酷我 anti.s（现主链）——跟到 CDN 看真实体积
    if kw and kw["rid"]:
        r = req("https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3"
                "&response=url&rid=MUSIC_%s" % kw["rid"],
                {"Referer": "https://www.kuwo.cn/"}, rng=None, timeout=10)
        link = r["body"].decode("utf-8", "ignore").strip()
        ch = {"api_status": r["status"], "api_ms": r["ms"], "got_url": link.startswith("http")}
        if link.startswith("http"):
            a = req(link)
            tb = total(a["headers"])
            ch.update(status=a["status"], total_bytes=tb, magic=magic(a["body"]),
                      verdict=verdict(tb, magic(a["body"])),
                      kbps=round(tb * 8 / 269) if tb and song == "晴天" else None)
        entry["channels"]["酷我 anti.s"] = ch

    # ② ikun / wwwweb（酷我 320k / flac）
    if kw and kw["rid"]:
        for q in ("320k", "flac"):
            body = json.dumps({"source": "kw", "musicId": kw["rid"], "quality": q}).encode()
            r = req("https://c.wwwweb.top/music/url", body=body,
                    headers={"Content-Type": "application/json"}, rng=None, timeout=15)
            j = jbody(r)
            link = j.get("url") or ""
            ch = {"status": r["status"], "ms": r["ms"], "code": j.get("code"),
                  "msg": (j.get("message") or j.get("msg") or "")[:40]}
            if link.startswith("http"):
                a = req(link)
                tb = total(a["headers"])
                ch.update(audio_status=a["status"], total_bytes=tb, magic=magic(a["body"]),
                          verdict=verdict(tb, magic(a["body"])))
            entry["channels"]["ikun wwwweb %s" % q] = ch

    # ③ 酷狗 zddyr source=kg（项目里没有这条）
    if kg and kg["hash"]:
        for q in ("128k", "320k", "flac"):
            u = "https://yy.zddyr.top/lx/api/?source=kg&quality=%s&mainHash=%s" % (q, kg["hash"])
            r = req(u, {"Referer": "https://www.kugou.com/"}, timeout=12)
            j = jbody(r)
            link = j.get("url") or ""
            ch = {"status": r["status"], "ms": r["ms"], "code": j.get("code"),
                  "msg": (j.get("msg") or "")[:40]}
            if link.startswith("http"):
                a = req(link)
                tb = total(a["headers"])
                dur = int(kg.get("duration") or 0)
                ch.update(audio_status=a["status"], total_bytes=tb, magic=magic(a["body"]),
                          verdict=verdict(tb, magic(a["body"])),
                          kbps=round(tb * 8 / dur / 1000) if dur and tb else None)
            entry["channels"]["酷狗 zddyr " + q] = ch

    # ④ 网易 gdstudio（预期：无版权，失败）
    if qq:  # 网易没有周杰伦，用歌名搜到的网易 id 作对照
        u = "http://music.163.com/api/search/get?s=%s&type=1&limit=1&offset=0" % urllib.parse.quote(song + " 周杰伦")
        j = jbody(req(u, {"Referer": "https://music.163.com/"}, rng=None))
        nid = None
        try:
            nid = str((((j.get("result") or {}).get("songs") or [])[0])["id"])
        except Exception:  # noqa: BLE001
            pass
        entry["ids"]["netease"] = nid
        if nid:
            g = req("https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=%s&br=320"
                    % nid, {"User-Agent": "LX-Music-Mobile"}, timeout=10)
            gj = jbody(g)
            link = gj.get("url") or ""
            ch = {"status": g["status"], "ms": g["ms"], "has_url": bool(link)}
            if link.startswith("http"):
                a = req(link)
                tb = total(a["headers"])
                ch.update(total_bytes=tb, magic=magic(a["body"]), verdict=verdict(tb, magic(a["body"])))
            entry["channels"]["网易 gdstudio"] = ch

    # ⑤ QQ cyapi（App 现用）/ 落月 vkeys
    if qq and qq["mid"]:
        r = req("https://cyapi.top/API/qq_music.php"
                "?apikey=1ffdf5733f5d538760e63d7e46ba17438d9f7b9dfc18c51be1109386fd74c3a1"
                "&type=json&mid=%s" % qq["mid"], {"Referer": "https://y.qq.com/"}, timeout=12)
        j = jbody(r)
        link = j.get("url") or ""
        ch = {"status": r["status"], "ms": r["ms"],
              "msg": str(j.get("msg") or j.get("message") or "")[:60], "has_url": bool(link)}
        if link.startswith("http"):
            a = req(link)
            tb = total(a["headers"])
            ch.update(total_bytes=tb, magic=magic(a["body"]), verdict=verdict(tb, magic(a["body"])))
        entry["channels"]["QQ cyapi"] = ch

        r = req("https://api.vkeys.cn/music/tencent/song/link?mid=%s&quality=8" % qq["mid"],
                timeout=12)
        j = jbody(r)
        data = j.get("data") or {}
        link = data.get("url") if isinstance(data, dict) else ""
        ch = {"status": r["status"], "ms": r["ms"], "code": j.get("code"),
              "msg": str(j.get("message") or "")[:60], "has_url": bool(link)}
        if isinstance(link, str) and link.startswith("http"):
            a = req(link)
            tb = total(a["headers"])
            ch.update(total_bytes=tb, magic=magic(a["body"]), verdict=verdict(tb, magic(a["body"])))
        entry["channels"]["QQ 落月 vkeys"] = ch

    out["songs"].append(entry)
    print("\n### " + song)
    for k, v in entry["channels"].items():
        print("  %-18s %s" % (k, json.dumps(v, ensure_ascii=False)[:230]))

# ---------- QQ 搜索延迟（"一直超时"的直接证据） ----------
for i in range(4):
    t0 = time.time()
    r = req("https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=%s&format=json&n=5&p=1"
            % urllib.parse.quote("周杰伦 晴天"), {"Referer": "https://y.qq.com/"}, rng=None, timeout=20)
    ok = r["status"] == 200 and b'"list"' in r["body"]
    out["qq_latency"].append({"round": i + 1, "status": r["status"], "ms": r["ms"], "ok": ok,
                              "bytes": len(r["body"])})
    print("QQ soso #%d: %dms status=%s ok=%s" % (i + 1, r["ms"], r["status"], ok))
    time.sleep(1)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print("\nWROTE " + OUT)

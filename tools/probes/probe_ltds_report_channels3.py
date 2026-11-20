#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第三轮：把「能不能进主链」的最后三点钉死。

1. 酷狗 zddyr 的档位谱：128k / 320k / flac / master 各回什么（播放链只要 ≤320k）
2. 正确偏移的 mid-file Range（上一轮偏移算大了 1000 倍，服务器回 416 是对的）
3. 直链寿命：拿 20 分钟前生成的那条 fsandroid 链再取一次
输出：tools/probes/out/ltds_report_probe3.json
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
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "ltds_report_probe3.json")
_last = {}


def _throttle(url, gap=1.0):
    host = urllib.parse.urlparse(url).netloc
    wait = gap - (time.time() - _last.get(host, 0))
    if wait > 0:
        time.sleep(wait)
    _last[host] = time.time()


def req(url, headers=None, rng="bytes=0-2047", timeout=20):
    h = dict(UA)
    h.update(headers or {})
    if rng:
        h["Range"] = rng
    _throttle(url)
    t0 = time.time()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=timeout, context=CTX) as r:
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


def total_bytes(h):
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
        return "mp3(id3)"
    if b[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2", b"\xff\xfa"):
        return "mp3"
    if b[4:8] == b"ftyp":
        return "m4a"
    return "?" + b[:6].hex()


out = {"generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "quality_ladder": [],
       "seek": [], "expiry": {}}

HASH = "64B39A6828913E58E1ED1F7F6061A380"   # 孤勇者 / 陈奕迅 / 256s
DUR = 256
link_master = ""

# ---------- 1. 档位谱 ----------
for q in ("128k", "320k", "flac", "master"):
    u = "https://yy.zddyr.top/lx/api/?source=kg&quality=%s&mainHash=%s" % (q, HASH)
    r = req(u, {"Referer": "https://www.kugou.com/"})
    try:
        j = json.loads(r["body"].decode("utf-8", "ignore"))
    except Exception:  # noqa: BLE001
        j = {}
    row = {"quality": q, "code": j.get("code"), "msg": (j.get("msg") or "")[:40],
           "api_ms": r["ms"], "has_url": bool(j.get("url"))}
    link = j.get("url") or ""
    if link.startswith("http"):
        a = req(link)
        tb = total_bytes(a["headers"])
        row.update(status=a["status"], ctype=a["headers"].get("content-type", ""),
                   total_bytes=tb, magic=magic(a["body"]),
                   kbps=round(tb * 8 / DUR / 1000) if tb else None,
                   jump_host=urllib.parse.urlparse(link).netloc,
                   jump_len=len(link))
        if q == "master":
            link_master = link
    out["quality_ladder"].append(row)
    print(json.dumps(row, ensure_ascii=False)[:300])

# ---------- 2. 正确的 mid-file seek ----------
seek_cases = []
if link_master:
    seek_cases.append(("酷狗 master 60s 处", link_master, DUR))
# 网易 meting（孤勇者 id=1901371647, 256s）
net = "https://api.qijieya.cn/meting/?server=netease&type=url&id=1901371647"
seek_cases.append(("网易 meting 60s 处", net, DUR))

for label, url, dur in seek_cases:
    head = req(url)
    tb = total_bytes(head["headers"])
    if not tb:
        out["seek"].append({"label": label, "error": "no total bytes", "status": head["status"]})
        continue
    off = int(60 * tb / dur) // 1024 * 1024
    s = req(url, rng="bytes=%d-%d" % (off, off + 2047))
    row = {"label": label, "offset": off, "status": s["status"],
           "content_range": s["headers"].get("content-range", ""),
           "ctype": s["headers"].get("content-type", ""),
           "magic": magic(s["body"]), "ms": s["ms"]}
    out["seek"].append(row)
    print(json.dumps(row, ensure_ascii=False)[:300])

# ---------- 3. 直链寿命（probe1 生成的那条） ----------
old = ("http://fsandroid.tx.kugou.com/202611202129/05c2192ce86681b251953fa5346fd4e9/v3/"
       "a10de94cd50c61e22790a3e7a0c0dd71/yp/full/ap1005_us1806684881_mimusicapi_pi2_mx321")
r = req(old)
out["expiry"] = {"age_hint": "probe1 生成（约 00:25），本条为复测",
                 "status": r["status"],
                 "content_range": r["headers"].get("content-range", ""),
                 "ctype": r["headers"].get("content-type", ""),
                 "magic": magic(r["body"]), "ms": r["ms"]}
print(json.dumps(out["expiry"], ensure_ascii=False))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print("\nWROTE " + OUT)

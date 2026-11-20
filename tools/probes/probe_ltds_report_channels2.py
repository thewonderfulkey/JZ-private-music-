#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第二轮：净新增通道的命中率与 seek 能力（决定能否进主链）。

  A. 酷狗 zddyr source=kg：6 首跨歌手 × (master / flac)，外加 mid-file Range 验 seek
  B. 网易 qijieya meting：取我们网易搜索真实返回的 6 个 id，验命中率 + seek

规则同第一轮：只 Range 取 2KB；同 host ≥1s；只认实测字节。
输出：tools/probes/out/ltds_report_probe2.json
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
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "ltds_report_probe2.json")
_last = {}


def _throttle(url, gap=1.0):
    host = urllib.parse.urlparse(url).netloc
    wait = gap - (time.time() - _last.get(host, 0))
    if wait > 0:
        time.sleep(wait)
    _last[host] = time.time()


def req(url, headers=None, rng="bytes=0-2047", method="GET", body=None, timeout=15):
    h = dict(UA)
    h.update(headers or {})
    if rng:
        h["Range"] = rng
    _throttle(url)
    t0 = time.time()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=h, data=body, method=method),
                                    timeout=timeout, context=CTX) as r:
            # rng=None（JSON 类）要读全，二进制 Range 只读前 4KB
            data = r.read() if rng is None else r.read(4096)
            return {"status": r.status, "ms": int((time.time() - t0) * 1000),
                    "headers": {k.lower(): v for k, v in r.headers.items()},
                    "body": data, "final_url": r.geturl()}
    except urllib.error.HTTPError as e:
        return {"status": e.code, "ms": int((time.time() - t0) * 1000),
                "headers": {k.lower(): v for k, v in e.headers.items()},
                "body": e.read(2048), "final_url": url}
    except Exception as e:  # noqa: BLE001
        return {"status": -1, "ms": int((time.time() - t0) * 1000), "headers": {},
                "body": str(e).encode()[:300], "final_url": url}


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


def dur_sec(d):
    d = int(d or 0)
    return d / 1000 if d > 2000 else d   # 酷狗 Duration 是秒；有些接口给毫秒


def get_json(url, headers=None):
    r = req(url, headers, rng=None)
    try:
        return json.loads(r["body"].decode("utf-8", "ignore")), r
    except Exception:  # noqa: BLE001
        return None, r


out = {"generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "kugou": [], "netease": []}

# ================= A. 酷狗 zddyr source=kg =================
KEYWORDS = ["陈奕迅 孤勇者", "刀郎 罗刹海市", "买辣椒也用券 起风了", "邓紫棋 光年之外", "周杰伦 夜曲"]
picks = []
for kw in KEYWORDS:
    j, _ = get_json("https://songsearch.kugou.com/song_search_v2?keyword=%s&page=1&pagesize=3"
                    "&platform=WebFilter&userid=0&clientver=2000&iscorrection=1&privilege_filter=0"
                    % urllib.parse.quote(kw))
    for it in ((j or {}).get("data") or {}).get("lists") or []:
        picks.append({"name": it.get("SongName"), "singer": it.get("SingerName"),
                      "hash": it.get("FileHash"), "duration": dur_sec(it.get("Duration"))})
        break   # 每词取第一条，6 首里只留不重复的
seen, uniq = set(), []
for p in picks:
    if p["hash"] and p["hash"] not in seen:
        seen.add(p["hash"])
        uniq.append(p)

print("素材 %d 首：%s" % (len(uniq), "、".join(p["name"] for p in uniq)))

for p in uniq[:6]:
    row = {"song": p["name"], "singer": p["singer"], "hash": p["hash"], "duration_s": p["duration"]}
    for q in ("master", "flac"):
        url = ("https://yy.zddyr.top/lx/api/?source=kg&quality=%s&mainHash=%s" % (q, p["hash"]))
        j, r = get_json(url, {"Referer": "https://www.kugou.com/"})
        j = j or {}
        link = j.get("url") or ""
        row[q] = {"code": j.get("code"), "msg": (j.get("msg") or "")[:40],
                  "api_ms": r["ms"], "has_url": bool(link)}
        if link.startswith("http") and q == "master":
            a = req(link)
            tb = total_bytes(a["headers"])
            row[q].update(status=a["status"], ctype=a["headers"].get("content-type", ""),
                          total_bytes=tb, magic=magic(a["body"]),
                          kbps=round(tb * 8 / p["duration"] / 1000) if p["duration"] else None,
                          jump=link[:70])
            # mid-file seek：直接跳 60 秒处
            seek = req(link, rng="bytes=%d-%d" % (int(60000 * tb / max(p["duration"], 1)),
                                                   int(60000 * tb / max(p["duration"], 1)) + 1023))
            row[q]["seek"] = {"status": seek["status"],
                              "content_range": seek["headers"].get("content-range", ""),
                              "magic": magic(seek["body"])}
    out["kugou"].append(row)
    print(json.dumps(row, ensure_ascii=False)[:400])

# ================= B. 网易 qijieya meting =================
nids = []
for kw in ("周杰伦 晴天", "陈奕迅 孤勇者", "许嵩 有何不可", "刀郎 罗刹海市", "孙燕姿 遇见", "周深 大鱼"):
    j, _ = get_json("http://music.163.com/api/search/get?s=%s&type=1&limit=3&offset=0"
                    % urllib.parse.quote(kw), {"Referer": "https://music.163.com/"})
    try:
        for it in ((j or {}).get("result") or {}).get("songs") or []:
            nids.append({"id": str(it["id"]), "name": it.get("name"),
                         "singer": " ".join(a.get("name", "") for a in it.get("artists") or []),
                         "duration": int((it.get("duration") or 0) / 1000)})
            break
    except Exception:  # noqa: BLE001
        pass

print("\n网易素材 %d 首" % len(nids))
for n in nids[:6]:
    u = "https://api.qijieya.cn/meting/?server=netease&type=url&id=%s" % n["id"]
    r = req(u)
    tb = total_bytes(r["headers"])
    ctype = r["headers"].get("content-type", "")
    row = {"song": n["name"], "singer": n["singer"], "id": n["id"], "duration_s": n["duration"],
           "status": r["status"], "ctype": ctype, "total_bytes": tb,
           "magic": magic(r["body"]), "ms": r["ms"],
           "kbps": round(tb * 8 / n["duration"] / 1000) if (n["duration"] and tb) else None}
    if tb > 1000 and "audio" in ctype:
        pos = int(60000 * tb / max(n["duration"], 1) / 1024) * 1024
        seek = req(u, rng="bytes=%d-%d" % (pos, pos + 1023))
        row["seek"] = {"status": seek["status"],
                       "content_range": seek["headers"].get("content-range", ""),
                       "magic": magic(seek["body"])}
    out["netease"].append(row)
    print(json.dumps(row, ensure_ascii=False)[:400])

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print("\nWROTE " + OUT)

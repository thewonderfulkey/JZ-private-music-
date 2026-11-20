#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""聆听岛报告（2026-11-21）里「净新增」通道的本机实测探针。

只测已确认没有接进 App 的四条，外加两条对照组：
  A. 酷狗取流     yy.zddyr.top/lx/api/?source=kg&quality=master   （App 内目前没有酷狗取流）
  B. 网易取流     api.qijieya.cn/meting/?type=url（直接吐音频字节）
  C. 酷我音质预检 musicpay.kuwo.cn/music.pay（MINFO）
  D. 酷狗歌词     m.kugou.com/app/i/krc.php（必须 timelength）
  对照 1. 酷狗官方 playInfo（已知"能搜不能播"）
  对照 2. wwwweb source=kg（报告怀疑 171KB 试听片段）

规则（skill 第 2 步）：
  · 一律 Range: bytes=0-2047，绝不整包下载
  · 只认实测：状态码 + Content-Range 总长 + 容器魔数 + 真实码率
  · 同一 host ≥1s 一次，别把免费后端打挂
输出：tools/probes/out/ltds_report_probe.json
"""
import json
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

UA = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
_last_hit = {}


def _throttle(url, gap=1.0):
    host = urllib.parse.urlparse(url).netloc
    now = time.time()
    wait = gap - (now - _last_hit.get(host, 0))
    if wait > 0:
        time.sleep(wait)
    _last_hit[host] = time.time()


def req(url, headers=None, rng=True, method="GET", body=None, timeout=15, redirect=True):
    h = dict(UA)
    h.update(headers or {})
    if rng:
        h["Range"] = "bytes=0-2047"
    _throttle(url)
    r = urllib.request.Request(url, headers=h, data=body, method=method)
    t0 = time.time()
    try:
        with urllib.request.urlopen(r, timeout=timeout, context=CTX) as resp:
            data = resp.read(4096) if rng else resp.read()
            return {
                "status": resp.status,
                "ms": int((time.time() - t0) * 1000),
                "headers": {k.lower(): v for k, v in resp.headers.items()},
                "body": data,
                "final_url": resp.geturl(),
            }
    except urllib.error.HTTPError as e:
        return {"status": e.code, "ms": int((time.time() - t0) * 1000),
                "headers": {k.lower(): v for k, v in e.headers.items()},
                "body": e.read(4096), "final_url": url}
    except Exception as e:  # noqa: BLE001
        return {"status": -1, "ms": int((time.time() - t0) * 1000),
                "headers": {}, "body": str(e).encode()[:400], "final_url": url}


def total_bytes(headers):
    cr = headers.get("content-range", "")
    if "/" in cr:
        try:
            return int(cr.rsplit("/", 1)[1])
        except ValueError:
            return 0
    try:
        return int(headers.get("content-length", "0") or 0)
    except ValueError:
        return 0


def magic_of(b):
    if b[:4] == b"fLaC":
        return "flac"
    if b[:3] == b"ID3":
        return "mp3(id3)"
    if b[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2", b"\xff\xfa"):
        return "mp3"
    if b[4:8] == b"ftyp":
        return "m4a"
    if b[:4] == b"OggS":
        return "ogg"
    if b[:4] == b"RIFF":
        return "wav"
    return "?" + b[:8].hex()


def audio_probe(url, duration=None, label=""):
    """对一条音频直链做 2KB Range 取证"""
    r = req(url)
    tb = total_bytes(r["headers"])
    kb = round(tb * 8 / duration / 1000, 1) if (duration and tb) else None
    return {
        "label": label,
        "status": r["status"],
        "ms": r["ms"],
        "ctype": r["headers"].get("content-type", ""),
        "total_bytes": tb,
        "magic": magic_of(r["body"]),
        "kbps": kb,
        "final_url": r["final_url"][:160],
    }


def json_body(r):
    try:
        return json.loads(r["body"].decode("utf-8", "ignore"))
    except Exception:  # noqa: BLE001
        return None


results = {"generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "cases": []}


def case(name, **kw):
    kw["case"] = name
    results["cases"].append(kw)
    print(f"\n=== {name} ===")
    print(json.dumps(kw, ensure_ascii=False, indent=2)[:1500])


# ---------- 0. 素材：酷狗搜索（拿 hash + 时长） ----------
KS = urllib.parse.quote("晴天 周杰伦")
sg = req("https://songsearch.kugou.com/song_search_v2?keyword=%s&page=1&pagesize=5"
         "&platform=WebFilter&userid=0&clientver=2000&iscorrection=1&privilege_filter=0" % KS,
         rng=False)
sgj = json_body(sg) or {}
kugou_songs = []
for it in ((sgj.get("data") or {}).get("lists") or [])[:3]:
    kugou_songs.append({
        "name": it.get("SongName"),
        "singer": it.get("SingerName"),
        "hash": it.get("FileHash"),
        "album_id": it.get("AlbumID"),
        "duration": it.get("Duration"),
    })
case("0 酷狗搜索(素材)", status=sg["status"], ms=sg["ms"], songs=kugou_songs)
k1 = kugou_songs[0] if kugou_songs else {}

# ---------- 对照 1：酷狗官方 playInfo ----------
if k1.get("hash"):
    r = req("https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=%s" % k1["hash"],
            headers={"Referer": "https://m.kugou.com/"}, rng=False)
    j = json_body(r) or {}
    case("对照1 酷狗官方 playInfo", status=r["status"], ms=r["ms"],
         has_url=bool(j.get("url")), errcode=j.get("errcode"),
         keys=sorted(j.keys())[:14], url=str(j.get("url"))[:80])

# ---------- D：酷狗歌词 krc.php（有/无 timelength） ----------
if k1.get("hash"):
    ms_len = int(k1.get("duration") or 0)
    with_t = ("https://m.kugou.com/app/i/krc.php?cmd=100&hash=%s&timelength=%d"
              % (k1["hash"], ms_len or 269000))
    r1 = req(with_t, headers={"Referer": "https://m.kugou.com/"}, rng=False)
    r2 = req("https://m.kugou.com/app/i/krc.php?cmd=100&hash=%s" % k1["hash"],
             headers={"Referer": "https://m.kugou.com/"}, rng=False)
    case("D 酷狗歌词 krc.php", with_timelength={"status": r1["status"], "bytes": len(r1["body"]),
                                                 "head": r1["body"][:90].decode("utf-8", "ignore")},
         without_timelength={"status": r2["status"], "bytes": len(r2["body"])})

# ---------- A：酷狗取流 zddyr source=kg ----------
if k1.get("hash"):
    variants = {
        "报告原样(固定albumId/songmid)": "https://yy.zddyr.top/lx/api/?source=kg&quality=master"
                                       "&songmid=350839&albumId=555864&mainHash=%s" % k1["hash"],
        "只给 mainHash": "https://yy.zddyr.top/lx/api/?source=kg&quality=master&mainHash=%s" % k1["hash"],
        "带真 albumId": "https://yy.zddyr.top/lx/api/?source=kg&quality=master"
                        "&albumId=%s&mainHash=%s" % (k1.get("album_id") or "", k1["hash"]),
    }
    for vname, vurl in variants.items():
        r = req(vurl, headers={"Referer": "https://www.kugou.com/"})
        j = json_body(r) or {}
        got = (j.get("url") or "") if isinstance(j, dict) else ""
        entry = {"variant": vname, "status": r["status"], "ms": r["ms"],
                 "code": j.get("code") if isinstance(j, dict) else None,
                 "msg": (j.get("msg") or "")[:60] if isinstance(j, dict) else str(r["body"][:80]),
                 "url_head": got[:90]}
        if got.startswith("http"):
            entry["audio"] = audio_probe(
                got, (k1.get("duration") or 0) / 1000 or None, label=vname)
        case("A 酷狗取流 zddyr kg", **entry)

    # 对照 2：wwwweb source=kg（报告说 171KB 疑似试听）
    body = json.dumps({"source": "kg", "musicId": k1["hash"], "quality": "128k"}).encode()
    r = req("https://c.wwwweb.top/music/url", body=body,
            headers={"Content-Type": "application/json"}, rng=False)
    j = json_body(r) or {}
    entry = {"status": r["status"], "ms": r["ms"],
             "code": j.get("code") if isinstance(j, dict) else None,
             "msg": (j.get("message") or j.get("msg") or "")[:70] if isinstance(j, dict) else ""}
    u = (j.get("url") or "") if isinstance(j, dict) else ""
    if u.startswith("http"):
        entry["audio"] = audio_probe(u, (k1.get("duration") or 0) / 1000 or None, label="wwwweb kg")
    case("对照2 wwwweb source=kg", **entry)

# ---------- B：网易取流 api.qijieya.cn/meting type=url ----------
# 347230 = 网易「晴天」；27867073 = 项目搜索里出现过的一首
for nid, nm in (("347230", "晴天"), ("186016", "许嵩-有何不可?")):
    u = "https://api.qijieya.cn/meting/?server=netease&type=url&id=%s" % nid
    r = req(u)
    tb = total_bytes(r["headers"])
    info = {
        "status": r["status"], "ms": r["ms"],
        "ctype": r["headers"].get("content-type", ""),
        "total_bytes": tb,
        "magic": magic_of(r["body"]),
        "final_url": r["final_url"][:150],
    }
    # 若它回的是 JSON 链接而不是字节，继续跟进那条链接
    if "json" in info["ctype"] or r["body"][:1] in (b"{", b"["):
        j = json_body(r) or {}
        link = ""
        if isinstance(j, dict):
            link = j.get("url") or ((j.get("data") or {}).get("url") if isinstance(j.get("data"), dict) else "") or ""
        info["json_url"] = link[:120]
        if link.startswith("http"):
            info["audio"] = audio_probe(link, 269, label="meting->" + nm)
    case("B 网易取流 qijieya meting " + nm, **info)

# ---------- C：酷我音质预检 music.pay ----------
rids = {"晴天": "228908", "七里香": "94237", "大鱼": "7095195"}
for nm, rid in rids.items():
    r = req("https://musicpay.kuwo.cn/music.pay?op=query&action=play&ids=%s" % rid,
            headers={"Referer": "https://www.kuwo.cn/"}, rng=False)
    j = json_body(r) or {}
    minfo = ""
    try:
        minfo = j["songs"][0]["MINFO"]
    except Exception:  # noqa: BLE001
        pass
    case("C 酷我音质预检 music.pay " + nm,
         status=r["status"], ms=r["ms"],
         errormsg=j.get("errormsg"), result=j.get("result"),
         minfo=minfo[:200], minfo_levels=[p for p in minfo.split(";") if p][:6])

os.makedirs(OUT_DIR, exist_ok=True)
path = os.path.join(OUT_DIR, "ltds_report_probe.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(results, f, ensure_ascii=False, indent=2)
print("\nWROTE " + path)

# -*- coding: utf-8 -*-
"""量一下「播放链取源」在真网上的实际耗时。

为什么量这个：切歌那一刻引擎先把音频停掉（AudioPlayer.swift `stopCurrentForSwitch`），
再去解析下一首；这段"没声音的空档"有多长，直接决定 iOS 在后台会不会把进程挂起。

按 App 的真实取法（SourceAdapters.swift）逐首跑：
  ① gdstudio 网易取 URL（播放在 `.lossless` 档 = br=740；A 方案定稿后是 br=320）
  ② StreamVerifier.inspect 等价的 Range 探测（bytes=0-4095，按域名给 Referer）
记录每一步的毫秒数。

用法：python tools/probes/probe_play_resolve_latency.py [采样首数]
"""
import json
import random
import sys
import time
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
PLAYLIST_ID = "7547299268"   # 老板真实导入过的网易「我喜欢的音乐」
SAMPLE = int(sys.argv[1]) if len(sys.argv) > 1 else 6


def get(url, headers=None, timeout=25):
    h = {"User-Agent": UA, "Referer": "https://music.163.com/"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def referer_for(host):
    h = (host or "").lower()
    if "126.net" in h or "163.com" in h:
        return "https://music.163.com/"
    if "kuwo" in h:
        return "https://www.kuwo.cn/"
    if "kugou" in h:
        return "https://m.kugou.com/"
    if "qq.com" in h or "gtimg" in h:
        return "https://y.qq.com/"
    return "https://music.qq.com/"


def probe(url, timeout=5):
    """StreamVerifier.inspect 的第一道 peek：只要拿到头几个字节就算成功。"""
    host = urllib.parse.urlparse(url).hostname
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Referer": referer_for(host),
        "Range": "bytes=0-4095",
        "Accept": "*/*",
    })
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        head = r.read(4096)
    return int((time.time() - t0) * 1000), len(head)


print("=== 拉真实歌单（网易 %s）===" % PLAYLIST_ID)
detail = get("https://music.163.com/api/v6/playlist/detail?id=%s&n=1000&s=8" % PLAYLIST_ID)
pl = detail.get("playlist", {})
ids = [t["id"] for t in (pl.get("trackIds") or []) if t.get("id")]
print("歌单名=%s  trackCount=%s  可取到 id=%d" % (pl.get("name"), pl.get("trackCount"), len(ids)))

random.seed(20261120)
picked = random.sample(ids[:400], SAMPLE)
songs = []
for i in range(0, len(picked), 200):
    chunk = picked[i:i + 200]
    enc = urllib.parse.quote("[" + ",".join(str(x) for x in chunk) + "]", safe="")
    js = get("https://music.163.com/api/song/detail?ids=%s" % enc)
    songs.extend(js.get("songs") or [])

print("\n=== 逐首按播放链取源 ===")
print("%-28s %-10s %8s %8s %8s" % ("歌名", "总耗时", "api740", "探测", "api320"))
rows = []
for s in songs:
    sid = s.get("id")
    name = (s.get("name") or "")[:26]
    total0 = time.time()
    api740 = api320 = probe_ms = None
    url = ""
    try:
        t = time.time()
        j = get("https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest"
                "&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease"
                "&id=%s&br=740" % sid,
                {"User-Agent": "LX-Music-Mobile"}, timeout=8)
        api740 = int((time.time() - t) * 1000)
        url = j.get("url") or ""
        if url:
            probe_ms, n = probe(url)
    except Exception as e:  # noqa: BLE001
        api740 = -1
        url = ""
    try:
        t = time.time()
        get("https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest"
            "&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease"
            "&id=%s&br=320" % sid,
            {"User-Agent": "LX-Music-Mobile"}, timeout=8)
        api320 = int((time.time() - t) * 1000)
    except Exception:  # noqa: BLE001
        api320 = -1
    total = int((time.time() - total0) * 1000)
    ok = "有源" if url else "无源"
    print("%-30s %7dms %7sms %7sms %7sms  %s" % (name, total, api740, probe_ms or 0, api320, ok))
    rows.append((total, api740, probe_ms))

good = [r for r in rows if r[0] > 0]
if good:
    gaps = sorted(r[0] for r in good)
    mid = gaps[len(gaps) // 2]
    print("\n空档（取源+探测，即「音频停着、下一首还没开始」的时长）：")
    print("  中位 %d ms   最快 %d ms   最慢 %d ms   （样本 %d）"
          % (mid, gaps[0], gaps[-1], len(gaps)))
    over = [g for g in gaps if g > 1800]
    print("  超过 quickPick 1.8s 窗口的：%d/%d" % (len(over), len(gaps)))

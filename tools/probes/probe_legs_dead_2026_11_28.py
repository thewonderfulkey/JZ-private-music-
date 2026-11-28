# -*- coding: utf-8 -*-
"""2026-11-28 取证（第五组）：两条补充判断。

A. 「网易官方」这条主腿是不是整体死了 —— 拿几首确定有版权的歌打同一个端点。
   如果都回 code=404，那它不是"这首歌没源"，是整条腿不干活。
B. 《BABY ANGEL》还有没有别的腿能出真直链：
   gdstudio tencent / meting tencent / 落月 v3 多档 / 网易 meting。
   有 → 说明跨平台补位少了这一条，可以补；没有 → 这首歌确实全网无免费链。
"""
import json
import time
import urllib.parse

import requests

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")


def enc(s):
    return urllib.parse.quote(s)


def get(url, headers=None, timeout=15):
    h = {"User-Agent": UA}
    if headers:
        h.update(headers)
    try:
        return requests.get(url, headers=h, timeout=timeout, allow_redirects=True)
    except Exception:
        return None


def head(url):
    r = get(url, {"Range": "bytes=0-1023"}, 15)
    if r is None:
        return "取不到"
    return "HTTP %s %s" % (r.status_code, r.headers.get("Content-Type", "")[:22])


print("=" * 80)
print("A. 网易官方 player/url 是不是整体死了（几首肯定有版权的歌）")
print("=" * 80)
for kw in ["晴天 周杰伦", "稻香 周杰伦", "起风了 买辣椒也用券", "泡沫 邓紫棋"]:
    r = get("https://music.163.com/api/search/get?s=%s&type=1&offset=0&limit=1"
            % enc(kw), {"Referer": "https://music.163.com/"}, 8)
    if r is None:
        print("  %-18s 搜索失败" % kw)
        continue
    rows = ((r.json().get("result") or {}).get("songs")) or []
    if not rows:
        print("  %-18s 搜不到" % kw)
        continue
    sid = rows[0]["id"]
    r2 = get("https://music.163.com/api/song/enhance/player/url?ids=[%s]&br=320000" % sid,
             {"Referer": "https://music.163.com/"}, 10)
    try:
        d = (r2.json().get("data") or [{}])[0]
        print("  %-18s id=%-10s code=%-4s url=%s"
              % (kw, sid, d.get("code"), "有" if d.get("url") else "空"))
    except Exception:
        print("  %-18s 解析失败 %s" % (kw, r2.text[:60] if r2 else "None"))
    time.sleep(1.0)

print()
print("=" * 80)
print("B. BABY ANGEL 还有没有别的腿（跨平台/网易侧）")
print("=" * 80)
NAME, ARTIST = "BABY ANGEL", "林娜琏"

# B1 gdstudio tencent
r = get("https://music-api.gdstudio.xyz/api.php?types=search&source=tencent&name=%s"
        "&count=5&pages=1" % enc("%s %s" % (NAME, ARTIST)))
try:
    rows = r.json() if r else []
    print("  [gdstudio tencent 搜] %d 条" % len(rows))
    for it in (rows or [])[:3]:
        print("      %s | %s | id=%s" % (it.get("name"), it.get("artist"), it.get("id")))
    if rows:
        sid = rows[0].get("id")
        r2 = get("https://music-api.gdstudio.xyz/api.php?types=url&source=tencent&id=%s&br=320"
                 % sid)
        try:
            u = (r2.json() or {}).get("url") or ""
            print("      gdstudio url → %s  %s" % (u[:80] if u else "<空>",
                                                  head(u) if u else ""))
        except Exception:
            print("      gdstudio url 解析失败")
except Exception:
    print("  [gdstudio tencent 搜] 解析失败")

print()
# B2 meting tencent by mid
mid = "001JlSKM1G0bsg"
for server in ["tencent", "netease"]:
    u = "https://api.qijieya.cn/meting/?server=%s&type=url&id=%s" % (server, mid)
    r = get(u)
    try:
        j = r.json() if r else []
        item = j[0] if isinstance(j, list) and j else {}
        url = item.get("url") or ""
        print("  [meting %s] url=%s %s" % (server, url[:80] if url else "<空>",
                                           head(url) if url else ""))
    except Exception:
        print("  [meting %s] 非JSON %s" % (server, (r.text[:60] if r else "None")))
    time.sleep(1.0)

print()
# B3 落月 v3 多档
for q in [4, 8, 10]:
    r = get("https://api.vkeys.cn/music/tencent/song/link?mid=%s&quality=%d" % (mid, q),
            {"Referer": "https://y.qq.com/"})
    try:
        j = r.json() if r else {}
        d = j.get("data") or {}
        url = d.get("url") or ""
        print("  [落月 v3 q=%2d] code=%s url=%s %s"
              % (q, j.get("code"), url[:60] if url else "<空>", head(url) if url else ""))
    except Exception:
        print("  [落月 v3 q=%2d] 非JSON %s" % (q, (r.text[:60] if r else "None")))
    time.sleep(1.2)

print()
# B4 酷我（妖狐）
r = get("https://api.yaohud.cn/api/music/kuwo?msg=%s&n=1&type=json"
        % enc("%s %s" % (NAME, ARTIST)), {"Referer": "https://www.kuwo.cn/"})
try:
    j = r.json() if r else {}
    print("  [妖狐酷我] code=%s msg=%s" % (j.get("code"), str(j.get("msg"))[:60]))
    d = j.get("data") or {}
    url = d.get("url") or "" if isinstance(d, dict) else ""
    if url:
        print("      url=%s %s" % (url[:70], head(url)))
except Exception:
    print("  [妖狐酷我] 非JSON %s" % (r.text[:80] if r else "None"))

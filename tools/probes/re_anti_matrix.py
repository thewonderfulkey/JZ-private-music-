# -*- coding: utf-8 -*-
"""anti.s 音质档位矩阵 + 返回 URL 的真实可播性（Range 取首段字节）+ 多曲目覆盖率。"""
import io
import json
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_anti_matrix.txt"
UA = "kwplayer_ar_12.0.6.4"
RID = "456593448"
lines = []


def get(url, headers=None, timeout=15, nbytes=None):
    h = {"User-Agent": UA}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read(nbytes) if nbytes else r.read(800).decode("utf-8", "ignore")
        return r.status, body, r.headers


# ---- 1. 档位矩阵 ----
TIERS = [
    ("128kmp3", "mp3", "128kmp3"),
    ("192kmp3", "mp3", "192kmp3"),
    ("320kmp3", "mp3", "320kmp3"),
    ("flac", "flac", "2000kflac"),
    ("flac2", "flac", "flac"),
]
lines.append("== 档位矩阵 ==")
for name, fmt, br in TIERS:
    u = ("https://antiserver.kuwo.cn/anti.s?type=convert_url3&format=%s&response=url&br=%s&rid=%s"
         % (fmt, br, RID))
    try:
        st, body, _ = get(u)
        url = ""
        try:
            url = json.loads(body).get("url", "")
        except Exception:
            url = body if body.startswith("http") else ""
        lines.append("%-10s st=%s url=%s" % (name, st, url[:120]))
        if url:
            # 真取首段字节，确认是音频而不是错误页
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA, "Range": "bytes=0-1023"})
                with urllib.request.urlopen(req, timeout=15) as r2:
                    head = r2.read(16)
                ctype = r2.headers.get("Content-Type")
                crange = r2.headers.get("Content-Range")
                lines.append("           -> %s %s range=%s head=%r" % (r2.status, ctype, crange, head))
            except Exception as e:
                lines.append("           -> 取流失败 %s" % e)
    except Exception as e:
        lines.append("%-10s ERR %s" % (name, e))

# ---- 2. 多曲目覆盖率（用官方搜索取 rid） ----
lines.append("")
lines.append("== 覆盖率：周杰伦/陈奕迅/五月天，各 10 条，按 rid 请求 320k ==")
ok = tried = 0
for singer in ("周杰伦", "陈奕迅", "五月天"):
    q = urllib.parse.quote(singer)
    s = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=20&pn=0&vipver=MUSIC_8.7.8.0_WX" % q)
    try:
        _, body, _ = get(s)
        items = re.findall(r"MUSICRID='MUSIC_(\d+)'.*?SONGNAME='([^']*)'", body)
    except Exception as e:
        lines.append("%s 搜索失败 %s" % (singer, e))
        continue
    cnt = 0
    for rid, title in items[:10]:
        tried += 1
        u = ("https://antiserver.kuwo.cn/anti.s?type=convert_url3&format=mp3&response=url&br=320kmp3&rid=%s" % rid)
        try:
            _, b, _ = get(u, timeout=10)
            obj = json.loads(b)
            if obj.get("code") == 200 and obj.get("url", "").startswith("http"):
                ok += 1
                cnt += 1
        except Exception as e:
            lines.append("   %s %s -> %s" % (singer, title[:14], e))
    lines.append("%s 命中 %d/10" % (singer, cnt))
lines.append("TOTAL 命中 %d/%d" % (ok, tried))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))

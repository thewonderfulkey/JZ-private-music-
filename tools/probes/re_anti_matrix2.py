# -*- coding: utf-8 -*-
"""1) 看 search r.s 的真实字段格式；2) 多曲目 × 多档位，比较返回文件字节数，判断 br 是否被尊重。"""
import io
import json
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_anti_matrix2.txt"
UA = "kwplayer_ar_12.0.6.4"
lines = []


def fetch(url, headers=None, timeout=15, raw=False):
    h = {"User-Agent": UA}
    if headers:
        h.update(headers)
    with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=timeout) as r:
        return r.status, r.read() if raw else r.read().decode("utf-8", "ignore"), r.headers


s_url = "https://search.kuwo.cn/r.s?all=%s&ft=music&rn=20&pn=0&vipver=MUSIC_8.7.8.0_WX" % urllib.parse.quote("周杰伦")
_, sample, _ = fetch(s_url)
lines.append("== r.s 原始片段（1800 字符）==")
lines.append(sample[:1800].replace("\r", ""))
lines.append("")

rids = re.findall(r"MUSICRID=MUSIC_(\d+)", sample)
lines.append("解析到 rid 数：%d，前 6 个：%s" % (len(rids), rids[:6]))
lines.append("")

TIERS = [("128kmp3", "mp3", "128kmp3"), ("320kmp3", "mp3", "320kmp3"),
         ("flac", "flac", "2000kflac"), ("aac", "aac", "320kaac")]
lines.append("== 逐曲 × 档位（字节数比较）==")
for rid in rids[:5]:
    lines.append("rid=%s" % rid)
    for name, fmt, br in TIERS:
        u = ("https://antiserver.kuwo.cn/anti.s?type=convert_url3&format=%s&response=url&br=%s&rid=%s"
             % (fmt, br, rid))
        try:
            _, b, _ = fetch(u, timeout=12)
            obj = json.loads(b)
            url = obj.get("url", "")
            if not url:
                lines.append("   %-9s code=%s 无 url msg=%s" % (name, obj.get("code"), obj.get("msg")))
                continue
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA, "Range": "bytes=0-0"})
                with urllib.request.urlopen(req, timeout=12) as r2:
                    cr = r2.headers.get("Content-Range") or ""
                    total = cr.split("/")[-1] if cr else "?"
                    ctype = r2.headers.get("Content-Type")
                lines.append("   %-9s %s %s %sB" % (name, ctype, rid, total))
            except Exception as e:
                lines.append("   %-9s 取流失败 %s" % (name, e))
        except Exception as e:
            lines.append("   %-9s ERR %s" % (name, e))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))

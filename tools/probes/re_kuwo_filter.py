# -*- coding: utf-8 -*-
"""按 KuwoSearchAdapter 的真实解析与过滤口径（extractAbsList + &nbsp;解码 + 相关性 + 变体剔除）复算，
确认 App 里「酷我 0 条」到底是接口没给、还是我们本地过滤掉。"""
import io
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_kuwo_filter.txt"
lines = []

KW = "IVORY TOWER"
url = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=20&pn=1&rformat=json&encoding=utf8"
       "&vipver=MUSIC_8.7.8.0_WX" % urllib.parse.quote(KW))
req = urllib.request.Request(url, headers={"User-Agent": "kwplayer_ar_12.0.6.4", "Referer": "https://www.kuwo.cn/"})
with urllib.request.urlopen(req, timeout=15) as r:
    text = r.read().decode("utf-8", "ignore")

abs_idx = text.find("'abslist'")
rest = text[abs_idx:]
open_i = rest.find("[")
close_i = rest.rfind("]")
list_text = rest[open_i:close_i + 1]

VARIANT = ["伴奏", "ktv", "现场", "dj", "live", "翻唱", "纯音乐", "钢琴", "remix", "串烧", "mv版", "合唱", "网友改编", "咚鼓"]
pair = re.compile(r"'([^']*)':\s*'((?:[^'\\]|\\.)*)'")

def chunks(s):
    inner = s[1:-1]
    depth = 0
    cur = []
    out = []
    for ch in inner:
        if ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        elif ch == "," and depth == 0:
            out.append("".join(cur)); cur = []
            continue
        cur.append(ch)
    out.append("".join(cur))
    return [c for c in out if c.strip()]

kept = 0
total = 0
for c in chunks(list_text):
    c = c.strip()
    if not (c.startswith("{") and c.endswith("}")):
        continue
    m = {}
    for mm in pair.finditer(c[1:-1]):
        k, v = mm.group(1), mm.group(2).replace("\\'", "'").replace("&nbsp;", " ").replace("&amp;", "&")
        m[k] = v
    name = m.get("SONGNAME", "").strip()
    rid = m.get("MUSICRID", "").replace("MUSIC_", "")
    artist = m.get("ARTIST", "")
    if not name or not rid:
        continue
    total += 1
    reasons = []
    if KW and KW not in name and KW not in artist:
        reasons.append("相关性(kw=%r name=%r artist=%r)" % (KW, name, artist))
    low = name.lower()
    if any(x in low for x in VARIANT):
        reasons.append("变体")
    if reasons:
        lines.append("DROP %-6s %-58s | %-14s | %s" % (rid, name, artist, " + ".join(reasons)))
    else:
        kept += 1
        lines.append("KEEP %-6s %-58s | %-14s" % (rid, name, artist))

lines.insert(0, "总记录=%d 保留=%d 丢弃=%d" % (total, kept, total - kept))
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines[:40]))

# -*- coding: utf-8 -*-
"""酷我：原唱 rid=1307392909 到底在搜索结果哪一页（妖狐已证明该 rid 可播）；
   顺手确认字段是 NAME 还是 SONGNAME（两版响应都可能出现）。"""
import io
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_kuwo_orig_loc.txt"
L = []
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
TARGET = "1307392909"
PAIR = re.compile(r"'((?:[^'\\]|\\.)*)':\s*'((?:[^'\\]|\\.)*)'")


def get(url, ua=UA, ref="https://www.kuwo.cn/", timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Referer": ref})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


def chunks(s):
    inner = s[1:-1]
    depth, cur, out = 0, [], []
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
    return [c.strip() for c in out if c.strip()]


def parse(text):
    i = text.find("'abslist'")
    if i < 0:
        return []
    rest = text[i:]
    lst = rest[rest.find("["): rest.rfind("]") + 1]
    recs = []
    for c in chunks(lst):
        if not (c.startswith("{") and c.endswith("}")):
            continue
        m = {}
        for mm in PAIR.finditer(c[1:-1]):
            m[mm.group(1)] = mm.group(2).replace("\\'", "'").replace("&nbsp;", " ").replace("&amp;", "&")
        if m.get("MUSICRID"):
            recs.append(m)
    return recs


for kw, rn, pn in (("IVORY TOWER", 20, 1), ("IVORY TOWER", 100, 1), ("IVORY TOWER", 20, 2),
                   ("IVORY TOWER SennaRin", 100, 1), ("IVORY TOWER 澤野弘之", 100, 1)):
    u = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=%d&pn=%d&rformat=json&encoding=utf8"
         "&vipver=MUSIC_8.7.8.0_WX" % (urllib.parse.quote(kw), rn, pn))
    try:
        recs = parse(get(u))
    except Exception as e:
        L.append("kw=%r ERR %s" % (kw, e)); L.append(""); continue
    keys = set()
    for r in recs:
        keys |= {"NAME"} if "NAME" in r else set()
        keys |= {"SONGNAME"} if "SONGNAME" in r else set()
    pos = [i for i, r in enumerate(recs, 1) if r.get("MUSICRID", "").replace("MUSIC_", "") == TARGET]
    L.append("== kw=%r rn=%d pn=%d → %d 条（字段 %s）｜原唱位置：%s ==" % (kw, rn, pn, len(recs), "/".join(sorted(keys)), pos or "无"))
    for i, r in enumerate(recs[:20], 1):
        name = r.get("NAME") or r.get("SONGNAME") or ""
        L.append("   %2d. %-11s %-42s %-20s %ss" % (i, r.get("MUSICRID", "").replace("MUSIC_", ""),
                                                    name[:40], r.get("ARTIST", "")[:18], r.get("DURATION", "")))
    L.append("")

io.open(OUT, "w", encoding="utf-8").write("\n".join(L) + "\n")
print("done")

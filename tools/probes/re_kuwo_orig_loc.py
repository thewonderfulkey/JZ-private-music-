# -*- coding: utf-8 -*-
"""更正：酷我 r.s 的字段是 NAME（不是 SONGNAME）。重新核对原唱 rid=1307392909 在搜索结果里的位置。"""
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_kuwo_orig_loc.txt"
L = []
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
PAIR = re.compile(r"'([^']*)':\s*'((?:[^'\\]|\\.)*)'")


def get(url, ua=UA, ref="https://www.kuwo.cn/", timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Referer": ref})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


def parse(text):
    i = text.find("'abslist'")
    if i < 0:
        return [], ""
    body = text[i:]
    body = body[body.find("["): body.rfind("]") + 1]
    recs = []
    for ch in re.findall(r"\{[^{}]*\}", body):
        m = {k: v.replace("\\'", "'").replace("&nbsp;", " ") for k, v in PAIR.findall(ch)}
        if m.get("NAME"):
            recs.append(m)
    return recs, ""


def q(kw, rn=20, pn=1):
    u = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=%d&pn=%d&rformat=json&encoding=utf8"
         "&vipver=MUSIC_8.7.8.0_WX" % (urllib.parse.quote(kw), rn, pn))
    text = get(u)
    return parse(text)


TARGET = "1307392909"
for kw, rn, pn in (("IVORY TOWER", 20, 1), ("IVORY TOWER", 100, 1), ("IVORY TOWER SennaRin", 100, 1),
                   ("IVORY TOWER 澤野弘之", 100, 1), ("IVORY TOWER 龙族", 100, 1)):
    recs, _ = q(kw, rn, pn)
    L.append("== kw=%r rn=%d pn=%d → %d 条 ==" % (kw, rn, pn, len(recs)))
    idx = [i for i, r in enumerate(recs, 1) if r.get("MUSICRID", "").replace("MUSIC_", "") == TARGET]
    L.append("   目标原唱出现在第 %s 位" % (idx or "无"))
    for i, r in enumerate(recs[:25], 1):
        L.append("   %2d. rid=%-11s %-42s %-20s %ss" % (
            i, r.get("MUSICRID", "").replace("MUSIC_", ""), r.get("NAME", "")[:40],
            r.get("ARTIST", "")[:18], r.get("DURATION", "")))
    L.append("")

open(OUT, "w", encoding="utf-8").write("\n".join(L) + "\n")
print("done")

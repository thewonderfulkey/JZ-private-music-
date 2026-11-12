# -*- coding: utf-8 -*-
"""酷我搜索为什么不给《IVORY TOWER》原唱（rid 1307392909，妖狐已证明可播）：
   ① 复测 r.s 是否只是这几次空；② 换 rn/关键词/排序看原唱能不能进结果。
"""
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_kuwo_search_gap.txt"
L = []
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
TARGET_RID = "1307392909"


def get(url, ua=UA, ref="https://www.kuwo.cn/", timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Referer": ref})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


PAIR = re.compile(r"'([^']*)':\s*'((?:[^'\\]|\\.)*)'")


def parse(text):
    i = text.find("'abslist'")
    if i < 0:
        return [], text[:200]
    body = text[i:]
    body = body[body.find("["): body.rfind("]") + 1]
    recs = []
    for ch in re.findall(r"\{[^{}]*\}", body):
        m = {k: v.replace("\\'", "'").replace("&nbsp;", " ") for k, v in PAIR.findall(ch)}
        if m.get("SONGNAME"):
            recs.append(m)
    return recs, ""


def probe(tag, kw, rn=20, pn=1, extra=""):
    u = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=%d&pn=%d&rformat=json&encoding=utf8"
         "&vipver=MUSIC_8.7.8.0_WX%s" % (urllib.parse.quote(kw), rn, pn, extra))
    try:
        text = get(u)
    except Exception as e:
        L.append("[%s] kw=%r ERR %s" % (tag, kw, e))
        return
    recs, head = parse(text)
    hit = [r for r in recs if r.get("MUSICRID", "").replace("MUSIC_", "") == TARGET_RID]
    L.append("[%s] kw=%r rn=%d pn=%d → 记录 %d 条，含目标原唱 rid=%s：%s" % (
        tag, kw, rn, pn, len(recs), TARGET_RID, "是" if hit else "否"))
    if head:
        L.append("     原始片段：%s" % head.replace("\n", " "))
    for r in recs[:6]:
        L.append("     %-11s %-40s %-18s %ss" % (r.get("MUSICRID", "").replace("MUSIC_", ""),
                                                  r.get("SONGNAME", "")[:38], r.get("ARTIST", "")[:16],
                                                  r.get("DURATION", "")))
    if recs:
        L.append("     末条：%s" % recs[-1].get("SONGNAME", "")[:50])


L.append("== 酷我 r.s 复测（同一查询连跑两条，判是不是被限流/假空） ==")
probe("A1", "IVORY TOWER")
probe("A2", "IVORY TOWER")
probe("B1", "IVORY TOWER", rn=100)
probe("B2", "IVORY TOWER 龙族", rn=100)
probe("B3", "IVORY TOWER SennaRin", rn=100)
probe("B4", "IVORY TOWER feat. SennaRin", rn=100)
probe("B5", "The Ivory Tower 澤野弘之", rn=100)
probe("C1", "IVORY TOWER", rn=20, pn=2)
probe("C2", "IVORY TOWER", rn=20, pn=3)

L.append("")
L.append("== 换 UA（kwplayer 安卓客户端）复测 ==")
probe_ua = "kwplayer_ar_12.0.6.4"
u = "https://search.kuwo.cn/r.s?all=%s&ft=music&rn=100&pn=1&rformat=json&encoding=utf8&vipver=MUSIC_8.7.8.0_WX" % urllib.parse.quote("IVORY TOWER")
try:
    text = get(u, ua=probe_ua)
    recs, head = parse(text)
    hit = [r for r in recs if r.get("MUSICRID", "").replace("MUSIC_", "") == TARGET_RID]
    L.append("kwplayer UA → 记录 %d 条，含目标：%s" % (len(recs), "是" if hit else "否"))
except Exception as e:
    L.append("kwplayer UA ERR %s" % e)

open(OUT, "w", encoding="utf-8").write("\n".join(L) + "\n")
print("\n".join(L))

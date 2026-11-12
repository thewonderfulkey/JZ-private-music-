# -*- coding: utf-8 -*-
"""核对两件事：
1) 酷我是不是真有《IVORY TOWER》原唱条目（笒音是单源酷我，它播出来了，条目应存在）；
2) 我方现在的酷我取流后端（妖狐，按"歌名+歌手"搜索）能不能取到同一条。
"""
import json
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_kuwo_ivorytower.txt"
L = []
UA_I = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"


def get(url, ua=UA_I, ref="https://www.kuwo.cn/", timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Referer": ref})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


PAIR = re.compile(r"'([^']*)':\s*'((?:[^'\\]|\\.)*)'")


def kuwo_search(kw, rn=20):
    u = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=%d&pn=1&rformat=json&encoding=utf8"
         "&vipver=MUSIC_8.7.8.0_WX" % (urllib.parse.quote(kw), rn))
    text = get(u)
    i = text.find("'abslist'")
    body = text[i:]
    body = body[body.find("["): body.rfind("]") + 1]
    recs = []
    for ch in re.findall(r"\{[^{}]*\}", body):
        m = {k: v.replace("\\'", "'").replace("&nbsp;", " ") for k, v in PAIR.findall(ch)}
        if m.get("SONGNAME"):
            recs.append(m)
    return recs


for kw in ("IVORY TOWER", "IVORY TOWER 澤野弘之", "IVORY TOWER 泽野弘之"):
    L.append("== 酷我 r.s 关键词：%s ==" % kw)
    try:
        recs = kuwo_search(kw)
        L.append("返回 %d 条" % len(recs))
        for r in recs:
            L.append("   %-12s | %-46s | %-22s | %ss | %s" % (
                r.get("MUSICRID", "").replace("MUSIC_", ""), r.get("SONGNAME", "")[:44],
                r.get("ARTIST", "")[:20], r.get("DURATION", ""), r.get("FORMAT", "")))
    except Exception as e:
        L.append("ERR %s" % e)
    L.append("")

L.append("== 妖狐酷我（我方现用取流后端，action=search，按歌名+歌手） ==")
for msg in ("IVORY TOWER澤野弘之", "IVORY TOWERSennaRin", "IVORY TOWER"):
    u = ("https://api.yaohud.cn/api/music/kuwo?key=nvgKtvzw7CFSNFrDhA6&action=search&msg=%s&n=1"
         % urllib.parse.quote(msg))
    try:
        js = json.loads(get(u, ua=UA_I, ref="https://api.yaohud.cn/"))
        d = js.get("data") or {}
        L.append("msg=%r code=%s songtitle=%r songname=%r level=%r url=%s" % (
            msg, js.get("code"), d.get("songtitle"), d.get("songname"),
            (d.get("vipmusic") or {}).get("level"), ((d.get("vipmusic") or {}).get("url") or "")[:90]))
    except Exception as e:
        L.append("msg=%r ERR %s" % (msg, e))

open(OUT, "w", encoding="utf-8").write("\n".join(L) + "\n")
print("\n".join(L))

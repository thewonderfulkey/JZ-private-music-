# -*- coding: utf-8 -*-
"""用真实接口数据复算 v2.1.88 的两条新口径（离线，不依赖设备）：
A) 识曲《IVORY TOWER》/澤野弘之、SennaRin → 按「核心歌名 + 歌手」能不能落到可播原唱；
B) 酷我「IVORY TOWER」在小写关键词下，新的大小写不敏感过滤能保留多少条（旧口径会整平台判空）。
"""
import io
import json
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_v2188_rules.txt"
lines = []
UA_QQ = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"


def get(url, ua=UA_QQ, ref="https://y.qq.com/", timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Referer": ref})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


# ---------- StudioPick.coreName / 归一化的 Python 复刻 ----------
BRACKET = re.compile(r"（[^）]*）|\([^)]*\)|\[[^]]*]|【[^】]*】")
EDIT = re.compile(
    r"\s*[-—–·]?\s*(伴奏|钢琴版|吉他版|翻唱|cover|live|现场版|现场|演唱会|音乐会|remix|dj版|dj|电音|串烧|"
    r"合唱版|合唱|纯音乐|钢琴|混音|重制|ktv|对唱|说唱|beat|instrumental|片段|剪辑|消音|学唱|"
    r"咚鼓|童声|古筝|学唱版|版本[0-9一二三四五六七八九十]+).*$", re.I)
QUOTED = re.compile(r"[\"'“”‘’「」『』]([^\"'“”‘’「』『」]*)[\"'“”‘’「」『』]")
PUNCT = re.compile(r"[\s\p{Punct}·、，。（）()【】《》\[\]、]" if False else r"[\s!-/:-@\[-`{-~·、，。（）()【】《》\[\]、]")


def core_name(raw):
    n = raw.strip()
    if not n:
        return ""
    n = BRACKET.sub("", n)
    n = re.sub(r"\s+", " ", n).strip()
    m = QUOTED.search(n)
    if m and m.group(1).strip():
        n = m.group(1).strip()
    n = EDIT.sub("", n).strip()
    n = re.sub(r"\s*[-—–·]\s*$", "", n).strip()
    return n


def core_key(raw):
    return PUNCT.sub("", core_name(raw).lower())


def singer_tokens(raw):
    s = BRACKET.sub("", raw.strip().lower())
    parts = re.split(r"[/&、,，\s]+", s)
    return {PUNCT.sub("", p) for p in parts if PUNCT.sub("", p)}


def singer_match(a, b):
    ta, tb = singer_tokens(a), singer_tokens(b)
    if not ta or not tb:
        return True
    if ta & tb:
        return True
    sa, sb = "".join(sorted(ta)), "".join(sorted(tb))
    return sa in sb or sb in sa


VARIANT = re.compile(r"伴奏|伴唱|纯音乐|instrumental|钢琴|翻唱|cover|remix|live|现场|演唱会|片段|剪辑|ktv|dj|消音|合唱", re.I)

# ---------- A：QQ 搜索结果（与 App 同关键词：歌名 + 歌手） ----------
HIT_TITLE = "IVORY TOWER"
HIT_ARTIST = "澤野弘之、SennaRin"
kw = HIT_TITLE + " " + HIT_ARTIST
url = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=30&w=%s&format=json" % urllib.parse.quote(kw)
lines.append("== A. QQ 搜索 keyword=%r ==" % kw)
try:
    js = json.loads(get(url))
    songs = ((js.get("data") or {}).get("song") or {}).get("list") or []
    lines.append("返回 %d 条" % len(songs))
    core = core_key(HIT_TITLE)
    hits = []
    for it in songs:
        name = it.get("songname", "")
        singers = "/".join((s.get("name") or "") for s in (it.get("singer") or []))
        dur = it.get("interval", 0)
        same_core = core_key(name) == core
        same_singer = singer_match(HIT_ARTIST, singers)
        variant = bool(VARIANT.search(name))
        flag = "AUTOPLAY" if (same_core and same_singer and not variant) else ("同曲非原唱" if same_core else "")
        if same_core:
            hits.append((name, singers, dur, same_singer, variant))
            lines.append("   %-44s | %-24s | %ss core=%s singer=%s variant=%s → %s" % (
                name, singers, dur, same_core, same_singer, variant, flag or "-"))
    playable = [h for h in hits if h[3] and not h[4]]
    lines.append("结论：可自动起播 %d 条；首选=%s" % (len(playable), playable[0][:2] if playable else "无"))
except Exception as e:
    lines.append("QQ ERR %s" % e)
lines.append("")

# ---------- B：酷我小写关键词 ----------
lines.append("== B. 酷我小写关键词过滤（新口径 vs 旧口径） ==")


def kuwo(keyword):
    u = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=20&pn=1&rformat=json&encoding=utf8"
         "&vipver=MUSIC_8.7.8.0_WX" % urllib.parse.quote(keyword))
    text = get(u, ref="https://www.kuwo.cn/")
    idx = text.find("'abslist'")
    rest = text[idx:]
    op, cl = rest.find("["), rest.rfind("]")
    body = rest[op:cl + 1]
    pair = re.compile(r"'([^']*)':\s*'((?:[^'\\]|\\.)*)'")
    records = []
    for ch in re.findall(r"\{[^{}]*\}", body):
        m = {k: v.replace("\\'", "'").replace("&nbsp;", " ").replace("&amp;", "&") for k, v in pair.findall(ch)}
        records.append(m)
    return records


for q in ("ivory tower", "Ivory Tower", "IVORY TOWER"):
    recs = kuwo(q)
    old = sum(1 for r in recs if q in r.get("SONGNAME", "") or q in r.get("ARTIST", ""))
    new = sum(1 for r in recs if q.lower().replace("  ", " ") in re.sub(r"\s+", " ", r.get("SONGNAME", "")).lower()
              or q.lower() in re.sub(r"\s+", " ", r.get("ARTIST", "")).lower())
    lines.append("  关键词 %-12r 记录=%d 旧口径保留=%d 新口径保留=%d" % (q, len(recs), old, new))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))

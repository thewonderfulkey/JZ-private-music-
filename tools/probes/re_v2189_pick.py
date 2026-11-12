# -*- coding: utf-8 -*-
"""复算 v2.1.89 的起播判定：识曲《我们都一样》张杰、胡迪、范如臣 /《异口同声 第十二期》
   ① 新查询词「我们都一样 张杰」能捞到哪条；② 按 REC_VARIANT 剔除 + StudioPick.studioScore 择优后会选谁。"""
import json
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_v2189_pick.txt"
L = []
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"


def get(url, ref, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": ref})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


BRACKET = re.compile(r"（[^）]*）|\([^)]*\)|\[[^]]*]|【[^】]*】")
EDIT = re.compile(
    r"\s*[-—–·]?\s*(伴奏|钢琴版|吉他版|翻唱|cover|live|现场版|现场|演唱会|音乐会|remix|dj版|dj|电音|串烧|"
    r"合唱版|合唱|纯音乐|钢琴|混音|重制|ktv|对唱|说唱|beat|instrumental|片段|剪辑|消音|学唱|"
    r"咚鼓|童声|古筝|学唱版|版本[0-9一二三四五六七八九十]+).*$", re.I)
QUOTED = re.compile(r"[\"'“”‘’「」『』]([^\"'“”‘’「」『』]*)[\"'“”‘’「」『』]")
LIVE = re.compile(r"现场|演唱会|音乐会|春晚|春节|联欢|跨年|晚会|盛典|颁奖|综艺|节目|直播|live|concert|unplugged|新声代|天赐|蒙面|我们的歌|声生不息|歌手20", re.I)
VARIANT = re.compile(r"伴奏|伴唱|纯音乐|instrumental|钢琴|翻唱|cover|remix|live|现场|演唱会|片段|剪辑|ktv|dj|消音|合唱", re.I)
MULTI = re.compile(r"[/&、,，;；]")


def core(raw):
    n = raw.strip()
    if not n:
        return ""
    n = BRACKET.sub("", n)
    n = re.sub(r"\s+", " ", n).strip()
    q = QUOTED.search(n)
    if q and q.group(1).strip():
        n = q.group(1).strip()
    n = EDIT.sub("", n).strip()
    return re.sub(r"\s*[-—–·]\s*$", "", n).strip()


def key(raw):
    return re.sub(r"[\s!-/:-@\[-`{-~·、，。（）()【】《》\[\]、]", "", core(raw).lower())


def clean(name):
    return core(name).lower() == name.strip().lower()


def singers(raw):
    s = BRACKET.sub("", raw.lower())
    return {re.sub(r"[\s!-/:-@\[-`{-~·、，。]", "", p) for p in re.split(r"[/&、,，\s]+", s) if p.strip()}


def singer_match(a, b):
    ta, tb = singers(a), singers(b)
    if not ta or not tb:
        return True
    return bool(ta & tb)


def consensus(durs):
    if len(durs) < 2:
        return None
    buckets = {}
    for d in durs:
        buckets.setdefault(d // 10, []).append(d)
    b = max(buckets.items(), key=lambda kv: len(kv[1]))
    if len(b[1]) < 2:
        return None
    return sorted(b[1])[len(b[1]) // 2]


def score(name, singer, album, dur, cons):
    s = 0
    s += 100 if clean(name) else -60
    if album and LIVE.search(album):
        s -= 80
    elif album.strip():
        s += 15
    if cons and dur:
        diff = abs(dur - cons)
        s += 40 if diff <= 12 else (0 if diff <= 30 else -70)
    s += -12 if MULTI.search(singer.strip()) else 10
    s -= len(name.strip()) // 6
    return s


HIT_TITLE = "我们都一样"
HIT_ARTIST = "张杰、胡迪、范如臣"
TITLE_KEY = key(HIT_TITLE)
PRIMARY = re.split(r"[/、,，&·|]", HIT_ARTIST)[0].strip()

for kw, tag in ((HIT_TITLE + " " + PRIMARY, "新口径（歌名+第一位歌手）"),
                (HIT_TITLE + " " + HIT_ARTIST, "旧口径（歌名+全部歌手）")):
    L.append("== %s：kw=%r ==" % (tag, kw))
    u = "https://music.163.com/api/search/get?s=%s&type=1&limit=30&offset=0" % urllib.parse.quote(kw)
    js = json.loads(get(u, "https://music.163.com/"))
    rows = []
    for it in ((js.get("result") or {}).get("songs") or []):
        rows.append((it.get("name", ""), "/".join(a.get("name", "") for a in (it.get("artists") or [])),
                     it.get("album", {}).get("name", ""), int((it.get("duration") or 0) / 1000)))
    cand = [r for r in rows if key(r[0]) == TITLE_KEY and singer_match(HIT_ARTIST, r[1]) and not VARIANT.search(r[0])]
    L.append("  网易返回 %d 条，同曲且歌手匹配且非变体 → 候选 %d 条" % (len(rows), len(cand)))
    for r in cand:
        L.append("     %-22s | %-16s | %-30s | %ss | clean=%s liveAlbum=%s" % (
            r[0][:20], r[1][:14], r[2][:28], r[3], clean(r[0]), bool(LIVE.search(r[2]))))
    if cand:
        cons = consensus([r[3] for r in cand])
        ranked = sorted(((score(*r, cons), r) for r in cand), key=lambda t: -t[0])
        L.append("    共识时长=%s ｜ 择优首选 = %s / %s / %s（分 %d）" % (
            cons, ranked[0][1][0], ranked[0][1][1], ranked[0][1][2], ranked[0][0]))
    L.append("")

open(OUT, "w", encoding="utf-8").write("\n".join(L) + "\n")
print("done")

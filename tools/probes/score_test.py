# 与 RecognizeScore.kt 同构的 Python 复算，用真实/半真实夹具验证排序
import json, re

BRACKET = re.compile(r"（[^）]*）|\([^)]*\)|\[[^]]*]|【[^】]*】")
EDIT_SUFFIX = re.compile(
    r"\s*[-—–·]?\s*(伴奏|钢琴版|吉他版|翻唱|cover|live|现场版|现场|演唱会|音乐会|remix|dj版|dj|电音|串烧|"
    r"合唱版|合唱|纯音乐|钢琴|混音|重制|ktv|对唱|说唱|beat|instrumental|片段|剪辑|消音|学唱|"
    r"咚鼓|童声|古筝|学唱版|版本[0-9一二三四五六七八九十]+).*$", re.I)
LIVE_ALBUM = re.compile(
    r"现场|演唱会|音乐会|春晚|春节|联欢|跨年|晚会|盛典|颁奖|综艺|节目|直播|"
    r"live|concert|unplugged|新声代|天赐|蒙面|我们的歌|声生不息|歌手20", re.I)
VARIETY_ALBUM = re.compile(r"综艺|异口同声|节目|第[0-9一二三四五六七八九十]+期|演唱会|音乐节|晚会|春晚|live|现场", re.I)


def core_name(raw):
    n = raw.strip()
    if not n:
        return ""
    n = BRACKET.sub("", n)
    n = re.sub(r"\s+", " ", n).strip()
    m = re.search(r"[\"'“”‘’「」『』]([^\"'“”‘’「」『』]*)[\"'“”‘’「」『』]", n)
    if m and m.group(1).strip():
        n = m.group(1).strip()
    n = EDIT_SUFFIX.sub("", n).strip()
    n = re.sub(r"\s*[-—–·]\s*$", "", n).strip()
    return n


def norm(s):
    return re.sub(r"[\s\W_·、，。（）()【】《》\[\]、]", "", s.lower())


def is_clean_title(n):
    return bool(n.strip()) and core_name(n).lower() == n.strip().lower()


def is_same_album_title(album, title):
    a, t = norm(album), norm(title)
    return bool(a and t) and (a == t or a.startswith(t))


def member_score(c):
    s = 0
    s += {1: 45, 2: -30}.get(c["is_original"], 0)
    s += 12 if is_clean_title(c["title"]) else -35
    album = c["album"].strip()
    if not album:
        s -= 8
    elif is_same_album_title(album, c["title"]):
        s -= 20
    elif VARIETY_ALBUM.search(album) or LIVE_ALBUM.search(album):
        s -= 28
    else:
        s += 15
    if 30 <= c["duration"] <= 1800:
        s += 4
    s += max(0, 7 - c["rank"] * 2)
    if c["source"] == "netease":
        s += 2
    return s


def fuse(kugou, netease):
    allc = [c for c in (kugou + netease) if c["title"].strip()]
    groups = {}
    for c in allc:
        key = core_name(c["title"]) or c["title"]
        key = norm(key) + "|" + norm(re.split(r"[/、,，&·|]", c["artist"])[0])
        groups.setdefault(key, []).append(c)
    items = []
    for members in groups.values():
        rep = max(members, key=member_score)
        score = member_score(rep)
        channels = {c["source"] for c in members}
        if len(channels) >= 2:
            score += 50
        formal = {norm(c["album"]) for c in members
                  if c["album"].strip() and not is_same_album_title(c["album"], c["title"])
                  and not VARIETY_ALBUM.search(c["album"]) and not LIVE_ALBUM.search(c["album"])}
        durs = sorted(c["duration"] for c in members if c["duration"] > 0)
        confirmed = len(durs) >= 2 and durs[-1] - durs[0] <= 3
        if len(formal) >= 2 and confirmed:
            score += 22
        items.append((score, rep, channels, len(formal), confirmed))
    items.sort(key=lambda t: (-t[0], {1: 0, 0: 1, -1: 1}.get(t[1]["is_original"], 2), len(t[1]["title"]), t[1]["rank"]))
    best = {}
    for c in allc:
        best[c["source"]] = max(best.get(c["source"], -10**9), member_score(c))
    return items, best


def show(name, kugou, netease):
    items, best = fuse(kugou, netease)
    print(f"\n== {name}")
    print(f"   channel best: 酷狗={best.get('kugou','—')} 网易={best.get('netease','—')}")
    for score, rep, ch, formal, confirmed in items[:5]:
        print(f"   {score:4d}  {rep['title']} / {rep['artist']} / {rep['album'] or '-'} "
              f"({rep['duration']}s, {rep['source']}, orig={rep['is_original']}, "
              f"channels={'+'.join(sorted(ch))}, formalAlbums={formal}, durOK={confirmed})")


S = lambda t, a, al, d, src, r, o: dict(title=t, artist=a, album=al, duration=d, source=src, rank=r, is_original=o)

# A. 真实：酷狗 5 条（2026-11-12 实抓）+ 网易 3 条（ncm_case1 实抓）
A_kg = [
    S("晴天", "周杰伦", "叶惠美", 269, "kugou", 0, 1),
    S("晴天", "凌霄(庄云霄)", "继续寻找周杰伦", 269, "kugou", 1, 2),
    S("晴天", "HanMoon", "", 0, "kugou", 2, 0),
    S("晴天", "小柒", "抖音热歌飙升榜", 0, "kugou", 3, 0),
    S("晴天", "77z", "", 162, "kugou", 4, 2),
]
A_ne = [
    S("丹尼尔在的晴天", "丹尼尔辛巴巴、鸡夫斯基", "丹尼尔在的晴天", 118, "netease", 0, -1),
    S("晴天", "王先森", "鸭力大呀", 314, "netease", 1, -1),
    S("晴天", "雷米克斯", "晴天", 125, "netease", 2, -1),
]
show("A 晴天：酷狗有 is_original，网易全是翻唱", A_kg, A_ne)

# B. 用户场景：酷狗只给翻唱（无原唱标记），网易给张杰两条正式专辑
B_kg = [S("我们都一样", "神仙哥哥", "我们都一样", 302, "kugou", 0, 2)]
B_ne = [
    S("我们都一样", "张杰", "明天过后", 302, "netease", 0, -1),
    S("我们都一样", "张杰", "One Chance 新歌+精选", 303, "netease", 1, -1),
    S("我们都一样", "橘子妹", "我们都一样", 298, "netease", 2, -1),
]
show("B 我们都一样：酷狗翻唱 vs 网易原唱", B_kg, B_ne)

# C/D 单通道
show("C 只有酷狗", A_kg, [])
show("D 只有网易", [], A_ne)

# E 双通道同一条
E_ne = [S("晴天", "周杰伦", "叶惠美", 269, "netease", 0, -1)]
show("E 双通道互证", A_kg[:1], E_ne)

# F 综艺现场命中（识曲认成节目版）
F_kg = [S("我们都一样", "张杰、胡迪、范如臣", "异口同声 第十二期", 268, "kugou", 0, 2)]
show("F 命中综艺版", F_kg, B_ne)

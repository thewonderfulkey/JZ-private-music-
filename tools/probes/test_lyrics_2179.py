# -*- coding: utf-8 -*-
"""v2.1.79 歌词逐字解析回归：用真实酷狗 KRC 明文，按 Kotlin 侧 krcToLines / 视图映射的同一逻辑复算。
目的：证明"落码后逐字时间真的能解析出来、且能一对一映射到字形"，不是只看编译通过。"""
import base64, hashlib, json, time, urllib.parse, urllib.request, zlib, re

SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
KEY = bytes([ord('@'), ord('G'), ord('a'), ord('w'), ord('^'), ord('2'), ord('t'), ord('G'),
             ord('Q'), ord('6'), ord('1'), ord('-'), 0xCE, 0xD2, ord('n'), ord('i')])

def md5(s): return hashlib.md5(s.encode("utf-8")).hexdigest()

def q(extra, module, mid):
    p = dict(extra)
    if module == "Lyric":
        p.update({"appid": "3116", "clientver": "11070"})
    else:
        p.update({"userid": "0", "appid": "3116", "token": "", "clienttime": int(time.time()),
                  "iscorrection": "1", "uuid": "-", "mid": mid, "dfid": "-",
                  "clientver": "11070", "platform": "AndroidFilter"})
    sig = md5(SALT + "".join("%s=%s" % (k, p[k]) for k in sorted(p)) + SALT)
    return "&".join("%s=%s" % (k, urllib.parse.quote(str(p[k]))) for k in sorted(p)) + "&signature=" + sig

def get(url, module, mid):
    req = urllib.request.Request(url, headers={
        "User-Agent": "Android14-1070-11070-201-0-%s-wifi" % module,
        "KG-Rec": "1", "KG-RC": "1", "KG-CLIENTTIMEMS": str(int(time.time() * 1000)), "mid": mid})
    return json.loads(urllib.request.urlopen(req, timeout=8).read().decode("utf-8", "replace"))

fails = []
def ck(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("  | " + detail if detail else ""))
    if not ok:
        fails.append(name)

mid = md5(str(int(time.time() * 1000)))
kw = "周杰伦 暗号"
u = "http://complexsearch.kugou.com/v2/search/song?" + q(
    {"sorttype": "0", "keyword": kw, "pagesize": 5, "page": 1}, "SearchSong", mid)
c0 = get(u, "SearchSong", mid)["data"]["lists"][0]
lj = get("https://lyrics.kugou.com/v1/search?" + q(
    {"album_audio_id": c0["ID"], "duration": int(c0["Duration"]) * 1000, "hash": c0["FileHash"],
     "keyword": kw, "lrctxt": "1", "man": "no"}, "Lyric", mid), "Lyric", mid)
cand = lj["candidates"][0]
dj = get("http://lyrics.kugou.com/download?" + q(
    {"accesskey": cand["accesskey"], "charset": "utf8", "client": "mobi", "fmt": "krc",
     "id": cand["id"], "ver": "1"}, "Lyric", mid), "Lyric", mid)
raw = base64.b64decode(dj["content"])
print("contenttype:", dj.get("contenttype"), "bytes:", len(raw))
if dj.get("contenttype") == 2:
    plain = raw.decode("utf-8", "replace")
else:
    x = bytes(b ^ KEY[i % 16] for i, b in enumerate(raw[4:]))
    plain = zlib.decompress(x).decode("utf-8", "replace")

# ---- 复刻 Kotlin krcToLines（同一正则、同一换算） ----
lineRe = re.compile(r"^\[(\d+),(\d+)\](.*)$")
wordRe = re.compile(r"<(\d+),(\d+),\d+>((?:.(?!\d+,\d+,\d+>))*)$")
# 注：Kotlin 侧无 $ 锚（与 krcToLrc 一致），这里两种都测，取不锚版为主
wordReNoAnchor = re.compile(r"<(\d+),(\d+),\d+>((?:.(?!\d+,\d+,\d+>))*)")


def krc_to_lines(p, wre):
    out = []
    for raw_line in p.splitlines():
        line = raw_line.strip()
        if not line.startswith("["):
            continue
        m = lineRe.match(line)
        if not m:
            continue
        lstart = int(m.group(1))
        words = []
        for w in wre.finditer(m.group(3)):
            s, d, t = int(w.group(1)), int(w.group(2)), w.group(3)
            if t:
                words.append((t, lstart + s, d))
        if not words:
            continue
        out.append((lstart, "".join(t for t, _, _ in words).rstrip(), words))
    return sorted(out, key=lambda r: r[0])


lines = krc_to_lines(plain, wordReNoAnchor)
ck("parsed lines >= 6", len(lines) >= 6, "lines=%d" % len(lines))
ck("all lines carry words", all(len(r[2]) > 0 for r in lines))
ck("word abs time = lineStart + rel", all(w[1] >= r[0] for r in lines for w in r[2]))
ck("anchored regex same count", len(krc_to_lines(plain, wordRe)) == len(lines),
   "anchored=%d unanchored=%d" % (len(krc_to_lines(plain, wordRe)), len(lines)))

# 定位那行 12 字（实测 start=16211「我想要的 想做的 你比谁都了」）
target = [r for r in lines if r[0] == 16211]
ck("line 16211 found", bool(target))
if target:
    t = target[0]
    ck("12 words", len(t[2]) == 12, "n=%d" % len(t[2]))
    ck("text matches", t[1] == "我想要的 想做的 你比谁都了", t[1])
    first = t[2][0]
    last = t[2][-1]
    ck("first word abs == 16211", first[1] == 16211, str(first[1]))
    ck("last word ends ~19702", last[1] + last[2] == 16211 + 3298 + 193,
       "%d" % (last[1] + last[2]))
    print("  words:", [(w[0], w[1] - 16211, w[2]) for w in t[2]])

# ---- 复刻视图 buildCharTimes（逐字→字符映射） ----
def build_char_times(text, words):
    cs = [None] * len(text)
    ce = [None] * len(text)
    wi = 0
    wci = 0
    for i, ch in enumerate(text):
        if ch == ' ':
            continue
        while wi < len(words) and words[wi][0].strip() == "":
            wi += 1
            wci = 0
        if wi >= len(words):
            return cs, ce, False
        w = words[wi]
        k = max(1, len([c for c in w[0] if c != ' ']))
        step = w[2] // k
        cs[i] = w[1] + step * wci
        ce[i] = cs[i] + step
        wci += 1
        if wci >= k:
            wi += 1
            wci = 0
    return cs, ce, any(x is not None for x in cs)


if target:
    t = target[0]
    cs, ce, ok = build_char_times(t[1], t[2])
    ck("char mapping built", ok)
    ck("no unmapped visible char",
       all(cs[i] is not None for i, c in enumerate(t[1]) if c != ' '),
       "unmapped=%d" % sum(1 for i, c in enumerate(t[1]) if c != ' ' and cs[i] is None))
    # 播放位置 17000ms（该行已唱到「的」的中段）→ 逐字亮度
    pos = 17000
    fills = []
    for i, c in enumerate(t[1]):
        if c == ' ':
            continue
        s, e = cs[i], ce[i]
        f = 0.0 if pos <= s else (1.0 if pos >= e else (pos - s) / float(max(1, e - s)))
        fills.append((c, round(f, 2)))
    print("  pos=17000 fills:", fills)
    lit = sum(1 for _, f in fills if f >= 1.0)
    partial = [c for c, f in fills if 0 < f < 1]
    # 实测：我/想/要 分别在 16367/16520/16718 唱完；「的」507→964（绝对 16718→17175），故 17000 时 3 全亮 + 的 62%
    ck("3 chars fully sung at 17000", lit == 3, "lit=%d partial=%s" % (lit, partial))
    ck("4th char 的 partial 62%", fills[3] == ("的", 0.62), str(fills[3]))
    ck("partial char is 的", partial == ["的"], str(partial))

    # 均分对照：12 字均分在 17000ms 只会到第 4.4 字左右 —— 证明两者确实不同（旧口径必然滞后/超前）
    line_end = t[2][-1][1] + t[2][-1][2]
    ratio = (pos - t[0]) / float(line_end - t[0])
    even_pos = ratio * 12
    print("  even-split position at same time: %.2f chars, timed: %d fully + 1 partial" % (even_pos, lit))
    ck("timed differs from even split meaningfully", abs(even_pos - (lit + 0.5)) > 0.3,
       "even=%.2f timed=%.2f" % (even_pos, lit + 0.5))

    # 句尾：唱完（19702ms）后到下一行（20021ms）之间 —— 必须全亮，不再欠染
    pos_end = 19950
    all_lit = all((1.0 if pos_end >= ce[i] else 0.0) == 1.0 for i, c in enumerate(t[1]) if c != ' ')
    ck("fully lit during interlude after last word", all_lit)

# ---- QRC：合成样本（相对 / 绝对两种基准都要能解） ----
qrcSample = ('<QrcInfos><LyricInfo><Lyric_1 LyricType="1" LyricContent="'
             '[1000,2000]你(1000,300)好(1300,300)世(1600,300)界(1900,300)\r\n'
             '[3000,1500]再(0,300)见(300,300)了(600,300)\r\n'
             '"/></LyricInfo></QrcInfos>')
contentRe = re.compile(r'<Lyric_1 LyricType="1" LyricContent="(.*?)"/>', re.S)
lineRe2 = re.compile(r"^\[(\d+),(\d+)\](.*)$")
wordRe2 = re.compile(r"((?:(?!\(\d+,\d+\)).)*)\((\d+),(\d+)\)")


def qrc_to_lines(s):
    content = contentRe.search(s).group(1)
    out = []
    for raw_line in content.splitlines():
        line = raw_line.strip()
        m = lineRe2.match(line) if line.startswith("[") else None
        if not m:
            continue
        start = int(m.group(1))
        ws = []
        for w in wordRe2.finditer(m.group(3)):
            t, a, b = w.group(1), int(w.group(2)), int(w.group(3))
            if t == "\r" or t == "":
                continue
            ws.append((t, a, b))
        if not ws:
            continue
        base = start if ws[0][1] < start else 0
        out.append((start, "".join(t for t, _, _ in ws), [(t, base + a, b) for t, a, b in ws]))
    return out


ql = qrc_to_lines(qrcSample)
ck("qrc lines parsed", len(ql) == 2, str(len(ql)))
ck("qrc absolute base kept", ql[0][2][0][1] == 1000, str(ql[0][2][0][1]))
ck("qrc relative base lifted", ql[1][2][0][1] == 3000, str(ql[1][2][0][1]))
ck("qrc text clean", ql[0][1] == "你好世界" and ql[1][1] == "再见了", "%s / %s" % (ql[0][1], ql[1][1]))

print("\nRESULT: %s" % ("ALL PARSER CHECKS PASS" if not fails else "FAILED: " + ", ".join(fails)))

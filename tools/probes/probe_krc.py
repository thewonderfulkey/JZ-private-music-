# -*- coding: utf-8 -*-
"""实测酷狗 KRC 明文：确认逐字时间是毫秒级、且与整行时间不同（用于回答"染色为什么跟不上"）"""
import base64, hashlib, json, time, urllib.parse, urllib.request, zlib, io, os

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

mid = md5(str(int(time.time() * 1000)))
kw = "周杰伦 暗号"
u = "http://complexsearch.kugou.com/v2/search/song?" + q(
    {"sorttype": "0", "keyword": kw, "pagesize": 5, "page": 1}, "SearchSong", mid)
js = get(u, "SearchSong", mid)
lst = js["data"]["lists"]
print("SEARCH hits:", len(lst))
c0 = lst[0]
print("first:", c0.get("SongName"), "| ID", c0.get("ID"), "| dur", c0.get("Duration"))

lrc_params = {"album_audio_id": c0["ID"], "duration": int(c0["Duration"]) * 1000,
              "hash": c0["FileHash"], "keyword": kw, "lrctxt": "1", "man": "no"}
ju = "https://lyrics.kugou.com/v1/search?" + q(lrc_params, "Lyric", mid)
lj = get(ju, "Lyric", mid)
cand = lj["candidates"][0]
print("lyric cand:", cand.get("id"), cand.get("song"), cand.get("singer"))

dl_params = {"accesskey": cand["accesskey"], "charset": "utf8", "client": "mobi",
             "fmt": "krc", "id": cand["id"], "ver": "1"}
du = "http://lyrics.kugou.com/download?" + q(dl_params, "Lyric", mid)
dj = get(du, "Lyric", mid)
print("contenttype:", dj.get("contenttype"))
raw = base64.b64decode(dj["content"])
if dj.get("contenttype") == 2:
    plain = raw.decode("utf-8", "replace")
else:
    body = raw[4:]
    x = bytes(b ^ KEY[i % 16] for i, b in enumerate(body))
    plain = zlib.decompress(x).decode("utf-8", "replace")

lines = [l.strip() for l in plain.splitlines() if l.strip().startswith("[")]
print("plain lines:", len(lines))
for l in lines[:8]:
    print("RAW>", l[:110])

# 解析逐字时间（KRC 词条 <start_ms,dur_ms,offset>文字）
import re
lineRe = re.compile(r"^\[(\d+),(\d+)\](.*)$")
wordRe = re.compile(r"<(\d+),(\d+),\d+>((?:.(?!\d+,\d+,\d+>))*)")


def parse(ln):
    m = lineRe.match(ln)
    if not m:
        return None
    start = int(m.group(1))
    ws = [(w.group(3), int(w.group(1)), int(w.group(2))) for w in wordRe.finditer(m.group(3))]
    return start, ws


i = 0
tagRe = re.compile(r"^\[[a-z]{2}:")
for l in lines:
    if tagRe.match(l):
        continue
    r = parse(l)
    if not r:
        continue
    start, ws = r
    if len(ws) >= 6:
        txt = "".join(w[0] for w in ws)
        print("\nLINE start=%dms  words=%d  text=%s" % (start, len(ws), txt))
        for text, s, d in ws[:16]:
            print("   %-4s start=%6dms dur=%4dms" % (text, s, d))
        i += 1
    if i >= 4:
        break

# 统计：同一行内各字时长差异（证明"均分"必然对不上）
print("\n=== 行内字时长差异（越高说明越不能均分）===")
stat = 0
for l in lines:
    if tagRe.match(l):
        continue
    r = parse(l)
    if not r:
        continue
    start, ws = r
    durs = [d for _, _, d in ws if d > 0]
    if len(durs) < 6:
        continue
    print("start=%6d  n=%2d  dur min=%4d max=%4d  rate=%.1fx" % (start, len(durs), min(durs), max(durs), max(durs) / max(1, min(durs))))
    stat += 1
    if stat >= 8:
        break


"""废掉酷我封面之后的兜底覆盖率：QQ 搜索（严格匹配）+ iTunes（tw 店）各能命中多少？

背景（2026-11-26）：老板拍板「只废酷我封面 API」。App 现在的封面链是
`song.picURL → 酷我 rid_pic → QQ 搜索 → iTunes`（`CoverResolver.swift:65-100`）。
前两站都要废（picURL 来自酷我搜索时是 wmvpic 横图；rid_pic 也是酷我），
剩下 QQ 搜索 + iTunes 两站必须够用，否则「本来有图（虽然是横图）→ 现在没图」。

顺带一个 2026-11-26 实测到的坑：iTunes 用**默认店（US）**搜华语歌几乎全是
`resultCount=0` 或不相干结果（0/25），加 `&country=tw` 才正常（稻香/青花瓷/晴天 都能中）。
`&country=cn` 是 0 条。所以 iTunes 那一站必须显式带店。
"""
import json
import re
import ssl
import time
import unicodedata
import urllib.parse
import urllib.request

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"}

SONGS = [
    ("断了的弦", "周杰伦"), ("稻香", "周杰伦"), ("青花瓷", "周杰伦"), ("晴天", "周杰伦"),
    ("众", "黄霄雲"), ("星辰大海", "黄霄雲"), ("侧脸", "黄霄雲"),
    ("江南", "林俊杰"), ("背对背拥抱", "林俊杰"),
    ("光年之外", "G.E.M.邓紫棋"), ("泡沫", "G.E.M.邓紫棋"),
    ("富士山下", "陈奕迅"), ("葡萄成熟时", "陈奕迅"),
    ("李白", "李荣浩"), ("麻雀", "李荣浩"),
    ("一千个伤心的理由", "张学友"), ("遥远的她", "张学友"),
    ("董小姐", "宋冬野"), ("莉莉安", "宋冬野"),
    ("素颜", "许嵩"), ("断桥残雪", "许嵩"),
    ("寂寞沙洲冷", "周传雄"), ("青花", "周传雄"),
    ("阿刁", "张韶涵"), ("欧若拉", "张韶涵"),
]
OUT = r"D:\Projects\Private_music\tools\probes\out\fallback_cover_coverage.json"


def norm(s):
    s = unicodedata.normalize("NFKC", s or "").lower()
    return re.sub(r"[\s\-_·、,，.。()（）\[\]【】《》'\"!?！？~&/+:：;；|]", "", s)


def title_ok(a, b):
    a, b = norm(a), norm(b)
    if not a or not b:
        return False
    return a == b or a in b or b in a


def artist_ok(target, cand):
    toks = [norm(x) for x in re.findall(r"[\u4e00-\u9fff]{2,}|[A-Za-z]{3,}", target)]
    if not toks:
        return True
    c = norm(cand)
    return any(t in c for t in toks)


def qq_cover(title, artist):
    kw = "%s %s" % (title, artist)
    url = ("https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=8&w=%s&format=json"
           % urllib.parse.quote(kw))
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={
                **UA, "Referer": "https://y.qq.com/"}), timeout=12, context=CTX) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:  # noqa: BLE001
        return None, str(e)
    for it in (((data.get("data") or {}).get("song") or {}).get("list") or []):
        am = it.get("albummid") or ""
        singers = "/".join(s.get("name", "") for s in (it.get("singer") or []))
        if am and title_ok(title, it.get("songname") or "") and artist_ok(artist, singers):
            return "https://y.gtimg.cn/music/photo_new/T002R500x500M000%s.jpg" % am, None
    return None, "no_match"


def itunes_cover(title, artist, country="tw"):
    enc = urllib.parse.quote(("%s %s" % (title, artist)).replace("/", " "))
    url = ("https://itunes.apple.com/search?term=%s&entity=song&limit=12&country=%s"
           % (enc, country))
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA),
                                    timeout=12, context=CTX) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:  # noqa: BLE001
        return None, str(e)
    for it in (data.get("results") or []):
        if not (it.get("trackName") and it.get("artistName") and it.get("artworkUrl100")):
            continue
        if title_ok(title, it["trackName"]) and artist_ok(artist, it["artistName"]):
            return it["artworkUrl100"].replace("100x100bb", "600x600bb"), None
    return None, "no_match"


def main():
    rows = []
    qq_hit = it_hit = both = 0
    for title, artist in SONGS:
        q, qe = qq_cover(title, artist)
        time.sleep(0.3)
        i, ie = itunes_cover(title, artist)
        time.sleep(0.3)
        qq_hit += bool(q)
        it_hit += bool(i)
        both += bool(q or i)
        rows.append({"title": title, "artist": artist, "qq": q, "itunes": i,
                     "qq_err": qe, "it_err": ie})
        print(f"{'QQ✓' if q else 'QQ✗'} {'IT✓' if i else 'IT✗'}  {title} / {artist}")
    n = len(SONGS)
    print(f"\nQQ 搜索命中 {qq_hit}/{n} = {qq_hit * 100 // n}%")
    print(f"iTunes(tw) 命中 {it_hit}/{n} = {it_hit * 100 // n}%")
    print(f"两条链合起来能出图 {both}/{n} = {both * 100 // n}%")
    print(f"两条都不行 {n - both} 首：" + "、".join(r["title"] for r in rows
                                                if not r["qq"] and not r["itunes"]))
    open(OUT, "w", encoding="utf-8").write(json.dumps(rows, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()

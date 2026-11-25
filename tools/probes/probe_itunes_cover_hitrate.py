"""iTunes 封面兜底命中率抽样：酷我封面废掉之后，「没封面」会多几首？

背景（2026-11-26）：老板拍板「只废酷我封面 API，封面用其他平台」。
App 的兜底链现在是 酷我 rid_pic → QQ 搜索 → iTunes（`CoverResolver.swift:81-93`）。
废掉酷我之后，兜底只剩 QQ 搜索 → iTunes，所以必须先知道 iTunes 对**华语老歌/综艺/Live**
到底给不给图，否则会出现「本来有图（虽然是横图）→ 现在没图」。

判据与 App 一致（`ITunesCover`）：歌名归一化后相等/包含，且歌手片段能在 artists 里找到。
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
    ("光年之外", "邓紫棋"), ("泡沫", "邓紫棋"),
    ("富士山下", "陈奕迅"), ("葡萄成熟时", "陈奕迅"),
    ("李白", "李荣浩"), ("麻雀", "李荣浩"),
    ("一千个伤心的理由", "张学友"), ("遥远的她", "张学友"),
    ("董小姐", "宋冬野"), ("莉莉安", "宋冬野"),
    ("素颜", "许嵩"), ("断桥残雪", "许嵩"),
    ("寂寞沙洲冷", "周传雄"), ("青花", "周传雄"),
    ("阿刁", "张韶涵"), ("欧若拉", "张韶涵"),
]


def norm(s):
    s = unicodedata.normalize("NFKC", s or "").lower()
    s = re.sub(r"[\s\-_·、,，.。()（）\[\]【】《》'\"!?！？~&/+:：;；|]", "", s)
    return s


def itunes(title, artist):
    term = ("%s %s" % (title, artist)).strip()
    enc = urllib.parse.quote(term.replace("/", " ").replace("&", " "))
    url = "https://itunes.apple.com/search?term=%s&entity=song&limit=10" % enc
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA),
                                    timeout=12, context=CTX) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:  # noqa: BLE001
        return None, str(e)
    a, b = norm(title), None
    toks = [norm(x) for x in re.findall(r"[\u4e00-\u9fff]{2,}|[A-Za-z]{3,}", artist)]
    for it in (data.get("results") or []):
        track, singer, art = it.get("trackName"), it.get("artistName"), it.get("artworkUrl100")
        if not (track and singer and art):
            continue
        tn = norm(track)
        title_ok = bool(tn and (tn == a or a in tn or tn in a))
        artist_ok = (not toks) or any(t in norm(singer) for t in toks)
        if title_ok and artist_ok:
            return art.replace("100x100bb", "600x600bb"), None
    return None, "no_match"


def main():
    hit = 0
    rows = []
    for title, artist in SONGS:
        art, err = itunes(title, artist)
        hit += 1 if art else 0
        rows.append({"title": title, "artist": artist, "art": art, "err": err})
        print(("✓ " if art else "✗ ") + f"{title} / {artist} {err or ''}")
        time.sleep(0.35)
    print(f"\niTunes 命中 {hit}/{len(SONGS)} = {hit * 100 // len(SONGS)}%")
    open(r"D:\Projects\Private_music\tools\probes\out\itunes_cover_hitrate.json", "w",
         encoding="utf-8").write(json.dumps(rows, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()

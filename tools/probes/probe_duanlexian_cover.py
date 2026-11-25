"""定位《断了的弦》那张盗版封面的出处：四个平台各取一张，落盘对比。

背景：2026-11-25 录屏 06:44，播放页封面是一张写着 `vmp65l3 5. ru,6xjp6 + 2ep JAY` 的
包装图。要判断"这张图是哪家给的"，只能把四家的图都拉下来、和录屏那一帧并排看。
"""
import json
import os
import ssl
import urllib.parse
import urllib.request

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"}
OUT = r"D:\Projects\Private_music\tools\probes\out\cover_census\probe_duanlexian"
KW = "断了的弦"


def get(url, headers=None, timeout=15):
    h = dict(UA)
    h.update(headers or {})
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=h),
                                    timeout=timeout, context=CTX) as r:
            return r.status, r.read()
    except Exception as e:  # noqa: BLE001
        return 0, str(e).encode()


def save(name, blob):
    p = os.path.join(OUT, name)
    open(p, "wb").write(blob)
    print(f"  {name}: {len(blob)} B")
    return p


def main():
    os.makedirs(OUT, exist_ok=True)

    # ① QQ
    u = ("https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=5&w=%s&format=json"
         % urllib.parse.quote(KW))
    st, body = get(u, {"Referer": "https://y.qq.com/"})
    data = json.loads(body.decode("utf-8", "replace"))
    for it in (((data.get("data") or {}).get("song") or {}).get("list") or [])[:5]:
        am = it.get("albummid") or ""
        print("[qq]", it.get("songname"), "|", it.get("albumname"), "| albummid=", am)
        if am:
            _, b = get("https://y.gtimg.cn/music/photo_new/T002R500x500M000%s.jpg" % am,
                       {"Referer": "https://y.qq.com/"})
            save("qq_%s.jpg" % am, b)

    # ② 酷我（wmvpic 曲图）
    u = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=5&pn=1&rformat=json&encoding=utf8"
         "&vipver=MUSIC_8.7.8.0_WX" % urllib.parse.quote(KW))
    st, body = get(u, {"Referer": "https://www.kuwo.cn/"})
    text = body.decode("utf-8", "replace")
    for i, m in enumerate(__import__("re").finditer(r"'MVPIC'\s*:\s*'([^']*)'", text)):
        mv = m.group(1).strip("/")
        if not mv:
            continue
        print("[kuwo] wmvpic=", mv)
        _, b = get("https://img1.kuwo.cn/wmvpic/" + mv)
        save("kuwo_%02d.jpg" % i, b)

    # ③ 网易
    u = ("https://music.163.com/api/search/get?s=%s&type=1&offset=0&limit=5"
         % urllib.parse.quote(KW))
    st, body = get(u, {"Referer": "https://music.163.com/"})
    data = json.loads(body.decode("utf-8", "replace"))
    ids = [str(s["id"]) for s in (((data.get("result") or {}).get("songs")) or [])][:5]
    if ids:
        u2 = "https://music.163.com/api/song/detail?ids=[%s]" % ",".join(ids)
        _, b2 = get(u2, {"Referer": "https://music.163.com/"})
        d2 = json.loads(b2.decode("utf-8", "replace"))
        for i, o in enumerate((d2.get("songs") or [])[:5]):
            pic = (o.get("album") or {}).get("picUrl") or ""
            print("[netease]", o.get("name"), "|", (o.get("album") or {}).get("name"), "|", pic[:80])
            if pic:
                _, b = get(pic + "?param=500y500")
                save("netease_%02d.jpg" % i, b)

    # ④ 酷狗
    u = ("https://mobiles.kugou.com/api/v3/search/song?format=json&keyword=%s&page=1"
         "&pagesize=5&showtype=1" % urllib.parse.quote(KW))
    st, body = get(u, {"Referer": "https://www.kugou.com/"})
    data = json.loads(body.decode("utf-8", "replace"))
    for i, it in enumerate((((data.get("data") or {}).get("info")) or [])[:5]):
        union = ((it.get("trans_param") or {}).get("union_cover") or "")
        print("[kugou]", it.get("songname"), "|", it.get("album_name"), "|", union[:80])
        if union:
            _, b = get(union.replace("{size}", "500").replace("http://", "https://"))
            save("kugou_%02d.jpg" % i, b)


if __name__ == "__main__":
    main()

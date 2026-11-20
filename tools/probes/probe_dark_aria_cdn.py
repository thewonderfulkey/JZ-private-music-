# -*- coding: utf-8 -*-
"""DARK ARIA 取流复测：NetEase CDN 直链在不同请求头下能不能取到音频。"""
import json
import urllib.error
import urllib.request

UA_IPHONE = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
             "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
UA_AVFOUNDATION = "AppleCoreMedia/1.0.0.21A360 (iPhone; U; CPU OS 17_0 like Mac OS X; zh_cn)"


def head(url, headers=None, rng="bytes=0-15"):
    h = {"User-Agent": UA_IPHONE}
    if rng:
        h["Range"] = rng
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, dict(r.headers), r.read(32)[:16]
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), b""
    except Exception as e:  # noqa: BLE001
        return None, {"err": repr(e)}, b""


def gd(br):
    u = ("https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest"
         "&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease"
         f"&id=2135545143&br={br}")
    req = urllib.request.Request(u, headers={"User-Agent": "LX-Music-Mobile"})
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read().decode())


for br in ("740", "320"):
    j = gd(br)
    url = j["url"]
    print(f"\n== br={br} size={j.get('size')} api_br={j.get('br')}")
    print("   url:", url[:100])
    cases = [
        ("带 Referer music.163.com", {"Referer": "https://music.163.com/"}),
        ("无 Referer（AVPlayer 的默认发法）", None),
        ("无 Referer + AppleCoreMedia UA", {"User-Agent": UA_AVFOUNDATION}),
    ]
    for label, hdrs in cases:
        st, hh, body = head(url, hdrs)
        print(f"   {label}: status={st} type={hh.get('Content-Type')} "
              f"len={hh.get('Content-Length')} range={hh.get('Content-Range')} head={body[:8]!r}")

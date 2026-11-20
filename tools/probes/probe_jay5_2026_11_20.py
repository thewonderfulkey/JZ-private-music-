"""第五轮：周杰伦整库抽样——酷我官方 anti.s 是不是**每一首**都只回那个 11.3s 占位音频。

rid 来自酷我官方「歌手页」接口（artistMusic，artistid=336 = 周杰伦），不是搜索猜的，
和 App 里「歌手页 → 热门歌曲」拿到的是同一批 id。
"""
import hashlib
import json
import ssl
import time
import urllib.request

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/122.0 Safari/537.36")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
PLACEHOLDER_MD5 = "43fe5f6460e49afdf0bc2340012fe7b5"


def get(url, headers=None, timeout=25, read=0):
    h = {"User-Agent": UA}
    h.update(headers or {})
    req = urllib.request.Request(url, headers=h)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            body = r.read(read) if read else r.read()
            return r.status, body, int((time.time() - t0) * 1000), dict(r.headers)
    except Exception as e:  # noqa: BLE001
        return None, str(e).encode(), int((time.time() - t0) * 1000), {}


st, body, ms, _ = get("https://wapi.kuwo.cn/api/www/artist/artistMusic?artistid=336&pn=1&rn=10",
                      {"Referer": "https://www.kuwo.cn/", "Accept": "application/json"}, timeout=25)
print(f"歌手页 {st} {ms}ms {len(body)}B")
try:
    j = json.loads(body.decode("utf-8", "replace"))
    songs = (j.get("data") or {}).get("list") or []
except Exception as e:  # noqa: BLE001
    print("解析失败", e, body[:200])
    songs = []
print(f"拿到 {len(songs)} 首\n")

same = 0
for it in songs:
    rid = str(it.get("rid") or it.get("musicrid") or "").replace("MUSIC_", "")
    name = it.get("name")
    if not rid:
        continue
    u = ("https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3"
         f"&response=url&rid=MUSIC_{rid}")
    st1, b1, ms1, _ = get(u, {"Referer": "https://www.kuwo.cn/"}, timeout=20)
    txt = b1.decode("utf-8", "replace").strip()
    if not txt.startswith("http"):
        print(f"《{name}》 rid={rid} anti.s → {txt[:60]}")
        continue
    st2, audio, ms2, hdr = get(txt, {"Referer": "https://www.kuwo.cn/"}, timeout=40)
    md5 = hashlib.md5(audio).hexdigest()
    mark = "★同一个占位文件" if md5 == PLACEHOLDER_MD5 else "真音频"
    if md5 == PLACEHOLDER_MD5:
        same += 1
    print(f"《{name}》 rid={rid} → {len(audio)}B md5={md5[:12]} {mark}")
    time.sleep(1.5)

print(f"\n抽样 {len(songs)} 首，命中同一个占位文件 {same} 首")

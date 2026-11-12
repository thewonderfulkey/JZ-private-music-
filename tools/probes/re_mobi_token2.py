# -*- coding: utf-8 -*-
"""从酷我 H5 首页捞 kw_token，再用 cookie+csrf 头请求 playUrl。"""
import http.cookiejar
import io
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_mobi_token2.txt"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
RID = "456593448"
lines = []
cj = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))


def get(url, headers=None):
    h = {"User-Agent": UA, "Accept": "text/html,application/json"}
    if headers:
        h.update(headers)
    with op.open(urllib.request.Request(url, headers=h), timeout=15) as r:
        return r.status, r.read(1200).decode("utf-8", "ignore")


for page in ("https://www.kuwo.cn/", "https://www.kuwo.cn/play_detail/%s" % RID):
    try:
        st, _ = get(page, {"Referer": "https://www.kuwo.cn/"})
        lines.append("GET %-45s %s" % (page, st))
    except Exception as e:
        lines.append("GET %-45s ERR %s" % (page, e))

for c in cj:
    lines.append("cookie: %s=%s" % (c.name, c.value))

kw = next((c.value for c in cj if c.name.lower() == "kw_token"), None)
lines.append("kw_token=%s" % kw)

if kw:
    for name, qs in (("v1", "type=music&httpsStatus=1"),
                     ("v3", "type=convert_url&httpsStatus=1"),
                     ("v1+br", "type=music&httpsStatus=1&br=320kmp3")):
        url = "https://www.kuwo.cn/api/v1/www/music/playUrl?mid=%s&%s" % (RID, qs)
        try:
            st, body = get(url, {"csrf": kw, "Referer": "https://www.kuwo.cn/play_detail/%s" % RID,
                                 "Accept": "application/json"})
            lines.append("playUrl %-8s %s :: %s" % (name, st, body.replace("\n", " ")[:400]))
        except Exception as e:
            lines.append("playUrl %-8s ERR %s" % (name, e))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))

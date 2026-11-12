# -*- coding: utf-8 -*-
"""对照组 + 带反爬 cookie 的 mobi.s 复测：先确认酷我域名本身可达，再判 mobi.s 到底是死链还是签名问题。"""
import base64
import http.cookiejar
import io
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_mobi_control.txt"
UA_WEB = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
UA_KW = "kwplayer_ar_12.0.6.4"
RID = "456593448"
lines = []
cj = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))


def call(name, url, ua=UA_WEB, extra=None):
    h = {"User-Agent": ua, "Accept": "*/*"}
    if extra:
        h.update(extra)
    try:
        with op.open(urllib.request.Request(url, headers=h), timeout=15) as r:
            body = r.read(800).decode("utf-8", "ignore")
        lines.append("%-34s %s :: %s" % (name, r.status, body.replace("\n", " ")[:300]))
        return body
    except Exception as e:
        lines.append("%-34s ERR %s" % (name, e))
        return ""


# --- 对照：上轮已验证可用的酷我接口 ---
call("CTRL lyric", "https://www.kuwo.cn/openapi/v1/www/lyric/getlyric?musicId=%s&httpsStatus=1" % RID,
     extra={"Referer": "https://www.kuwo.cn/"})
call("CTRL discover", "https://www.kuwo.cn/openapi/v1/recommend/discover/v0", extra={"Referer": "https://www.kuwo.cn/"})
call("CTRL searchKey", "https://www.kuwo.cn/openapi/v1/www/search/searchKey?key=%E5%91%A8%E6%9D%B0%E4%BC%A6&httpsStatus=1",
     extra={"Referer": "https://www.kuwo.cn/"})
call("CTRL search.kuwo.cn r.s", "https://search.kuwo.cn/r.s?all=%E5%91%A8%E6%9D%B0%E4%BC%A6&ft=music&rn=5&pn=0&vipver=MUSIC_8.7.8.0_WX")

# --- 拿反爬 cookie ---
try:
    call("warmup www.kuwo.cn", "https://www.kuwo.cn/")
except Exception:
    pass
cookies = "; ".join("%s=%s" % (c.name, c.value) for c in cj)
lines.append("cookie jar: %s" % (cookies or "(空)"))

# --- mobi.s 复测（带 cookie） ---
PLAIN = ("corp=kuwo&source=kwplayer_ar_12.0.6.4&type=convert_url&br=320kmp3&rid=%s&format=mp3&response=url" % RID)
Q64 = base64.b64encode(PLAIN.encode()).decode()
for f in ("kuwo", "web", "kwplayer"):
    call("mobi.s f=%s 空q" % f, "https://mobi.kuwo.cn/mobi.s?f=%s&q=" % f,
         ua=UA_KW, extra={"Cookie": cookies, "Referer": "https://mobi.kuwo.cn/"})
    call("mobi.s f=%s b64" % f,
         "https://mobi.kuwo.cn/mobi.s?f=%s&q=%s" % (f, urllib.parse.quote(Q64, safe="")),
         ua=UA_KW, extra={"Cookie": cookies, "Referer": "https://mobi.kuwo.cn/"})

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))

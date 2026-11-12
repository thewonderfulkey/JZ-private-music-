# -*- coding: utf-8 -*-
"""酷我 web playUrl 需要 csrf token：先取 token，再带 cookie+header 请求播放地址。"""
import http.cookiejar
import io
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_mobi_csrf.txt"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
RID = "456593448"
lines = []

cj = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))


def get(url, headers=None):
    h = {"User-Agent": UA, "Referer": "https://www.kuwo.cn/", "Accept": "application/json"}
    if headers:
        h.update(headers)
    with op.open(urllib.request.Request(url, headers=h), timeout=12) as r:
        return r.status, r.read(900).decode("utf-8", "ignore"), r.headers.get("Set-Cookie")


def show(name, st, body):
    lines.append("%-28s %s :: %s" % (name, st, body.replace("\n", " ")[:400]))


# 1) 取 token
for url in ("https://www.kuwo.cn/api/csrf", "https://www.kuwo.cn/api/csrf?httpsStatus=1"):
    try:
        st, body, sc = get(url)
        show("csrf " + url.split("?")[0].split("/")[-1], st, body)
        if sc:
            lines.append("   Set-Cookie: %s" % sc)
    except Exception as e:
        lines.append("csrf %s ERR %s" % (url, e))

tokens = []
for c in cj:
    lines.append("   cookie: %s=%s" % (c.name, c.value))
    if c.name.lower() in ("kw_token", "token"):
        tokens.append((c.name, c.value))

# 2) 带 token 请求播放地址
for name, ck, hd in [(n, v, None) for n, v in tokens] or [("无token", "", None)]:
    hdrs = {"Cookie": "%s=%s" % (ck, hd) if hd else ""}
    if hd:
        hdrs["csrf"] = hd
    for variant, qs in (
        ("playUrl v1", "type=music&httpsStatus=1"),
        ("playUrl v3", "type=convert_url&httpsStatus=1"),
        ("playUrl v1+br", "type=music&httpsStatus=1&br=320kmp3"),
    ):
        url = "https://www.kuwo.cn/api/v1/www/music/playUrl?mid=%s&%s" % (RID, qs)
        try:
            st, body, _ = get(url, hdrs)
            show("%s [%s]" % (variant, name), st, body)
        except Exception as e:
            lines.append("%s [%s] ERR %s" % (variant, name, e))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))

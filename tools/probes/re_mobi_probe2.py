# -*- coding: utf-8 -*-
"""换通道试探：http 版 mobi.s、mobiweb.s、酷我 web playUrl 是否匿名可用。"""
import base64
import io
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_mobi_probe2.txt"
lines = []
RID = "456593448"
PLAIN = ("corp=kuwo&source=kwplayer_ar_12.0.6.4&type=convert_url"
         "&br=320kmp3&rid=%s&format=mp3&response=url" % RID)
Q_B64 = base64.b64encode(PLAIN.encode()).decode()


def call(name, url, ua="kwplayer_ar_12.0.6.4", extra=None):
    h = {"User-Agent": ua}
    if extra:
        h.update(extra)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=12) as r:
            body = r.read(700).decode("utf-8", "ignore")
        lines.append("%-30s %s :: %s" % (name, r.status, body.replace("\n", " ")[:320]))
    except Exception as e:
        lines.append("%-30s ERR %s" % (name, e))


call("http mobi.s b64",
     "http://mobi.kuwo.cn/mobi.s?f=kuwo&q=" + urllib.parse.quote(Q_B64, safe=""))
call("mobiweb.s b64",
     "https://mobi.kuwo.cn/mobiweb.s?f=kuwo&q=" + urllib.parse.quote(Q_B64, safe=""))
call("web playUrl v1",
     "https://www.kuwo.cn/api/v1/www/music/playUrl?mid=%s&type=music&httpsStatus=1" % RID,
     ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120 Safari/537.36",
     extra={"Referer": "https://www.kuwo.cn/"})
call("web playUrl v2",
     "https://www.kuwo.cn/api/www/music/playUrl?mid=%s&type=music" % RID,
     ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120 Safari/537.36",
     extra={"Referer": "https://www.kuwo.cn/"})
call("web playUrl v3",
     "https://www.kuwo.cn/api/v1/www/music/playUrl?mid=%s&type=convert_url&httpsStatus=1" % RID,
     ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120 Safari/537.36",
     extra={"Referer": "https://www.kuwo.cn/"})

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))

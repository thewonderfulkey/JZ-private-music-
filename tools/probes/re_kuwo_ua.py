# -*- coding: utf-8 -*-
"""关键对照：同一个酷我 r.s 查询，换 App 实际使用的 UA（iPhone Safari）后结果是否变空。
App 的 ApiClient 统一发 iPhone Safari UA + Accept + Referer，而 vipver 参数只是模拟客户端。"""
import io
import re
import urllib.parse
import urllib.request

OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_kuwo_ua.txt"
lines = []
APP_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
          "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
KW = "IVORY TOWER"
url = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=20&pn=1&rformat=json&encoding=utf8"
       "&vipver=MUSIC_8.7.8.0_WX" % urllib.parse.quote(KW))


def run(label, ua):
    req = urllib.request.Request(url, headers={
        "User-Agent": ua,
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "Referer": "https://www.kuwo.cn/",
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            text = r.read().decode("utf-8", "ignore")
    except Exception as e:
        lines.append("%-18s ERR %s" % (label, e))
        return
    total = re.search(r"'TOTAL':'(\d+)'", text)
    rid = len(re.findall(r"MUSICRID':'MUSIC_(\d+)", text))
    absl = text.find("'abslist'")
    lines.append("%-18s len=%6d TOTAL=%s MUSICRID=%d abslist=%s" % (
        label, len(text), total.group(1) if total else "?", rid, absl))
    seg = text[absl:absl + 220] if absl >= 0 else text[:220]
    lines.append("    样本：%s" % seg.replace("\r", " ")[:220])


run("iPhone Safari UA", APP_UA)
run("kwplayer UA", "kwplayer_ar_12.0.6.4")

# 酷我搜索页/接口对 iPhone UA 是否另有分支：再用中文词对照一次
KW2 = "周杰伦"
url2 = url.replace(urllib.parse.quote(KW), urllib.parse.quote(KW2))
for label, ua in (("iPhone 周杰伦", APP_UA), ("kwplayer 周杰伦", "kwplayer_ar_12.0.6.4")):
    req = urllib.request.Request(url2, headers={"User-Agent": ua, "Referer": "https://www.kuwo.cn/"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            t = r.read().decode("utf-8", "ignore")
        lines.append("%-18s TOTAL=%s MUSICRID=%d" % (
            label, (re.search(r"'TOTAL':'(\d+)'", t) or [None, "?"])[1],
            len(re.findall(r"MUSICRID':'MUSIC_(\d+)", t))))
    except Exception as e:
        lines.append("%-18s ERR %s" % (label, e))

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))

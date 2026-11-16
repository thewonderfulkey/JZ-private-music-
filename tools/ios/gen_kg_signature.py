"""算出酷狗签名的期望 query 串（固定输入），给 Swift 侧断言用。

签名错了不会崩，只会表现为"酷狗歌词永远取不到"——是最难排查的一类失败。
这里用固定 mid/clienttime 把结果钉成常量，Swift 的 kgQuery 必须逐字节一致。
"""
from __future__ import annotations

import hashlib
import json
import urllib.parse
from pathlib import Path

KG_SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
OUT = Path(".build/lyrics-fixtures/kg-sign.json")


def md5(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def kg_query(params, module, mid, dfid="-", clienttime=0) -> str:
    all_ = list(params)
    if module == "Lyric":
        all_ += [("appid", "3116"), ("clientver", "11070")]
    else:
        all_ += [
            ("userid", "0"), ("appid", "3116"), ("token", ""),
            ("clienttime", str(clienttime)), ("iscorrection", "1"),
            ("uuid", "-"), ("mid", mid), ("dfid", dfid),
            ("clientver", "11070"), ("platform", "AndroidFilter"),
        ]
    items = sorted(all_, key=lambda kv: kv[0])
    signature = md5(KG_SALT + "".join(f"{k}={v}" for k, v in items) + KG_SALT)
    query = "&".join(f"{k}={urllib.parse.quote(v, safe='')}" for k, v in items)
    return query + f"&signature={signature}"


search_query = kg_query(
    [("sorttype", "0"), ("keyword", "晴天 周杰伦"), ("pagesize", "20"), ("page", "1")],
    module="SearchSong", mid="abcdef0123456789", dfid="-", clienttime=1700000000,
)
lyric_query = kg_query(
    [("album_audio_id", "123456"), ("duration", "269000"), ("hash", "abc123def456"),
     ("keyword", "周杰伦 - 晴天"), ("lrctxt", "1"), ("man", "no")],
    module="Lyric", mid="abcdef0123456789",
)

payload = {"searchSong": search_query, "lyric": lyric_query}
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
print("searchSong:", search_query)
print("lyric     :", lyric_query)
print(f"✓ 写入 {OUT}")

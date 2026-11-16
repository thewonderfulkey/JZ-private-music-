# -*- coding: utf-8 -*-
"""歌词解密探针：把 Android 的 KRC / QRC 解密算法在 Python 里跑一遍，用**真实接口数据**验证，
并产出可以提交进仓库的测试向量（给 Swift 的 SelfTest 用）。

为什么要有这一步：QQ 的 3DES 是 QQMusicDecoder 的非标准 DES 变体（S 盒输入位序反转），
标准库 DES 解不开；KRC 是「跳 4 字节 + XOR + zlib」。如果只照抄 Kotlin，写错了也看不出来——
所以这里先独立实现一遍，用真实歌词当样本，Swift 侧再拿同一批向量做断言。

跑法：
    python tools/ios/probe_lyrics.py            # 默认 晴天/周杰伦
    python tools/ios/probe_lyrics.py "稻香" "周杰伦"
输出：
    .build/lyrics-fixtures/krc.b64 / krc.plain / qrc.hex / qrc.plain / des-vectors.json
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import random
import re
import sys
import time
import urllib.parse
import zlib
from datetime import date

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools", "ios"))
from probe_network import http  # noqa: E402

os.environ.setdefault("no_proxy", "*")

OUT = os.path.join(".build", "lyrics-fixtures")
os.makedirs(OUT, exist_ok=True)

KG_SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
QQ_QRC_KEY = b"!@#)(*$%123ZXC!@!@#)(NHL"
KRC_KEY = bytes([ord("@"), ord("G"), ord("a"), ord("w"), ord("^"), ord("2"), ord("t"), ord("G"),
                 ord("Q"), ord("6"), ord("1"), ord("-"), 0xCE, 0xD2, ord("n"), ord("i")])


def md5(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def urlenc(s: str) -> str:
    return urllib.parse.quote(s, safe="")


# ============================================================ KRC / LRC


def krc_decrypt(enc: bytes) -> str:
    body = enc[4:] if len(enc) > 4 else enc
    xored = bytes(b ^ KRC_KEY[i % len(KRC_KEY)] for i, b in enumerate(body))
    return zlib.decompress(xored).decode("utf-8", "ignore")


KRC_LINE = re.compile(r"^\[(\d+),(\d+)\](.*)$")
KRC_WORD = re.compile(r"<(\d+),(\d+),\d+>((?:.(?!\d+,\d+,\d+>))*)")


def krc_to_lines(plain: str):
    out = []
    for raw in plain.splitlines():
        line = raw.strip()
        m = KRC_LINE.match(line)
        if not m:
            continue
        start = int(m.group(1))
        words = []
        for w in KRC_WORD.finditer(m.group(3)):
            text = w.group(3)
            if not text:
                continue
            words.append({"text": text, "startMs": start + int(w.group(1)), "durMs": int(w.group(2))})
        if not words:
            continue
        out.append({"timeMs": start, "text": "".join(w["text"] for w in words).rstrip(), "words": words})
    return sorted(out, key=lambda x: x["timeMs"])


# ============================================================ QQ 非标准 DES


SBOX = [
    [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
    [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,15,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
    [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
    [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,10,13,8,9,4,5,11,12,7,2,14],
    [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
    [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
    [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
    [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11],
]

M32 = 0xFFFFFFFF


def _bitnum(a: bytes, b: int, c: int) -> int:
    byte = a[(b // 32) * 4 + 3 - (b % 32) // 8]
    return ((byte >> (7 - b % 8)) & 1) << c


def _bitnum_intr(a: int, b: int, c: int) -> int:
    return ((a >> (31 - b)) & 1) << c


def _bitnum_intl(a: int, b: int, c: int) -> int:
    return (((a << b) & M32) & 0x80000000) >> c


def _sbox_bit(a: int) -> int:
    return (a & 32) | ((a & 31) >> 1) | ((a & 1) << 4)


def _initial_permutation(data: bytes):
    s0 = 0
    for i, b in enumerate([57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7]):
        s0 |= _bitnum(data, b, 31 - i)
    s1 = 0
    for i, b in enumerate([56,48,40,32,24,16,8,0,58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6]):
        s1 |= _bitnum(data, b, 31 - i)
    return s0, s1


def _inverse_permutation(s0: int, s1: int) -> bytes:
    # 逐行照抄 Kotlin（Kotlin 的 8 个赋值顺序是 3,2,1,0,7,6,5,4，不能自己推）
    def one(pairs):
        v = 0
        for src, b, c in pairs:
            v |= _bitnum_intr(s0 if src == 0 else s1, b, c)
        return v & 0xFF
    data = [0] * 8
    data[3] = one([(1, 7, 7), (0, 7, 6), (1, 15, 5), (0, 15, 4), (1, 23, 3), (0, 23, 2), (1, 31, 1), (0, 31, 0)])
    data[2] = one([(1, 6, 7), (0, 6, 6), (1, 14, 5), (0, 14, 4), (1, 22, 3), (0, 22, 2), (1, 30, 1), (0, 30, 0)])
    data[1] = one([(1, 5, 7), (0, 5, 6), (1, 13, 5), (0, 13, 4), (1, 21, 3), (0, 21, 2), (1, 29, 1), (0, 29, 0)])
    data[0] = one([(1, 4, 7), (0, 4, 6), (1, 12, 5), (0, 12, 4), (1, 20, 3), (0, 20, 2), (1, 28, 1), (0, 28, 0)])
    data[7] = one([(1, 3, 7), (0, 3, 6), (1, 11, 5), (0, 11, 4), (1, 19, 3), (0, 19, 2), (1, 27, 1), (0, 27, 0)])
    data[6] = one([(1, 2, 7), (0, 2, 6), (1, 10, 5), (0, 10, 4), (1, 18, 3), (0, 18, 2), (1, 26, 1), (0, 26, 0)])
    data[5] = one([(1, 1, 7), (0, 1, 6), (1, 9, 5), (0, 9, 4), (1, 17, 3), (0, 17, 2), (1, 25, 1), (0, 25, 0)])
    data[4] = one([(1, 0, 7), (0, 0, 6), (1, 8, 5), (0, 8, 4), (1, 16, 3), (0, 16, 2), (1, 24, 1), (0, 24, 0)])
    return bytes(data)


def _f(state: int, key) -> int:
    t1 = (_bitnum_intl(state, 31, 0) | ((state & 0xF0000000) >> 1) | _bitnum_intl(state, 4, 5) |
          _bitnum_intl(state, 3, 6) | ((state & 0x0F000000) >> 3) | _bitnum_intl(state, 8, 11) |
          _bitnum_intl(state, 7, 12) | ((state & 0x00F00000) >> 5) | _bitnum_intl(state, 12, 17) |
          _bitnum_intl(state, 11, 18) | ((state & 0x000F0000) >> 7) | _bitnum_intl(state, 16, 23))
    t2 = (_bitnum_intl(state, 15, 0) | ((state & 0x0000F000) << 15) | _bitnum_intl(state, 20, 5) |
          _bitnum_intl(state, 19, 6) | ((state & 0x00000F00) << 13) | _bitnum_intl(state, 24, 11) |
          _bitnum_intl(state, 23, 12) | ((state & 0x000000F0) << 11) | _bitnum_intl(state, 28, 17) |
          _bitnum_intl(state, 27, 18) | ((state & 0x0000000F) << 9) | _bitnum_intl(state, 0, 23))
    t1 &= M32
    t2 &= M32
    lrg = [(t1 >> 24) & 0xFF, (t1 >> 16) & 0xFF, (t1 >> 8) & 0xFF,
           (t2 >> 24) & 0xFF, (t2 >> 16) & 0xFF, (t2 >> 8) & 0xFF]
    for i in range(6):
        lrg[i] ^= key[i]
    st = ((SBOX[0][_sbox_bit(lrg[0] >> 2)] << 28) |
          (SBOX[1][_sbox_bit(((lrg[0] & 0x03) << 4) | (lrg[1] >> 4))] << 24) |
          (SBOX[2][_sbox_bit(((lrg[1] & 0x0F) << 2) | (lrg[2] >> 6))] << 20) |
          (SBOX[3][_sbox_bit(lrg[2] & 0x3F)] << 16) |
          (SBOX[4][_sbox_bit(lrg[3] >> 2)] << 12) |
          (SBOX[5][_sbox_bit(((lrg[3] & 0x03) << 4) | (lrg[4] >> 4))] << 8) |
          (SBOX[6][_sbox_bit(((lrg[4] & 0x0F) << 2) | (lrg[5] >> 6))] << 4) |
          SBOX[7][_sbox_bit(lrg[5] & 0x3F)]) & M32
    return (_bitnum_intl(st, 15, 0) | _bitnum_intl(st, 6, 1) | _bitnum_intl(st, 19, 2) |
            _bitnum_intl(st, 20, 3) | _bitnum_intl(st, 28, 4) | _bitnum_intl(st, 11, 5) |
            _bitnum_intl(st, 27, 6) | _bitnum_intl(st, 16, 7) | _bitnum_intl(st, 0, 8) |
            _bitnum_intl(st, 14, 9) | _bitnum_intl(st, 22, 10) | _bitnum_intl(st, 25, 11) |
            _bitnum_intl(st, 4, 12) | _bitnum_intl(st, 17, 13) | _bitnum_intl(st, 30, 14) |
            _bitnum_intl(st, 9, 15) | _bitnum_intl(st, 1, 16) | _bitnum_intl(st, 7, 17) |
            _bitnum_intl(st, 23, 18) | _bitnum_intl(st, 13, 19) | _bitnum_intl(st, 31, 20) |
            _bitnum_intl(st, 26, 21) | _bitnum_intl(st, 2, 22) | _bitnum_intl(st, 8, 23) |
            _bitnum_intl(st, 18, 24) | _bitnum_intl(st, 12, 25) | _bitnum_intl(st, 29, 26) |
            _bitnum_intl(st, 5, 27) | _bitnum_intl(st, 21, 28) | _bitnum_intl(st, 10, 29) |
            _bitnum_intl(st, 3, 30) | _bitnum_intl(st, 24, 31)) & M32


def _crypt(data: bytes, key) -> bytes:
    s0, s1 = _initial_permutation(data)
    for idx in range(15):
        prev = s1
        s1 = _f(s1, key[idx]) ^ s0
        s0 = prev
    s0 = _f(s1, key[15]) ^ s0
    return _inverse_permutation(s0, s1)


def _key_schedule(key: bytes, mode: int):
    schedule = [[0] * 6 for _ in range(16)]
    shift = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    perm_c = [56,48,40,32,24,16,8,0,57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35]
    perm_d = [62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,60,52,44,36,28,20,12,4,27,19,11,3]
    comp = [13,16,10,23,0,4,2,27,14,5,20,9,22,18,11,3,25,7,15,6,26,19,12,1,40,51,30,36,
            46,54,29,39,50,44,32,47,43,48,38,55,33,52,45,41,49,35,28,31]
    c = d = 0
    for i in range(28):
        c |= _bitnum(key, perm_c[i], 31 - i)
        d |= _bitnum(key, perm_d[i], 31 - i)
    for i in range(16):
        c = ((c << shift[i]) | (c >> (28 - shift[i]))) & 0xFFFFFFF0
        d = ((d << shift[i]) | (d >> (28 - shift[i]))) & 0xFFFFFFF0
        target = 15 - i if mode == 0 else i
        for j in range(24):
            schedule[target][j // 8] |= _bitnum_intr(c, comp[j], 7 - (j % 8))
        for j in range(24, 48):
            schedule[target][j // 8] |= _bitnum_intr(d, comp[j] - 27, 7 - (j % 8))
    return schedule


ENCRYPT, DECRYPT = 1, 0


def _tripledes_setup(key: bytes, mode: int):
    k0, k1, k2 = key[0:8], key[8:16], key[16:24]
    if mode == ENCRYPT:
        return [_key_schedule(k0, ENCRYPT), _key_schedule(k1, DECRYPT), _key_schedule(k2, ENCRYPT)]
    return [_key_schedule(k2, DECRYPT), _key_schedule(k1, ENCRYPT), _key_schedule(k0, DECRYPT)]


def _tripledes_crypt(data: bytes, keys) -> bytes:
    d = data
    for k in keys:
        d = _crypt(d, k)
    return d


def qrc_decrypt(hex_text: str) -> str:
    cleaned = hex_text.strip()
    if not cleaned:
        return ""
    raw = bytes.fromhex(cleaned)
    keys = _tripledes_setup(QQ_QRC_KEY, DECRYPT)
    out = bytearray()
    for off in range(0, len(raw) - 7, 8):
        out += _tripledes_crypt(raw[off:off + 8], keys)
    return zlib.decompress(bytes(out)).decode("utf-8", "ignore")


QRC_CONTENT = re.compile(r'<Lyric_1 LyricType="1" LyricContent="(.*?)"/>', re.S)
QRC_WORD = re.compile(r"((?:(?!\(\d+,\d+\)).)*)\((\d+),(\d+)\)")


def qrc_to_lines(plain: str):
    m = QRC_CONTENT.search(plain)
    if not m:
        return []
    out = []
    for raw in m.group(1).splitlines():
        line = raw.strip()
        lm = KRC_LINE.match(line)
        if not lm:
            continue
        start = int(lm.group(1))
        raw_words = []
        for w in QRC_WORD.finditer(lm.group(3)):
            text = w.group(1)
            if text in ("\r", "") or text == "":
                continue
            raw_words.append((text, int(w.group(2)), int(w.group(3))))
        if not raw_words:
            continue
        base = start if raw_words[0][1] < start else 0
        words = [{"text": t, "startMs": base + s, "durMs": d} for t, s, d in raw_words]
        out.append({"timeMs": start, "text": "".join(w["text"] for w in words).rstrip(), "words": words})
    return sorted(out, key=lambda x: x["timeMs"])


# ============================================================ 酷狗接口


def kg_query(extra: dict, module: str, mid: str) -> str:
    params = dict(extra)
    if module == "Lyric":
        params["appid"] = "3116"
        params["clientver"] = "11070"
    else:
        params.update({
            "userid": "0", "appid": "3116", "token": "", "clienttime": int(time.time()),
            "iscorrection": "1", "uuid": "-", "mid": mid, "dfid": "-",
            "clientver": "11070", "platform": "AndroidFilter",
        })
    items = sorted(params.items())
    signature = md5(KG_SALT + "".join(f"{k}={v}" for k, v in items) + KG_SALT)
    return "&".join(f"{k}={urlenc(str(v))}" for k, v in items) + f"&signature={signature}"


def kg_headers(module: str, mid: str) -> dict:
    return {
        "User-Agent": f"Android14-1070-11070-201-0-{module}-wifi",
        "Connection": "Keep-Alive",
        "KG-Rec": "1", "KG-RC": "1",
        "KG-CLIENTTIMEMS": str(int(time.time() * 1000)),
        "mid": mid,
    }


def kg_lyrics(title: str, artist: str):
    mid = md5(str(int(time.time() * 1000)))
    params = {"sorttype": "0", "keyword": f"{title} {artist}".strip(), "pagesize": 20, "page": 1}
    url = "http://complexsearch.kugou.com/v2/search/song?" + kg_query(params, "SearchSong", mid)
    _, body = http(url, kg_headers("SearchSong", mid), timeout=10)
    js = json.loads(body.decode("utf-8", "ignore"))
    lists = (js.get("data") or {}).get("lists") or []
    if not lists:
        return None, "搜索无候选"
    song = lists[0]
    song_id, file_hash = song.get("ID"), song.get("FileHash")
    dur_ms = int(song.get("Duration") or 0) * 1000
    lrc_params = {
        "album_audio_id": song_id, "duration": dur_ms, "hash": file_hash,
        "keyword": f"{artist} - {title}", "lrctxt": "1", "man": "no",
    }
    url = "https://lyrics.kugou.com/v1/search?" + kg_query(lrc_params, "Lyric", mid)
    _, body = http(url, kg_headers("Lyric", mid), timeout=10)
    cands = json.loads(body.decode("utf-8", "ignore")).get("candidates") or []
    if not cands:
        return None, "歌词模块无候选"
    cid, accesskey = cands[0].get("id"), cands[0].get("accesskey")
    dl_params = {"accesskey": accesskey, "charset": "utf8", "client": "mobi",
                 "fmt": "krc", "id": cid, "ver": "1"}
    url = "http://lyrics.kugou.com/download?" + kg_query(dl_params, "Lyric", mid)
    _, body = http(url, kg_headers("Lyric", mid), timeout=10)
    dl = json.loads(body.decode("utf-8", "ignore"))
    content, ctype = dl.get("content") or "", dl.get("contenttype", -1)
    if not content:
        return None, "download 无 content"
    return {"song": song, "content": content, "contenttype": ctype, "id": cid}, None


# ============================================================ QQ 接口


def qq_comm():
    return {
        "ct": 11, "cv": "1003006", "v": "1003006", "os_ver": "15",
        "phonetype": "24122RKC7C",
        "rom": "Redmi/miro/miro:15/AE3A.240806.005/OS2.0.105.0.VOMCNXM:user/release-keys",
        "tmeAppID": "qqmusiclight", "nettype": "NETWORK_WIFI", "udid": "0",
    }


def qq_request(comm: dict, method: str, module: str, param: dict):
    payload = json.dumps({"comm": comm, "request": {"method": method, "module": module, "param": param}})
    req_body = payload.encode("utf-8")
    import urllib.request
    req = urllib.request.Request("https://u.y.qq.com/cgi-bin/musicu.fcg", data=req_body, method="POST")
    req.add_header("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
                                 "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
    req.add_header("Content-Type", "application/json")
    req.add_header("Cookie", "tmeLoginType=-1;")
    with urllib.request.urlopen(req, timeout=10) as resp:
        js = json.loads(resp.read().decode("utf-8", "ignore"))
    if js.get("code", -1) != 0:
        return None
    r = js.get("request") or {}
    if r.get("code", -1) != 0:
        return None
    return r.get("data")


def b64(s: str) -> str:
    return base64.b64encode(s.encode("utf-8")).decode()


def qq_session(comm):
    data = qq_request(comm, "GetSession", "music.getSession.session",
                      {"caller": 0, "uid": "0", "vkey": 0})
    if not data:
        return False
    s = data.get("session") or {}
    comm["uid"] = s.get("uid", "")
    comm["sid"] = s.get("sid", "")
    comm["userip"] = s.get("userip", "")
    return True


def qq_lyrics(title: str, artist: str):
    comm = qq_comm()
    if not qq_session(comm):
        return None, "GetSession 失败"
    search_id = (random.randint(1, 19) * 18014398509481984
                 + random.randint(0, 4194304) * 4294967296
                 + int(time.time() * 1000) % 86400000)
    data = qq_request(comm, "DoSearchForQQMusicLite", "music.search.SearchCgiService", {
        "search_id": str(search_id), "remoteplace": "search.android.keyboard",
        "query": f"{title} {artist}".strip(), "search_type": 0, "num_per_page": 20,
        "page_num": 1, "highlight": 0, "nqc_flag": 0, "page_id": 1, "grp": 1,
    })
    if not data:
        return None, "DoSearch 失败"
    items = (data.get("body") or {}).get("item_song") or []
    if not items:
        return None, "搜索无候选"
    song = items[0]
    qid = song.get("id")
    singer = ((song.get("singer") or [{}])[0]).get("name", "")
    album = (song.get("album") or {}).get("name", "")
    interval = int(song.get("interval") or 0)
    lyric = qq_request(comm, "GetPlayLyricInfo", "music.musichallSong.PlayLyricInfo", {
        "albumName": b64(album), "crypt": 1, "ct": 19, "cv": 2111,
        "interval": interval, "lrc_t": 0, "qrc": 1, "qrc_t": 0, "roma": 1, "roma_t": 0,
        "singerName": b64(singer), "songID": int(qid or 0),
        "songName": b64(song.get("title", title)), "trans": 1, "trans_t": 0, "type": 0,
    })
    if not lyric:
        return None, "GetPlayLyricInfo 失败"
    enc = lyric.get("lyric") or ""
    qrc_t = lyric.get("qrc_t", 0)
    lrc_t = str(lyric.get("lrc_t", "0"))
    eff = str(qrc_t) if qrc_t else lrc_t
    if not enc or eff == "0":
        return None, f"无加密歌词 qrc_t={qrc_t} lrc_t={lrc_t}"
    return {"song": song, "hex": enc, "eff_t": eff}, None


# ============================================================ 主流程


def main() -> int:
    title = sys.argv[1] if len(sys.argv) > 1 else "晴天"
    artist = sys.argv[2] if len(sys.argv) > 2 else "周杰伦"
    print(f"\n=== 歌词探针：{title} / {artist} ===")

    fixtures = {}

    # ---- 酷狗 KRC
    print("\n[酷狗] 搜索 + 歌词模块 + download")
    kg, kg_err = kg_lyrics(title, artist)
    if kg_err:
        print(f"  ✗ {kg_err}")
    else:
        enc = base64.b64decode(kg["content"])
        print(f"  contenttype={kg['contenttype']}  密文 {len(enc)} 字节  song={kg['song'].get('SongName')}")
        try:
            if kg["contenttype"] == 2:
                print("  （contenttype=2 是 base64 纯文本 LRC，非 KRC）")
            else:
                plain = krc_decrypt(enc)
                lines = krc_to_lines(plain)
                print(f"  ✓ KRC 解密成功：明文 {len(plain)} 字符，{len(lines)} 行，首行={lines[0]['text'][:30]!r}"
                      f"，逐字词数={len(lines[0]['words'])}")
                for ln in lines[:5]:
                    print(f"    [{ln['timeMs']:>6}] {ln['text'][:34]}")
                fixtures["krc.b64"] = kg["content"]
                fixtures["krc.plain"] = plain[:4000]
                fixtures["krc.expect"] = json.dumps(
                    {"lines": len(lines), "first": lines[0]["text"], "words": len(lines[0]["words"]),
                     "firstWord": lines[0]["words"][0]}, ensure_ascii=False)
        except Exception as e:  # noqa: BLE001
            print(f"  ✗ KRC 解密失败：{type(e).__name__}: {e}")

    # ---- 合成 QRC（QQ 接口被限流时也能验证 hex→DES→inflate→解析 整条链）
    synth_qrc_plain = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<QrcInfos><QrcHeadInfo SaveTime="1"/><LyricInfo LyricCount="1">'
        '<Lyric_1 LyricType="1" LyricContent="'
        '[0,500]晴天(0,600) - (600,300)周杰伦(900,700)\n'
        '[2250,500]词：(2250,300)周杰伦(2550,500)\n'
        '[4500,500]故事的小黄花(4500,700)从(5200,300)出生那年就飘着(5500,900)\n'
        '[6750,500]童年的荡秋千(6750,700)随(7450,300)记忆一直晃到现在(7750,900)\n'
        '[9000,500]吹着前奏望着天空(9000,900)我(9900,300)想起花瓣试着掉落(10200,900)\n'
        '[11250,500]为你翘课的那一天(11250,900)花(12150,300)落的那一天(12450,600)\n'
        '[13500,500]教室的那一间(13500,700)我(14200,300)怎么看不见(14500,700)\n'
        '[15750,500]消失的下雨天(15750,700)我(16450,300)好想再淋一遍(16750,700)\n'
        '"/></LyricInfo></QrcInfos>'
    )

    def build_synth_qrc(plain: str) -> str:
        raw = zlib.compress(plain.encode("utf-8"), 9)
        pad = (-len(raw)) % 8
        raw += b"\x00" * pad
        enc = _tripledes_setup(QQ_QRC_KEY, ENCRYPT)
        return b"".join(_tripledes_crypt(raw[i:i + 8], enc) for i in range(0, len(raw), 8)).hex()

    synth_qrc_hex = build_synth_qrc(synth_qrc_plain)
    back = qrc_decrypt(synth_qrc_hex)
    synth_qrc_lines = qrc_to_lines(back)
    print(f"\n[合成 QRC] {len(synth_qrc_hex) // 2} 字节密文 → 解出 {len(synth_qrc_lines)} 行"
          f"，首行={synth_qrc_lines[0]['text']!r}，逐字 {len(synth_qrc_lines[0]['words'])} 个")
    assert back == synth_qrc_plain, "合成 QRC 往返不一致"
    fixtures["qrc.synth.hex"] = synth_qrc_hex
    fixtures["qrc.synth.plain"] = synth_qrc_plain
    fixtures["qrc.synth.expect"] = json.dumps({
        "lines": len(synth_qrc_lines),
        "firstText": synth_qrc_lines[0]["text"],
        "firstTimeMs": synth_qrc_lines[0]["timeMs"],
        "firstWords": len(synth_qrc_lines[0]["words"]),
    }, ensure_ascii=False)

    # ---- 合成 KRC（KRC 的封装是 4 字节头 + XOR + zlib，顺带验证异或实现）
    synth_krc_plain = (
        "[0,1500]<0,600,0>晴天<600,300,0> - <900,600,0>周杰伦\n"
        "[2250,1200]<0,300,0>词：<300,900,0>周杰伦\n"
        "[4500,2000]<0,700,0>故事的小黄花<700,300,0>从<1000,1000,0>出生那年就飘着\n"
        "[6750,1800]<0,700,0>童年的荡秋千<700,300,0>随<1000,800,0>记忆一直晃到现在\n"
        "[9000,2000]<0,900,0>吹着前奏望着天空<900,300,0>我<1200,800,0>想起花瓣试着掉落\n"
        "[11250,1600]<0,900,0>为你翘课的那一天<900,300,0>花<1200,400,0>落的那一天\n"
    )

    def build_synth_krc(plain: str) -> str:
        # 顺序必须是「先 zlib 压缩、再逐字节 XOR」——解密侧是 XOR 之后 inflate
        compressed = zlib.compress(plain.encode("utf-8"), 9)
        xored = bytes(b ^ KRC_KEY[i % len(KRC_KEY)] for i, b in enumerate(compressed))
        # 真实 KRC 是 4 字节头 + 上述数据；头内容解密侧不关心，用 4 个 0 填充
        return base64.b64encode(b"\x00\x00\x00\x00" + xored).decode()

    synth_krc_b64 = build_synth_krc(synth_krc_plain)
    back_krc = krc_decrypt(base64.b64decode(synth_krc_b64))
    synth_krc_lines = krc_to_lines(back_krc)
    print(f"[合成 KRC] {len(base64.b64decode(synth_krc_b64))} 字节 → 解出 {len(synth_krc_lines)} 行"
          f"，首行逐字 {len(synth_krc_lines[0]['words'])} 个")
    assert back_krc == synth_krc_plain, "合成 KRC 往返不一致"
    fixtures["krc.synth.b64"] = synth_krc_b64
    fixtures["krc.synth.plain"] = synth_krc_plain
    fixtures["krc.synth.expect"] = json.dumps({
        "lines": len(synth_krc_lines),
        "firstText": synth_krc_lines[0]["text"],
        "firstTimeMs": synth_krc_lines[0]["timeMs"],
        "firstWords": len(synth_krc_lines[0]["words"]),
    }, ensure_ascii=False)

    # ---- QQ QRC
    print("\n[QQ] GetSession + DoSearch + GetPlayLyricInfo")
    qq, qq_err = qq_lyrics(title, artist)
    if qq_err:
        print(f"  ✗ {qq_err}")
    else:
        print(f"  hex {len(qq['hex'])} 字符  qrc_t 生效值={qq['eff_t']}")
        try:
            plain = qrc_decrypt(qq["hex"])
            lines = qrc_to_lines(plain)
            print(f"  ✓ QRC 解密成功：明文 {len(plain)} 字符，{len(lines)} 行"
                  + (f"，首行={lines[0]['text'][:30]!r}，逐字词数={len(lines[0]['words'])}" if lines else "（无逐字行）"))
            for ln in lines[:5]:
                print(f"    [{ln['timeMs']:>6}] {ln['text'][:34]}")
            # 只保留前 3000 个 hex 字符没必要——QRC 必须整段解，所以按整段存
            fixtures["qrc.hex"] = qq["hex"]
            fixtures["qrc.plain"] = plain[:4000]
            if lines:
                fixtures["qrc.expect"] = json.dumps(
                    {"lines": len(lines), "first": lines[0]["text"], "words": len(lines[0]["words"])},
                    ensure_ascii=False)
        except Exception as e:  # noqa: BLE001
            print(f"  ✗ QRC 解密失败：{type(e).__name__}: {e}")

    # ---- DES 交叉验证向量（Swift 侧用同一批向量断言自己的实现）
    print("\n[DES] 生成 6 组加解密向量（Swift 侧逐字节比对）")
    vectors = []
    seeds = [b"JZTEST01", b"LYRICS!!", b"01234567", b"ABCDEFGH", "中文歌词一".encode("utf-8"), b"krcqrc12"]
    for raw in seeds:
        block = (raw + b"\x00" * 8)[:8]
        enc_keys = _tripledes_setup(QQ_QRC_KEY, ENCRYPT)
        cipher = _tripledes_crypt(block, enc_keys)
        dec_keys = _tripledes_setup(QQ_QRC_KEY, DECRYPT)
        back = _tripledes_crypt(cipher, dec_keys)
        assert back == block, (block, back)
        vectors.append({
            "plainHex": block.hex(),
            "cipherHex": cipher.hex(),
        })
        print(f"  {block.hex()} -> {cipher.hex()} -> {back.hex()} {'OK' if back == block else 'FAIL'}")
    fixtures["des-vectors.json"] = json.dumps(vectors, indent=2)
    fixtures["_meta"] = json.dumps({
        "title": title, "artist": artist,
        "generated": str(date.today()),
        "note": "由 tools/ios/probe_lyrics.py 用真实接口数据生成；Swift 侧 SelfTest 用它们断言解密实现",
    }, ensure_ascii=False, indent=2)

    for name, content in fixtures.items():
        path = os.path.join(OUT, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    print(f"\nfixtures 写入 {OUT}：{', '.join(sorted(fixtures))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

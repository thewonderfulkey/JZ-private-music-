# -*- coding: utf-8 -*-
"""试验：Shazam 指纹（shazamio 内核生成）能否直接喂给网易 /api/music/audio/match"""
import asyncio, json, os, urllib.parse, urllib.request

WAV = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\probe_shazam_10s.wav"

from shazamio import Shazam
from shazamio_core import SearchParams

async def main():
    sh = Shazam()
    sig = await sh.core_recognizer.recognize_path(value=WAV, options=SearchParams())
    uri = sig.signature.uri
    print("签名 uri 前缀:", uri[:60], "总长:", len(uri))
    b64 = uri.split("base64,")[-1]

    url = "https://interface.music.163.com/api/music/audio/match"
    form = urllib.parse.urlencode({
        "sessionId": "441df692-afea-4a54-8aff-f5f20fd34f12",
        "algorithmCode": "shazam_v2", "duration": "10",
        "rawdata": b64, "times": "2", "decrypt": "1",
    }).encode()
    req = urllib.request.Request(url, data=form, method="POST", headers={
        "user-agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
                       "Chrome/124.0.0.0 Safari/537.36"),
        "accept": "application/json",
        "content-type": "application/x-www-form-urlencoded; charset=UTF-8",
        "origin": "chrome-extension://pgphbbekcgpfaekhcbjamjjkegcclhhd",
    })
    body = urllib.request.urlopen(req, timeout=25).read().decode("utf-8", "replace")
    j = json.loads(body)
    print("网易 code:", j.get("code"), "noMatchReason:", (j.get("data") or {}).get("noMatchReason"))
    for it in ((j.get("data") or {}).get("result") or [])[:5]:
        s = it.get("song") or {}
        print("  命中:", s.get("name"), "/", "/".join(a.get("name", "") for a in (s.get("artists") or [])),
              "| 专辑:", (s.get("album") or {}).get("name"))
    if not ((j.get("data") or {}).get("result") or []):
        print("  原始:", body[:200])

asyncio.run(main())


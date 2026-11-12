# -*- coding: utf-8 -*-
import io, os, re
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build"

def lines(name):
    p = os.path.join(OUT, name)
    with io.open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()

bad = lines("v2151_badging.txt")
keep = []
for l in bad:
    if l.startswith(("package:", "launchable-activity", "uses-permission", "sdkVersion", "targetSdkVersion", "application:", "compileSdkVersion")):
        keep.append(l)
print("== BADGING ==")
print("\n".join(keep[:24]))

sign = lines("v2151_apksigner.txt")
print("\n== APKSIGNER ==")
sel = [l for l in sign if ("Verified" in l or "SHA-256" in l or "Signer" in l or "v1/v2" in l or "Number of signers" in l)]
print("\n".join(sel[:12]))

res = lines("v2151_res.txt")
print("\n== RES ==")
want = ("jz_paper", "Theme.JZMusicHelper", "splash_ink")
for l in res:
    if any(w in l for w in want):
        print(l.strip()[:160])

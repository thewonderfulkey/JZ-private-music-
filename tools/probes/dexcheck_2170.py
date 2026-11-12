import zipfile, os
apk = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
needles = [b"next.bin", b"prefetch done", b"play cache key=", b"local file", b"NextTrackCache"]
hit = {n: 0 for n in needles}
with zipfile.ZipFile(apk) as z:
    for n in z.namelist():
        if n.endswith(".dex"):
            data = z.read(n)
            for nd in needles:
                if nd in data:
                    hit[nd] += 1
for k, v in hit.items():
    print(k.decode(), v)

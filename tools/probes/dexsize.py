import zipfile, os
a = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\JZ音乐助手-v2.1.69.apk"
b = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\JZ音乐助手-v2.1.70.apk"
for tag, p in (("2169", a), ("2170", b)):
    with zipfile.ZipFile(p) as z:
        d = {n: z.getinfo(n).file_size for n in z.namelist() if n.endswith(".dex")}
        print(tag, d, "total", sum(d.values()))

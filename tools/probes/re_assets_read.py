# -*- coding: utf-8 -*-
import io
import zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\lark-im-resources\file_v3_0017b_7d1a3d77-04bb-49d2-b75c-8f0330b1745g.apk"
z = zipfile.ZipFile(APK)
out = []
for n in ["assets/flutter_assets/assets/player/REFERENCE.md",
          "assets/flutter_assets/NativeAssetsManifest.json",
          "assets/flutter_assets/assets/skin_packs/thumbnails/sources.json",
          "assets/flutter_assets/FontManifest.json"]:
    try:
        data = z.read(n).decode("utf-8", "ignore")
    except Exception as e:
        data = "ERR %s" % e
    out.append("===== %s" % n)
    out.append(data[:3000])
    out.append("")
io.open(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\re_assets_read.txt", "w", encoding="utf-8").write("\n".join(out))
print("ok")

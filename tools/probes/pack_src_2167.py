# -*- coding: utf-8 -*-
"""把当前安卓工程打包成源码归档（与 v2.1.63 归档同口径：仅源码与资源，无构建产物、无 gradle wrapper、无 local.properties）。"""
import io, os, zipfile

SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\JZ音乐助手-安卓源码.zip"

INCLUDE_DIRS = [os.path.join("app", "src", "main")]
INCLUDE_FILES = [os.path.join("app", "build.gradle.kts"), os.path.join("app", "proguard-rules.pro"),
                 "build.gradle.kts", "gradle.properties", "settings.gradle.kts", "安卓APK安装说明.md"]

names = []
for d in INCLUDE_DIRS:
    base = os.path.join(SRC, d)
    for root, dirs, files in os.walk(base):
        dirs[:] = [x for x in dirs if x not in (".gradle", "build", ".idea")]
        for f in files:
            p = os.path.join(root, f)
            names.append((p, os.path.relpath(p, SRC).replace("\\", "/")))
for f in INCLUDE_FILES:
    p = os.path.join(SRC, f)
    if os.path.isfile(p):
        names.append((p, f.replace("\\", "/")))
    else:
        print("MISSING:", f)

names.sort(key=lambda t: t[1])
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    for p, arc in names:
        z.write(p, arc)

with zipfile.ZipFile(OUT) as z:
    print("entries:", len(z.namelist()))
    print("size:", os.path.getsize(OUT))
    print("zip test:", z.testzip())

# 版本一致性
g = io.open(os.path.join(SRC, "app", "build.gradle.kts"), encoding="utf-8").read()
for line in g.splitlines():
    if "versionCode" in line or "versionName" in line:
        print(line.strip())

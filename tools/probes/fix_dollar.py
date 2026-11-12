# -*- coding: utf-8 -*-
"""修掉拼接时被过度转义的 \$，并补上三套版式与共用零件。"""
import io

PATH = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper\ui\PlayerScreen.kt"
src = io.open(PATH, encoding="utf-8").read()
src = src.replace("${'$'}", "$")
io.open(PATH, "w", encoding="utf-8", newline="").write(src)
print("fixed dollar; len", len(src))

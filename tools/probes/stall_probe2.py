# -*- coding: utf-8 -*-
import os, time, subprocess

out = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\stall_probe2.txt"
apk = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"

q = ('Get-CimInstance Win32_Process -Filter "ProcessId=30356 or ProcessId=31384" '
     '| Select-Object -ExpandProperty CommandLine')
r = subprocess.run(["powershell", "-NoProfile", "-Command", q],
                   capture_output=True, text=True, encoding="utf-8", errors="replace")

stamp = time.strftime("%H:%M:%S", time.localtime(os.path.getmtime(apk)))
now = time.strftime("%H:%M:%S")

lines = []
lines.append("java cmdlines:")
lines.append((r.stdout or "").strip()[:1000])
lines.append("apk mtime = " + stamp + "  (仍是 v2.1.60，pager 改动未编入)")
lines.append("now       = " + now)
open(out, "w", encoding="utf-8").write("\n".join(lines))
print("\n".join(lines))

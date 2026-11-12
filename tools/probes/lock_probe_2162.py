# -*- coding: utf-8 -*-
"""定位 dex 目录里到底哪个文件被占用：逐个尝试删除并打印真实错误；顺带列出 java 进程。"""
import os, shutil, subprocess, io

D = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\intermediates\dex\release\mergeDexRelease"
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\lock_probe_2162.txt"

lines = []
if os.path.isdir(D):
    for name in sorted(os.listdir(D)):
        p = os.path.join(D, name)
        try:
            if os.path.isfile(p):
                with open(p, "r+b") as f:          # 试独占写
                    pass
                os.remove(p)
                lines.append("DELETED " + name)
            else:
                shutil.rmtree(p)
                lines.append("RMDIR " + name)
        except Exception as e:
            lines.append("LOCKED  %s -> %s: %s" % (name, type(e).__name__, e))
else:
    lines.append("dir absent")

q = 'Get-CimInstance Win32_Process -Filter "Name=\'java.exe\'" | Select-Object -ExpandProperty CommandLine'
r = subprocess.run(["powershell", "-NoProfile", "-Command", q], capture_output=True, text=True, encoding="utf-8", errors="replace")
lines.append("--- java procs ---")
for ln in (r.stdout or "").splitlines():
    lines.append(ln.strip()[:180])

io.open(OUT, "w", encoding="utf-8").write("\n".join(lines))
print("\n".join(lines))

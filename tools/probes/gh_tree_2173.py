import hashlib, subprocess, requests, io
p = subprocess.run([r"D:\Git\cmd\git.exe","credential","fill"], input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True)
tok=[l.split("=",1)[1] for l in p.stdout.splitlines() if l.startswith("password=")][0]
H={"Authorization":"token "+tok,"Accept":"application/vnd.github+json","User-Agent":"agent"}
root=requests.get("https://api.github.com/repos/thewonderfulkey/JZ-private-music-/git/trees/main",headers=H,timeout=60).json()
t05=[e["sha"] for e in root["tree"] if e["path"]=="05-源码归档"][0]
sub=requests.get(f"https://api.github.com/repos/thewonderfulkey/JZ-private-music-/git/trees/{t05}",headers=H,timeout=60).json()
for e in sub["tree"]: print("05 ->", e["path"], e["sha"])
local=io.open(r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\JZ音乐助手-安卓源码.zip","rb").read()
print("local zip md5", hashlib.md5(local).hexdigest().upper(), len(local))
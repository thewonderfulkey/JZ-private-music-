import zipfile, sys
apk = sys.argv[1]
out = sys.argv[2]
z = zipfile.ZipFile(apk)
dex = b"".join(z.read(n) for n in z.namelist() if n.endswith(".dex"))
kws = ["正在解析音源", "该曲最高只有", "已换源", "拿不到所选音质会自动换源"]
lines = []
for k in kws:
    lines.append("%s = %s" % (k, k.encode("utf-8") in dex))
lines.append("flux = %s" % (b"resolveForDownload" in dex))
lines.append("probe_gone = %s" % (b"SourceProbe" not in dex))
open(out, "w", encoding="utf-8").write("\n".join(lines))
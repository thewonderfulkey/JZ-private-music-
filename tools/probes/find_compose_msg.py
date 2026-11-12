import io, os, zipfile, sys

ROOT = r"C:\Users\17948\.gradle\caches\modules-2\files-2.1"
NEEDLE = b"left the composition"
hits = []
scanned = 0
for dirpath, dirnames, filenames in os.walk(ROOT):
    for fn in filenames:
        if not fn.endswith((".jar", ".aar")):
            continue
        p = os.path.join(dirpath, fn)
        scanned += 1
        try:
            with zipfile.ZipFile(p) as z:
                for n in z.namelist():
                    if not n.endswith(".class"):
                        continue
                    data = z.read(n)
                    if NEEDLE in data:
                        hits.append((p, n))
        except Exception:
            pass
print("scanned archives:", scanned)
for p, n in hits[:20]:
    print(os.path.basename(p), "->", n)
print("hits:", len(hits))

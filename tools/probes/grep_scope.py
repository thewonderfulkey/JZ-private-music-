# -*- coding: utf-8 -*-
import io, os, zipfile

ROOT = r"C:\Users\17948\.gradle\caches\modules-2\files-2.1"
needle = b"left the composition"
hits = []

def scan_classes(zf, path):
    for n in zf.namelist():
        if n.endswith(".class"):
            try:
                b = zf.read(n)
            except Exception:
                continue
            if needle in b:
                hits.append((path, n))

for dirpath, dirs, files in os.walk(ROOT):
    if "androidx" not in dirpath.lower():
        continue
    for f in files:
        if not (f.endswith(".jar") or f.endswith(".aar")):
            continue
        path = os.path.join(dirpath, f)
        try:
            if f.endswith(".aar"):
                with zipfile.ZipFile(path) as z:
                    if "classes.jar" not in z.namelist():
                        continue
                    data = z.read("classes.jar")
                with zipfile.ZipFile(io.BytesIO(data)) as zz:
                    scan_classes(zz, path)
            else:
                with zipfile.ZipFile(path) as zz:
                    scan_classes(zz, path)
        except Exception:
            pass

for p, n in hits[:40]:
    print(p)
    print("    ", n)
print("TOTAL", len(hits))

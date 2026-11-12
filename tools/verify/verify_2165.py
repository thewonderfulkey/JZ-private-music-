# -*- coding: utf-8 -*-
"""APK 静态验证（apk-verify skill 步骤1）：badging / apksigner / zip 完整性 / 组件核对。"""
import io, os, subprocess, zipfile, hashlib

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
SDK = r"C:\Users\17948\AppData\Local\Android\Sdk"
AAPT = os.path.join(SDK, r"build-tools\34.0.0\aapt2.exe")
SIGNER = os.path.join(SDK, r"build-tools\34.0.0\apksigner.bat")
OUT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\verify_2165.txt"
lines = []
def log(s):
    print(s, flush=True); lines.append(s)

log("APK %s  size=%d  md5=%s" % (APK, os.path.getsize(APK),
    hashlib.md5(io.open(APK, "rb").read()).hexdigest().upper()))
env = dict(os.environ); env["JAVA_HOME"] = r"C:\Users\17948\AppData\Local\Programs\jdk-17"
r = subprocess.run([AAPT, "dump", "badging", APK], capture_output=True, text=True, encoding="utf-8", errors="replace")
for ln in r.stdout.splitlines():
    if ln.startswith(("package:", "application-label", "sdkVersion", "targetSdkVersion", "launchable-activity")) \
            or "permission" in ln.lower() and "uses-permission" in ln:
        log(ln.strip()[:180])
r2 = subprocess.run([SIGNER, "verify", "--print-certs", APK], capture_output=True, text=True,
                    encoding="utf-8", errors="replace", env=env)
log("apksigner rc=%d" % r2.returncode)
for ln in (r2.stdout or "").splitlines():
    if "Signer" in ln or "SHA-256" in ln or "Verified" in ln:
        log(ln.strip()[:160])
if r2.returncode != 0:
    log("apksigner stderr: " + (r2.stderr or "")[:400])
with zipfile.ZipFile(APK) as z:
    bad = z.testzip()
    log("zip entries=%d  testzip=%s" % (len(z.namelist()), "OK" if bad is None else bad))
    man = z.read("AndroidManifest.xml")
    log("AndroidManifest.xml bytes=%d" % len(man))
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines))

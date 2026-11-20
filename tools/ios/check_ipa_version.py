"""校验 IPA 包内版本（二进制 Info.plist），输出版本/构建号/minOS/appex 数。"""
import glob
import os
import plistlib
import sys

root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ["TEMP"], "ipacheck")
apps = glob.glob(os.path.join(root, "**", "*.app"), recursive=True)
if not apps:
    print("没找到 .app")
    sys.exit(1)
app = apps[0]
with open(os.path.join(app, "Info.plist"), "rb") as f:
    pl = plistlib.load(f)
print("bundle id :", pl.get("CFBundleIdentifier"))
print("version   :", pl.get("CFBundleShortVersionString"))
print("build     :", pl.get("CFBundleVersion"))
print("minOS     :", pl.get("MinimumOSVersion"))
ex = glob.glob(os.path.join(root, "**", "*.appex"), recursive=True)
print("appex     :", [os.path.basename(e) for e in ex])

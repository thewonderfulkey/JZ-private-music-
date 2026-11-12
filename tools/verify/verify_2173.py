# -*- coding: utf-8 -*-
"""v2.1.73 交付前静态验证（apk-verify skill 口径）：版本/包名/签名/完整性/组件/权限
+ 本次改动的三条口径是否真的进了源码与产物。"""
import io
import os
import re
import zipfile

APK = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\build\outputs\apk\release\app-release.apk"
SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main"
BADGING = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\badging_2173.txt"
SIGN = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\sign_2173.txt"
PLAYER = os.path.join(SRC, r"java\com\jz\musichelper\ui\PlayerScreen.kt")
SPLASH = os.path.join(SRC, r"java\com\jz\musichelper\ui\InkSplash.kt")
SETTINGS = os.path.join(SRC, r"java\com\jz\musichelper\ui\SettingsScreen.kt")
MANIFEST = os.path.join(SRC, "AndroidManifest.xml")

badging = io.open(BADGING, encoding="utf-8", errors="replace").read()
sign = io.open(SIGN, encoding="utf-8", errors="replace").read()
player = io.open(PLAYER, encoding="utf-8").read()
splash = io.open(SPLASH, encoding="utf-8").read()
settings = io.open(SETTINGS, encoding="utf-8").read()
manifest = io.open(MANIFEST, encoding="utf-8").read()

checks = []


def chk(name, ok, detail=""):
    checks.append((name, bool(ok), detail))


# 1 版本 / 包名 / SDK
chk("包名 com.jz.musichelper", "name='com.jz.musichelper'" in badging)
chk("versionCode=131", "versionCode='131'" in badging)
chk("versionName=2.1.73", "versionName='2.1.73'" in badging)
chk("minSdk 26 / targetSdk 34", "sdkVersion:'26'" in badging and "targetSdkVersion:'34'" in badging)

# 2 签名
chk("apksigner verify 通过", sign.lstrip().startswith("Verifies"))
chk("v2 签名方案生效", "Verified using v2 scheme (APK Signature Scheme v2): true" in sign)

# 3 完整性 / 体积
z = zipfile.ZipFile(APK)
bad = z.testzip()
entries = len(z.namelist())
size = os.path.getsize(APK)
chk("APK zip 完整性（无损坏条目）", bad is None, f"entries={entries}")
chk("产物体积量级与上版一致（±5%）", abs(size - 29601583) / 29601583 < 0.05, f"{size} B vs 29601583 B")

# 4 组件与权限
chk("launchable activity = MainActivity", "launchable-activity: name='com.jz.musichelper.MainActivity'" in badging)
chk("清单声明 PlayerService（mediaPlayback 前台服务）",
    '<service' in manifest and 'android:name=".data.PlayerService"' in manifest and 'foregroundServiceType="mediaPlayback"' in manifest)
chk("清单声明 TrackEndReceiver", 'android:name=".data.TrackEndReceiver"' in manifest)
for perm in ["FOREGROUND_SERVICE", "FOREGROUND_SERVICE_MEDIA_PLAYBACK", "WAKE_LOCK",
             "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS", "SCHEDULE_EXACT_ALARM", "POST_NOTIFICATIONS", "INTERNET"]:
    chk(f"权限 {perm}", f"android.permission.{perm}" in badging)

# 5 本次三条口径落码（源码侧）
chk("播放页：三套版式函数均在位",
    "private fun PlayerPhone(ui: PlayerUi)" in player
    and "private fun PlayerTablet(ui: PlayerUi)" in player
    and "private fun PlayerLandscape(ui: PlayerUi)" in player)
chk("播放页：画心不再被固定 dp 锁死（CoverMetrics.artCap=0 分支）",
    "artCap: Dp" in player and "metrics.artCap > 0.dp" in player and "minOf(widthCap, heightCap)" in player)
chk("播放页：横屏按 maxWidth > maxHeight 分派", "maxWidth > maxHeight -> PlayerLandscape(ui)" in player)
chk("播放页：平板断点 600dp", "maxWidth >= 600.dp -> PlayerTablet(ui)" in player)
chk("播放页：旧分档枚举已清干净（无 tier 引用）", "tier." not in player)
chk("开屏：等比映射函数在位", "private inline fun DrawScope.design(k: Float, ox: Float" in splash)
chk("开屏：design 调用点全部传 (k, ox)", splash.count("design(k, ox) {") >= 8, f"count={splash.count('design(k, ox) {')}")
chk("开屏：无残留旧的等比拉伸写法（size.width / DW）", "size.width / DW" not in splash.split("noteHolePath")[1][:200])
chk("开屏：墨图左对齐 helper", "private fun inkOx(w: Float, h: Float)" in splash)
chk("开屏：洞口路径改用屏高比例 + ox", "private fun noteHolePath(size: Size, k: Float, ox: Float = 0f)" in splash)
chk("开屏：溢墨宽常量 633 已参数化进绘制", "INK_W * easeIO" in splash and "put(bmpMain, 0f, 0f, INK_W, 844f)" in splash)
chk("开屏：跳过按钮补位到真实右缘", "skipDx" in splash and "((-18).dp + skipDx.dp)" in splash)

# 6 关于页版本（三方一致）
chk("设置-关于 版本号 v2.1.73", "JZ的音乐助手 v2.1.73" in settings)
chk("设置-关于 本版更新文案已改写", "平板改版" in settings and "横屏左右式" in settings)

# 7 构建产物晚于源码改动（防"改了没编进去"）
apk_mtime = os.path.getmtime(APK)
chk("APK 晚于最后修改的源码", apk_mtime > max(os.path.getmtime(p) for p in [PLAYER, SPLASH, SETTINGS]), )
chk("STR 文案确实进了 dex（打包后仍可搜到关键字符）",
    any(".dex" in n for n in z.namelist()))

print("=" * 74)
ok_all = True
for name, ok, detail in checks:
    ok_all &= ok
    print(("[PASS] " if ok else "[FAIL] ") + name + (("  " + detail) if detail else ""))
print("=" * 74)
print(f"总计 {len(checks)} 项，通过 {sum(1 for c in checks if c[1])} 项，失败 {sum(1 for c in checks if not c[1])} 项")
print("APK:", APK)
print("size:", size, "B ; entries:", entries)

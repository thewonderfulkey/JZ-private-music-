"""把 App 显示名统一成「JZ 音乐」：Info.plist 已改，这里改界面与文档里的遗留文案。"""
from pathlib import Path

OLD = "JZ的音乐助手"
NEW = "JZ 音乐"

TARGETS = [
    "ios/JZMusicHelper/Views/SearchView.swift",
    "ios/JZMusicHelper/Views/SettingsView.swift",
    "ios/JZMusicHelper/Services/DownloadManager.swift",
]

for name in TARGETS:
    p = Path(name)
    s = p.read_text(encoding="utf-8")
    n = s.count(OLD)
    if n:
        p.write_text(s.replace(OLD, NEW), encoding="utf-8")
    print(f"{name}: 替换 {n} 处")

# 文档：ROLLOUT §2 那行补上定稿口径与图标说明
doc = Path("docs/ios/IOS-ROLLOUT.md")
s = doc.read_text(encoding="utf-8")
s = s.replace(
    "| `CFBundleDisplayName` | JZ 音乐（与 APK「JZ的音乐助手」保持一致，过长会截断） |",
    "| `CFBundleDisplayName` | **JZ 音乐**（与安卓「JZ的音乐助手」故意区分：iOS 图标下只能显示 5–6 个字，"
    "「JZ的音乐助手」会被截成「JZ的音…」；定稿见 §0 的口径） |",
)
doc.write_text(s, encoding="utf-8")
print("IOS-ROLLOUT.md: 显示名口径已更新")

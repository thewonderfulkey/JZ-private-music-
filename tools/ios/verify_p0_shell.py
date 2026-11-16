"""P0 验收自检：单导航、5 Tab、Sources 阶段成员、旧文件清理。"""
from __future__ import annotations

import re
from pathlib import Path

SWIFT = list(Path("ios").rglob("*.swift"))
pbx = Path("ios/JZMusicHelper.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
phase = re.search(r"PBXSourcesBuildPhase;.*?\);", pbx, re.S).group(0)


def count_swift(needle: str) -> int:
    return sum(p.read_text(encoding="utf-8").count(needle) for p in SWIFT)


print("=== 单导航检查 ===")
print('Label("历史" 次数:', count_swift('Label("历史"'))
print('Label("设置" 次数:', count_swift('Label("设置"'))
print('TabView( 次数:', count_swift("TabView("))
print(".tabItem 次数:", count_swift(".tabItem"))

print("\n=== Sources 编译阶段（新文件应 =1，旧文件应 =0）===")
for name in ["RootTabView", "DiscoverView", "SearchTabView", "RecognizeView", "DownloadsTabView",
             "LibraryView", "Components", "LibraryStore", "SettingsStore",
             "Tokens", "Haptics", "CoverResolver"]:
    print(f"  {name}.swift :", len(re.findall(rf"{name}\.swift in Sources", phase)))
print("  --- 已删除的旧文件 ---")
for name in ["MainTabView", "SearchView", "HistoryView", "DownloadsView", "PlayerManager", "HistoryStore"]:
    print(f"  {name}.swift :", len(re.findall(rf"{name}\.swift in Sources", phase)))

print("\n=== 磁盘上是否还有旧文件 ===")
for name in ["MainTabView.swift", "SearchView.swift", "HistoryView.swift", "DownloadsView.swift",
             "PlayerManager.swift", "HistoryStore.swift"]:
    hits = [str(p) for p in SWIFT if p.name == name]
    print(f"  {name}: {'仍在 ' + hits[0] if hits else '已删除'}")

print("\n=== 5 Tab 顺序（按文件行号）===")
root = Path("ios/JZMusicHelper/Views/RootTabView.swift").read_text(encoding="utf-8").splitlines()
for i, line in enumerate(root, 1):
    if ".tabItem" in line:
        print(f"  RootTabView.swift:{i}  {line.strip()}")

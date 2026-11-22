#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""收藏爱心的「观测契约」闸门（2026-11-23，v2.4.86）

背景（老板真机反馈）：在「热门音乐 → 查看全部」里点爱心，收藏**真的**加成/取消了，
爱心却只是抖一下、不变红。真因不是收藏逻辑，而是视图**丢了对 `favorites` 的订阅**：
`@Observable` 的订阅粒度是「这次 body 求值里读过哪些属性」，而
`LibraryStore.isFavorite` 为了性能挂了一张非观察的判定缓存，命中时一个属性都不读
就直接 return —— 于是那些只靠 `isFavorite` 拿爱心状态的行，数据变了、界面不重画。

这条闸门钉两件事：
  ① `LibraryStore.isFavorite` 必须**真读** `favorites`（把 `.count` 当参数交给
     `FavoriteObservation.cached`），且不许退回"命中缓存直接 return"的老写法；
  ② 所有挂爱心的列表页必须继续走 `library.isFavorite(...)`（不许把收藏状态塞进
     `@State` / 传常量 Bool —— 那样同样会僵住）。

跑法：python3 tools/ios/check_favorite_heart.py
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STORE = os.path.join(ROOT, "ios/JZMusicHelper/Models/LibraryStore.swift")

# 挂了爱心、且状态必须跟着收藏表走的所有列表页（一个都不能漏）
HEART_SURFACES = [
    "ios/JZMusicHelper/Views/ChartSongsView.swift",      # 榜单「查看全部」← 老板这次报的
    "ios/JZMusicHelper/Views/SearchTabView.swift",       # 搜索结果
    "ios/JZMusicHelper/Views/ArtistDetailView.swift",    # 歌手页
    "ios/JZMusicHelper/Views/PlaylistDetailView.swift",  # 歌单广场详情
    "ios/JZMusicHelper/Views/NewSongsView.swift",        # 最新单曲「查看全部」
    "ios/JZMusicHelper/Views/MyPlaylistViews.swift",     # 我的歌单
]

errors = []
notes = []


def read(rel):
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        errors.append("找不到文件：%s" % rel)
        return ""
    with io.open(path, encoding="utf-8") as fh:
        return fh.read()


def function_body(text, signature):
    """从 `signature` 那一行起，截到下一个同缩进的 `}`（够用：这些函数体里没有嵌套花括号收尾）"""
    start = text.find(signature)
    if start < 0:
        return None
    end = text.find("\n    }", start)
    if end < 0:
        return text[start:]
    return text[start:end]


# ① 判定函数本身
store = read("ios/JZMusicHelper/Models/LibraryStore.swift")
body = function_body(store, "func isFavorite(")
if body is None:
    errors.append("LibraryStore 里找不到 `func isFavorite(`")
else:
    if "favorites.count" not in body:
        errors.append(
            "LibraryStore.isFavorite 没有真读 `favorites.count`：\n"
            "    命中判定缓存就 return 会让视图悄悄丢掉对收藏的订阅 → 点了爱心图标不动。\n"
            "    写法见 FavoriteObservation（Models 旁的 Services/NameMatch.swift）。")
    if "FavoriteObservation.cached(" not in body:
        errors.append("LibraryStore.isFavorite 没有走 `FavoriteObservation.cached(_, favoritesCount:)`")
    if re.search(r"if\s+let\s+hit\s*=\s*favoriteMatchCache\[", body):
        errors.append(
            "LibraryStore.isFavorite 又退回「命中缓存直接 return」的老写法了"
            "（这正是 v2.4.85 之前爱心不动的根因）")

# ② 判定器还在（读数量这件事是结构性的，不许改成 `_ = favorites`）
name_match = read("ios/JZMusicHelper/Services/NameMatch.swift")
if "enum FavoriteObservation" not in name_match:
    errors.append("Services/NameMatch.swift 里的 `enum FavoriteObservation` 不见了")
elif "guard favoritesCount > 0 else { return nil }" not in name_match:
    errors.append("FavoriteObservation.cached 的语义变了（应当：收藏为空则不采信缓存）")

# ③ 所有挂爱心的列表页仍走真实判定
for rel in HEART_SURFACES:
    text = read(rel)
    if not text:
        continue
    if "isFavorite: library.isFavorite(" not in text:
        errors.append(
            "%s 没有把收藏状态接到 `library.isFavorite(...)` 上"
            "（塞进 @State / 传常量都会让爱心僵住）" % os.path.basename(rel))
    if re.search(r"@State[^\n]*\bisFavorite\b", text):
        errors.append("%s 把收藏状态存进了 @State（收藏表一变它不会跟着变）" % os.path.basename(rel))

# ④ 行组件里的爱心必须由传入的值驱动（不是自己的状态）
components = read("ios/JZMusicHelper/Views/Components.swift")
if 'isFavorite ? "heart.fill" : "heart"' not in components:
    errors.append("Components.swift 的 SongRow 爱心不再由 `isFavorite` 驱动")

# ⑤ 另外两个常驻爱心（迷你条 / 播放页）也必须直连收藏表
for rel in ["ios/JZMusicHelper/Views/MiniPlayerBar.swift",
            "ios/JZMusicHelper/Views/NowPlayingView.swift"]:
    if "library.isFavorite(" not in read(rel):
        errors.append("%s 的爱心没有接 `library.isFavorite(...)`" % os.path.basename(rel))

if len(HEART_SURFACES) != 6:
    errors.append("HEART_SURFACES 清单被改动过（新加爱心列表页请一起加进来）")

if errors:
    print("❌ 收藏爱心的观测契约检查未通过：")
    for e in errors:
        print("   · " + e)
    sys.exit(1)

print("✅ 收藏爱心观测契约通过：判定函数真读 favorites，%d 个列表页都接在 library.isFavorite 上"
      % len(HEART_SURFACES))
for n in notes:
    print("   · " + n)

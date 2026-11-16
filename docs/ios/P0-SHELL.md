# P0 外壳与五页骨架：落地对照

> 落地于 `ae3fa7d`（2026-11-16），CI run #43817286344 全绿，IPA 887.7 KB，已发飞书群。
> 设计依据：[IOS-IA-SCREENS.md](IOS-IA-SCREENS.md)、[IOS-UI-DESIGN.md](IOS-UI-DESIGN.md)。

## 1 设计元素 → 代码位置

| 设计稿元素 | 代码位置 |
|---|---|
| **5 Tab 顺序**（发现/搜索/识曲/下载/资料库） | `Views/RootTabView.swift:32/39/47/55/63`（`.tabItem` 五处，顺序即此） |
| **纸底** `Tokens.Palette.paper` | `RootTabView.swift:29/37/44/52/61`（五个 Tab 根视图 `.paperBackground()`）；`SettingsView.swift:105`（`.background(Tokens.Palette.paper)`） |
| **SongRow**（§2.1） | 定义 `Views/Components.swift:62`；使用 `SearchTabView.swift:101`、`LibraryView.swift:47`、`DiscoverView.swift:118`、`RecognizeView.swift:163` |
| **平台状态行**（§2.5） | 定义 `Views/Components.swift:185`；使用 `SearchTabView.swift:90` |
| **资料库分段**（收藏/最近播放） | `Views/LibraryView.swift:25`（`Picker("分段")`，`.segmented`） |
| **设置入口**（资料库右上 gear） | `Views/LibraryView.swift:68-72`（`NavigationLink { SettingsView() }` + `gearshape`） |
| Mini Player 常驻（safeAreaInset） | `RootTabView.swift:66-73` |
| 空态 / 骨架 / 待接入占位 | `Components.swift` 的 `EmptyStateView` / `SkeletonRows` / `PendingFeatureRow` |

## 2 单导航自检（不允许两套并存）

```
SwiftUI Label("历史") : 0
SwiftUI Label("设置") : 0
TabView 视图          : 1
.tabItem              : 5
```

已删除：`MainTabView.swift`、`SearchView.swift`、`HistoryView.swift`、`DownloadsView.swift`、
`PlayerManager.swift`、`HistoryStore.swift`（源码与 pbxproj 同时移除，`Sources` 阶段里各自 0 处）。

## 3 每页：真实数据 / 骨架 分界

| 页面 | 已是真实数据 | 仍只是骨架（明确不假装） |
|---|---|---|
| 发现 | 最近播放（`LibraryStore`，持久化）；猜你喜欢（由最近播放真实派生） | 编辑精选 = 3 个**静态分类**（无假歌单，卡片下写明"随 P1 接入"）；热门榜单 = 待接入占位 |
| 搜索 | 四平台并发搜索 + 合并排序、平台状态行真实条数、搜索历史、**已隐藏 N 首无音源**（`PlayerEngine.deadSongKeys`） | — |
| 识曲 | 麦克风舞台、聆听倒计时（12/15/20 秒）、辨认中、取消、最近识过（`LibraryStore`） | 酷狗指纹通道已接（P3 第一段，见 [IOS-RECOGNIZE.md](IOS-RECOGNIZE.md)）：真实采集 → 打分 → 结果卡 + 其他版本；网易 afp 通道下一段补 |
| 下载 | 下载记录与进度（`DownloadManager`，真实数据源） | — 下载动作已于 P2 接上（音质选择 / 三级换源 / 后台下载 / 95% 体积校验，见 [IOS-DOWNLOADS.md](IOS-DOWNLOADS.md)）；入口：播放页「下载」、搜索结果与资料库长按「下载…」 |
| 资料库 | 收藏（增删持久化）、最近播放、播放全部/随机 | — |
| 设置 | 外观、音质、歌词字号/动画、识曲时长、清空数据（真实生效） | 「无源自动换源 / 跨平台补源 / 跳过上限 / 仅 Wi-Fi / 后台下载」**键已存**但引擎尚未消费（随 P1/P2 接） |

## 4 旧播放器的清理

- `PlayerManager` 已删；`SongDetailView` 重写为 **`SourceDetailView`**（音源详情），数据全部读 `PlayerEngine` 当前状态，不再自己发解析请求；入口在播放页「⋯ → 音源详情」。
- 下载记录不再借 `HistoryStore`，由 `DownloadManager` 自己落盘（`downloads.json`）。

## 5 下一轮

1. 编辑精选 / 热门榜单的真数据源（歌单池）→ 接上后这两块从骨架变实数据。
2. 设置里那几个开关让引擎真正消费（换源开关、跳过上限）。
3. ~~P2 下载：音质选择弹层 + `DownloadResolver.plan` + 95% 体积校验。~~ **已完成**（`DownloadFlow` / `DownloadSheet` / `DownloadGuard`，见 [IOS-DOWNLOADS.md](IOS-DOWNLOADS.md)），待装机验收。
4. P3 识曲：指纹通道 + 打分 + 结果页。

# 列表页「定位到正在播放」

> iOS v2.4.34（212） · 2026-11-20 · 老板第 44 轮需求

## 一句话

每个**歌曲列表页**右上角多一颗「定位」：点一下，列表滚到**正在播放的那一行**并闪一下；
当前这首不在这张列表里，就浮一句轻提示——不弹窗、不改播放、不动队列。

## 1 需求与边界

老板原话（2026-11-20）：

> 现在有个新功能需要添加，随着歌单越来越多，列表也越来越多，想要快速定位到当前播放的那一首歌在哪个位置，
> 需要有个按钮添加到所有列表页。

当场确认的两点：

| 问题 | 答案 |
|---|---|
| 改哪一端 | **只做 iOS**（Android / Windows 桌面不动） |
| 点下去什么效果 | **滚到那首 + 高亮闪一下**；不在本列表 → 提示「当前歌曲不在此列表」 |

## 2 覆盖范围

「列表页」= 整页就是一列歌、用户会往下滑很久的页面。**共 8 个**：

| 页面 | 文件 | 队列 / 行数据 |
|---|---|---|
| 我的收藏 | `Views/LibraryView.swift`（`FavoritesView`） | `library.favorites` |
| 下载（已下载段） | `Views/DownloadsTabView.swift` | `downloads.completedSongs`（行按 `DownloadItem.id`） |
| 搜索结果 | `Views/SearchTabView.swift`（`SearchView`） | `visibleSongs` |
| 榜单「查看全部」 | `Views/ChartSongsView.swift` | `page.songs` |
| 最新单曲「查看全部」 | `Views/NewSongsView.swift` | `feed.newReleases` |
| 歌单广场 → 歌单详情 | `Views/PlaylistDetailView.swift` | `detail.releases` |
| 我的歌单 → 歌单详情 | `Views/MyPlaylistViews.swift`（`MyPlaylistDetailView`） | `playlist.songs` |
| 歌手页「热门歌曲」 | `Views/ArtistDetailView.swift` | `releases` |

**故意不加的**（避免"按钮在、但没有意义"）：

- 发现页的横滑模块（歌单广场 / 歌手大全 / 最近播放 / 最新单曲卡片 / 猜你喜欢 / 热门音乐）：
  它们是"三行一页 / 横滑卡片"，不是能一直往下滑的长列表，而且发现页同时有六个模块——
  一颗按钮定位到哪一个模块都说不清。
- 歌手大全、歌单广场整页：列的是**歌单/歌手**，没有"某一首歌在第几行"。
- 播放页的「播放列表」：本来就把当前项标成波形 + 「正在播放」胶囊，再加一颗按钮是重复。

## 3 判定口径：`Services/ListLocate.swift`

为什么不能只比 `Song.id`：`id` = 平台 + 平台内 id，只会出现在"当初按这份数据起播"的那张列表里。
在收藏里点播了网易版《晴天》，进榜单页（酷我 rid）就比不上——但那确实是同一首歌。

两步：

1. **`id` 精确命中**（同一条数据，零歧义）。同一首在列表里出现两遍时取**第一处**。
2. **跨平台同一条录音**，四个条件全过才算：

   | 条件 | 说明 |
   |---|---|
   | 版本类**相等**（`NameMatch.versionClass`） | 原唱 / Live / 伴奏 / 翻唱 / DJ 之间互不定位（不是"子集"，是相等） |
   | 歌名归一化相近（`NameMatch.titleMatches`） | 去括号版本说明 + 去标点后相等，或长度差 ≤6 且互相包含 |
   | 歌手有交集（`NameMatch.singerMatches`） | 任一方没写歌手时这条不拦（与全 App 同口径） |
   | 时长差 ≤4s（`NameMatch.maxDurationDiffSec`） | 两边都有时长才卡；缺时长时上面三条已经够严 |

**为什么比 `NameMatch.sameRecording` 更严**：那套口径是给「搜索 / 换源」用的——候选集已经被歌名约束过，
所以它允许"歌手 + 时长对上、歌名不同"（译名场景）。放在一张完整列表上就危险了：同一位歌手两首时长相近
（《晴天》269s / 《七里香》270s）会被判成同一首、定位到隔壁那行。定位这个动作**宁可不跳，也不能跳错行**，
所以多加了一道 `titleMatches`，版本类也从"候选是源的子集"改成"双方相等"。

**已知且接受的边界**：译名不同的同一首（《연애의 조건》/《恋爱的条件》）**不认**，会提示"不在这个列表里"。
把它放进 `sameRecording` 会连带把同歌手的另一首误认进来，不值得。

## 4 交互与实现：`Views/NowPlayingLocate.swift`

三块，页面只负责接线（`@State private var locator = SongLocator()`）：

- `SongLocator`：状态与动作（滚动 / 高亮 / 提示 / VoiceOver 播报）
- `LocateNowPlayingButton`：导航栏右侧那颗按钮（箭头 + 「定位」，浅朱砂胶囊）
- `.locatedFlash(active:)` / `.locateToast(_:)`：行高亮与轻提示

### 滚动

与播放页歌词「回到当前」（`NowPlayingView.pinLine`）同一套：`LazyVStack` 远跳时第一次 `scrollTo`
常常只把目标行实例化、落点并不居中，所以在 **0 / 60 / 160 / 340ms 各贴一次**（`anchor: .center`），
任一次贴中画面就稳定。教训来自 r77：只补一次"下一拍"在真机上常常还不够。

### 高亮

朱砂淡底（14%）+ 左侧 3pt 竖条，**1.6s 后 0.45s 淡出**。高亮记的是 `Song.id`（不是行下标），
所以列表数据刷新（收藏/下载增删）时不会串行。Reduce Motion 下不做额外动效，只保留淡入淡出。

### 提示

| 情况 | 文案 |
|---|---|
| 没在播放 | 还没有在播放的歌 |
| 当前歌不在这张列表 | 《歌名》不在这个列表里 |
| 列表还在加载 / 本来就是空 | 列表还是空的 |

1.8s 自动消失，`ToastView` 浮在迷你条上方，不吃点击。

### 下载页的特殊处理

同一首歌可以下载两档音质（320k / 无损），两行的 `song.id` 相同——用 `song.id` 当 ScrollView 行 id 会撞。
所以行 id 用 `DownloadItem.id.uuidString`，`SongLocator` 的另一个重载允许传入与 `songs` 一一对应的
`rowIDs: [String]`（路由统一用 `String`，避开 `UUID` / `String` 混用时的类型推断歧义）。

### VoiceOver

滚动之后 `UIAccessibility.post(.announcement, "已定位到第 N 首：歌名")`；只滚动不播报的话，
读屏用户不知道停在哪一行。

## 5 文件清单

新增：

- `ios/JZMusicHelper/Services/ListLocate.swift`（纯逻辑，进 SelfTest 编译清单）
- `ios/JZMusicHelper/Views/NowPlayingLocate.swift`（组件）

改动：8 个列表页 + `ios/SelfTest/main.swift` + `.github/workflows/ios-ipa.yml`（selftest 编译清单）
+ `ios/JZMusicHelper.xcodeproj/project.pbxproj`（`tools/ios/add_pbx_files.py` 登记两个新文件）。

## 6 断言（`SelfTest` 第 44 节，13 条）

`id` 精确命中 / 重复取第一处 / 没在播放 / 空列表 / 跨平台同曲（时长差 1s）/ 原唱 ↔ Live 双向不认 /
时长差 11s 不认 / 同歌手同时长另一首不误认 / 同名不同歌手不认 / 缺歌手靠歌名 + 时长命中 /
译名不同不认。

## 7 验证与遗留

- 本机是 Windows，没有 Swift 工具链：**编译与断言由 CI 跑**（`logic-tests` job 的 `swiftc` + 全部断言），
  IPA 由 `build-ipa` job 出包。
- 离线能判的先判掉了：`tools/ios/check_pbxproj.py`（对象引用/漏挂）与 `tools/ios/check_ui_hygiene.py`
  （硬编码字号 / 固定行高）在本机已通过。
- 真机观感（滚动落点、高亮时长、导航栏按钮与各页标题的挤压）需要装机确认——尤其
  `List`（下载页）里 `ScrollViewReader.scrollTo` 的落点，模拟器/真机表现可能与 `LazyVStack` 略有差别。

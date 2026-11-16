# iOS 产品体验整改（2026-11-16，老板真机录屏 7 项）

> 来源：老板在开发群发的真机录屏（70s，16:46 那版）。逐条对照后改的是 **iOS 版当前代码**，
> 不是录屏里那一版原型——录屏那版还是 4 Tab（搜索/下载/历史/设置）的 P0 外壳，
> 但 7 条问题在当前代码里都真实存在。每条的"改前 → 改后"和验证方式写在下表。

## 一、逐条结果

| # | 老板原话 | 问题定位（改前） | 改法（改后） |
|---|---|---|---|
| ① | 编辑精选模块太长太大，参考 APK 是长方形 | `DiscoverView` 里是 160×160 的**正方形**大卡，4 张横滑，占掉首屏一半高度 | 改成 **170×64 的长方形纸卡**（对齐 Android `EditorCard` 150×66dp 的比例）：左侧 3pt 类色条 + 歌单名 + 「20 首 · 每日换一批」+ 右箭头。横向一行放得下 2 张半，不再顶掉下面的模块 |
| ② | 猜你喜欢和热门音乐排版丑、没设计感 | 两段都是「分隔线列表」：猜你喜欢一行带一句灰副标题、热门是「01 + 48 封面 + 平台胶囊 + 时长」，两段还长得不一样 | 两段统一成 **三行一页的翻页列表卡**（对齐 APK 的 HorizontalPager）：纸色卡底 + 细描边 + 一行 46pt 封面 + 歌名 + 副行 + 右侧播放三角；猜你喜欢的副行是「因为你在听 X」，热门是名次（前三名朱砂）；底部一排小胶囊做翻页指示。两段共用同一个 `DiscoverSongRow`，不会再各长各的 |
| ③ | 点歌播放只像拉起一张布，没覆盖整页 | 播放页是 `.sheet` + `.presentationDetents([.large])`：圆角、顶部漏出下层页面 | 改 **`.fullScreenCover`**（RootTabView），真满屏；收起方式给两条：左上角 chevron.down、或按住顶部往下拽 90pt。顶部加了一条 36×5 的小横条做抓手暗示 |
| ④ | 歌词没有正常返回，都是空 | 两层原因：**(a) 酷狗三个端点写的是 `http://`**，iOS ATS 默认拒绝明文请求（-1022），整条酷狗歌词源在真机上是死的（本地 Python 探针能通，是因为 urllib 没有 ATS）；**(b) 歌词藏在"点封面"后面**（`showLyrics` 默认 false），不点就永远看不见 | (a) 三处端点换 `https://`（实测 200）+ `Info.plist` 补 ATS 例外兜住其它明文音频地址；(b) 播放页封面下面**直接跟一块常驻歌词面板**（当前行逐字高亮、上下淡出、自动滚到中间），空态写明「这首歌还没取到歌词」+「重试」，打开播放页时若仍为空会自动再取一次（`PlayerEngine.reloadLyrics`） |
| ⑤ | 悬浮栏没有收藏/上一首/下一首，只有一个暂停；还把底层栏挡住了 | `MiniPlayerBar` 只有一个播放键，且挂在 **TabView** 的 `safeAreaInset` 上 → 条子盖在 Tab 栏之上，播歌后点不到其它 Tab | 四个键：**收藏 / 上一首 / 播放暂停 / 下一首**（各自 44pt 命中区）；挂载改成挂在**每个 Tab 的 NavigationStack** 上（`miniPlayerInset`），inset 只挤压内容区，Tab 栏完整可见可点；push 到搜索页/歌单页时条子照样在 |
| ⑥ | 搜索希望放在发现页最上方，不是一个 Tab | 5 Tab（发现/搜索/识曲/下载/资料库），搜索占一整格 | 搜索**从 Tab 里撤掉**，入口做成发现页第一行（胶囊搜索框）；点开 push 到 `SearchView`（自动聚焦键盘、自带返回）。Tab 收回 4 个：发现/识曲/下载/资料库。快捷指令「搜索歌曲」仍可用：写进 `router.pendingSearch`，发现页看到就把搜索页推到前台 |
| ⑦ | 搜索结果没去重，参考 APK 的去重方法 | 只做了「同平台同 ID」去重，跨平台/同平台不同 ID 的同一首歌全留着（录屏里《倔强》一屏 5 条、《夜曲》四家各一条） | 移植 APK v2.1.10 的 `songDedupeKey`：`归一化(歌名)|归一化(歌手)`，归一化 = 小写 → 还原 `\u0026`/`&nbsp;` → 只留 `0-9a-z` 与汉字。**先排序再 distinct**，所以留下的是匹配度最高的那条（平台位次先验也算在内）。被合并掉的其他平台版本不丢，点播放时仍由跨平台补源兜底 |

### 顺带修掉的一个真机可见脏数据

录屏里歌手显示成 `周杰伦\u0026Lara梁心颐`——QQ 接口把 `&` 双重转义成**字面量** `\u0026` 返回。
新增 `TextClean`（`Models/Song.swift`）：还原字面量 `\uXXXX` + 清 `&nbsp;/&amp;/` 零宽字符/BOM，
并在 `Song.make(...)` 里统一入口清洗，搜索/收藏/下载/锁屏四处都不会再看到反斜杠。

## 二、改动的文件

```
ios/JZMusicHelper/Models/Song.swift              + TextClean + Song.make
ios/JZMusicHelper/Services/SearchAdapters.swift   4 个适配器改走 Song.make
ios/JZMusicHelper/Services/SearchRanker.swift     + dedupeKey / normalizedKey / dedupe
ios/JZMusicHelper/Services/SearchService.swift    searchRanked 里做跨平台去重
ios/JZMusicHelper/Services/LddcLyrics.swift       酷狗三端点 http → https
ios/JZMusicHelper/Services/AudioPlayer.swift      + reloadLyrics()
ios/JZMusicHelper/Services/AppRouter.swift        4 Tab + showPlayer（播放页全屏）
ios/JZMusicHelper/Info.plist                      + NSAppTransportSecurity 允许明文
ios/JZMusicHelper/Views/RootTabView.swift         4 Tab / 全屏播放页 / 每条 Tab 挂迷你条
ios/JZMusicHelper/Views/DiscoverView.swift        重写：搜索入口 / 长方形卡 / 分页列表卡
ios/JZMusicHelper/Views/SearchTabView.swift       重写为 SearchView（push 页，不再是 Tab）
ios/JZMusicHelper/Views/MiniPlayerBar.swift       重写：四键 + miniPlayerInset
ios/JZMusicHelper/Views/NowPlayingView.swift      重写：满屏 + 歌词常驻 + 重试
ios/JZMusicHelper/Views/HotChartView.swift        行样式并入 DiscoverSongRow
ios/JZMusicHelper/Views/LibraryView.swift         点歌进播放页
ios/JZMusicHelper/Views/DownloadsTabView.swift    点本地歌进播放页
ios/JZMusicHelper/Views/EditorPlaylistView.swift  点歌进播放页
ios/JZMusicHelper/Views/RecognizeView.swift       结果/其他版本进播放页
ios/SelfTest/main.swift                           +17 条断言（文本清洗 8 + 跨平台去重 9），总数 363 条
```

## 三、怎么验的（以及验不到什么）

| 项 | 手段 | 结论 |
|---|---|---|
| 纯逻辑口径 | `swiftc` 编译 SelfTest 并跑全部断言（CI logic-tests job） | **363 条全绿**（本轮 +17：文本清洗 8 条、跨平台去重 9 条） |
| 界面卫生 | `tools/ios/check_ui_hygiene.py` | 18 个界面文件通过（无硬编码字号、无常量行高截断文本） |
| 工程结构 | `tools/ios/check_pbxproj.py` | 175 对象 / 2 target 通过（本轮没加新文件，不需要改 pbxproj） |
| 语法 | tree-sitter-swift 解析 `ios/**/*.swift` | 66 个文件 0 个 ERROR/MISSING 节点 |
| 能否编译 | `xcodebuild`（CI build-ipa job） | ✅ **BUILD SUCCEEDED** |
| 扩展是否进包 | CI 的 `unzip -l` 门禁 | ✅ `PlugIns/JZWidgets.appex`（260,440 B）在包里 |
| 真机观感 | **验不到**：开发机是 Windows，没有 iPhone/模拟器 | 录制里那 7 条都属于"看得见"的问题，改完仍需装机确认：编辑精选卡够不够小、翻页手感、满屏播放页、歌词真的出来了、迷你条四键、发现页顶部搜索、搜索结果条数 |

## 四、本轮出的包

| 项 | 值 |
|---|---|
| 文件 | `JZ-Music-v2.1.95-075fe1f-r54-ios-unsigned.ipa` |
| 大小 | 1.49 MB |
| SHA-256 | `93063f077196f3f94200d114a4383e64a870b5287bcf6bd38aee9e09009af2ff` |
| CI | [run #54](https://github.com/thewonderfulkey/JZ-private-music-/actions/runs/43855913748)（logic-tests ✅ / build ✅ / 插件门禁 ✅ / 发飞书群 ✅） |
| 提交 | `075fe1f` |

> 认包只认文件名里的 `075fe1f-r54`：群里的历史包（r47 `650a8e1` 及更早）都还没有这 7 项改动。

## 五、装机时按这个顺序试

1. **发现页**：最上面是搜索框；编辑精选是 4 张长方形卡（一屏能看到 2 张半）；猜你喜欢/热门音乐是「三行一页」的卡，左右滑能翻页，底部小胶囊跟着动。
2. **搜索**：点顶部搜索框 → 自动弹键盘 → 搜「周杰伦」→ 结果里《夜曲》《晴天》各只出现一次（同平台不同 ID 的也合并），不再一屏全是同一首。
3. **点一首歌**：播放页整屏盖住（下面看不到列表）、封面→歌词常驻可见并有当前行高亮；若显示「这首歌还没取到歌词」，点右上「重试」。
4. **收起播放页**：左上角 chevron.down 或按住顶部往下拽。
5. **迷你条**：播放中回到任意 Tab，底部条上有 ❤ / ⏮ / ⏸ / ⏭ 四个键；**Tab 栏仍然完整可点**（能切到下载、资料库）。
6. **收藏**：点 ❤ 变实心，进「资料库 › 收藏」能看到这首。


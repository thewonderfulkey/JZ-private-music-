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

### 另外两处顺手改掉的真机问题（都跟 ③ ⑤ 同一片改动区）

| 问题 | 为什么 | 改法 |
|---|---|---|
| 播放页点「下载…」像没反应 | 音质选择 sheet 只挂在 `RootTabView`（根视图）上，而播放页是盖在它上面的模态：根视图弹不出 sheet | 播放页自己再挂一个同一个 `downloadFlow.isPresented` 的 sheet；根视图那个加 `!showPlayer` 闸门，保证同一时刻只有一个活的 |
| 每次打开播放页，歌词可能闪一下空态 | 打开就无条件 `reloadLyrics()`，而它会先清空 `lyrics` 再去取 | 只在 `lyrics.isEmpty && !isLoadingLyrics` 时重取（已取到的歌直接复用） |

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

## 四、本轮出的包（**装这个**）

| 项 | 值 |
|---|---|
| 文件 | `JZ-Music-v2.1.95-e9499bf-r55-ios-unsigned.ipa` |
| 大小 | 1.50 MB |
| SHA-256 | `0e00bae1f2d9d022f959cb37cde8c4ad09ca1a8b83904430184ca5a3877511ca` |
| CI | [run #55](https://github.com/thewonderfulkey/JZ-private-music-/actions/runs/43856937060)（logic-tests ✅ 363 条 / build ✅ / 插件门禁 ✅ / 发飞书群 ✅） |
| 提交 | `e9499bf` |

> 认包只认文件名里的 `e9499bf-r55`：群里的历史包（r54 `075fe1f`、r47 `650a8e1` 及更早）都没有这 7 项改动。
> 其中 **r54 是同一批改动的中间包**（少了"播放页下载 sheet"和"歌词只在空时重取"两处），**已被 r55 取代码**，不用装。

## 五、装机时按这个顺序试

1. **发现页**：最上面是搜索框；编辑精选是 4 张长方形卡（一屏能看到 2 张半）；猜你喜欢/热门音乐是「三行一页」的卡，左右滑能翻页，底部小胶囊跟着动。
2. **搜索**：点顶部搜索框 → 自动弹键盘 → 搜「周杰伦」→ 结果里《夜曲》《晴天》各只出现一次（同平台不同 ID 的也合并），不再一屏全是同一首。
3. **点一首歌**：播放页整屏盖住（下面看不到列表）、封面→歌词常驻可见并有当前行高亮；若显示「这首歌还没取到歌词」，点右上「重试」。
4. **收起播放页**：左上角 chevron.down 或按住顶部往下拽。
5. **迷你条**：播放中回到任意 Tab，底部条上有 ❤ / ⏮ / ⏸ / ⏭ 四个键；**Tab 栏仍然完整可点**（能切到下载、资料库）。
6. **收藏**：点 ❤ 变实心，进「资料库 › 收藏」能看到这首。

---

# 第二轮整改（2026-11-16 晚，老板 6 项）

## 一、逐条结果

| # | 老板原话 | 根因 / 定位 | 改法 |
|---|---|---|---|
| ① | 退出后台后灵动岛还挂着，希望组件进程全杀掉 | 上一版只在"引擎判定没有歌"时 `end()`；进程被系统/用户收掉时**没人去收活动**，内存在的时候没来得及收、内存没了更没人收 | ① 退到后台且没在放歌 → 立刻 `end()`；② `applicationWillTerminate` 里把系统里**所有** `Activity<SongActivityAttributes>` 结束掉 + 清 `MPNowPlayingInfoCenter` + 释放音频会话（`MainActor.assumeIsolated` 同步执行，不排队）；③ **下次启动第一件事**扫一遍全部结束（上滑强杀不给回调，只能这样兜）；④ 设置里新增「实时活动」开关，关掉就根本不创建 |
| ② | 播放页太丑，参考群里邓紫棋那张 | 上一版是白底 + 封面 + 一行行控件，没有背景层次 | 改成沉浸式：**封面铺满做高斯模糊 + 压暗背景**、大圆角封面压在上面、白色题名、半透明歌词卡、细进度条、白色圆形播放键；所有键走统一的按压反馈 |
| ③ | 点击反馈不明显，参考 Light Player | 全 App 用的是 `.buttonStyle(.plain)`——它连系统自带的按下高亮也一起去掉了，点下去屏幕没有任何变化 | 新增 `PressFeedbackButtonStyle`（按下缩到 0.97 + 压暗 0.82 + spring 回弹），把 8 个界面文件里 26 处 `.plain` 全换掉；再补触觉：行/卡片 `Haptics.tap()`、切 Tab `selection`、播放键/切歌沿用原有触觉 |
| ④ | 歌词和唱的时间对不上（有时晚、有时早） | 两个叠加：**(a)** 切行用的是 0.5 秒才更新一次的 `currentTime`（最坏晚 500ms）；**(b)** 行高亮取的是 KRC/QRC 的**行开始**，而很多行第一个字比行开始晚 0.3–1s（所以"还没唱就切了"） | (a) 新增 25Hz 歌词 ticker，用 `preciseTime` 判定；(b) 行高亮改用 `highlightStartMs`（有逐字时间就取第一个字的起点）；再给一个**用户偏移**（±600ms，设置里 Stepper + 播放页「慢一点 / 快一点」现场调），逐字染色与切行同源 |
| ⑤ | 资料库那页设计不好，换成「我的收藏」，放到发现和识曲中间 | 资料库把收藏/最近播放塞成一个分段控件，像"设置入口 + 两张列表" | 整页换成 **我的收藏**：大卡「我喜欢的音乐 · N 首」+ 播放全部/随机 + 干净的收藏列表（行内可取消收藏）+ 右上齿轮；Tab 顺序变成 **发现 / 我的收藏 / 识曲 / 下载** |
| ⑥ | 下载：①选完音质直接下 ②现在会失败 ③找到无损却按 320k 下 | **②** `didFinishDownloadingTo` 里把临时文件 `moveItem` 放进了 `DispatchQueue.main.async`，而那个临时文件在回调返回后就会被系统删 → 移动失败 → 记一条"下载失败"。**③** 档位只信接口自报，没拿落盘后的文件复验。**①** 设计上强制"核对 → 确认"两步 | **①** 实测命中目标档 → 直接开下（1.8 秒"已开始下载"确认后自动收起）；只有降级才需要点头。**②** 临时文件在 delegate 回调里**同步**搬走，再回主线程更新；`taskMap` 加锁；错误翻译成人话（超时/断网/服务器拒绝）。**③** 落盘后读文件头 16 字节 + 真实体积重算容器与码率：档位以实测为准、后缀改成真实容器（`.flac` 里装 mp3 会当场改回 `.mp3`），不一致时在下载行写一句"实测 … 没达到 …" |

## 二、新增/改动的文件（第二轮）

```
Models/SettingsStore.swift          + liveActivityEnabled / lyricOffsetMs（±600 夹取）
Models/DownloadItem.swift           + actualNote（落盘实测与标注不一致时的一句话）
Services/AudioPlayer.swift          + lyricPositionMs / 25Hz 歌词 ticker / seek 后立即重算
Services/LyricsModel.swift          + highlightStartMs（有逐字时间取第一个字的起点）
Services/LyricsCleaning.swift       indexAt 改用 highlightStartMs
Services/LiveActivityController.swift  开关 gate + endAllActivities() + 退出清理
Services/NowPlayingCenter.swift     + teardown()（清锁屏卡片、释放音频会话）
Services/DownloadManager.swift      临时文件同步搬移 / 锁 / 落盘复验 / 错误翻译 / 退出清理
Services/DownloadFlow.swift         命中目标档直接下载（+ .started 阶段）
Services/DownloadGuard.swift        + Verdict（文件头 → 容器/码率/档位/后缀）+ downgradeNote
Services/AppRouter.swift            Tab：discover / favorites / recognize / downloads
Views/RootTabView.swift             新 Tab 顺序 + 切 Tab 触觉 + 退后台收活动
Views/LibraryView.swift             整页重写为 FavoritesView（我的收藏）
Views/NowPlayingView.swift          整页重写（沉浸式 + 按压反馈 + 歌词偏移微调）
Views/Components.swift              + PressFeedbackButtonStyle（.press / .pressSubtle）
Views/Haptics.swift                 + tap() / tabChanged()
Views/DownloadSheet.swift           直接下载文案 + .started 确认页
Views/DownloadsTabView.swift        实测档位说明
Views/SettingsView.swift            + 歌词偏移 / 实时活动开关
ios/SelfTest/main.swift             +16 条断言（切行时间点 8 / 落盘实测档位 8）
```

## 三、验证

| 项 | 手段 | 结论 |
|---|---|---|
| 纯逻辑 | CI logic-tests（swiftc 编译 + 断言） | **379 条全绿**（第二轮 +16：切行时间点 8 / 落盘实测档位 8） |
| 界面卫生 / 工程结构 / 语法 | `check_ui_hygiene.py` / `check_pbxproj.py` / tree-sitter | 18 文件通过 / 175 对象 2 target / 66 文件 0 语法错误 |
| 编译 | CI build-ipa | ✅ **BUILD SUCCEEDED**，`PlugIns/JZWidgets.appex` 在包里 |
| 真机 | **验不到**（Windows 无 iPhone） | 要你装机确认：退出后台后灵动岛是否消失、播放页观感、点击手感、歌词是否对齐、我的收藏页、下载是否一次点完且档位正确 |

> 中间踩了两个自己的坑（都记下来免得下轮再犯）：① 切行时间点写成 `min(行时间, 第一个字)`，
> 等于把高亮提前，正好是老板说的"还没唱就切"——改成 `max`；② `DownloadItem.quality` 是 `let`，
> 落盘复验要改写它，编译报 "cannot assign to property"。这两处各费了一轮 CI。

## 四、本轮出的包（**装这个**）

| 项 | 值 |
|---|---|
| 文件 | `JZ-Music-v2.1.95-e01f607-r58-ios-unsigned.ipa` |
| 大小 | 1.53 MB |
| SHA-256 | `3771c2b13edaec267cc239c4d7a40f287aaf01d9ea52a3e0ccdc9e73ee7aa37a` |
| CI | [run #58](https://github.com/thewonderfulkey/JZ-private-music-/actions/runs/43869801424)（逻辑 379 条 ✅ / 编译 ✅ / 插件门禁 ✅ / 发飞书群 ✅） |
| 提交 | `e01f607` |

> 群里同一晚还有 `…fe338c4-r56…`、`…ac40b5c-r57…` 两个**失败**的构建通知（编译/断言没过，没出包），
> 以及 `…e9499bf-r55…`（第一轮 7 项的包）。**这一轮请装 r58**；r55 是上一批改动，不含本轮 6 项。

---

# 第三轮整改（2026-11-16 深夜，老板 4 项）

## 一、逐条结果

| # | 老板原话 | 根因 / 定位 | 改法 |
|---|---|---|---|
| ① | 正在播放时点其他 Tab，歌被强行暂停 | 识曲页 `onDisappear → cancelListen() → capture.cancel() → AudioCapture.stop()`，而 `stop()` **无条件**调用 `restorePlaybackSession()`：先 `setActive(false, .notifyOthersOnDeactivation)` 再重开音频会话。那一下会把正在播放的会话掐断，重开后 `AVPlayer` 不会自己恢复 → 表现就是"切 Tab 歌停了" | `AudioCapture.stop()` 只在**真的在录**（`wasRunning`）时才收尾；`restorePlaybackSession()` 不再 `setActive(false)`（只把类别切回 playback 并保持激活）；`RecognizeView.cancelListen()` 只在 `capture.isRunning` 时才动采集。三条一起堵死这条路径 |
| ② | 播放详情页保持双击封面显示歌词，跟 Light Player 一样 | 上一版把歌词做成了常驻卡片，没有"双击切换"这个交互 | 改成 APK/Light Player 同款：**双击封面 → 大歌词**，**双击歌词 → 回封面**（点某一句仍然跳转到那句）。封面下留一行小字「双击封面看歌词」做提示 |
| ③ | 歌词滚动时间还是不对，参考 APK 的歌词滚动逻辑 | APK 的 `LyricsService.indexAt` 就一句：`lines[i].timeMs <= positionMs` 就切（**行开始时间**）。上一版我改成"第一个字真正唱出来的时刻"（`max(行时间, 首字起点)`），整体偏晚，正好和 APK 相反 | **逐字照抄 APK**：`indexAt` 用 `line.timeMs`；逐字时间只参与行内染色，不参与切行。25Hz ticker（`lyricPositionMs` = 精确位置 + 用户偏移）保留——APK 那边也有一条高频位置更新，这样才不吃 0.5 秒观察者的延迟。上一版的 `highlightStartMs` 删除 |
| ④ | 播放页把「顺序播放」和「下载」弄没了；另外要能下拽关闭 | 上一版这两个按钮只留了图标（模式图标在左、下载图标在右），没有文字，窄屏上还容易被挤掉；关闭只能点左上角 | 控制行改回 APK 的「图标 + 文字」：**播放模式（显示"列表循环/单曲循环/随机播放"）/ 上一首 / 播放 / 下一首 / 下载**，两侧列各 56pt、中间键收窄（320pt 窄屏也放得下）；**整页向下拽 ≥110pt（或快速甩）即关闭**，带跟手位移与淡出 |

## 二、改动的文件（第三轮）

```
Services/AudioCapture.swift        stop() 只在录音时恢复会话；restorePlaybackSession 不再 setActive(false)
Views/RecognizeView.swift          cancelListen() 只在 capture.isRunning 时动采集
Services/LyricsCleaning.swift      indexAt 回到 APK 口径（line.timeMs）
Services/LyricsModel.swift         删掉上一版加的 highlightStartMs
Views/NowPlayingView.swift         双击封面/歌词切换、图标+文字控制行、整页下拽关闭
ios/SelfTest/main.swift            歌词切行断言按 APK 口径重写（8 条）
```

## 三、验证

| 项 | 手段 | 结论 |
|---|---|---|
| 纯逻辑 | CI logic-tests | **379 条全绿**（歌词切行 8 条已按 APK 口径重写） |
| 界面卫生 / 工程结构 / 语法 | 三道本地门禁 | 18 文件 / 175 对象 2 target / 66 文件 0 语法错误 |
| 编译 | CI build-ipa | ✅ BUILD SUCCEEDED，插件在包里 |
| 真机 | **验不到**（Windows 无 iPhone） | 要你确认：切 Tab 歌还停不停、双击封面出歌词、歌词是否跟得上（可现场 ±200ms 微调）、顺/下载两个键在不在、下拽能不能关 |

> 这一轮的 CI 很不顺：同一个 run（#60）前两次在 macOS runner 上跑到 15 分钟被系统 **cancelled**（不是我取消的，日志都没留下），
> 第三次重跑才成功；中间还因为我把一条断言的期望值写反（`indexAt(5200-200)` 本来就该命中第二句）失败过一次。
> 结论：**r60 这个包是三次重跑后才出来的**，代码就是 `6b65361`。

## 四、本轮出的包（**装这个**）

| 项 | 值 |
|---|---|
| 文件 | `JZ-Music-v2.1.95-6b65361-r60-ios-unsigned.ipa` |
| 大小 | 1.54 MB |
| SHA-256 | `f443eb9ac91e6fd2dcb575b29bc97ef40f70d05df1dbaa731a3e597305fd8b64` |
| CI | [run #60（第 3 次尝试）](https://github.com/thewonderfulkey/JZ-private-music-/actions/runs/43877544553)（379 条断言 ✅ / 编译 ✅ / 插件门禁 ✅ / 发飞书群 ✅） |
| 提交 | `6b65361` |

> 认包只认 `6b65361-r60`。群里更早的 `r58`（e01f607，第二轮 6 项）与 `r55`（第一轮 7 项）都不要装了。

---

# 第四轮整改（2026-11-17 凌晨，老板 3 项 + 60 秒真机录屏）

> 来源：老板在开发群发的 **60 秒真机录屏**（`100814347.mov`，1080×2341）+ 一张参考版式截图
> （群里那张「大封面 / 居中歌名歌手 / 音质小胶囊 / 一行播放键」的播放页，应该是 Light Player 那一路）。
> 录屏是逐帧看完的（30 帧均匀抽帧 + 关键帧放大 1.6~3 倍），下面每条都是**按画面像素量出来的**，
> 不是照文字猜的。

## 一、最严重的一条：播放页排版（整页横向溢出）

| 项 | 内容 |
|---|---|
| 屏幕上的实际样子 | 顶栏只剩居中的「正在播放」，左右两角的收起 `⌄`、更多 `⋯` **不见**；封面下面「歌名 / 歌手 / 收藏」**整块不见**；进度条**没有任何左右留白**、一直通到屏幕两边；进度条两端的时间**不见**；播放控制只剩中间三个键，**播放模式（列表循环）与下载不见**；底部状态行**不见**。老板说的"说明里要加的功能按钮全都没有"，其实是**它们在屏幕外面**，不是没做出来 |
| 怎么定位的 | 逐帧量像素：进度条胶囊的亮线在 x=0..539（整帧 540 宽）都亮，而代码里明明给了 24pt 左右内边距 → **父级给播放页的宽度比屏幕还宽**（按左/右两端元素被推出屏幕的距离反推，至少 450pt，可能上千）。旧版式全靠 `Spacer` 把元素顶到两头，一宽就整排顶出去，只有**居中**的东西留在屏幕上——和录屏里"只剩封面和三个键"完全对得上 |
| 改法（两层） | ① 新增纯函数 `LayoutRules.playerWidth(available:screen:)`：可用宽度有效且不超屏 → 原样；比屏幕宽 / 0 / NaN → **钉回屏幕宽**；iPad 再限 700。② 播放页**每一行都显式 `.frame(width: w)`**，全页零个"靠 Spacer 顶到两头"的写法，外层给多宽都穿不出去 |
| 版式（照群内截屏） | 顶栏（收起 / 正在播放 / 更多）→ 居中大封面（双击进歌词）→ 居中歌名 + 歌手 → **音质小胶囊**（`FLAC` `1533 kbps` `酷我` `已下载`）→ **一行四个功能键：收藏 / 下载 / 歌词 / 音源（图标 + 文字）** → 进度条 + 两端时间 → **一行五个播放键：播放模式（带文字"列表循环"）/ 上一首 / 播放 / 下一首 / 播放列表** → 底部状态行给宽度留边、单行省略 |
| 顺带补的 | 「播放列表」以前根本没有入口：新增队列面板（点一首直接跳过去，当前曲朱砂高亮 + 正在播的喇叭图标） |

## 二、歌词（第 3 条：还是没对上 / 点歌词跳的位置不对）

拆成三件事，都改了：

| # | 问题 | 改法 |
|---|---|---|
| ① | **点某一句跳的位置不对** | 旧代码 `seek(toFraction: (line.timeMs/1000)/duration)` → 引擎里再 `duration * fraction`，一道乘一道除，而且**用户偏移没算进去**：偏移 +200ms 时点第 N 句会跳到第 N 句的"下一句"位置。现在给引擎加了 `seek(toSeconds:)`（所有跳转的唯一入口）和 `seek(toLyricLine:)`，目标 = **行时间 − 用户偏移**（`LyricsCleaning.seekTargetMs`），跳完 `indexAt(位置+偏移)` 正好等于被点那一句 |
| ② | **暂停时点歌词"跳了但高亮不动"** | 25Hz 的歌词 ticker 只在播放时跑，而 `AVPlayer.currentTime()` 在 seek 之后还要一会儿才更新 → 旧代码用的是旧位置。现在 `seek` 里直接用**目标位置**把当前行算出来并落上 |
| ③ | **整首歌整体偏**（同一歌名不同版本，前奏差好几秒） | ① 上了 LRC 的 `[offset:±N]` 标签：正数 = 歌词提前，解析时按 `行时间 − offset` 落，以前完全没解析，带 offset 的源会整体偏 0.2~1 秒；② 用户偏移范围从 **±600ms 放宽到 ±2000ms**（步进 100），设置页加了「把偏移归零」，播放页歌词区三个胶囊 **慢一点 / 归零 / 快一点** 横向排死（上一版这三个键被 `Spacer` 顶出屏幕，老板根本调不到），偏移值实时显示（`+0.4s` / `−1.2s` / `对齐`） |

> 为什么不是再调一次切行阈值：第二轮试过 `max(行时间, 首字起点)`（偏晚），第三轮回退到 APK 的
> `line.timeMs`（老板说还是不对）——**两个方向都试过就说明不是阈值问题，是"歌词文件 ≠ 这份音频"**
> 或"偏移没生效"。所以这轮不再动阈值，而是把**偏移**做成真的能调、点歌词真的能跳对。

## 三、设置（第 3 条：改成单独的 Tab）

| 项 | 改前 | 改后 |
|---|---|---|
| 入口 | 只有「我的收藏」右上角一个齿轮 push 进去 | **独立 Tab**：底部 5 格 = 发现 / 我的收藏 / 识曲 / 下载 / 设置（`gearshape.fill`），收藏页右上角齿轮撤掉，只留这一个入口；设置页改大标题，与其它 Tab 一致 |
| 歌词偏移 | Stepper ±600 / 步进 100 | ±2000 / 步进 100 + 「把偏移归零」按钮 + 人话说明 |

## 四、版本号

| 项 | 改前 | 改后 |
|---|---|---|
| iOS 显示版本（`MARKETING_VERSION`） | `1.0`（设置 › 关于 里一直显示 1.0，是个老 bug） | **2.1.96** |
| 构建号（`CURRENT_PROJECT_VERSION`） | `1` | **154** |
| Android / 出包文件名版本 | `versionName 2.1.95` / `versionCode 153` | **2.1.96 / 154**（CI 的包名从 gradle 读，所以文件名会变成 `JZ-Music-v2.1.96-<sha>-r<run>-ios-unsigned.ipa`） |

## 五、改动的文件（第四轮）

```
Services/LayoutRules.swift            + playerWidth(available:screen:)（播放页宽度钉死的唯一口径）
Views/NowPlayingView.swift            整页重写：钉宽度 + 群内截屏版式 + 四个功能键 + 播放列表 + 歌词微调
Views/RootTabView.swift               5 Tab（+ 设置）
Services/AppRouter.swift              Tab 枚举 + settings
Views/LibraryView.swift               撤掉收藏页右上角齿轮
Views/SettingsView.swift              大标题 / 偏移 ±2000 / 归零
Models/SettingsStore.swift            clampOffset 放宽到 ±2000
Services/AudioPlayer.swift            + seek(toSeconds:) / seek(toLyricLine:) / jump(to:)
Services/LyricsCleaning.swift         + lrcOffsetMs / seekTargetMs；parseLrc 应用 [offset:]
ios/SelfTest/main.swift               +13 条断言（宽度钉死 4 / LRC offset 5 / 点歌词跳转 4）
android/app/build.gradle.kts          versionCode 154 / versionName 2.1.96
ios/JZMusicHelper.xcodeproj           MARKETING_VERSION 2.1.96 / CURRENT_PROJECT_VERSION 154
```

## 六、验证

| 项 | 手段 | 结论 |
|---|---|---|
| 纯逻辑 | CI logic-tests（swiftc + 断言） | **391 条全绿**（本轮 +12：宽度钉死 4 / LRC offset 5 / 点歌词跳转 3） |
| 界面卫生 | `tools/ios/check_ui_hygiene.py` | 18 个界面文件通过 |
| 工程结构 | `tools/ios/check_pbxproj.py` | 175 对象 / 2 target 通过（本轮没加新文件） |
| 语法 | tree-sitter-swift 解析 `ios/**/*.swift` | 66 个文件，0 个新 ERROR 节点（唯一命中的是 SelfTest 里那段带 `\{` 的多行字符串样本，老问题） |
| 编译 / 出包 | CI build-ipa（macOS runner） | 见下 |
| 真机观感 | **验不到**（开发机 Windows，没有 iPhone/模拟器） | 要老板装机确认：播放页上一屏能看到全部控件、点歌词跳对了、歌词微调按钮在、设置是第 5 个 Tab |

## 七、本轮出的包（**装这个**）

| 项 | 值 |
|---|---|
| 文件 | `JZ-Music-v2.1.96-dcf6f85-r61-ios-unsigned.ipa` |
| 大小 | 1,644,226 字节（≈1.57 MB） |
| SHA-256 | `2630ddb6328bae70b0fad292021d044242f755ba0d59f4a851d9cf8be0d5ac04` |
| CI | [run #61](https://github.com/thewonderfulkey/JZ-private-music-/actions/runs/43890494922)（一次过：逻辑断言 ✅ / BUILD SUCCEEDED / 插件在包里 ✅ / 发飞书群 ✅） |
| 提交 | `dcf6f85` |
| 包内自证 | `Info.plist` 里 `CFBundleShortVersionString = 2.1.96` / `CFBundleVersion = 154`；二进制里有新类型 `PlayerQueueSheet`（第四轮新写的播放列表） |

> 认包只认 `dcf6f85-r61`。群里更早的 `r60`（6b65361，第三轮）以及 `r58`/`r55` 都别装了——
> 那些包的播放页还是"左右两头被顶出屏幕"的版式。
> 装机时按下面顺序试：**① 点一首歌 → 播放页上能不能一眼看全「收起 / 更多 / 歌名歌手 / 收藏 / 下载 /
> 歌词 / 音源 / 进度时间 / 列表循环 / 上一首 / 播放 / 下一首 / 播放列表」；② 双击封面进歌词 →
> 点某一句是否跳到那句（高亮落在被点的那句）；③ 歌词整体偏早就按「慢一点」、偏晚按「快一点」，
> 最多 ±2 秒；④ 底部第 5 个 Tab 是「设置」。**









# 第五轮整改（2026-11-17 凌晨，老板 9 条 + 群内两张真机截屏）

> 来源：老板在开发群发的两张真机截屏（01:51 播放页 / 01:53 歌词页）+ 9 条文字反馈，
> 以及一张 APK 参考截图（《慢慢》那一版播放页的版式）。每条的"改前 → 改后"写在下表。

## 一、逐条结果

| # | 老板原话（摘要） | 问题定位（改前） | 改法（改后） |
|---|---|---|---|
| ① | 封面和播放栏中间一大段空隙；文字下的标签也没居中 | 标题与功能键之间用的是**无上限 `Spacer()`**：屏幕上所有富余高度都被它吞在中间（截屏里音质标签到功能键约 139pt）。音质标签放在横向 `ScrollView` 里，内容天然靠左 | 新增 `LayoutRules.playerGap(availableHeight:)`：按屏高给 **50~64pt 的有上限留白**，多出来的高度落到状态行下面（与 APK 参考图一致）。标签行给内容 `minWidth = 行宽`，装得下就被居中，装不下仍可横向滑 |
| ② | 播放列表只有一首歌，列表循环也来回只放这一首 | 从「编辑精选歌单」和「下载」点歌时走的是 `playSingle`，队列里只有 1 首；列表循环在 1 首队列上等于单曲循环 | 点歌即把**整列**当队列：下载页 = 全部已完成下载；精选歌单 = 点中那首先播（1~3 秒出声），其余按列表顺序后台解析追加。搜索 / 收藏 / 榜单本来就走整列队列 |
| ③ | 歌词总是不准，七里香的词总返回 live 版 | LDDC 评分只拿「搜索结果里的时长」做过滤，候选 `七里香 (Live)` 仍能拿 73 分过线；而**歌词文件自己写的时长**（KRC `[total:]` / LRC `[length:]`）完全没用上 | 新增 `LyricsMeta` 解析文件头（ti/ar/al/total/length/duration/offset）；取词后做**文件头验收**：时长差 >8s、标题分 <50、歌手分 <30 就丢掉换下一个候选（元数据缺失则放行，否则真实酷狗 KRC 会被整批误杀）；新增版本标签惩罚：候选带「查询没有的」live/现场/演唱会/翻唱/cover/remix/伴奏/纯音乐… 扣 35 分；排序改成「分数 → 时长差 → 源」，候选从 2 个放宽到 3 个 |
| ④ | 双击封面是小框歌词，要全屏歌词 | 歌词是播放页里的一块圆角卡片（左右留边、下方还有功能键行与状态行），看起来就是个"小框" | 歌词改成**整页层**：去掉卡片底 / 描边 / 左右边距，从顶栏下方一路铺到进度条，功能键行与状态行收起；顶栏加「封面」返回键，⋯ 菜单里也加「回到封面」 |
| ⑤ | 歌词快进后退时还没切就立刻弹回原位置 | `onChange(lyricIndex)` 无条件 `scrollTo`，用户一停手就被拽回当前行 | 新增 `LyricsUXRules.dwellSeconds = 4`：滑过歌词后 **4 秒没有新操作**才回当前行；期间底部有「回到当前」可以立刻回去 |
| ⑥ | 歌词判定太敏感，没点到也算点了，范围太宽 | 每行 `.contentShape(Rectangle())` + 满宽 `frame(maxWidth:)`，手指从空白扫过也算点击 | 命中区只认**文字本身**（两侧用 Spacer 撑开）；滑动刚结束 0.35 秒内的触摸只当"刹车"（`isTapCoolingDown`）；`isTap` 要求位移 ≤8pt 且时长 ≤0.5s |
| ⑦ | 歌词界面上下滑把播放页退出去了 | 整页下拽收起手势用 `simultaneousGesture` 无条件挂着，和歌词滚动抢手势 | 歌词模式下**不挂**下拽手势（`page` 里按 `showLyrics` 二分），收起播放页只走左上角 chevron |
| ⑧ | 下载要把歌词和封面一起下、内嵌为一体；删除也一一对应删掉 | 只下音频；歌词和封面全靠网络，离线点开下载好的歌只有播放器 | 下载完成后异步补料：**旁车** `.lrc` + `.jpg`（所有容器都能用）+ **内嵌**（m4a 走 AVFoundation metadata、mp3 走 ID3v2.4：标题/歌手/专辑/封面/歌词）；删除下载时先删旁车再删音频；播放本地文件优先读旁车歌词与封面；下载列表多一行「已内嵌歌词+封面 / 歌词封面已存旁车」 |
| ⑨ | 悬浮栏挡住各 Tab 最后一条，也挡搜索结果 | 迷你条用 `safeAreaInset` 挂在 NavigationStack 上，内层 `ScrollView`/`List` 的滚动内容不随之让位 | 改成 **overlay 浮层 + 每个可滚动页面末尾 `MiniPlayerSpacer()` 真实占位**（发现/收藏/识曲/下载/设置/搜索结果/最近搜索/歌单页/榜单页），滚到底一定停得出来 |

## 二、改动的文件（第五轮）

```
Services/LayoutRules.swift            + playerGap(availableHeight:) / LyricsUXRules（停留 4s / 点击阈值 / 刹车冷却）
Services/LyricsCleaning.swift         + LyricsMeta（文件头元数据）+ meta(_:)
Services/LddcMatch.swift              + versionTags / versionPenalty（版本标签惩罚，主评分公式未改）
Services/LddcLyrics.swift             取词带回文件头 → headerRejection 验收；排序 weighted；候选 2 → 3
Services/DownloadCompanion.swift      新增：旁车路径/读写删、LRC 文本、ID3v2.4 标签（纯 Foundation）
Services/AudioTagEmbedder.swift       新增：m4a metadata 导出 + mp3 前置 ID3，先临时文件再原子替换
Services/DownloadManager.swift        下载完成补料（取词/取封面/旁车/内嵌/回填）+ localLyrics/localCoverURL + 删除先删旁车 + completedSongs
Services/AudioPlayer.swift            本地歌词优先（离线有词）；其余播放逻辑未动
Models/DownloadItem.swift             + companionsNote（可选，旧 downloads.json 兼容）
Views/NowPlayingView.swift            播放页：有上限留白 / 标签居中 / 整页歌词 / 歌词停留与点击判定 / 歌词页禁用下拽收起 / 本地封面
Views/MiniPlayerBar.swift             safeAreaInset → overlay 浮层 + MiniPlayerSpacer
Views/Components.swift                SongArtwork 优先用下载时存的本地封面
Views/RootTabView.swift / DiscoverView / LibraryView / SearchTabView / DownloadsTabView / EditorPlaylistView / HotChartView / RecognizeView / SettingsView
                                      迷你条挂载改名 + 每个列表末尾占位；下载页整列队列；歌单页后台补队列
ios/SelfTest/main.swift               +70 条断言（留白 4 / 歌词手感 9 / 文件头 10 / 版本惩罚 9 / 排序与验收 13 / 下载旁车与 ID3 25）
ios/JZMusicHelper.xcodeproj           新文件挂载 + MARKETING_VERSION 2.1.97 / CURRENT_PROJECT_VERSION 155
.github/workflows/ios-ipa.yml         logic-tests 清单加 DownloadCompanion.swift（AudioTagEmbedder 只进 App）
android/app/build.gradle.kts          versionCode 155 / versionName 2.1.97
```

## 三、验证

| 项 | 手段 | 结论 |
|---|---|---|
| 纯逻辑 | CI logic-tests（swiftc + 断言） | **461 条全绿**（r61 的 391 + 本轮 70：留白 4 / 歌词手感 9 / 文件头 10 / 版本惩罚 9 / 排序与验收 13 / 下载旁车与 ID3 25） |
| 界面卫生 | `python tools/ios/check_ui_hygiene.py` | 18 个界面文件通过 |
| 工程结构 | `python tools/ios/check_pbxproj.py` | 179 个对象 / 2 个 target 通过 |
| 语法 | tree-sitter-swift 解析 `ios/**/*.swift` | 68 个文件，0 个新 ERROR（唯一命中的仍是 SelfTest 里那段 `\{` 多行字符串样本，老问题） |
| 类型 | 开发机（Windows）本来没有 Swift；本轮额外在 **WSL + Swift 6.0.3** 里用桩模块（CryptoKit / Compression）把 CI 的完整 swiftc 清单 typecheck 了一遍 | **TYPECHECK_EXIT=0**（含 SelfTest 与 DownloadCompanion） |
| 断言实跑 | 同上，另起一个只含纯逻辑文件的小 runner（不需要网络/解密） | **64/64 通过**：留白、歌词手感、文件头、版本惩罚、排序、文件头验收、旁车读写删、ID3 字节布局 |
| 真机观感 | **验不到**（开发机 Windows，没有 iPhone/模拟器） | 需要老板装机确认：见下 |

## 四、本轮出的包（**装这个**）

| 项 | 值 |
|---|---|
| 文件 | `JZ-Music-v2.1.97-4e9b09d-r62-ios-unsigned.ipa` |
| 大小 | 1,725,119 字节（≈1.65 MB） |
| SHA-256 | `d1680bd1a4dd92e9d0c71d02fa43fd80499a1849f65139ee63047b5ecbbc2530` |
| CI | [run #62](https://github.com/thewonderfulkey/JZ-private-music-/actions/runs/43904747643)（一次过：逻辑断言 ✅ / BUILD SUCCEEDED / 插件在包里 ✅ / 发飞书群 ✅） |
| 提交 | `4e9b09d` |
| 包内自证 | `Info.plist` 里 `CFBundleShortVersionString = 2.1.97` / `CFBundleVersion = 155`；二进制里有新类型 `DownloadCompanion` / `AudioTagEmbedder`（下载词图内嵌）与 `PlayerQueueSheet` |

> 认包只认 `4e9b09d-r62`。r61（dcf6f85）是上一轮的包，里面还是"封面到播放栏一大段空白 + 小框歌词 + 只下一首的队列"。

## 五、装机按这个顺序试

1. **播放页版式（①）**：封面到功能键之间不再有一大截空白；歌名下面的音质标签是**居中**的。
2. **歌词页（④⑤⑥⑦）**：双击封面 → 整页歌词（没有圆角小框）；上下滑歌词，**停手约 4 秒**才回到正在唱的那句，期间点「回到当前」立刻回；滑动时手指扫过空白不会跳歌；在歌词页上下滑**不会**把播放页收起来；右上角「封面」能回封面。
3. **歌词对不对版（③）**：搜「七里香 周杰伦」播原版，看词是不是录音室版（副歌顺序对、逐行能跟上）。仍差一点就用「慢一点 / 快一点」（每下 200ms，最多 ±2s）。
4. **播放列表（②）**：从「下载」页点一首 → 打开播放列表，应该是**整列**；列表循环能自动下一首。精选歌单点单曲同理（其余曲目会边放边补进队列）。
5. **离线词图（⑧）**：下载一首（等几十秒让补料跑完），下载列表那行会多一句「已内嵌歌词+封面」/「歌词封面已存旁车」；开飞行模式，点已下载的歌 → 封面和歌词都还在。
6. **悬浮栏（⑨）**：每个 Tab 滚到最底、搜索结果滚到最底，最后一条都能完整露出来，不被播放条压住。


---

# 第六轮整改（2026-11-17 凌晨 03:xx，老板 7 条 + 群内三张截屏 + 一段 8 秒录屏）

> 来源：老板在开发群发的 r62 真机截屏（02:53 播放列表 1 首 / 02:45 播放页 / 02:46 歌词空态）
> 与一段 8 秒录屏（02:47，点同一首歌 → 转圈"正在解析音源…"），外加 7 条文字反馈。
> 本轮开工前按老板要求先把 5 个口径问清楚（布局铺法 / 小字去留 / 队列范围 /
> 同一首再点 / 歌词兜底），全部按"推荐项"执行。

## 一、逐条结果

| # | 老板原话（摘要） | 问题定位（改前） | 改法（改后） |
|---|---|---|---|
| ① | 播放页调板正了，但进度条下方还有一大段空白；要所有元素从上到下均匀分布、自适应 | 上一版把"标题与功能键之间"的留白压成 50~64pt 之后，整列仍是**顶端对齐**：富余高度不会自己消失，全部堆在播放键下面（截屏底部 ~200pt 空白） | 改 **「封面撑满型」整列铺满**：`VStack` 高度钉成屏高，段与段之间用等权 `Spacer(minLength:)`（下限 12~24pt，富余均分）；封面边长由 `LayoutRules.playerCoverSide(width:height:)` 吃掉富余高度（除封面外固定块估 380pt，剩下的 72% 给封面，夹 140~380、不超屏宽−56）。封面 → 标题 → 功能键 → 进度 → 播放键 → 底部，一路铺到底 |
| ② | 暂停键下方的小字不用显示了，已经在「音源」里 | `statusRow` 常驻一行：正常态写「音源 cyapi QQ · M4A · 97 kbps」并 `minHeight: 16` 预留高度 | 常驻行删掉；只在 `player.errorText` 有值时出现一行橙色 `errorLine`（无源/换源失败/播放失败），正常状态**一点高度都不占**。音质细节仍在「音源」面板 |
| ③ | 歌词压根取不到了；双击封面要全屏歌词（不要框）；再次双击非歌词区域回封面 | 两层硬门槛把候选**全丢掉**：`abs(目标−候选) > 4s` 直接丢（实测 蓝莲花/后来/倔强/我不配 一个候选都不剩），版本标签惩罚把唯一的 live 候选也压到及格线下，文件头验收再把剩下的一票否决 | 三道闸全部改软：**时长只排序不过滤**；版本惩罚只影响排序；文件头验收改成"优先选通过的那份，一份都没通过就退回排名最高的那份"；新增 **酷我兜底**（非酷我的歌按「歌名 歌手」在酷我搜同一首，取官方行级词）；取到的词按音源实际时长 **线性对齐时间轴**（`alignedToAudio`，比例 0.75~1.35 才拉，差 <2% 不动）。歌词页去掉空态的圆角卡片；顶部歌名行 / 曲目信息行双击即回封面；空态多一行**失败原因**（下一轮能直接定位是哪条链断了） |
| ④ | 点最近播放里的歌，播完自动"下一首"还是它自己，播放列表始终只有一首 | `DiscoverView` 最近播放的卡片 `play([song], at: 0)` ——只把这一首塞进队列 | 改成 `play(library.recentSongs, at: index)`：**整列最近播放（最多 50 首）**当队列，列表循环/随机才真的会往下走 |
| ⑤ | 点正在播的这首会重新请求、重头播 | `play(queue:startAt:)` 无条件重置队列/进度/歌词并重新走三级取流 → 转圈"正在解析音源…"后从头放 | 新增 `PlaybackRules.shouldReuseCurrentSong(...)`：同一首歌 + 已装上播放项 + 无错误 → **只把播放列表换成这次点的整列**（`adoptQueue`），音频、进度、歌词全部保留，直接弹播放页；上次解析失败的歌仍允许重试 |
| ⑥ | 搜索页点历史记录后键盘不收回 | 历史胶囊的按钮只 `keyword = word; runSearch()`，`fieldFocused` 一直是 true | 点历史先 `fieldFocused = false` 再搜索（结果不再被键盘顶掉半屏） |
| ⑦ | 悬浮条和底层栏最后一条之间空隙又太大了，要严丝合缝 | 占位 `56 + 16 = 72`，页面自己再 `.padding(.bottom, 32)`，而条子本体只占 64 → 空出 40pt；`List`/`Form` 页面用占位行时 `insetGrouped` 的 section 间距还会再插一段 | 新增 `MiniPlayerMetrics`：占位**正好等于**条子高度（56 + 上下各 4 = 64），没播歌时 24（页面底部呼吸）；各页去掉额外的 32pt 底 padding；下载页/设置页改用 `.safeAreaInset(edge: .bottom) { MiniPlayerClearance() }`（真实内容 inset，滚到底最后一条紧贴条子上沿） |

## 二、改动的文件（第六轮）

```
Services/LayoutRules.swift        playerGap 改成"间距下限 12~24"；+ playerCoverSide / chromeHeight；+ MiniPlayerMetrics
Services/LyricsCleaning.swift     + alignedToAudio（时间轴按音源时长对齐）
Services/LddcLyrics.swift         去掉 ±4s 硬过滤；版本惩罚只排序；文件头验收改软（chooseOutcome）；
                                  + scoredCandidate（纯函数）+ FetchedOutcome；取词后对齐时间轴
Services/LyricsService.swift      + 非酷我的歌走"酷我搜索 + 官方歌词"兜底；+ failureReason；统一对齐出口
Services/PlaybackRules.swift      + shouldReuseCurrentSong（同一首再点不重播）
Services/AudioPlayer.swift        play() 同曲复用（adoptQueue）；+ lyricsFailure（失败原因给人看）
Views/NowPlayingView.swift        整列铺满版式 / 封面边长按屏算 / 状态行 → 仅错误行 / 歌词空态去框 + 失败原因 / 双击回封面
Views/MiniPlayerBar.swift         占位 = 条子高度；+ MiniPlayerClearance（List/Form 用真实 inset）
Views/DiscoverView.swift          最近播放整列当队列
Views/SearchTabView.swift         点历史记录收键盘
Views/DownloadsTabView.swift      下载列表改 safeAreaInset 让位
Views/SettingsView.swift          设置表单改 safeAreaInset 让位
Views/LibraryView / RecognizeView / EditorPlaylistView / HotChartView
                                  去掉额外的 32pt 底 padding（严丝合缝）
ios/SelfTest/main.swift           +31 条断言（铺满 5 / 悬浮条 3 / 同曲复用 4 / 候选软过滤 4 /
                                  验收优选 4 / 时间轴对齐 7，另更新留白 4 条）
ios/JZMusicHelper.xcodeproj       MARKETING_VERSION 2.1.98 / CURRENT_PROJECT_VERSION 156
android/app/build.gradle.kts      versionCode 156 / versionName 2.1.98
```

## 三、验证

| 项 | 手段 | 结论 |
|---|---|---|
| 纯逻辑 | CI logic-tests（swiftc + 断言） | 见下方出包记录（本轮新增 31 条） |
| 候选软过滤的真因 | 本机 Python 复刻酷狗搜索 + KRC 解密，跑了 8 首歌 | 改前：蓝莲花/后来/倔强/我不配 **±4s 内 0 个候选**（→ 没词）；七里香只有 299s 原版 + 302s live（live 被版本惩罚压掉，原版可以过） |
| 类型 | WSL + Swift 6.0.3 + 桩模块，CI 完整 swiftc 清单 typecheck | `TYPECHECK_EXIT=0` |
| 断言实跑 | 本机小 runner（纯逻辑，不含解密/网络） | **31/31 通过**（铺满、悬浮条、同曲复用、候选软过滤、验收优选、时间轴对齐） |
| 真机观感 | **验不到**（开发机 Windows，没有 iPhone/模拟器） | 需要老板装机确认（见下） |

## 四、装机按这个顺序试

1. **播放页铺满（①②）**：进播放页，从顶栏到播放键之间是否还有"空一大块"的地方；暂停键下面**没有**那行小字了；故意断网放一首 → 出错时才出现一行橙色提示。
2. **歌词（③）**：搜《我不配》《蓝莲花》《后来》各播一首，打开歌词——应当**有词**（哪怕版本略不同，也不会整首空着）；顶部小字会写来源（`LDDC` / `酷我兜底` / `…·已对齐 ×1.34`）。双击封面 → 全屏歌词（没有圆角框）；**双击顶部歌名/曲目信息那一片** → 回封面；点某一句仍然是跳转。
3. **队列（④）**：点「最近播放」里第 2 张卡 → 播放列表里是整列最近播放；等这首放完，自动播下一首（不是又回到它自己）。
4. **同一首再点（⑤）**：正在放这首歌时，回到列表再点它一次 → 直接弹播放页，**不转圈、不重头播**（进度条位置不变）。
5. **搜索键盘（⑥）**：搜索页点一条历史记录 → 键盘自己收回去，结果完整露出来。
6. **悬浮条（⑦）**：各 Tab / 搜索结果滚到最底 → 最后一条紧贴播放条上沿，中间没有多余空隙。

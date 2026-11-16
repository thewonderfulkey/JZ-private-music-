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







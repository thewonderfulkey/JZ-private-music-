# note_v2.1.95-windows —— Windows 桌面版 JZ Music（PC 版式）

日期：2026-11-14
产物：

- **单文件** `JZ Music-2.1.95-portable.exe`（138.6MB，双击即用，不用安装；首跑解包约 4s，之后约 2s 启动）

## 做了什么

把 APK 的能力整套搬到 Windows，并在**第一版反馈"界面和 APK 完全不一样、像是另写了一个 App"之后，
按 PC 音乐客户端（网易云 / QQ 音乐 / 酷狗 PC）的结构重做了界面**：

- 左侧栏导航（发现音乐 / 搜索结果 / 听歌识曲 / 我喜欢的 / 下载管理 / 最近播放 / 设置 + 桌面歌词开关）
- 顶部搜索栏（回车即四平台并发检索）
- 宽内容区：编辑精选海报卡、热门音乐双列、猜你喜欢封面网格、搜索结果表格（平台筛选 / 播放全部 / 收藏 / 下载）
- 右侧"正在播放"面板：大封面 + 逐字歌词（点歌词跳转）+ 队列页签
- 底部播放条：封面/曲名/收藏、上一首-播放-下一首、进度（可拖动）、播放模式、歌词、音量、下载
- 保留水墨视觉：纸色底、墨色文字、朱砂强调、霞鹜文楷、编辑精选海报渐变

## 平台层转换

| Android | Windows |
|---|---|
| MediaPlayer | FFmpeg(javacv) 解码 + Java Sound 输出（mp3/flac/m4a/ogg/wav 全覆盖） |
| AudioRecord | TargetDataLine（48k→8k 探测，多点平均降采样） |
| 悬浮窗 + 原生 Canvas | JWindow（置顶/透明）+ Java2D 自绘，逻辑一一对应 |
| SharedPreferences | `%APPDATA%\JZ音乐助手\prefs_*.json`（同 API） |
| MediaStore 公共 Music | `%USERPROFILE%\Music\JZ音乐助手` |
| 前台服务 / 闹铃 / Doze | 无需（进程常驻）；曲终走解码线程回调 |

## 本轮修掉的根因（都是"桌面才有"的问题）

1. **所有 https 直链报 `Hostname ... not verified`**：`ApiClient` 里用了
   `HttpsURLConnection.getDefaultHostnameVerifier()` 兜底，它在桌面 JVM 上拿到 OkHttp 的 SSLSession
   一律返回 false。改成自己按证书 SAN 做通配校验（`StrictHostnames`），酷狗 CDN 的特例照旧放行。
2. **下载完成瞬间整个进程崩掉**：`HistoryStore.saveDownloadItems` 在 IO 线程改
   `SnapshotStateList`，Recomposer 抛 `Unsupported concurrent change during composition`。
   现在下载状态统一经 `onUiThread` 落到 EDT，并把下载进度刷新节流到 150ms。
3. **首页"热门音乐"一直空**：`HomeCache` 里存过一份"当天 + 空列表"的缓存，命中后就不再加载。
   现在只有"当天且非空"才算命中（PC 版单独修，手机版逻辑未动）。
4. **本地缓存文件被当成远程流打开**：Windows 路径是 `C:\...`，原来的 `startsWith("/")` 判不出来。
5. **桌面歌词在 2560 宽屏上只有 12% 宽**：整栏按 `LyricsMetrics.scale=1.6` 等比放大（比例不变）。

## 验证（本机实测）

- 搜索：`晴天` → QQ 50 / 网易 50 / 酷我 32 / 酷狗 30，无报错
- 播放：解析 cyapi QQ → 打开 → 整首缓存落盘后切本地续播（位置不跳），进度条按声卡进度走
- 歌词：右侧面板逐字歌词随播放滚动、当前句加粗、点行跳转
- 下载：选 320k，实测只有 128k → 体积校验判档 → 如实降级保存并写明原因，落盘 `Music\JZ音乐助手`
- 桌面歌词：切走窗口后浮现，纸签 + 两行 + 逐字染色 + 拖动吸边均正常
- 识曲页：麦克风圆环、时长档位、结果区、最近识过

## 追加：改名 JZ Music

产品名、exe 名、窗口标题、应用内品牌统一为 **JZ Music**；数据目录随之改为
`%APPDATA%\JZ Music\` 与 `%USERPROFILE%\Music\JZ Music\`，首次启动把旧目录的配置与已下载文件拷过来。

## 追加（同日）：去掉听歌识曲

PC 端用不到识曲，整块从桌面版移除：侧边栏入口、识曲页、麦克风采集与双通道打分都不再出现在 Windows 构建里
（侧边栏现为：发现音乐 / 搜索结果 / 我喜欢的 / 下载管理 / 最近播放 / 设置 + 桌面歌词开关）。
APK 那边不受影响。

## 缺口（如实记录）

1. **听歌识曲已按要求移除**：桌面版不再包含麦克风采集与双通道打分，也不再需要 WebView/wasm 依赖。
2. **没有真机声卡的多设备回归**：本机只有一路输出设备；音量走 `MASTER_GAIN`，极端静音（-80dB）下
   个别驱动可能报"不支持该控制"，已 runCatching 兜住。
3. **安装包是 WiX 生成的 exe**：首次构建会联网下载 WiX（Compose 插件行为），离线机器首次打包会失败。

## 追加：首轮问题清单（10 项）

| # | 反馈 | 处理 |
|---|---|---|
| 1 | 下载目录要可配置 | 设置页「下载位置 → 更改目录」，JFileChooser 选择，落 `download_dir` 偏好；下载/打开目录/下载页路径全部跟随 |
| 2 | 关掉软件就退出，不能后台放 | 关窗改为收进系统托盘（`TrayManager`），播放不中断；托盘菜单：显示/播放暂停/上一首/下一首/退出；首次收起弹气泡提示。无托盘的极端环境自动退回"关窗即退出" |
| 3 | 搜索 QQ / 酷狗返回 0 | 定位：QQ 的 `client_search_cp` 被风控成 HTTP 500（同一台机器上连"晴天"都 0 条）。主源换成 `search_for_qq_cp`（结构一致、实测 200），旧接口留备源，再空退 smartbox 联想接口 |
| 4 | 没有点击特效 | 列表行/按钮/侧边栏都加了按下反馈（立即压暗 + 按钮 96% 缩放，90ms 渐变）；悬停改 90ms 过渡 |
| 5 | 主动切歌要先停当前 | 列表点歌、底部上一首/下一首：先 `PlayerManager.stop()` 再解析新源，不再"上一首还在响、新歌解析完才切" |
| 6 | 方大同《Red Bean》没有歌词 | 根因：LDDC 按"歌手+歌名"检索，英文名 `Red Bean` 查不到（改成 `红豆` 就有 35 行）。加了换名兜底：搜同曲候选（歌手一致、时长 ±5s、标题不同）拿中文名再查，现已 43 行 |
| 7 | 进度条要显示缓存 | 自绘 `SeekBar`：墨=已播 / 灰=已缓存（`PlayCache.frac`）/ 浅=未加载，可点击与拖动 |
| 8 | 歌词要逐字过渡（唱过的字变色），桌面歌词同逻辑 | 右侧歌词面板改成 AnnotatedString 逐字染色：唱过的字墨色、正在唱的字按进度插值；与桌面歌词栏共用同一套"KRC/QRC 逐字毫秒 → 字符时间"映射 |
| 9 | 桌面歌词要一直显示，不要跟着主窗口隐藏 | 去掉 `appVisible` 门控：开关打开即常驻，点 ×收起主窗口也不消失 |
| 10 | 点歌词快进/后退会卡死 | 根因：`seekTo` 从 UI 线程 `synchronized` 抢解码锁，而解码线程正卡在 `grabSamples()/write()`，互等死锁。改成"只登记 `pendingSeek` 由解码线程就地处理"，UI 立即返回；写声卡也改成按 `available()` 分片写，不再整块阻塞 |

另：加了**单实例**（文件锁），避免开出多个副本/多个托盘图标抢声卡。

## 追加：第二轮问题清单（10 项）

| # | 反馈 | 状态 |
|---|---|---|
| 1 | 点 × 仍退出，不能后台播放 | **未解决**（见下方"卡在哪"）。已查到底：Compose 在 WINDOW_CLOSING 时会销毁窗口，AWT 的 `AWTAutoShutdown` 随后结束 JVM；试过 DO_NOTHING_ON_CLOSE、隐藏窗口、Compose 隐形窗口、AWT 1×1 常驻窗口，packaged 版依旧 0.4s 后退出。可行方案是自绘标题栏（不产生系统关闭事件），下一轮做 |
| 2 | 下载页每首加删除按钮 | 已加（行内垃圾桶，直接"删除含文件"）；`remove()` 也改成"删文件失败不影响移除记录" |
| 3 | 可点元素要手型光标 | 已加 `Modifier.handCursor()`，列表行/按钮/图标/侧边栏/筛选条/面板文字全部生效 |
| 4 | 换关键词后旧结果还挂着 | 已改：`search()` 一进来就清空旧结果，且慢请求回来时若关键词已变则丢弃 |
| 5 | 猜你喜欢点《发如雪》放成方大同 | 播放下标改为按渲染时的显式下标（原来用 `indexOf`，重复条目会取错行）；热门双列同样处理 |
| 6 | 桌面歌词当前句强调弱、无逐字过渡 | 根因：只有"无逐字时间"时才喂行内进度，遇到"有逐字时间但字符对不齐"就整行不亮。改成无条件喂进度，视图按字/按行自适应；唱过=墨色、未唱=淡墨 |
| 7 | 歌词贴底时工具条把窗口顶上去 | 已改：检测下方空间不足且上方够时，工具条改为**向上**展开并同步上移窗口，栏体视觉位置不变 |
| 8 | 右下角有没功能的按钮 | 音量图标→点击静音/恢复；下载图标→当前歌曲选音质直接下载；歌词/循环保留 |
| 9 | 列表里点下载要跑到右侧面板选音质 | 已改：行内下载图标直接弹出音质菜单（标准/高品/无损），选完即下 |
| 10 | 点"删除（含文件）"后出 bug | `remove()` 防御化：删除文件失败不再抛、记录一定移除、Toast 反馈；同时避免删除正在播放的缓存文件 |

另：便携启动器加了 **payload 指纹**（解包目录 = `app-<版本>-<指纹>`）。之前同版本重新打包后，
`%LOCALAPPDATA%` 里已有的旧副本会被一直复用——这也是"改了却看不出变化"的根因之一。

## 卡在哪（第 1 项）

- 现象：点 × → `windowClosing` 监听被调用 → 窗口隐藏/最小化 → 约 0.4s 后 `AWTAutoShutdown` 触发 JVM 退出。
- 已排除：`defaultCloseOperation` 已是 `DO_NOTHING_ON_CLOSE`（日志里 op=0）；常驻的 AWT `Frame`（1×1、屏幕外、UTILITY）与 Compose 隐形窗都试过，仍然触发。
- 结论：Compose Desktop 的 `Window` 在收到 WINDOW_CLOSING 时会自行销毁窗口，绕不开。下一轮改成**无边框窗口 + 自绘标题栏**（关闭按钮直接隐藏/最小化，不产生系统关闭事件），顺带做成网易云那种自绘顶栏。

## 追加：第三轮问题清单（7 项）

| # | 反馈 | 处理 | 验证 |
|---|---|---|---|
| 7 | 设置选了"收进托盘"却直接退出 | **真凶找到**：`Window(onCloseRequest = ...)` 里一直是老的"关掉+退进程"逻辑，前几轮改的都是监听器，等于没生效。改成按 `close_action` 走"收进托盘"。又因为 AWT 的 `AWTAutoShutdown` 在最后一个可见窗口隐藏/最小化时会结束 JVM，最终做法是**把窗口挪到屏幕外**（不隐藏、不最小化、不销毁）；二次启动通过 127.0.0.1:51823 把窗口叫回来 | 打包 exe 实测：点 × 后进程存活、日志 `onCloseRequest -> hide offscreen`；再次双击 exe 窗口复原 |
| 5 | 点下载 / 点垃圾桶直接退出 | 下载菜单原来是 `DropdownMenu`（另开系统窗口），桌面版上关掉这类弹窗会触发 AWT 关停。改成**主窗口内的音质浮层**（标准/高品/无损/取消），`startDownload`、`remove` 全部 runCatching 兜底；删除时删文件失败也一定移除记录 | 浮层实测可弹出、点选后进程存活；删除逻辑已防御化 |
| 6 | 下载配置要能改下载位置 | 下载管理页顶部加「更改下载位置」（JFileChooser），与「打开下载目录」并列 | 实测两个按钮都在 |
| 1 | 歌词贴底时工具条把栏体顶上去且闪一下 | 先判定朝上/朝下，再一次性 `setBounds` 让窗口"底边不动向上长"，不再先 setSize 再 setLocation 造成"先下后上"的闪跳 | 代码完成，需在真实歌词场景复核 |
| 2 | 工具条透明 | 工具条原来只画图标不铺底色，现在先 `drawPaper` 铺和栏体同主题的纸色 | 截图确认不透明 |
| 3 | 逐字过渡 | 行内进度改成**无条件**喂给视图（之前只在"没有逐字时间"时喂，遇到有字时间但对不齐就整行不亮） | 代码完成 |
| 4 | 当前句强调不够 | 当前句加淡墨圆角底 + 已唱部分下方细下划线 + 字号不变但对比更强 | 代码完成 |

### 顺带修掉的坑
- 便携启动器缓存：解包目录带上 payload 指纹（`app-<版本>-<指纹>`），否则同版本重新打包仍跑旧副本。
- 日志：打包版没有控制台，`JzLog` 现在同时写 `%APPDATA%\JZ Music\files\desktop.log`，出问题可直接看。

## 追加：第四轮（托盘菜单 / 单击恢复 / 崩溃根因）

| 问题 | 根因 | 处理 | 验证 |
|---|---|---|---|
| 托盘右键菜单乱码、退出项显示成"JZ Music" | AWT `PopupMenu` 在 Windows 上把中文标签按平台编码塞进宽字符 API | 改自绘菜单窗口 `TrayMenuWindow`（Java2D + Microsoft YaHei） | 截图确认六项中文全对、退出项红色 |
| 托盘点击要两下才恢复 | `TrayIcon.addActionListener` 只在**双击**时触发 | 换 `MouseListener`，左键单击即恢复 | 代码路径已改（等实操确认） |
| 点下载 / 点垃圾桶，软件直接退出 | ① `HistoryStore.downloadsState` 是 `SnapshotStateList`，`clear()+addAll()` 落在重组期间 → `Unsupported concurrent change during composition`；② `Res.image()` 用 `getOrPut` 缓存 null → `putIfAbsent(key,null)` NPE，而它在组合里被调用 | 下载记录改不可变快照 + StateFlow 驱动；`Res.image` 不缓存 null；搜索/播放的状态写入统一回 UI 线程 | 打包版实测：下载存活并落盘 2.7MB、删除存活、进程不再退出 |
| 改下载目录不实时刷新 | `downloadDir` 是普通属性，Compose 观察不到 | 加 `downloadDirRevision` 状态，读取即建立依赖 | 编译验证 |
| 桌面歌词悬浮窗（独立 JWindow）一开始放歌就退出 | 独立 AWT 窗口在播放/切歌时触发 `AWTAutoShutdown` → `System.exit` | **暂时停用**（`FLOATING_BAR_ENABLED = false`），主窗口内歌词面板不受影响 | 停用后播放稳定（实测连续播放 20s+ 无退出） |

### 顺带
- `application(exitProcessOnExit = false)`：进程生死由我们决定（托盘应用不该被 Compose 直接结束）；退出路径显式 `exitProcess(0)` 保证真退出。
- 打包版日志写 `%APPDATA%\JZ Music\files\desktop.log`，崩溃栈可直接看。

## 追加：桌面歌词悬浮栏 Compose 重写（进行中）

### 已完成
- `data/LyricsBarState.kt`：悬浮栏的唯一事实源（可见性/当前句/下一句/逐字位置/主题/字号/锁定/工具条/位置版本）。
- `data/DesktopLyrics.kt`：控制器重写，去掉全部 AWT 窗口代码；只负责偏好、取词、100ms 推进、把结果写进状态。
- `ui/desktop/DesktopLyricsBar.kt`：Compose 窗口版悬浮栏——纸色圆角卡、顶部细线、逐字染色（`Karaoke.annotate`）、
  右上锁、工具条（上一句/播放暂停/下一句/A- A+/锁定/关闭）、拖动、贴屏幕底时工具条朝上、3 秒自动收起。
- 实测：窗口渲染、逐字染色（"闻风起"亮 / "韶华落"暗）、随播放滚动，全部正常，**进程不再退出**。

### 卡住的一步（所以本轮没开启）
Compose 窗口的可见性/输入在打包版里不稳定：
- 刚显示时 `isShowing=false`，手动 `isVisible=true` 后能收到点击（在 (48,48) 位置实测 `bar clickable fired`）；
- 一旦用 `window.setLocation` 定位到目标位置（如 607,722），窗口仍可见，但**收不到任何鼠标事件**；
- Win+D 之后窗口还会消失。已排除：透明窗口、focusable、toFront、尺寸 dp/px 混用（已统一为 dp=逻辑像素）。

### 现状
`BAR_ENABLED = false`（`ui/desktop/DesktopLyricsBar.kt`）。悬浮栏代码全部保留，验收通过后一行改 true 即可开启；
本轮交付包行为与上一版一致：悬浮窗关闭，主界面歌词面板正常（含逐字染色）。

## 追加：悬浮栏重写第二轮排查记录

### 这轮新增的事实（都已复现、有日志/系统调用佐证）
1. **Compose 窗口收不到输入**：`WindowFromPoint` 确认点击落在悬浮窗自己的 `SunAwtCanvas`（win32 层命中正确），
   但 composition 里 `pointerInput`/`clickable` 一个事件都没收到。只要代码里调过 `window.setSize/setLocation`，
   输入管线就失效；改成几何全交给 `winState` 后输入恢复过一次（在 (48,48) 位置抓到 `bar clickable fired`），
   但窗口一旦离开默认位置又失效。`alwaysOnTop`、`focusable`、`transparent`、`toFront` 都不影响结论。
2. **`winState.position` 只在创建时生效**：运行期改它不会移动窗口（用创建时传入 `position = WindowPosition(x.dp,y.dp)` 才真正落位）。
3. **AWT JWindow 路线同样会在"开始播放"时退出**：窗口创建成功、播放一开始，EDT 直接走 `System.exit`（shutdown hook 栈里 EDT 在 `Shutdown.runHooks`）。
4. **SecurityManager 取证在打包版不可用**：加了 `-Djava.security.manager=allow` 并装 SM 后，进程起不来（无窗口、无日志），
   该手段放弃。

### 现状
两条路线都回退到"关闭"：
- `ui/desktop/DesktopLyricsBar.kt`：`BAR_ENABLED = false`（Compose 版完整代码保留）
- `data/LyricsBarWindow.kt`：`ENABLED = false`（AWT 版完整代码保留，含拖动/工具条/位置持久化）

交付包 = 稳定版：悬浮窗关闭，主界面歌词面板（含逐字染色）正常，播放/下载/删除/托盘均验证通过。

### 下一轮的具体打法（不再猜）
- 用"最小可复现"二分：只建空 JWindow 不显示 → 只显示空窗口 → 只挂 View 不显示 → 显示+View，
  每次只跑"启动→播放 10s"，确定是哪一步引入的退出；
- 或者在窗口显示前后对比 `AWTAutoShutdown` 的 peer 集合（反射 `sun.awt.AWTAutoShutdown` 的 `peerMap`），
  看主窗口是否在歌词窗口 show 后被错误地移出集合。

## 追加：悬浮栏第三轮（二分定位）

用 `JZ_BAR_MODE` 做最小复现矩阵，每档只跑"启动 → 播 10s"，结果：

| 模式 | 内容 | 结果 |
|---|---|---|
| off | 不建窗 | 活 |
| empty | 建空 JWindow，不显示 | 活 |
| empty_show | 建空窗口并显示 | 活 |
| font | 窗口 + JLabel（霞鹜文楷）并显示 | 活 |
| view_nosync | 窗口 + `DesktopLyricsView` 并显示，但**不喂数据** | 活 |
| view | 同上 + 喂数据（setEmpty / setPair / setPosition…） | **约 5s 后退出** |
| view + NOPAINT | 同上但 `drawScene`/`rebuild` 直接 return | **仍退出** |
| view + NORESIZE | 同上但 `applyHeight` 不执行 | **仍退出** |
| view + 单次 setEmpty | 只调一次 `setEmpty("测试文本")` | **仍退出** |
| JWindow 带 owner / 改 undecorated JFrame | 换窗口类型 | **仍退出** |

结论：
- 与"画"无关（关掉绘制照样退），与"改窗口尺寸"无关（关掉 resize 照样退）；
- 只要**歌词组件被喂了内容**（哪怕一次 `setEmpty`），约 5 秒后 JVM 就会在 EDT 上走 `System.exit`；
- 换窗口类型（JWindow owner / undecorated JFrame）都不改变结果；
- 打包版里装 SecurityManager 做取证会直接起不来，此路不通。

### 现状
`LyricsBarWindow` 默认 `MODE=off`（需环境变量才启用），`DesktopLyricsBar`（Compose 版）`BAR_ENABLED=false`。
交付包行为：悬浮窗关闭、主界面歌词面板（逐字染色）正常、播放/下载/删除/托盘均稳定。

### 下一步（留给下次，方向已很窄）
在 `LyricsBarView` 被喂数据那一刻，反射打印 `sun.awt.AWTAutoShutdown.getInstance()` 的 `peerMap` 键集合，
确认主窗口是否被移出；若被移出，说明 `WToolkit` 在我们创建第二个顶层窗口时把主窗口 peer 清掉了，
修法是"让悬浮窗与主窗共享同一个 toolkit 窗口容器"，或干脆把歌词画在主窗口的**同进程透明覆盖层**里。

## 追加：悬浮栏第四轮（排除 AWTAutoShutdown + 给出新方案）

### 这轮新增的证据
- 反射 `sun.awt.AWTAutoShutdown.peerMap`（`--add-opens java.desktop/sun.awt(.windows)=ALL-UNNAMED`）持续打印，
  在崩溃前最后一次快照是 **n=9 个窗口**（ComposeWindow 主窗、ComposeDialog 驻留窗、JWindow 驻留窗、TrayIcon、
  悬浮窗 JFrame、SharedOwnerFrame…）。**peerMap 非空 → 不是 AWTAutoShutdown 触发的退出**。
- 把 `main` 拆成 `runApp()` + `AppRoot()`，在 `application {}` 返回后打日志：**这条日志始终没出现**，
  说明 Compose 的 application 作用域没有结束，也不是 Compose 主动退出。
- 也就是说：**EDT 上有一处显式 `System.exit`**，但它既不是我们的关闭/托盘分支（都会先打日志），也不是 Compose 的收尾。

### 结论
在 `DesktopLyricsView` 被喂入任何文本之后 ~5 秒，一定有某个东西在 EDT 上调 `System.exit`；
它不来自我们的代码、不来自 Compose 的 application 结束、也不来自 AWTAutoShutdown 的空窗口判定。
用 SecurityManager 取证在打包版会起不来，这条路已排除。

### 交付
悬浮栏默认关闭（`LyricsBarWindow.MODE=off`，`DesktopLyricsBar.BAR_ENABLED=false`），
诊断开关（`JZ_BAR_MODE` / `JZ_BAR_SYNC` / `JZ_BAR_NOPAINT` / `JZ_BAR_NORESIZE` / `JZ_PEER_TRACE`）全部保留。

### 建议的下一步方案（绕开问题，而不是继续追）
把悬浮栏做成**独立进程**：主程序通过本地 socket 推送"当前句/下一句/播放位置/主题"，子进程只负责开窗画字。
- 子进程的 AWT 出任何问题都杀不到播放器；
- 主程序只需要 `ProcessBuilder` + 一条 JSON 行协议；
- 位置/字号/拖动状态仍存在主程序偏好里，子进程启动时接收一次。
这是目前唯一能"结构上保证不再退出"的做法。

## ★ 根因定案：所有"用着用着突然退出"的真凶

`Main.kt` 的**单实例检查写在了 composable 内部**（`AppRoot`）。Compose 每次重组都会重跑它，
第二次 `SingleInstance.tryAcquire()` 必然失败（端口已被自己占用），于是执行 `exitProcess(0)`。

所以：**任何触发重组的功能**（歌词窗出现、下载/删除后列表更新、切歌后面板刷新…）都会在几秒内把进程干掉，
而且日志里只会看到一句 "JVM shutdown"，没有任何异常——这解释了整整几轮查不到原因的退出。

证据（shutdown hook 抓的栈）：
```
System.exit
 ← java.lang.Runtime.exit
 ← com.jz.musichelper.MainKt.AppRoot(Main.kt:104)
 ← RecomposeScopeImpl.compose          // 重组时执行
 ← ComposerImpl.recompose$runtime
```

修法：把单实例检查移到 `main(args)` 里、`application {}` 之前（一次性执行）。

## 桌面歌词悬浮栏（重写后的最终形态）

- 架构：`data/LyricsBarState`（状态）+ `data/DesktopLyrics`（控制器）+
  `data/LyricsBarWindow`（进程内 AWT 窗口 + 原 Java2D 视图）+ `LyricsBarMain`/`LyricsBarProcess`（子进程方案，保留备用）。
- 渲染：**已验证正常**——纸色卡、逐字染色、上下两句、随播放推进，且**不再导致退出**。
- 已知限制：该悬浮窗在本机**收不到鼠标事件**（已确认：`WindowFromPoint` 命中的就是我们的窗口；
  窗口样式含 `WS_EX_NOACTIVATE`；JWindow / undecorated JFrame、进程内外都试过；Swing 的
  `mousePressed/mouseReleased` 一次都没进）。因此"点栏体出工具条 / 拖动改位置"目前不可用。
- 结论：悬浮栏默认关闭（`dl_enabled=false`），开关仍在设置与侧边栏里，打开可看到歌词显示。

## 本轮实测（交付配置：悬浮栏关闭）

| 场景 | 结果 |
|---|---|
| 搜索周深 → 播放 | 通过（142 首，四平台有数） |
| 行内下载 → 选音质 | 通过（进程存活、文件落盘） |
| 下载页删除 | 通过（存活、记录移除） |
| 关窗 → 托盘 | 通过（进程存活、日志 hide offscreen） |
| 再次双击 exe | 通过（窗口复原） |
| 连续播放 30s+ | 通过（无退出） |

## 又来一个同类坑：`init()` 也在 composable 里（本轮修掉）

上一条修了"单实例检查在 composable 里"。继续查日志发现 `JZ_DL: init enabled=true` **每 100ms 刷一次**——
`PlayLog.init() / HistoryStore.init() / DownloadManager.init() / PlayerManager.init() / NetworkProbe.init() /
NextTrackCache.init() / PlayCache.init() / DesktopLyrics.init() / AppState.startAutoContinue()`、
以及 shutdown hook、未捕获异常兜底，**全都写在 `AppRoot()` 里**，于是每次重组：

- 重复注册 shutdown hook（成千上万个，退出时能把进程拖死）；
- 重复 `DesktopLyrics.init()` → 反复 `LyricsBarWindow.show()` → 悬浮栏每 100ms 重定位一次（闪烁）；
- 重复 `PlayerManager.init()` / 下载管理器 init → 状态竞争。

修法：全部搬进 `runApp()`，在 `application {}` 之前执行一次。

## 悬浮栏改 undecorated JFrame

- `JWindow` 的 peer 带 `WS_EX_NOACTIVATE`（0x08000000），点击不进 Swing 派发链；
  改 `JFrame(isUndecorated = true, alwaysOnTop = true)` 后 peer 是 `SunAwtFrame`、ex 只有 `WS_EX_TOPMOST`。
- 仍然存在（本机）：窗口级 `mousePressed` 也不触发；`WindowFromPoint` 命中的确实是它。
  → 结论：**这台机器的注入输入进不了非主窗口**，与窗口类型无关。
- 对策：位置不靠拖动，新增**位置预设**（设置 → 桌面歌词 → 位置：上/中/下 × 左/中/右），
  实测 `hx=2,vy=0` → 栏体移到 `1215,0`（右上角），默认 → `607,722`。
- 另外设了 `isAutoRequestFocus = false`，避免悬浮栏一起来就把主窗口挤成"非活动窗口"。

## 本轮实测

| 场景 | 结果 |
|---|---|
| 启动（悬浮栏开） | 通过：`init` 只打一次；栏体 `607,722 492x105`；播放正常；歌词 52 行 |
| 位置预设 右下 → 右上 | 通过：`bar repositioned to 1215,0` |
| 连续播放 30s+ | 通过：无退出 |
| 搜索/播放/下载/删除/关窗到托盘/二次启动 | 通过（见上一节） |

## 仍待确认（如实记录）

- 自动化点击对**侧边栏底部两项（桌面歌词/设置）**和右上齿轮偶发无效：
  `WindowFromPoint` 命中的是主窗口 canvas，但 Compose 的 clickable 没被触发（会中途换一批点击又生效）。
  怀疑是合成输入在此环境下的焦点/激活问题，需要人手点一次确认。
- 悬浮栏本体仍收不到鼠标事件（工具条/拖动不可用），位置用设置里的预设代替。

## 第 6 轮反馈（用户实测）：6 条，逐条处理

> 用户要求：先看 QQ/网易云/酷狗 的窗口架构再改。结论：它们的主窗"×"=最小化到托盘（可配置），
> 桌面歌词是 **WS_EX_TOOLWINDOW**（无任务栏按钮）的置顶窗，靠悬停出工具条、可拖动。

| # | 反馈 | 根因 | 处理 |
|---|---|---|---|
| 1 | × 之后完全关不掉，托盘右键也没反应 | × 会收进托盘 + 自绘托盘菜单在某些状态弹不出来 | × 改成"关前台、**不留托盘**、进程留后台"；托盘只在 − 时出现；二次启动 exe 唤回 |
| 2 | × 应该直接从前端关掉（连托盘都不显示），− 才是最小化托盘 | 语义错了 | × = 关前台留后台（设置里选"直接退出"则真退出）；− = 收进托盘（会装回托盘图标） |
| 3 | 下载管理里删完，条目还在 | 下载任务的收尾回调会把记录加回来 | `DownloadManager` 增加 `removedIds` 墓碑，`appendItem/updateItem` 见到墓碑直接丢弃 |
| 4 | 悬浮栏放到底部仍显示不全 | 行数变化/工具条展开后没同步窗口高度 | `sync()` 里内容变化即 `applyHeight()`；贴底时窗口向上长高、按"栏体底边"锚点决定工具条朝上 |
| 5 | 悬浮栏没有逐字染色（右侧面板有） | 两个原因：① `paused` 残留为 true → 整句按"暂停"淡墨画；② 逐字时间的裁剪重画用 `clipRect`，本机实测不生效 | ① 每 tick 同步 `paused = !isPlaying`；② 改用"画已唱前缀"的方式（`sungPrefix`），实测已唱字变成 `#2C2822` 实墨 |
| 6 | 点歌词跳转后被瞬间拽回当前句 | 自动滚动没有缓冲 | 用户手动滚动/点歌词后"按住" 8s / 3s 再自动回位（`holdUntil`） |
| 7 | 悬浮栏变成了"新的托盘应用" | 用了 `JFrame` → 任务栏多一个图标 | 换成 `JDialog(owner) + undecorated + Type.UTILITY` → peer 是 `SunAwtDialog`，`ex=0x88`（TOPMOST + **TOOLWINDOW**），任务栏无图标 |

### 附带发现
- `JWindow` 的 peer 带 `WS_EX_NOACTIVATE`，点击永远进不了 Swing 派发链；
  `JDialog(Type.UTILITY)` 既能点，又没有任务栏按钮 —— 这是本轮最关键的修复。

### 实测记录
- 栏体窗口样式：`ex=0x00000088 toolwindow=True`（无任务栏按钮）
- 点栏体 → `toolbar open=true`，工具条 6 键（⏮ ⏸ ⏭ A- A+ 🔒 ✕）在栏体**上方**完整显示
- 逐字染色：截图取色 `#2C2822`（实墨）与淡墨并存，已唱部分清晰可见
- × → `onCloseRequest -> hide to background (no tray)`，进程存活、窗口与歌词栏都移出屏幕
- 二次启动 exe → 主窗回到前台、歌词栏一起回来
- − → `minimize -> tray` + `tray installed`，窗口收起

## 修：点 × 之后托盘里还留着一个图标

**现象**：点 × 后主界面没了、音乐还在放，但右下角托盘（的溢出面板里）仍然有 JZ Music 的图标。

**根因**：托盘图标是在**启动时**就装上的（`DisposableEffect` 里 `TrayManager.install(...)`），
`onCloseRequest` 里的 `TrayManager.remove()` 在图标被 Windows 收进"溢出面板"后再摘除，
系统托盘不会立刻重排，用户看到的还是旧图。

**改法：托盘图标只在"收进托盘"这个状态存在。**
- 启动：只装驻留窗口（keep-alive），**不装托盘图标**。
- `×`：关前台 → 移出屏幕 + 摘掉托盘图标（本来也没装）。
- `−`：最小化 → 装托盘图标 + 移出屏幕。
- 从托盘/二次启动唤回：显示窗口后立刻摘掉托盘图标。
- `TrayManager.remove()` 不再顺手销毁驻留窗口（否则 AWT 认为"没有可见窗口"会结束 JVM），
  改成退出时才 `destroyKeepAliveWindow()`；另外记录所有装过的 `TrayIcon`，`remove()` 时一并摘除，防止历史泄漏。
- 歌词栏隐藏时 `sync()` 直接返回，不再每 100ms 算一次负坐标（曾把工具条方向锚点算成 -21740）。

**实测**（打包 exe）
- 启动日志：只有 `keep-alive window installed`，没有 `tray installed`。
- 点 × → `onCloseRequest -> hide to background (no tray)` + `tray icon removed`，进程存活、音乐继续。
- 再次双击 exe → 主窗回到 (48,48) 前台、歌词栏一起回来，日志 `tray icon removed`。
- 最小化（−）→ `minimize -> tray` + `tray installed`。
## 修（关键）：「点 × 收进后台」之后，× 直接没反应了

**现象**：上一版把 × 改成"关掉前台、不留托盘"之后，点 × 什么都不发生——窗口纹丝不动、音乐照放，
用户连"关掉这个窗口"都做不到（`−` 还能最小化，但关不掉）。

**根因**（日志坐实）：`onCloseRequest` 是进来了，但隐藏动作挂在 `TrayManager` 的 `onHide` 回调上：

```
W/JZ_APP: onCloseRequest -> hide to background (no tray)
I/JZ_TRAY: tray icon removed
I/JZ_TRAY: windowClosing -> hide offscreen (op=0)     ← 打完了日志，窗口没动
```

`onHide` 只有在**装托盘图标时**才会被赋值，而上一版改成"启动不装图标"，
于是启动后 `onHide == null`，`hideMainWindow()` 是个空炮。× 看上去就是"死按钮"。

**改法：回归 QQ 音乐 / 网易云 / 酷狗的语义，且隐藏动作自包含**

| 操作 | 行为 |
|---|---|
| `×`（默认） | 收进托盘：装托盘图标 → 记窗口位置 → `isVisible=false`（任务栏按钮随之消失）→ 气泡提示；音乐继续 |
| `×`（设置=直接退出） | 真退出：停歌词、停播放器、摘托盘、销毁驻留窗口、结束进程 |
| `−` | 普通最小化到任务栏（不再自己接管，不装托盘图标） |
| 托盘左键 / 菜单「显示主界面」/ 再双击一次 exe | 按原位置唤回，并立刻摘掉托盘图标 |

要点：
- `hideToTray` 自己就是完整实现，不再依赖 `TrayManager` 的回调（`hideMainWindow()` 已删除）；
- 藏的是窗口本身（`isVisible=false`），不是"挪到屏幕外"——任务栏按钮才会真的消失；
  进程靠常驻的 keep-alive 窗口撑着，AWTAutoShutdown 不会结束 JVM；
- 桌面歌词窗是**无 owner 的 `Type.UTILITY` 对话框**（`WS_EX_TOOLWINDOW`），
  所以主窗收进托盘时它**继续显示**、任务栏也不多图标——实测 `ex=0x88 vis=True`；
- 托盘右键菜单的 DPI 坑：`TrayIcon` 事件坐标是**物理像素**、AWT 的 `setLocation` 是**逻辑像素**，
  150% 缩放下菜单会掉到屏幕外（看起来"右键没反应"）。改成用 `MouseInfo` 取指针位置，
  超出逻辑屏幕就按 `defaultTransform` 缩放折回来。
- 「界面与托盘」设置文案同步改成：× = 收进托盘（可改为直接退出），− = 普通最小化。

**实测（打包 exe，150% 缩放 / 2560×1600）**
- 启动：`vis=True`，托盘图标 **不存在**（`tray installed` 不出现）
- 点 ×：`vis=False`、进程存活、`tray installed`、`play.log`/CPU 继续增长、歌词栏 `vis=True ex=0x88`
- 任务栏：主窗 `vis=False`，无 JZ 按钮
- 托盘（溢出面板）左键 → `tray icon removed` + `main window shown`，位置/尺寸原样
- 托盘右键 → 菜单在图标上方屏内弹出（`menu at 1266,707`），点「显示主界面」→ 窗口回来
- `−` → `iconified=True`、**无**托盘图标；最小化状态下被关（Alt+F4）→ 收进托盘，再唤回正常
- 设置改成「直接退出」→ 点 × 进程干净退出（`quit: lyrics+player shutdown, then exit`）
- 再双击一次 exe → 第二个进程退出、主窗回到前台

## 修：托盘右键菜单太丑 / 没有反馈 / 关掉托盘面板后不消失

**现象**：右下角溢出面板里右键 JZ Music，弹出来的是很朴素的纯文字块；鼠标划过去没有高亮；
关掉托盘面板之后菜单还赖在屏幕上，非得点一下才消失。

**根因**：菜单窗口是 `JWindow` + `Window.Type.POPUP`。POPUP 类型在 Windows 上会被设成
`WS_EX_NOACTIVATE`——**永远拿不到焦点**，于是
- `windowLostFocus` 根本不会触发（"点别处/关面板后自动消失"这条逻辑等于没写）；
- 悬浮高亮也不稳定。

**改法**
- 换成**可获焦**的 `JWindow`（`focusableWindowState=true` + `setAutoRequestFocus(true)`），
  失焦/`windowDeactivated` 即收；
- 视觉重做：224×40/行 的墨色圆角卡片 + 柔和投影（per-pixel 透明）+ 轻描边；
  每行一个线性图标（窗口/播放·暂停/上一首`|<`/下一首`>|`/电源），危险项（退出）上方一条分隔线；
- 交互：悬浮行淡墨高亮、按下再深一档、松开才执行（"按下去就消失"没有反馈的问题）；
- 实测这台机器上托盘右键拿不到前台焦点（`GetForegroundWindow` 仍是别的窗口），所以额外加了一层
  "盯鼠标"的兜底收起：进过菜单又离开 → 1 秒收；跑到离右键位置很远 → 0.7 秒收；
  一直没进菜单 → 2.5 秒收。指针回到菜单里计时清零。

## 修：桌面歌词栏三个交互 bug

**现象**
1. 收起状态下**点一次栏体没反应**，得连点两次工具条才出来；
2. 在屏幕底部唤出工具条、等它 3 秒自动收起后，**栏体被顶上去了**一节（越开越高）；
3. 栏体贴底、工具条朝上弹出时，**按钮点不动**。

**根因**
1. 3 秒自动收起只改了视图（`DesktopLyricsView.setToolbar(false)`），
   `LyricsBarState.toolbarOpen` 还是 `true`。下一次点栏体，`toggleToolbar()` 先把状态改成 false
   （视图本来就是收起的，没有视觉变化），**第二次点才真正打开**——所以永远是"点两次"。
2. `applyHeight()` 只在"工具条收起"时把 `anchorBottomY` 记成 `win.y + barH`，而窗口高度变小后
   y 仍沿用旧顶边 → 栏体停在被抬起的位置，且这个位置又被当成下一次的锚点。
3. 工具条的命中矩形是用**绘制坐标**（朝上时是负 y，因为画布整体下移了）算的，
   而鼠标事件是**组件坐标**；朝上时热区全在屏幕外，自然点不到。
   另外 `mousePressed` 用 `e.y > barH` 判断"是否点在工具条上"，朝上时栏体本身就满足这个条件。

**改法**
- 自动收起 / 拖动前收起工具条都走 `DesktopLyrics.setToolbarOpen(false)`，状态与视图保持一致；
- `applyHeight()` 改成以**栏体底边**为唯一锚点：工具条朝上 → `y = anchor - h`；
  收起/朝下 → `y = anchor - barH`。工具条开合只会让窗口上下长，栏体永远停在原处；
- 命中矩形改用组件坐标（`hitTop`），并用 `toolbarAbove` 区分"工具条在上/在下"，
  朝上时点栏体 = 收起工具条；
- 顺带：空态（"暂无歌词"）时也能唤出工具条（之前在空态分支里 `return` 了，工具条根本没画）。

**实测**（150% 缩放，打包 exe）
- 栏体 738×157 → 点 1 次 → 738×288（向上长，底边 1528 不动）✅
- 工具条朝上点"播放/暂停"→ 图标由 ⏸ 变 ▶、歌词淡墨 + 暂停标记 ✅（之前点不动）
- 等 3.4 秒自动收起 → 回到 910,1371 738×157，与初始完全一致 ✅（不再被顶上去）
- 收起后再点 1 次 → 立即展开 ✅
- 托盘菜单：悬浮高亮 ✅、点空白 1.2 秒内消失 ✅、不碰它 2.5 秒自己消失 ✅、
  点"显示主界面"菜单收起且主窗回来 ✅

## 改：底部播放条去掉两个"看不懂"的图标按钮，播放模式改成图标按钮

**问题**：右下角播放条上是「单曲循环」四个字 + 一个歌词图标 + 音量 + 一个下载箭头。
- 那行文字看不出能点，点了也没有任何反馈；
- 歌词图标（气泡带音符）和"正在播放"面板里已有的歌词页签重复，纯图标又看不出是什么；
- 下载箭头在**右侧「正在播放」面板里本来就有**（带音质菜单），播放条上这个是重复的。

**改法**
- 删掉播放条上的「歌词」与「下载」两个图标按钮（功能没丢：歌词走顶栏的歌词页签/面板，下载走右侧面板的下载按钮）；
- 「单曲循环」文字 → 图标按钮：列表循环 `Repeat` / 单曲循环 `RepeatOne` / 随机播放 `Shuffle`，
  点一下切换并弹一条"播放模式：xxx"的轻提示（图标本身也需要一点解释）；
- 底部右侧宽度从 250dp 收到 190dp，音量区不再被挤。

## 改：发现音乐「编辑精选」四张卡换成纸色

**问题**：四张卡是整块高饱和渐变（暖金 0xFFF0B45A / 宝蓝 0xFF5A7DF0 / 玫红 0xFFE0608E / 青绿 0xFF3EC6A8），
和全 App 的"水墨 + 纸底"完全不在一个体系里，放在一起很扎眼。

**改法**：类别色只保留成"一笔墨"，不再是底色
- 底：`lerp(surface, 类别色, 0.10)` 的淡染，向下渐变回纸色 `surface`；
- 左侧一道 3dp 窄色条（`lerp(类别色, 墨, 0.18)`）用来分类；
- 右下角一个大号楷体水印字（华/粤/影/欧），低透明度，像盖在纸上的印记；
- 标题恢复墨色、11sp 副标题用弱文字色；
- 悬浮：HoverRow 的淡墨底 + 边框由 10% 提到 50% 强调色。

## 修：单曲循环其实在「顺序播放」（关键）

**现象**：播放模式选了单曲循环，一首放完却接着放下面的歌。

**根因是一条链，四个环节叠在一起**：

1. `advanceAfterTrackEnd` 在**所有模式**下第一件事就是 `PlayCache.clear()`（"播完即删"）。
   单曲循环马上要重播同一首，却先把它的本地缓存文件删了；
2. 重播直接复用 `PlayerManager.currentUrl`——那正是刚被删掉的本地路径。
   而"是不是本地文件"的判断写成了 `!it.startsWith("/")`：Windows 路径是 `C:\…`，
   **永远判成"非本地"**，所以删掉的文件照样被当成可用源；
3. 打开已删除文件失败 → `onTrackPlaybackFailed` → 重新取流；运气不好取流也失败时，
   `resolveAndPlayIfNeeded` 里的 autoSkip 会调用 `nextSong()` —— 于是"单曲循环"就变成了"顺序播放"；
4. 另外 `onTrackCompleted()` 先判 `q.isEmpty()`：队列为空时，单曲循环直接返回 false，也会掉进"下一首"分支。

**改法**
- 单曲循环**不清缓存**（`if (playMode.value != SINGLE_LOOP) PlayCache.clear()`）；
- 新增 `replayCurrent(tag)`，按三条硬规则取源：
  ① 预取缓存命中 → 直接本地起播；
  ② 仍有效的在线 URL 或**磁盘上确实存在**的本地文件（`File(u).exists()`）；
  ③ 都没有 → 重新取流（**绝不跳下一首**）；
- `onTrackCompleted()` 把 SINGLE_LOOP 提到最前面判断，与队列无关；
- autoSkip 在单曲循环下改为"原地重播"（前 3 次），不会直接跳到下一首；
- 日志补了 `mode=` 与 `replayCurrent tag=… cached=… url=…`，以后一眼能看出走了哪条路。

**实测**（150% / 2560×1600，连点 3 轮"seek 到末尾 → 播完"）

```
trackEnd tag=completed key=QQ001zMQr71F1Qo8 mode=SINGLE_LOOP
replayCurrent tag=completed key=QQ001zMQr71F1Qo8 cached=true
play cache key=QQ001zMQr71F1Qo8 tag=single
play gen=3 src=本地预取 ...\prefetch\QQ001zMQr71F1Qo8.bin
```

三轮全部重播同一首（`tag=single`，同一 key），列表循环仍正常切下一首（`tag=next`），随机仍不重复。

## 修：下拉菜单 / 开关是 Material 默认淡紫

**现象**：右侧「正在播放」面板点下载，弹出的音质菜单是淡紫底（`#F3EDF7`），和纸墨配色打架。

**根因**：桌面壳 `DesktopShell()` 从来没套过 `AppTheme`，Material3 组件取的是**默认色板**；
而 Material3 的浮层用的是 `surfaceContainer` 系列颜色，默认就是 Material 的淡紫。

**改法**：把纸墨色板抽成 `InkColorScheme`（含 `surfaceContainer*`、`surfaceTint`），
在 `Main.kt` 里用 `MaterialTheme(colorScheme = InkColorScheme)` 包住 `DesktopShell()`
（只换颜色，不动桌面壳自己的字体排版）。

**实测**：菜单底色 `#F9F5EC`（纸色），边框淡墨，与白纸底一致。

## 全面测试（本轮）

| 项 | 结果 |
|---|---|
| 冷启动 / 无托盘图标 | ✅ 只有 keep-alive，无 tray installed |
| 搜索（四平台） | ✅ 「晴天」158 首，按平台分栏可筛 |
| 点热门列表播放（建队列） | ✅ 起播 + 预取下一首 |
| 暂停 / 继续 | ✅ 暂停时歌词转淡墨、按钮变 ▶ |
| 上一首 / 下一首 | ✅ 解析到不同 key 并起播 |
| 进度条点击跳转 | ✅ `seek applied` |
| 音量静音 / 恢复 | ✅ 0 ↔ 1，持久化 |
| 收藏（播放条爱心） | ✅ 写入 favorites |
| 播放模式三态（单曲/列表/随机） | ✅ 单曲重播同一首；列表下一首；随机不重复 |
| 右侧面板「队列 / 正在播放」 | ✅ 队列显示当前曲目，可切回 |
| 音质选择下拉 | ✅（本轮修好配色） |
| 设置页 | ✅ 窗口与托盘、桌面歌词、音质、下载位置、关于 |
| 桌面歌词开关 | ✅ 工具窗 `ex=0x88`（TOPLEVEL+TOOLWINDOW），任务栏无图标 |
| 歌词栏点栏体开合工具条 | ✅ 首点即开、再点收起、3 秒自动收起后回原位 |
| × 收托盘 / 托盘唤回 | ✅ 窗口隐藏、无任务栏按钮、托盘有图标；唤回位置尺寸不变 |
| 托盘右键菜单 | ✅ 纸色卡片 + 悬浮/按下反馈，点空白/不理会均自动收起 |
| 异常日志 | ✅ crash.log 无新条目（仅有 01:09/01:13 两条历史） |

顺手记下但未改的两个小瑕疵：
- 设置页「最近一次异常」显示的是上午 01:13 的旧崩溃（`skia Paint` 初始化失败），不是本次的；
  若不想看到，可以在设置页加一个"清除"按钮。

## 修：把播放模式做成"看得出状态"的按钮（单曲循环以为坏了的那次）

**用户反馈**：单曲循环还是往下播。

**查到的事实**（prefs 时间戳 + play.log）：用户那次会话（20:15:11 启动、20:16:22 退出）里，
`play_mode` 在 **20:15:57 被写成了 `SHUFFLE`**——也就是当时根本不是单曲循环，而是随机播放。
为什么会这样：上一轮把「单曲循环」文字换成了**纯图标按钮**，
`Repeat`（列表循环）和 `RepeatOne`（单曲循环）在 12px 上几乎分不出，
用户点了两下以为在单曲循环，实际停在随机播放上。

而且那段时间的 play.log 里**没有任何 `trackEnd`**——歌都没放到结尾，
全是"点列表换歌"（`playSongs` 会先 `PlayerManager.stop()`），所以不是播完自动跳。

**结论**：单曲循环的代码路径（上一轮修的 `replayCurrent`）是对的，
坏在"模式状态看不见"这一层 UI。

**改法**
- 播放模式按钮改成**图标 + 当前模式名**（`⟳ 单曲循环` / `↻ 列表循环` / `⤨ 随机播放`）：
  是按钮（有悬浮高亮、按下变色、手型光标），但把状态摆在明面上；
- 点击后仍然弹"播放模式：xxx"的轻提示；
- `cyclePlayMode()` 补一条 `PlayLog.log("playMode -> X")`，以后能直接从日志追溯模式切换。

**实测**
- 模式按钮：`随机播放 → 单曲循环 → 列表循环 → 随机播放`，每次点击 prefs 与日志同步（`playMode -> SINGLE_LOOP` 等）；
- 单曲循环下，把进度拖到接近结尾、自然播完：
  `trackEnd tag=completed key=QQ0039MnYb0qxYhV mode=SINGLE_LOOP` → `replayCurrent ... cached=true`
  → `play cache ... tag=single` → 同一首重播 ✅

## 加：让「单曲循环」这件事看得见（第三次反馈）

**用户反馈**：单曲循环依旧是顺序播放。

**又查了一遍日志**（用户会话 21:13:17~21:14:13）：
- 整个会话**一条 `trackEnd` 都没有**——没有任何一首播到结尾；
- 一共 30 多次 `stop gen=N` → `resolve start key=<另一首>`，每次间隔 0.3~2 秒。
  这种"显式 stop + 立刻换歌"只可能来自两处：`playSongs()`（点列表里的一行）或播放条的 ⏭/⏮。
  也就是说，那段时间歌一直在被**点/切**，从来没跑到结尾，单曲循环根本没机会触发。

**但"用户以为在单曲循环、实际不在"这件事必须根治**，所以这一轮加了三处可见性：
1. 播放条右侧的按钮已经带模式名（上一轮），这次再加：
2. **右侧「正在播放」面板标题旁显示状态**：`单曲循环 · 已重播 N 次`（没重播过就只显示"单曲循环"），
   重播计数在换歌时清零；
3. **重播时弹一条轻提示**：`单曲循环 · 重播《歌名》`；
4. 日志补齐：`ui: next/prev`、`ui: play row -> 歌名`、`playMode -> X`、`replayCurrent ...`，
   下次再有"顺序播放"的反馈，日志能直接指出是谁切的歌。

**实测**（点一次热门行开播 → 模式=单曲循环 → 拖到结尾 → 自然播完）

```
seek applied gen=2 -> 264395ms
completed gen=2 pos=269025
trackEnd tag=completed key=QQ0039MnYb0qxYhV mode=SINGLE_LOOP
replayCurrent tag=completed key=QQ0039MnYb0qxYhV cached=true
play cache ... tag=single
play gen=3 src=本地预取 ...\prefetch\QQ0039MnYb0qxYhV.bin
```
面板同时显示 `单曲循环 · 已重播 1 次`，进度回到 00:10/04:29（同一首）。

## 改：日志默认写进项目目录，老日志已迁入并校验

**要求**：日志别再往 C 盘（`%APPDATA%\JZ Music\files`）放，改成项目里的相对路径，并把以前的日志全部迁过来。

**改法（`AppEnv.logsDir`）**：按顺序解析，命中即用
1. `JZ_LOG_DIR` 环境变量 / `-Djz.log.dir=`（相对路径按当前工作目录）；
2. 从"启动位置"向上找项目根 —— 便携启动器传 `--launch-dir=<它自己所在目录>`，
   再退到代码所在目录、当前工作目录；**项目根判定**：能看到 `tools/build-desktop.ps1`
   或 `desktop/build.gradle.kts` 或 `.git` 的目录；
3. 找不到（被单独拷到别的机器）→ 应用所在目录下的 `logs`；
4. 目录不可写 → 退回旧位置，绝不因为日志路径把应用带崩。

配套：
- `desktop.log` / `play.log` / `crash.log` 全部改写到 `<项目根>/logs/`；
- 便携启动器（`Launcher.cs`）把自己的目录用 `--launch-dir` 传进来，
  否则应用只会从 `%LOCALAPPDATA%` 的解包目录向上找，还是落回 C 盘；
- 歌词栏子进程由主进程传 `--log-dir=<主进程日志目录>`；
- 设置页「关于」里的日志目录改为显示新路径，「打开日志目录」也指向它；
- `.gitignore` 增加 `logs/`（本机排查用，不入库）；
- 启动时第一行日志打印 `logs dir -> <绝对路径>`，以后一眼能确认落点。

**迁移结果（`tools/migrate-logs.ps1`，校验通过才删源文件）**

| 文件 | 方式 | 源行数 | 目标行数 | 期望行数 | 校验 |
|---|---|---|---|---|---|
| crash.log | 复制（哈希比对） | 46 | 46 | 46 | PASS |
| desktop.log | 合并（旧内容放前、新内容放后） | 2129 | 2132 | 2132 | PASS |
| play.log | 复制（哈希比对） | 943 | 943 | 943 | PASS |

校验口径：SHA-256 一致、行数一致、`desktop.log` 以旧内容开头并以新内容结尾（时间顺序不乱）。
迁移后 `%APPDATA%\JZ Music\files` 已清空（0 个文件）。

**运行验证**
- 直接跑 app-image：`logs dir -> D:\Projects\Private_music\logs`；
- 跑打包的便携 exe：同样解析到 `D:\Projects\Private_music\logs`；
- `%APPDATA%\JZ Music\files` 与 `%LOCALAPPDATA%\JZ Music\**\logs` 都没有新文件（计数 0）。

> 注：`cache/`（播放缓存）、`prefs_*.json`（设置）仍在 `%APPDATA%`，它们不是日志；要一起搬的话再说。

## 改：更换下载位置不再弹系统目录框，改成应用内纸墨风选择器

**要求**：点「更改下载位置 / 更改目录」弹出的那个框太丑，重新设计一款和主题搭配的。

**原因**：原来用的是 Swing `JFileChooser`（`DIRECTORIES_ONLY`）。它在 Windows 上弹的是系统老式目录框：
灰底、无圆角、还带「文件类型」下拉，跟纸墨界面完全是两个软件；顺带还能把整盘根目录
（截图里那次的 `D:\`）选成下载目录，把歌直接丢到盘符根下。

**改法**：新建 `ui/desktop/DirPicker.kt`（`DirPicker` 状态 + `DirPickerOverlay()`），
`pickDownloadDir()` 只负责打开它。仍然画在主窗口里的一层浮层，不另开系统窗口——
桌面版的历史坑：独立窗口容易触发 AWT 关停 / 收不到鼠标事件。

- **配色**：纸色渐变卡（`#FDFBF4 → #F4EEDF`）+ 18dp 圆角 + 1dp 墨色描边 + 柔和投影；
  朱砂（`#B03A2E`）只用在标题窄签、选中竖条、悬浮文件夹图标和主按钮旁的字；
  左栏纸色比卡片深一档，用来分区而不是画线。
- **左栏**：常用位置（下载/音乐/桌面/文档/图片/视频，OneDrive 接管的情况也认）、
  本应用（默认位置 / 当前下载目录，两者相同时只留一条）、此电脑（盘符用系统显示名，
  例「新加卷 (D:)」）。
- **中部**：`↑` 上一级、`↻` 刷新、面包屑（路径太深时留「盘符 … 最后两级」）、
  文件夹列表（中文本地化排序、跳过 `$RECYCLE.BIN` 之类的系统垃圾目录、隐藏目录压淡），
  单击进入、整行悬浮高亮、底部 18dp 渐隐不硬切最后一行。
- **底部**：路径框可编辑（`前往` 跳转）、`新建文件夹` 就地起名、`取消`、`下载到这里`；
  下方一行说明"将保存到 …"，出错时变朱砂。
- **护栏**：当前目录是盘符根时主按钮置灰，并提示"这是整块磁盘的根目录，请进入其中一个文件夹再选"。
- **键盘**：Esc 先收「新建文件夹」再关浮层（窗口级预览接管，见 `Main.kt`）；
  回车在没有输入焦点时走窗口预览，在输入框里走 IME Done，两条都收口到 `DirPicker.enterPressed()`。
- **其它**：空文件夹给一个淡墨大文件夹图标 + 两行提示；读目录失败（无权限）显示朱砂提示；
  目录读取走 `Dispatchers.IO`，不占 UI 线程。

**验证（打包前的 gradle run，2560×1600 @150%）**
- 从下载管理点「更改下载位置」打开浮层，左栏/面包屑/列表渲染正常；
- 进入 `D:\Projects\Private_music\.build` 列表正常；点「新建文件夹」→ 输入名称 → 点「创建」
  生成目录并自动进入（日志 `JZ_DIR: mkdir …`）；
- 点「下载到这里」→ 下载管理页头部立即变成新目录，底部浮出"下载目录已改为 …"
  （日志 `JZ_DIR: picked …` 与 `JZ_DLM: downloadDir -> …`）；
- 盘符根目录下主按钮置灰 + 朱砂提示，选不了 `D:\`（正是旧对话框那次选出来的脏值）；
- Esc 关闭；点遮罩关闭；`↑`/`↻`/面包屑跳转正常。


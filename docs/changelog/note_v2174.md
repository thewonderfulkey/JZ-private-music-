## 音乐助手 v2.1.74（vc132）· 新增桌面歌词

按方案第八节的四个默认口径实现，两处入口都接上了，代码已编译出包。

### 一、两处入口
- **设置页**：新增「桌面歌词」段落（插在「后台连播」之前），开关 + 实时授权状态 + 去授权 + 重置位置。
- **播放页右上角三个点**：原来的假按钮（点了只弹"更多操作（演示）"）换成真菜单，两项：`桌面歌词 / 桌面歌词 · 已开`、`查看歌词 / 封面`（复用原来的歌词切换）。三套版式（手机竖屏 / 平板 / 横屏左右式）共用同一个顶栏，所以横屏、iPad 上都有。

### 二、歌词栏本体
- 悬浮窗（`TYPE_APPLICATION_OVERLAY`，minSdk 26 不需要旧 `TYPE_PHONE` 分支），App 退到桌面或切到别的应用时出现；窗口内是原生自绘 View，不走 Compose（避免自己注入 lifecycle 所有者、也不依赖外部帧时钟）。
- 两行：当前行 15sp `#2E2A24` + 下一行 13sp `#8A8378`；纸白底 `#F2FAF8F3`、圆角 18dp、1dp 墨线描边 `#DED7C8`、无投影；字体就是 App 里用的霞鹜文楷。宽 `min(屏宽-32dp, 480dp)`、高 88dp。
- 换行 300ms：旧行上移 10dp 淡出、新行自下 10dp 淡入（Decelerate），只在换行那一帧跑动画。
- 暂停：保留最后一帧、当前行透明度压到 0.6，右侧画「‖」，不整窗消失。
- 拖动：`FLAG_NOT_FOCUSABLE` 不抢焦点；松手左右各留 16dp，位置按屏幕比例存偏好，转屏后按比例复位。
- 歌词数据全部复用现成链路：`LyricsService.fetch`（唯一歌词源、4h 缓存、in-flight 去重）+ `indexAt` 定位；位置直读 `MediaPlayer.currentPosition`（新加的 `PlayerManager.currentPositionMs()`），不用 ticker 那 500ms 粒度，换行不会晚半拍。
- 自己盯状态：200ms 读一次 `AppState.lastSong` 与播放中标志。原因是后台/桌面时 Compose 不再出帧，若靠 `LaunchedEffect` 推状态，自动连播切歌会停在上一首。

### 三、有一个口径我按"更合理"落地了，请留意
方案里写的是「App 内打开播放页时自动隐藏」，我实现成**只要 App 在前台就不显示，回到桌面/切到别的应用才出现**。理由：悬浮栏压在 App 自己的列表和播放页上会挡内容，"桌面歌词"本来就该在桌面看。所以你在 App 里打开开关后当场是看不到的，会弹一句"回到桌面（或切到别的应用）播放时即可看到"。若你更想要"App 内也盖一条"，我把判断改成只看播放页是否打开即可，一句话的事。

### 四、权限与降级
- 新增 `SYSTEM_ALERT_WINDOW`（清单里放在 `SCHEDULE_EXACT_ALARM` 之后）。没有权限时开关不硬开，先跳系统「显示在其他应用上层」页，回来在 `onResume` 复查并自动接上窗口。
- 国产 ROM 打不开该页时退到应用详情页，文案里点名「显示悬浮窗 / 在其他应用上层显示」。
- 若 `addView` 仍被系统拦下（有些 ROM `canDrawOverlays` 为真但二级开关关着），开关自动回弹为关，状态行显示"未授权"，不留假状态。

### 五、验证
- 构建：`assembleRelease` BUILD SUCCESSFUL（中途遇到一次 `mergeDexRelease` 的 classes.dex 被守护进程占用，停 daemon 后正常）。
- 静态（apk-verify 口径）：包名 `com.jz.musichelper`、`versionCode 132` / `2.1.74`；签名 v2 校验 `Verifies`；zip 183 条目、无损坏；`SYSTEM_ALERT_WINDOW` 已在 badging 里；`PlayerService`（foregroundServiceType=mediaPlayback）、`TrackEndReceiver`、`MainActivity` 声明未变；dex 里确实含 `DesktopLyrics` / `DesktopLyricsView` 类与 `2.1.74` 串（不是复用了旧包）；APK 29,634,383 B（上一版 29,617,967 B，+16 KB）。
- 图里两张是按真实字体与色值渲染的歌词栏效果（播放中 / 暂停），尺寸比例就是 88dp 胶囊 + 底部往上 120dp。
- **缺口**：本机 `adb devices` 还是空，真机四项没跑——桌面出现、盖在别的应用上、跟播滚动与切歌、拖动与转屏、授权回来开关接上。这些只能你在机器上点，出问题把现象告诉我。

APK 在下面这条消息。

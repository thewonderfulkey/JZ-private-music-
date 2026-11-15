# Windows 桌面版（PC 版式）

> 与 APK 共用同一套网络层 / 播放引擎 / 歌词逻辑（PC 端不做识曲）；界面按 PC 音乐客户端（网易云 / QQ 音乐 / 酷狗 PC）的结构重做。

## 一、为什么不是"手机版原样搬过来"

第一版曾把 APK 的 Compose 手机竖屏界面整份搬进桌面窗口（430×900 的"手机壳"）。
在手机上那套版式是精心排过的；一到桌面（1280 宽、甚至最大化）就变成单列被拉宽、内容挤在左上角，
观感上就是"另一个 App"。所以现在的做法是：

- **保留**：四平台检索、多后端取流兜底、整首缓存、自动连播、逐字歌词、下载校验、
  收藏/历史/设置、桌面歌词悬浮栏、水墨色板与霞鹜文楷。
- **不做**：听歌识曲（PC 端用不到；麦克风采集与双通道打分整块不进入桌面版）。
- **重做**：导航与布局。左侧栏 + 宽内容区（表格/卡片）+ 右侧"正在播放"（大封面 + 滚动歌词 + 队列）+ 底部播放条。

## 二、界面结构

```
┌───────────┬─────────────────────────────────────────┬──────────────────┐
│ JZ Music   │  发现音乐   [搜索框]          歌词 设置  │  正在播放         │
│ PC · 水墨版│                                          │  ┌────────────┐  │
│           │  ┌──── 内容区（按左侧导航切换）────┐     │  │   封面      │  │
│ 发现音乐  │  │ 编辑精选 · 热门音乐 · 猜你喜欢   │     │  └────────────┘  │
│ 搜索结果  │  │ 搜索结果表（平台筛选/播放全部）   │     │  歌名 / 歌手      │
│ 我喜欢的  │  │ 收藏 · 下载 · 历史 · 设置        │     │  逐字歌词（可点跳）│
│ 我喜欢的  │  └──────────────────────────────────┘     │  队列（页签切换）  │
│ 下载管理  │                                           │                  │
│ 最近播放  │                                           │                  │
│ 桌面歌词  │                                           │                  │
│ 设置      │                                           │                  │
├───────────┴───────────────────────────────────────────┴──────────────────┤
│ 封面 歌名/歌手 ♥ │ ⏮ ⏯ ⏭ │ 00:00 ─────●──── 04:29 │ 循环·歌词·音量·下载 │
└──────────────────────────────────────────────────────────────────────────┘
```

默认窗口 1280×830，最小 980×640；右栏可收起。关窗 = 收进系统托盘（音乐继续放），退出走托盘菜单；单实例运行。

## 三、平台层对照（Android → Windows）

| Android | Windows | 说明 |
|---|---|---|
| `MediaPlayer` | FFmpeg（javacv）+ `SourceDataLine` | 统一解 mp3/flac/m4a/ogg/wav；JavaFX 不支持 FLAC 也不能带 UA/Referer |
| `AudioRecord` | —（已移除） | PC 端不做听歌识曲，麦克风采集不进桌面构建 |
| `TYPE_APPLICATION_OVERLAY` 悬浮窗 | `JWindow`（置顶/无边框/逐像素透明）+ Java2D 自绘 | 同一份绘制逻辑（纸签/逐字染色/工具条/拖动吸边） |
| `SharedPreferences` | `Data\prefs_*.json`（安装版，安装目录下）；开发模式仍是 `%APPDATA%\JZ Music\` | 同 API（getXxx / edit().putXxx().apply()） |
| `MediaStore` / 公共 Music 目录 | `Download\`（安装目录下，下载默认落这里） | 开发模式回退到 `%USERPROFILE%\Music\JZ Music` |
| 前台服务 / 闹铃 / Doze | 无（进程常驻） | 桌面不存在息屏冻结，曲终直接走解码线程回调 |
| `WebView`（afp.wasm 指纹） | —（已移除） | 桌面端不做识曲，不引入 WebView 依赖 |

## 四、已移除：听歌识曲

PC 端不需要识曲，整块（侧边栏入口、识曲页、麦克风采集、双通道打分）都不在桌面版里。
侧边栏现在是：发现音乐 / 搜索结果 / 我喜欢的 / 下载管理 / 最近播放 / 设置（外加桌面歌词开关）。

> 移植时顺带确认过：APK 的网易 afp 引擎依赖 WebView 跑 wasm，而 JavaFX WebView 实测
> `typeof WebAssembly === undefined`。既然桌面端不做识曲，这条依赖也就彻底不需要了——
> 不用为了它引入 JCEF/Chromium（那要多 200MB）。

## 五、目录

```
desktop/
├── build.gradle.kts            Compose Desktop + javacv(ffmpeg) 依赖、jpackage 打包配置
├── icons/app.ico               应用图标（由 assets/icon-headphones.png 生成）
└── src/main/
    ├── kotlin/com/jz/musichelper/
    │   ├── Main.kt             入口：初始化、窗口（1280×830）、桌面歌词焦点联动、冒烟注入
    │   ├── model/ network/     与 APK 共用（取流/歌词/排序），仅平台接缝改过
    │   ├── data/               PlayerManager(ffmpeg) / VoiceCapture / DesktopLyrics / 存储 / 下载
    │   └── ui/
    │       ├── desktop/        ★ PC 版式（DesktopShell / DesktopPages / DesktopMisc / Components）
    │       ├── App.kt 等       手机竖屏版式（保留作对照，不参与 PC 版渲染）
    │       └── theme/          水墨色板 + 字体
    └── resources/              字体、水墨底图、afp 资产（后者当前未启用）
```

## 六、构建与验证

```powershell
pwsh -File .\tools\build-desktop.ps1            # 编译 + 打包便携版
pwsh -File .\tools\build-desktop.ps1 -Run       # 开发模式直跑
pwsh -File .\tools\build-desktop.ps1 -Publish   # 产物打进 releases\windows\
pwsh -File .\tools\build-setup.ps1              # 安装包（推荐分发方式，见下）
```

产物：

- **安装包（对外主发）**：`releases\windows\JZ Music Setup-<版本>.exe`
  —— 由 `tools\build-setup.ps1` 生成（源码 `tools\setup\`），装完就是一个 `JZ Music` 文件夹：
  `JZ Music.exe` + `app\` + `runtime\` + `Download\` + `Log\` + `Cache\` + `Data\` + `Backup\` + `说明\` + 卸载程序。
  安装/卸载/静默参数见 [docs/INSTALL.md](INSTALL.md)。
- 免安装单文件：`releases\windows\JZ Music-<版本>-portable.exe`
  —— 由 `tools\build-portable-exe.ps1` 生成：把 app-image 压成 zip、作为资源嵌进一个 .NET 启动器。
  首跑解包到 `%LOCALAPPDATA%\JZ Music\app-<版本>-<指纹>\`（约 4s）并写 `.ready` 标记，之后直接拉起内部 exe（约 2s）。
  这个解包目录就是它的「安装根」，所以数据也落在里面（`Download\` / `Log\` / `Data\` / `Cache\`），
  删掉那个目录 = 连配置一起清空。
- 开发产物：`desktop\build\compose\binaries\main\app\JZ Music\`（app-image 目录，调试用）
- jpackage + WiX 安装包：`desktop\build\compose\binaries\main\exe\JZ Music-<版本>.exe`（**不再对外提供**）

自动化验证（等价 APK 侧的 adb 冒烟）：

```powershell
# 启动后自动搜索并播第一首，日志里打各平台条数
$env:JZ_SMOKE_SEARCH='晴天'; $env:JZ_SMOKE_PLAY='1'
pwsh -File .\tools\build-desktop.ps1 -Run

# 截图与点击（按窗口内像素坐标，脚本自己换算 DPI）
pwsh -File .\tools\desktop-ui.ps1 -Cmd shot -Out .build\shot.png
pwsh -File .\tools\desktop-ui.ps1 -Cmd click -Coords 120,197
pwsh -File .\tools\screenshot-printwindow.ps1 -Out .build\shot.png   # 窗口被遮挡也能截
```

## 七、命名与目录

- 产品名 / exe 名 / 窗口标题 / 应用内品牌统一为 **JZ Music**（与 APK 的「JZ 音乐助手」区分开）。
- **安装版**：一切都跟着安装目录走 —— 配置 `Data\`、下载 `Download\`、日志 `Log\`、缓存 `Cache\`、备份 `Backup\`。
  整个文件夹拷走就能搬机；卸载时可选保留 Download/Data。
- **开发模式**（`gradle run`，没有 jpackage 安装根）：沿用旧布局 `%APPDATA%\JZ Music\`、
  `%USERPROFILE%\Music\JZ Music\`、`<项目根>\logs`。
- 从旧布局升级到安装版：第一次启动把 `prefs_*.json` **拷**进 `Data\`（只拷不删，写
  `.migrated-from-appdata` 标记）；旧下载目录里的歌不搬，按文件名把下载记录里的路径修正到 `Download\`。

## 八、约定

1. 版本号与 Android 同源（读 `android/app/build.gradle.kts` 的 `versionName`）。
2. 桌面版有自己的版式文件（`ui/desktop/`），不要再把手机版式塞回窗口里。
3. 播放位置只能用声卡已消费帧数（`SourceDataLine.longFramePosition`）算，不能用解码进度——解码快于实时。
4. Compose 的 Snapshot 状态只能在 UI 线程写（`data/onUiThread`），后台线程写会直接把进程打挂。

# 工程结构与模块职责

> 基准：v2.1.91（v2.1.92 起识曲模块拆出 `RecognizeScore`）
> 统计：42 个 Kotlin 文件 / 约 1.4 万行；包名 `com.jz.musichelper`

## 分层

```
app/src/main/java/com/jz/musichelper/
├── MainActivity.kt            入口 Activity（Compose）
├── ui/                        界面层（Compose）
├── data/                      运行时状态与系统集成（播放/下载/持久化/悬浮窗）
├── network/                   网络与解析（搜索/取流/歌词/封面/识曲）
└── model/                     数据模型
```

**没有** Retrofit / Room / Hilt / Navigation。HTTP 用 OkHttp 手写（`ApiClient`），持久化用 SharedPreferences + JSON（`HistoryStore`），导航用 `AppState.tab` + 条件渲染。

## ui/

| 文件 | 约 | 职责 |
|---|---|---|
| `App.kt` | 116KB | `AppState` 全局状态机（搜索、播放、识曲、队列）、`MainTab` 六格底栏、MiniPlayer、播放页覆盖、识曲起播与"其他版本"逻辑 |
| `HomeScreen.kt` | 96KB | 首页：搜索框/历史、编辑精选、热门分页、猜你喜欢、结果列表 |
| `PlayerScreen.kt` | 57KB | 播放页三套版式（手机竖屏 / 平板画心 / 横屏左右）、歌词视图、下载弹层、三点菜单 |
| `InkSplash.kt` | 45KB | 水墨开屏动画（分层山水 + 音符收尾 + 跳过） |
| `RecognizeScreen.kt` | 35KB | 识曲页：麦克风、阶段文案、结果纸签、其他版本、最近识过 |
| `DesktopLyricsView.kt` | 33KB | 桌面歌词悬浮栏的原生 Canvas 自绘（逐字染色/工具条/纸色/锁定） |
| `SettingsScreen.kt` | 28KB | 设置：音质、桌面歌词、后台连播白名单、数据管理、关于（内建近 6 版变更） |
| `AppTheme.kt` | 6KB | 水墨色板 `InkInk`（纸/墨/朱砂）、两款楷体、背景渐变 |
| 其余 | | `DownloadsScreen` `FavoritesScreen` `HistoryScreen` `InkSearchBar` |

## data/

| 文件 | 职责 |
|---|---|
| `PlayerManager.kt` | `MediaPlayer` 封装、进度/播放态 |
| `PlayerService.kt` | 前台服务（`mediaPlayback`），保证息屏/后台不被回收 |
| `TrackEndAlarm.kt` / `TrackEndReceiver` | Doze 下曲终唤醒（精确闹铃兜底） |
| `PlayCache.kt` | 当前曲整首缓存 → 落盘后切本地源续播 |
| `NextTrackCache.kt` | 下一首预取 |
| `DownloadManager.kt` | 四档音质下载、状态机、本地文件管理 |
| `DesktopLyrics.kt` | 悬浮窗生命周期、100ms ticker、偏好（纸色/字号/锁定）、歌词定位 |
| `VoiceCapture.kt` | 麦克风采集：`VOICE_RECOGNITION` 音源、原生采样率探测、多点平均降 8k、RMS 静音判据 |
| `HistoryStore.kt` | 搜索历史、最近播放、识曲历史（50 条）、识曲时长偏好 |
| `PlayLog.kt` | 播放日志 |

## network/

| 文件 | 职责 |
|---|---|
| `ApiClient.kt` | OkHttp 封装：GET JSON / POST bytes / POST form，统一 UA/Referer/超时，`ApiError` 分类 |
| `SearchAdapters.kt` | 四平台搜索适配器（QQ / 网易 / 酷我 / 酷狗）+ 酷我变体过滤与相关性过滤 |
| `SearchAndResolve.kt` | 搜索聚合 + 取流解析主流程 |
| `SourceAdapters.kt` | 10 个取流后端，按音质出直链 |
| `SearchRanker.kt` | 全平台结果排序（质量分、去重、前缀/专辑收敛） |
| `StudioPick.kt` | 录音室原唱优选：核心歌名、共识时长、`studioScore` |
| `CoverResolver.kt` | 封面解析、去重、并发限流、QQ 兜底 |
| `LyricsService.kt` | 歌词单一入口：4h 缓存、in-flight 去重、多源分派 |
| `LddcLyrics.kt` / `LddcCrypto.kt` / `LddcMatch.kt` | LDDC 双源（酷狗 KRC / QQ QRC）解密、逐字时间解析、匹配 |
| `KwLyrics.kt` | 酷我官方歌词（行级时间） |
| `TraditionalMap.kt` | 繁→简映射（30KB 表），用于歌词清洗与歌手比对 |
| `RecognizeAdapter.kt` | 酷狗指纹识曲 + `Judge`（变体/合集/原唱判定） |
| `NeteaseFingerprint.kt` | WebView 承载 afp 引擎，PCM → 指纹 |
| `NeteaseRecognizer.kt` | 网易 `audio/match` 调用与解析 |
| `RecognizeScore.kt` | **v2.1.92**：双通道候选归一化、聚类、打分与择优 |
| `NetworkProbe.kt` | 网络可用性探测（Doze 等待重试用） |

## 资源与包体

| 项 | 体积 | 说明 |
|---|---|---|
| `res/font/lxgw_wenkai_regular.ttf` | 19.31 MB | 霞鹜文楷（正文/标题） |
| `res/font/mashanzheng_regular.ttf` | 5.86 MB | 马善政（题字） |
| `assets/afp_wasm_b64.js` + `sandbox.bundle.js` + `recognizer.html` | 397 KB | 网易 afp 指纹引擎（WebView 加载） |
| `res/drawable-nodpi/*` | ~1.7 MB | 水墨背景、开屏分层图 |

APK 约 29.9 MB，其中字体占 25.2 MB。要瘦身只能做字体子集化（会掉生僻字，需产品决策）。

## 关键约束

1. **`MediaPlayer` 单实例**：`PlayerManager` 全局唯一，切歌走 `release + new`，不要并发建两个。
2. **识曲结果必须能落到"可播条目"**：识曲只给元数据，播放仍走 `SearchService` + `StudioPick`。
3. **悬浮窗 View 不走 Compose**：后台不出帧，Compose 的 `LaunchedEffect` 收不到状态；必须自己 100ms 轮询。
4. **版本号三处一致**：`build.gradle.kts` / 设置页「关于」/ 发布 note。验证脚本会查。
5. **改 UI 前先看 `docs/design/功能基线-39项.md`**：功能不许丢。

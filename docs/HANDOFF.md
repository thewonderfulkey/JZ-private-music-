# JZ 音乐助手 · 接手说明（基准版 v2.1.91）

> **⚠️ 目录已于 2026-11-12 重组，本文中的旧路径只作历史参考。** 新旧对应：
>
> | 本文提到的旧位置 | 现在的位置 |
> |---|---|
> | `…\new-chat-1\JZMusicHelperAndroid\` | `D:\Projects\Private_music\android\` |
> | `…\new-chat-1\*.apk` | `releases\`（最新一版）/ `archive\apk\`（历史） |
> | `…\new-chat-1\note_v*.md`、`gh_note_*.md` | `docs\changelog\` |
> | `…\new-chat-1\_tmp_build\verify_*.py` | `tools\verify\` |
> | `…\new-chat-1\_tmp_build\probe_*.py`、`re_*.py` | `tools\probes\` |
> | `…\new-chat-1\听歌识曲免费通道探活报告.md` | `docs\recognition\` |
> | `…\new-chat-1\笒音2.0.1-API逆向对照.md` 等 | `docs\api\` |
> | `…\new-chat-1\桌面歌词-实现方案-v2.1.74.md`、`功能基线-39项.md` | `docs\design\` |
> | `03-构建服务API\` | `services\`（已改为不入库） |
> | `D:\Projects\Private_music\01-APK发布\`、`05-源码归档\` 等 | `releases\` / `archive\` |
>
> 最新进度见 `CHANGELOG.md`、`docs\changelog\note_v2192.md`、`docs\RECOGNITION.md`。
> 构建：`D:\Projects\Private_music` 下 `pwsh -File tools\build.ps1`（工具链在 `.build\toolchain`）。

> 编写时间：2026-11-12
> 依据：`C:\Users\17948\DoubaoWork` 下的工作目录、技能包、逐版交付说明（note_*.md）、验证日志（verify_*.txt）、探活报告，以及 `JZMusicHelperAndroid` 源码本体。
> 说明：豆包那边**没有可读的对话记录原文**（`chats\` 是它的工作目录而不是聊天导出；桌面端历史存在 `AppData\Local\Doubao\User Data` 的 Chromium 库里，无法直接读）。真正能还原开发过程的，是它每版写下的 `note_vXXXX.md`（"改了什么/为什么/实测数据/验证表/缺口/自查步骤"）＋`verify_*.txt` 静态验证输出。本文就是把这些串起来的结论。

---

## 0. 一句话现状（先看这三条落差）

**代码最新版是 v2.1.91，但它只存在于豆包的工作目录里。**

| 位置 | 内容 | 版本 | 状态 |
|---|---|---|---|
| `C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\` | **最新源码工程 + 最新 APK** | **v2.1.91（vc149）** | ✅ 唯一最新 |
| `D:\Projects\Private_music\` | 你给的"项目地址" | v2.1.73（vc131） | ⚠️ 落后 18 个版本 |
| GitHub `thewonderfulkey/JZ-private-music-` | 第五版 Release | v2.1.79 | ⚠️ 落后 12 个版本 |
| `D:\Projects\Private_music\01-APK发布\` | 按 README 只留最新 APK | 里面是 v1.6.4 | ❌ 已不符合规则 |

- 最新包：`JZ音乐助手-v2.1.91.apk`，29,859,137 B，MD5 `C1A8447B9B6FB0CF064CC9CB3D49FB9C`
- **本轮我独立复核过**（不依赖它的日志）：`aapt2 dump badging` → `com.jz.musichelper / 149 / 2.1.91 / minSdk 26 / target 34 / label "JZ Music"`；`apksigner verify --print-certs` → 证书 SHA-256 `916ad2328810c691a4022d9716a77709e9ebb08aa262b373c0b05b8c6aed07ac`，与其历史各版一致（同为 Android Debug 证书，可覆盖安装）
- 与构建产物 `app\build\outputs\apk\release\app-release.apk` 的 MD5 完全一致（已核对），即"发出去的就是这份源码编出来的"
- `D:\Projects\Private_music` 的 git 最后提交是 2026-11-11 15:28（v2.1.73），之后 2.1.74→2.1.91 全部没有入库

**所以接手第一件事不是写代码，是先把 2.1.91 收进版本控制（见 §8）。**

---

## 1. 资产地图

| 路径 | 是什么 | 备注 |
|---|---|---|
| `DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\` | **Android 主工程**（Gradle，无 gradlew，用本机 gradle-8.9 调） | 42 个 .kt / 13,773 行 |
| 同上 `JZ音乐助手-v2.1.91.apk` | 最新交付包 | MD5 与 build 产物一致 |
| 同上 `JZ音乐助手-v2.1.0~2.1.90-*.apk` | 全量历史包（约 40 个） | 体积 12~30MB 不等 |
| 同上 `_tmp_build\` | **验证/探针脚本主战场**：`verify_2191.py` 等逐版验证脚本、`probe_*.py` 接口探活、`mock_*.py` 用 HTML 还原界面截图、`re_*.py` 逆向与规则回归 | 最有价值的"方法沉淀"在这里 |
| 同上 `_tmp_fb2\` `_tmp_fb3\` `_tmp_fb4\` | 逐版 note（v2.1.26→2.1.90） | note 即"交付说明" |
| 同上 `note_2191.md` `gh_note_*.md` | 最新版说明 / GitHub 发布记录 | |
| 同上 `听歌识曲免费通道探活报告.md` | 识曲全部免费通道的实测普查（228 行） | v2.1.91 网易通道的依据 |
| 同上 `桌面歌词-实现方案-v2.1.74.md` | 桌面歌词方案（权限/降级/视觉/风险） | |
| 同上 `笒音2.0.1-API逆向对照.md` | 竞品（`com.cenmusic.app`）音乐/封面/歌词 API 逆向对照，给出"我们该补什么" | 2.1.87 酷我封面/歌词的来源 |
| 同上 `_rea_v6\` | 逆向工程资产：lx-music-source v6/v7 签名算法、`V6/V7签名算法.md`、竞品 dex/APK 样本 | 音源侧的"外挂能力库" |
| 同上 `JZ音乐助手-UI改版-原型\功能基线-39项.md` | v2.0.4 的 39 项功能基线（UI 改版不许丢功能） | 回归清单 |
| 同上 `UI设计文档.md` / `UI设计Skill\SKILL.md` | 早期 UI 规范（暗色 Material 路线） | **已被水墨方向取代**，仅作史料 |
| `D:\Projects\Private_music\` | 面向用户的归档仓库（git，remote 指向 GitHub） | 停在 v2.1.73 |
| `D:\Projects\Private_music\03-构建服务API\` | 网易云 API（api-enhanced）、LrcApi、LDDC 工具、node_modules | 本地构建/歌词服务，日常迭代不动 |
| `D:\Projects\Private_music\04-歌曲API调研\` | 音乐 API 审计包、测试脚本 | 调研资产 |

---

## 2. 工程与技术栈

```
JZMusicHelperAndroid/
├── build.gradle.kts / settings.gradle.kts / gradle.properties / local.properties
│   └─ 无 gradlew（用 C:\Users\17948\AppData\Local\Programs\gradle-8.9\bin\gradle.bat）
└── app/
    ├── build.gradle.kts        applicationId com.jz.musichelper, vc149 / 2.1.91
    │                           compileSdk 34, minSdk 26, targetSdk 34, JDK 17
    │                           release 也签 debug（为了直装），isMinifyEnabled=false
    └── src/main/
        ├── AndroidManifest.xml 权限/组件（见 §3.9）
        ├── assets/             网易 afp 指纹引擎三件套（recognizer.html / afp_wasm_b64.js / sandbox.bundle.js ≈ 397KB）
        ├── res/font/           霞鹜文楷 19.31MB + 马善政 5.86MB ← 包体大头
        ├── res/drawable-nodpi/ 水墨背景、开屏分层图
        └── java/com/jz/musichelper/
            ├── MainActivity.kt
            ├── ui/             App.kt(116KB) HomeScreen(96KB) PlayerScreen(57KB) InkSplash(45KB)
            │                   RecognizeScreen(35KB) SettingsScreen(28KB) DesktopLyricsView(33KB)
            │                   DownloadsScreen FavoritesScreen HistoryScreen InkSearchBar theme/AppTheme
            ├── data/           PlayerManager PlayerService DownloadManager PlayCache NextTrackCache
            │                   DesktopLyrics TrackEndAlarm HistoryStore PlayLog VoiceCapture
            ├── network/        SearchAdapters SourceAdapters SearchAndResolve SearchRanker StudioPick
            │                   LyricsService LddcCrypto LddcLyrics LddcMatch KwLyrics CoverResolver
            │                   RecognizeAdapter NeteaseFingerprint NeteaseRecognizer NetworkProbe
            │                   TraditionalMap(30KB 简繁映射) ApiClient
            └── model/          Model.kt PlayMode.kt
```

依赖只有 8 条：Compose BOM 2024.09.03 + material3 + icons-extended、activity-compose、lifecycle、coroutines、**OkHttp 4.12**、**Coil 2.7**。没有 Retrofit、没有 Room、没有 Hilt——全部手写 + SharedPreferences/JSON 文件持久化。

**关键技术选择（改代码前必须知道）**
- 播放：`MediaPlayer` + `PlayerService`（前台服务 `mediaPlayback`）+ `WAKE_LOCK` + Doze 白名单 + `SCHEDULE_EXACT_ALARM` 曲终唤醒（v2.1.67~2.1.72 是围绕"息屏播完不切歌"打的硬仗）
- 歌词：`LyricsService` 单一入口（4h 缓存 + 并发去重）；酷我官方接口优先（v2.1.87），失败回退 LDDC 双源（酷狗 KRC / QQ QRC），`LddcCrypto` 解出**逐字时间**（v2.1.79 起的核心技术资产）
- 音源：4 平台搜索（QQ/网易/酷我/酷狗）+ 10 个取流后端（`SourceAdapters`）+ 多后端并发解析 + 失败换源
- 识曲：酷狗 `fingerprint.service`（8k PCM 直传）主通道 + 网易 `audio/match`（WebView 跑 afp.wasm 生成本地指纹）兜底（v2.1.91）
- 桌面歌词：`TYPE_APPLICATION_OVERLAY` 悬浮窗 + **原生 Canvas 自绘**（不走 Compose），逐字染色按 KRC/QRC 真实时间

---

## 3. 功能现状（v2.1.91 实际能力）

### 3.1 导航与骨架
6 个 Tab：**首页 / 识曲 / 收藏 / 下载 / 历史 / 设置**（v2.1.83 加识曲页）＋播放页全屏覆盖 ＋ MiniPlayer（画卷式悬浮条，含 4 个按钮）＋ 开屏动画（水墨山水分层，4s，可跳过）。

### 3.2 首页
搜索框（含历史展开）＋编辑精选横条卡＋热门榜单（分页 7×3，与"猜你喜欢"同款）＋猜你喜欢双列网格；板块顺序 v2.1.62 调整过。

### 3.3 搜索
四平台并发，先回先显示；`SearchRanker` 全平台合并排序；平台行标出各平台返回条数（v2.1.88 "N 平台并发"按实际注册数计数）；无源歌曲自动隐藏（`deadSongKeys`），检测中灰置；酷我相关性过滤改大小写+空白不敏感（v2.1.88 修"酷我 0 条"）。

### 3.4 取流
`UrlResolver.resolveAll` → 多后端并发 → 按音质挑源（流畅/标准/高品/无损）→ 失败换源；连续无源自动跳过（上限 3）；同曲并发去重。

### 3.5 播放
三态循环（列表/单曲/随机，持久化）、自动连播、息屏保活、防退出重播、`PlayCache`（v2.1.85：整首缓存到本地、进度条下画缓存带、落盘后切本地源续播、只缓存当前一首）、`NextTrackCache` 预取下一首。

### 3.6 歌词
酷我官方（平台 ID 精确匹配、行级时间）→ LDDC 酷狗 KRC（逐字时间）→ LDDC QQ QRC → 其他；简繁清洗（`TraditionalMap` 30KB）；损坏检测与多重采样交叉验证（v1.5.x 老资产）；播放页大歌词双击切换。

### 3.7 封面
`CoverResolver` 去重 + 并发限流；酷我 `MVPIC`→`img1.kuwo.cn/wmvpic`（v2.1.87，约 78% 有值）；空值走 QQ 同歌名+歌手兜底；黑胶封面判定；热门封面预取。

### 3.8 桌面歌词（v2.1.74→2.1.79，两处入口：设置页 / 播放页三点菜单）
悬浮窗、两行（当前行+下一行）、霞鹜文楷、纸色三选（素纸/旧黄/夜墨）、字号五档、锁定、轻点浮出 6 格工具条（上一句/暂停/下一句/字号/锁定/关闭，3s 自动收）、拖动吸边、转屏比例复位、逐字染色按**真实逐字时间**、暂停保留最后一帧变灰 + 「‖」。
口径：**App 在前台一律不显示，回桌面/切别的应用才出现**（方案原写"仅播放页隐藏"，实现取了"更合理"的一版，可一句话改回）。

### 3.9 听歌识曲（v2.1.80→2.1.91，6 个版本的迭代）
- 入口：识曲 Tab（整页只有麦克风可点）、播放页三点菜单（跳过去并直接开听）
- 采集：`VOICE_RECOGNITION` 音源，原生采样率（48k/32k/16k/8k 依次探测）→ 多点平均降到 8k
- 通道：**先录 6s 打酷狗，认出立即出结果；没对上继续录满 12s，同时打酷狗+网易**；网易失败时酷狗已用更长片段复跑（互为兜底）
- 时长档位：12/15/20s（旧 5/10s 自动按 12s）；聆听中再点麦克风＝取消
- 结果页：方角纸签「识 所 得」+ 朱砂印、歌名 26sp、歌手/专辑分两行、「播放这首歌」墨块主操作、「再听一次｜其他版本 · N 条」
- 起播：按「歌名+第一位歌手」检索，命中综艺/现场版时不锁翻唱者，在同曲录音室版里择优；队列取同曲前 6 条
- 原唱判定（v2.1.90 D 口径）：只标一处「原唱」小印；命中即录音室版按识曲歌手标；命中现场/综艺版则要求"同歌手 ≥2 张不同正式专辑且时长互差 ≤3s"才标，推不出就不标
- 历史：50 条，SharedPreferences `rec_history`，退出保留

### 3.10 下载与设置
四档音质下载 + 下载管理（进度/重试/取消/删除本地文件）；设置页：音质、桌面歌词（开关/授权状态/纸色/字号/锁定/重置位置）、后台连播与电池白名单入口、数据管理、关于（**内建最近 6 个版本的变更记录**，是现成的 changelog）。

### 3.11 清单权限（全都要清点，避免"加了权限没测"）
`INTERNET`、`POST_NOTIFICATIONS`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_MEDIA_PLAYBACK`、`WAKE_LOCK`、`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`、`SCHEDULE_EXACT_ALARM`、`SYSTEM_ALERT_WINDOW`、`WRITE_EXTERNAL_STORAGE(maxSdk 28)`、`RECORD_AUDIO`；组件：`MainActivity`、`PlayerService(mediaPlayback)`、`TrackEndReceiver`。

---

## 4. 版本时间线（只列有据可查的节点）

| 版本段 | 主题 |
|---|---|
| v1.0–v1.5.x | 从 0 到可用：4 平台搜索/取流/下载、歌词 LrcApi 多重采样交叉验证、简繁清洗、酷我三方签名链 |
| v1.6–v1.9.x | 首页改版（v1.9.0 UI 预览）、封面体系（黑胶识别/QQ 兜底）、热门/猜你喜欢 |
| v2.0.x | **水墨 UI 改版**（39 项功能基线不许丢）、搜索黑胶封面修复、热门只放原唱+同曲去重 |
| v2.1.0–2.1.10 | 水墨山水重构版（画卷/贴图/羽化）、音源整改接入、搜索优化 |
| v2.1.11–2.1.25 | 点击反馈/墨纸按压、悬浮栏遮挡修复、画卷背景、等距贴右回归 |
| v2.1.26–2.1.35 | 悬浮播放栏终版（黑胶盘+四钮严丝合缝）、搜索框改"太阳"+"飞燕" |
| v2.1.48–2.1.49 | 下载音质修复：无损真的是 27MB FLAC，不是 2.97MB 的 96k |
| v2.1.50–2.1.58 | 开场动画上线并逐帧对齐（时长对齐网易云 4s、音符收尾、跳过位置） |
| v2.1.59–2.1.62 | 首页改版落码、热门改分页、板块顺序调整 |
| v2.1.63 | 字体回归（霞鹜文楷 + 马善政）→ 包体涨到 29.6MB，GitHub「第四版」 |
| v2.1.64–2.1.66 | 下载链路补齐、设置页关于精简、悬浮栏不再压字 |
| v2.1.67–2.1.72 | **息屏/Doze 连播修复**（前台服务→WAKE_LOCK→电池白名单→曲终闹铃），v2.1.68~72 为测版未发 GitHub |
| v2.1.73 | 平板/横屏自适应：开屏按屏高等比、播放页三套版式（手机/平板画心/横屏左右式）→ 归档与 GitHub「第四版 v2.1.73」 |
| v2.1.74–2.1.79 | **桌面歌词**：上线→"开了不显示"死锁修复→墨边纸签→元素化（逐字染色/工具条/三纸色）→去进度条+真实逐字时间（v2.1.79 发 GitHub「第五版」） |
| v2.1.80–2.1.86 | **听歌识曲**：方案 A 闭环→作用域/权限误报修复→采样与静音判据修复→独立 Tab+直接起播→取消/50 条历史/时长四档→严格歌手匹配+其他版本+播放缓存→结果页重做 |
| v2.1.87 | 酷我封面（MVPIC）+ 酷我官方歌词接口（KwLyrics） |
| v2.1.88 | 同曲判定改"核心歌名"（剥 feat./后缀）、平台条数标注、酷我大小写与短标题排序 |
| v2.1.89 | 识曲起播改「歌名+第一位歌手」检索，命中综艺/现场时在同曲录音室版择优 |
| v2.1.90 | 「原唱」D 口径重做（上一版误标"录音室版"满屏），先读指纹多候选取优 |
| v2.1.91 | **识曲改酷狗＋网易双通道互为兜底**（随包 397KB afp 引擎，WebView 生成本地指纹） |

---

## 5. 它原来是怎么干活的（这套流程值得照抄）

### 5.1 构建环境（本机已具备）
| 件 | 路径 | 说明 |
|---|---|---|
| JDK 17 | `C:\Users\17948\AppData\Local\Programs\jdk-17` | `JAVA_HOME` 指这里 |
| Gradle 8.9 | `C:\Users\17948\AppData\Local\Programs\gradle-8.9\bin\gradle.bat` | 工程里**没有 gradlew** |
| Android SDK | `C:\Users\17948\AppData\Local\Android\Sdk`（`local.properties` 已写） | build-tools 34.0.0 |
| Gradle 缓存 | `C:\Users\17948\.gradle`（modules-2 已在，离线也能编） | |

```powershell
$env:JAVA_HOME='C:\Users\17948\AppData\Local\Programs\jdk-17'
cd <工程目录>
& 'C:\Users\17948\AppData\Local\Programs\gradle-8.9\bin\gradle.bat' :app:assembleRelease --no-daemon
# 产物：app\build\outputs\apk\release\app-release.apk
```
> ⚠️ 我这边的沙箱只能写自己的 workspace：默认 `GRADLE_USER_HOME`（`C:\Users\17948\.gradle`）不可写会导致 Gradle 报 `Failed to load native library 'native-platform.dll'`。把 `GRADLE_USER_HOME` 指到可写目录即可启动（已实测 `gradle --version` 通过）。完整 `assembleRelease` 需要工程目录可写（要授权）。

### 5.2 每版固定四步
1. **改码**（一次只做一个维度，避免"整页重写"）
2. **`assembleRelease`** 出包
3. **静态验证 `apk-verify`**：每版一个 `_tmp_build\verify_21XX.py`，产出 `verify_21XX.txt`。固定检查项演化到 20~66 项，典型包括：
   - `badging` 包名 / versionCode / versionName；`gradle` 与 `dex` 与「关于页」**三方版本号一致**
   - `apksigner verify` 通过 + **证书 SHA-256 与历史一致**（`916ad232...`）
   - zip 条目数（183）与无损坏条目；体积量级
   - **"非旧产物"强证据**：`classes2.dex` 大小/CRC 变化、dex 内出现新文案且旧版本文案消失、新色值/类名在包内
   - 权限与组件声明仍在（防止改着改着把 `PlayerService` 丢了）
   - 源码级断言（例如 `drawChevron` 签名已改、`TICK_MS=100L`、`totalVis` 存在）
   - 末尾必有一行 **`缺口：adb devices 恒空`**
4. **写 note**（`note_vXXXX.md`，固定口吻）：本次改了什么 → 为什么/根因 → 实测数据表 → 验证 PASS 表 → **缺口如实写明** → 30 秒自查步骤 → 口径提醒。然后用 Lark API 发 APK（`send_apk_*.txt` 是回执）。

### 5.3 发布与归档
- **GitHub**：`https://github.com/thewonderfulkey/JZ-private-music-`，Release 按「第 N 版」命名（第一版 v1.8.2 / 第二版 / 第三版 v2.0.4 / 第四版 v2.1.73 / 第五版 v2.1.79），每次两个资产：APK + 源码 zip，**发布后下载回来逐字节比 MD5**
- 坑：本机 `git push` 到 github.com 的 TLS 握手持续失败（schannel/openssl 都试过），所以远端提交是走 **GitHub REST API** 生成的，本地仓库 hash 与远端不一致（`note_gh_2173.md` 里写明了），恢复后 `git fetch && git reset --hard origin/main`
- **归档**：`D:\Projects\Private_music` 的 README 有硬规则——每轮只留最新 APK（`01-APK发布/`）、`05-源码归档` 放完整工程 zip、其他资产不动

### 5.4 它验证"看不到的界面"的办法（很实用）
没有真机时，用 **Python + Chromium/WebView 抽帧**：`mock_bar_v*.py` / `mock_rec_page_*.py` 用 HTML 复刻 Compose 版面渲染出图对比；`extract_*_frames.py` 从用户录屏抽帧量像素（例如"底栏识曲标签白字写白纸"是靠像素扫描确认的）。这套"录屏逐秒取证 → 判根因 → 落码 → dex 断言"是它质量的主要来源。

---

## 6. 之前用到的 skill（真实盘点，不含想象）

**结论：技能目录基本是空的，得重装。**

| 位置 | 内容 | 状态 |
|---|---|---|
| `DoubaoWork\skills\` | 空目录（0 个文件） | ❌ |
| `...\new-chat-1\skills-lock.json` | 只登记 1 个：`reverse-engineer-anything`（源 `morluto/rea`，装在 `.agents/skills/reverse-engineer-anything/SKILL.md`） | 登记的目录已空 ❌ |
| `...\new-chat-1\skills_top10\` | 11 个通用工程技能：`handoff`、`tdd`、`triage`、`grilling`/`grill-me`/`grill-with-docs`、`find-skills`、`domain-modeling`、`agent-browser`、`improve-codebase-architecture`、`setup-matt-pocock-skills` | ✅ 文件在 |
| `...\new-chat-1\skills_design_10\` | 10 个设计/前端技能：`ui-ux-pro-max`、`design-taste-frontend`、`frontend-design`、`high-end-visual-design`、`design-mobile-apps`、`prototype`、`web-design-guidelines`、`codebase-design`、`hyperframes-animation`、`hyperframes-creative` | ✅ 文件在（含 app-screens.md 86KB、motion.md 56KB 等大参考） |
| `...\new-chat-1\UI设计Skill\SKILL.md` | **自定义**「音乐 App UI 设计（Compose+SwiftUI）」规范：token 树/组件规范/动效表/"AI 味"黑名单 | ✅ 但方向是暗色 Material，**与最终水墨风相悖**，只能当方法论用 |
| `...\new-chat-1\_rea_v6\` | 逆向工程实战产物：lx-music-source v6/v7 签名算法、`V6/V7签名算法.md`、竞品 dex/APK 样本、`changqing_*` 源脚本 | ✅ 音源侧真正的"外挂"资产 |

**接手建议**：`reverse-engineer-anything` 若还要用就去 `morluto/rea` 重装；`skills_top10` 里的 `handoff` 正好是"交接"，可以直接拿来当模板；设计侧以**现有水墨代码 + UI设计文档**为准，不要再套那套暗色规范。

---

## 7. 已知缺口与风险（不粉饰）

1. **没有真机、没有模拟器**（`adb devices` 从 v2.1.74 到 v2.1.91 全是空）。所有 2.1.74 之后的功能**只有静态验证**。v2.1.75 的"桌面歌词开了不显示"就是三处互等死锁——编译能过、静态检查能过、预览图好看，只有真机才暴露。**任何新功能，没有真机验证就等于没做完。**
2. **版本漂移**：2.1.80→2.1.91 这 12 版没进 Git、没发 GitHub、没进归档；`05-源码归档` 的 zip 还是 v2.1.73。一旦豆包工作目录被清，这 12 版就没了。
3. **网易通道的合规/稳定性**：随包捆绑 `afp.wasm`（网易私有产物，无授权、无 SLA），接口参数（固定 `sessionId`）来自官方浏览器扩展，随时可能失效 → 代码里已做"WebView 起不来就静默只走酷狗"的降级，但**真机上的首次编译耗时/内存/512KB base64 跨桥表现全部未验**。
4. **Shazam 路线未采用**：需 NDK+Rust（本机全无）、GPL-3.0 传染、返回英文元数据会放大变体判定问题（探活报告的结论）。
5. **接口全是时点性的**：酷我/QQ/网易/酷狗三方接口随时变；`vipver` 老客户端参数、酷我三方签名链这类"考古型"依赖最脆。
6. **release 用 debug 签名**：个人分发没问题、可直接覆盖安装，但上不了商店；且**以后必须同签**，换签会导致覆盖安装失败（历史证书 SHA-256 `916ad2328810c691...`）。
7. **包体 29.9MB**，其中字体 25.2MB；想瘦身只能换字体子集化（会掉"正楷"质感，需你拍板）。
8. **代码巨石**：`App.kt` 116KB、`HomeScreen.kt` 96KB 单文件，UI 改动风险高；无组件拆分、无单元测试，验证靠 dex 字符串断言（脆弱，容易"测了个字符串"而不是"测了行为"）。
9. **沙箱/网络限制**（我这侧）：只能写 workspace；GitHub push TLS 曾失败（可改走 API）。

---

## 8. 建议的接手路径

### 第 0 步（今天，先保命）
1. 把 `JZMusicHelperAndroid`（排除 `build/`、`.gradle/`、`.kotlin/`）纳入 git，打 tag `v2.1.91`；把 `_tmp_build` 里的 `verify_*.py` / `note_*.md` / 报告类文档一并入库（它们是"为什么这么做"的唯一记录）
2. 归档：`05-源码归档\JZ音乐助手-安卓源码.zip` 换成 v2.1.91 完整工程；`01-APK发布` 只留 v2.1.91；根目录 APK 换 v2.1.91
3. GitHub 发「第六版 v2.1.91」（含 2.1.80→2.1.91 的变更说明，可直接从设置页"关于"里抄）

### 第 1 步（半天，补上欠了两个月的真机账）
装 v2.1.91 按这张单子过一遍，出问题记现象，别猜：
- [ ] 冷启动开屏：分层山水是否错位、跳过按钮位置、4s 时长
- [ ] 首页：搜索 4 平台都回条数、编辑精选、热门分页、猜你喜欢
- [ ] 搜索→播放：取流速度、换源、无源隐藏、封面是否真图
- [ ] 歌词：有逐字时间（如《暗号》间奏段）整句是否唱完即全亮；纯 LRC 曲子是否只是匀速推开
- [ ] 桌面歌词：回桌面出现、盖在别的应用上、跟播换行、暂停变灰+「‖」、拖动吸边、转屏复位、无权限时设置页写出原因
- [ ] 识曲：6s 快出结果；12s 时网易是否真的兜底（拔掉酷狗结果才看得出）；取消；50 条历史退出保留；"其他版本"与「原唱」小印是否只标对张杰这类
- [ ] 下载：四档音质、无损是不是 27MB 级 FLAC
- [ ] 后台连播：息屏→播完自动下一首（这条历史复发过三次，重点盯）
- [ ] 平板/横屏：播放页三套版式

### 第 2 步（技术债，1~2 天）
- 把 `verify_*.py` 收敛成一个参数化的 `tools/apk_verify.py`（版本号/文案表从外部传），别再每版复制一份
- 给 `App.kt`/`HomeScreen.kt` 做机械拆分（只搬代码不改行为），先降改动风险
- 补一份真正的 `README.md`（现在的 00-README 是目录说明，`06-文档/构建指引.md` 还写着 iOS，误导性很强）

### 第 3 步（功能候选，按投入产出排）
| 候选 | 成本 | 依据 |
|---|---|---|
| 桌面歌词"只在播放页隐藏"口径二选一 | 一句话 | v2.1.75 note 里已写明可改 |
| 歌词整体偏移 ±0.1~2s 调节 | 小 | v2.1.79 缺口：翻版/变速版与原版时间轴会整体偏 |
| 识曲"多段投票"（2~3 段 6s，按候选交集投票） | 小、0 成本 | 探活报告第 1 步建议；-5dB 时酷狗单段会抖 |
| 网易通道真机验证与降级观测 | 中 | 唯一未端到端验证的主链路 |
| 缓存治理（设置里加"清理缓存"、显示占用） | 小 | 现在只缓存当前一首，但 `PlayCache`/`NextTrackCache` 无入口 |
| 字体子集化瘦身（29.9MB → 5MB 级） | 中 | 需你接受"生僻字回退系统字体" |
| 搜索结果骨架屏/封面渐显 | 小 | 现在封面闪空 |

---

## 9. 需要你拍板的三件事

1. **主工作目录定在哪？**
   - A) 继续用 `DoubaoWork\chats\2026-10-22\new-chat-1\`（原样，我只读+需授权写）
   - B) 以 `D:\Projects\Private_music` 为准，我把 v2.1.91 同步进去（需授权写该盘）
   - C) 我在 workspace 建一份 git 仓库接管，稳定后再推回 D 盘/GitHub（推荐：我能自由读写、可编译、可验证）
2. **现在要不要先把 2.1.91 同步到 GitHub「第六版」+ 归档？**（这是防丢，优先级最高）
3. **下一步优先做哪个？** 真机验证清单 / 归档发布 / 某个具体新功能

---

## 附录 A：v2.1.91 交付验证原文（21 项全 PASS）
`_tmp_build\verify_2191.txt`：版本三方一致 149/2.1.91、包名、minSdk 26/target 34、签名证书 SHA-256 一致、`apksigner verify` 通过、zip 无损坏、体积 29,859,137 B、三份网易引擎资产逐字节一致、dex 文案断言、清单含 INTERNET/RECORD_AUDIO、关于页正文无 ASCII 双引号。
唯一缺口：无设备。

## 附录 B：命令速查
```powershell
# 看包信息
& 'C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0\aapt2.exe' dump badging <apk> | Select-String 'package|sdkVersion'
# 签名
& 'C:\Users\17948\AppData\Local\Android\Sdk\build-tools\34.0.0\apksigner.bat' verify --print-certs <apk>
# 包内条目
python -c "import zipfile;z=zipfile.ZipFile(r'<apk>');print(len(z.namelist()), z.testzip())"
# 全量历史 note（按时间）
Get-ChildItem 'C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1' -Recurse -Filter 'note_v*.md'
```

## 附录 C：一句话给下一位接手者
> 这个项目的问题从来不是"功能没做"，而是"没有设备验证 + 最新代码不在版本库里"。先把 2.1.91 收进 git 和 Release，再插上手机跑一遍，比什么新功能都值。

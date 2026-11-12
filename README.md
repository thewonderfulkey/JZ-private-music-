# JZ 音乐助手（JZ Music）

Android 端音乐聚合播放器：四平台检索（酷我 / QQ / 网易云 / 酷狗）、多后端取流兜底、逐字时间歌词、桌面歌词悬浮栏、听歌识曲（酷狗 + 网易双通道按评分融合）。

| 项 | 值 |
|---|---|
| 当前版本 | **v2.1.95**（versionCode 153） |
| 包名 | `com.jz.musichelper` |
| 最低 / 目标 SDK | 26 / 34（compileSdk 34） |
| 技术栈 | Kotlin + Jetpack Compose（Material3）、OkHttp、Coil、MediaPlayer |
| 构建 | Gradle 8.9 + JDK 17（无 gradlew，脚本见 `tools/build.ps1`） |
| 签名 | Android Debug 证书（SHA-256 `916ad232…`，**不可更换**，否则无法覆盖安装） |
| 分发 | 仅本地：`releases/` 只保留最新一版 APK；GitHub 暂不同步 |

## 目录结构

```
Private_music/
├── android/                  Android 工程（可直接构建）
│   ├── app/src/main/         Kotlin 源码 / 资源 / 网易 afp 指纹引擎 assets
│   ├── build.gradle.kts      版本号、依赖、签名配置
│   └── settings.gradle.kts
├── releases/                 交付物：只留最新 APK + 交付说明
├── docs/
│   ├── HANDOFF.md            接手说明（历史、缺口、路线）
│   ├── ARCHITECTURE.md       工程结构与模块职责
│   ├── RECOGNITION.md        听歌识曲：链路、打分模型、测试夹具
│   ├── RELEASE.md            构建 / 验证 / 交付流程
│   ├── design/               UI 设计文档、功能基线、桌面歌词方案
│   ├── recognition/          识曲免费通道探活报告
│   ├── api/                  各平台接口调研与逆向对照
│   └── changelog/            逐版交付说明（v2.1.26 起，note_*.md）
├── tools/
│   ├── build.ps1             一键构建
│   ├── verify/               出包静态验证脚本与历史输出
│   └── probes/               接口探活、规则回归、界面 mock 脚本
├── .build/                   **构建工具链（默认忽略，不入库）**
│   ├── toolchain/jdk-17      JDK 17（自带，不依赖 C 盘安装）
│   ├── toolchain/gradle-8.9  Gradle 8.9（自带）
│   └── gradle-home/          GRADLE_USER_HOME（依赖缓存，离线可编）
├── services/                 本地服务（第三方，非本仓库维护）
│   ├── netease-api/          网易云 API（api-enhanced）
│   ├── lrc-api/              LrcApi 歌词服务
│   └── lddc/                 LDDC 歌词搜索工具
└── archive/                  历史资产：旧 APK、源码 zip、iOS 工程、调研包
```

## 快速开始

构建工具链已放进项目：`.build\toolchain\jdk-17` + `.build\toolchain\gradle-8.9`，
`GRADLE_USER_HOME` 指向 `.build\gradle-home`，**不依赖 C 盘的 JDK/Gradle 安装**（缺失时才回退）。

```powershell
cd D:\Projects\Private_music
pwsh -File .\tools\build.ps1              # 只构建 release
pwsh -File .\tools\build.ps1 -Clean       # 先 clean
pwsh -File .\tools\build.ps1 -Publish     # 构建并复制到 releases\

pwsh -File .\tools\dev.ps1                # 一条命令：构建 → 静态验证 → 模拟器冒烟 → 飞书通知
```

脚本会先打印「项目根目录 / 构建目录 / 工具链 / 缓存 / 版本」，确认路径无误再编译。
产物：`android\app\build\outputs\apk\release\app-release.apk` → `releases\JZ音乐助手-v<版本>.apk`。

自动化细节见 [docs/AUTOMATION.md](docs/AUTOMATION.md)：模拟器冒烟覆盖启动/崩溃/导航/版本，
飞书发到群「音乐软件开发」，失败会带截图与 logcat 留在 `tools\smoke\out\`。

## 核心能力

| 模块 | 说明 |
|---|---|
| 搜索 | 四平台并发 + `SearchRanker` 全局排序；无源歌曲自动隐藏；平台行标出各平台条数 |
| 取流 | 10 个后端多路解析，按音质挑源，失败换源；连续无源自动跳过（上限 3） |
| 播放 | 前台服务 + WAKE_LOCK + Doze 白名单 + 曲终闹铃；三态循环、自动连播、整首缓存、下一首预取 |
| 歌词 | 酷我官方接口 → LDDC（酷狗 KRC / QQ QRC，含逐字时间）；4h 缓存 + 并发去重 |
| 桌面歌词 | 悬浮窗 + 原生 Canvas 自绘；逐字染色、三纸色、五档字号、工具条、拖动吸边 |
| 听歌识曲 | 酷狗指纹（8k PCM）+ 网易 afp（WebView 本地指纹），**按统一评分选更可信的候选** |
| 下载 | 四档音质、下载管理、本地删除 |

## 约定

1. **本目录是唯一主目录**，后续改动只落在这里；GitHub 只在明确要求时同步。
2. `releases/` 只保留最新一版 APK，旧包进 `archive/apk/`。
3. 签名证书沿用历史 debug 证书，**不要换**。
4. 每版必须留下 `docs/changelog/note_v<版本>.md`（改了什么 / 根因 / 实测 / 验证 / 缺口）。
5. 没有真机时，静态验证 + 桌面侧接口实测是下限，**不能当"已验证"**。

## 文档索引

- 接手先读：[docs/HANDOFF.md](docs/HANDOFF.md)
- 改代码前读：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- 改识曲读：[docs/RECOGNITION.md](docs/RECOGNITION.md)
- 出包发版读：[docs/RELEASE.md](docs/RELEASE.md)
- 自动化与通知：[docs/AUTOMATION.md](docs/AUTOMATION.md)



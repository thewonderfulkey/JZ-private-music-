# 构建 · 验证 · 交付

## 1. 环境

| 件 | 路径 | 备注 |
|---|---|---|
| JDK 17 | `C:\Users\17948\AppData\Local\Programs\jdk-17` | `build.ps1` 自动设置 `JAVA_HOME` |
| Gradle 8.9 | `C:\Users\17948\AppData\Local\Programs\gradle-8.9\bin\gradle.bat` | 工程**没有** gradlew |
| Android SDK | `C:\Users\17948\AppData\Local\Android\Sdk` | build-tools 34.0.0；`android/local.properties` 写 `sdk.dir` |

沙箱注意：若 `GRADLE_USER_HOME`（默认 `~/.gradle`）不可写，Gradle 会报
`Failed to load native library 'native-platform.dll'`——把 `GRADLE_USER_HOME` 指到可写目录，或用完整权限运行。

## 2. 出包

```powershell
pwsh -File .\tools\build.ps1 -Publish
# → releases\JZ音乐助手-v2.1.92.apk
```

改版本号只改一处：`android/app/build.gradle.kts` 的 `versionCode` / `versionName`，
然后同步设置页「关于」的标题与「本版更新」正文（验证脚本会查两处是否一致）。

## 3. 出包后必做的静态验证

工具：`tools/verify/`（`verify_2191.py` 是当前模板，抄一份改成新版本号）。

```powershell
python tools\verify\verify_2192.py
```

固定项（不能少）：

| 组 | 检查 |
|---|---|
| 版本 | `aapt2 dump badging` → 包名 / versionCode / versionName；与 `build.gradle.kts`、设置页「关于」**三方一致** |
| 签名 | `apksigner verify --print-certs` → SHA-256 必须是 `916ad232…`（换签 = 无法覆盖安装） |
| 完整性 | zip 条目数（183 上下）、`testzip()` 无坏条目、体积量级 29~30 MB |
| 非旧产物 | `classes2.dex` 大小/CRC 变化；dex 内含新版本号与新文案、**不含**上一版本文案 |
| 组件 | `MainActivity`、`PlayerService(mediaPlayback)`、`TrackEndReceiver` 声明仍在 |
| 权限 | `INTERNET`、`RECORD_AUDIO`、`SYSTEM_ALERT_WINDOW`、`FOREGROUND_SERVICE*`、`WAKE_LOCK`、`SCHEDULE_EXACT_ALARM` |
| 源码级断言 | 本轮改动的关键常量/函数签名确实在源码里（例如 `TICK_MS=100L`、`FAST_PATH=false`） |
| 资产 | 网易三件套（`recognizer.html` / `afp_wasm_b64.js` / `sandbox.bundle.js`）与源码逐字节一致 |

**必须写清缺口**：本机 `adb devices` 是否为空、哪些行为只在真机上才能验。不要把静态 PASS 说成"已验证"。

## 4. 交付

1. `releases/` 只保留最新 APK：`JZ音乐助手-v<版本>.apk`（发布到 GitHub 时资产名改成 `JZ-Music-v<版本>.apk`），
   旧的移到 `archive/apk/`；Windows 单文件 exe 走 `releases\windows\`，发布时改名 `JZ-Music-v<版本>-windows-x64.exe`；
2. 写 `docs/changelog/note_v<版本>.md`，固定六段：
   - 这版改了什么（用户视角一句话）
   - 根因 / 为什么这么改（能贴实测数据就贴）
   - 实现要点（动了哪几个文件、关键参数）
   - 验证结果（PASS 表 + 明确缺口）
   - 30 秒自查步骤
   - 口径提醒（还有哪些"一句话就能改"的取舍没做）
3. `README.md` 的「下载」段落版本号与文件名、`CHANGELOG.md` 追加一条；
4. 本地 git 提交（GitHub 仅在明确要求时同步）。

## 5. 提交信息规范

```
v2.1.92：<一句话主题>

- 识曲：双通道候选统一打分择优（酷狗/网易），去掉"酷狗有结果就不看网易"
- 新增 network/RecognizeScore.kt；App 侧改为 fuse 后取 top1
- 验证：静态 28 项 PASS；缺口：无真机
```

## 6. 常见坑

| 现象 | 原因 / 处理 |
|---|---|
| `mergeDexRelease` 报文件被占用 | 停 Gradle daemon（`gradle --stop`）后重试 |
| 安装提示"签名不一致" | 换了签名证书；只能用历史 debug 证书 |
| 关于页版本与 APK 不一致 | 只改了一处 versionName |
| 构建成功但装上是旧包 | `app/build/outputs` 里有多个产物，取最新的 `app-release.apk` |
| 桌面歌词不出现 | 先看设置页「桌面歌词」状态行给出的原因（权限/系统拦截） |

## 7. 发布到 GitHub

`powershell
cd D:\Projects\Private_music
git -c http.proxy= -c https.proxy= push origin main
git -c http.proxy= -c https.proxy= push origin v<版本>
python tools\release_github.py --tag v<版本> --name "第 N 版 v<版本>" 
    --body-file .build\release_body.md --asset releases\JZ-Music-v<版本>.apk --asset releases\windows\JZ-Music-v<版本>-windows-x64.exe
`

> 本机 git 全局配了 http.proxy=http://127.0.0.1:7890，代理没开时所有 github 操作都会报
> "Failed to connect to 127.0.0.1:7890"（之前一直以为是 TLS 问题）。命令里带 -c http.proxy= 绕过即可。
> 凭据在 Windows 凭据管理器（git credential manager），git credential fill 可取到 PAT 供 API 用。

### Release 里只放三样东西（固定口径）

1. **Android APK**：`JZ-Music-v<版本>.apk`
2. **Windows 程序**：`JZ-Music-v<版本>-windows-x64.exe`（**单个 exe、非安装器**，双击即用）
3. **源码**：GitHub 在 Release 页面自动生成的 `Source code (zip / tar.gz)`，不用自己传

不要上传的东西（以前传过，已废弃）：

| 不上传 | 为什么 |
|---|---|
| `JZ Music Setup-<版本>.exe`（安装器） | 用户装个播放器不该先跑安装器；单文件 exe 已经够用，两套分发只会让人选错 |
| `...-portable.exe`（带 portable 后缀的那份） | 就是第 2 条那个程序，名字里不需要 `portable`，多一个词反而像"另一个版本" |
| `*-android-source-*.zip`（自己打的源码包） | GitHub 自动生成 Source code，重复传一份没有意义，还会和 tag 不一致 |

- 仓库**不存 exe**：单个 138–145 MB，超过 GitHub 单文件 100 MB 上限（`.gitignore` 里
  `releases/windows/*.exe` 已挡），exe 只作为 Release 资产上传。
- 版本号与 Android 同源（`android/app/build.gradle.kts` 的 `versionName`），所以同一 Release 里
  apk 与 exe 版本号必然一致。
- **tag 必须包含这一版的实际代码**：Release 的 Source code 是从 tag 出的快照，
  tag 落后于 `main` 时源码包里就会缺东西（例如少了 `desktop/`）。发版时先确认 `git rev-parse v<版本>`
  指向当前要发布的提交；需要改就用 `git tag -f` + `git push -f origin v<版本>`。

上传仍用 `tools/release_github.py`，`--asset` 可给多次；同名资产会先删再传，**整段命令可重复执行**（幂等）。
上传前想清掉旧资产（比如上面三种废弃资产），直接 `DELETE /repos/{owner}/{repo}/releases/assets/{id}`。

两条实测经验：

1. `release_github.py` 只负责"建 Release / 传资产"，**不会改已有 Release 的标题和正文**；
   正文要改，单独 `PATCH /repos/{owner}/{repo}/releases/{id}`（`body` 字段）。
2. 脚本用 urllib，会读 Windows 注册表里的系统代理（本机是那个没开的 127.0.0.1:7890），
   表现为连不上/超时。在同一个进程里先设 `$env:no_proxy='*'` 再跑即可；145 MB 上传约 15–20 分钟，别中途打断。


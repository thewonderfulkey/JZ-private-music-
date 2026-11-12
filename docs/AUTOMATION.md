# 自动化：构建 → 验证 → 冒烟 → 飞书通知

一条命令跑完，失败会停在失败的那一步，并把截图 / logcat 留在磁盘上。

```powershell
cd D:\Projects\Private_music
pwsh -File .\tools\dev.ps1                       # 全流程（构建 + 静态验证 + 模拟器冒烟 + 飞书）
pwsh -File .\tools\dev.ps1 -SkipSmoke            # 只构建 + 静态验证
pwsh -File .\tools\dev.ps1 -SkipNotify           # 不发飞书（本地调代码时用）
pwsh -File .\tools\dev.ps1 -Note "修了识曲取消"   # 追加一句到飞书消息里
pwsh -File .\tools\dev.ps1 -Clean                # 先 clean 再构建
```

退出码：`0` 全通过；`1` 构建 / 静态验证 / 冒烟任一失败（失败也会发飞书，标题带 ❌）。

## 1. 三个阶段各自做什么

| 阶段 | 脚本 | 内容 |
|---|---|---|
| 构建 | `tools/build.ps1` | 用项目内 JDK17 + Gradle 8.9 编 release，产物同时复制到 `releases/` |
| 静态验证 | `tools/verify/verify_<版本>.py` | 版本三方一致、签名证书、zip 完整性、资产一致、dex 文案、源码断言 |
| 冒烟 | `tools/smoke/smoke.ps1` | 模拟器装包启动、查崩溃/ANR、六格导航、识曲页、关于页版本、全程截图 |

## 2. 模拟器冒烟（tools/smoke/）

首次准备（约 1.5GB，装到 Android SDK，只需一次）：

```powershell
pwsh -File .\tools\smoke\install-emulator.ps1
```

日常：

```powershell
pwsh -File .\tools\smoke\smoke.ps1                    # 无设备则自动起模拟器，测完关掉
pwsh -File .\tools\smoke\smoke.ps1 -KeepEmulator      # 测完不关（下一步继续用手动看）
pwsh -File .\tools\smoke\smoke.ps1 -Reuse             # 复用已在运行的设备
pwsh -File .\tools\smoke\smoke.ps1 -Apk releases\JZ音乐助手-v2.1.92.apk
```

- AVD 名字 `jz_smoke`，放在 `.build\avd`（不污染 C 盘），4 核 / API 34 / 1080×2340；
- 用 WHPX 加速（`Windows Hypervisor Platform accelerator is operational`），冷启动约 10~20 秒（本机实测）；
- 输出：`tools\smoke\out\v<版本>\` —— `01-home.png` `02-recognize.png` `03-settings.png`、各页 uiautomator XML、`smoke.log`、`logcat-tail.txt`。

**当前断言（10 项）**：设备启动、安装成功、设备版本与构建一致、Activity 启动、无 FATAL、无 ANR、进程存活、底部六格导航、识曲页渲染、关于页版本正确。

**能覆盖**：启动崩溃、白屏/黑屏、页面渲染缺失、导航错乱、版本号漏同步、安装/签名问题。
**不能覆盖**：麦克风采集与识曲链路（模拟器没有真实声源）、息屏/Doze 行为、桌面歌词悬浮窗、真实网络波动下的取流表现。
这几项仍需要在真机上点一遍（见 `docs/HANDOFF.md` 的验收清单）。

## 3. 飞书通知（tools/notify/lark.py）

配置在 `.lark/config.json`（**已 gitignore，含 webhook 地址，不要提交**）：

- 已配好自定义机器人 webhook → 发**文本**消息到群「音乐软件开发」；
- 想连 APK 文件一起发：填 `app_id` / `app_secret`（飞书自建应用，开通 `im:message`、`im:resource`，
  并把机器人拉进群）。脚本会自动先传文件再补一条文字说明；没有凭据时只发文字。

手动发：

```powershell
python tools\notify\lark.py --title "v2.1.93 已出包" --body "改了什么…" --apk releases\JZ音乐助手-v2.1.93.apk
```

## 4. 我（Agent）的标准动作

1. 改代码 → `tools/dev.ps1 -SkipNotify`；
2. 失败就读 `tools\smoke\out\v<版本>\` 里的截图和 logcat，修，再跑；
3. 直到 `ALL PASS` 再 `tools/dev.ps1`（这次带通知）把结果和包发群里；
4. 写 `docs/changelog/note_v<版本>.md`，提交。

## 5. 新增一个冒烟断言

在 `tools/smoke/smoke.ps1` 里加：

```powershell
if (TapText '收藏') {
    Start-Sleep -Seconds 2
    $xml = UiDump '04-favorites'
    $r = (& $python $uidump --file $xml --has '我喜欢的音乐' | Out-String).Trim()
    Step '收藏页渲染' ($r -match 'FOUND') $r
}
```

`uidump.py` 支持 `--has`（存在即通过）/ `--any`（多个任一）/ `--center`（返回点击坐标）/ `--list`（列当前屏所有文字）。

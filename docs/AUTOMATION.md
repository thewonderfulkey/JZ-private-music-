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

**当前断言（18 项）**：设备启动、安装成功、设备版本与构建一致、Activity 启动、无 FATAL、无 ANR、进程存活、底部六格导航、识曲页渲染、关于页版本正确，以及**识曲两组各 4 项**（出结果 / 命中歌名歌手 / 通道结论 / 结果卡显示）。

**识曲怎么在模拟器里测**（模拟器没有真实声源）：

- 冒烟用的是 `smoke` 变体（`app/build/outputs/apk/smoke/app-smoke.apk`）——与 release 同源同签，
  只多一个编译期开关 `RECOG_TEST_HOOK=true` 和 `assets/fixtures/` 两段 12s/8k PCM；
- 触发：`adb shell am start -n com.jz.musichelper/.MainActivity --es jz_test_pcm qingtian_8k.pcm`；
- 结果同时写进 logcat（tag `JZ_TEST`）与界面结果卡，冒烟脚本两边都断言；
- 正式包 `RECOG_TEST_HOOK=false`：`jz_test_pcm` 字符串与 fixtures 资产都不会进 release 包（验证脚本会查）。

样本由 `tools/smoke/make_fixtures.py` 生成（妖狐酷我直链 → miniaudio 解码 → 8k 单声道），
当前两段：`qingtian_8k.pcm`（晴天/周杰伦）、`womendouyiyang_8k.pcm`（我们都一样/张杰）。

**能覆盖**：启动崩溃、白屏/黑屏、页面渲染缺失、导航错乱、版本号漏同步、安装/签名问题、**识曲双通道与打分结论**。
**不能覆盖**：真实麦克风采集（模拟器无真实声源，用注入替代）、息屏/Doze、桌面歌词悬浮窗、真实网络抖动下的取流。
这几项仍需要在真机上点一遍（见 `docs/HANDOFF.md` 的验收清单）。

## 3. 飞书通知（tools/notify/lark.py）

配置在 `.lark/config.json`（**已 gitignore，含 webhook 与 app secret，不要提交**）：

- 自定义机器人 webhook → 发**文本**消息到群「音乐软件开发」（已验证）；
- 自建应用（`app_id` / `app_secret`）→ 先上传 APK 作为文件消息，再补一条文字说明（已验证：
  `bot in chat: code 0` + `file message: om_…`）。

首次接入只有一步需要人工：**机器人必须由人在客户端拉进群**（群设置 → 群机器人 → 添加机器人），
飞书不允许机器人把自己加进群（`232011`）。之后脚本每次发文件前会 best-effort 校验一次成员关系，已在群则跳过。

所需权限：`im:resource`（上传）、`im:message` 或 `im:message:send_as_bot`（发消息）、
`im:chat.members:write_only`（成员校验/加人）；**应用能力里要启用「机器人」**，且每次改能力/权限都要重新发版。

手动发：

```powershell
# 成功：群里只收到一条 APK（文件名可自定义，带版本与主题）
python tools\notify\lark.py --title "v2.1.93 已出包" ^
    --apk releases\JZ音乐助手-v2.1.93.apk --name "JZ音乐助手-v2.1.93-识曲双通道打分.apk"

# 失败：一条红色卡片
python tools\notify\lark.py --title "v2.1.93 冒烟失败" --body "…" --fail

# 想在文件之后补一条说明卡（默认不发）
python tools\notify\lark.py --title "…" --apk … --note
```

**为什么不是"一条带说明的文件"**：飞书的文件消息不能带正文，消息卡片也不支持 `file` 块
（实测返回 `11310 unsupported type of block`）。所以「一次交付一条消息」的落地方式是：
**只发 APK，文件名带版本 + 主题**；说明留在 `docs/changelog/`，失败才发卡片。

凭据存放：`app_secret` 优先取环境变量 `LARK_APP_SECRET`（`setx` 已写入用户环境），
其次 `.lark/secret.env`（gitignore），最后才是 `.lark/config.json`（现已清空 secret）。

### 踩过的三个错误码（按这个顺序排查）

| 错误码 / 现象 | 含义 | 处理 |
|---|---|---|
| `99991672` …`im:resource` | 缺上传文件的权限 | 开放平台 → 权限管理 → 开通 `im:resource`（或 `im:resource:upload`） |
| `234007 App does not enable bot feature` | **应用没启用机器人能力**（发文件时） | 应用能力 → 添加应用能力 → **机器人**；然后**重新创建版本并发布**（加能力必须发新版才生效） |
| `232025 Bot ability is not activated` | 同上，但发生在**拉机器人进群**时 | 同上 |
| `99991672` …`im:message` / `im:message:send_as_bot` | 缺"以机器人身份发消息"的权限 | 权限管理 → 开通 `im:message` 或 `im:message:send_as_bot` |
| 群里「添加机器人」搜不到应用 | 群机器人搜索只搜机器人广场，自建应用不在广场 | 飞书搜索框搜应用名 → 打开应用 → 添加到群；或群设置 → 群机器人 → 添加机器人 → 翻「自建应用」分组 |
| `232011 Operator can NOT be out of the chat` | 机器人不在群里，且**飞书不允许机器人把自己拉进群** | 必须由人在客户端添加：群设置 → 群机器人 → 添加机器人 → 选应用（或飞书搜索应用名 → 详情页「添加到群聊」） |
| `230002 Bot/User can NOT be out of the chat` | 同上（发消息时） | 同上 |
| `99991672` …`im:chat.members:write_only` | 想用 API 把机器人拉进群 | 开通 `im:chat` 或 `im:chat.members:write_only`，脚本会自动尝试拉群 |

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

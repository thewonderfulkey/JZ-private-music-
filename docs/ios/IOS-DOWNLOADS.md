# iOS 下载层（P2）：选档 → 换源 → 体积校验 → 落盘

> 状态：**已落码、CI 编译通过、纯逻辑断言通过**（2026-11-16）。**没有在真机上验证过"文件能不能完整下下来"**——这一步要装机试，§6 有 5 步清单。
> 上一环：[IOS-PLAYBACK.md](IOS-PLAYBACK.md)（播放）、[IOS-LYRICS.md](IOS-LYRICS.md)（歌词）。下一环：P3 识曲。

---

## 1 这一层做了什么

```
播放页「下载」/ 搜索结果长按「下载…」/ 资料库长按
        │
        ▼
  DownloadSheet（挂在 RootTabView 的唯一弹层）
        │ ① 选档（无损 / 高品 / 标准，默认跟着播放音质）
        ▼
  DownloadFlow.choose(档位)
        │ ② DownloadResolver.plan —— 三级换源链（本平台 → 跨平台补位 → 通用后端）
        ▼
  offer（核实就是该档 / 只有更低一档 + 明确文案）
        │ ③ 用户点「开始下载」
        ▼
  DownloadManager（后台 URLSession + 进度 + 完成通知 + 95% 体积校验）
        │
        ▼
  Documents/Music/<歌手> - <歌名> [平台/后端].<真实容器>
        （文件 App → 我的 iPhone → JZ 音乐 可见）
```

| 文件 | 职责 |
|---|---|
| [DownloadGuard.swift](ios/JZMusicHelper/Services/DownloadGuard.swift) | **纯函数**：95% 体积判定、缺口比例、仅 Wi-Fi 拒下、档位顺序、体积文案。不碰 UIKit，CI 能直接断言 |
| [DownloadFlow.swift](ios/JZMusicHelper/Services/DownloadFlow.swift) | `@Observable` 编排：选档 → 解析 → 确认；`NetworkStatus`（NWPathMonitor 缓存 Wi-Fi 判定） |
| [DownloadSheet.swift](ios/JZMusicHelper/Views/DownloadSheet.swift) | 下载面板（三段式：选档 / 核对中 / 确认） |
| [DownloadManager.swift](ios/JZMusicHelper/Services/DownloadManager.swift) | 后台下载、进度、落盘、95% 校验、坏文件删除、去重、完成通知 |
| [DownloadItem.swift](ios/JZMusicHelper/Models/DownloadItem.swift) | 记录模型（新增 `expectedBytes`，旧 records 缺这个键也能解码） |

**入口只有一处弹层**：`RootTabView` 上的 `.sheet(isPresented: downloadFlow.isPresented)`。播放页、搜索结果、资料库都只是调 `downloadFlow.start(song:want:)`，不各自弹 sheet——否则同一时刻会出现两个音质选择。

---

## 2 与 Android 的口径对照

| 能力 | Android | iOS | 是否等价 |
|---|---|---|---|
| 三档音质 | 标准 / 高品 / 无损，选档后解析 | 同，档位文案同 | ✅ |
| 取源 | `DownloadResolver`：本平台 → 跨平台补位 → 通用后端 | 同（`DownloadResolver.plan`，复用播放层的三级链） | ✅ |
| 降级处理 | 拿不到目标档就取最高可得档，并告知 | 同；**确认页标题直接写"只有高品 320k"**，按钮上方不留悬念 | ✅（更显式） |
| 体积校验 | 实际 ≥ 预期 95% 才入库 | `DownloadGuard.isComplete`，同 95%；不达标**删文件**并标失败 | ✅ |
| 后台下载 | 前台服务 + 通知 | `URLSessionConfiguration.background` + App Delegate 回调 + 本地通知 | ✅ |
| 文件名 | `歌手 - 歌名 [平台/后端].<真实容器>` | 同；容器来自取流阶段的头部探测，杜绝 `.flac` 里装 mp3 | ✅ |
| 仅 Wi-Fi | 有开关 | 有开关，**在开始下载前拦**并给一句人话 | ✅ |
| 重复入库 | 同曲不重复排 | 同曲 `activeItem` 命中就直接复用，不排第二条 | ✅ |
| 断点续传 | 无 | 无（后台会话由系统重试） | 等价 |
| 本地文件播放 | 下完可用本地文件播 | **未做**：下载列表点一行仍走在线取流（P5 再补 `AVPlayerItem(fileURLWithPath:)` 分支） | 部分 |

---

## 3 已知的取舍（都写进代码注释了）

1. **解析一次只解一档**：`DownloadResolver.plan(want:)` 是「按用户选的档位去换源」，不是「一次算出三档分别可不可得」。好处是省 30 秒；代价是选完无损才知道有没有无损——所以确认页必须把"只有 X"写在最显眼处。
2. **预期体积可能为 0**：部分音源忽略 Range 请求也不回 Content-Length，此时 `expectedBytes = nil`，`isComplete` 直接放行。宁可信其完整，也不要凭 0 误删好文件。
3. **校验失败不自动重试**：坏文件删掉、标失败，用户可在下载页左滑「重试」。自动重试会在弱网下把流量烧光。
4. **Wi-Fi 判定按"最近一次路径"**：`NWPathMonitor` 还没回调时默认按 Wi-Fi 放行，避免一进 App 就把下载判死。
5. **通知权限是可选**：拒绝也不影响下载（`JZMusicHelperApp.init` 里请求）。

---

## 4 这一层被验证到什么程度

| 验证 | 手段 | 结果 |
|---|---|---|
| 95% / 仅 Wi-Fi / 档位顺序 / 体积文案 | CI `logic-tests`（`swiftc` 编 `ios/SelfTest/main.swift` 直接跑） | ✅ 13 条断言（见 `section("下载校验…")`） |
| 整包能否编译 | CI `build-ipa`（`xcodebuild`，iOS 17 target，device arm64） | 见本轮 CI |
| **文件能不能真下下来** | ❌ 本机是 Windows，无模拟器/设备 | **未验证**，见 §6 |
| 断网 / 切后台 / 杀进程 | ❌ 同上 | **未验证**，见 §6 |

> 说法边界：✅ 只覆盖"逻辑对 + 类型对"，不覆盖"真机上跑起来对"。不要在装机之前说"下载做好了"。

---

## 5 踩到的坑（已修，记下来）

| 坑 | 现象 | 处理 |
|---|---|---|
| `DownloadItem` 加非可选字段 | 旧的 `downloads.json` 里没有这个键，`JSONDecoder` 直接抛错，下载页整页空白 | `expectedBytes` 用**可选**类型（合成解码对可选走 `decodeIfPresent`） |
| `URLSession` 进度回调给 `totalBytesExpectedToWrite = -1` | 进度条分母被写成 -1，`progressText` 变 `--%` 且体积消失 | 只在 `> 0` 时覆盖 `totalBytes` |
| 两个 Sheet 同时可达 | 播放页自己弹下载面板 + 外壳也弹，会出现两层音质选择 | 只有 `RootTabView` 一处 `.sheet`，子视图一律只调 `DownloadFlow` |
| `SettingsStore` 被实例化两份 | 设置页关掉「仅 Wi-Fi」，下载层读的是另一份，开关看起来没生效 | `SettingsStore.shared`，App 与 Service 层共用同一实例 |

---

## 6 装到手机上要试的 5 件事（P2 验收）

1. 播放页点右侧「下载」→ 选**无损** → 面板应显示"可以下载 无损 FLAC"或"只有高品 320k"（**不许**两句话都没有就开下）。
2. 确认后回下载页：应出现「正在进行」这一组，进度百分比在走。
3. 下完 → 文件 App → 我的 iPhone → JZ 音乐 → Music：文件在，后缀与面板上的"实测容器"一致。
4. 下到一半断网 → 条目应转「失败」并给出原因，恢复网络后左滑「重试」能续上。
5. 设置里打开「仅 Wi-Fi」→ 关 Wi-Fi 用蜂窝再下 → 应被拦下并提示，**不能悄悄开下**。

任何一条不符，把现象告我，我按这条链定位（选档入口 / 换源 / 落盘校验 / 开关）。

---

## 7 下一步

| 顺序 | 内容 | 为什么是它 |
|---|---|---|
| **下一步** | P3 识曲：指纹通道（酷狗 + 网易）+ 打分 + 结果页 + 其他版本 | 五个 Tab 里最后一页还是"通道没接上"的占位 |
| 之后 | 下载列表点行播本地文件（`AVPlayerItem(url: fileURL)`） | 现在下完仍走在线取流，离线时点了没声音 |
| 之后 | 编辑精选 / 热门榜单的真数据源（歌单池） | 发现页这两块还是静态分类占位 |
| 之后 | P4 系统面（Live Activity / Widget / App Intents） | 自签版能直接用的 iOS 独占体验 |

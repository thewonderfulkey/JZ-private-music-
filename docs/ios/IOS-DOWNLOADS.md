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
| 本地文件播放 | 下完可用本地文件播 | ✅ 播放引擎 `loadCurrent` 优先播本地文件（`DownloadManager.localFileURL`），离线可放，见 [IOS-CLOSEOUT.md](IOS-CLOSEOUT.md) §2 | ✅ |

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
| 95% / 仅 Wi-Fi / 档位顺序 / 体积文案 | CI `logic-tests`（`swiftc` 编 `ios/SelfTest/main.swift` 直接跑） | ✅ 13 条断言全绿（`section("下载校验…")`） |
| 整包能否编译 | CI `build-ipa`（`xcodebuild`，iOS 17 target，device arm64） | ✅ BUILD SUCCEEDED，run [#43820907204](https://github.com/thewonderfulkey/JZ-private-music-/actions/runs/43820907204)；`JZ-Music-v2.1.95-ios-unsigned.ipa`（约 1.0 MB）已发飞书群 |
| **文件能不能真下下来** | ❌ 本机是 Windows，无模拟器/设备 | **未验证**，见 §6 |
| 断网 / 切后台 / 杀进程 | ❌ 同上 | **未验证**，见 §6 |

> 说法边界：✅ 只覆盖"逻辑对 + 类型对"，不覆盖"真机上跑起来对"。不要在装机之前说"下载做好了"。
> 本轮踩到一个编译错并已修：`View` 上没有 `.onDismiss` 修饰符（那是 sheet 的 `onDismiss:` 参数），见 §5。

---

## 5 踩到的坑（已修，记下来）

| 坑 | 现象 | 处理 |
|---|---|---|
| `DownloadItem` 加非可选字段 | 旧的 `downloads.json` 里没有这个键，`JSONDecoder` 直接抛错，下载页整页空白 | `expectedBytes` 用**可选**类型（合成解码对可选走 `decodeIfPresent`） |
| `URLSession` 进度回调给 `totalBytesExpectedToWrite = -1` | 进度条分母被写成 -1，`progressText` 变 `--%` 且体积消失 | 只在 `> 0` 时覆盖 `totalBytes` |
| 两个 Sheet 同时可达 | 播放页自己弹下载面板 + 外壳也弹，会出现两层音质选择 | 只有 `RootTabView` 一处 `.sheet`，子视图一律只调 `DownloadFlow` |
| `SettingsStore` 被实例化两份 | 设置页关掉「仅 Wi-Fi」，下载层读的是另一份，开关看起来没生效 | `SettingsStore.shared`，App 与 Service 层共用同一实例 |
| `View` 上写 `.onDismiss { }` | `xcodebuild` 报 `value of type 'some View' has no member 'onDismiss'`（iOS 17 SDK 没有这个 View 修饰符） | 改用 `sheet(isPresented:onDismiss:content:)` 的 `onDismiss:` 参数，回调里再 `flow.dismiss()` |

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
| 已完成 | P3 识曲双通道、P4 系统面、P5 打磨、收尾四项 | 见 [IOS-RELEASE.md](IOS-RELEASE.md) 的分期总表 |
| 之后 | 下载列表点行播本地文件（`AVPlayerItem(url: fileURL)`） | 现在下完仍走在线取流，离线时点了没声音 |
| 之后 | 编辑精选 / 热门榜单的真数据源（歌单池） | 发现页这两块还是静态分类占位 |
| 之后 | P4 系统面（Live Activity / Widget / App Intents） | 自签版能直接用的 iOS 独占体验 |

---

## 8 把歌曲信息写回音频文件（第 48/49 轮，2026-11-22）

老板两轮原话（IPA 交付群 00:17 一张「文件 › JZ 音乐 › Download」截屏：`Cover 642 · Lyrics 638 · Music 662`）：

> ① 我已经把导入的歌曲所有封面都替换内置了，那么本地的后台文件封面并没有和前端内置的对齐，我希望对齐，先把封面和歌曲对齐，自动把内置的封面下载下来替换原有文件中该歌曲的封面，如果该歌曲后台文件中没有封面那么直接添加进去并建联就行了。
>
> ② 那现在是否可以同时把封面、歌名、歌手、专辑还有音频信息一起通过这个按钮写入音频文件，直接改动音频本地文件的信息。

### 8.1 为什么会对不上（两条路各走各的）

| 面 | 真实来源 | 什么时候写 |
|---|---|---|
| **前端显示** | 旁车 `Cover/<基名>.jpg`（`SongArtwork.load` 先读它，没有才走 `picURL` / `CoverResolver` 兜底） | 导入时或补料取到图时 |
| **音频文件标签** | mp3 的 ID3 帧（TIT2/TPE1/TALB/APIC/USLT）/ m4a 的 metadata | **只在下载完成 / 补料取到图那一次** |

老板后来在「编辑歌曲信息」里换的封面、改的歌名/歌手/专辑，走的只有**旁车 + App 内记录**
（`MetadataCoverImage.writeSidecar` + `MetadataWriter.apply`）——文件里的标签还是导入时那一套，
或者压根没有。截屏那三个目录的数字也说明了同一件事：`Cover 642` ≠ `Music 662`，
有 20 首连旁车都没有（它们在界面上是 `picURL` 的在线图）。

### 8.2 这一版做了什么

入口：下载页右上「⋯」→ **把歌曲信息写进音频文件（封面/歌名/歌手/专辑）**（一次性），
另加一条自动路径：编辑页保存 → 立刻写回这一首。

每首按「前端正在显示的那一套」为准，两步一起做完：

1. **建联（旁车）**：没有 `Cover/<基名>.jpg` → 用 `song.picURL`，地址也没有就走
   `CoverResolver.coverURLIgnoringOriginal`（酷我 rid → QQ 严格匹配 → iTunes），下到就写旁车；
2. **写回（内嵌）**：歌名 / 歌手 / 专辑 / 时长 / 封面 / 歌词 写进音频文件本身 ——
   mp3 只替换那几帧（`DownloadCompanion.ID3Tags`），m4a 换同名 metadata（passthrough 导出）。

> 不写"码率 / 格式"：那不是标签，是从字节算出来的属性。硬塞进备注字段只会在播放器里
> 多出一行看不懂的字；下载页那一行（`actualNote`）仍然负责显示它。时长（TLEN）是标准帧，写了。

硬约束（都写进代码注释）：

| 约束 | 做法 | 为什么 |
|---|---|---|
| 不许顺手删别的帧 | 只替换 TIT2/TPE1/TALB/TLEN/APIC/USLT，其余帧**原样搬** | 别人写的年份/流派/音轨号、以及内嵌歌词都要留着 |
| 音频体一个字节不改 | 新标签 + 原文件标签之后的原始字节 | "能放"这件事不能赌 |
| 编码不乱写 | v2.4 用 UTF-8；v2.3 纯 ASCII 用 latin1，**含中文一律 UTF-16 + BOM** | v2.3 标准里没有 UTF-8，硬写就是方块/乱码 |
| 解析不了就不碰 | v2.2 / unsynchronisation / 扩展头 / footer / 帧长度越界 → 返回 `nil`，原文件保持 | 宁可不写，也不写坏能放的歌 |
| 失败保留原文件 | 先写 `.tags-<uuid>` 临时文件，体积/ID3 头校验通过才 `replaceItemAt` | 中途被杀也不会留半截音频 |
| 不重复写 | 现有字段与目标一致 → 跳过（`already`） | 662 首能省多少 IO 省多少 |
| 空值 = 不动 | 传空字符串表示"这一项别改"，不是"清空" | 清空比缺字段更难恢复 |

结果分六项报给老板，一项都不吞：**改写 / 新增 / 本来一致 / 没信息可写 / 格式不支持 / 失败**。
进度条（`正在写回歌曲信息 12/662`）在列表顶部，可「停止」；停止只停还没开始的，在飞的那几首会做完。

另外：补料（`fillCompanion` 第 ⑤ 步）也改成先走同一条 `writeTags`（保留不认识的帧），
只有它判"处理不了"时才退回老的整条重建 —— 否则老板刚写回的年份/流派会被下一次补料抹掉。

### 8.3 验证到什么程度

| 验证 | 手段 | 结果 |
|---|---|---|
| 字段读得回来、别的帧不丢、音频体不变、v2.3 中文走 UTF-16 | `ios/SelfTest/main.swift` 新增一节（33 条） | ✅ 本机 swiftc 6.0.3（WSL）实跑 33/33；CI `logic-tests` 同样编译并跑 |
| pbxproj / 界面卫生 | `tools/ios/check_pbxproj.py`、`check_ui_hygiene.py` | ✅ 通过 |
| m4a 分支（AVFoundation 导出） | CI `build-ipa` 编译 + 真机 | ⚠️ 编译由 CI 保证；**真机行为待老板验证** |
| 662 首实际写回 | 老板装机点一次 | ⏳ 待验证（预计 1–3 分钟，留在 App 前台） |

### 8.4 第 50 轮：补上 FLAC（老板库里有 642 首是 FLAC）

老板 2026-11-22 01:05 的真机结果：**改写 6 · 新增 14 · 格式不支持 642**。
那 642 首全是 **FLAC** —— 上一版只做了 mp3/m4a，判它们"格式不支持"，是我的判断失误
（不是文件坏了，旁车封面/歌词当时已经写好了）。截屏同时给了 `Cover 662 / Lyrics 638 / Music 662`。

这一版按 FLAC 标准写法补齐（`DownloadCompanion.FlacTags`）：

| 项 | 写到哪里 |
|---|---|
| 歌名 / 歌手 / 专辑 | `VORBIS_COMMENT` 的 `TITLE=` / `ARTIST=` / `ALBUM=`（文件里原有的 `DATE=` / `TRACKNUMBER=` 等**原样保留**） |
| 歌词 | `VORBIS_COMMENT` 的 `UNSYNCEDLYRICS=` |
| 封面 | `PICTURE` 块（type 3 = front cover），旧封面块替换掉；宽高从 JPEG/PNG 头里读 |
| 音频 | 元数据块之后的所有字节**原样搬** |
| 开头挂的 ID3v2 | 丢掉（非标准前缀、常带旧封面；解码仍从 `fLaC` 开始） |

另外把"看不明白"的地方补上了：写回结果现在多报一行 **目录：Music 662 · Cover 662 · Lyrics 638** ——
`Lyrics` 比 `Music` 少，是"这首歌本来没取到词"，不是写回失败；`Cover` 与 `Music` 相等就说明建联齐了。

断言：`ios/SelfTest/main.swift` 第 50 轮再加 20 条（读旧值、写新值、`DATE` 保留、音频帧不变、
前置 ID3 处理、非 FLAC 拒绝、空字段不写），本机 53/53 全绿。

### 8.5 第 51 轮：A 方案（文件是真相 + 状态可见）

老板 2026-11-22 02:02 拍板「继续按 A 方案往下走」。这一轮不加新格式，只把**口径**和**可见性**做出来：

**① 谁说了算（口径）**

| 层 | 角色 |
|---|---|
| 音频文件里的标签 | **真相**（TIT2/TPE1/TALB/APIC/USLT；flac 是 Vorbis Comment + PICTURE） |
| `Cover/` `Lyrics/` 旁车 | **缓存**（App 读取快、跨容器可用；可以重建） |
| `downloads.json` | **路引**（路径/收藏/来源/状态；显示仍读它，但以文件为准可一键覆盖） |

判定是纯函数 `DownloadCompanion.FileTruth.state(file:song:hasCoverSidecar:hasLyricsSidecar:)`，
四种结果：`inSync`（文件里就是这一套）/ `sidecarOnly`（只有旁车）/ `missing`（连图都没有）/
`unsupported`（容器写不了标签）。

**② 状态可见（界面）**

- 下载页每行右侧、时长左边一个小圆点：**绿**=文件已对齐、**灰**=只在旁车、**橙**=没封面、
  **淡灰**=容器不支持（VoiceOver 会读中文说明）。
- 「⋯」→ **检查文件对齐（封面/标签/歌词）**：只读扫描全库（并发 4），结果写进记录，圆点立刻更新；
  弹窗报 `文件已对齐 X · 只在旁车 Y · 没封面 Z · 容器不支持 W`。
- 编辑页新增 **「文件里现在是」**：把文件里的歌名/歌手/专辑/封面/歌词原样列出来，
  对照上面的输入框；按钮 **「以文件为准（覆盖列表）」** 用文件里的值覆盖列表，
  并把文件里的图/词同步成旁车 —— A 方案的"以文件为准"是能真的点到的，不是口号。
- 写回成功时顺手把该首标成 `inSync`（不用再跑一次检查）。

**③ 顺带修的**

`ios/SelfTest/main.swift` 里那条 `只能写旁车的容器：flac/ogg/wav` 是第 50 轮之前的口径，
这一轮改成 `flac 也是能内嵌的容器` + `只能写旁车：ogg/wav` —— r177 红的根因就是它。

断言：第 51 轮再加 7 条（四种状态 + 只有旁车词 + 中文说明），本机 60/60 全绿。

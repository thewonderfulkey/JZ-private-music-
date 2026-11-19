# iOS 播放层（P1）：引擎、系统面与可验证的边界

> 状态：**已落码、CI 编译通过、纯逻辑断言通过**（2026-11-16）。**没有实机/模拟器验证过"能不能出声"**——那一步需要你把 IPA 装到手机上试（§6 有 6 步清单）。
> 上一环：[IOS-NETWORK.md](IOS-NETWORK.md)（搜索与取流）。下一环：歌词（LDDC/KRC·QRC 解密）。

---

## 1 这一层做了什么

```
搜索结果 ──点击──▶ PlayerEngine ──取流（网络层三级链）──▶ AVPlayer
                     │                                     │
                     │                                     ├─▶ 锁屏/控制中心（NowPlayingCenter）
                     │                                     └─▶ 耳机键 / AirPods（MPRemoteCommandCenter）
                     ├─▶ 播完推进（单曲循环 / 列表 / 随机 / **心动**）
                     ├─▶ 时长防线（差 >5s 判坏源）
                     └─▶ 无源跳歌（连跳 3 首停）
```

| 文件 | 职责 |
|---|---|
| [PlaybackRules.swift](ios/JZMusicHelper/Services/PlaybackRules.swift) | **纯函数**：`PlayMode` 四态、下一首/上一首索引、时长校验、连跳上限、模式循环顺序。不依赖 AVFoundation，所以 CI 能直接断言 |
| [HeartbeatRules.swift](ios/JZMusicHelper/Services/HeartbeatRules.swift) | **纯函数**：心动模式的画像（五通道加权 / 饱和 / 衰减）、打分与惩罚、MMR 多样性、新旧比例调度。CI 有断言，见 [IOS-HEARTBEAT.md](IOS-HEARTBEAT.md) |
| [HeartbeatEngine.swift](ios/JZMusicHelper/Services/HeartbeatEngine.swift) | 心动模式的编排：召回（种子歌手 / 画像歌手 / 搜索词 / 旧爱池）→ 排序 → 预取整首落盘 → 交给播放器；播放事件与「不感兴趣」的持久化 |
| [AudioPlayer.swift](ios/JZMusicHelper/Services/AudioPlayer.swift) | `PlayerEngine`（`@Observable`）：队列、播放/暂停、上一首/下一首、seek、模式切换、取流（3 轮重试 + 坏源黑名单）、进度与缓冲、播完推进、坏源拒播、无源跳过 |
| [NowPlayingCenter.swift](ios/JZMusicHelper/Services/NowPlayingCenter.swift) | 音频会话（`.playback` + 后台）、锁屏/控制中心信息（含异步封面）、远程命令、打断恢复、拔耳机暂停 |
| [MiniPlayerBar.swift](ios/JZMusicHelper/Views/MiniPlayerBar.swift) | 迷你条（56pt、材质、进度细线） |
| [NowPlayingView.swift](ios/JZMusicHelper/Views/NowPlayingView.swift) | 播放页（封面 / 题名 / 进度含缓冲带 / 四态循环 / 心动理由条与「不感兴趣」/ 上一首-播放-下一首 / 状态行 / 音源行 / 播放列表含「即将播放」） |

接入点：`MainTabView` 注入引擎、`safeAreaInset` 挂迷你条、`sheet` 打开播放页；`SearchView` 的行改成「点一下就播，队列 = 当前结果整列」（与 Android 一致）。

---

## 2 与 Android 的口径对照

| 能力 | Android | iOS | 是否等价 |
|---|---|---|---|
| 播放模式 | `SINGLE_LOOP / LIST_LOOP / SHUFFLE`，点一下循环切换 | `SINGLE_LOOP / LIST_LOOP / SHUFFLE / HEARTBEAT`，`cycled()` 同顺序；心动模式为 iOS 独有，见 [IOS-HEARTBEAT.md](IOS-HEARTBEAT.md) | ➕ |
| 播完推进 | 单曲循环重播 / 列表取模 / 随机不重复当前 | 同；单曲循环是 `seek(0)+play`，**不重新取流**（省 1–12s） | ✅（更快） |
| 上一首 | 随机模式下也是重随机 | 同 | ✅ |
| 时长防线 | 实际与曲目差 >5s → 拒播换源 | 同，且把该 URL 记进坏源名单，换源时跳过 | ✅ |
| 无源跳歌 | 连跳上限 3，每首提示 600ms | 连跳上限 3，`skipMessage` 给一句人话 | ✅ |
| 三级取流 + 重试 | 本平台 → 跨平台补位 → 3 轮（2/2.5/3s） | 同（复用网络层） | ✅ |
| 后台播放 | 前台服务 + 常驻通知 + wakelock | `AVAudioSession.playback` + 后台音频 | ✅（iOS 更省心） |
| 锁屏控制 | Android 版**没有**（无 MediaSession） | 系统 Now Playing + 控制中心 + 耳机键全自动 | ➕ 净增益 |
| 拔耳机暂停 | Android 版**没有** | `routeChange(.oldDeviceUnavailable)` → 暂停 | ➕ |
| 来电打断 | 无处理 | `interruption`：`.began` 暂停，`.ended` 且 `shouldResume` 才恢复 | ➕ |
| 音量 | 无应用内音量（系统媒体音量） | 同 | ✅ |
| 倍速 / 均衡器 / 睡眠定时 | 都没有 | 都没有 | ✅ |
| 播放队列页 | 内部有队列、无页面 | 内部有队列、暂无页面（设计稿 §3.12，随 P0/P5 的 UI 一起做） | 等价 |
| 下一首预取 | 预取 3 首落盘 | 心动模式预取 1-2 首并整首落盘（切歌读本地文件）；其余模式仍是边下边播 | 部分 |

---

## 3 已知的取舍（都写进代码注释了）

1. **`MainActor.assumeIsolated` 建引擎**：`@State` 的默认值在非隔离上下文求值，而 `PlayerEngine` 是 `@MainActor`。View 构造一定在主线程，所以这里安全；但这是一个"我保证在主线程"的类型断言，将来若有人把 `MainTabView` 塞进非主线程容器会 trap。
2. **系统面延迟装配**：音频会话/远程命令/进度观察在**第一次播放**时才装（`attachSystemIfNeeded`），避免 App 一启动就抢音频会话。
3. **单曲循环不重新取流**：直接重播同一份 `AVPlayerItem`。好处是快；代价是如果这份流中途失效，要等它报错才会换源（`failedToPlayToEndTime` 已接）。
4. **坏源黑名单是按"当前曲目"的**：切歌即清空。所以同一首歌第二次进来仍可能撞同一条坏源一次——可接受（否则要跨会话持久化，收益不大）。
5. **旧的 `PlayerManager.swift` 还在**（`SongDetailView` 的试听还在用它）。现在有两套播放器，理论上会同时出声。等 P0 重做 UI 时一并删掉，**现在别在详情页和播放页同时点播放**。

---

## 4 这一层被验证到什么程度

| 验证 | 手段 | 结果 |
|---|---|---|
| `PlaybackRules` 的口径 | CI `logic-tests`（`swiftc` 编 `ios/SelfTest/main.swift` 直接跑） | ✅ 91 条断言全绿，其中播放相关 17 条：单曲循环原地、列表取模与回绕、随机不重复自己、单首/空队列、时长差 4s/31s、时长未知、连跳 2/3 首、模式循环顺序 |
| 整包能否编译 | CI `build-ipa`（`xcodebuild`，iOS 17 target，device arm64） | ✅ BUILD SUCCEEDED（run #43802409335） |
| **能不能出声** | ❌ 本机是 Windows，没有模拟器也没有设备 | **未验证**，见 §6 |
| 锁屏/耳机键是否真的响应 | ❌ 同上 | **未验证**，见 §6 |

> 说法边界：以上"✅"只覆盖"逻辑对 + 类型对"，不覆盖"在真机上跑起来对"。不要在没装机之前对外说"播放器做好了"。

---

## 5 踩到的坑（已修，记下来）

| 坑 | 现象 | 处理 |
|---|---|---|
| `nonisolated init` 写 `@MainActor` 属性 | `xcodebuild` 报 `main actor-isolated property 'mode' can not be mutated from a nonisolated context` | 引擎 init 回到主线程，View 侧用 `MainActor.assumeIsolated` 桥 |
| pbxproj 手工加 5 个文件 | 需要同时进 BuildFile / FileReference / 分组 / Sources 四处，且 ID 不能撞 | 把脚本泛化成 `tools/ios/add_pbx_files.py Services A.swift … Views B.swift …`（幂等、自动分配 ID） |
| `@Environment(PlayerEngine.self)` 预览里没注入 | 预览崩溃 | `SearchView` 预览补 `.environment(…)` |

---

## 6 装到手机上要试的 6 件事（P1 验收）

1. 搜「晴天 周杰伦」→ 点第一条 → **3 秒内出声**，播放页显示「音源 cyapi QQ · M4A · 97 kbps」之类。
2. 锁屏 → 应看到**封面、歌名、歌手、进度**；锁屏上点暂停/播放有效。
3. 拔掉耳机（或断开蓝牙）→ **自动暂停**。
4. 播放页把模式切到**单曲循环** → 一首放完应重播；切**随机** → 连续 10 首不应出现「同一首接着同一首」。
5. 搜一首冷门歌 → 本平台无源时，状态行应出现「换源/跳歌」文案，**不能是"点了没反应"**。
6. 后台播放 5 分钟 → 切回 App，进度应与实际一致（不是从头或卡住）。

任何一条不符，把现象告我，我按这条链定位（引擎 / 系统面 / 取流）。

---

## 7 下一步

| 顺序 | 内容 | 为什么是它 |
|---|---|---|
| **下一步** | 歌词：酷我官方 LRC → LDDC（QQ QRC / 酷狗 KRC）→ 逐字解密 → 繁转简 → 播放页歌词态 | 这是产品最"别人没有"的地方之一，也是播放页缺的最后一块；移植量大（Android 侧约 500 行加解密） |
| 之后 | P0 UI 骨架（5 Tab + 发现/搜索/资料库/下载/设置按设计稿重做） | 现在 UI 还是 4 Tab 原型，设计稿的 5 Tab 要靠它落地；顺带删掉旧的 `PlayerManager` |
| 之后 | P2 下载（后台 URLSession + 95% 体积校验 + 文件 App） | 已拍板"下载进 v1"，且网络层已能给出"目标档候选清单" |

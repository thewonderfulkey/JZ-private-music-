# 后台播完不自动换下一首 —— 诊断报告（B）+ 歌单缓存现状（C）

> **状态**：2026-11-20 诊断（本文 §1–§5、§7）→ 同日晚老板拍板 → **A+B+C 第一批/第二批已实施**，
> 版本 2.4.33（211）。实施记录与"计划 vs 实际"的差异见 **§10**。
> 结论来自两类证据：① 逐行读代码（下面每条都带 `文件:行`）；② 在真网上按 App 的取流链实测耗时
> （`tools/probes/probe_play_resolve_latency.py`、`probe_quickpick_window.py`，样本是老板真实导入的
> 网易「我喜欢的音乐」729 首）。
>
> **本机是 Windows，没有 iPhone 也没有模拟器**，所以"真机 3 次 × 2 场景"的秒表我跑不了。
> §5 给了打点规格 + 6 步动作，装机的人 10 分钟能跑完；跑回来的 6 行就能把最后那格补上。
> 报告里凡是用平台机制（不是本仓代码）推的地方都标了「需真机确认」。

---

## 1. 一句话结论

**卡在「上一首播完 → 下一首起播」之间那段被设计出来的空档里，不是队列逻辑，也不是网络慢。**
`goTo()` 先 `player.pause()` 把声音停掉，再去异步取源（`AudioPlayer.swift:517` → `:523`）；
在后台，声音一停就等于交出了后台执行权，取源还没回来就被系统挂起（`resolveStream` 全程没有
`beginBackgroundTask`，全仓 0 处），回前台任务才被续上——所以看起来"卡住，回来又自己好了"。

顺带纠正两个前提：空档**结构上就 ≥1.8 秒**（实测网络只占 0.5 秒，是"等齐三个后端"把它拖到 1.8 秒）；
空档上限**不是 12 秒**，是 15 秒（`collectDeadline`）起步、最坏约 3 分钟（`cross` 45 秒 × 3 轮）。

---

## 2. 证据一：代码里这条链路长什么样

| 步骤 | 位置 | 事实 |
|---|---|---|
| ① 监听播完 | `AudioPlayer.swift:756` | `AVPlayerItem.didPlayToEndTimeNotification`，`object: item`（只认当前 item，`:764` 校验） |
| ② 播完处理 | `:783` `handleTrackFinished()` | 列表循环 → `PlaybackRules.nextIndex(...)` → `:804` `goTo(next)` |
| ③ 换曲 | `:503` `goTo()` | **`:517` 先 `stopCurrentForSwitch()`（`player.pause()` + `isPlaying = false` + 刷新锁屏）**，`:523` 才 `Task { await loadCurrent() }` |
| ④ 取源 | `:556` `loadCurrent()` → `:614` `await resolveStream(for:)` | 纯网络 + 探测，全过程无后台任务保护 |
| ⑤ 起播 | `:627` → `:631` `start(item:)` | `:635` `replaceCurrentItem` → `:636` `player.play()` |
| ⑥ 锁屏状态 | `:539` `updateNowPlaying()` → `NowPlayingCenter.swift:189` | 空档期间把 `playbackState` 主动置为 `.paused`（等于又告诉系统一遍"我没在放"） |

**空档 = 从 `:517` 到 `:636`**，也就是从"声音停"到"新 item 开始出声"之间，全部是网络。

---

## 3. 证据二：这段空档实测有多长

### 3.1 单个后端（网易主通道 gdstudio，`br=740` 即现在的无损档）

| 歌 | 接口取 URL | Range 探测 | 合计（单后端） |
|---|---|---|---|
| Into the rainbow | 721 ms | 257 ms | 1524 ms |
| Twilight Line | 658 ms | 394 ms | 1603 ms |
| Sun | 455 ms | 144 ms | 1176 ms |
| 漫漫 | 516 ms | 160 ms | 1180 ms |
| 0222心动-比尔的歌 | 428 ms | 141 ms | 1099 ms |
| Spirits | 938 ms | 133 ms | 1502 ms |

→ **网络本身不慢**：接口 0.43–0.94 s，探测 0.13–0.39 s。

### 3.2 但播放链不是"谁先回来用谁"，而是"等齐三个后端"

`resolveStream` 第一步 `quickPick`（`:665`）→ `DownloadResolver.quickPick`（`URLResolver.swift:540`）
→ `collect`（`:637`）的实现是 `for await r in group`（`:655`），**必须等三个 primary 后端全部返回
或全部撞到 1.8 s 窗口**（每个 job 套 `withTimeoutOrNil(left)`，`left ≈ 1.8 s`）。

实测三个后端并发（网易歌）：

| 歌 | gdstudio | oiapi | 妖狐酷我 | 等齐 |
|---|---|---|---|---|
| 你太美 | 515 ms | 1610 ms | 2579 ms | **2582 ms** |
| Dragonflame | 527 ms | 2083 ms | 1964 ms | **2085 ms** |
| 南风说 | 513 ms | 1391 ms | 2021 ms | **2023 ms** |
| Catch My Breath | 576 ms | 1613 ms | 4919 ms | **4921 ms** |

→ 三个后端**没有一次**在 1.8 s 内等齐（0/4）。所以在 App 里：

- 只要 gdstudio 在 1.8 s 内回了（它 0.43–0.94 s，基本都回），`quickPick` 就**吃满 1.8 s** 才返回；
- 一旦 gdstudio 也超 1.8 s（移动网、聚合接口被风控——r123~r125 的旧账），`quickPick` 返回 nil，
  掉进 `plan()`（`:670`，预算 **15 s**，`URLResolver.swift:447`），再不行还有
  `SameSongCrossResolver.resolve`（`:675`，预算 **45 s**，`URLResolver.swift:151`）；
  `resolveStream` 还会重来 3 轮、每轮之间 sleep 2 / 2.5 s（`:656`–`:663`）。

**所以空档是：至少 1.8 s（结构性下限，与网速快慢无关），再加 `AVPlayer` 起播那一下（未测）；
不顺时 15 s 起；最坏分钟级。**
"有时卡"= 空档长短与系统挂起阈值赛跑 —— 短的时候扛过去了，长的时候就被挂起。

---

## 4. 逐条验证老板的 5 个假设

| # | 假设 | 结论 | 证据 |
|---|---|---|---|
| 1 | `:756` → `handleTrackFinished()`（`:783`）→ `goTo(next)`（`:804`） | **✅ 成立** | 三处代码如上，且 `:764` 有"只认当前 item"的校验、`:785` 有 1.2 s 迟到通知过滤 |
| 2 | `goTo` 先 `stopCurrentForSwitch()` 暂停，再 `Task { await loadCurrent() }`，取源是异步网络 | **✅ 成立，而且比设想的更硬**：是**必然**先停（`:517` 在 `:523` 之前，无任何条件），不是"可能停" | `:517` / `:523` / `:533`–`:540` |
| 3 | 歌与歌之间音频是停的；`UIBackgroundModes=audio` 只在出声时保活；挂起导致取源卡住 | **✅ 机制成立（方向正确），但两处要修正**：<br>① 空档不是"12 秒"，是 1.8 s 起、15 s / 45 s 兜底；<br>② 网络不是主因（实测单后端 1.1–1.6 s，0.5 s 就拿到 URL）<br>「具体几秒被挂起」需真机确认（平台行为，不在本仓代码里） | `Info.plist:40-43`（`UIBackgroundModes=[audio]`）；`NowPlayingCenter.swift:60-72`（`.playback` + `setActive(true)`，只在 `applicationWillTerminate` 里释放 `:41`） |
| 4 | 导入歌单多为网易源，走 `NeteaseLookup`（多源检索+校验），空档更长 | **❌ 推翻**。`NeteaseLookup` **不在播放链上**：只有 `candidateList(forDownload: true)` 才跑它（`URLResolver.swift:275`），播放链 `SameSongCrossResolver.resolve` 传的是 `forDownload: false`（`:158`）。<br>真正让空档变长的是 **`quickPick` 的"等齐"语义** + oiapi/妖狐拖到 2–5 s，与"导入"无关；<br>但**平台**确实有影响：导入的酷我歌只有妖狐一个后端（2–4.9 s），更容易吃满 1.8 s 后掉进 `plan()` | `SourceAdapters.swift:524-539`（后端表）、`:540`（`quickPick`） |
| 5 | 队尾 `nextIndex` 返回 nil（会不会是"队列到头"） | **❌ 推翻（列表循环/随机）**：`nextIndex` 列表循环是 `(current+1) % count`（`PlaybackRules.swift:82-84`），随机也不返回 nil（`:85-92`）。只有**心动模式**到队尾返回 nil（`:93-96`），而且那边会现场算下一首（`AudioPlayer.swift:808-813`），不会静默停住 | `PlaybackRules.swift:74-97` |

另外两条老板点名要确认、代码上是"确定没有"的：

| 确认项 | 结论 | 证据 |
|---|---|---|
| 有没有 `beginBackgroundTask` 包裹取源 | **没有，全仓 0 处** | `grep beginBackgroundTask ios/` → 无匹配 |
| 当前歌播完**之前**有没有预取下一首 | **没有**（只有心动模式有） | `pendingLocal`/`pendingStream` 只在 `goTo(localURL:streamURL:)` `:508`/`:513` 被赋值，唯一调用方是 `playHeartbeat`（`:826`/`:830`）。列表循环走 `:804` `goTo(next)`，两个参数都是 nil → 每次换曲必然重新联网 |
| 锁屏/切后台时 `AVAudioSession` 是否仍 active | **是**（`.playback`，全程不释放） | `NowPlayingCenter.swift:64-65`、`:41` |
| `UIBackgroundModes` 是否含 audio | **是** | `Info.plist:40-43` |

> 一句话：会话确实是 active、后台模式也确实声明了——但这两样都只保证"正在出声时不被打断"，
> **不保证"没出声时还能继续跑网络"**。空档一旦长过系统的耐心，进程就挂起。

---

## 5. 真机怎么把最后这格补齐（10 分钟，6 次）

### 5.1 打点规格（5 个点，每点一行）

统一格式：`HH:mm:ss.SSS | 阶段 | appState | 歌名/下标 | 备注`

| 阶段 | 打在哪 | 必须带的字段 |
|---|---|---|
| `didPlayToEnd` | `AudioPlayer.swift:783` `handleTrackFinished()` 第一行 | `applicationState`、当前 `index`、`queue.count` |
| `goTo 开始` | `:505` 之后 | 目标 index、`mode` |
| `resolve 开始 / 结束` | `:611` 前后（`isResolving = true/false`） | 耗时 ms、`src` 有无、`backendName` |
| `item readyToPlay` | `:730` `case .readyToPlay` | 与 `didPlayToEnd` 的间隔（**这个差值就是卡住时长**） |
| `play()` | `:636` 之后 | `isPlaying`、`applicationState` |

`appState` 取 `UIApplication.shared.applicationState`（`.active/.inactive/.background`）。
打点放一个 200 行环形缓冲，设置页加「播放诊断」只读页（可长按复制），比现在的 `取源诊断` 弹层更好贴回来。

### 5.2 六次动作

场景 A（切后台）：进「我的歌单」→ 播全部 → 播到第 1 首**剩 10 秒**时上滑回桌面 → 等 20 秒 → 看是否自动到第 2 首。
场景 B（锁屏）：同上，但改成按电源键锁屏。
每个场景 3 次，记录：是否卡住 / 卡在哪个阶段（看最后一条打点的阶段名）/ 卡了多久（`readyToPlay` 与 `didPlayToEnd` 的差值）/ 回前台是否自动恢复。

### 5.3 三种结果分别说明什么（预先写死，避免事后解释）

| 打点形态 | 结论 |
|---|---|
| `didPlayToEnd` 与 `readyToPlay` 差 >5 s，且 `resolve 结束` 一直到回前台才出现（或 appState 在空档里变 `.background` 后再无日志） | **挂起成立**（本报告结论）→ 按 §6 修 |
| `didPlayToEnd` 后 `readyToPlay` 很快到（<2 s）但没有声音、`play()` 也调了 | 不是挂起，是 `AVPlayer` 起播/会话问题 → 改查音频会话与 item 状态 |
| `nextIndex` 相关日志显示 `count=1` 或 mode=心动 | 队列问题 → 与 §4 第 5 条不符，需要另查 |

---

## 6. 改动清单（A + B + C 一次做完，等确认）

### B（后台播完不换歌）—— 按性价比排序

| # | 改什么 | 位置 | 风险 | 验收 |
|---|---|---|---|---|
| **B1** | **预取下一首的源**（真正的修法）：起播成功就按 `nextIndex` 把下一首解析好，塞进已有的 `pendingStream`/`pendingLocal`；`goTo` 命中就直接起播，零网络 | 新增 `prefetchTask`；`start(item:)` `:631` 末尾触发；`goTo` `:503` 命中判断；`loadCurrent` `:596` 已有消费逻辑可直接复用 | 中：多一次网络与探测；**必须与 A 的 320k 上限一致，预取不准取 FLAC**；换队列/手点要 cancel | 锁屏连播 3 首，`goTo 开始`→`readyToPlay` < 0.2 s；流量增加可接受（320k 一条 URL，不是整首下载） |
| **B2** | **`beginBackgroundTask` 兜底**：`goTo` 开头 begin，`start()` 或取源失败时 end（成对，防泄漏） | `:503`–`:524`、`:617`–`:619` | 低：只延长几秒窗口，不改变逻辑 | 打点里空档仍在（因为 B1 才是根治），但**不会**在空档里变 suspended |
| **B3** | **回前台自愈**：`scenePhase == .active` 时若 `isResolving` 仍挂着 → 重踢一次；`toggle()` `:332` 的 `if isResolving { return }` 改成"重试一次" | `RootTabView.swift:86-99`、`AudioPlayer.swift:328-346` | 中：需 nonce 防双开解析 | 手动把 App 挂 60 s 再回前台，点播放要能出声音（现在点了没反应） |
| **B4**（可选） | 自然播完这条路径**不要**先 `pause()`（r71 的口径是"手动换曲先暂停"，不是"播完也停"）：`nextTrack()`/`handleTrackFinished` 走 `goTo(pauseFirst: false)` | `:517`、`:349`、`:804` | 中：两条路径分开，改动面稍大 | 有预取时整段空档 ≈0（无缝） |
| **B5** | `didPlayToEnd` 的 1.2 s 迟到过滤要在"预取命中直接 swap"后重新核对 | `:785` | 低 | 不出现"刚起播就被切走" |

### A（在线降到 320k、无损只下载）

| # | 改什么 | 位置 | 风险 |
|---|---|---|---|
| A1 | 播放档从 `.lossless` 改 `.high`（320） | `AudioPlayer.swift:213` | 低 |
| A2 | `resolveStream` 三处 `want: quality` 改播放档 | `:665` / `:670` / `:675` | 低 |
| A3 | **下线 `scheduleQualityUpgrade`**（否则会把播放链偷偷升到 FLAC，与 A 直接冲突） | `:688`–`:711` | 低（少一条后台 15 s 的任务，对 B 也是减负） |
| A4 | 播放链排序按实测码率 320>256>128、FLAC 不进播放链；下载链保持 无损>320>256>128 | `URLResolver.swift:106-139`（`SourcePicker.score`）、`DownloadResolver.score` `:583-602`、`tierOf` `:560-565`（需加 `forPlayback` 口径） | 中：两套口径要分开，别把下载链一起改了 |
| A5 | 删 `deadSongKeys.insert` | `:946`；**同类还有 `:959`（`handleNoSource`）**，A 只写了 946，这处要不要一起删请老板定 | 低 |
| A6 | 同曲换源：失败时同曲换下一条、保持进度、全失败才跳歌 | `:944`–`:956`（现在是直接 `advanceAfterFailure()` 跳下一首）、复用 `pendingRestoreSeconds` `:181`/`:734` | 中：要防"同曲无限重试"，用 `rejectedSourceURLs` 上限 + `consecutiveSkips` 兜底 |
| A7 | UI 诚实标注「高品 320k（无损仅下载）」 | `:626` 状态行、播放页音质行、下载弹层 | 低 |

### C（歌单缓存）—— 见 §7，导入歌单**不用改**，要改的是广场歌单详情

---

## 7. C：歌单缓存现状（只梳理）

### 7.1 「我的歌单」（导入的）—— 已经是双层缓存，且零网络

| 层 | 实现 | 位置 |
|---|---|---|
| 磁盘 | `Documents/my_playlists.json`，导入时原子写一次，之后**不再请求任何歌单接口** | `MyPlaylistStore.swift:22-25`、`:75-78` |
| 内存 | `@Observable` 单例，`playlists: [ImportedPlaylist]`，进程内一直活着；`App` 里 `@State` 持有 | `MyPlaylistStore.swift:14-20`、`JZMusicHelperApp.swift:15` |
| 进入页面 | 详情页/整页都直接读内存，**零请求、零 loading、无骨架** | `MyPlaylistViews.swift:227-334`（`playlist` 计算属性 = `store.playlist(id:)`） |
| 回前台 | `DiscoverView` 的 `scenePhase == .active` 只刷 feed/广场/歌手，**完全不碰 `myPlaylists`** | `DiscoverView.swift:85-91` |

**结论：老板要的"加载一次后不再加载"，导入歌单这条路已经做到了，而且比 TTL 更狠（快照永不刷新，除非重新导入）。**
唯一会"重新加载"的情况是**进程被系统杀掉后再冷启动**：那时会重新 JSON 解码一次（729 首约几十毫秒，同步、在主线程，`init` 里做）。
如果观感上"回后台再进来像重新加载"，更可能是这两件事之一：
① 冷启动时发现页那几个**网络模块**在拉数据（骨架块）；② 歌单封面重新走缓存（`CoverImageCache` 有磁盘缓存，正常是读盘几十毫秒）。

### 7.2 会真的"每次进都重新加载"的，是广场歌单详情

| 页面 | 缓存 | 表现 |
|---|---|---|
| 歌单广场列表 | 内存 + **按本地日落盘**（`cachedSquare`），另有 30 分钟节流的 1KB 探测 | 当天再进零请求：`SquareFeed.swift:61-70`、`:145-155` |
| **歌单详情**（广场点进去） | **只有 `@State` 内存**，没有磁盘、没有跨实例缓存 | 每次 push 都 `KuwoPlaylist.fetchDetail` 重新拉 100 首 + 骨架：`PlaylistDetailView.swift:69`、`:144-154` |

→ 如果老板说的"歌单"是广场里点进去的那种，那"每次进都转圈"是**真的**，原因就是这一层没有缓存。

### 7.3 建议（不写代码）

1. **导入歌单：不改**。已是内存 + 磁盘快照，改它没有收益。
2. **广场歌单详情加双层缓存**：`Caches/playlist-details/<id>.json`，`Codable`，TTL 24 h（或本地日）；
   进页面先出缓存（第一帧就有 100 行），TTL 内不请求；只在**冷启动首次 / 下拉刷新 / TTL 过期**时重拉。
   现成的三个同款实现可以照着写：`CoverImageCache`（磁盘 + 内存 + 淘汰）、`SquareFeed`（按日落盘）、`KuwoPlaylist.cachedSquare`。
3. **回前台不自动刷新**：保持现状（`DiscoverView` 只刷 feed，且有 10 分钟/30 分钟节流）。
4. 顺手把 `MyPlaylistStore.load()` 从"启动时同步解码"改成"首发后异步补一次"，冷启动能再省几十毫秒（可选）。

---

## 8. 需要老板拍板的三件事

1. **A5**：`deadSongKeys.insert` 除了 `:946`，`:959`（`handleNoSource`）也是同类写法——一起删，还是只删 946？
2. **B4**：自然播完这条路径要不要"不先暂停"（配合预取做到无缝）？这是 B 里唯一会碰到 r71 那条"换曲先暂停"口径的改动。
3. **打点页**：诊断面板放在「设置 → 播放诊断」（只读、可复制），长期保留，还是只出一次诊断包？

---

## 9. 本轮没做的事（边界）

- 没有改任何代码（A/B/C 都只出清单）。
- 没有真机数据：本机 Windows，无 iPhone/模拟器；§5 是给装机侧的执行脚本。
- 实测耗时来自本机网络（Windows → 公网），与手机 4G/Wi-Fi 会有差异；但"等齐三个后端"是代码语义，与网络快慢无关。
- 未验证：iOS 具体在"停声后几秒"挂起（平台行为），以及挂起时 URLSession 是"冻结后继续"还是"直接失败"——这两点 §5 的 6 次复现就能定。

---

## 10. 实施记录（2026-11-20，v2.4.33 / 211）

### 10.1 落地的文件

| 文件 | 改了什么 |
|---|---|
| `Services/PlaybackRules.swift` | 新增 `PlaybackQualityRules`（≤320k 门槛 / 实测码率排序 / 320 档判定 / UI 文案）、`PrefetchRules`（20–30 秒窗口）、`maxSameSongSwitches = 3` |
| `Services/URLResolver.swift` | 新增 `DownloadResolver.firstPlayable`（先到先用，第一个过「≤320k + 身份闸」的候选立刻返回） |
| `Services/SourceAdapters.swift` | 新增 `KuwoOfficialAdapter`（`anti.s?rid=`，酷我歌的 ≤320k 那条源）并注册进 `SourceRegistry` |
| `Services/AudioPlayer.swift` | 打点 `PlaybackTrace`；`playbackQuality`；预取（B1）；`beginBackgroundTask`（B2）；`recoverIfStalled`（B3）；`goTo(pauseFirst:)`（B4）；同曲换源（A6）；删两处 `deadSongKeys`（A5）；`schedulePlaybackUpgrade` 取代 `scheduleQualityUpgrade`（A3） |
| `Views/SettingsView.swift` | 「设置 → 播放 → 播放诊断」入口 + `PlaybackDiagnosticsView` |
| `Views/NowPlayingView.swift` | 音质胶囊改「高品 320k（无损仅下载）」，本地文件写「本地播放」 |
| `Views/RootTabView.swift` | `scenePhase == .active` → `player.recoverIfStalled()` |
| `Services/KuwoPlaylist.swift` | `Detail: Codable`；详情缓存（内存 + `Caches/playlist-details/<pid>.json`，TTL 24h）；`detailNetworkCalls` 计数 |
| `Views/PlaylistDetailView.swift` | 先读缓存再联网；下拉刷新；「x 分钟前更新」 |
| `ios/SelfTest/main.swift` | 新增 4 节断言（播放档位 12 条 / 同曲换源上限 / 身份闸 5 条 / 预取窗口 9 条） |
| `docs/ios/*`、`CHANGELOG.md`、版本号 | 2.4.32(210) → 2.4.33(211) |

### 10.2 计划 vs 实际（三处偏差，都是实施时才发现的）

1. **必须补一条酷我官方源**。计划里没有这一项，但实施时发现 `YaohuKuwoAdapter` **忽略 quality 参数**，
   实测「晴天 / 夜曲」都只回 `level=lossless, bitrate=740` 的 FLAC。按"FLAC 不进播放链"过滤后，
   酷我歌（歌单广场 / 热门音乐 / 最新单曲全是酷我）会**整首没源**。所以补 `KuwoOfficialAdapter`：
   `anti.s?type=convert_url&format=mp3&response=url&rid=MUSIC_<rid>` 实测回 129kbps mp3
   （`audio/mpeg`，2,302,801 B / 143s，ID3 头正常，支持 Range）。
   `br=320` / `br=320k` / `format=flac` 服务端不认：回的是一个约 181KB 的残片（10kbps），已避坑。
2. **升档时机从"resolve 里"挪到"start 之后"**。原来在 `resolveStream` 里就调升档，那时 `source`
   还是上一首的，`isTopTier` 判断必然错；现在放到 `loadCurrent` 起播成功之后（那时才知道这一首真实码率）。
3. **`resolveStream` 去掉 `quiet` 参数**。预取不需要"不写状态行"这个开关——`resolveStream` 本来就不写 UI，
   状态行是 `loadCurrent` 写的，多一个参数只会多一条分支。

### 10.3 代价与回滚点（写清楚，避免下一轮当成 bug 查）

- **酷我歌的在线音质从 FLAC 变成 128k mp3**。这是 A 口径的直接后果（酷我官方只给 129kbps，妖狐只给 740k 无损）。
  起播后 `schedulePlaybackUpgrade` 会在后台尝试跨平台找 320k 并无缝换源（保留进度）；
  找不到就停在 128k。要回退：`PlaybackQualityRules.isPlayable` 里放行无损即可（一行）。
- **预取会让每次切歌多一次"下一个 URL"的解析**（约 0.5–1.5s 的后台网络，不下载音频）。
  流量代价是一条 URL + 一次 Range 探测，可忽略。
- **`beginBackgroundTask` 是定时豁免**：30 秒内没起播就会到期，到期后进程仍可能被挂起——
  但那时已经"确实没源"，不是我们的空档问题。

### 10.4 验收口径（本机做不到真机，交给装机侧）

| 项 | 怎么验 | 期望 |
|---|---|---|
| 320k | 播放页音质胶囊 + 播放诊断里 `play` 那行的 backend/kbps | 出现 `320kbps` 或 `128kbps`，**永不出现 FLAC/1087kbps**；播放页写「高品 320k（无损仅下载）」 |
| 同曲换源 | 播一首，用抓包/改 hosts 把第一条源打坏 | 诊断里出现「源失败 → 同曲换源（第 1 条）→ 预取/play」，**不跳歌**，进度接着走 |
| 预取 | 连续播 3 首，看诊断里 `didPlayToEnd` → `item ready` 的时间差 | 目标 ≤0.3s（预取命中会先有一条 `预取命中`），最差 ≤1s |
| 后台连播 | 锁屏放 3 首 | 每首都自动切；诊断里 `didPlayToEnd` 与 `item ready` 都在「后台」，`resolve` 前后都有「后台任务 开始/结束」 |
| 广场歌单缓存 | 进一个广场歌单 → 回后台 → 再进来 | 页头立即有内容、写「x 分钟前更新」；诊断页「歌单详情接口」次数**不涨**（= 0 请求） |

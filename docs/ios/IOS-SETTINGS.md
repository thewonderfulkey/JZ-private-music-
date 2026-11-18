# iOS 设置页（第四十轮重排）+ 车载自动播放 + 保存位置

> 最后更新：2026-11-19（第四十轮补丁 2，r113 / v2.4.14 / 192；补丁 1 r112 / v2.4.13 / 191；初版 r110 / v2.4.12 / 190）。
> 老板原话：「现在这个音乐软件的设置页面有些太乱太杂了，有些设置选项是不需要展示的」。
> 补丁来自真机反馈：「可配置的位置只有打开按钮，没有保存按钮……设置页面显示的只有一个 Music，
> 我要把完整的路径显示出来」——见 §4。
> 这份文件是**设置页现在的全貌**：哪些项在、哪些项已经下线、下线后行为是什么。
> 旧版对照表见 [IOS-FEATURE-PARITY.md](IOS-FEATURE-PARITY.md) §9。

---

## 1 现在的设置页（自上而下）

| 分组 | 行 | 类型 | 说明 |
|---|---|---|---|
| 外观 | 外观 | 分段：跟随系统 / 浅色 / 深色 | 唯一的外观开关 |
| 播放 | 车载自动播放 | 开关（默认开） | 连上车机 / 车载蓝牙后自动接着放，见 §3 |
| 歌词 | 歌词字号 | 跟随系统 / 大 / 特大 | |
| 歌词 | 可缓存歌曲数量 | Stepper 50–1000，步进 50（默认 200） | **本轮新增**，见 §2 |
| 歌词 | 已缓存 / 清空歌词缓存 | 只读 + 破坏性按钮 | 保留 |
| 识曲 | 聆听时长 | 12 / 15 / 20 秒 | 保留 |
| 下载 | 仅 Wi-Fi 下载 / 后台下载 | 开关 | 保留 |
| 下载 | 已下载 | 只读计数 | 保留 |
| 下载 | 保存位置 | 显示整条路径；点开可「选择文件夹…」+「保存到这里」/「恢复默认」 | 本轮由只读文案改为可配，见 §4 |
| 数据 | 清空搜索历史 / 最近播放 / 识曲历史 | 破坏性按钮（带条数） | 保留 |
| 关于 | 应用 / 版本 / 声明 | 只读 | 保留 |

---

## 2 下线的九项（行为改回固定口径）

老板的判据是"这些**没有第二种合理选择**，摆出来只会让人犹豫"。逐条对应：

| 下线项 | 原来的键 | 现在的行为 | 代码位置 |
|---|---|---|---|
| 音质偏好 | `quality` | 恒从**无损**起取；拿不到由 `SourcePicker.score` 逐级下降（无损 > 320k > 128k，同分优先直连后端）。老用户存过的低档值一并忽略 | `AudioPlayer.init` / `URLResolver.SourcePicker` |
| 无源自动换源 | `auto_fallback` | 恒开：最多 3 轮解析（间隔 2s / 2.5s / 3s） | `AudioPlayer.resolveStream` |
| 跨平台补源 | `cross_platform` | 恒开：本平台无源时走 `SameSongCrossResolver` | 同上 |
| 无源自动跳过 | `auto_skip` | 恒开 | `AudioPlayer.skipLimit` |
| 连续跳过上限 | `skip_limit` | 恒 **3 首**（`PlaybackRules.autoSkipLimit`，与 Android `AUTO_SKIP_MAX` 同值） | 同上 |
| 逐字动画 | `lyric_anim` | **按词决定**：`LyricLine.hasWordTiming`（KRC/QRC 解出来的行有 words）就逐字染色，普通 LRC 只有行级时间就整行白字 | `NowPlayingView.textContent` |
| QQ 歌词源（实验） | `lyrics_qq_source_enabled` | 内置，恒参与：与酷狗**并行**搜候选（QQ 给 2.5 秒上限，超时即丢，不拖主链） | `LddcLyrics.searchCandidates` |
| 默认偏移 | `lyric_offset_ms` | 恒 0。播放页「慢一点 / 快一点 / 归零」照旧**按单曲**记（`lyric_offset_by_song`），默认值不再暴露 | `SettingsStore.offsetMs(forSong:)` |
| 清空所有单曲偏移 | — | 设置页不再有入口（单曲微调本身仍是可逆的：归零/再点） | — |
| 识别前暂停本机播放 | `rec_pause` | 恒暂停：不暂停收到的就是自己放的歌 | `RecognizeView.listen()` |

> 键名都留在原地没删：老版本写过 UserDefaults，新版本**不读**它们了，
> 所以升级后不会出现"以前关了换源、升级后还关着"的隐性状态。

---

## 3 车载自动播放（`CarAudioAutoPlay`）

老板口径：「车载 car play，当连接车载蓝牙之后自动播放歌曲……可以接着上次没播完的接着放，
如果上次没有放歌，那就自动选择热门歌单上的歌曲放」。

### 3.1 先划边界（不装作能做到）

| 想要 | 能不能 | 说明 |
|---|---|---|
| 车机屏上出现我们的界面 | ❌ | 真 CarPlay 要 Apple 单独审批的 `com.apple.developer.carplay-audio`，自签分发拿不到 |
| 连上**车载蓝牙 / 车机**就自动开播 | ✅ | 本轮做的就是这个（行为一致，只是没有车机 UI） |
| 进程被上滑杀掉后连车自动响 | ❌ | iOS 不会为一个音频 App 的蓝牙事件冷启动进程；要先打开一次 App |
| 拔掉 / 断开自动暂停 | ✅ | 一直是既有行为（`NowPlayingCenter` 的 `oldDeviceUnavailable`），本轮顺带把断点落盘 |

### 3.2 判定（纯函数，CI 钉住）

`CarAudioRules.shouldAutoplay(enabled:isPlaying:kind:)`：

- 端口 **车机**（`AVAudioSession.Port.carAudio`，有线/无线 CarPlay、USB 车机）或 **蓝牙音频**
  （`.bluetoothA2DP` / `.bluetoothHFP` / `.bluetoothLE`，车载蓝牙走这一类）→ 算"车里"；
- USB 声卡（`.usbAudio`）、外放/耳机 → 不算（在电脑前插个声卡不该自己放歌）；
- **正在播时不动**（只是换了个输出，重头播就是 bug）；开关关掉一律不动。

### 3.3 播什么

1. 刚才只是暂停（App 一直活着）→ 接着当前这首的原位置继续（`player.toggle()`）；
2. 否则读**上次播放快照**（`PlaybackSnapshotStore`）：
   `PlaybackRestoreRules.shouldResume` 要求"播过 ≥3 秒、离结尾还 ≥8 秒、上一轮不是自然播完"，
   满足就从断点续播（`play(queue:startAt:positionSeconds:)`，seek 等 `readyToPlay` 才发）；
3. 没有快照 / 上一轮已经播完 → 放**热门**（`DiscoverFeed.hotSongs`，酷我官方热歌榜；
   没加载过就 `loadHotIfNeeded()`）。

快照存在 UserDefaults（键 `last_playback_snapshot_v1`）：当前这首 + **往后最多 50 首** + 位置 + 时长。
写入时机：起播、换歌、每 10 秒、暂停、播完（标 `finished`）、退到后台、断开音频设备。
队列尾巴不存是为了让快照保持在几 KB。

### 3.4 会话口径（决定了灵不灵）

iOS 的路由变更通知基本只在音频会话**激活过**之后才送到 App，而"连上车机"恰恰是"这次还没播"的时候。
所以 `CarAudioAutoPlay.attach`（根视图出现时）就 `setCategory(.playback)` + `setActive(true)`，
但带 **`.mixWithOthers`**：不打断别人正在放的歌；真正起播时 `NowPlayingCenter` 会重新配成独占 `.playback`。

---

## 4 保存位置可配（`DownloadLocation` + `DownloadLocationSheet`）

- **默认**仍是 `Documents/Music`（「文件 › JZ 音乐 › Music」可见，靠 Info.plist 的
  `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`）。升级后老用户看到的行为不变；
  `downloads.json` 里存的是绝对路径，已下好的文件不动。
- 设置页「保存位置」那一行显示的是**整条面包屑**（`文件 › JZ 音乐 › Music`、`iCloud Drive › 我的音乐`
  或 `文件 › 别处 › 子目录`），下面另有一行**绝对路径**小字；不再是只写一个 `Music`。
- 点进「保存位置」页（`DownloadLocationView`）：**列出「文件 › JZ 音乐」下已有的文件夹**（默认 `Music`
  在最前），点一下选中 → 点 **「保存」** 立刻生效；要新名字就「新建文件夹…」（输入名字 → 创建并保存）；
  「恢复默认」也在这一页。
- **为什么不用系统文件夹选择器**：老板真机录屏里，系统选择器右上角「打开」按下去**连关都不关**，
  是他自己手动关掉的——那个选择器在这台机器上压根没有完成选择，修我们的回调也没用。
  所以改成 App 内确定能成的路径（建在 App 自己的 Documents 下，永远有写权限，`文件` App 里也看得见）。
  旧版本真存成过的安全书签仍然有效，页面会显示它、也能一键恢复默认。
- 保存前做两道把关：目录**能建**、**真写一个探针文件再删掉**（`DownloadLocation.isWritable`）——
  写不进去会当场弹提示，而不是等下载完才发现。
- 书签解不开 / 目录被删被移走 → 自动退回默认目录（不崩、不往坏路径里写），页面显示一行橙色提示。
- 外部目录在进程内**保持打开**（`DownloadLocation.openScope`，按目录去重）：
  下载落盘、旁车 `.lrc/.jpg` 写入、播放本地文件、删除都在这个作用域之内。
- 注意：**换位置只影响之后的下载**；已下好的歌还在原目录，播放/删除照旧靠 `localPath`。

---

## 5 验收（真机按这三条走）

1. **设置页**：只剩上表那些行；Stepper 改"可缓存歌曲数量"后杀掉 App 再进来还在；「已缓存」数字不变。
2. **车载**：手机已配对车机蓝牙 → 开车机 → 应自动开始放；上次听到一半的歌从断开的位置继续；
   若上次是听完的（或从没播过）→ 放热门。**正在播时**连车机不该重头播。拔掉（下车）自动暂停。
3. **保存位置**：设置页那一行显示整条路径 → 点进去 → 列表里选一个文件夹（或「新建文件夹…」输名字）→
   点「保存」→ 上面那行路径立刻变（绝对路径也对）→ 下首歌进那个文件夹（文件 App 能看到音频 + `.lrc` + `.jpg`）→
   「恢复默认」后新下载回到「JZ 音乐 › Music」。

---

## 6 已知未做

- 真车机 UI（CarPlay scene）——需要 Apple 审批的 entitlement，见 §3.1；
- 「清空所有单曲偏移」入口（老板要求下线；需要时可到播放页逐首归零）；
- 换保存位置时**搬走**已下载文件（现在只影响新下载，避免在后台搬大文件）。

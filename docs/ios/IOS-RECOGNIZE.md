# iOS 听歌识曲（P3）：麦克风 → 双通道指纹 → 统一打分 → 结果页

> 状态：**两条通道都已落码、CI 编译与纯逻辑断言通过**（2026-11-16）。**没有在真机上"对着音箱听过"**——本机是 Windows，没有设备。装机清单见 §6。
> 通道 1：酷狗（裸 PCM 上传）· 通道 2：网易（afp wasm 指纹，WKWebView 承载）

---

## 1 这一条链

```
点麦克风
  → 权限（AVAudioApplication.requestRecordPermission）
  → 暂停自己的播放（设置项 pauseBeforeRecognize）
  → AudioCapture：原生 48k/44.1k → AVAudioConverter → 8k 单声道 16bit LE
  → 6 秒先偷问一次酷狗（EARLY_SECONDS）──命中──▶ 提前收工
  → 没中：录满设置时长（12/15/20）→ 双通道并发：
        ├─ 酷狗：8k Int16 PCM 直接 POST（gateway.kugou.com 指纹接口）
        └─ 网易：8k Int16 → Float32 base64 → WKWebView 里 afp.wasm 出指纹
                → POST interface.music.163.com/api/music/audio/match
  → RecognizeScore.fuse（原唱标记 / 裸名 / 专辑 / 时长 / 位次 + 跨通道互证 +50）
  → 结果卡 + 「其他版本」（走现有跨平台搜索，播放也用它）
```

| 文件 | 职责 |
|---|---|
| [AudioCapture.swift](ios/JZMusicHelper/Services/AudioCapture.swift) | 麦克风采集与降采样、实时电平、结束时把音频会话还给播放 |
| [KugouRecognizer.swift](ios/JZMusicHelper/Services/KugouRecognizer.swift) | 酷狗协议 + 签名 + 解析 |
| [FingerprintPCM.swift](ios/JZMusicHelper/Services/FingerprintPCM.swift) | **纯函数**：Int16 → Float32 小端 base64（只取最后 12 秒） |
| [NeteaseFingerprint.swift](ios/JZMusicHelper/Services/NeteaseFingerprint.swift) | WKWebView 承载 `afp.wasm`，JS 桥取指纹；资源在 `ios/JZMusicHelper/Recognizer/` |
| [NeteaseRecognizer.swift](ios/JZMusicHelper/Services/NeteaseRecognizer.swift) | 网易协议 + **纯函数**解析（noMatchReason / result[]） |
| [RecognizeScore.swift](ios/JZMusicHelper/Services/RecognizeScore.swift) | **纯函数**打分与身份归并（CI 直接断言） |
| [RecognizeView.swift](ios/JZMusicHelper/Views/RecognizeView.swift) | 状态机、双通道并发、结果卡、其他版本、最近识过、1×1 指纹宿主 |

**为什么只有网易那一路要在端上算指纹**：酷狗接口收的就是裸 PCM，不需要本地指纹；网易要的是自家 afp 指纹（在 wasm 里算），所以那一路才需要 WKWebView。wasm 资源是从 `android/app/src/main/assets` **原样拷**过来的三个文件（约 397KB），由 `tools/ios/add_pbx_resources.py` 登记进 Resources 阶段——少一处就是运行时 `Bundle.main.url` 返回 nil（不报编译错，很难查）。

---

## 2 与 Android 的口径对照

| 能力 | Android | iOS | 是否等价 |
|---|---|---|---|
| 采样 | 原生采样率采集 → 降到 8k（v2.1.82 起） | 同（AVAudioEngine + AVAudioConverter） | ✅ |
| 时长档 | 12/15/20 秒，6 秒先问一次酷狗 | 同（`EARLY_SECONDS = 6`） | ✅ |
| 采集前暂停播放 | 有（设置项） | 同（`pauseBeforeRecognize`） | ✅ |
| 权限被拒 | 引导去系统设置 | 同（文案给到具体路径） | ✅ |
| 静音判定 | peakRms 阈值 | peak < 0.008 → "几乎没听到声音" | ✅ |
| 酷狗通道 | 裸 PCM + md5 签名 | 逐行移植 | ✅ |
| 网易通道 | WebView 跑 afp.wasm | WKWebView 跑同一份 wasm，JS 桥同名（`AndroidBridge.onResult`） | ✅ |
| 打分 | `RecognizeScore.fuse`（8 条加权） | 逐条移植 | ✅ |
| 结果 | 结果卡 + 其他版本 + 最近识过 | 同 | ✅ |

---

## 3 打分口径（截图里的「识别依据」就来自它）

```
单条候选：
  is_original   1 → +45   2（翻唱/他人版本）→ −30   4（原唱但非该录音室版）→ −8
  歌名裸名       是 → +12   不是（带 Live/DJ/伴奏…）→ −35
  专辑          正式独立专辑 +15；同名合集 −20；现场/综艺 −28；无专辑 −8
  时长          30s–30min → +4
  通道内位次     7 − 2×rank（第 1 条 +7，第 5 条 0）
  网易多给的元数据 +2
身份级：
  两通道命中同一身份（核心歌名 + 第一歌手）+50
  同歌手 ≥2 张正式专辑且时长互差 ≤3s +22
```

排序：分数 → 原唱标记 → 标题更短 → 通道位次 → 酷狗优先。
界面那行「识别依据：酷狗 83 ／ 网易 40 → 双通道互证」就是 `bestByChannel` + `note` 的直接呈现。

---

## 4 已知取舍

1. **网易通道要等满 11 秒才发**：它的指纹窗口是 12 秒，喂 8 秒会被服务端判 `noMatchReason=10`。所以"6 秒提前收工"只走酷狗；酷狗没对上才录满并叫网易——常见情况仍是 6~7 秒出结果。
2. **采集用 `measurement` 模式**：关掉大部分 AGC/降噪（Android 选 `VOICE_RECOGNITION` 是同一目的）。副作用是安静环境下底噪更明显，但音乐不会被削平。
3. **不保存录音**：PCM 只在内存里，识别完即释放；权限文案里也写明"不保存、不上传"。
4. **结果歌不保证能播**：指纹通道只给"歌名 + 歌手"，能不能出声音仍由现有跨平台取流链决定；播放按钮点下去失败会走播放层原有的状态行。
5. **「其他版本」最多 6 条**：按"裸名 + 同歌手"优先。`原唱` 标记只在同时满足这两条时给——与 Android v2.1.94 的口径一致（不是歌手对上就算原唱）。

---

## 5 验证边界

| 验证 | 手段 | 结果 |
|---|---|---|
| 打分与身份归并 | CI `logic-tests` | ✅ 22 条断言（run #43830848168） |
| 网易通道：Float32 输入 / 表单 / 响应解析 | CI `logic-tests` | ✅ 18 条断言（`section("网易通道…")`），全套 299 条全绿，run [#43831668767](https://github.com/thewonderfulkey/JZ-private-music-/actions/runs/43831668767) |
| 资源是否真进了包 | IPA 体积 1.00 MB → **1.31 MB**（三个 wasm 资源约 397KB） | ✅ 说明 Resources 阶段登记生效 |
| **真机能不能听到、能不能识别** | ❌ 无设备 | **未验证**，见 §6 |

> 说法边界：这里没验证过麦克风、没验证过接口签名在真机上是否被接受、没验证过 WKWebView 里那份 wasm 能不能编译出指纹。签名与指纹参数都是照 Android 逐行搬的，但**第一次装机必须实测**。

---

## 6 装机要试的 6 件事

1. 首次点麦克风 → 系统弹权限 → 允许后开始倒数（12 秒档）。
2. 手机放在外放音箱前 1 米，放一首常见歌 → **6~9 秒内**应出结果（不用等满 12 秒）。
3. 结果显示歌名 + 歌手 + 「识别依据：酷狗 <分数> ／ 网易 <分数> → 双通道互证」（只有一家命中时写「采用酷狗/采用网易」）。
4. 点结果右侧播放键 → 出声（走跨平台取流）。
5. 「其他版本」里应有同名不同版本，原唱那条带朱砂「原唱」标记。
6. 安静环境点麦克风（没人放歌）→ 应提示"几乎没听到声音…"或"这次没听出来"，**不能一直转圈**。

任何一条不符，把现象告我，我按这条链定位（采集 / 签名 / 解析 / 打分 / 解析成可播源）。

---

## 7 后续

| 顺序 | 内容 | 为什么 |
|---|---|---|
| **下一步** | P4 系统面：Live Activity（锁屏歌词/灵动岛）+ Widget + App Intents + 分享 | 自签版能直接用的 iOS 独占体验 |
| 之后 | P5 打磨（VoiceOver / Dynamic Type / iPad / 性能）+ 收尾项（队列追加、下载播本地文件、设置开关被引擎消费） | 交付前最后一遍 |


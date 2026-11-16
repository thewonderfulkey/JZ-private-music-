# iOS 网络层：实现、实测与与 Android 的差异

> 状态：**已落码、已通过 CI 编译与逻辑自测**（2026-11-16）。
> 这一层只做「搜得到 + 取得到 + 音质说实话」，没有 UI（P0 的骨架在下一步）。
> 相关：[IOS-FEATURE-PARITY.md](IOS-FEATURE-PARITY.md)（功能口径）、[IOS-ROLLOUT.md](IOS-ROLLOUT.md)（分期与验收）。

---

## 1 文件与职责

| 文件 | 职责 | 对应 Android |
|---|---|---|
| `Models/Song.swift` | `Song`（平台/ID/歌名/歌手/专辑/时长/封面）+ `durationSec` + `searchKeywordCompact` | `model/Model.kt` |
| `Models/DownloadItem.swift` | `StreamSource`（+`directId`/`kbps`/`totalBytes`）、`DownloadItem` | 同文件 |
| `Services/APIClient.swift` | 统一 GET（UA / Referer / Accept / 超时）、文本与 JSON、`URLSession.bytes` 的 Range 探测底座、`withTimeoutOrNil` | `ApiClient.kt` |
| `Services/SearchAdapters.swift` | 四平台搜索（QQ / 网易 / 酷我 / 酷狗） | `SearchAdapters.kt` |
| `Services/SearchRanker.swift` | 跨平台全局排序（权重、平台位次先验、去重、稳定排序） | `SearchRanker.kt` |
| `Services/NameMatch.swift` | 歌名/歌手归一化匹配（跨源身份校验） | `NameMatch`（在 `SourceAdapters.kt` 末尾） |
| `Services/StudioPick.swift` | 录音室原唱优选（裸名 / 现场专辑 / 共识时长 / 单歌手） | `StudioPick.kt` |
| `Services/KuwoParser.swift` | 酷我 r.s 的 Python 单引号文本解析 + 相关性过滤 + `Pattern` 正则工厂 | 内嵌在 `KuwoSearchAdapter` |
| `Services/SourceAdapters.swift` | 5 个取流后端 + `StreamVerifier`（容器/体积探测）+ `QualityFacts`（真实档位）+ `UrlNormalizer` | `SourceAdapters.kt` |
| `Services/SearchService.swift` | 四平台并发搜索、单平台 8s 超时、绝不外抛、合并排序 | `SearchAndResolve.kt` 的 `SearchService` |
| `Services/URLResolver.swift` | `URLResolver`（单后端 12s）/ `SourcePicker` / `SameSongCrossResolver`（40s、8 候选、每批 3 条）/ `DownloadResolver.plan` | 同文件其余部分 |
| `SelfTest/main.swift` | 纯逻辑断言（不联网、不碰模拟器），CI 里 `swiftc` 直接跑 | Android 无对应物 |

依赖方向是单向的：`Models → APIClient → parser/ranker/picker → adapters → resolver`。没有 UIKit / SwiftUI 依赖，所以能被独立编译成命令行程序做回归。

---

## 2 实测结论（2026-11-16，本机直连）

跑法：`python tools/ios/probe_network.py "晴天 周杰伦"`（探针照 Android 的原样请求，输出真实容器与码率）

### 2.1 搜索

| 平台 | 结果 | 耗时 | 备注 |
|---|---|---|---|
| QQ | ✅ 20 条 | ~1.4s | 首条 晴 天 / 周杰伦 / 叶惠美 / 269s（口径正确） |
| 网易 | ✅ 20 条 | ~3.8s | 首条是 UGC「晴天 (原唱 周杰伦) / RyaVocal」，正是排序要压的类型 |
| 酷我 | ✅ 10 条（修好后） | ~2.4s | 原始 50 条→相关性过滤后剩 10；旧口径是 **0 条**（见 §3.1） |
| 酷狗 | ✅ 20 条 | ~3.0s | 宿主 `mobiles.kugou.com`（旧 `mobilecdn` 证书不匹配已弃用） |

### 2.2 取流

| 后端 | 结果 | 真实容器 / 码率 | 判定 |
|---|---|---|---|
| cyapi QQ | ✅ | m4a · **97kbps** · 3.28MB | 不命中 320k（与 Android 注释一致，按事实标"标准"） |
| gdstudio 网易 | ✅ | mp3 · **320kbps** · 10.83MB | 命中高品（诚实分档） |
| oiapi 网易 | ❌ code=0 但无 url | — | 通道当前失效（保留适配器，恢复时零改动） |
| 妖狐酷我 | ✅ | flac（22.7MB / 269s）；**直链是 http** | 见 §3.3：http→https 后同样可取 |
| 酷狗官方 playInfo | ❌ 200 但响应无 url | — | `errcode=0` 只回元数据；trackercdn 变体一律 `20028`。**酷狗当前"能搜不能播"**，由跨平台补位兜底 |

结论：**搜索四家全通；取流可用三家（QQ / 网易 / 酷我），酷狗靠跨平台补位**。这正是 Android v2.1.90 之前的真实处境，不是 iOS 特有缺陷。

---

## 3 有意的三处偏离（都写了理由，不是"顺手改"）

### 3.1 酷我相关性过滤：整串子串 → 词元匹配

Android v2.1.95 的过滤是「`歌名` 或 `歌手` 里包含**整个查询串**」。两词查询（"晴天 周杰伦"）里，歌名没有这六个字、歌手也没有 → 全被过滤 → **酷我恒 0 条**。
实测：`rn=50` 原始 50 条 / 旧口径 **0 条** / 全词命中 **14 条** / 任词命中 50 条。

iOS 口径：先取「**每个词都命中**（歌名+歌手拼一起查）」；一条都没有时退回「任一词命中」；仍为空才算不相关。既修掉 0 条，又保留"挡住无关 UGC"的初衷。有单测：`KuwoParser.relevantRecords`。

### 3.2 排序里「标题只是查询串一部分」的封顶：大小写不敏感

Android 是 `phrase.contains(title)`，而 `title` 已被 `uppercase()`——用户输小写时这条封顶永远不生效（"IVORY" 压过 "IVORY TOWER" 的已知问题）。iOS 改成大小写不敏感，行为只在"本该封顶却没封顶"时变化。

### 3.3 不开 ATS 例外，改为 http → https 升级

Android 为了让酷狗证书不匹配的域名能用，OkHttp 里对该域名放行了 hostname 校验。iOS **不做**这种例外（HIG / 安全最差实践），并且把 ATS 保持严格（`Info.plist` 里 `NSAllowsArbitraryLoads` 已删）。

代价是：妖狐酷我返回的直链是 `http://car-lw.kuwo.cn/...`，严格 ATS 下播不了。
实测同一个 URL 换成 `https://` 一样可取（206 / `audio/x-flac` / 22.7MB），所以 `UrlNormalizer.upgraded` 统一把 `http://` 升成 `https://`，升级后取不到的源按"不可用"处理。

---

## 4 验证方式（本机没有 Swift 工具链，所以靠两处）

1. **CI 逻辑自测**（`.github/workflows/ios-ipa.yml` 的 `logic-tests` job）：`swiftc` 把网络层 + `ios/SelfTest/main.swift` 编成命令行程序直接跑，不联网、不碰模拟器，约 1 分钟。断言覆盖：
   - 排序：裸名 vs (Live)、平台位次先验、同分平台优先级、稳定排序、同 ID 去重、专辑维度、长查询封顶
   - 原唱：裸名判定、现场专辑、共识时长、按核心名归并、录音室版胜出
   - 身份校验：多歌手串、版本后缀、不同歌不匹配、妖狐标题切分
   - 音质：容器头识别（flac/ogg/m4a/mp3/wav/html）、97kbps→标准、320kbps→高品、flac→无损、kbps=0 不命中、区间边界 255/256/600/601
   - 酷我解析：新旧字段、`MUSIC_` 前缀、秒数与 `mm:ss`、HTML 实体、转义单引号、引号内逗号不切分、**两词查询不再 0 条**
   - 挑源与目标档：无损优先、高品优先 ID 直连、`isExact` 的容器+码率口径
2. **整包编译**：同一 workflow 的 `build-ipa` job 用 `xcodebuild`（iOS 17 target、device arm64）编真机包，等于把整套 UI + 网络层一起过一遍类型检查。

现状：`logic-tests` ✅ 全绿；`build-ipa` ✅ BUILD SUCCEEDED（未签名 IPA 已出）。

> 本地只有 Windows，无法 `swiftc`/`xcodebuild`；所以**不要**在本地声称"编过了"。改完这一层就推一次，看 Actions。

---

## 5 这一层还没做的（P1/P3 的事）

| 缺什么 | 归属 | 说明 |
|---|---|---|
| 歌词（酷我官方 / LDDC 双源 / KRC·QRC 逐字解密 / 繁转简） | P1 | Android 有 `LddcCrypto.kt`（303 行）与 `LddcMatch.kt`（219 行），移植量大，单独做 |
| 识曲双通道 + 打分 | P3 | 酷狗指纹（PCM + 签名）、网易（WKWebView + afp.wasm）、`RecognizeScore` 权重 |
| 下载落盘 / 后台 URLSession / 95% 体积校验 / 文件 App | P2 | 现有 `DownloadManager.swift` 仍是原型级，要按 `DownloadResolver.plan` 重写 |
| 播放与锁屏 | P1 | `AVAudioSession` + `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` |
| 音源详情页需要的数据 | P2 | 现在已能拿到"后端名 / 真实容器 / 真实码率 / 直连或搜索式"，够画 §3.5 那个页面 |

---

## 6 维护提示

- 接口挂了先跑 `python tools/ios/probe_network.py`，它会把「哪家搜索空 / 哪个后端没 URL / 真实码率变成多少」直接打出来。
- 改排序权重、原唱判定、码率区间、酷我过滤这类"数字口径"，**必须**同步改 `ios/SelfTest/main.swift`，CI 会拦。
- 新增一条 pbxproj 文件引用时不要手写 ID：用 `tools/ios/add_pbx_files.py` 的思路（按已占用 ID 动态分配），否则会和 `F…13`（Info.plist）、`F…14`（app）撞车——这个坑已经踩过一次。

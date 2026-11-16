# iOS 落地说明：系统集成、权限、审核风险与分期

> 配套：[IOS-UI-DESIGN.md](IOS-UI-DESIGN.md)、[IOS-IA-SCREENS.md](IOS-IA-SCREENS.md)、[IOS-FEATURE-PARITY.md](IOS-FEATURE-PARITY.md)。
> 本文只回答"要开工还缺什么"：系统能力清单、Info.plist / 能力开关、审核风险、分发、分期与验收。**仍不写代码。**

---

## 0 已拍板（2026-11-16，老板确认）

设计评审后三个开放问题已定，下文按此口径写死，不再保留"二选一"：

| # | 决定 | 落地影响 |
|---|---|---|
| 1 | **最低系统版本 = iOS 17.0** | 可用 `@Observable`、`ContentUnavailableView`、`scrollPosition`、`onChange(of:initial:)`；**不再写 iOS 16 兼容分支**。Live Activity 本身 16.1+，基线取 17 后无降级方案需要做。`matchedTransitionSource` / `.navigationTransition(.zoom)` 属 iOS 18，仍按"有则用、无则系统默认 sheet 上滑"写。 |
| 2 | **分发方式 = 自签（不受 App Store 审核约束），下载功能进 v1** | 下载留在 P2、按原设计做完整（三档音质 + 换源 + 体积校验 + 后台下载 + 文件 App 可见）。§3 的审核风险降级为"知识储备"（哪天要上架再看），不阻塞任何一期。 |
| 3 | **信息架构保持当前方案** | 5 Tab = 发现 / 搜索 / 识曲 / 下载 / 资料库；设置进资料库右上；识曲占 Tab。不再准备第二套 IA。 |

---

## 1 系统能力清单（设计依赖）

| 能力 | 用途 | 最低系统 | 需要的声明 |
|---|---|---|---|
| **App 基线** | 全部 | **iOS 17.0**（已定，见 §0） | `IPHONEOS_DEPLOYMENT_TARGET = 17.0` |
| 后台音频 | 锁屏/后台继续播放 | iOS 13+ | `UIBackgroundModes = [audio]`，`AVAudioSession.category = .playback` |
| Now Playing / 锁屏 / 耳机键 | 播放控制、锁屏信息 | iOS 13+ | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`（无需声明） |
| 后台下载 | 下载不被切后台打断 | iOS 13+ | `URLSessionConfiguration.background` + App Delegate 回调 |
| 麦克风采集 | 识曲 | iOS 13+ | `NSMicrophoneUsageDescription` + 运行时 `AVAudioSession.requestRecordPermission` |
| 实时活动（Live Activity） | 锁屏歌词 / 灵动岛 | 能力 16.1+，本项目基线 17 | `NSSupportsLiveActivities = YES`，ActivityKit，需在 Info.plist 提供 `NSSupportsLiveActivitiesFrequentUpdates`（若要逐字刷新） |
| 灵动岛 | 紧凑/展开/最小三态 | iPhone 14 Pro+ | 随 Live Activity 自动获得 |
| Widget | 主屏/锁屏小组件 | iOS 17（锁屏组件 16+） | WidgetKit extension，`App Group` 共享数据 |
| App Intents / 快捷指令 | 识曲、播放收藏 | iOS 17 | App Intents extension 或主 App 内定义 |
| 文件 App 可见 | 下载目录 | iOS 11+ | `UIFileSharingEnabled = YES` + `LSSupportsOpeningDocumentsInPlace = YES` |
| AirPlay | 投到音响 | 系统 | `AVRoutePickerView`（无需声明） |
| 分享导出 | 分享歌曲/文件 | 系统 | `ShareLink` |
| 聚焦索引 | 搜歌直达 | iOS 13+ | `CoreSpotlight` |

**设计上的取舍（要写进产品说明）**
- **基线 iOS 17**：低于 17 的设备不提供安装包（自签本来就只装自己的设备，没有覆盖率压力）。这条写进安装说明，避免"我手机 15.7 装不上"的疑问。
- 不做 CarPlay：需要单独 entitlement 与苹果审批，且本项目没有导航/语音场景，收益低。**明确写进"iOS 不做"清单**。
- 不做 Apple Watch App（v1）；不做 iCloud 同步（v1 数据都在本机，与 Android 一致——Android 也没有云同步）。

---

## 2 Info.plist 与工程能力（设计评审通过后再动）

| Key | 值（中文文案已定稿） |
|---|---|
| `NSMicrophoneUsageDescription` | 识别你正在听的歌时需要使用麦克风，只采集几秒环境音，录音不会保存，也不会上传。 |
| `UIBackgroundModes` | `audio` |
| `NSSupportsLiveActivities` | `YES` |
| `NSSupportsLiveActivitiesFrequentUpdates` | `YES`（逐字歌词需要；若审核/功耗有问题则降级为整行） |
| `UIFileSharingEnabled` | `YES` |
| `LSSupportsOpeningDocumentsInPlace` | `YES` |
| `CFBundleDisplayName` |（2026-11-16 已落地：App 内 Info.plist 已是 `JZ 音乐`；图标已换成耳机版 1024 不透明 PNG，sha256 `46e9f5e5…`）**JZ 音乐**（与安卓「JZ的音乐助手」故意区分：iOS 图标下只能显示 5–6 个字，「JZ的音乐助手」会被截成「JZ的音…」；定稿见 §0 的口径） |
| `UILaunchScreen` | 纸底色（`UIColorName = Paper`，用 Asset Catalog 的 Paper 颜色集）。**题字图暂未加**：需要一个 `题字.pdf/png` 资产，目前仓库里没有；等设计给图再补 `UIImageName` |
| `UIUserInterfaceStyle` | 不设（跟随系统；App 内再给「外观」三项） |
| `ITSAppUsesNonExemptEncryption` | `NO`（只做 HTTPS，无自研加密导出；但 KRC/QRC 解密是**解析**不是加密，需在审核说明里写清） |
| `LSApplicationQueriesSchemes` | 无（不检测其他 App） |
| `NSAppTransportSecurity` | 不加例外。**所有接口必须 HTTPS**；Android 侧若存在 http 直链（部分音源 http→https 已在上游替换），iOS 侧取流时若拿到 http 必须走 `AVURLAsset` 失败兜底换源，不允许开 ATS 全局放行 |

---

## 3 App Store 审核风险（已降级为"知识储备"，不阻塞开发）

**分发已定为自签（§0 第 2 条）**：不经过 App Store 审核，下列条款当前**不构成阻塞**。保留这张表的原因只有一个——哪天要上架 / 进 TestFlight 公测，这些是会被卡住的点，届时直接照着改：

| 风险 | 条款 | 具体表现 | 若上架时的应对 |
|---|---|---|---|
| **第三方曲库聚合 + 下载** | 5.2.3 知识产权 / 4.2 最低功能 | 聚合 QQ/网易/酷我/酷狗的取流与**下载**，可能被判定为"未经授权分发受版权保护内容" | ① 关于页声明：仅个人使用、版权归各平台、不托管内容；② 上架版把「下载」改为「导出到文件」或整块关掉（代码里用编译开关 `CLOUD_DISTRIBUTION` 隔离，自签版保持完整）；③ 不把上架当目标 |
| 应用名含他人商标 | 5.2.1 | 界面与文案里出现「QQ 音乐 / 网易云 / 酷狗 / 酷我」 | 平台名仅作**来源标注**（事实性描述），不用其 logo、不用其主色；关于页写"平台名称归各自公司所有" |
| 从网络抓取接口 | 5.2.2 | 逆向签名（V6/V7 签名算法） | 不在 App 内展示接口地址与签名逻辑；不在商店描述里宣传"破解/绕过会员" |
| 麦克风 | 5.1.1 | 采环境音 | 使用说明写清"只采环境音、不保存、不上传"；首次使用前先应用内解释；不后台采集 |
| 后台下载+播放 | 2.5.4 | 后台模式滥用 | 只用于音频播放与用户发起的下载，不用于后台轮询 |
| 隐私标签 | App Privacy | 有网络请求、本地存储 | 不收集、不追踪、无广告 SDK；网络请求只到各平台接口（由用户发起）。**不接任何统计 SDK**（自签版同样遵守，降低日后上架成本） |
| 破解/绕过 | 5.2.1 | 音质档位、会员曲目 | 不宣称"解锁会员/无损破解"；音质档位描述为"取可用源里最好的一档" |

**结论**：v1 走**个人自签分发**（Sideloadly / AltStore / 爱思助手，CI 已有出未签名 IPA 的能力，见 [RELEASE.md §8](../RELEASE.md)）。因此上面这些是"将来上架才需要处理"的清单，**不是现在的设计约束**——下载、锁屏歌词、后台播放都按完整体验做。

---

## 4 分发与安装（自签，已定）

| 项 | 说明 |
|---|---|
| 产物 | `JZ-Music-v<版本>-ios-unsigned.ipa`，由 `.github/workflows/ios-ipa.yml` 在 `macos-15` 上产（仓库转 public 后 Actions 免费、不限次，见 [RELEASE.md §8](../RELEASE.md)） |
| 签名 | 用户侧用 **AltStore / Sideloadly / 爱思助手** 重签。免费 Apple ID 签名 **7 天到期**（AltStore 可在同一 Wi-Fi 下自动续签），付费开发者账号 **1 年** |
| 安装前提 | iOS 17.0+；无需越狱；设备上需信任描述文件 |
| 更新方式 | 覆盖安装即可（同一 bundle id + 同一签名证书才能覆盖；换证书会变成"两个 App"） |
| 已知限制（要写进 README） | ① 7 天/1 年到期后需重签，App 会打不开（不是数据丢失，重签即恢复）；② 未签名 IPA 不能被 iTunes / 爱思的"安装"直接吃，要用重签工具；③ 自签 App 的推送/后台刷新受限（本项目不依赖推送） |

---

## 4 分期（每期都能出可安装的包）

| 期 | 范围 | 产出 | 验收 |
|---|---|---|---|
| **P0 骨架** | 5 Tab + 资料库 + 设置 + 搜索（四平台）+ SongRow + 空态/加载/失败 | 能搜、能看结果、能进设置 | 搜索 20 个关键词无崩溃；375/393/430 三宽不破版 |
| **P1 播放**（引擎/系统面/歌词解密已完成；取词编排与歌词界面待补） | 三级解析 + Now Playing + 锁屏/耳机键 + Mini Player + 歌词 | 能完整听一首歌，锁屏可控，歌词跟着走 | 连续播 20 首无"静默失败"；无源时给明确文案；锁屏封面/进度正确；逐字歌词跟随播放位置 |
| **P2 下载**（已落码，待装机验收 · [IOS-DOWNLOADS.md](IOS-DOWNLOADS.md)） | 音质选择 + 后台下载 + 校验 + 下载页 + Files 可见 | 能下载并按档位校验 | 断网/切后台/杀进程三种情况都有正确状态；坏文件不会入库 |
| **P3 识曲** | 麦克风 + 双通道 + 打分 + 结果页 + 其他版本 + 最近识过 | 能识出原唱/翻唱 | 10 段真实样本，原唱判定与 Android 一致；无权限路径完整 |
| **P4 系统面** | Live Activity（锁屏歌词/灵动岛）+ Widget + App Intents + 分享 | iOS 独占体验 | 锁屏歌词跟随换行；灵动岛三态正常；功耗可接受（30 分钟播放耗电 <5%） |
| **P5 打磨** | 无障碍全流程 VoiceOver、Dynamic Type AX5、Dark Mode、iPad、性能 | 可交付自签包 | §5 验收表全绿 |

**工程顺序提醒**：P1 之前必须先落地 `AudioSession + NowPlaying + RemoteCommand` 三件套（否则"能播但锁屏不显示"会被误判为播放 bug）。

---

## 5 验收清单（HIG 视角，逐项打勾才算完成）

### 5.1 每页通用
- [ ] 375×667 / 393×852 / 430×932 / iPad 1024×1366 四宽均无截断
- [ ] 浅色 + 深色 + 增强对比度三种外观
- [ ] Dynamic Type 最大档（AX5）可用
- [ ] VoiceOver 可以从头到尾完成该页主任务
- [ ] 所有可点元素 ≥44×44pt
- [ ] 空/加载/失败/权限四态齐全
- [ ] 无硬编码字号/颜色（除 `paper`/`paperElevated`/`vermilion`）

### 5.2 关键流程（6 条必须实机走通）
1. 冷启动 → 搜「晴天」→ 点第一条 → 起播（<3s）→ 锁屏可见封面/进度 → 耳机双击下一首 → 回 App 状态一致。
2. 搜一首冷门歌 → 本平台无源 → 自动跨平台补位成功 → 音源详情页能看到"第 2 级补源"。
3. 断网播放 → 断网 → 提示"等待网络恢复"→ 恢复后自动续播（不跳歌）。
4. 下载无损 → 实际只拿到 320k → 明确告知"已按高品 320k 保存"→ 文件 App 能看到文件。
5. 识曲 → 外放一首 → 出结果 → 「识别依据」可见 → 点「其他版本」→ 原唱行有「原唱」标注。
6. 开启锁屏歌词 → 锁屏看歌词跟随 → 关闭 → 立刻恢复。

### 5.3 反例（必须不出现）
- 无源时"点了没反应"（必须有文案）。
- 加载中允许重复点击导致重复起播（需去重，与 Android `resolveAndPlayIfNeeded` 同口径）。
- 进度条跳动（时间标签必须等宽数字）。
- 收藏成功弹窗（应当只用状态变化 + 轻触觉）。
- 播放页打开后返回键/下滑关不掉且不停止音频。

---

## 6 与现有 iOS 原型的关系

现有 `ios/JZMusicHelper/`（17 个 Swift 文件，4 Tab，`JZMusicHelper.xcodeproj` 手写工程，CI 出未签名 IPA）**不是这份设计的实现**，而是"能否编译 + 能否出包"的探路件。落码时的处理：

| 现有文件 | 处置 |
|---|---|
| `JZMusicHelperApp.swift` / `MainTabView.swift` | 重写（5 Tab + 环境注入） |
| `SearchView.swift` / `DownloadsView.swift` / `SettingsView.swift` / `HistoryView.swift` | 按本设计重写；`SongRow` 抽取为共享组件 |
| `SongDetailView.swift` | 拆成「音源详情 Sheet」+「歌曲操作菜单」，不再有独立详情页 |
| `Services/*`（APIClient / SearchAdapters / SourceAdapters / URLResolver / DownloadManager / HistoryStore / PlayerManager） | **保留骨架并补齐**：这层是产品的实质（签名、适配器、解析链），值得逐行移植 |
| `Models/Song.swift` / `DownloadItem.swift` | 扩充字段（音质核实结果、后端名、容器、时长校验、来源级） |
| 新增 | NowPlaying、Lyrics、RecognizeScore、RecognizeAdapter、LiveActivity extension、Widget extension、AppIntents |

---

## 7 已拍板与对应开工口径

三个开放问题已于 2026-11-16 定下（见 §0）。这里只留"决定 → 开工时具体怎么做"的落点，避免以后又被重新讨论：

| 决定 | 开工时的硬约束 |
|---|---|
| 基线 iOS 17 | 工程 `IPHONEOS_DEPLOYMENT_TARGET = 17.0`；不写 `if #available(iOS 16…)` 分支；`@Observable` 做状态（不引 Combine/`ObservableObject`）；空态一律 `ContentUnavailableView`；iOS 18 的 `.navigationTransition(.zoom)` 用 `#available` 包一层并保留默认转场 |
| 自签 + 下载进 v1 | 下载按 P2 完整实现（三档 + 换源 + 95% 体积校验 + 后台 `URLSession` + 文件 App 可见）；上架相关的开关只留一个编译宏 `CLOUD_DISTRIBUTION`，默认关，代码里不进任何上架降级分支 |
| IA 保持现方案 | 5 Tab 固定：发现/搜索/识曲/下载/资料库；设置只出现在资料库右上；不做侧栏（iPad 也用顶部 Tab） |

---

## 8 设计产物清单

| 文件 | 内容 |
|---|---|
| [IOS-UI-DESIGN.md](IOS-UI-DESIGN.md) | 设计总纲：原则、品牌→系统映射、颜色/字体/间距/材质/动效/触觉/图标令牌、无障碍、现有原型自评（4/10 → 达标路径） |
| [IOS-IA-SCREENS.md](IOS-IA-SCREENS.md) | 5 Tab 信息架构 + 12 个逐页设计（布局图、交互表、五态、无障碍、iPad） |
| [IOS-FEATURE-PARITY.md](IOS-FEATURE-PARITY.md) | 132 条 APK 功能 → iOS 落点；Android 独有的 12 项替代方案；必须保留的技术口径 |
| [mockups/](mockups/) | 5 张 393×852 视觉稿（PNG）+ 可再渲染的 HTML 源 |
| [IOS-NETWORK.md](IOS-NETWORK.md) | **网络层已落码的实现与实测**：文件职责、四平台搜索/取流实测表（2026-11-16）、三处有意偏离 Android 的理由、CI 验证方式、还没做的部分 |
| [IOS-LYRICS.md](IOS-LYRICS.md) | **歌词（两段都已完成）**：KRC/QRC 解密与逐字解析、繁转简、LRC/清洗；LDDC 双源取词（评分 11 组向量比对、酷狗签名逐字节比对）、酷我官方、4h 缓存、播放页歌词态；两个 SDK 坑与验证边界 |
| [IOS-PLAYBACK.md](IOS-PLAYBACK.md) | **播放层（P1）**：引擎与三态循环、时长防线、无源跳歌、锁屏/耳机键/打断、迷你条与播放页；与 Android 的口径对照、已知取舍、验证边界、装机验收 6 步 |
| [IOS-DOWNLOADS.md](IOS-DOWNLOADS.md) | **下载层（P2）**：选档 → 三级换源 → 确认 → 后台下载 → 95% 体积校验；与 Android 的口径对照、五个取舍、装机验收 5 步 |
| 本文件 | 已拍板事项（§0）、系统能力、Info.plist、审核风险、分发与自签（§4）、分期、验收 |

---

## 9 P0 起跑清单（下一步要动的东西，按依赖排序）

设计已定稿，落码时第一批要建的文件/顺序（写入 `ios/JZMusicHelper/`，沿用现有 `.xcodeproj`）：

1. **工程配置**：`IPHONEOS_DEPLOYMENT_TARGET=17.0`、`Info.plist` 按 §2 补键、`UIBackgroundModes=audio`、`Assets.xcassets` 加 `paper` / `PaperElevated` / `AccentColor` 三个颜色集。
2. **设计令牌层**：`Theme/Tokens.swift`（颜色 3 个 + 字体角色映射 + 间距/圆角常量 + 触觉封装 `Haptics.swift`）。这是唯一允许出现数值的地方。
3. **模型与存储**：`Song` 扩字段（后端名/音质核实/容器/来源级）、`LibraryStore`（收藏/最近/搜索历史/识曲历史，上限 20/50/20/50）、`SettingsStore`（`@Observable`，键名见 parity §6–§9）。
4. **网络层移植**：`APIClient`（UA/Referer/超时）→ 四个 `SearchAdapter` → `SearchRanker`（权重照抄）→ `SourceRegistry` / `URLResolver`（三级链）→ `QualityProbe`（Range 4096 + kbps 换算）。**先不做 UI，用 20 个关键词跑通控制台输出**。
5. **外壳**：`RootTabView`（5 Tab）+ `MiniPlayer`（`safeAreaInset`）+ `SongRow` + `StatusLine` + 空态。
6. **五页骨架**：发现/搜索/识曲/下载/资料库 + 设置（先接真数据，识曲页先只有麦克风舞台与状态机）。

每步的验收：能编译、能在真机（或模拟器）上看到对应页面、没有硬编码颜色字号。


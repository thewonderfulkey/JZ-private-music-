# iOS 落地说明：系统集成、权限、审核风险与分期

> 配套：[IOS-UI-DESIGN.md](IOS-UI-DESIGN.md)、[IOS-IA-SCREENS.md](IOS-IA-SCREENS.md)、[IOS-FEATURE-PARITY.md](IOS-FEATURE-PARITY.md)。
> 本文只回答"要开工还缺什么"：系统能力清单、Info.plist / 能力开关、审核风险、分期与验收。**仍不写代码。**

---

## 1 系统能力清单（设计依赖）

| 能力 | 用途 | 最低系统 | 需要的声明 |
|---|---|---|---|
| 后台音频 | 锁屏/后台继续播放 | iOS 13+ | `UIBackgroundModes = [audio]`，`AVAudioSession.category = .playback` |
| Now Playing / 锁屏 / 耳机键 | 播放控制、锁屏信息 | iOS 13+ | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`（无需声明） |
| 后台下载 | 下载不被切后台打断 | iOS 13+ | `URLSessionConfiguration.background` + App Delegate 回调 |
| 麦克风采集 | 识曲 | iOS 13+ | `NSMicrophoneUsageDescription` + 运行时 `AVAudioSession.requestRecordPermission` |
| 实时活动（Live Activity） | 锁屏歌词 / 灵动岛 | iOS 16.1+ | `NSSupportsLiveActivities = YES`，ActivityKit，需在 Info.plist 提供 `NSSupportsLiveActivitiesFrequentUpdates`（若要逐字刷新） |
| 灵动岛 | 紧凑/展开/最小三态 | iPhone 14 Pro+ | 随 Live Activity 自动获得 |
| Widget | 主屏/锁屏小组件 | iOS 16+（锁屏） | WidgetKit extension，`App Group` 共享数据 |
| App Intents / 快捷指令 | 识曲、播放收藏 | iOS 16+ | App Intents extension 或主 App 内定义 |
| 文件 App 可见 | 下载目录 | iOS 11+ | `UIFileSharingEnabled = YES` + `LSSupportsOpeningDocumentsInPlace = YES` |
| AirPlay | 投到音响 | 系统 | `AVRoutePickerView`（无需声明） |
| 分享导出 | 分享歌曲/文件 | 系统 | `ShareLink` |
| 聚焦索引 | 搜歌直达 | iOS 13+ | `CoreSpotlight` |

**设计上的取舍（要写进产品说明）**
- iOS 16.1 是最低版本门槛（Live Activity）。若想覆盖更早设备 → 锁屏歌词降级为"只在 Now Playing 显示一行歌词"。
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
| `CFBundleDisplayName` | JZ 音乐（与 APK「JZ的音乐助手」保持一致，过长会截断） |
| `UILaunchScreen` | 纸底色 `#FAF8F3` + 题字图（静态） |
| `UIUserInterfaceStyle` | 不设（跟随系统；App 内再给「外观」三项） |
| `ITSAppUsesNonExemptEncryption` | `NO`（只做 HTTPS，无自研加密导出；但 KRC/QRC 解密是**解析**不是加密，需在审核说明里写清） |
| `LSApplicationQueriesSchemes` | 无（不检测其他 App） |
| `NSAppTransportSecurity` | 不加例外。**所有接口必须 HTTPS**；Android 侧若存在 http 直链（部分音源 http→https 已在上游替换），iOS 侧取流时若拿到 http 必须走 `AVURLAsset` 失败兜底换源，不允许开 ATS 全局放行 |

---

## 3 App Store 审核风险（这是本项目最大不确定性）

用 `apple-appstore-reviewer` 的口径先自查一遍：

| 风险 | 条款 | 具体表现 | 设计上的应对 |
|---|---|---|---|
| **第三方曲库聚合 + 下载** | 5.2.3 知识产权 / 4.2 最低功能 | 聚合 QQ/网易/酷我/酷狗的取流与**下载**，可能被判定为"未经授权分发受版权保护内容" | ① 设置「关于」明确声明：仅个人学习测试、内容版权归各平台、不提供内容托管；② **下载功能做成可选**（首启不默认开启？）——若被拒，保住"搜索 + 播放"主链路；③ 首选分发路径：**自签 IPA / AltStore / TestFlight 内测**，不把上架当 v1 目标 |
| 应用名含他人商标 | 5.2.1 | 界面与文案里出现「QQ 音乐 / 网易云 / 酷狗 / 酷我」 | 平台名仅作**来源标注**（事实性描述），不用其 logo、不用其主色；关于页写"平台名称归各自公司所有" |
| 从网络抓取接口 | 5.2.2 | 逆向签名（V6/V7 签名算法） | 不在 App 内展示接口地址与签名逻辑；不在商店描述里宣传"破解/绕过会员" |
| 麦克风 | 5.1.1 | 采环境音 | 使用说明写清"只采环境音、不保存、不上传"；首次使用前先应用内解释；不后台采集 |
| 后台下载+播放 | 2.5.4 | 后台模式滥用 | 只用于音频播放与用户发起的下载，不用于后台轮询 |
| 隐私标签 | App Privacy | 有网络请求、本地存储 | 标签口径：不收集、不追踪、无广告 SDK；网络请求只到各平台接口（由用户发起）。**不接任何统计 SDK** |
| 破解/绕过 | 5.2.1 | 音质档位、会员曲目 | 不宣称"解锁会员/无损破解"；音质档位描述为"取可用源里最好的一档" |

**结论**：v1 定位为**个人侧载**（Sideloadly/AltStore 自签，已有 CI 出未签名 IPA 的能力）；上架是 v2 的可选目标，且上架前建议先砍掉"下载"或改为"仅导出到文件"。这条要老板拍板，见 §7 待确认。

---

## 4 分期（每期都能出可安装的包）

| 期 | 范围 | 产出 | 验收 |
|---|---|---|---|
| **P0 骨架** | 5 Tab + 资料库 + 设置 + 搜索（四平台）+ SongRow + 空态/加载/失败 | 能搜、能看结果、能进设置 | 搜索 20 个关键词无崩溃；375/393/430 三宽不破版 |
| **P1 播放** | 三级解析 + Now Playing + 歌词 + 锁屏/耳机键 + Mini Player + 队列 | 能完整听一首歌，锁屏可控 | 连续播 20 首无"静默失败"；无源时给明确文案；锁屏封面/进度正确 |
| **P2 下载** | 音质选择 + 后台下载 + 校验 + 下载页 + Files 可见 | 能下载并按档位校验 | 断网/切后台/杀进程三种情况都有正确状态；坏文件不会入库 |
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

## 7 需要老板拍板的三件事

1. **最低系统版本**：iOS 16.1（有锁屏歌词/灵动岛）还是 iOS 17（`@Observable`、更简单的状态管理，但放弃 16.1 设备）？
   *建议 iOS 17：本项目只有自用/小范围侧载，设备基数不是问题，代码显著更干净。*
2. **下载功能是否进入 v1**：它是审核最大风险点，也是产品卖点。
   *建议：自签分发 → 进 v1；若要上架 → v1 先砍下载，加"导出到文件"替代。*
3. **识曲 Tab 的位置**：顶部 Tab 已满 5 格。若你更希望「设置」占一格、识曲收进发现页卡片 + 控制中心，我可以给第二套 IA。**当前方案：识曲占 Tab，设置进资料库右上。**

---

## 8 设计产物清单

| 文件 | 内容 |
|---|---|
| [IOS-UI-DESIGN.md](IOS-UI-DESIGN.md) | 设计总纲：原则、品牌→系统映射、颜色/字体/间距/材质/动效/触觉/图标令牌、无障碍、现有原型自评（4/10 → 达标路径） |
| [IOS-IA-SCREENS.md](IOS-IA-SCREENS.md) | 5 Tab 信息架构 + 12 个逐页设计（布局图、交互表、五态、无障碍、iPad） |
| [IOS-FEATURE-PARITY.md](IOS-FEATURE-PARITY.md) | 132 条 APK 功能 → iOS 落点；Android 独有的 12 项替代方案；必须保留的技术口径 |
| [mockups/](mockups/) | 5 张 393×852 视觉稿（PNG）+ 可再渲染的 HTML 源 |
| 本文件 | 系统能力、Info.plist、审核风险、分期、验收、待拍板事项 |

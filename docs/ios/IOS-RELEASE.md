# iOS 交付总表（P0–P5 收官）

> 最后更新：2026-11-16。这份文件是**索引**：每一期做了什么、口径写在哪份文档、对应的可装包是哪个构建戳。
> 一条总边界先说清：**开发机是 Windows，没有 iPhone / 模拟器**。所以所有"能不能出声 / 能不能被识别 /
> 锁屏长什么样 / AX5 排版有没有崩"都还是**未验证**——每一期文档都写了装机清单，按页验。

---

## 1 分期状态

| 期 | 内容 | 状态 | 口径文档 |
|---|---|---|---|
| **P0** 骨架 | 5 Tab（发现/搜索/识曲/下载/资料库）+ 设置 + 设计令牌 + 空/加载/失败态 | ✅ | [P0-SHELL.md](P0-SHELL.md) |
| **P1** 播放 | 引擎、三态循环、时长防线、无源跳歌、锁屏/耳机键/打断、逐字歌词 | ✅ | [IOS-PLAYBACK.md](IOS-PLAYBACK.md)、[IOS-LYRICS.md](IOS-LYRICS.md) |
| **P2** 下载 | 选档 → 三级换源 → 确认 → 后台下载 → 95% 体积校验 → 文件 App 可见 | ✅ | [IOS-DOWNLOADS.md](IOS-DOWNLOADS.md) |
| **P3** 识曲 | 麦克风采集（原生率→8k）→ 酷狗 PCM / 网易 afp 指纹双通道 → 8 条加权统一打分 → 结果页 + 其他版本 | ✅ | [IOS-RECOGNIZE.md](IOS-RECOGNIZE.md) |
| **P4** 系统面 | 分享（ShareLink）、三个 App Intents、Widget 扩展（今日精选）、Live Activity（锁屏歌词 / 灵动岛） | ✅ | [IOS-SYSTEM.md](IOS-SYSTEM.md) |
| **P5** 打磨 | VoiceOver 标签、Dynamic Type（行高/语义字体）、iPad 单列 700、封面内存缓存 | ✅ | [IOS-POLISH.md](IOS-POLISH.md) |
| 收尾 | 队列追加（播放全部补满）、下载列表播本地文件、设置四开关生效、编辑精选按新旧轮换 | ✅ | [IOS-CLOSEOUT.md](IOS-CLOSEOUT.md) |

---

## 2 构建戳 → 功能对照（认文件名里的 `sha7-rNN`）

| 构建戳 | commit | 这一包多了什么 |
|---|---|---|
| `r38` | `b753b89` | P3 酷狗通道（麦克风 → PCM → 打分 → 结果页） |
| `r39` | `5817608` | 网易 afp 指纹通道（WKWebView 跑 wasm）+ 双通道互证 |
| `r40` | `8901b18` | 收尾四项 |
| `r41` | `019f58d` | 分享 + 三个 App Intents + AppRouter |
| `r44` | `006a1fb` | **Widget 扩展目标**（IPA 里出现 `PlugIns/JZWidgets.appex`） |
| `r45` | `98846b3` | 加"插件必须嵌入"的 CI 门禁 |
| `r46` | `5b9fb7b` | Live Activity（锁屏歌词 / 灵动岛三态） |
| `r47` | `650a8e1` | P5 打磨（当前最新可装包） |

装之前**核对文件名里的构建戳**：版本号 v2.1.95 是从 Android 的 `versionName` 读的，不会随 iOS 提交变化。
自签方式与 7 天/1 年有效期见 [IOS-ROLLOUT.md](IOS-ROLLOUT.md) §4。

---

## 3 CI 的四道门（每轮都过）

| 门 | 脚本/步骤 | 拦什么 |
|---|---|---|
| 逻辑断言 | `ios/SelfTest/main.swift`（swiftc 直跑） | **346 条**：排序权重、原唱判定、码率区间、歌词解密、识曲打分、下载校验、版式规则… |
| 工程结构 | `tools/ios/check_pbxproj.py` | 括号平衡、引用了不存在的对象、target 缺字段、phase 没挂上 target |
| 界面卫生 | `tools/ios/check_ui_hygiene.py` | 文本用硬编码字号（不跟随 Dynamic Type）、含文字块用固定行高 |
| 扩展嵌入 | `unzip -l` 看 `PlugIns/*.appex` | copy phase 漏挂也会 BUILD SUCCEEDED，这一道专门拦它 |

构建通过后 IPA 自动发飞书群，文件名带构建戳（见 §2）。

---

## 4 装机验收总清单（按顺序过一遍）

1. **冷启动** → 搜「晴天」→ 点第一条 3 秒内出声 → 锁屏有封面/进度 → 耳机双击下一首（[IOS-PLAYBACK.md](IOS-PLAYBACK.md) §6）
2. **换源** → 搜一首冷门歌，本平台无源时应看到"换源/跳歌"文案，不是点了没反应
3. **识曲** → 外放一首常见歌，6~9 秒出结果；「识别依据」应出现两家分数或"采用酷狗"（[IOS-RECOGNIZE.md](IOS-RECOGNIZE.md) §6）
4. **下载** → 播放页下载 → 选无损 → 确认页写明档位与体积 → 下完在「文件」App 能看到（[IOS-DOWNLOADS.md](IOS-DOWNLOADS.md) §6）
5. **离线** → 飞行模式下点已下载的歌应能播（状态行「本地文件 · …」）
6. **发现页** → 4 张分类卡可点开、20 首能逐首播；「播放全部」队列会补满（[IOS-DISCOVER.md](IOS-DISCOVER.md) §6、[IOS-CLOSEOUT.md](IOS-CLOSEOUT.md) §6）
7. **系统面** → 快捷指令里能看到三个动作；主屏能加「今日精选」组件；锁屏活动随播放/切歌变化（[IOS-SYSTEM.md](IOS-SYSTEM.md) §6）
8. **可达性** → AX5 最大字号不截断；VoiceOver 能从发现页走到播放页（[IOS-POLISH.md](IOS-POLISH.md) §6）

---

## 5 已知未做 / 明确不做

| 项 | 状态 | 原因 |
|---|---|---|
| **真机验证** | ❌ 全部未验 | 开发机是 Windows，没有 iPhone 与模拟器；这是这份交付**唯一缺的一环**，也是所有文档反复标注的边界 |
| 播放队列页（设计稿 §3.12） | 未做 | 引擎内部有队列，缺一个"看一眼队列"的界面；优先级低于系统面 |
| 下一首预取（落盘 3 首） | 未做 | AVPlayer 边下边播够用，省流量优先 |
| 发现页 DynamicPool 完整版 | 简版 | 只做"最久没展示优先 + 展示记日"，不做"每日从搜索结果注入 2000 条池子" |
| 网易逐字歌词上锁屏 | 未做 | 当前按行更新（`NSSupportsLiveActivitiesFrequentUpdates` 已开，随时可加强） |
| 无缝/淡入淡出切歌、倍速、均衡器 | 明确不做 | 与 Android 一致，Android 也没有 |

---

## 6 这套东西是怎么验的（给下一位接手的人）

- **能离线判定的全部进了 CI**：纯函数（排序/打分/校验/版式）→ 346 条断言；工程结构与界面卫生 → 两个脚本门禁。
- **必须上机的都写成了清单**：每期文档的"装机要试的 N 件事"，按页列到"看到什么算对、看到什么算什么问题"。
- **每轮收尾都留了构建戳**：出问题时报"r47 上的哪一条不符"，就能直接对到功能和 commit，不用猜装的是哪一包。

# iOS 版 UI 设计总纲（设计令牌 · 视觉语言 · 动效 · 无障碍）

> 状态：**设计稿（未落码）**。本文件只定义"长什么样、为什么这样"，不写 SwiftUI 实现。
> 基线：Android v2.1.95（versionCode 153）全部用户可见功能，逐屏迁移；功能对照见 [IOS-FEATURE-PARITY.md](IOS-FEATURE-PARITY.md)。
> 依据：Apple Human Interface Guidelines（导航 / 字体 / 颜色 / 材质 / 手势 / 无障碍 / 图标）+ 本项目既有的纸墨语言（`android/.../ui/theme/AppTheme.kt`、[UI设计文档](../design/UI设计文档.md)）。

---

## 0 一句话概念

**「宣纸、墨、朱砂，装在一台 iOS 设备里」** —— 骨架 100% 用系统原生控件（TabView / NavigationStack / List / Sheet / ContextMenu / Materials），品牌只从三处渗出来：**纸底、墨色文字、朱砂一点**，再加两件"画"（封面、歌词）。

这条分工是全部设计争议的裁判标准：**任何"这个控件长得不像 iOS"的地方都必须删掉，任何"删掉后就不像 JZ"的地方才允许保留。**
按此口径，Android 版的手绘底栏墨印、方块朱砂播放钮、纸签弹层、毛笔题字、山水位图、水墨开场动画**全部不进 iOS 版**——它们的职能由系统控件 + 材质 + 动效替代（替代映射见 §7），品牌预算只留给颜色、字重与封面。
唯一的例外是**开屏**（2026-11-18 老板要求"按图标设计一个开屏动画"）：它不搬 Android 那套 5.3s 的山水，只让**图标自己戴上**——落笔、戴耳罩、出声三拍，1.72s、冷启动一次、点即跳过。理由与边界见 §2 与 §6.1。

---

## 1 设计原则（五条，按优先级）

| # | 原则 | 具体裁决 |
|---|---|---|
| 1 | **内容优先，chrome 退让** | 列表页面上没有卡片边框、没有分区块色、没有渐变底；只有纸底 + 发丝分隔线。装饰只允许出现在"没有内容可看"的地方（空态、启动页、关于页）。 |
| 2 | **系统控件优先，自定义控件必须有理由** | 搜索用 `.searchable`，设置用 `Form` + 原生 `Toggle/Picker`，动作入口用长按菜单与 `.swipeActions`，弹层用 `.sheet` / `.confirmationDialog`。禁止重画开关、滑块、分段控件、返回按钮。 |
| 3 | **一点朱砂** | 一屏只允许一处实心朱砂（主播放钮 / 主按钮 / 选中态），其余朱砂只做描边、小字、圆点。参考"出门前摘掉一件配饰"。 |
| 4 | **歌词是主角之一** | 播放页是全 App 唯一允许做"重"的地方：大幅封面、整屏歌词、封面取色的背景光晕。其他页面一律安静。 |
| 5 | **每个状态都要设计** | 每页必须给出 5 态：首屏空、加载、有数据、无源失败、权限/网络异常。只有"有数据"一态的设计不算完成。 |

### 明确不做的（"AI 味"/Android 味黑名单）

- ❌ 手绘/自绘控件（墨印方块 tab 指示器、朱砂方印播放钮、纸签卡片边框、自绘进度条凹槽）→ 用系统控件。
- ❌ 顶部品牌渐变条 + 大留白横幅（Android 首页的"渐变品牌区"）→ iOS 用大标题 + 横向 Carousel。
- ❌ 彩色状态圆点传达平台健康度（颜色单独承载语义）→ 改为文字 + 图标。
- ❌ 自绘 Toast → 用内联状态行 / `.alert` / 底部短暂提示条（仅"已收藏"这类无打断反馈）。
- ❌ 全套自定义字体铺满界面（Android 用霞鹜文楷铺全部文本）→ iOS 全系统字体，书法体只作图片资产。
- ❌ 卡片套卡片、紫色渐变、全大写 eyebrow、`A · B · C` 中点风格堆砌。

---

## 2 品牌 → 系统 的映射规则（最重要的一张表）

| 品牌资产 | Android 版做法 | iOS 版做法 | 理由 |
|---|---|---|---|
| 纸底 `#FAF8F3` | 每页铺 `PaperBrush` 垂直渐变 | **一处**自定义色 `Color.paper`（Asset Catalog，含暗色 `#0E0D0B`），仅用于页面与弹层背景（替代 `systemGroupedBackground`）；不再做渐变 | 自定义背景色是 HIG 允许的"app 身份"，渐变底会与系统材质打架 |
| 墨字 `#2E2A24` | `LocalPalette.text` | 一律 `Color(.label)` / `.secondaryLabel` / `.tertiaryLabel` | 语义色自动适配暗色、增强对比度、粗体文本 |
| 弱文字 `#746C60` | 自定义 `text3`（4.8:1） | `.tertiaryLabel`（系统已保证 4.5:1）；元数据用 `.footnote` + `.secondaryLabel` | 不必自造第三级灰 |
| 朱砂 `#B03A2E` | `accent` / `heartOn` | **App 强调色**：Asset Catalog `AccentColor`，浅色 `#B03A2E`（对纸底 5.4:1），暗色 `#FF8A76`（对 `#0E0D0B` 8.2:1） | 全局 tint，一处定义 |
| 霞鹜文楷 | 全局 `KaiTypography` | **不进 UI 文本**。仅打包为图片资产用于：启动页题字、关于页署名 | 系统字体才能吃到 Dynamic Type / 粗体文本 / 字距调整 |
| 毛笔题字「发现音乐」 | 文本渲染 | 静态图（PDF 矢量资产，**不参与** 无障碍朗读文字，`accessibilityLabel("发现音乐")`） | 装饰性字形 |
| 朱砂印章 | 10dp 旋转方印 | App 图标主体 + 空态/关于页的小图形（1 处） | 品牌符号，不做 UI 元素 |
| 山水位图 | 播放页 `ink_bg_player` | ❌ 不进。改用**封面取色的柔和光晕**（同 Apple Music） | 位图在 iOS 上会与小尺寸屏幕/暗色模式冲突 |
| 水墨开场动画 | 5.3s 自绘 Canvas 山水 | ❌ **不搬那一套**。改为「耳机标自己戴上」：落笔（头梁沿弧长出来）→ 戴上（两只耳罩自下弹入）→ 出声（朱砂声波 + 轻顶），1.72s、冷启动一次、点即跳过、减弱动效静态 0.65s。代码 `Views/SplashView.swift`，时间轴 `Services/SplashTimeline.swift`，预览 `mockups/splash-icon-v1.html`，分镜 `mockups/splash-frames.png` | iOS LaunchScreen 是系统静态截图、播不了动画，所以它是启动后的**覆盖层**；正因为起点是空白纸，第一拍才必须是"落笔"。超过 2s 的开场是首启流失点，故压到 1.72s |
| 自绘底栏 | 墨印滑动的 6 格 | 系统 `TabView`（5 格） | 见 [IOS-IA-SCREENS.md](IOS-IA-SCREENS.md) §1 |

---

## 3 颜色令牌

### 3.1 自定义只留三个

| Token | Light | Dark | 用法 | 对比度（已核算） |
|---|---|---|---|---|
| `paper`（纸） | `#FAF8F3` | `#0E0D0B` | 页面底、Sheet 底、Tab 栏材质的落底色 | — |
| `paperElevated`（纸·浮） | `#FFFDF8` | `#1B1916` | 分组列表行底、卡片、播放页信息层 | — |
| `vermilion`（朱砂 / AccentColor） | `#B03A2E` | `#FF8A76` | tint、主按钮、心形已收藏、进度已播、选中 | 5.4:1 / 8.2:1 |

> 落码时必须在这两个色值上跑 Xcode Accessibility Inspector 的对比度检查，两种外观 + `Increase Contrast` 各一次；数值达标才允许提交。

### 3.2 其余全部用语义色

| 用途 | 令牌 | 说明 |
|---|---|---|
| 主文字（歌名、标题） | `Color(.label)` | 不要写 `#2E2A24` |
| 次文字（歌手、专辑） | `Color(.secondaryLabel)` | |
| 元数据（时长、码率、平台） | `Color(.tertiaryLabel)` + `.footnote` | 弱化靠字号，不靠压颜色 |
| 分隔线 | `Color(.separator)` | 1px（`0.5pt` 下 hairline） |
| 分组底 | `Color(.systemGroupedBackground)` 或 `paper` | 二选一，同一页只用一种 |
| 行底 | `Color(.secondarySystemGroupedBackground)` 或 `paperElevated` | |
| 危险 / 删除 | `Color(.systemRed)` | 不用朱砂，避免与品牌色混淆 |
| 成功（下载完成） | `Color(.systemGreen)` | 只在图标与文字同时出现时用 |
| 警告（无源 / 权限） | `Color(.systemOrange)` | 必须配图标与文字 |

**规则**：朱砂**永不**表示"错误"。错误一律 `systemRed` + 图标。两者的红必须靠形状区分（朱砂只出现在圆/胶囊/实心按钮里）。

### 3.3 平台的"身份色"（克制版）

四家平台标签不能靠四种颜色区分（违反"不得只靠颜色传达信息"）。做法：**统一的墨色胶囊 + 平台文字**，仅在需要强调时用 12% 朱砂底：

```
[酷我]  [QQ]  [网易]  [酷狗]      ← 胶囊：.footnote .semibold，纸·浮底 + 发丝描边，墨字
```

平台健康度（搜索结果顶部）用文字 + 符号，不用彩色圆点：

```
酷我 12 · QQ 8 · 网易 0 · 酷狗 5        ← 有结果：次文字
酷我 12 · QQ 8 · 网易 暂无 · 酷狗 5     ← 无结果：tertiaryLabel
酷我 12 · QQ 超时 · 网易 —— · 酷狗 5    ← 失败：systemOrange + exclamationmark.triangle.fill 小图标
```

---

## 4 字体与排版

**全部使用系统字体**（SF Pro / 中文自动 PingFang SC）。下表是"角色 → Dynamic Type 样式"的唯一映射，禁止出现 `Font.system(size:)` 硬编码字号。

| 角色 | 样式 | 默认字号/行高 | 字重 | 备注 |
|---|---|---|---|---|
| 页面大标题 | `.largeTitle` | 34 / 41 | `.bold` | 发现、资料库、下载；随滚动收起 |
| 分区块标题（编辑精选等） | `.title3` | 20 / 25 | `.semibold` | 行内 `<` 标题 + 右侧动作 |
| 页面内小标题（导航栏内联） | `.headline` | 17 / 22 | `.semibold` | |
| 列表歌名 | `.body` | 17 / 22 | `.regular` | 单行截断，`truncationMode: .tail` |
| 列表副行（歌手 · 专辑） | `.subheadline` | 15 / 20 | `.regular` | `.secondaryLabel` |
| 元数据（时长、码率、平台） | `.footnote` | 13 / 18 | `.regular` | `.tertiaryLabel`；数字用 `.monospacedDigit()` |
| 按钮文字 | `.body` | 17 / 22 | `.semibold` | 系统按钮样式已含 |
| 播放页歌名 | `.title2` | 22 / 28 | `.bold` | 最多 2 行 |
| 播放页歌手 | `.title3` | 20 / 25 | `.regular` | `.secondaryLabel` |
| 歌词当前行 | `.title2` | 22 / 28 | `.bold` | 逐字高亮 |
| 歌词其他行 | `.body` | 17 / 22 | `.regular` | `.tertiaryLabel`，非当前行降不透明度到 55%，**不用 45%**（对比不足） |
| 全屏歌词（沉浸） | `.title` | 28 / 34 | `.bold` | 逐字播放模式 |
| 识曲结果歌名 | `.title` | 28 / 34 | `.bold` | |
| 数字时间 | `.footnote` | 13 / 18 | `.regular` | 必须 `.monospacedDigit()`，防止跳动 |
| Tab 栏标签 | 系统默认 | 10 | — | 不自定义 |

**排版纪律**
- 最小字号 11pt（仅限装饰），正文最小 `.footnote`。
- 中文行高比系统默认再放 4%（歌词区用 `.lineSpacing(4)`）。
- 所有可截断文本给 `lineLimit` + `truncationMode`，不靠省略号硬切。
- 数字（时长、进度、码率、条数）一律等宽数字。
- 支持 `.dynamicTypeSize(...DynamicTypeSize.accessibility3)` 上限测试：列表行变高、播放页封面缩小、横向 Carousel 卡片增高，**不允许出现重叠或截断**。

---

## 5 形状、间距、材质

### 5.1 圆角（连续圆角 `RoundedRectangle(cornerRadius:style: .continuous)`）

| 元素 | 圆角 |
|---|---|
| 列表封面缩略图（48pt） | 8 |
| 卡片封面 | 12 |
| 歌单/资料库头部大图 | 16 |
| 播放页封面 | 20（iPad 24） |
| Sheet | 系统默认（不加自定义） |
| 胶囊（平台标签、chip） | `.capsule` |
| 按钮 | 系统 `.bordered` / `.borderedProminent` 默认形状 |

### 5.2 间距（4pt 基数）

| 名称 | 值 | 用途 |
|---|---|---|
| 页边距 | 16（iPhone）/ 20（iPad 竖）/ 24（iPad 横） | 列表行内、区块 |
| 行内间隙 | 12 | 封面 ↔ 文字 |
| 网格间隙 | 8（横向）/ 16（纵向） | 猜你喜欢、编辑精选 |
| 区块间距 | 28 | 发现页模块之间 |
| 行高 | ≥44（可点区），歌曲行 60 | |
| 底部安全 | 内容列表额外 `.safeAreaInset` 让位 mini player（56）+ Tab 栏 | |

### 5.3 材质（只用系统材质）

| 表面 | 材质 |
|---|---|
| Tab 栏 | 自绘 58pt 纸底（`paper`）+ 0.5pt 顶部 `.08` 分割线；选中项是朱砂 10% 胶囊（不透明、不用 blur） |
| Mini Player 背景 | `.regularMaterial` + 1pt `.separator` 上边线，圆角 12，左右 8pt 内缩 |
| 播放页背景 | 封面取色 → `LinearGradient` + `.ultraThinMaterial` 叠层（暗色下用 `.thickMaterial` 保对比） |
| Sheet | 系统默认 `.large` detent + `.presentationBackground(.regularMaterial)` |
| 识别中的麦克风舞台 | 无卡片，直接画在 `paper` 上（"没有内容可看"时才允许装饰） |

> 禁止自定义 `UIVisualEffectView` 参数、禁止叠加多层自绘模糊（性能与观感都会崩）。

---

## 6 动效与触觉

### 6.1 动效（全部用系统曲线，尊重 `Reduce Motion`）

| 场景 | 做法 | 时长/曲线 |
|---|---|---|
| Tab 切换 | 自绘 `JZTabBar`：选中胶囊用 `matchedGeometryEffect` 在 5 个槽位间滑动（0.36s / damping 0.80），文字只淡入、图标换实心并 `symbolEffect(.bounce)`；Tab 内容 0.985→1 + 交叉淡变 0.26s（`Tokens.Motion.tabContent`）。**不做** Android 的左右滑入 | 360 / 260ms |
| 进播放页 | `matchedTransitionSource` + `.navigationTransition(.zoom)` 从 mini player 封面放大（iOS 18+）；iOS 17 回退为 `.sheet` 默认上滑 | 系统 |
| 封面 ↔ 歌词切换 | `.spring(response: 0.42, dampingFraction: 0.86)` 交叉淡变 + 轻微缩放（`Tokens.Motion.panelSwap`） | 340ms |
| 歌词行推进 | `.spring(response: 0.38, dampingFraction: 0.92)` 位移 + 当前行字重/色过渡 | 380ms |
| 逐字染色 | `linear(duration: 0.14)` 单字推进（跟随每字 start/end） | 140ms |
| 收藏心跳 | `.bouncy(duration: 0.26)`，scale 1 → 1.16 → 1；图标 `replace` + `bounce` | 260ms |
| 按压反馈（全局） | 按下 scale 0.95 / 压暗 0.78；列表行改为整条 22% 亮色高亮 + scale 0.985（Light Player 式"亮一下"）。下落 0.14s spring，松手 0.30s 渐隐；普通点击不再给触觉 | 140 / 300ms |
| 下载完成 | 行内进度区收起 + `.snappy` 图标切换 | 260ms |
| 列表增删 | 系统 `List` 默认动画，不自定义 | — |
| 无源自动跳歌 | 无炫技：顶部内联提示条滑入 200ms，2s 后淡出 | 200ms |
| 识曲 · 聆听 | 三圈声波从 136pt 底盘外扩（1.5s 一圈、错峰 0.42s、1→1.55、0.32→0）；24 根径向电平条（麦克风 RMS ×5.5 后低通，3→15pt）；12 秒倒计时环（0.08 底轨 + 朱砂进度） | 30fps `TimelineView` |
| 识曲 · 辨认 | 声波收起；204pt 雷达弧 1.1s 转一圈（18% 弧长，`AngularGradient` 尾迹）+ `waveform` 变量色 | 1.1s/圈 |
| 识曲 · 结果 | 一次 0.55s 成功脉冲（1→1.55、0.55→0）+ 图标 `replace` 变勾；结果卡 0.42s spring 从下方 12pt 顶上来 | 550 / 420ms |
| 识曲 · 失败 | 舞台横向抖 3 下（±6pt / 0.36s）+ 图标斜杠；文案只做 6pt 上浮淡入，**不整页渐变** | 360ms |
| 开屏（冷启动一次） | 耳机标自绘三拍：头梁扇形遮罩落笔（easeOut）→ 两只耳罩弹入（spring 0.40 / 0.72，右耳罩晚 0.06s）→ 朱砂声波 + 1.04 轻顶；退场时纸底淡出、首页 0.985→1 交叉淡入 | 1.72s（图标 1.30–1.58 先走，纸底 1.30–1.72） |
| `Reduce Motion` 开启 | 关闭 zoom 转场、关闭封面缩放，改纯 crossfade；歌词改为直接跳行；开屏不做落笔/弹入/声波，图标直接是完整的，停 0.35s 淡出 0.30s；底部栏胶囊不滑动只换底色；识曲不做声波/抖动/成功脉冲/`bounce`，只留倒计时环与 0.15s 淡变 | 0.65s / 0.15s |

### 6.2 触觉（克制：只在"改变了什么"时给）

| 事件 | 触觉 |
|---|---|
| 播放 / 暂停 | `UIImpactFeedbackGenerator(style: .light)` |
| 上一首 / 下一首 | `.light` |
| 进度条拖动经过整 10% | `UISelectionFeedbackGenerator()`（最多每 10% 一次，不逐点） |
| 收藏 / 取消收藏 | `.light`（不叠加通知型） |
| 下载开始 | `.light` |
| 下载完成 / 全部源解析失败 | `UINotificationFeedbackGenerator` `.success` / `.error` |
| 识曲出结果 | `.success` |
| 识曲没听出来 / 失败 | `.warning` / `.error` |
| 切 Tab | `UISelectionFeedbackGenerator()`（只在真的换 Tab 时一下） |
| 普通点击 / 点歌 / 列表行 / 卡片 | **不给触觉**（第三十三轮：老板要"高亮"不要"震动"）；反馈走 22% 亮色高亮 |
| 麦克风开始聆听 | `.medium`（物理动作） |
| 拖拽排序（队列） | `.light` + 系统 drag 反馈 |
| **禁止**：滚动、翻页、每次打勾、Toast 出现时给触觉 | — |

### 6.3 识曲舞台的结构（第三十二轮）

老板 2026-11-18 对着 Light Player 录屏说"点击识曲是渐变，太丑且不符合功能"。旧实现只有一颗
210pt 的圈在 `easeInOut(0.6)` 里整体淡入淡出，把图标、文字、结果卡一起拖着渐变；新实现把
"听音"这件事拆成三拍，每一拍只动该动的东西：

| 拍 | 画面 | 为什么 |
|---|---|---|
| 听 | 底盘外三圈声波（1.5s/圈、错峰 0.42s）+ 24 根径向电平条（跟麦克风 RMS）+ 12 秒倒计时环 | 声波=在听，电平=听到了，倒计时=还要多久——三个都是真信息，不是装饰 |
| 认 | 声波收掉，204pt 雷达弧 1.1s 转一圈 + `waveform` 变量色 | 换了个动作，用户能看出"录完了，在比对" |
| 果 | 0.55s 成功脉冲 + 图标变勾 + 结果卡从下顶上来；没听出来/失败则舞台抖 3 下 + 斜杠 | 成功"放大一下"，失败"摇一下头"；文案只做 6pt 上浮淡入 |

数值口径全部在 `Services/RecognizeMotion.swift`（纯函数，CI 有 14 条断言钉住），
视觉预演 `docs/ios/mockups/motion-rework.html` 与 `motion-rework.png`（6 拍 + 底栏 3 态），
生成脚本 `tools/ios/gen_motion_mockup.py`——改手感先改预演，再同步回 Swift。

> 自绘底栏是本次唯一偏离系统控件的地方（系统 tab bar 的选中态没有可插手的位移），
> 其余仍是系统控件；iPad 也走同一条底部栏（与 iPhone 一致，不做侧栏），
> 底栏字号上限 `xxLarge`，VoiceOver 读完整标签（"我的收藏"而不是"收藏"）。

---

## 7 图标与 App 图标

### 7.1 SF Symbols 映射（唯一图标来源，禁止自绘图标）

| 位置 | 符号 |
|---|---|
| Tab · 发现 | `house.fill`（未选中 `house`） |
| Tab · 搜索 | `magnifyingglass`（无填充变体，靠 tint 表示选中） |
| Tab · 识曲 | `waveform` |
| Tab · 下载 | `arrow.down.circle.fill` / `arrow.down.circle` |
| Tab · 资料库 | `square.stack.fill` / `square.stack` |
| 播放 | `play.fill` / `pause.fill` |
| 上一首 / 下一首 | `backward.fill` / `forward.fill` |
| 循环三态 | `repeat`（列表循环）/ `repeat.1`（单曲循环）/ `shuffle`（随机） |
| 收藏 | `heart` / `heart.fill` |
| 下载 | `arrow.down.circle`、`arrow.down.circle.fill`（已完成） |
| 更多 | `ellipsis` |
| 音源详情 | `antenna.radiowaves.left.and.right` |
| 歌词 | `quote.bubble`、`text.justify.leading` |
| 识曲 | `mic.fill`（页内）、`stop.fill`（取消聆听） |
| 时长档位 | `timer` |
| 其他版本 | `square.stack.3d.up` |
| 最近识过 | `clock.arrow.circlepath` |
| 设置 | `gearshape` |
| 清理 | `trash` |
| 重试 | `arrow.clockwise` |
| 成功 | `checkmark.circle.fill` |
| 失败 | `exclamationmark.triangle.fill` |
| 无源/断网 | `wifi.exclamationmark`、`bolt.horizontal.circle` |
| 文件 | `folder`、`doc.text` |
| AirPlay | `airplayaudio` |
| 睡眠定时（若做） | `moon.zzz` |

渲染规范：Tab 与导航栏用 `.body`/`.headline` 尺寸；行内 accessory 用 `.footnote` + `.tertiaryLabel`；多色用 `.symbolRenderingMode(.hierarchical)` 而非多色。

### 7.2 App 图标（1024×1024 单图 + iOS 18 三变体）

- **主体**：一枚朱砂印章（连续圆角方形，边距 96pt），印面是单字「音」的负形（纸色镂空）。不做文字排版，不做圆角遮罩（系统自动 squircle）。
- **Light**：纸色底 `#F7F3EA` + 朱砂印 `#B03A2E`。
- **Dark**：墨底 `#14120F` + 朱砂提亮 `#FF8A76` 印。
- **Tinted**：单色黑印面（系统着色）。
- 禁止：渐变球体、玻璃拟态、图标内小字、Apple 设备轮廓。
- 出口：`AppIcon-1024.png`（无 alpha），`Assets.xcassets/AppIcon.appiconset` 三变体。

---

## 8 无障碍（作为验收项，不是加分项）

| 项 | 要求 |
|---|---|
| 触摸目标 | 所有可点元素 ≥44×44pt；行内小按钮用 `.contentShape` + `.frame(minWidth:44,minHeight:44)` |
| VoiceOver 标签 | 每个控件都有名词式 `accessibilityLabel`；状态用 `.accessibilityValue`；后果用 `.accessibilityHint` |
| 组合 | 歌曲行用 `.accessibilityElement(children: .combine)`，朗读顺序「歌名，歌手，酷我，3:45」 |
| 进度条 | `.accessibilityValue("1:23 / 3:45")`，可调（`.accessibilityAdjustableAction`） |
| 歌词 | 整屏歌词作为一个可滚动元素，当前行 `.accessibilityValue("第 3 行，共 42 行")`；逐字高亮对 VoiceOver 无意义，不朗读 |
| 颜色 | 平台、原唱、收藏、下载状态**全部**同时有文字或图标，不靠色 |
| Dynamic Type | 最大档（AX5）不截断、不重叠；播放页在 AX 档下自动切"信息优先"布局（封面缩小到 40% 高度） |
| 粗体文本 | 允许系统加粗后仍不溢出 |
| 对比度 | 正文 4.5:1、大字号 3:1、控件边界 3:1（两外观各测） |
| Reduce Motion | 见 §6.1 |
| 触觉 | 仅装饰性；关闭触觉后功能不变 |
| 语音控制 | 所有按钮有可见标签，不用纯图标无标签的按钮 |

---

## 9 现有 iOS 原型自评（`ios/JZMusicHelper`，2026-11 版）

按本套规范的口径打分（满分 10，见评分表）：

| 检查项 | 现状 | 得分 |
|---|---|---|
| 安全区适配 | `TabView` + `NavigationStack` 均为系统容器，未越界 | ✅ |
| 44×44pt | 行内平台胶囊、清空 × 按钮偏小，未加 `contentShape` | ❌ |
| 暗色模式 | 用了 `Color(.systemGray6)` / `.secondary` 等语义色，但搜索栏自绘灰底与纸色底冲突；无暗色验证 | 部分 |
| Dynamic Type | 全部用语义字体（`.body`/`.subheadline`/`.caption`），无硬编码字号 | ✅ |
| VoiceOver | 无任何 `accessibilityLabel`；状态点纯色无声 | ❌ |
| 原生导航 | 4 个 Tab、`NavigationStack`、`Form` 设置页均为原生 | ✅ |
| 语义色（不硬编码） | 混用 `.orange/.green/.red/.gray` 表达平台健康度（颜色单独承载语义） | ❌ |
| 系统控件优先 | 自绘搜索栏 + 自绘空态（iOS 17 已有 `ContentUnavailableView`） | ❌ |
| 标准手势与触觉 | 无长按菜单、无滑动操作、无任何触觉 | ❌ |
| SF Symbols / 图标 | 全部用 SF Symbols | ✅ |

**当前得分：4/10**（"能用，但露出 Android 痕迹，且无障碍缺失"）。
**到 10/10 需要的具体改动**（本套设计已全部覆盖）：

1. 删掉自绘搜索栏，改 `.searchable(text:placement:.navigationBarDrawer(displayMode:.always))`。
2. 平台健康度改"文字 + 图标"（§3.3），删掉红/绿/橙圆点。
3. 空态改用 `ContentUnavailableView`。
4. 补 5 个 Tab 的信息架构（现缺识曲、收藏、历史合并后的资料库）。
5. 补播放页（现状只能在详情页试听，没有 Now Playing、没有锁屏信息）。
6. 所有行加 `accessibilityElement(children: .combine)` 与 `swipeActions`（收藏/下载/删除）。
7. 用 Asset Catalog 定义 `paper` / `vermilion`，删掉 `Color(.systemGray6)` 之类的临时底色。
8. 加触觉（§6.2）。

---

## 10 落码前的检查清单（设计验收）

- [ ] 每个页面都有 5 态稿（空 / 加载 / 有数据 / 失败 / 权限）。
- [ ] 每个页面在 375pt（SE）、393pt（15）、430pt（Pro Max）、iPad 1024pt 四种宽度下都有布局说明。
- [ ] 每个页面浅色 + 深色都过一遍。
- [ ] 每个页面的 VoiceOver 朗读顺序写清楚。
- [ ] 每个"朱砂实心"元素都能回答"为什么是它"。
- [ ] 没有任何一处硬编码字号或颜色（除 §3.1 三个令牌）。
- [ ] 没有一处自绘控件（除歌词逐字渲染与封面光晕）。

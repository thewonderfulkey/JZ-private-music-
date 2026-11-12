# UI 设计文档（「JZ的音乐助手」美化设计规范）

> 学习 GitHub 上 UI 设计相关的文档 / 项目仓库 / Agent 后的沉淀成果（只学习，不改 App 代码）。
> 调研日期：2026-10-28。所有规范均有真实来源（官方文档或开源仓库），来源链接见 §9；数值为可直接落地的建议值。
> 配套产物：`UI设计Skill/SKILL.md`（Agent 可复用技能，安装说明见 §10）。

---

## 1 总览

本文档为双端音乐 App「JZ的音乐助手」（Android：Kotlin + Jetpack Compose + Material 3；iOS：SwiftUI，17 个 Swift 文件工程；功能：4 平台并发搜索、歌曲详情含音质三档与多取流链接、试听、下载管理、历史）的 UI 美化提供可落地设计规范。调研覆盖四块：

1. **移动端设计系统**：Material Design 3（色彩 role / Type Scale / Shape / tonal elevation / 导航栏）、W3C DTCG 设计 Token + Style Dictionary、Apple HIG（44pt / 材质 / 字号）、SwiftUI 视觉 API。
2. **UI 设计 Agent / 生成类项目**：screenshot-to-code、OpenUI、Codel、make-real、anthropics/skills frontend-design、impeccable、OpenHands 前端工作流——提炼"让 AI 产出漂亮 UI"的 prompt 与工作流方法论。
3. **音乐类 App UI 参考**：LX Music、SimpMusic、Phonograph/VinylMusicPlayer、RetroMusicPlayer、Namida、Timber、MellowPlayer、Vibe 共 8 个开源播放器。
4. **配色 / 字体 / 动效规范**：3 套暗色 hex 色板、封面取色（Palette API）、M3 官方动效时长与缓动曲线。

## 2 设计原则（音乐 App 通用，综合官方文档与开源项目）

| # | 原则 | 依据 / 来源 |
|---|---|---|
| 1 | **封面是视觉中心**：大封面 + 从封面主色生成的渐变/模糊背景铺满（正在播放页/详情页），UI 退居封面之后 | Spotify 深色设计范式（https://designbycurio.com/zh/spotify-dark ） |
| 2 | **暗色主题优先**：近黑/深灰底 + 单一强调色；M 系官方建议暗色表面用深灰而非纯黑（#121212 量级）以降低刺眼感，OLED 场景可用纯黑 | https://m2.material.io/design/color/dark-theme.html ；https://m3.material.io/blog/android-dark-theme-tutorial |
| 3 | **信息层级用字号/字重表达，不靠色块**：歌名 ＞ 艺人 ＞ 专辑 ＞ 元数据；主文字/次文字用语义色 | MD3 color roles + 开源播放器通用做法 |
| 4 | **按角色取色，不写死颜色**：Android 用 `MaterialTheme.colorScheme.*`，iOS 用语义色（`Color(.systemBackground)` / `.label`），暗色模式自动适配 | https://m3.material.io/styles/color/roles ；https://developer.apple.com/design/human-interface-guidelines/materials |
| 5 | **层级靠 tonal elevation 而非阴影**：浮层（底部播放条/选中卡片）用 `surfaceContainer` + 轻微 tonalElevation 从内容区浮起 | https://developer.android.google.cn/develop/ui/compose/designsystems/material3 |
| 6 | **克制：大胆只用一处**，其余保持安静（"出门前摘掉一件配饰"）；明确避开"AI 味"套路（见 §7.3 黑名单） | anthropics/skills frontend-design（https://github.com/anthropics/skills ） |
| 7 | **可点击目标**：iOS ≥44×44pt（HIG 硬指标），Android ≥48dp（Compose 默认触摸目标） | https://developer.apple.com/design/tips/ |
| 8 | **双端 token 单一事实源**：色值/字号/圆角/间距只写一份 token（DTCG），Style Dictionary 编译双端产物，杜绝两端漂移 | https://github.com/amzn/style-dictionary ；https://www.w3.org/community/design-tokens/ |

## 3 推荐设计系统与配色方案

### 3.1 设计系统选择

- **Android**：Material 3（androidx.compose.material3）原生主题：`ColorScheme`（darkColorScheme 改色板）、`Typography`（Type Scale 五族三档）、`Shapes`（5 档圆角）。动态取色 `dynamicDarkColorScheme(context)` 需 Android 12+，低版本 fallback 自定义 dark scheme（来源：https://developer.android.google.cn/develop/ui/compose/designsystems/material3 ）。
- **iOS**：SwiftUI 语义色 + 材质：`Color(.systemBackground)`、`.label/.secondaryLabel`、`.ultraThinMaterial`（浮层）、`glassEffect`（iOS 26 Liquid Glass）；暗色模式由系统切换（来源：https://developer.apple.com/design/human-interface-guidelines/materials ）。
- **token**：W3C DTCG 格式（`$value/$type/$description`、`{...}` 别名两级结构），工具 Style Dictionary 编译 Android/iOS 产物；2025.10 已支持 light/dark 主题切换（来源：https://www.designtokens.org/tr/2025.10/color/ ；https://styledictionary.com/ ）。

### 3.2 暗色主题色板（3 套，可直接取用）

**色板 A：Spotify 式「近黑底 + 单一强调绿」（推荐默认，音乐 App 最成熟范式）**

| 角色 | Hex | 用途 |
|---|---|---|
| 页面背景 | `#121212` | 全局背景 |
| 卡片/表面 | `#181818` | 列表分组、卡片容器 |
| 主文字 | `#FFFFFF` | 歌名/标题 |
| 次文字 | `#B3B3B3` | 艺人、辅助说明 |
| 强调色 | `#1DB954` 常态 / `#1ED760` 播放高亮 / `#1AA34A` 按压 | 只用于主操作（播放/试听按钮），不大面积铺 |

来源：https://themeandcolor.com/blog/spotify-dark-mode-colors 、https://open-design.ai/plugins/design-system-spotify/

**色板 B：M3 式「深紫灰底 + 淡紫主色」（与 Compose M3 token 映射最顺）**

| 角色 | Hex | 用途 |
|---|---|---|
| 页面背景 | `#121212`（M3 基线约 `#141218`） | 全局背景 |
| 表面/卡片 | `#1D1B20` | 卡片、导航/迷你条容器 |
| 主文字（on-surface） | `#E6E0E9` | 歌名/标题 |
| 次文字（on-surface-variant） | `#CAC4D0` | 艺人、元数据 |
| 强调色（primary） | `#D0BCFF` | 播放按钮、选中态、进度条 |

来源：https://m3.material.io/blog/android-dark-theme-tutorial 、https://aiuxplayground.com/skills/material-3/ 、https://colorfyi.com/id/blog/color-in-mobile-design/

**色板 C：iOS OLED 式「纯黑底 + 中性灰阶」**

| 角色 | Hex | 用途 |
|---|---|---|
| 页面背景 | `#000000` | OLED 纯黑，省电沉浸 |
| 表面/卡片 | `#1C1C1E` | iOS 风格分组容器 |
| 主文字 | `#FFFFFF` | 标题 |
| 次文字 | `#8E8E93` | iOS 系统灰辅助信息 |
| 强调色 | 自定义（单色，小面积） | 主操作 |

来源：https://colorfyi.com/id/blog/color-in-mobile-design/

> **封面取色逻辑**：Android 用 `androidx.palette` 从封面 Bitmap 提取 6 种色样（Light/Vibrant/Dark × Vibrant/Muted），`Palette.from(bitmap)` 异步生成，`get<Profile>Color(defaultColor)` 带兜底；正在播放页背景取 **Dark Vibrant 或 Muted** 作渐变基色（来源：https://developer.android.google.cn/develop/ui/views/graphics/palette-colors?hl=zh-cn 、https://github.com/codepath/android_guides/wiki/Dynamic-Color-using-Palettes ）。iOS 可用 `UIColor` 取封面平均色/主色做背景。

### 3.3 设计 Token JSON 示例（DTCG，音乐 App 场景）

两级结构：`primitive`（原始色板，写死一次）→ `semantic`（语义 role，双端共用）；暗色只换 primitive 色值，语义层不动。

```json
{
  "color": {
    "primitive": { "brand": { "500": "#1DB954", "300": "#1ED760" }, "ink": { "900": "#121212", "700": "#181818" }, "paper": { "0": "#FFFFFF", "100": "#B3B3B3" } },
    "semantic": {
      "primary":          { "$value": "{color.primitive.brand.500}", "$type": "color" },
      "onPrimary":        { "$value": "{color.primitive.paper.0}",   "$type": "color" },
      "surface":          { "$value": "{color.primitive.ink.900}",   "$type": "color" },
      "surfaceContainer": { "$value": "{color.primitive.ink.700}",   "$type": "color" },
      "onSurface":        { "$value": "{color.primitive.paper.0}",   "$type": "color" },
      "onSurfaceVariant": { "$value": "{color.primitive.paper.100}", "$type": "color" }
    }
  },
  "typography": {
    "playTitle":   { "$value": "headlineSmall", "$type": "textStyle", "sp": 24, "lineHeight": 32 },
    "listTitle":   { "$value": "titleMedium",   "$type": "textStyle", "sp": 16, "lineHeight": 24, "weight": "medium" },
    "listSubtitle":{ "$value": "bodyMedium",    "$type": "textStyle", "sp": 14, "lineHeight": 20 },
    "navLabel":    { "$value": "labelLarge",    "$type": "textStyle", "sp": 14, "lineHeight": 20, "weight": "medium" }
  },
  "spacing": { "xs": { "$value": 4, "$type": "spacing" }, "s": { "$value": 8, "$type": "spacing" }, "m": { "$value": 16, "$type": "spacing" }, "l": { "$value": 24, "$type": "spacing" } },
  "radius":  { "small": { "$value": 8, "$type": "borderRadius" }, "medium": { "$value": 12, "$type": "borderRadius" }, "large": { "$value": 16, "$type": "borderRadius" }, "pill": { "$value": 999, "$type": "borderRadius" } },
  "size":    { "navBarHeight": { "$value": 80, "$type": "dimension" }, "miniPlayerHeight": { "$value": 64, "$type": "dimension" }, "hitTargetMin": { "$value": 44, "$type": "dimension" } },
  "motion":  { "standard": { "$value": 300, "$type": "duration" }, "fast": { "$value": 150, "$type": "duration" } }
}
```

（结构参照 DTCG 规范与音乐场景整理；样式说明见 §3.1 来源）

## 4 组件规范（可直接抄的数值）

### 4.1 字号矩阵（Type Scale，Compose sp = SwiftUI pt 取同值）

| Token | 字号 / 行高 | 字重 | 用途 |
|---|---|---|---|
| headlineSmall | 24 / 32 | Regular | 正在播放/详情页曲名 |
| headlineMedium | 28 / 36 | Regular | 页面大标题 |
| titleLarge | 22 / 28 | SemiBold | 歌单/详情副标题 |
| titleMedium | 16 / 24 | Medium | 列表行主标题（歌名） |
| bodyMedium | 14 / 20 | Regular | 艺人、副标题 |
| bodySmall | 12 / 16 | Regular | 时长、年份、码率等元数据 |
| labelLarge | 14 / 20 | Medium | 底部导航标签、按钮文字 |

来源：https://developer.android.google.cn/develop/ui/compose/designsystems/material3

### 4.2 圆角（Shape）与间距

| 项 | 值 | 用途 |
|---|---|---|
| extraSmall | 4dp | 小 chip、徽章 |
| small | 8dp | 输入框、封面缩略图 |
| medium | 12dp | **默认卡片**、列表行 |
| large | 16dp | 大封面、详情卡 |
| extraLarge | 24dp | 底部弹层（播放页面板） |
| 全圆 | pill | 搜索框、播放按钮 |
| 间距基数 | 4dp/pt（xs4 / s8 / m16 / l24） | 页面边距 16、行内距 12、元素间隔 8/12 |

来源：https://m3.material.io/styles/shape/corner-radius-scale

### 4.3 组件尺寸与色 role

| 组件 | 数值 / role | 说明 |
|---|---|---|
| 底部 NavigationBar | 高 **80dp**；容器 `surfaceContainer`；标签 `onSurfaceVariant`；选中 pill `secondaryContainer` + `onSecondaryContainer`；3–5 目的地 | https://m3.material.io/components/navigation-bar/specs |
| 迷你播放条 | 高 **64dp**；`surfaceContainer` + 轻微 tonalElevation；悬浮 Tab 之上 | token 示例（§3.3） |
| 曲目列表行 | 高 ≥48dp；左 48–56dp 封面缩略图（圆角 8）→ 歌名(titleMedium, 单行省略) → 艺人(bodyMedium, onSurfaceVariant) → 右时长(bodySmall) | 开源播放器行业默认行 |
| 歌曲详情页 | 大封面（屏宽 60–70%，圆角 16–24，居中）→ 歌名(headlineSmall) → 艺人 → 专辑 → 音质三档分段控件 → 取流链接卡片列表 → 下载入口 | §4.4 布局 |
| 状态层 | Hover 8% / Focus 10% / Pressed 10%（透明叠加） | https://m3.material.io/components/navigation-bar/specs |
| 可点击目标 | iOS 44×44pt；Android 48dp | https://developer.apple.com/design/tips/ |
| 分割线 | `outlineVariant`（勿用 `outline`） | https://m3.material.io/styles/color/roles |

### 4.4 页面布局模式（对齐 JZ 四 Tab + 详情页）

- **搜索页**：顶部搜索框（圆角 12 实心表面色）→ 结果列表；行 = 封面缩略图 + 歌名 + 歌手/专辑 + 右侧"试听/下载"双操作；多平台来源用 chip/icon 标注（对照 LX Music 多音源列表）。
- **歌曲详情页**：自上而下 = 大封面与标题区（封面渐变背景）→ 音质三档分段控件（流畅/高清/无损）→ 取流链接列表（每条：来源/码率/试听入口，可复制）→ 下载管理入口。
- **迷你播放条**：左 40dp 封面（圆角 8）+ 歌名/进度薄条 + 播放/暂停与下载状态；点击上滑展开全屏播放页（Phonograph 系 Sliding Player Panel 交互：https://phonographplus.github.io/changelogs/changeslogs/changelog.html ）。
- **下载管理/历史**：行 = 状态 icon（成功/进行中/失败）+ 歌名 + 进度条或大小；历史行附"最近播放时间"。
- **设置页**：分组列表（分组标题 bodySmall 次文字 + 行项 48dp），开关/单选用平台标准控件。
- **空态**：图标 + 一行提示（次文字色），居中。

## 5 动效建议（M3 官方规范 + 落地值）

| 场景 | 缓动（贝塞尔） | 时长 | 说明 |
|---|---|---|---|
| 页面进入 | Standard decelerate `(0.0, 0.0, 0.2, 1)` | **400ms** | 加速进入后减速落定 |
| 页面退出 | Standard accelerate `(0.4, 0.0, 1, 1)` | **200ms** | 快速离场 |
| Tab 切换 / 面板展开收回 | Standard `(0.4, 0.0, 0.2, 1)` | **300ms** | 最通用默认值 |
| 迷你条 ↔ 全屏播放页（共享元素） | Emphasized | **500ms** | 跨大尺寸布局变化 |
| 列表项进入（搜索返回） | Standard 淡入 + 轻微上移 | 200–300ms | 落地建议 |
| 封面旋转（CD 效果） | Linear 匀速，仅播放中转动、暂停缓停 | 一圈 8–12s | 落地建议 |

来源：https://m3.material.io/styles/motion/easing-and-duration 、https://m2.material.io/develop/android/theming/motion

## 6 Compose 与 SwiftUI 双端实现要点

| 需求 | Android Compose | iOS SwiftUI |
|---|---|---|
| 主题 | `MaterialTheme(colorScheme = darkColorScheme(...), typography = ..., shapes = ...)`；Android 12+ 可 `dynamicDarkColorScheme(context)` | `Color(.systemBackground)` / `.label` / `.secondaryLabel`（自动适配暗色）；自定义色用 Asset Catalog 的 Any/Dark 两组 |
| 底部导航 | `NavigationBar(containerColor = surfaceContainer, indicatorColor = secondaryContainer)` | `TabView` + `safeAreaInset` 放迷你播放条 |
| 曲目列表行 | `Row` + `Card`(medium 圆角) + 两行 `Text`；`Modifier.minimumInteractiveComponentSize()` 保证 48dp | `HStack` + `Button`，`frame(minWidth: 44, minHeight: 44)` |
| 详情页 | `LazyColumn`：大封面（`graphicsLayer` 圆角/`BlurredBackground` 渐变）→ 文字列 → `SegmentedButton`（音质三档）→ 链接卡片 | `ScrollView` + `Image` 封面渐变背景 + `Picker(.segmented)` + 卡片 `List` |
| 迷你播放条 | 自定义 `Surface(tonalElevation = ...)` 或 `BottomAppBar`，`AnimatedVisibility` 展开 | `.safeAreaInset(edge: .bottom) { }` + `.ultraThinMaterial`（或 M3 语义色）+ `matchedGeometryEffect` 共享元素展开 |
| 动态取色 | `androidx.palette` / `dynamicColorScheme` | `UIColor` 平均色或主色；`glassEffect`（iOS 26） |
| 动效 | `animateContentSize` / `AnimatedVisibility` / `animateColorAsState` / `tween(durationMillis, easing = FastOutSlowInEasing)` | `withAnimation(.easeInOut(duration: 0.3))` / `.animation(.spring)` / `matchedGeometryEffect` |
| 状态层 | `InteractionSource` + `indication`（默认 ripple + 状态层） | `Button` 默认 + `.buttonStyle(.plain)` 自定义按压反馈 |

## 7 UI 设计 Agent 工作流借鉴（未来美化迭代方法论）

来源综合：anthropics/skills frontend-design、wandb/openui、pbakaus/impeccable、abi/screenshot-to-code、OpenHands 博客、Cursor 文档（详见 §9）。

### 7.1 通用工作流（调研 → token → 组件 → 页面 → 截图验证 → 迭代）

1. **定 brief**：写清产品主题/受众/约束（可落成 `PRODUCT.md`）；找 1–3 张参考 App 截图做风格锚点（screenshot-to-code / Cursor 均支持喂参考图："拿目标截图对比当前 UI，逐项调间距/颜色/字体"）。
2. **先定设计 token 再写码**：4–6 个命名 hex + 字体角色 + ASCII 布局草图；写完对照 brief 自审"这是不是我对任何产品都会画的默认图"，删掉套路再动手（frontend-design 的 plan→review→build 两阶段）。
3. **组件级生成，不整页重写**：一次一个组件/区域（OpenUI 的 `<!--FIX (n): ...-->` 锚点局部修改）；要求填充真实样例数据与完整交互，不留占位文案（make-real）。
4. **截图验证闭环**：生成 → 截图 → 视觉模型/人自审（"一张图值一千 token"）→ 把截图 + 当前代码一起回喂再改；有条件建 Playwright 视觉回归基线。
5. **迭代一次只调一个维度**：用单维度指令（bolder / quieter / typeset / layout），不用"再好看一点"这种笼统话；写码与评审用不同模型。

### 7.2 prompt 技巧

- 把设计 token 表（`--primary/--surface/--onSurfaceVariant` 等）**直接内嵌进 system prompt**，并给用法示例，"优先使用这些颜色"（OpenUI 的工程化做法）。
- 人设化："把自己当成知名设计工作室的设计总监，客户已拒绝过所有陈词滥调的提案"（frontend-design）。
- 输出契约前置：技术栈、只写某文件/某组件、命名规则写进 prompt。
- 不变量写清："保持现有数据接口不变 / 不改业务逻辑"（OpenHands）。

### 7.3 "AI 味"黑名单（美化时必须规避）

奶油底+赤陶色、近黑底+单一荧光色滥用、紫蓝渐变、卡片套卡片、全大写 eyebrow 标签、`A · B · C` 中点分隔、行尾 `→`、等宽字体当数据标签、Inter 全家桶、bounce 弹性动效、灰色文字压彩色底、触控目标过小（来源：anthropics/skills frontend-design；pbakaus/impeccable 62 条确定性检测器规则）。

## 8 参考项目清单与最值得借鉴

### 8.1 最值得借鉴的 5 个项目（Top 5）

| # | 项目 | 仓库 | 对 JZ 的具体借鉴点 |
|---|---|---|---|
| 1 | **LX Music（洛雪音乐）** | https://github.com/lyswhut/lx-music-desktop （移动版 https://github.com/lyswhut/lx-music-mobile ） | 与 JZ 定位最像的中文多音源聚合：搜索结果 = 每个音源一条"取流链接"，音质选择、试听、下载管理、历史记录均有成熟 UI——优先精读其信息分组与下载管理页 |
| 2 | **SimpMusic** | https://github.com/maxrave-dev/SimpMusic | Kotlin + Compose Multiplatform 客户端：搜索结果列表、正在播放页、歌词联动的 **Compose 实现与 JZ 技术栈最贴近** |
| 3 | **Phonograph / VinylMusicPlayer** | https://github.com/VinylMusicPlayer/VinylMusicPlayer （经典交互记录：https://phonographplus.github.io/changelogs/changeslogs/changelog.html ） | **Sliding Player Panel**：迷你播放条上滑展开全屏播放页的经典交互，JZ 试听条照此实现 |
| 4 | **Retro Music Player** | https://github.com/RetroMusicPlayer/RetroMusicPlayer | Material You 动态取色 + 正在播放页重做经验：详情页随封面取色换渐变背景可直接搬 |
| 5 | **Namida** | https://github.com/namidaco/namida | "本地库 + 在线音源"双模式与高完成度 UI，参考列表密度与页面过渡 |

### 8.2 完整参考清单

| 类别 | 项目 | 仓库/文档 | 可借鉴点 |
|---|---|---|---|
| 音乐 App | RetroMusicPlayer / Namida / SimpMusic / Phonograph(Vinyl) / Timber / MellowPlayer / Vibe / LX Music | 见 §8.1 与 §9 | 布局/配色/动效/交互（详情见调研笔记） |
| 设计系统 | Material 3 | https://m3.material.io/styles/color/roles 、https://m3.material.io/styles/motion/easing-and-duration 、https://m3.material.io/components/navigation-bar/specs | color roles / 动效 / 导航规范 |
| 设计系统 | Compose M3 官方指南 | https://developer.android.google.cn/develop/ui/compose/designsystems/material3 | ColorScheme/Typography/Shapes/elevation |
| 设计系统 | material-components-android / androidx | https://github.com/material-components/material-components-android 、https://github.com/androidx/androidx | 组件规范与实现源码 |
| 设计系统 | SwiftUIX | https://github.com/SwiftUIX/SwiftUIX | SwiftUI 组件/工具库 |
| 设计 Token | W3C DTCG / Style Dictionary | https://www.w3.org/community/design-tokens/ 、https://github.com/amzn/style-dictionary | token 单一事实源、双端编译 |
| UI Agent | anthropics/skills frontend-design | https://github.com/anthropics/skills | 去套路化设计计划、AI 味黑名单 |
| UI Agent | wandb/openui | https://github.com/wandb/openui | token 内嵌 prompt、FIX 锚点局部修改、截图评审闭环 |
| UI Agent | pbakaus/impeccable | https://github.com/pbakaus/impeccable | PRODUCT/DESIGN 文件分离、单维度调节命令、62 条检测器 |
| UI Agent | abi/screenshot-to-code / tldraw make-real / semanser/codel | https://github.com/abi/screenshot-to-code 、https://github.com/tldraw/make-real 、https://github.com/semanser/codel | 截图输入、真实样例数据、沙箱闭环 |
| UI Agent | OpenHands 前端工作流 / Cursor browser | https://www.openhands.dev/blog/best-way-to-get-ai-to-completely-refactor-frontend-code 、https://cursor.com/docs/agent/tools/browser | 契约先行、截图基线、参考截图逐项对齐 |
| 视觉规范 | Spotify 深色 / 暗色规范 / Palette 取色 | https://designbycurio.com/zh/spotify-dark 、https://m2.material.io/design/color/dark-theme.html 、https://developer.android.google.cn/develop/ui/views/graphics/palette-colors?hl=zh-cn | 暗色色板、封面取色 |

## 9 来源清单（全部链接）

- MD3：Color roles https://m3.material.io/styles/color/roles ；Shape https://m3.material.io/styles/shape/corner-radius-scale ；Navigation bar https://m3.material.io/components/navigation-bar/specs ；Motion https://m3.material.io/styles/motion/easing-and-duration ；暗色教程 https://m3.material.io/blog/android-dark-theme-tutorial
- Compose M3：https://developer.android.google.cn/develop/ui/compose/designsystems/material3 ；Palette：https://developer.android.google.cn/develop/ui/views/graphics/palette-colors?hl=zh-cn
- 仓库：material-components-android https://github.com/material-components/material-components-android ；androidx https://github.com/androidx/androidx ；SwiftUIX https://github.com/SwiftUIX/SwiftUIX ；style-dictionary https://github.com/amzn/style-dictionary ；DTCG https://www.w3.org/community/design-tokens/ 、https://www.designtokens.org/tr/2025.10/color/
- Apple HIG：Materials https://developer.apple.com/design/human-interface-guidelines/materials ；Accessibility https://developer.apple.com/design/human-interface-guidelines/accessibility ；Design tips（44pt）https://developer.apple.com/design/tips/
- 音乐 App：LX Music https://github.com/lyswhut/lx-music-desktop ；SimpMusic https://github.com/maxrave-dev/SimpMusic ；Phonograph https://github.com/kabouzeid/Phonograph 、Vinyl https://github.com/VinylMusicPlayer/VinylMusicPlayer 、Sliding Panel 记录 https://phonographplus.github.io/changelogs/changeslogs/changelog.html ；Retro https://github.com/RetroMusicPlayer/RetroMusicPlayer ；Namida https://github.com/namidaco/namida ；Timber https://github.com/naman14/Timber ；MellowPlayer https://gitlab.com/ColinDuquesnoy/MellowPlayer ；Vibe https://github.com/cmlcali/vibe
- 色板：Spotify https://themeandcolor.com/blog/spotify-dark-mode-colors 、https://open-design.ai/plugins/design-system-spotify/ ；M3 tokens https://aiuxplayground.com/skills/material-3/ 、https://colorfyi.com/id/blog/color-in-mobile-design/
- UI Agent：frontend-design https://cdn.jsdelivr.net/gh/anthropics/skills@main/skills/frontend-design/SKILL.md ；OpenUI https://github.com/wandb/openui 、prompt 原文 https://cdn.jsdelivr.net/gh/wandb/openui@main/frontend/src/api/openai.ts ；impeccable https://github.com/pbakaus/impeccable ；screenshot-to-code https://github.com/abi/screenshot-to-code 、DeepWiki https://deepwiki.com/abi/screenshot-to-code ；make-real https://github.com/tldraw/make-real ；codel https://github.com/semanser/codel ；OpenHands 博客 https://www.openhands.dev/blog/best-way-to-get-ai-to-completely-refactor-frontend-code ；Cursor https://cursor.com/docs/agent/tools/browser

## 10 产物与 SKILL 安装

- 本文档：`C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\UI设计文档.md`
- 可复用技能：`C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\UI设计Skill\SKILL.md`（YAML frontmatter + 工作流 + 内置规范速查，Agent 加载后即可按规范产出设计）
- 调研笔记（原始素材，含更多细节）：3 份子代理笔记（设计系统 / 音乐 App UI / UI Agent 方法论）
- **SKILL 安装位置**：将 `UI设计Skill\SKILL.md` 复制到 `C:\Users\17948\AppData\Local\DoubaoWork\User Data\Default\.doubaowork\agent_mode\workspace\.user_skills\ui-design-for-music-app\SKILL.md`（本环境 skill 根目录为 `workspace\.user_skills\`，每个技能一个同名目录）即可被 Agent 加载。

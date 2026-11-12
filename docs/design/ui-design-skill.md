---
name: ui-design-for-music-app
description: 当用户要求设计、美化或重做移动 App（尤其音乐类 App）的界面，需要配色方案、组件规范、双端（Jetpack Compose / SwiftUI）实现指引或 UI 设计评审时使用。先按内置设计规范产出可落地设计（色板 hex、字号、圆角、间距、动效），再给双端实现要点，最后用截图验证。不承接纯海报/插画类艺术创作。
---

# 音乐类 App UI 设计（Compose + SwiftUI 双端）

为「JZ的音乐助手」这类音乐 App 提供可落地的 UI 设计规范与实现指引。核心主张：**先定设计 token，再写组件，最后拼页面**；暗色主题优先；封面图是视觉中心。完整来源与参考项目见配套《UI设计文档.md》（同目录）。

## 触发场景

- 用户要求美化 / 重新设计 App UI、换配色、改暗色主题、做"好看一点"的界面。
- 需要为页面（列表 / 详情 / 播放控制 / 设置）给出具体色值、字号、圆角、间距、动效参数。
- 需要 Compose（Material3）与 SwiftUI 双端一致实现要点。
- 需要对现有界面做设计评审（对照本文档规范逐项检查）。

## 工作流

1. **调研对齐**：确认 App 平台（Android Compose / iOS SwiftUI / 双端）、现有页面结构、用户偏好（品牌色、是否强制暗色）。音乐类 App 默认：暗色优先、封面为中心、单强调色。可让用户提供 1–3 张参考 App 截图作风格锚点（"拿参考截图对比当前 UI，逐项调间距/颜色/字体"）。
2. **设计 token**：先输出 token 树（color / typography / spacing / radius / motion），JSON 形式，双端同源（Compose 用 MaterialTheme，SwiftUI 用 Color/Asset Catalog）。色板必须给 hex；写完先自审"这是不是对任何产品都成立的默认套路"，删掉套路再继续。
3. **组件规范**：按页面角色给组件级规范——曲目列表行、搜索框、歌曲详情页、音质/取流链接选择器、迷你播放条、正在播放控制、下载任务列表、设置项、空态。每组件含：尺寸、间距、圆角、字号、状态（默认/按下/禁用）颜色。**一次只做一个组件，不整页重写**；填充真实样例数据，不留占位文案。
4. **双端实现要点**：Compose（Material3 colorScheme/typography/shape、NavigationBar、palette 取封面色、animate* 动效）与 SwiftUI（Color/Asset Catalog、safeAreaInset 迷你播放条、matchedGeometryEffect 展开动画、Material 材质）一一对应写出。
5. **验证**：改完必须构建运行 + 截图；对照规范逐项检查（色值是否与 token 一致、暗色对比度、点击区 ≥44pt/48dp、文字层级、动效时长缓动符合下表）；**一次只调一个维度**地迭代（用"更醒目/更安静/调字号/调布局"这类单维度指令，不用"再好看一点"）。

## 内置设计规范要点（速查，来源与链接见《UI设计文档.md》§3-§6、§9）

### 色彩（暗色主题，三套可选色板）

- **色板 A（Spotify 式，默认推荐）**：背景 `#121212`、表面 `#181818`、主文字 `#FFFFFF`、次文字 `#B3B3B3`、强调 `#1DB954`（播放高亮 `#1ED760`、按压 `#1AA34A`）。强调色只用于主操作，不大面积铺。
- **色板 B（M3 原生）**：背景 `#121212`（基线 `#141218`）、表面 `#1D1B20`、主文字 `#E6E0E9`、次文字 `#CAC4D0`、强调 `#D0BCFF`——与 Compose M3 token 映射最顺。
- **色板 C（iOS OLED）**：背景 `#000000`、表面 `#1C1C1E`、主文字 `#FFFFFF`、次文字 `#8E8E93`、强调自定单色。
- 语义 role 用法：页面背景 `surface`、导航/迷你条 `surfaceContainer`、主文字 `onSurface`、次文字 `onSurfaceVariant`、分割线 `outlineVariant`、选中态 `primaryContainer`+`onPrimaryContainer`。
- 封面取色：Android `androidx.palette`（Dark Vibrant/Muted 作渐变基色）或 Compose `dynamicDarkColorScheme`（Android 12+）；iOS 用 `UIColor` 平均色；正在播放页/详情页背景 = 封面主色渐变。

### 排版（Compose sp = SwiftUI pt 同值）

| 角色 | 字号/行高 | 字重 | 用途 |
|---|---|---|---|
| headlineMedium | 28/36 | Regular | 页面大标题 |
| headlineSmall | 24/32 | Regular | 播放/详情曲名 |
| titleLarge | 22/28 | SemiBold | 副标题 |
| titleMedium | 16/24 | Medium | 列表行主标题 |
| bodyMedium | 14/20 | Regular | 艺人/副标题 |
| bodySmall | 12/16 | Regular | 时长/码率/年份元数据 |
| labelLarge | 14/20 | Medium | 导航标签、按钮 |

元数据（音质/时长/码率）用等宽数字感小号字。

### 圆角与间距

- 圆角：XS 4 / small 8（输入框、缩略图）/ medium 12（默认卡片、列表行）/ large 16（大封面）/ XL 24（底部弹层）/ pill（搜索框、播放按钮）。
- 间距基数 4（xs4 / s8 / m16 / l24）：页面边距 16、行内距 12、元素间隔 8/12。
- 点击区：Android ≥48dp（`Modifier.minimumInteractiveComponentSize()`）、iOS ≥44×44pt。
- 状态层透明叠加：Hover 8% / Focus 10% / Pressed 10%。

### 组件与布局模式

- **曲目列表行**：≥48dp 高；48–56dp 封面缩略图（圆角 8）→ 歌名（单行省略）→ 艺人（次文字）→ 右侧时长/操作。
- **歌曲详情页**：大封面（屏宽 60–70%，圆角 16–24）+ 封面渐变背景 → 歌名 → 艺人 → 专辑 → 音质三档分段控件 → 取流链接卡片列表（来源/码率/试听）→ 下载入口。
- **迷你播放条**：64dp，`surfaceContainer`+轻微 tonalElevation（Compose）/ `.safeAreaInset(edge:.bottom)`+`.ultraThinMaterial`（SwiftUI）；左 40dp 封面 + 歌名/进度 + 播放/暂停；点击上滑展开全屏播放页（Sliding Player Panel 交互，300ms standard）。
- **底部导航**：Compose `NavigationBar` 80dp、3–5 项、选中 pill `secondaryContainer`；SwiftUI `TabView`。
- **下载管理/历史**：状态 icon + 歌名 + 进度条/大小；空态 = 图标+提示居中。

### 动效（M3 官方规范）

| 场景 | 缓动 | 时长 |
|---|---|---|
| 页面进入 | decelerate `(0,0,0.2,1)` | 400ms |
| 页面退出 | accelerate `(0.4,0,1,1)` | 200ms |
| Tab/面板过渡 | standard `(0.4,0,0.2,1)` | 300ms |
| 迷你条↔播放页共享元素 | emphasized | 500ms |
| 列表项进入 | 淡入+上移 | 200–300ms |
| 封面旋转（播放中） | linear，一圈 8–12s | 持续 |

Compose：`tween(300, easing = FastOutSlowInEasing)` / `AnimatedVisibility` / `animateContentSize`；SwiftUI：`withAnimation(.easeInOut(duration: 0.3))` / `matchedGeometryEffect` / `.animation(.spring)`。

### "AI 味"黑名单（必须规避）

奶油底+赤陶色、近黑底+单一荧光色滥用、紫蓝渐变、卡片套卡片、全大写 eyebrow 标签、`A · B · C` 中点分隔、行尾 `→`、等宽字体当数据标签、Inter 全家桶、bounce 弹性动效、灰色文字压彩色底、触控目标过小、lorem ipsum 占位文案。

## 参考项目（详见《UI设计文档.md》§8）

LX Music（多音源聚合 UI）、SimpMusic（Compose 参考）、Phonograph/VinylMusicPlayer（Sliding Player Panel）、RetroMusicPlayer（动态取色）、Namida（列表密度）、anthropics/skills frontend-design 与 pbakaus/impeccable（反模板方法论）、wandb/openui（token 内嵌 prompt）。

## 交付格式

- 先给"设计 token + 组件规范"（表格、hex、具体数值），再给双端实现要点（关键代码形态描述），最后给验证清单（色值一致性、对比度、点击区、动效）。
- 涉及需要精确数值、比例、统计关系时用确定性 HTML/SVG 或表格表达，不用生成图补造。
- 来源真实：色值/规范来自官方文档或实测项目时附来源链接（见《UI设计文档.md》§9）。

<!-- 安装位置：复制本文件至 C:\Users\17948\AppData\Local\DoubaoWork\User Data\Default\.doubaowork\agent_mode\workspace\.user_skills\ui-design-for-music-app\SKILL.md（本环境 skill 根目录为 workspace\.user_skills\，每个技能一个同名目录） -->

# iOS 打磨（P5）：无障碍、Dynamic Type、iPad、性能

> 状态：**已落码、CI 编译与断言通过**（2026-11-16）。真机未验（Windows 无设备）。
> 这一期不改功能，只做"能不能被别人正常用"的四件事。

---

## 1 VoiceOver（朗读）

| 位置 | 处理 |
|---|---|
| 歌曲行（SongRow） | `accessibilityElement(children: .combine)` + 显式标签「歌名，歌手，时长」+ 提示「轻点播放」 |
| 榜单行（ChartRow） | 「第 N 名，歌名，歌手，时长」 |
| 迷你播放条 | 「正在播放：歌名，歌手」+ 提示「轻点打开播放页」；封面 `accessibilityHidden` |
| 识曲舞台 | 「开始识曲 / 停止聆听」+ `.isButton` + `accessibilityAction` |
| 歌词行 | 每行一个元素，值「第 N 行，共 M 行」，提示「跳到这一句」 |
| 播放页控件 | 播放模式（朗读当前模式）/ 上一首 / 播放暂停 / 下一首 / 下载，均有标签 |
| 平台状态行 | 合成一句「QQ 20 条，网易 超时…」，不让 VoiceOver 逐个念分隔符 |
| 进度条 | `accessibilityValue` 给"当前/总时长"，`accessibilityAdjustableAction` 支持上下滑调节 |

**机器能管的部分**写成了门禁 [check_ui_hygiene.py](tools/ios/check_ui_hygiene.py)：
硬编码字号、含文字块的固定行高——这两类会直接让"放大字号/朗读"失效，所以进 CI。

---

## 2 Dynamic Type（最大档 AX5）

| 问题 | 处理 |
|---|---|
| 行高写死 60pt | 全部改 `minHeight`（SongRow / ChartRow / PendingFeatureRow / 歌单行 / 版本行 / 迷你条） |
| 文本用 `.font(.system(size:))` | 文本一律语义字体（`.title3`/`.body`/`.footnote`…）；`system(size:)` 只允许出现在 `Image(systemName:)` 图标上 |
| 长标题截断 | 标题行 `lineLimit(2)` + 允许行高增长；专辑/歌手信息单行省略 |
| 歌词字号档 | 设置里「跟随系统 / 大 / 特大」三档，实现是把 `DynamicTypeSize` 映射到具体样式，不覆盖系统设置 |

CI 门禁：`check_ui_hygiene.py` 的 R1/R2 两条规则（18 个界面文件全绿）。

---

## 3 iPad（单列 700 居中）

- 不做侧栏（IA 已定）：仍用顶部 Tab。
- 内容统一套 `.readableWidth()`：`sizeClass == .regular` 时 `maxWidth 700` 居中，iPhone 上等于原宽。
- 判定逻辑抽到 [LayoutRules.swift](ios/JZMusicHelper/Services/LayoutRules.swift)（纯函数，10 条断言）：
  `contentWidth(available:)` = `min(available, 700)`，宽度未知（0/负数/NaN）直接给 700。
- 已套的页面：发现 / 搜索 / 识曲 / 资料库 / 歌单页 / 榜单页。

---

## 4 性能

| 项 | 之前 | 现在 |
|---|---|---|
| 封面 | 每行 `AsyncImage`，滚出屏幕再回来**重新下载+解码** | [CoverImageCache](ios/JZMusicHelper/Services/CoverImageCache.swift)：内存 NSCache（300 张 / 60MB），同一 URL 并发只发一次请求 |
| 进度回调 | 0.5s 一次，动整个播放页 | 只在播放中更新，且歌词区用 `TimelineView` 局部重绘（30fps 只作用于当前行） |
| 锁屏活动 | — | 刷新节流：内容变了最快 0.5s、只有进度在走时 6s（见 IOS-SYSTEM §5.1） |
| 列表 | `LazyVStack` | 未变（已经是懒加载） |

---

## 5 验证边界

| 验证 | 手段 | 结果 |
|---|---|---|
| 版式规则（限宽/宽屏） | CI `logic-tests` | ✅ 10 条断言 |
| 界面卫生（字号/行高） | CI 门禁 `check_ui_hygiene.py` | ✅ 18 个文件全绿 |
| 工程结构（pbxproj） | CI 门禁 `check_pbxproj.py` | ✅ 175 个对象 / 2 target |
| **VoiceOver 实际朗读顺序 / AX5 实际排版 / iPad 实际观感** | ❌ 无设备 | **未验证**（§6 是人工清单） |

---

## 6 装机要过的清单（P5 验收）

1. 设置 → 辅助功能 → 显示与文字大小 → 调到**最大**（AX5）：五个 Tab 里每个页面不截断、不重叠；
   歌曲行的歌名/歌手仍能读全（必要时换行）。
2. 开 VoiceOver，从发现页滑到播放页：每首歌应念「歌名，歌手，时长」，轻点两下能播放；
   迷你条念「正在播放：…」；播放页三个传输键各自报出功能。
3. iPad（或模拟器）：发现/搜索页内容应居中 700 宽，两侧留白，不横贯全屏。
4. 快速上下滚动搜索结果 200 行：封面不应反复闪烁重载（内存命中）；内存占用不应持续上涨。
5. 深色模式 + 增强对比度：纸底色与朱砂仍在（不出现纯黑底 + 纯白字的硬碰）。

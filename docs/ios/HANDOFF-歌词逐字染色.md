# 交接单 · A 档：歌词逐字染色与视觉打磨

> 由「微信 · 通用管家」会话完成；**已由 iOS 会话核对并合并**（补了 44pt 触摸区与无障碍动作，见提交记录）。
> 你（iOS 会话）看到这份单子时，`git status` 应该已经显示 3 个改动文件。

## 已完成

| 文件 | 改动 |
| --- | --- |
| `ios/JZMusicHelper/Views/NowPlayingView.swift` | 歌词面板整体重写：逐字染色、字号阶梯、上下淡出、spring 行推进、Reduce Motion、点行 seek + 触觉 |
| `ios/JZMusicHelper/Services/AudioPlayer.swift` | 新增 `preciseTime`：直读 `AVPlayer.currentTime()`，仅供歌词 30fps 使用 |
| `ios/JZMusicHelper/Views/SettingsView.swift` | 「歌词」区：`已缓存 N 首` + 「清空歌词缓存」（调 `LyricsService.shared.clearCache()`） |

`git diff --stat`：3 files changed, 125 insertions(+), 14 deletions(-)

## 为什么单独加 `preciseTime`

原播放器的 `addPeriodicTimeObserver` 是 **0.5 秒**一次（`AudioPlayer.swift:346`），
逐字染色按它取值会变成"每半秒蹦几个字"。方案是绕开它：歌词层用
`TimelineView(.animation(minimumInterval: 1/30))` + `player.preciseTime`，
进度条等常规 UI 仍走原来的低频 `currentTime`，不增加全页重绘。

## 与设计稿 §3.6 的对应

| 设计稿 | 实现位置 |
| --- | --- |
| 当前行 `.title2` 22/28 bold | `lyricLineView` 当前行分支 |
| 其他行 `.body` + 55% 不透明度 | `Color.secondary.opacity(0.55)` |
| 逐字染色，单字 140ms 线性 | `currentLineString`：`(nowMs - word.startMs) / 140` 插值 `mix()` |
| 无逐字时间（酷我源）回退整行高亮 | `guard line.hasWordTiming else { … }` |
| 行推进 `spring(0.38, 0.92)` | `onChange(of: player.lyricIndex)` |
| 上下淡出 | `lyricsFadeMask`（64pt 渐变） |
| `Reduce Motion` 直接跳行 | `@Environment(\.accessibilityReduceMotion)` |
| 点行 seek + 触觉 | `UIImpactFeedbackGenerator(style: .light)` |
| 行距 +4% | `.lineSpacing(4)` |

## 尚未验证（务必注意）

1. **本地没有编译过**：改动来自 Windows 环境，没有 Xcode，只有括号平衡与类型签名的人工核对。
   → 必须靠 CI 的 macOS runner 编译验证。
2. **真机滚动 / 真机取词**仍未验证（与你原先列的两条一致），需要装包看。
3. 未做全屏沉浸歌词（`.title` 28/34）——那属于另一个界面，不在本次范围。

## 下一步（建议）

```powershell
git add ios/JZMusicHelper/Views/NowPlayingView.swift `
        ios/JZMusicHelper/Services/AudioPlayer.swift `
        ios/JZMusicHelper/Views/SettingsView.swift
git commit -m "feat(ios): 歌词逐字染色与视觉打磨（字号阶梯/上下淡出/spring 推进/清空缓存）"
git push
```

推送后看 `ios-ipa.yml` 的这次 run：
- 编译过 = 语法与类型没问题；
- 编译不过 = 大概率在 `TimelineView`、`AttributedString.foregroundColor`、`LabeledContent` 这三处，按报错改即可。

## 回滚

三处都是纯 UI 层改动，未触碰歌词解析、签名、网络层。要回滚：

```powershell
git checkout -- ios/JZMusicHelper/Views/NowPlayingView.swift `
                ios/JZMusicHelper/Services/AudioPlayer.swift `
                ios/JZMusicHelper/Views/SettingsView.swift
```

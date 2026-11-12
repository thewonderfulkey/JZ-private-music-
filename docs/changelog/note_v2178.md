# v2.1.78 桌面歌词三处修正（箭头 / 逐字时间 / 进度线）

你反馈的三条都落码了：**（1）上一句 / 下一句箭头方向、（2）逐字染色"时间不准"改按字数均分、（3）底边进度线精细化**。

## 一、箭头方向反了 —— 是画法符号反了，不是功能错

`drawChevron(canvas, cx, cy, dir: Float)` 用乘法算两条臂：`moveTo(cx + dx*dir, cy-dy) → lineTo(cx - dx*dir*0.7, cy) → …`。
**尖点落在 `cx - dx*dir`、两臂在 `cx + dx*dir`**——`dir = -1`（上一句）时尖点跑到右边，正好和意图相反；`dir = +1`（下一句）同理反向。功能（`seekTo` 相邻行）一直是对的，错的只是这个图形。

修法是把隐式符号改成显式语义：签名 `drawChevron(canvas, cx, cy, left: Boolean)`，内部 `val s = if (left) -1f else 1f`，路径
`(cx - s*dx, cy-dy) → (cx + s*dx, cy) → (cx - s*dx, cy+dy)`，尖点恒在 `cx + s*dx`。
调用处写死语义：第 1 格 `left = true`（‹ 上一句）、第 3 格 `left = false`（› 下一句）。顺带把箭头放到与其它图标同高：`dx=3.6dp` / `dy=5.6dp` / 描边 1.4dp（原 3.0 / 4.6 / 1.2 比「‖」矮一截）。

## 二、逐字染色"时间不准" —— 三个原因叠在一起

1. **不是按字数均分**：旧代码 `totalChars = lines.sumOf { it.length }`，`sung = ratio * totalChars`，再 `take = min(line.length, remain).toInt()` 取整 → 每 200ms 直接**跳一整格**，且空格也算一个字；
2. **采样太粗**：ticker 200ms，一个字约 300–500ms，一格可能跨两个字，看着就是"过一会儿猛跳一下"；
3. **换句先归零**：`idx != lastIndex` 时 `setKaraoke(0f); return`，新句要等到下一拍才开始算进度，整整慢半拍；
4. 附带一处：300ms 换句过渡里新句用 `0f` 画，进场那一下没有进度。

现在改成：

- **按可见字数均分**：`totalVis = lines.sumOf { l -> l.count { it != ' ' } }`，`sungVis = ratio * totalVis`，逐行累加 `accVis`；**空格只带宽度、不占时段**；
- **字内连续推进**：逐字符累加 `wSung`，当前字按 `part = remain - used` **按比例压深**（不是一个字非黑即白），所以染色是"匀速推开"；
- **采样 100ms**（`TICK_MS 200 → 100`）；
- **换句不归零**：去掉 `setKaraoke(0f); return`，换句后立刻用当前播放位置算 ratio；
- **过渡帧带染色**：`drawPairAt(..., (1f-progress), progress, false, karaoke)`，新句进场第一帧就带进度。

口径说明：这里的"均分"= **每个字（除空格外）占等长时间**，唱到第 6.58 个字时第 7 个字压深 58%。如果你要的是"按 LRC 时间轴/字级时间戳"（很多 LRC 只有整行时间，没有逐字时间），那就是另一套（需要逐字时间戳数据源），这版先给"按字数均分"。

## 三、底边进度线：从"两根方条"改成一条标尺

旧实现只有三行：固定 `inset = dp(10f)` 的两根 `drawRect`，方角、单色、暂停直接不画。问题在于它跟文字没任何关系——句子 8 个字时线长 288dp，线比字长得多；句子 21 个字时线又和字对不上。

现在：

1. **两端与歌词文字块的实际宽度对齐**：`blockW = curLines.maxOf { measureW(curPaint, it) }`，`left = (w - blockW)/2`，`right = left + blockW` —— 线成了字的"下框线"，短句短线、长句长线；
2. **槽两端各 9% 渐隐**：`LinearGradient(paper → track → track → paper)`，两端用纸色收尾，不与首尾字形硬碰；
3. **圆头**：`th = 1.8dp`、`r = th/2`、`drawRoundRect`，距底 `5.4dp`；
4. **已唱段是实色圆头**（`fill` 62%），暂停时降为 `blend(paper, ink, 0.26)` —— **暂停不再整条消失**，恢复播放接着跑。

## 四、改动文件

| 文件 | 改动 |
|---|---|
| `ui/DesktopLyricsView.kt` | ① `drawChevron` 改 `left: Boolean` + 尺寸放大；② `drawPairAt` 字数均分（`totalVis/sungVis/accVis/wSung` 部分压深）；③ `drawProgress` 整段重写（对齐文字块 / 渐变槽 / 圆头 / 暂停保留）；④ `onDraw` 过渡帧传 `karaoke`、进度线恒画；⑤ 新增 `LinearGradient` / `Shader` 导入 |
| `data/DesktopLyrics.kt` | `TICK_MS=100L`；`tickOnce()` 换句不再归零（`seekToLine()` 里归零保留，那是跳句后的正确起点） |
| `ui/SettingsScreen.kt` | 关于页 `v2.1.78`，本版更新整段改写 |
| `app/build.gradle.kts` | vc136 / `2.1.78` |

## 五、验证

静态 **40 项，39 PASS + 1 缺口**：

- `versionCode=136` / `versionName=2.1.78`、包名 `com.jz.musichelper`、`SYSTEM_ALERT_WINDOW` / `FOREGROUND_SERVICE` 在列；
- `apksigner verify` 通过、v2 方案 true、单签名、zip 183 条目无损坏；
- dex 内 `2.1.78` 关于文案在、`v2.1.77` 已消失，三套纸色与 `dl_theme` / `dl_lock` 仍在；
- 源码级断言：`drawChevron` 已是 `left: Boolean`、PREV=`left = true` / NEXT=`left = false`、无旧 `dir: Float`；`l.count { it != ' ' }` 与 `cw * part` 在、旧 `toInt()` 取整已消失；`drawProgress` 用 `lines.maxOf { measureW(...) }` + `drawRoundRect`；`TICK_MS = 100L`；`tickOnce` 内无 `setKaraoke(0f)`；
- **缺口：`adb devices` 为空、本机无模拟器/AVD，真机冒烟仍做不了。** 均分染色的观感、100ms 采样的顺滑度、箭头方向、进度线两端与文字是否真的齐，这些只能你装上后看。

## 六、口径提醒

- **「均分」实现为"每个可见字等权 + 字内连续推进"**；若要"字级时间戳"版本，需要数据源里有逐字时间。
- **上一句 / 下一句** 仍是"跳到相邻歌词行、不切歌"；**关闭** 仍是"关掉桌面歌词开关"。这两个语义上版没改，你未反馈问题。
- 进度线宽度会随句子长短变化（对齐文字），如你更想要"固定长度的标尺"（不随句子伸缩），说一句就换。

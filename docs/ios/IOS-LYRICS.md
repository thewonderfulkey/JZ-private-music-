# iOS 歌词层：解密、取词编排、缓存与播放页歌词态

> 状态：**两段都已落码，CI 逻辑自测（172 条断言）与整包编译全绿**（2026-11-16，run #43805437759）。
> 已完成：解密/解析/清洗 → LDDC 双源取词 + 酷我官方 → 4h 缓存与并发去重 → 播放页歌词态。
> **没有**验证的是"真机上放一首歌、歌词能不能跟着走"——那需要装包（§7 有清单）。
> 上一环：[IOS-PLAYBACK.md](IOS-PLAYBACK.md)。相关：[IOS-FEATURE-PARITY.md](IOS-FEATURE-PARITY.md) §4 歌词系统。

---

## 1 做了什么

| 文件 | 职责 | 对应 Android |
|---|---|---|
| [LyricsModel.swift](ios/JZMusicHelper/Services/LyricsModel.swift) | `LyricWord` / `LyricLine` / `LyricsResult` / `LyricsError`；逐字时间是**整首绝对毫秒** | `LyricWord/LyricLine`（在 `LyricsService.kt`） |
| [LyricsCleaning.swift](ios/JZMusicHelper/Services/LyricsCleaning.swift) | 歌手清洗、损坏判定、单行清洗、LRC 解析、播放位置→行下标 | `LyricsService` 的四个同名函数 |
| [TraditionalMap.swift](ios/JZMusicHelper/Services/TraditionalMap.swift) | 繁→简逐字映射（4666 组，**由脚本从 Android 那张表生成**） | `TradToSimpMap` |
| [LddcCrypto.swift](ios/JZMusicHelper/Services/LddcCrypto.swift) | KRC 解密（4 字节头 + XOR + inflate）、QRC 解密（hex + QQ 专用 3DES + inflate）、KRC/QRC → 逐字行、→ LRC 兜底、zlib 解压底座 | `LddcCrypto.kt` |
| [LddcMatch.swift](ios/JZMusicHelper/Services/LddcMatch.swift) | 候选评分：标题×0.5 + 歌手×0.5、标题 <30 再 −35、及格线 55、时长容差 4s | `LddcMatch.kt` |
| [LddcLyrics.swift](ios/JZMusicHelper/Services/LddcLyrics.swift) | 酷狗 / QQ 双源搜索 → 评分选优 → 前 2 个候选取词 → 解密；签名、会话、dfid 注册 | `LddcLyrics.kt` |
| [KwLyrics.swift](ios/JZMusicHelper/Services/KwLyrics.swift) | 酷我官方歌词（`getlyric?musicId=`，行级时间，≥3 行才收） | `KwLyrics.kt` |
| [LyricsService.swift](ios/JZMusicHelper/Services/LyricsService.swift) | 唯一入口（actor）：酷我官方优先 → LDDC；4 小时缓存；同 key 并发共享同一 Task | `LyricsService` |
| [NowPlayingView.swift](ios/JZMusicHelper/Views/NowPlayingView.swift) | 播放页歌词态：点封面切歌词、当前行高亮、点行 seek、自动居中 | `PlayerScreen` 的大歌词视图 |

## 2 验证到什么程度（这次最有说服力的部分）

歌词这条链最容易"看起来跑通、其实解出来是乱码"，所以做了三层验证：

### 2.1 真实数据：酷狗《晴天》KRC

`tools/ios/probe_lyrics.py` 用 Python 独立实现跑真实接口（`complexsearch.kugou.com` → `lyrics.kugou.com/v1/search` → `/download`），拿到 **4192 字节 KRC 密文**，解出：

- 明文 **8405 字符**、**63 行**
- 首行 `晴天 - 周杰伦 (Jay Chou)`，**逐字 14 个词**
- 时间轴正常：`[0] 晴天 - 周杰伦` / `[2250] 词：周杰伦` / `[4500] 曲：周杰伦` / `[6750] 编曲：周杰伦` …

这份密文**原样编进了 Swift 测试**（`ios/SelfTest/LyricsFixtures.swift`），CI 里断言：解密成功、含"晴天"、明文 >5000 字符、≥40 行、首行有逐字时间、逐字时间按行内相对时间换算成绝对时间。

### 2.2 合成样本：KRC / QRC 往返

- 合成 KRC（6 行，含逐字）：断言行数、首行文本/时间/词数、逐字拼接 == 整行文本（这是逐字染色的前提）
- 合成 QRC（8 行，含逐字）：hex → 3DES → inflate → 解析，断言同上
- **两份密文都是用 Python 参考实现"加密"出来的**，Swift 只负责解——避免自证

### 2.3 3DES 逐字节对照

QQ 的 3DES 是 QQMusicDecoder 的非标准 DES 变体（S 盒输入位序反转），系统 CommonCrypto 的 DESede 与它不互认。Swift 侧是从 LDDC 完整移植的软件实现，用 **6 组 Python 独立生成的单块向量**双向断言（加密 == 密文、解密 == 明文）。

> 结论：**解密这条链是拿真实数据钉住的**，不是"编译过了就算"。

## 3 两个坑（都花了一轮 CI 才确认）

### 3.1 `COMPRESSION_ZLIB` 实际只吃裸 deflate

Apple 文档说 `COMPRESSION_ZLIB` 是 RFC 1950（zlib 包装），但实测（Xcode 16.4 / macOS 15 SDK）**喂 zlib 包装直接 `COMPRESSION_STATUS_ERROR`**，喂裸 deflate 才成功。

处理：`Zlib.inflate` 先看首字节 `CM` 是否为 8（deflate），是就**剥掉 2 字节 zlib 头**再走裸流解码；流结束后多余的 Adler-32 与补零不会被消费。这个行为写进了代码注释，避免以后有人"顺手改回去"。

### 3.2 `compression_stream` 必须先清零

`UnsafeMutablePointer<compression_stream>.allocate` 得到的是未初始化内存，`compression_stream_init` 要求 `state` 为 NULL——不 `memset` 就会初始化失败。已在代码里显式 `memset`。

## 4 取词编排（第二段）

### 4.1 优先级

```
酷我歌曲? ──是─→ 酷我官方 getlyric（平台 ID 精确、行级时间，≥3 行才收）
   │                  └─ 空词/不足 3 行 → 继续往下
   └─否─→ LDDC 双源：
            酷狗 complexsearch（签名）┐
            QQ  musicu.fcg（会话）    ├→ 候选评分（>55 且时长 ±4s）→ 前 2 个并发取词
                                      ┘     → 解密 → ≥6 行且不是乱码才算成功
```

- 评分：`标题分×0.5 + 歌手分×0.5`，标题 <30 再 −35，及格线 **55**，时长容差 **4s**（一个数都没改）
- 同分优先级：**QQ → 酷狗**（对齐 LDDC `sources=(QM, KG)`）
- 缓存：命中后 **4 小时**；同一首歌的并发请求共享同一个 `Task`（`LyricsService` 是 actor）
- 酷狗签名：`Lyric` 模块**只含 appid+clientver+业务参数**，多塞公共参数会签名失配；搜索模块反而要全套

### 4.2 这一段怎么验证的

| 验证对象 | 手段 | 状态 |
|---|---|---|
| 评分口径（11 组真实歌名/歌手） | `tools/ios/ref_match.py`（照 Kotlin 独立转写的 Python 实现）算出期望分，Swift 逐条比对 | ✅ 全部一致 |
| 酷狗签名 query | 固定 `mid`/`clienttime`，Python 算出期望串，Swift 的 `kgQuery` **逐字节**比对（SearchSong + Lyric 两条） | ✅ 一致 |
| 酷我时间解析 | `parseTimeMs` 对数字/字符串/负值/非数字/缺失 6 种输入 | ✅ |
| 取词真跑（网络） | ❌ 本机与 CI 都不该在自测里打接口（会 flaky、也会被限流） | **未验证** |

> 签名那条尤其值：签名错了不会崩，只会"酷狗歌词永远取不到"，是最难排查的一类失败。现在它被钉在断言里了。

## 5 与 Android 的口径对照

| 能力 | Android | iOS | 等价 |
|---|---|---|---|
| KRC 解密 | 4 字节头 + XOR + inflate | 同 | ✅ |
| QRC 解密 | hex + 非标 3DES + inflate | 同（Swift 移植，向量验证） | ✅ |
| KRC 逐字 | `<start,dur,offset>文字`，start 为行内相对 → 换算绝对 | 同 | ✅ |
| QRC 逐字 | `文字(start,dur)`；首词 < 行首时视为行内相对 | 同 | ✅ |
| 损坏判定 | 占位符 + 危险码点 + 必须同时含中文 | 同 | ✅ |
| 单行清洗 | 繁转简 → 剔脏字符 → 含 `<` 整行丢弃 → 中文里的 `?` 抹掉 | 同 | ✅ |
| LRC 解析 | `[mm:ss.xxx]`，xxx 按毫秒 | 同（多时间戳一行展开也一致） | ✅ |
| 繁转简 | 4666 组表 | 同表（脚本生成，不手抄） | ✅ |
| 逐字兜底 | 逐字解析失败 → 压成整行 LRC | 同（`krcToLrc` / `qrcToLrc`） | ✅ |
| 候选评分 | 标题×0.5+歌手×0.5、<30 重罚、>55、±4s | 同（11 组向量比对） | ✅ |
| 取词优先级 | 酷我官方 → LDDC 双源 | 同 | ✅ |
| 缓存 | 4h + 并发共享 | 同（actor） | ✅ |
| 歌词界面 | 大歌词：当前行朱砂、其余 45% 弱色、自动居中 | 播放页：点封面切歌词、当前行 accent+bold、其余 75%、自动居中、点行 seek | 🔧 视觉待按设计稿打磨 |
| 逐字染色 | 按每字 start/dur 染色 | 数据已带 `words`，**渲染还没用上** | ⏳ |
| 歌词偏移校准 | Android 也没有 | 同（不做） | ✅ |

## 6 已完成（逐字染色，第二轮补）与仍未做的

逐字染色已落码：`TimelineView(.animation(1/30))` + `player.preciseTime` 按每字 start/dur 插值（单字 140ms 线性），
字号阶梯（当前行 `.title2` bold / 其他行 `.body` 55%）、上下 64pt 淡出、行推进 spring(0.38, 0.92)、
`Reduce Motion` 直接跳行、点行 seek + 轻触觉、44pt 触摸区与 VoiceOver 动作都已对上设计稿 §3.6 / §8。
参见 [HANDOFF-歌词逐字染色.md](HANDOFF-歌词逐字染色.md)。

仍未做的：

| 缺什么 | 说明 |
|---|---|
| **逐字染色** | `LyricLine.words` 已有每字 start/dur，渲染层还没按字推进颜色（设计稿 §3.6 的"跟着唱到哪个字亮哪个字"） |
| 歌词视觉打磨 | 字号阶梯、上下淡出、当前行过渡时长、点行 seek 的触觉，都按设计稿 §3.6 再对一遍 |
| 歌词缓存清理入口 | `LyricsService.clearCache()` 已备好，设置页还没接 |
| 真实 QQ QRC 样本 | 采集时被 IP 限流（`request.code=2001`），仓库里是合成样本；拿到真样本重跑脚本即可 |

## 7 复现方式（换台机器也能重跑）

```bash
python tools/ios/probe_lyrics.py "晴天" "周杰伦"   # 拉真实 KRC/QRC，产出 .build/lyrics-fixtures/
python tools/ios/gen_kg_signature.py              # 生成酷狗签名的期望 query
python tools/ios/gen_lyrics_fixtures.py           # 生成 ios/SelfTest/LyricsFixtures.swift
python tools/ios/gen_traditional_map.py           # 从 Android 的 TraditionalMap.kt 重新生成繁简表
```

> QQ 的 `musicu.fcg` 在采集时有 IP 限流（`request.code=2001`，返回空候选），所以仓库里的 QRC 样本是**合成**的；
> 真实 QQ QRC 拿到后重跑上面两步即可替换，Swift 侧不用改（fixture 驱动的断言会自动用新样本）。

## 8 装到手机上要看的三件事

1. 放一首**有逐字歌词**的歌（酷狗源）→ 播放页点封面 → 歌词出现，当前行高亮并自动滚到中间。
2. 一首**酷我来源**的歌 → 歌词来源显示"酷我"（行级时间，没有逐字）。
3. 切歌 → 歌词跟着换；同一首切走再切回来 → 应该几乎立刻出现（4h 缓存命中）。

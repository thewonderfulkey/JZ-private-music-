# iOS 歌词层：解密、取词编排、缓存与播放页歌词态

> 状态：**取词链已按 LDDC 口径收敛到四步（r73，2026-11-17），CI 逻辑断言与整包编译为准**。
> 已完成：解密/解析/清洗 → LDDC（酷狗）取词 + 酷我官方 + LRCLIB + 网易云 → 4h 缓存与并发去重 → 播放页歌词态。
> **当前口径看 §11**；§10 及以前的"三层验收"是历史实现，r72 起已删除。
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

1. 放一首**有逐字歌词**的歌（酷狗源）→ 播放页点歌词面板（现在常驻，不用点封面）→ 歌词出现，当前行高亮并自动滚到中间。
2. 一首**酷我来源**的歌 → 歌词来源显示"酷我"（行级时间，没有逐字）。
3. 切歌 → 歌词跟着换；同一首切走再切回来 → 应该几乎立刻出现（4h 缓存命中）。

## 9 2026-11-16 真机反馈「歌词全是空」的复盘（必读）

老板真机录屏里歌词区一直是空的。排查结论是**两个问题叠在一起**，都不是解密算法：

| 层 | 问题 | 证据 | 修法 |
|---|---|---|---|
| 网络 | `LddcLyrics` 里酷狗三个端点写的是 `http://`（complexsearch / lyrics.v1 / download） | iOS 的 ATS 默认拒绝明文请求，`URLSession` 直接返回 -1022 `NSURLErrorAppTransportSecurityRequiresSecureConnection`。**本地 Python 探针是通的**——因为 urllib 没有 ATS，这个差异把问题藏了整整两轮 | 三处改 `https://`（实测三个端点都 200）+ `Info.plist` 加 `NSAllowsArbitraryLoads`（音频直链也有一堆明文地址） |
| 界面 | 歌词藏在"点封面"后面（`showLyrics` 默认 false），不点永远看不见；空态也没有重试 | 播放页代码 | 歌词面板常驻在封面下方；空态写原因 + 「重试」；打开播放页若仍为空自动再取一次（`PlayerEngine.reloadLyrics`） |

这次改完，酷狗源在真机上才**第一次真的发起过请求**。剩下的未知只有"到手的数据在真机上能不能正确渲染"这一层，装机清单见 [IOS-PRODUCT-FIXES.md](IOS-PRODUCT-FIXES.md) §4。

## 10 2026-11-17「七里香总返回 live 词」的复盘：用歌词文件头判版本

老板真机反馈：七里香播原版，词却总是 live 版，逐行时间整体对不上。逐层看下来：

| 层 | 事实 | 为什么不够 |
|---|---|---|
| LDDC 主评分（与 APK 逐字一致） | 标题×0.5 + 歌手×0.5，标题<30 再 −35，及格 55，候选时长 ±4s | 「七里香 (Live)」标题 LCS ≈46、歌手 100 → **总分 73 直接过线**。同歌手同主标题的现场版，主公式天然拦不住 |
| 候选时长过滤 | 用搜索结果里的 `Duration` | 这个字段经常是 0 或差几秒；live 与录音室版相差 15s 以上时才有机会拦住 |
| 歌词文件本身 | KRC 头部 `[total:261000]`、LRC `[length:04:21]`、还有 `[ti:]/[ar:]/[al:]` | **原来完全没解析**，而它才是"这份词对应哪一版音频"的直接证据 |

现在的三层（都不改主公式）：
1. `LyricsCleaning.meta(_:)` 解析文件头（新增 `LyricsMeta`），KRC/QRC 解密后的明文直接喂。
2. `LddcLyrics.headerRejection`：文件头时长与本曲差 >**8s**、标题分 <50、歌手分 <30 → 丢掉这个候选换下一个（候选从 2 个放宽到 3 个）。元数据缺失**放行**——真实酷狗 KRC 只有 `[ti:]/[ar:]/[al:]/[by:]/[offset:]`，没有 `[total:]`，一刀切会把正常词整批误杀。
3. `LddcMatch.versionPenalty`：候选标题带「查询没有的」live/现场/演唱会/翻唱/cover/remix/伴奏/纯音乐/karaoke/片段/demo/acoustic → 扣 **35** 分（73 − 35 = 38 < 55）。查询自己就是 Live 时不扣。

排序也顺手改成「分数降序 → 时长差升序 → QQ 优先」，同分时更接近本曲时长的候选先被试。

新增断言（`ios/SelfTest/main.swift` 第五轮两段）覆盖：文件头三种时长写法、`[ti:七里香 - 周杰伦]` 剥歌手后缀、KRC 行不被误当标签、版本标签惩罚（含 `Olive` 不误判）、时长差恰好 8s 的边界、真实酷狗 KRC 缺 `[total:]` 必须放行。

## 11 r73 取词链（当前口径，2026-11-17）

老板 r73 的录屏（320s）里四首歌：《那天下雨了》55 行 LDDC 逐字、《曾经的你》47 行 LDDC 逐字、
《晴天》63 行 LDDC 逐字——都对；**《发如雪》51 行「酷我」是错的**：
正文第一句「本字幕由QQ音乐独家AI字幕技术生成」，后面全是专辑介绍口播。

### 11.1 那条 51 行的错词是怎么来的（实测复现）

1. 酷我里周杰伦的《发如雪》**没有正片**。`search.kuwo.cn/r.s?all=发如雪 周杰伦` 的 20 条候选是
   伴奏/DJ版/拍摄花絮/霍元甲/现场版/升2（2026-11-17 实测，逐条列出）。
2. 旧链第 3 步「按名字去酷我兜底」用 `NameMatch` 挑中「发如雪 拍摄花絮」（118s，一条专访视频），
   它的官方"歌词"就是那 51 行字幕文案。**行数够、时间轴也有，所以每一道旧闸门都放行了。**
3. 而这一步排在 LRCLIB 之前，于是 LRCLIB 那份正确的 113 行同步词根本没机会出场。

### 11.2 现在的链（四步，任一步拿到就是答案）

| 顺序 | 源 | 触发条件 | 备注 |
|---|---|---|---|
| ① | LDDC（酷狗 KRC） | 一律先走 | 逐字；搜不到候选时**只用歌名再搜一次**（LDDC `auto_fetch` 原样行为） |
| ② | 酷我官方词 | **仅当这首歌自身就是酷我那一版**（平台 ID 精确） | 不再按名字猜；只拦"这是文案不是歌词" |
| ③ | LRCLIB | LDDC 失败 | `/api/get` 精确命中 → `/api/search` 挑 |
| ④ | 网易云 | 前三条都失败 | |

### 11.3 四条硬口径（全部纯函数，SelfTest 直接断言）

1. **打分仍是一个字没改的 LDDC 公式**：标题×0.5 + 歌手×0.5（标题<30 再 −35）、及格 55、时长差 ≤4s。
2. **原版优先、变体垫底**（`LddcLyrics.rank`）：查询里没有的版本标记（live/伴奏/花絮/访谈…）
   只能排在原版后面。公式本身拦不住——「发如雪 拍摄花絮」标题 54.5 + 歌手 100 = 77 分。
   查询自己带 (Live) 时，Live 候选不算"多出来的标记"，照常第一（老板要的"歌名带 live 优先 live 词"）。
3. **按名字搜的源（LRCLIB / 网易云）一律不收变体**：宁可没词，也不贴另一版。
4. **正文闸门**（`LyricsCleaning.commentaryReason` + `contentVersionRejection`）：
   正文前 12 行出现「本字幕由 / AI字幕 / 本视频 / 点击订阅 …」→ 这不是歌词，拒收。
   正文前 2 行自报是另一个版本（Live/演唱会/伴奏…）→ 拒收。
5. 取词后若 KRC/QRC 文件头写了歌名且与候选歌名标题分 <40 → 判为"下到别人的词"，换下一个候选。

### 11.4 本地取词服务（`services/lddc/code/LDDC/lyrics_api_server.py`）也一起修了

老板说的"本地的 LDDC 服务有点问题"就是这个文件：它以前**直接取 `results[0]`**。实测：
「七里香 周杰伦」在网易云的第一条是「七里香 (女声版)」、在 LRCLIB 的第一条是歌手写作 GM Lyric 的上传。
现在它调 LDDC 自己的 `calculate_title_score/calculate_artist_score` + 同样的 55 分/±4s/最多 3 个候选。
（LDDC.exe 那个 GUI 本来就是对的——它走 `auto_fetch`；错的只是这个 HTTP 包装。）

### 11.5 还没做的

- **QQ 音乐（QM）没有接进 App**：实测同一台机器上时通时不通（`req.code=2001`，前两首通、后两首不通）。
  它的 QRC 是逐字最全的一份，等它稳定或加退避后再并行接回，权重排在 KG 之前。
- 真机上"酷狗取词两条通道都没成"那一类失败，本轮靠 ③ LRCLIB 兜住，没有正面解决网络层。

---

## 12 点歌词快进/后退之后"退回上一句"的根因（第二十一轮，2026-11-18）

老板反复提的那件事（"用歌词快进或后退，滚动原本是准的又不准了"），根因不在 seek 落地——
而在**推导口径**：`indexAt` 是「行时间 ≤ 位置」，而真机 `AVPlayer.seek` 常落到目标**之前**
几百毫秒（远端流按关键帧对齐）。于是点下去那一刻钉住的这一行，在下一拍 ticker（40ms）
按真实位置重算时就被推成**上一句**；滚动跟着同一个下标走，看起来就是"闪一下、退回一句、从此不对"。

修法（`LyricsUXRules.lyricSeekHoldToleranceMs` + `LyricsCleaning.lyricSeekHoldDecision`，纯函数有断言）：

| 情形 | 行为 |
|---|---|
| 播放头还没走到被点那一行，且差距 ≤ 2500ms | **继续钉住那一行**（高亮与滚动同一下标） |
| 播放头走到/超过这一行的时间戳 | 立刻交还正常推导（`indexAt`），此后与普通播放完全一致 |
| 差距 > 2500ms（多半是拖了进度条） | 不钉：这已经不是"落点误差"，按位置走 |
| 拖进度条 / 换歌 / 重取歌词 | 清掉钉子 |

规则**不看平台、时长、是否逐字**，所以所有歌表现一致——这正是老板要的"所有音乐保持一致"。
断言：`ios/SelfTest/main.swift` 的 `section("歌词：点歌词跳转后的「等它唱到」窗口")`。

---

## 13 第二十二轮：seek 完成回调"提前返回"导致的错行（9 分钟录屏复现）

老板 r85 的录屏（567 秒）里，**位置 0:49** 时高亮显示的是《黄昏》**1:36** 那一行"爱情进入永夜"
（该曲 51 行 · 酷我）。核对 `getlyric` 的时间戳：0:49 应该是"有离开自己的感觉"（0:47），
高亮整整**跳到 47 秒之后**。同一段里 1:45 → "依然记得从你眼中"（1:43）、2:59 → "黄昏的地平线"（2:56）
都是对的，说明**不是歌词文件错，而是跳转后的那一下算错**。

根因：`AVPlayer.seek` 的完成回调会**提前返回**（`finished=true`，但 `currentTime()` 还是旧值）。
旧实现（r77）一看回调就解除保护，40ms 的歌词 ticker 立刻拿**旧位置**重算 → 高亮/滚动跳到几十秒外，
并一直错到播放头追上那一行为止（所以表现为"瞬间对不上，之后也乱"）。

现在的时间源（纯函数 `LyricsUXRules.seekClockSource`，6 条断言）：

| 情形 | 用哪个位置 |
|---|---|
| 播放头已在目标 ±`seekLandToleranceMs`(1200ms) 内 | **真实位置**（真落地了） |
| 还没到目标，但 `seekOptimisticMaxSeconds`(1.5s) 未到期 | **seek 目标**（画面不倒退） |
| 窗口到期，播放头还报旧值 | **真实位置**（宁可跳一下，绝不冻住） |

要点：**任何时刻都必须给出一个位置**——旧实现里 `.wait` 会直接 `return`，等于冻住高亮
（兜底 10 秒就是这个冻住的时长）。点歌词跳转再叠加 §12 的"等它唱到"钉子；两条路径共用同一个时钟，
进度条拖动也走它，所以"所有歌、所有跳转方式"表现一致。

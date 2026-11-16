# iOS 歌词层（第一段）：解密、解析、清洗

> 状态：**已落码、CI 逻辑自测与整包编译全绿**（2026-11-16，run #43804206116）。
> 这一段只做「把加密歌词变成带逐字时间的行」，**还没有** LDDC 搜索/取词编排和歌词界面——那是下一段（§6）。
> 上一环：[IOS-PLAYBACK.md](IOS-PLAYBACK.md)。相关：[IOS-FEATURE-PARITY.md](IOS-FEATURE-PARITY.md) §4 歌词系统。

---

## 1 做了什么

| 文件 | 职责 | 对应 Android |
|---|---|---|
| [LyricsModel.swift](ios/JZMusicHelper/Services/LyricsModel.swift) | `LyricWord` / `LyricLine` / `LyricsResult` / `LyricsError`；逐字时间是**整首绝对毫秒** | `LyricWord/LyricLine`（在 `LyricsService.kt`） |
| [LyricsCleaning.swift](ios/JZMusicHelper/Services/LyricsCleaning.swift) | 歌手清洗、损坏判定、单行清洗、LRC 解析、播放位置→行下标 | `LyricsService` 的四个同名函数 |
| [TraditionalMap.swift](ios/JZMusicHelper/Services/TraditionalMap.swift) | 繁→简逐字映射（4666 组，**由脚本从 Android 那张表生成**） | `TradToSimpMap` |
| [LddcCrypto.swift](ios/JZMusicHelper/Services/LddcCrypto.swift) | KRC 解密（4 字节头 + XOR + inflate）、QRC 解密（hex + QQ 专用 3DES + inflate）、KRC/QRC → 逐字行、→ LRC 兜底、zlib 解压底座 | `LddcCrypto.kt` |

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

## 4 与 Android 的口径对照

| 能力 | Android | iOS | 等价 |
|---|---|---|---|
| KRC 解密 | 4 字节头 + XOR + inflate | 同 | ✅ |
| QRC 解密 | hex + 非标 3DES + inflate | 同（Swift 移植，向量验证） | ✅ |
| KRC 逐字 | `<start,dur,offset>文字`，start 为行内相对 → 换算绝对 | 同 | ✅ |
| QRC 逐字 | `文字(start,dur)`；首词 < 行首时视为行内相对 | 同（同一自适应口径） | ✅ |
| 损坏判定 | 占位符 + 危险码点 + 必须同时含中文 | 同 | ✅ |
| 单行清洗 | 繁转简 → 剔脏字符 → 含 `<` 整行丢弃 → 中文里的 `?` 抹掉 | 同 | ✅ |
| LRC 解析 | `[mm:ss.xxx]`，xxx 按毫秒 | 同（多时间戳一行展开也一致） | ✅ |
| 繁转简 | 4666 组表 | 同表（脚本生成，不手抄） | ✅ |
| 逐字兜底 | 逐字解析失败 → 压成整行 LRC | 同（`krcToLrc` / `qrcToLrc`） | ✅ |
| 代理区/控制字符 | 剔除 | 同 | ✅ |

## 5 这一层还没做的

| 缺什么 | 说明 |
|---|---|
| 酷我官方歌词接口 | `getlyric?musicId=`（行级时间，酷我歌曲优先走它，≥3 行才收） |
| LDDC 搜索/取词编排 | 酷狗 `complexsearch` + 签名、QQ `musicu.fcg`（GetSession/DoSearch/GetPlayLyricInfo）、候选评分（`LddcMatch`：标题×0.5+歌手×0.5、<30 重罚 −35、>55 才收、时长 ±4s）、取前 2 个候选取词、≥6 行才算成功 |
| 缓存 | 4 小时内存缓存 + 同 key 并发共享（Android 有，避免切歌重复请求） |
| 歌词界面 | 播放页歌词态（逐字染色、点行 seek、自动居中）——按设计稿 §3.6 |

## 6 下一段计划

1. `LddcMatch.swift`（候选评分，纯函数，可断言）→ 2. `LddcLyrics` 取词编排（酷狗签名 / QQ 会话）→ 3. `KwLyrics`（酷我官方）→ 4. `LyricsService`（优先级 + 缓存 + 并发去重）→ 5. 播放页歌词态。

顺序理由：评分层是纯逻辑，先把"选对歌"的判定钉死，再接网络——否则取词跑通但选了翻唱版的词，界面看着没问题、实际全错。

## 7 复现方式（换台机器也能重跑）

```bash
python tools/ios/probe_lyrics.py "晴天" "周杰伦"   # 拉真实 KRC/QRC，产出 .build/lyrics-fixtures/
python tools/ios/gen_lyrics_fixtures.py            # 生成 ios/SelfTest/LyricsFixtures.swift
python tools/ios/gen_traditional_map.py            # 从 Android 的 TraditionalMap.kt 重新生成繁简表
```

> QQ 的 `musicu.fcg` 在采集时有 IP 限流（`request.code=2001`，返回空候选），所以仓库里的 QRC 样本是**合成**的；
> 真实 QQ QRC 拿到后重跑上面两步即可替换，Swift 侧不用改（fixture 驱动的断言会自动用新样本）。

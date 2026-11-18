# iOS 媒体链路总览：搜索 / 音源 / 封面 / 歌词（内置了哪些 API，各自怎么走）

> 2026-11-18 整理（第三十一轮之后）。代码位置都标了文件名，口径以代码为准；本文只做"看懂"用。
> 一句话：**搜索四条平台线 → 点歌先看本地文件 → 再按平台取流 → 不够就跨平台补 → 拿到音频后验时长；
> 封面和歌词是两条独立的兜底链，跟取流并行跑。**

---

## 0 一张图

```
用户在 搜索/歌单/歌手/榜单/新歌 点一首歌
        │
        ├─（有下载）→ 直接播本地文件（不走网络）
        │
        └─ 取流：本平台后端（1~2 个，并行，每个 12s）
                   ↓ 都没有
                 同曲跨平台补源（搜同名同歌手 → 逐条取流，40s 封顶）
                   ↓ 还没有
                 等 2s / 2.5s / 3s 再各试一轮（设置可关）
                   ↓
                 拿到 URL → AVPlayer 装 item → 实测时长与曲目差 >25s 就丢弃换下一首
        │
        ├─ 封面（并行）：本地文件 → 歌曲自带 picURL → 酷我按 rid → QQ 严格匹配 → iTunes → 占位
        └─ 歌词（并行）：① 酷我官方 → ② LDDC（酷狗+QQ）→ ③ LRCLIB → ④ 网易云 → 空态写原因
```

---

## 1 内置 API 清单（按用途）

| 用途 | 服务 / 域名 | 端点 | 现状 |
|---|---|---|---|
| 搜索 · QQ | `c.y.qq.com` | `/soso/fcgi-bin/client_search_cp` | 20 条/页，正常 |
| 搜索 · 网易 | `music.163.com` | `/api/search/get` + `/api/song/detail`（补封面） | 20 条/页，正常 |
| 搜索 · 酷我 | `search.kuwo.cn` | `/r.s`（`vipver=MUSIC_8.7.8.0_WX`） | 正常；`MVPIC` 约 78% 有图 |
| 搜索 · 酷狗 | `mobiles.kugou.com` | `/api/v3/search/song` | 正常（旧 `mobilecdn` 证书不匹配已弃用） |
| 取流 · QQ | `cyapi.top` | `/API/qq_music.php`（mid 直查） | 通，但只给 ~97kbps m4a（按实测标"标准"） |
| 取流 · 网易 | `music-api.gdstudio.xyz` | `/api.php`（source=netease&br=128/320/740） | 主通道（320 实测 320k mp3） |
| 取流 · 网易（备） | `oiapi.net` | `/api/Music_163` | **当前失效**（code=0 但没有 url），保留等恢复 |
| 取流 · 酷我 | `api.yaohud.cn` | `/api/music/kuwo`（按歌名+歌手搜） | 健康（flac 直链），需要身份校验 |
| 取流 · 酷狗 | `m.kugou.com` | `/app/i/getSongInfo.php?cmd=playInfo&hash=` | **当前不返回 url**（能搜不能播），靠跨平台补位 |
| 封面 · 酷我 | `artistpicserver.kuwo.cn` | `/pic.web?type=rid_pic&size=320&rid=` | 正常；有 http / kwcdn / starheads 三个坑 |
| 封面 · iTunes | `itunes.apple.com` | `/search?term=&entity=song&limit=10` | 最后一级公共兜底 |
| 歌词 · 酷我 | `www.kuwo.cn` | `/openapi/v1/www/lyric/getlyric?musicId=` | 行级，只对酷我歌 |
| 歌词 · 酷狗 | `complexsearch.kugou.com` / `lyrics.kugou.com` / `krcs.kugou.com` | 搜索 → `/v1/search` + `/download`（krcs 老接口兜底） | 逐字 KRC，签名 |
| 歌词 · QQ | `u.y.qq.com` | `/cgi-bin/musicu.fcg`（GetSession → DoSearch → GetPlayLyricInfo） | QRC 逐字 |
| 歌词 · LRCLIB | `lrclib.net` | `/api/get`（精确）+ `/api/search` | 独立公开源，标准 LRC |
| 歌词 · 网易 | `music.163.com` | `/api/search/get` + `/api/song/lyric?id=` | 行级 LRC |
| 歌单 / 歌手 / 榜单 | `wapi.kuwo.cn` / `kbangserver.kuwo.cn` | 见 [IOS-DISCOVER.md](IOS-DISCOVER.md) | 发现页用 |

> ATS：`Info.plist` 现在是 `NSAllowsArbitraryLoads = true`（早期曾严格），但代码仍统一把取流/封面地址
> **http 升 https**（`UrlNormalizer` / `CoverResolver.ridPicURL` / `ITunesCover`）——升了取不到就按坏源处理。

---

## 2 搜索：四条平台线并发

- `SearchService.searchAll`：四个 `SearchAdapter` **同时**跑，每个平台独立 **8s 超时**；单平台失败只标"超时/失败"，绝不外抛。
- 结果合并后 `SearchRanker.rank` + `dedupe`：先排序、再按「归一化歌名+歌手」去重，保留匹配度最高那条；
  被合并掉的平台版本**没有丢**——播放时 `SameSongCrossResolver` 还会用它补源。
- 各平台细节：
  - QQ：`songmid` 进 `platformID`，封面用 `albummid` 拼 `y.gtimg.cn/.../T002R300x300M000<mid>.jpg`；
  - 网易：搜索只回 id，封面再打一次 `/api/song/detail`（20 首一次）；
  - 酷我：`MUSICRID` 去掉 `MUSIC_` 当前缀当 rid；`KuwoParser` 过滤相关性；整页都是变体时也返回变体（避免"0 首"）；
  - 酷狗：`hash` 进 `platformID`，封面取 `trans_param.union_cover`（`{size}`→500）。

---

## 3 音源（"音乐返回"）：三级取流 + 两道验真

### 3.1 每次点歌的完整顺序（`AudioPlayer.loadCurrent` / `resolveStream`）

1. **本地文件优先**：`DownloadManager.localFileURL` 命中就直接播，离线也能放，省一次解析。
2. **本平台后端**（`SourceRegistry.adapters(for:)`，与歌曲同平台的适配器，**并行**，每个 12s）：
   - QQ → `CyapiQQAdapter`；网易 → `GdstudioNeteaseAdapter` + `OiapiNeteaseAdapter`；酷我 → `YaohuKuwoAdapter`；酷狗 → `KugouPlayInfoAdapter`。
3. **质量择优**（`SourcePicker`）：真无损容器（flac/ape/wav）> 自报无损 > 高品 > 标准；m4a 降权；同分优先"按平台 ID 直连"（directId）。
4. **跨平台补源**（`SameSongCrossResolver`，设置可关）：用「歌名+歌手」四平台搜，按同曲判定挑候选
   （歌名+歌手匹配、时长差 ≤12s；原唱 vs Live/节目版只允许差 ≤3s），最多 8 条、每批 3 条、总共 40s 封顶；
   拿到一条可用源就返回。
5. **重试**：还失败就等 **2s / 2.5s / 3s** 再各来一轮（设置「无源自动换源」关掉就只试 1 轮）。
6. **装 item 后验真**（`wire` + `PlaybackRules`）：
   - `PlaybackRules.durationMismatch`：实测音频时长与曲目元数据差 **>25s** → 判坏源，`rejectSource`（拉黑该 URL）→ 换下一首；
   - `AVPlayerItem` `.failed` / 播放中断 → 同样拉黑换源；
   - 连续 3 首无源（设置可改）→ 停住并写"连着 3 首都没有可用的播放源"，不把队列烧光。

### 3.2 每个后端都要先"验真"

`StreamVerifier.inspect`：对 URL 做一次 `Range: bytes=0-4095` 的 GET，读 16 字节容器头
（`fLaC` / `OggS` / `ftyp` / `ID3` / `RIFF` / mp3 帧头），同时拿 `Content-Range` / `Content-Length` 算总字节。
`QualityFacts` 再用「容器 + 总字节 ÷ 时长」反推真实档位（flac/wav 直接无损；≥256k 高品；否则标准）——
**接口自报的音质一律不信**，这是为了消灭"标无损、下到 128k"。

### 3.3 下载（`DownloadResolver.plan`）

和播放共用一条换源链，但多一层"目标档"：
本平台后端 → 跨平台补源 → 通用搜索式后端（妖狐酷我，无损档或"一条源都没有"时才打）→
按 `isExact`（容器 + 实测码率）筛出目标档，最多留 3 条 exact + 1 条"最高可得档"兜底。

---

## 4 封面：五级 + 三层缓存

### 4.1 解析顺序（`CoverResolver` + `CoverImageCache.image(for:)`）

1. **已下载歌曲的本地封面**（下载时一起存的，离线也有图）；
2. 歌曲自带 `picURL`（酷狗旧 `imgessl` 除外——CDN 软失败，固定回黑胶占位图）；
3. **酷我按 rid 同平台取图**：`artistpicserver/pic.web?type=rid_pic&size=320&rid=`（只对纯数字 rid 的酷我歌）；
   统一 http→https、`.kwcdn.kuwo.cn`→`.kuwo.cn`、**拒收 `/starheads/`（歌手头像）**；
4. **QQ 严格匹配**：`歌名 歌手` 搜一次（≤10 条），歌名完全相等 + 歌手任一片段相等才取图；
5. **iTunes 兜底**：`term=歌名 歌手`，核心名相等/包含 + 歌手片段匹配，`artworkUrl100` 换 600×600。

全失败 → 返回 nil，UI 落占位图（不贴错图，宁可没有）。

### 4.2 缓存与坏地址

- 图片三层：内存 `NSCache`（300 张）→ **磁盘** `Caches/cover-images`（600 张，MD5 命名，按最后访问淘汰）→ 网络；
- URL 解析结果：内存 + `UserDefaults`（最多 300 条），同一首歌不重复搜；
- **坏地址黑名单**：加载 404/解码失败 → `markDead` 拉黑该 URL 并清掉缓存，下一次自动降到下一级；
- 并发闸门 3（首屏几十行同时没图也不会打请求风暴），单次 5s 超时。

---

## 5 歌词：四步，先准后全

`LyricsService.resolve`（8 秒硬超时），顺序是老板 r74 拍板、不许调的：

| 步 | 源 | 条件 | 拿到的形态 |
|---|---|---|---|
| ① | **酷我官方** `getlyric?musicId=` | 只对酷我平台的歌；musicId 精确；≥6 行；排除"字幕/文案" | 行级（秒） |
| ② | **LDDC：酷狗 + QQ** | 两个搜索源并行（QQ 只给 2.5s）；候选过**身份闸**后按分数取前 2 个，各试 2 次；5.5s 预算 | 酷狗 KRC / QQ QRC 逐字（解密后） |
| ③ | **LRCLIB** | `/api/get` 精确命中，失败再 `/api/search` 按同一套评分挑 | 标准 LRC 行级 |
| ④ | **网易云** | 搜索 15 条 → 同一套身份闸 → 前 3 个候选逐个取 `/api/song/lyric` | 行级 LRC |

- **身份闸**（`LddcMatch.identityRejection`，②③④共用）：时长差 **≤4s**、歌手分 **≥90**、**版本类一致**
  （原版↔原版、Live↔Live、伴奏↔伴奏）；再要求总分 >55（标题×0.5 + 歌手×0.5）。
- **词自报身份**：KRC/QRC 文件头的 `[ti:]/[ar:]`、`[total:]` 与正在播的这首比对，不一致就换下一个候选。
- **回退不许跨歌手/跨版本类**：首选失败先重试自己一次，仍失败才换第 2 个同类候选；都没有就**空着**并写原因
  （"这首歌没有原唱歌词（词源里只有别的版本）" / "没搜到词源" / "取词超时" / "四个源都没取到"）。
- **时间轴对齐**：拿到词后按音源实际时长拉一遍（`LyricsCleaning.alignedToAudio`），比例写进来源标签（"已对齐 ×1.02"）。
- 缓存：内存 4 小时、200 首；并发请求共享同一个 Task。

---

## 6 缓存一览

| 数据 | 层 | 失效 |
|---|---|---|
| 封面图 | 内存 300 → 磁盘 600 张（60MB 上限） | LRU / 系统清 Caches |
| 封面 URL | 内存 + UserDefaults 300 条 + 坏地址黑名单 | 加载失败即拉黑 |
| 歌词 | 内存 4h / 200 首 | 过期 / 设置里"清空歌词缓存" |
| 音源 | **不缓存**（每次点歌重新解析） | — |
| 歌曲列表（发现页） | 每个模块当天缓存（见 IOS-DISCOVER §5.1） | 跨天 / 下拉刷新 |

---

## 7 现状与已知断点（看这张表就知道哪条线在生效）

| 链路 | 主用 | 兜底 | 已知问题 |
|---|---|---|---|
| QQ 音源 | cyapi（m4a 标准） | 跨平台 | 只有 ~97kbps，达不到高品 |
| 网易音源 | gdstudio | oiapi（失效中）、跨平台 | oiapi 恢复前等于单通道 |
| 酷我音源 | 妖狐（搜索式） | 跨平台 | 无 rid 直连，靠歌名+歌手 + 身份校验 |
| 酷狗音源 | 官方 playInfo | 跨平台 | 官方接口当前不回 url |
| 封面 | picURL / 酷我 rid_pic | QQ 严格、iTunes | 酷我部分 rid 地址 404（已拉黑跳级） |
| 歌词 | 酷我官方 / LDDC | LRCLIB、网易云 | 酷我非官方曲、冷门歌可能只有行级或空 |

> 设计口径就两条：**宁缺毋滥**（别人的版本/封面/音源宁可不要）、**失败写原因**（空态能看出断在哪一环）。

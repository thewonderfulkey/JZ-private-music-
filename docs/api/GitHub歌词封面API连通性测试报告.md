# GitHub 歌词 / 封面 API 连通性测试报告（2026-10-28 实测）

## 1 概述与摘要

> 本次调研 GitHub 上可获取【歌曲歌词】与【歌曲/专辑封面】的 API 项目并逐个做连通性测试，与本系列《GitHub音乐源连通性测试报告》（100 条音乐源、非废源 33 条，已归入《接口归类清单-音乐与歌词.md》§1.2）同口径、同测试锚点，作为 iOS SwiftUI / 安卓 Kotlin「JZ的音乐助手」新增【歌词显示】与【专辑封面】功能的选型依据。

- **与 §1.2（33 条音乐源）的衔接**：33 条非废源音乐接口按平台分为酷我系（haitangw/nxinxz/zddyr/oiapi/mobi.s，出 `rid`）、QQ 系（cyapi.top/a.aa.cab，出 `songmid`）、网易云系（gdstudio/oiapi Music_163/s0o1，出 `id`）、酷狗系（星海 kg 支流，出 `hash`）。本次歌词/封面接口按**同一平台标识符**（rid/songmid/id/hash）与之配对，音乐源负责出音频 URL，歌词/封面接口负责同平台补 LRC 文本与封面图。
- **已知基线（用户此前上传并已测通，纳入本轮核对）**：LrcApi（本地 28883 + 公开 api.lrc.cx，含 `/lyrics` 与 `/cover` 路由）与 LDDC 歌词搜索（本地 uvicorn 8000，`/lyrics?source=lrclib/ne/qm/kg`，酷狗源开箱即用）——本轮对其重新实测确认现状，并作为"纯搜索接口"子类的参照基准。
- **结果摘要（实测）**：歌词类 **15 个 HTTP API 源**——可用 3 / 部分可用 2 / 不可用（废源）10（另 2 个纯客户端库未计）；封面类 **7 个 HTTP API 源**——可用 3 / 部分可用 2 / 不可用（废源）2（另 3 个需鉴权/本地文件型/脚本未计）。**推荐集成：歌词 = 网易云官方直连（网易系音乐源按 id 配对）+ LrcApi 跨平台兜底；封面 = QQ songinfo→y.gtimg.cn 与酷狗 getSongInfo（均无防盗链直链）+ LrcApi /cover 兜底（6/6 full、3000px+）。**详见 §4.3。

### 1.1 歌词 / 封面接口与音乐源的配对逻辑（App 集成设计）

音乐源返回的 `(platform, 平台标识符)` 直接映射到同平台歌词/封面端点；搜索式接口（LrcApi/LDDC/LRCLIB）按 `title+artist` 做跨平台兜底：

| 音乐源平台 | 音乐源返回标识 | 歌词接口（直连/代理） | 封面接口（直连/代理） | 搜索式兜底 |
| --- | --- | --- | --- | --- |
| 酷我 | `rid`（数字） | 酷我 songinfoandlrc?rid=（lrclist 字段） | 同端点 pic 字段（img1.kuwo.cn） | LrcApi / LDDC kg |
| QQ | `songmid`（字母数字） | c.y.qq.com/lyric.fcg?songmid= / Rain120 qq-music-api /getLyric | fcg_play_single_song → album_mid → y.gtimg.cn T002R300x300M000{album_mid}.jpg | LrcApi / LDDC qm |
| 网易云 | `id`（数字） | api.music.163.com/api/song/lyric?id=（需登录态，见 §5 局限） | api.music.163.com/api/song/detail → al.picUrl | LrcApi / LDDC ne |
| 酷狗 | `hash`（32位hex） | krcs.kugou.com/search?hash= / wwwapi getdata lyrics | wwwapi getdata img / getSongInfo img | LDDC kg（0.03s 命中） |

> 实现要点：①App 数据层已按 `(platform, id)` 存音乐 URL，歌词/封面接口按同一三元组直接取；②搜索式接口作为"平台直连失败时的回退链"（LDDC 的回退链顺序 LRCLIB→NE→QM→KG 已实测，KG 最快）；③LrcApi 一个项目同时提供 `/lyrics` 与 `/cover`，集成成本最低（见 §4 推荐清单）。

## 2 测试方法与判定口径

- **测试曲（沿用音乐源系列锚点，已实测版权状态）**：类A 周杰伦《晴天》《七里香》《稻香》——QQ mid / 酷狗 hash / 酷我 rid 见 §1.1 锚点；网易云无周杰伦官方原版（仅 UGC 翻唱），网易系接口一律用备份曲（大鱼 516823132 / 演员 32507038 / 年少有为 1293886117）测试并标注 expected 依据。
- **主判定（沿用用户口径）**：废源 = 3 首固定测试曲全部无法返回（歌词文本 / 封面图片字节）；**任一能返回即非废源**。
- **子维度**：可用 = 可达平台测试曲全部返回完整可落地结果；部分可用 = 仅部分曲目返回或结果不完整；不可用 = 全部失败。命中分级：`full`（完整 LRC ≥20 时间戳行 / 封面图片真实下载、魔数+宽高有效）、`partial`（有返回但不完整）、`fragment`（试听/占位/防盗链等不可用返回）、`expected_fail`（平台无此曲，注明依据）、`source_fail`（端点自身故障）。
- **三分类**：纯搜索接口（按 title/artist 检索）/ 直连平台接口（网易云、QQ、酷我等官方端点自带歌词/封面字段）/ 第三方聚合服务（平台代理与聚合 API）。
- **风控（沿用）**：单端点 ≤3 次、2s/5s 退避、同 host ≥1s、全局 ≤3 req/s、单请求 15s / 下载 25s；酷狗 CDN 证书 hostname 不匹配用 `verify=False` + 移动 UA；Python 3.13 + requests + pycryptodome + PIL 13.0.0。

## 3 候选项目清单（GitHub 调研结果）

### 3.1 歌词类候选（17 项 = 15 个 HTTP API 实测 + 2 个客户端库）

| # | 项目 / 仓库 | 类型 | 部署形态 | 判定 | 摘要 |
|---|---|---|---|---|---|
| 1 | HisAtri/LrcApi（1265★，StreamMusic 配套） | 聚合搜索 | 本地自部署 28883 / 公开 api.lrc.cx | 可用 | 3/3 full（周杰伦），1.4-3.3s，完整 LRC |
| 2 | chenmozhijin/LDDC（1862★，逐字歌词匹配） | 聚合搜索 | 本地自部署 uvicorn 8000 | 部分可用 | 仅 kg 酷狗链路 0.24-0.31s；lrclib/ne/qm 404 |
| 3 | LRCLIB 社区歌词库（lrclib.net） | 纯搜索 | 公开服务 | 部分可用 | 有词但仅 plainLyrics 无时间戳；稻香 SSL 超时 |
| 4 | 网易云官方直连（无 GitHub 仓） | 直连平台 | 官方端点 | 可用 | 备份曲 3/3 full，156-190ms，40-81 时间戳行 |
| 5 | QQ lyric.fcg（无 GitHub 仓） | 直连平台 | 官方端点 | 不可用 | 端点已下线 404 |
| 6 | QQ lyric_download.fcg（无 GitHub 仓） | 直连平台 | 官方端点 | 不可用 | 200 但 CDATA 空壳，需登录态 |
| 7 | 酷狗 krcs.search（参考 PyPI ll-kugou-lyric-api 0.1.3） | 直连平台 | 官方端点 | 不可用 | 仅 accesskey 元数据，正文需二次解密 |
| 8 | 酷狗 wwwapi getdata（无 GitHub 仓） | 直连平台 | 官方端点 | 不可用 | dfid/mid 校验反爬 err30020 |
| 9 | 酷我 songinfoandlrc（无 GitHub 仓） | 直连平台 | 官方端点 | 不可用 | 强制 kw_token cookie，伪造 301 |
| 10 | boidu.dev / BetterLyrics（docs.betterlyrics.org） | 聚合 | 公开实例 | 不可用 | 改 X-API-Key 授权制，匿名 401 |
| 11 | Binaryify/NeteaseCloudMusicApi | 聚合 | 公开实例 | 不可用 | 3 个候选实例全下线/不可达 |
| 12 | Rain120/qq-music-api | 聚合 | 公开实例 | 不可用 | Vercel 超时、Deno Deploy 2026-07 关停 |
| 13 | akashrchandran/spotify-lyrics-api | 聚合 | 公开实例 | 不可用 | 演示实例下线，Musixmatch token 未配置 |
| 14 | TharukRenuja/SyncLRC | 聚合 | 公开实例 | 不可用 | synclrc.dev TLS 超时、api.wbwlrc.workers.dev 不可达 |
| 15 | （扩展发现）f1nniboy/lrcmux、Wilooper/Lyrica、lujjjh/lyrics-api | 聚合/库 | 仅自部署 | 未测 | 无公开实例，标注自部署可用性未实测 |
| 16 | cqjjjzr/MusicBee-NeteaseLyrics | 库 | — | 未测(非API服务) | C# 客户端插件 |
| 17 | guohuiyuan/music-lib | 库 | — | 未测(非API服务) | Go 客户端库 |

### 3.2 封面类候选（10 项 = 7 个 HTTP API 实测 + 3 个未测）

| # | 项目 / 仓库 | 类型 | 部署形态 | 判定 | 摘要 |
|---|---|---|---|---|---|
| 1 | HisAtri/LrcApi `/cover`（docs.lrc.cx） | 聚合搜索 | 公开 api.lrc.cx（本地 401、liapi 502） | 可用 | 6/6 full，3000-4000px，落到 mzstatic |
| 2 | QQ 官方 songinfo（无 GitHub 仓） | 直连平台 | 官方端点 | 可用 | 3/3 full 300²，无防盗链，94-262ms |
| 3 | 酷狗 getSongInfo（m.kugou.com，无 GitHub 仓） | 直连平台 | 官方端点 | 可用 | 3/3 full 480²（{size} 需替换），~100ms |
| 4 | 酷我 songinfo（m.kuwo.cn / www.kuwo.cn） | 直连平台 | 官方端点 | 不可用 | 暖 cookie+csrf 后 data={}，pic 被风控剥离 |
| 5 | Binaryify/NeteaseCloudMusicApi | 聚合 | 公开实例 | 不可用 | vercel 超时 / gdstudio 404 |
| 6 | iTunes Search API（Apple，被大量 GitHub 项目引用） | 聚合 | 官方公开 | 部分可用 | 周杰伦 2/3 miss+稻香错配；备份曲 3/3 full |
| 7 | Cover Art Archive（MusicBrainz） | 聚合 | 官方公开 | 部分可用 | 两步链路通但华语覆盖稀疏，archive.org 超时 |
| 8 | harry75369/genius-lyrics-api（npm） | 搜索 | 需 token | 未测(需鉴权) | 强制 client access token |
| 9 | ironsmile/euterpe | 库 | 自建 | 未测(非API服务) | 本地文件扫描型媒体服务器 |
| 10 | ClaireCJS/classics_cover_downloader（Discogs 驱动） | 库 | 需 token | 未测(非API服务) | 纯脚本，Discogs DB API 需 token |

## 4 逐源明细

### 4.1 歌词类逐源明细表

测试日期：2026-10-28　测试曲：晴天/七里香/稻香（周杰伦）+ 网易云备份曲（大鱼/演员/年少有为）

| # | 源名称 | 项目/仓库 | 类型 | 平台 | 端点模板 | 测试结果（歌×分级） | 判定 | 响应/备注 |
|---|--------|-----------|------|------|----------|----------------------|------|-----------|
| 1 | LrcApi 本地自部署 | github.com/HisAtri/LrcApi | aggregator | multi | `http://127.0.0.1:28883/lyrics?title={t}&artist={a}` | 晴天 full / 七里香 full / 稻香 full | 可用 | 1.4-3.2s，完整 LRC |
| 2 | LrcApi 公开实例 | github.com/HisAtri/LrcApi | aggregator | multi | `https://api.lrc.cx/lyrics?title={t}&artist={a}` | 晴天 full / 七里香 full / 稻香 full | 可用 | 繁体 LRC；/api/v1/lyrics/single 404 |
| 3 | LDDC 歌词搜索本地 | github.com/chenmozhijin/LDDC | aggregator | multi | `http://127.0.0.1:8000/lyrics?title={t}&artist={a}&source={src}` | 晴天 full(kg) / 七里香 full(kg) / 稻香 full(kg) | 部分可用 | 仅 kg 酷狗链路 239-309ms；lrclib/ne/qm 均 404 |
| 4 | LRCLIB 社区歌词库 | github.com/LRCLIB | search | multi | `https://lrclib.net/api/get?track_name={t}&artist_name={a}&album_name=` | 晴天 partial / 七里香 partial / 稻香 source_fail | 部分可用 | 有词但仅纯文本无时间戳；稻香连续超时 |
| 5 | 网易云官方直连 | music.163.com | direct | netease | `https://api.music.163.com/api/song/lyric?id={id}&lv=-1&kv=-1&tv=-1` | 大鱼 full / 演员 full / 年少有为 full | 可用 | 156-190ms，40-81 时间戳行 |
| 6 | QQ lyric.fcg 旧端点 | y.qq.com | direct | qq | `https://c.y.qq.com/lyric.fcg?format=json&songmid={mid}&songtype=0` | 晴天 404 / 七里香 404 / 稻香 404 | 不可用 | 端点已下线 |
| 7 | QQ lyric_download.fcg | y.qq.com | direct | qq | `https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg?songmid={mid}&format=json` | 晴天 fragment / 七里香 fragment / 稻香 fragment | 不可用 | 200 但 CDATA 空壳，需登录态 |
| 8 | 酷狗 krcs search | github.com/zhizhouyao/ll-kugou-lyric-api | direct | kugou | `https://krcs.kugou.com/search?ver=1&man=yes&client=mobi&hash={hash}` | 晴天 fragment / 七里香 fragment / 稻香 fragment | 不可用 | 仅返回 accesskey 元数据，无正文 |
| 9 | 酷狗 wwwapi getdata | kugou.com | direct | kugou | `https://wwwapi.kugou.com/yy/index.php?r=play/getdata&hash={hash}&album_id={aid}` | 晴天 err30020 / 七里香 err30020 / 稻香 err30020 | 不可用 | dfid/mid 反爬校验拒绝 |
| 10 | 酷我 H5 直连 | kuwo.cn | direct | kuwo | `https://m.kuwo.cn/newh5/singles/songinfoandlrc?rid={rid}&from=web` | 晴天 400 / 七里香 301无词 / 稻香 301无词 | 不可用 | 需有效 kw_token cookie，伪造被拒 |
| 11 | boidu.dev / BetterLyrics | docs.betterlyrics.org | aggregator | multi | `https://lyrics-api.boidu.dev/getLyrics?s={t}&a={a}` | 晴天 超时 / 七里香 401 / 稻香 超时 | 不可用 | 改 API Key 授权制，匿名 401 |
| 12 | NeteaseCloudMusicApi 公开实例 | github.com/Binaryify/NeteaseCloudMusicApi | aggregator | netease | `{base}/lyric?id={id}` | 全部 ConnectTimeout 不可达 | 不可用 | 3 个候选实例全下线 |
| 13 | qq-music-api 公开实例 | github.com/Rain120/qq-music-api | aggregator | qq | `{base}/getLyric?mid={mid}` | vercel 超时 / deno 404 已关停 | 不可用 | Deno Deploy 2026-07 关停 |
| 14 | spotify-lyrics-api | github.com/akashrchandran/spotify-lyrics-api | aggregator | multi | `https://spotify-lyrics-api.vercel.app/getLyrics?track={t}&artist={a}` | 全部 ConnectTimeout 不可达 | 不可用 | 公开演示实例下线 |
| 15 | SyncLRC 公开实例 | github.com/TharukRenuja/SyncLRC | aggregator | multi | `https://api.wbwlrc.workers.dev/getLyrics?artist={a}&title={t}` | 全部 ConnectTimeout 不可达 | 不可用 | synclrc.dev TLS 握手超时 |
| 16 | MusicBee-NeteaseLyrics | github.com/cqjjjzr/MusicBee-NeteaseLyrics | library | netease | — | — | 未测(非API服务) | C# 客户端插件，不计统计 |
| 17 | music-lib | github.com/guohuiyuan/music-lib | library | multi | — | — | 未测(非API服务) | Go 客户端库，不计统计 |

#### 歌词类关键发现

1. **直连链路可用性**：网易云官方直连（api.music.163.com）3 首备份曲全部 full，156-190ms 最快最稳；QQ/酷狗/酷我官方端点全面反爬（404/400/301/err30020），匿名直连基本废。
2. **反爬现状**：酷我强制 kw_token cookie（伪造 301）、酷狗 wwwapi dfid 校验（30020）、boidu 改 X-API-Key 授权（401）；LDDC 的 ne/qm 子源本轮实测均 404，与既往"平台反爬"结论一致。
3. **基线项目复测**：LrcApi 本地与公开实例均全通（full ×3）；LDDC 仅 kg 酷狗链路可用（0.24-0.31s），lrclib/ne/qm 三源 404，与既往"kg 可用、lrclib 结构性 404、ne/qm 反爬"吻合。
4. **公开实例生态**：Binaryify/Rain120/spotify-lyrics-api/SyncLRC 的公开部署实例全部不可达（Vercel/Workers 超时、Deno Deploy 2026-07 关停），第三方聚合公开实例基本凋零。
5. **LRCLIB 局限**：社区库有词但仅 plainLyrics（无同步时间戳），稻香查询连续 SSL 握手超时，国内访问不稳定。

### 4.2 封面类逐源明细表

测试日期：2026-10-28　｜　分类：cover（歌曲/专辑封面）　｜　测试曲锚点沿用既有系列（晴天/七里香/稻香 + 网易备份曲 大鱼/演员/年少有为）。
命中分级：full=真实下载(200/字节>0/魔数匹配/PIL 宽高≥200)；partial=URL在但错配/过小；fragment=防盗链·占位·空壳；expected_fail=该平台无此曲；source_fail=端点故障/需鉴权。

| # | 源名称 | 项目/仓库 | 类型 | 平台 | 端点模板 | 测试结果（歌×分级） | 判定 | 响应/备注 |
|---|--------|-----------|------|------|----------|----------------------|------|-----------|
| 1 | LrcApi /cover | ghacg/lrcapi (docs.lrc.cx) | aggregator | multi | `GET {base}/cover?title={title}&artist={artist}` 直出 image/jpeg | 晴天 full / 七里香 full / 稻香 full / 备份曲3首 full（共6/6，3000×3000~4000×4000） | **可用** | 公开 `api.lrc.cx` 健康，1.2~3.3s，落到 mzstatic；本地 28883 需登录=401；`liapi.lrc.cx` 502/超时宕机 |
| 2 | NeteaseCloudMusicApi | Binaryify/NeteaseCloudMusicApi | aggregator | netease | `GET {base}/song/detail?ids=[<id>]` | 大鱼：vercel 实例 connect-timeout / gdstudio 实例 404 Not Found（0 命中） | **不可用（废源）** | 探测 2 个公开实例均不可达/无路由，未取到封面 |
| 3 | QQ音乐 songinfo | 官方直连（无GitHub仓） | direct | qq | `GET c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?songmid=<mid>&format=json`→album.mid，再拼 `y.gtimg.cn/music/photo_new/T002R300x300M000<mid>.jpg` | 晴天 full(300²) / 七里香 full(300²) / 稻香 full(300²) | **可用** | album.mid 精准返回《叶惠美/七里香/魔杰座》，图片直下无防盗链，94~262ms |
| 4 | 酷我 songinfo | 官方直连（无GitHub仓） | direct | kuwo | `GET m.kuwo.cn/newh5/singles/songinfoandlrc?rid=<rid>&from=web`→data.pic | 晴天 400 / 七里香 data={} / 稻香 data={}（pic 全空） | **不可用（废源）** | h5 与 www.kuwo.cn api 暖 cookie+csrf 后仍空壳，裸接口被风控剥离，需完整浏览器指纹 |
| 5 | 酷狗 getSongInfo | 官方直连（无GitHub仓） | direct | kugou | `GET m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=<hash>`→img（**{size} 须替换为 480**），verify=False+移动UA | 晴天 full(480²,97KB) / 七里香 full(480²,108KB) / 稻香 full(480²,93KB) | **可用** | img 自带字面 `{size}`，不替换会下到 17853B 占位图；替换后 150/300/480 三档皆可，~100ms |
| 6 | iTunes Search API | Apple 官方（被大量GitHub项目引用） | aggregator | multi | `GET itunes.apple.com/search?term=<曲+歌手>&media=music&entity=song&limit=1`→artworkUrl100（100×100 换 300×300） | 晴天 expected_fail(resultCount=0) / 七里香 expected_fail(0) / 稻香 partial(误配"伦/黑加伦") / 备份曲3首 full(300²) | **部分可用** | 无需鉴权；仅覆盖美区商店曲目，周杰伦原版缺失、稻香错配；备份曲全中 |
| 7 | Cover Art Archive | MusicBrainz 官方 | aggregator | multi | 两步：`musicbrainz.org/ws/2/release-group/?query=...`(需UA)取 mbid → `coverartarchive.org/release-group/<mbid>/front-500.jpg` | 晴天 expected_fail(无rg) / 七里香 503限流 / 稻香错配+404 / 大鱼 mbid命中但 archive.org 超时 / 演员 expected_fail / 年少有为 404 | **部分可用** | 链路通但华语 rg 覆盖稀疏、多数无 front 图、本机到 archive.org CDN 超时；耗时 0.5~4.5s |
| 8 | genius-lyrics-api | harry75369/genius-lyrics-api (npm) | search | multi | `GET api.genius.com/search?q=<query>`（Bearer token） | 全部未测（无 token） | **未测(需鉴权)** | 强制 client access token，未配置凭证，不编造 |
| 9 | euterpe | ironsmile/euterpe | library | selfhost | `/v1/album/{albumID}/artwork`（本地文件扫描） | 全部 N/A | **未测(非API服务)-参考** | 自建媒体服务器，封面来自本地入库文件，不适用在线检索 |
| 10 | classics_cover_downloader | ClaireCJS/classics_cover_downloader | library | multi | Discogs DB API（需 token）客户端脚本 | 全部 N/A | **未测(非API服务)** | GitHub 扩展检索新候选；纯脚本，依赖 Discogs token |

#### 封面类关键发现

1. **直链可落地性最好的两家是 QQ 与酷狗**：QQ 经 songinfo 拿 album.mid 后自拼 `y.gtimg.cn/...T002R300x300...jpg` 三曲全中、无防盗链；酷狗 `m.kugou.com` getSongInfo 的 `img` 字段三曲全中——但**必须把返回 URL 里的字面 `{size}` 替换为 480**，否则下到 17KB 占位图（两曲字节数完全相同即占位证据）。
2. **酷我裸接口已废**：`newh5/singles/songinfoandlrc` 与 `www.kuwo.cn/api/...` 即便暖 cookie+csrf 也只回 `data={}`，pic 字段被风控剥离，rid 直取封面这条路当前走不通，需经完整浏览器指纹/签名代理。
3. **网易云直连不稳定**：`music.163.com/api/song/detail` 偶发一次返回完整 `al.picUrl`（实测 大鱼 1500×1500、126KB 可下），但随即连续多次返回 `al:null` 被剥离；Binaryify 系公开实例本次探测 2 个均不可达，封面获取实际需依赖 weapi 封装或 LrcApi 这类聚合。
4. **聚合层 LrcApi 公开实例是本次最大亮点**：`api.lrc.cx/cover` 6/6 全 full 且分辨率达 3000~4000×3000~4000（最终落到 mzstatic），连 iTunes 直搜搜不到的周杰伦晴天/七里香都能正确命中；iTunes 直搜则仅对上架美区的曲目有效（周杰伦 2/3 miss、稻香错配）。
5. **防盗链/分辨率现状**：QQ(gtimg)、酷狗(imge)、网易(126.net)、LrcApi→mzstatic 图片 CDN 均**无 Referer 校验、可直链**；Cover Art Archive 经 archive.org 重定向，本机网络到该 CDN 超时且华语覆盖稀疏，不适合做主源。分辨率档次：QQ/酷狗 300~480px，网易单图可达 1500px，LrcApi/iTunes 可升级到 1400~4000px。

### 4.3 推荐给 App 集成的接口清单

**歌词（推荐 2 主 + 1 备选）**

| 优先级 | 接口 | 端点 / 调用 | 配对对象 | 实测依据 |
|---|---|---|---|---|
| 主 | 网易云官方直连 | `GET https://api.music.163.com/api/song/lyric?id={id}&lv=-1&kv=-1&tv=-1` | 网易系音乐源（gdstudio/oiapi Music_163/s0o1 出的 `id`） | 备份曲 3/3 full，156-190ms，40-81 时间戳行（独立复核：大鱼 200/178ms/40 行） |
| 主 | LrcApi（跨平台兜底） | `GET https://api.lrc.cx/lyrics?title={title}&artist={artist}` 或本地 `http://127.0.0.1:28883/lyrics` | 全部平台按 title+artist；QQ/酷我系因平台反爬取不到词时兜底 | 周杰伦 3/3 full（1.4-3.3s 完整 LRC，繁体）；本地/公开均通 |
| 备 | LDDC 本地 kg 源 | `GET http://127.0.0.1:8000/lyrics?title={t}&artist={a}&source=kg` | 酷狗系音乐源（星海 kg 支流出的 `hash`） | kg 链路 3/3 full，239-309ms |

不推荐：QQ lyric.fcg（已下线 404）、酷狗/酷我匿名直连（反爬）、Binaryify/Rain120/spotify/SyncLRC 公开实例（全部不可达）。

**封面（推荐 3 主 + 1 备选）**

| 优先级 | 接口 | 端点 / 调用 | 配对对象 | 实测依据 |
|---|---|---|---|---|
| 主 | QQ songinfo → gtimg | `GET c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?songmid={mid}&format=json` 取 album.mid，再 `GET https://y.gtimg.cn/music/photo_new/T002R300x300M000{album_mid}.jpg` | QQ 系音乐源（cyapi/a.aa.cab 出的 `songmid`） | 3/3 full 300²、无防盗链（独立复核：晴天 200/227ms/33KB JPEG 300×300） |
| 主 | 酷狗 getSongInfo | `GET https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash={hash}` 取 img，**img URL 字面 `{size}` 替换为 480**，`verify=False`+移动 UA | 酷狗系音乐源（星海 kg 支流出的 `hash`） | 3/3 full 480²、~100ms（不替换会下到 17KB 占位图） |
| 主 | LrcApi `/cover`（跨平台兜底） | `GET https://api.lrc.cx/cover?title={title}&artist={artist}` | 全部平台；直连 miss 时兜底 | 6/6 full，3000-4000px（含 iTunes 直搜 miss 的周杰伦曲目） |
| 备 | 网易云 song/detail | `GET https://api.music.163.com/api/song/detail?ids=[{id}]` 取 al.picUrl | 网易系音乐源（`id`） | 单图 1500px 可下，但直连偶发被风控剥离（al=null），需节流/代理/登录态 |

不推荐：酷我裸接口（废源）、Binaryify 公开实例（废源）、Cover Art Archive（华语覆盖稀疏+archive.org 超时）、iTunes 直搜（周杰伦 2/3 miss，仅美区上架曲目）。

> **集成总则**：App 数据层已按 `(platform, id)` 存音乐 URL——酷我 `rid`、QQ `songmid`、网易 `id`、酷狗 `hash`；歌词/封面接口按同一标识符同平台直接配对，搜索式接口（LrcApi）作为平台直连失败时的回退链，回退顺序建议 LrcApi → LDDC(kg)。一个项目同时提供 `/lyrics`+`/cover` 的 LrcApi 集成成本最低。

## 5 失败原因分布

**歌词类 10 个废源（不可用）失败原因：**

| 原因 | 数量 | 涉及源 |
|---|---|---|
| 公开实例全部下线/不可达（Vercel/Workers 超时、Deno Deploy 2026-07 关停） | 4 | Binaryify/NeteaseCloudMusicApi、Rain120/qq-music-api、spotify-lyrics-api、SyncLRC |
| 平台反爬 / 强制鉴权 | 3 | 酷我（kw_token cookie 伪造 301）、酷狗 wwwapi（dfid/mid 校验 err30020）、boidu.dev（X-API-Key 授权 401） |
| 官方端点下线 / 需登录态空壳 | 2 | QQ lyric.fcg（404 已下线）、QQ lyric_download.fcg（200 但 CDATA 空壳） |
| 返回元数据、正文需二次解密 | 1 | 酷狗 krcs.search（仅 accesskey，download 端点 400 error 20010） |

**封面类 2 个废源（不可用）失败原因：**

| 原因 | 数量 | 涉及源 |
|---|---|---|
| 公开实例不可达（vercel 超时 / gdstudio 路由 404） | 1 | Binaryify/NeteaseCloudMusicApi |
| 裸接口被风控剥离（暖 cookie+csrf 后仍 data={}） | 1 | 酷我 songinfo（m.kuwo.cn / www.kuwo.cn） |

**未测（不计入连通统计）**：歌词 2 项（C# 插件 MusicBee-NeteaseLyrics、Go 库 music-lib——非 API 服务）；封面 3 项（genius-lyrics-api 需 token、euterpe 本地文件扫描型、classics_cover_downloader 需 Discogs token）。

## 6 与前序审计衔接

- 音乐源：见《接口归类清单-音乐与歌词.md》§1.2（33 条非废源）与本系列《GitHub音乐源连通性测试报告.md》§4。
- 歌词基线：LDDC / LrcApi 既往结论见《接口归类清单-音乐与歌词.md》二类 2A/2B（2026-10-22 实测），本轮已重新实测核对。
- 结论口径、命中分级、废源定义与音乐源系列完全一致，App 可按 §1.1 配对逻辑统一接入。

## 7 局限说明

- **时点性**：本报告测试于 2026-10-28；第三方公开实例生态凋零且时点性强（Vercel/Workers 超时、Deno Deploy 已关停），本次"不可用"结论仅代表测试时点；自部署型项目（Binaryify/Rain120 等）代码仍在，部署后可用性未测。
- **网易云直连偶发风控**：lyric 接口偶发需 cookie，song/detail 封面接口出现连续 `al:null` 剥离；App 集成建议节流+可选登录态，或经 weapi 封装代理。
- **酷狗两条注意**：①图片 URL 字面 `{size}` 必须替换为 150/300/480，否则下到 17KB 占位图；②接口/图片 CDN 证书 hostname 不匹配，需 `verify=False` + 移动 UA。
- **LrcApi 本地 `/cover` 实测 401 需登录**（公开实例健康）；本地自部署需自配凭证；公开实例依赖 lrc.cx 服务可用性。
- **LRCLIB 局限**：社区词库仅 plainLyrics（无同步时间戳），且国内访问 SSL 握手不稳定（稻香连续超时）。
- **周杰伦 3 首在网易云无官方原版**：网易系接口以备份曲（大鱼/演员/年少有为）测试并标注 expected 依据，不影响接口能力判定（口径与音乐源系列一致）。
- **未测项目未编造结论**：需 token（Genius/Discogs）、本地文件型（euterpe）、客户端库（C#/Go）如实标注未测原因。
- **LrcApi 公开实例返回繁体 LRC**（需自行繁转简或接受）；LDDC 的 ne/qm 子源受平台反爬影响（与既往结论一致）。

## 8 产物与复现

- 本报告：`C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\GitHub歌词封面API连通性测试报告.md`；汇总图：同目录 `GitHub歌词封面API连通性测试-汇总图.html`。
- 逐源 JSON（含端点模板/参数/每曲 status/http/ms/sample/detail，json.tool 校验通过）：`C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\lrc_cover_api\_results\lyric_sources.json`、`cover_sources.json`；分节表：`lyric_section.md`、`cover_section.md`。
- 测试锚点与口径与既有系列一致（《GitHub音乐源连通性测试报告.md》§4.1、《测试曲目清单与版权验证表.md》）；探测脚本（子代理 artifacts 内）与风控参数（单端点≤3 次、2s/5s 退避、同 host≥1s、≤3req/s）可复现全部结论。

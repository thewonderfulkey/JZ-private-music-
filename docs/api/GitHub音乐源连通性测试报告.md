# GitHub 音乐源连通性测试报告（3 仓库全源实测）

> 测试基准：周杰伦《晴天》；测试时间 2026-10-22（UTC-7）。本报告与既有《接口归类清单-音乐与歌词.md》口径衔接：接口分"返回音乐的接口 / 返回歌词的接口"两类，本任务只测音乐源。

## 1 概述与摘要

- **仓库盘点**：`pdone/lx-music-source`（branch main，28 个 js，11 个源目录）；`Huibq/keep-alive`（branch master，6 js + 2 json + 1 py，5 个音源 + 2 个保活脚本）；`guoyue2010/lxmusic-`（branch main，**15 个版本目录共约 307 个 js** + `yinyuan.zip` 15 个备份文件，覆盖 2026-02-12 ~ 2026-09-07 各代快照，超出任务预判的 3 个版本目录规模）。
- **测试规模**：去重后共 **100 条源记录**（pdone 11 / keep-alive 7 / guoyue 82）；完全重复（同 md5）合并后**唯一源 89 个**。
- **统一口径结论：可用 1 / 部分可用 33 / 不可用 66，可用率 1.0%**。
  - 唯一**可用**：`KuwoDES/KE-DES`（guoyue V2603_miniupdate 一般档，酷我专用源，官方 `mobi.kuwo.cn/mobi.s` 320k 完整可下，10,797,030 B == Content-Length，269 s 吻合，与前序审计字节级一致）。
  - **部分可用 33**：其中 17 条完成了《晴天》**原版**完整下载验证但均为单平台（酷我 13 条、QQ 4 条；多平台聚合源仅验证通单平台，按统一口径归部分可用）；其余为仅翻唱、返回 URL 未完整验证、需卡密参数等。
  - **不可用 66**：失败主因排序——其他(35，多为第三方代理后端停用/521/落地页)、空结果(13)、域名失效(11)、无法静态提取端点(10)、404(7)、超时(6)、反爬(5)、需登录(5)、SSL(3)、需签名(2)。

| 仓库 | 盘点 js | 源记录 | 可用 | 部分可用 | 不可用 | 可用率(统一口径) |
|---|---|---|---|---|---|---|
| pdone/lx-music-source | 28 | 11 | 0 | 2 | 9 | 0% |
| Huibq/keep-alive | 6(+2json+1py) | 7 | 0 | 3 | 4 | 0% |
| guoyue2010/lxmusic-（全版本+zip） | ~307+15 | 82 | 1 | 28 | 53 | 1.2% |
| **合计（去重前记录）** | ~341 | **100** | **1** | **33** | **66** | **1.0%** |

> 口径调和说明：分片 3.1 表中 pdone 的 2 条（全豆要、星海）原判"可用 2"，系"完整返回音频"口径（酷我单平台完整下载 10,792,943 B/269.82 s 属实）；本报告按用户三分法原文"部分可用（…或特定平台可用）"统一口径，将"多平台聚合源仅单平台验证"下移为**部分可用**（完整下载证据保留在行内）；`KuwoDES` 为单平台专用源、在其唯一平台上完整验证，保持**可用**。若按宽松口径"完整返回音频即可用（不论平台数、不含翻唱）"，可用为 17 条。

> 汇总图：`GitHub音乐源连通性测试-汇总图.html`（同目录，静态 SVG、无外部依赖，数据与本节一致）。

> **多曲目重测（2026-10-22 第二轮，详见 §4）**：主判定改为"废源/非废源"——**非废源 33 / 废源 67**（100 条记录：35 条多曲目重测 + 65 条沿用首轮直接判废）。类C（网易云独有）经 59 候选跨平台实测 0 首入选，废源判定按类A 3 首 + 类B 3 首执行；33 个保留源**全部命中 VIP 付费类（类B）**、29 个命中无版权类（类A），官方直连层 6 首全灭、全部经第三方代理链出链。重测汇总图：`GitHub音乐源多曲目重测-汇总图.html`。

## 2 测试方法与判定口径

- **测试曲**：《晴天》（搜索词"晴天"/"晴天 周杰伦"，备用词"七里香 周杰伦"）。实测锚点：酷我 rid=228908 / 51685512、网易 id=186016、QQ mid=0039MnYb0qxYhV、酷狗 hash B3A5…18B7。
- **完整可下载** = 实际下载字节数 == Content-Length，且时长吻合（晴天约 269 s，±10 s；时长用纯 Python MP3/Ogg 帧扫描，本机无 ffmpeg）。
- **无损界定**：FLAC=无损；MP3 320k 不算无损。
- **三级归类（统一口径）**：**可用**=返回可播放直链且完整下载验证通过，且非"多平台源仅单平台验证"（单平台专用源在唯一平台上完整验证→可用）；**部分可用**=返回播放 URL 但下载未完整验证 / 多平台源仅单平台验证 / 需卡密或参数 / 仅翻唱他曲 / 搜索通但取 URL 失败；**不可用**=其余（404/超时/SSL/域名失效/需登录/需签名/反爬/空结果/无法静态提取端点）。
- **失败原因标签**：需登录、需签名、反爬、404、超时、SSL、域名失效、空结果、参数错误、无法静态提取端点、其他。
- **风控约束**：单端点最多 3 次尝试（2s/5s 退避），单请求超时 15 s（下载 25 s），同 host 间隔 ≥1 s，全局 ≤3 req/s；同源重试控制在合理次数，未触发风控封禁。
- **方法**：静态提取脚本内 `https?://` 端点（含 base64/hex 编码形式）→ 按脚本参数形态直连探测（搜索→取首个结果 id→取 URL 接口→播放直链）→ 直链做下载验证；jsjiami v7 等反调试混淆源如实记"无法静态提取端点"，不编造端点。

## 3 逐仓库明细（4 个分片实测表）


### 3.1 仓库 pdone/lx-music-source（去重后 11 个源；可用 2 / 部分可用 0 / 不可用 9，可用率 2/11≈18.2%）

- 去重说明：仓库共 11 个源目录（changqing/flower/grass/huanyin/huibq/ikun/juhe/lx/qdy/sixyin/xinghai），按规则每目录仅测 `latest.js`（均存在），同目录其余历史版本文件（如 lx/2.js~6.js、sixyin/1.2.0.js、ikun/6.js 等）只记入 JSON 的 `versions_present`，不单独测试；根目录 README/probe.py/.health-state.json 为线索文件，非音源，不测。
- 关键发现：
  - **真正可用（完整下载验证通过，320k MP3，10,792,943 字节 == Content-Length，269.82s 吻合《晴天》）**：`qdy 全豆要[聚合音源]`（末级长青SVIP链 musicapi.haitangw.net/music/kw.php 与念心SVIP链 music.nxinxz.com/kw.php，重定向 car-er.kuwo.cn）、`xinghai 星海音乐源`（自建后端 yy.zddyr.top/lx/api/，X-Token 自签令牌，kw 320k 完整下载）。两者均仅完成酷我(kw)单平台验证，QQ/咪咕/酷狗等缺 songmid 未全测。
  - **典型失效**：① 域名 DNS 失效（ikunshare、music-dl.sayqz.com、sixyin.com）；② 服务被停摆/拦截（huibq onrender 503 Suspended；juhe Cloudflare 429 限流；flower/grass 个人机 http 403、https 端口关闭；lx 独家音源连接被 RST）；③ 上游被限/路径下线（huanyin 咪咕 code502；qdy 的 qsvip 搜索 404；changqing 模板全 404）；④ 原版空、仅翻唱（gdstudio 网易原版 id=186016 返回空 url，翻唱 id=2652820720 出 24bit FLAC，56MB 按 12MB 上限截断未完整校验）。
  - 失效原因分布（按记录主标签）：域名失效 3（huibq 服务停摆、ikun、sixyin）、反爬 3（flower、grass、juhe）、空结果 1（huanyin 咪咕 code502，其 sayqz 代理链另附 DNS 失效）、404 1（changqing）、其他 1（lx，连接重置+端点无法静态提取）。
  - 测试曲：周杰伦《晴天》，搜索词"晴天 周杰伦"；完整可下载判定=字节数==Content-Length 且时长 269s±10s；无损仅认 FLAC，MP3 320k 不算无损；本轮未取得无损完整文件。

| # | 源名称 | 类型 | 脚本路径 | 请求端点(method+URL+参数形态) | 连通探测(状态/延迟/错误) | 可播放URL | 下载验证(字节/时长/格式) | 失败原因 | 归类 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 长青SVIP音源 | 自定义源 | changqing/latest.js | GET yinyue.haitangw.net/kw/kw.php?type=mp3&id=&level= | 404 / 57ms / nginx 404 | 否 | 未下载，模板全404 | 404 | 不可用 |
| 2 | 野花🌷 | 自定义源 | flower/latest.js | GET 97.64.37.235/url/{src}/{id}/{q} | 403 / 184ms / nginx 403,https超时 | 否 | 未下载 | 反爬 | 不可用 |
| 3 | 野草🌾 | 自定义源 | grass/latest.js | GET 97.64.37.235/url/{src}/{id}/{q} | 403 / 390ms / nginx 403 | 否 | 未下载 | 反爬 | 不可用 |
| 4 | 幻音音源 | 自定义源 | huanyin/latest.js | GET api.xcvts.cn/api/music/migu?gm=&n=1; sayqz代理 | 200/2407ms 但body code502; sayqz DNS失效 | 否 | 未下载 | 空结果 | 不可用 |
| 5 | Huibq_lxmusic源 | 自定义源 | huibq/latest.js | GET lxmusicapi.onrender.com/url/{src}/{id}/{q}; X-Key | 503 / 400ms / Service Suspended | 否 | 未下载 | 域名失效 | 不可用 |
| 6 | ikun音源 | 自定义源 | ikun/latest.js | GET api.ikunshare.com/url?source=&songId=&quality= | DNS NXDOMAIN / 域名失效 | 否 | 未下载 | 域名失效 | 不可用 |
| 7 | 聚合API接口(CF) | 聚合源 | juhe/latest.js | POST api.music.lerd.dpdns.org/{source}, JSON body | 429 / 661ms / Cloudflare限流 | 否 | 未下载 | 反爬 | 不可用 |
| 8 | 独家音源 | 自定义源 | lx/latest.js | apiUrl 88.lxmusic.xn--fiqs8s, 需signSalt签名; 路径VM混淆 | RST 10054 / 连接重置; http拦截页 | 否 | 未下载 | 其他 | 不可用 |
| 9 | 全豆要[聚合音源] | 聚合源 | qdy/latest.js | GET 多链: oiapi/Kuwo; haitangw/nxinxz /kw.php | 200 / 350ms / 末级链通; qsvip404 | 是 | 10,792,943B==CL / 269.82s / mp3 320k | — | 可用 |
| 10 | 六音音源 | 自定义源 | sixyin/latest.js | 端点VM+AES加密无法静态提取; 需网易/QQ登录Cookie | DNS NXDOMAIN / sixyin.com失效 | 否 | 未下载 | 域名失效 | 不可用 |
| 11 | 星海音乐源 | 聚合源 | xinghai/latest.js | GET yy.zddyr.top/lx/api/?source=kw&name=&songmid=, X-Token | 200 / 455ms / code200; 余平台需ID | 是 | 10,792,943B==CL / 269.82s / mp3 320k | — | 可用 |

补充说明：qdy/xinghai 共用的 GDAPI（music-api.gdstudio.xyz）仅对网易翻唱 id=2652820720 返回 24bit FLAC（56,037,067B，按 12MB 上限截断 12,582,912B，STREAMINFO 解析 278.96s，未完整校验，仅作支流观察，不计入源级"部分可用"）；网易原版 186016 返回空 url。qdy 的 oiapi 溯音酷我能返回签名短链但下载即 410，QQ 接口 403 维护；这些失效链已在 JSON 逐条记录。探测节奏：单端点最多 3 次（2s/5s 退避），单请求超时 15s（下载 25s），同 host 间隔≥1s。


> 口径调和注（针对 3.1 节）：该节"可用 2 / 可用率 18.2%"为分片代理按"完整返回音频"口径的原始判定；按本报告统一口径（§1），`qdy 全豆要[聚合音源]`（多平台聚合，仅酷我平台完整验证 10,792,943 B/269.82 s）与 `xinghai 星海音乐源`（多平台聚合，仅酷我平台完整验证）下调为**部分可用**，其余行不变。


### 3.2 仓库 Huibq/keep-alive（去重后 7 个源；可用 0 / 部分可用 3 / 不可用 4，可用率 0/7 = 0%）

- 去重说明：本仓库内 7 个条目（5 个 MusicFree 插件 + render_api.js lx 源 + main.py 保活脚本）无相互重复。`render_api.js`（MD5 53B59E609D82230F03FFD67BF2376DF0）与 pdone 仓库 `huibq/latest.js`、`huibq/1.2.0.js` MD5 完全一致，属跨仓库同源，跨库汇总时应合并为同一源；5 个 MusicFree 插件在 pdone 仓库无同名/同 MD5 文件。`allPlugins.json` 另声明 10 个远端第三方插件（Audiomack、bilibili、歌词网、歌词千寻、快手、猫耳FM、Navidrome、音悦台、WebDAV、Youtube），无本地 js，按规则不单独测，仅作仓库声明源登记。
- 关键发现：
  1. 全部取流都汇聚到自建代理 `https://lxmusicapi.onrender.com/url/{source}/{id}/{quality}`（鉴权头 `X-Request-Key: share-v3`），该后端当前返回 **503 Service Suspended（This service has been suspended by its owner）**，已被所有者停用，5 个插件与 lx 源均拿不到播放 URL，无一条完成下载验证。
  2. 搜索层仍部分可达：酷狗 `songsearch.kugou.com`、QQ `u.y.qq.com/cgi-bin/musicu.fcg`、酷我 `search.kuwo.cn/r.s` 均 200 并命中周杰伦《晴天》原版（酷狗 hash B3A5…18B7；QQ mid 0039MnYb0qxYhV；酷我 rid 228908）；咪咕 `scr_search_tag` 已 301 迁移至 /v5（旧接口退役）；网易云 weapi 加密搜索返回 200 空体（疑反爬/需 cookie），声明的备选域名 share.duanx.cn DNS 失效。
  3. `main.py` 为 GitHub Actions 每 3 天触发的保活脚本，`render_url/render_key/header_key` 均为 secrets，仓库内不可见，无法静态重建端点。
  4. README 自述最高 320k、不支持数字专辑、频繁请求会封 IP；当前失败主因是代理后端停用，而非风控封禁。

| # | 源名称 | 类型 | 脚本路径 | 请求端点(method+URL+参数形态) | 连通探测(状态/延迟/错误) | 可播放URL | 下载验证(字节/时长/格式) | 失败原因 | 归类 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 小枸音乐(酷狗) | MusicFree自定义源 | Music_Free/xiaogou.js | GET songsearch.kugou.com 搜索; onrender /url/kg/{hash}/320k | 搜索200/102ms命中原版; 取URL503停用 | 否 | 未测(无直链) | 其他(后端停用) | 部分可用 |
| 2 | 小蜜音乐(咪咕) | MusicFree自定义源 | Music_Free/xiaomi.js | GET m.music.migu.cn搜索; onrender /url/mg/{id}/320k | 搜索301→/v5退役; 代理503; 备用301 | 否 | 未测(无直链) | 其他(退役+停用) | 不可用 |
| 3 | 小秋音乐(QQ音乐) | MusicFree自定义源 | Music_Free/xiaoqiu.js | POST u.y.qq.com musicu.fcg搜索; onrender /url/tx/{mid}/320k | 搜索200/298ms命中原版; 取URL503停用 | 否 | 未测(无直链) | 其他(后端停用) | 部分可用 |
| 4 | 小蜗音乐(酷我) | MusicFree自定义源 | Music_Free/xiaowo.js | GET search.kuwo.cn/r.s搜索; onrender /url/kw/{rid}/320k | 搜索200/63ms命中原版; 取URL503停用 | 否 | 未测(无直链) | 其他(后端停用) | 部分可用 |
| 5 | 小芸音乐(网易云) | MusicFree自定义源 | Music_Free/xiaoyun.js | POST music.163.com weapi(加密); onrender /url/wy/{id}/320k | weapi200空体/99ms反爬; 代理503; duanx失效 | 否 | 未测(无直链) | 反爬 | 不可用 |
| 6 | Huibq_lxmusic源 | lx-music自定义源 | render_api.js | GET onrender /url/{kw\|kg\|tx\|wy\|mg}/{id}/q; share-v3 | 503/401ms停用; 仅musicUrl; pdone同源 | 否 | 未测(无直链) | 其他(后端停用) | 不可用 |
| 7 | keep-alive保活脚本 | API保活 | main.py | GET render_url(secrets)+X-Request-Key/X-Forwarded-For | secrets不可见,无法静态提取,未发请求 | 否 | 不适用(非取流) | 无法静态提取端点 | 不可用 |

补充登记（allPlugins.json 声明、无本地 js、未单独测）：Audiomack 0.0.2、bilibili 0.1.15、歌词网 0.0.0、歌词千寻 0.0.0、快手 0.0.1、猫耳FM 0.1.4、Navidrome 0.0.0、音悦台 0.0.1、WebDAV 0.0.2、Youtube 0.0.1（均经 gitee.com/maotoumao/MusicFreePlugins 分发）。

### 3.3 仓库 guoyue2010/lxmusic-（V2603家族分片，去重后 33 个源；可用 1 / 部分可用 18 / 不可用 14，可用率 1/33）

- 去重说明：跨 v260212/V2603/V2603_latest/V2603_miniupdate/V2603_organized 按「源显示名(@name/文件名主干)+文件md5」去重，共盘点107个js、得33个canonical；canonical 按优先级 V2603_organized > V2603_miniupdate > V2603_latest > V2603 > v260212 取最新目录那份；一般/优质/良好/较差为质量分级，非去重依据，不同分级文件均单独测试；同一md5在多目录出现的记入 versions_present，不重复测。疑似跨分片重复（更晚版本目录同名文件）未跨目录测试。

- 关键发现：
  1. 仅 1 个源完整可用：KE-DES 走官方 mobi.kuwo.cn convert_url_with_sign，酷我320k MP3 字节数==Content-Length(10,797,030B)、API声明269s，与《晴天》吻合。
  2. 「四平台FLAC」宣传普遍不实：唯一稳定完整的是酷我320k（官方mobi或nxinxz/haitangw代理同源同文件）；网易原版《晴天》(id186016)在所有GD系接口均返回url空，只能取到他人翻唱；QQ仅cyapi单链且所测mid实测映射《告白气球》；酷狗/咪咕全灭；FLAC多为50MB+翻唱，超12MB下载上限截断。
  3. 10个「全豆要」聚合源靠多链路回退勉强出URL，主链大量死亡：kw-er.kuwo.cn 410 Gone、api.vsaa.cn 全路径404、oiapi QQ 403维护、music-dl.sayqz.com DNS失效、api.cenguigui.cn 521、lxmusicapi.onrender.com 503停摆、m-api.ceseet.me 返回落地HTML。
  4. 2个打包/混淆源（洛雪科技独家v4、洛雪音乐源v2-fix jsjiami v7反调试）无法静态提取端点；野花/野草主机97.64.37.235 nginx存活但 /flower|grass/v1/url/ 路由404，npm配置包仅含版本vinfo元数据。
  5. 测试曲《晴天》(酷我rid=51685512/269s)；原版取不到的接口用备用词「七里香 周杰伦」复测；完整性以字节数==Content-Length+API声明时长为准（无ffmpeg，MP3帧扫描仅扫前2MB会低估，不作唯一判据）。

| # | 源名称 | 类型 | 脚本路径 | 请求端点(method+URL+参数形态) | 连通探测(状态/延迟/错误) | 可播放URL | 下载验证(字节/时长/格式) | 失败原因 | 归类 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 全豆要 | 聚合源 | V2603_latest\优质-支持四平台FLAC\全豆要(聚合音源)\全豆要-聚合音源 v3.0.0 TSS解密版.… | GET http://music.nxinxz.com/kw.php?id=<rid>&level=exhigh&ty… | 200/950ms/— | 是 | 10797030/269s/mp3/OK | 其他 | 部分可用 |
| 2 | 全豆要 | 聚合源 | V2603_latest\优质-支持四平台FLAC\全豆要(聚合音源)\全豆要-聚合音源 v3.0.0.js | GET http://music.nxinxz.com/kw.php?id=<rid>&level=exhigh&ty… | 200/950ms/— | 是 | 10797030/269s/mp3/OK | 其他 | 部分可用 |
| 3 | 全豆要[聚合音源] | 聚合源 | V2603_latest\优质-支持四平台FLAC\全豆要(聚合音源)\全豆要-聚合音源 v4.0 TSS解密版.js | GET https://music-api.gdstudio.xyz/api.php?types=url&source… | 200/1650ms/— | 是 | 11161644/—s/mp3/OK | 其他 | 部分可用 |
| 4 | 全豆要[聚合音源] | 聚合源 | V2603_latest\优质-支持四平台FLAC\全豆要(聚合音源)\全豆要-聚合音源 v4.0.js | GET https://music-api.gdstudio.xyz/api.php?types=url&source… | 200/1650ms/— | 是 | 11161644/—s/mp3/OK | 其他 | 部分可用 |
| 5 | 全豆要[聚合音源] | 聚合源 | V2603_latest\优质-支持四平台FLAC\全豆要(聚合音源)\全豆要-聚合音源 v5.0.js | GET https://music-api.gdstudio.xyz/api.php?types=url&source… | 200/1650ms/— | 是 | 11161644/—s/mp3/OK | 其他 | 部分可用 |
| 6 | 全豆要[聚合音源] | 聚合源 | V2603_latest\优质-支持四平台FLAC\全豆要(聚合音源)\全豆要-聚合音源 v5.1.js | GET https://music-api.gdstudio.xyz/api.php?types=url&source… | 200/1650ms/— | 是 | 11161644/—s/mp3/OK | 其他 | 部分可用 |
| 7 | 全豆要[聚合音源] | 聚合源 | V2603_latest\优质-支持四平台FLAC\全豆要(聚合音源)\全豆要-聚合音源 v9.1 91特供版.js | GET https://music-api.gdstudio.xyz/api.php?types=url&source… | 200/1650ms/— | 是 | 11161644/—s/mp3/OK | 其他 | 部分可用 |
| 8 | 全豆要[聚合音源] | 聚合源 | V2603_latest\优质-支持四平台FLAC\全豆要(聚合音源)\全豆要-聚合音源 v9.2 92特供版 Dee… | GET https://music-api.gdstudio.xyz/api.php?types=url&source… | 200/1650ms/— | 是 | 11161644/—s/mp3/OK | 其他 | 部分可用 |
| 9 | 全豆要[聚合音源] | 聚合源 | V2603_latest\优质-支持四平台FLAC\全豆要(聚合音源)\全豆要-聚合音源 v9.3 93特供版.js | GET https://music-api.gdstudio.xyz/api.php?types=url&source… | 200/1650ms/— | 是 | 11161644/—s/mp3/OK | 其他 | 部分可用 |
| 10 | Ciallo～(∠・ω< )⌒☆ | 平台源 | V2603_miniupdate\一般-支持单平台FLAC或多平台320k\Ciallo~.js | GET https://api.s0o1.com/API/wyy_music?msg=<kw>&sm=10 （搜索）；… | 200/1140ms/— | 是 | 12582912/—s/flac/截断/不符 | 空结果 | 部分可用 |
| 11 | KuwoDES | 平台源 | V2603_miniupdate\一般-支持单平台FLAC或多平台320k\KE-DES.js | GET https://mobi.kuwo.cn/mobi.s?f=web&source=kwplayercar_ar… | 200/153ms/— | 是 | 10797030/269s/mp3/OK | — | 可用 |
| 12 | yibai酷我流式(v4) | 平台源 | V2603_miniupdate\一般-支持单平台FLAC或多平台320k\yibai酷我流式V4.js | GET http://kwdec.942240.xyz/kwurl?id=<rid>&q=320k; id=rid; … | —/14ms/域名失效 | 否 | 未测 | 域名失效 | 不可用 |
| 13 | 惜缘 | 聚合源 | V2603_miniupdate\一般-支持单平台FLAC或多平台320k\惜缘 v1.js | GET https://yunzhiapi.cn/API/yyjhss.php?id=<id>&type=<qq/kw… | 200/493ms/空结果 | 否 | 未测 | 空结果 | 不可用 |
| 14 | Free listen | 平台源 | V2603_miniupdate\较差-支持单平台320k或多平台128k\FreeListen-需自备网易云VIP密… | GET/POST 各平台直连：www.kuwo.cn/api/v1/www/music/playUrl; u.y.qq… | 200/112ms/需签名 | 否 | 未测 | 需签名 | 不可用 |
| 15 | Huibq_lxmusic源 | 自定义源 | V2603_organized\一般-支持单平台FLAC或多平台320k\HUIBQ音源.js | GET https://lxmusicapi.onrender.com/url/<source>/<id>/<qual… | 503/857ms/其他 | 否 | 未测 | 其他 | 不可用 |
| 16 | 忆音音源 | 自定义源 | V2603_organized\一般-支持单平台FLAC或多平台320k\忆音音源 v1.js | GET https://music.3e0.cn/?server=<tencent/netease>&type=url… | 200/349ms/空结果 | 否 | 未测 | 空结果 | 不可用 |
| 17 | 星海音乐源 | 聚合源 | V2603_organized\一般-支持单平台FLAC或多平台320k\星海音乐源 v2.2.8.js | GET https://music-api.gdstudio.xyz/api.php?use_xbridge3=tru… | 200/1650ms/— | 是 | 11161644/—s/mp3/OK | 空结果 | 部分可用 |
| 18 | 统一音乐源 | 自定义源 | V2603_organized\一般-支持单平台FLAC或多平台320k\统一音乐源.js | GET https://music-api.gdstudio.xyz/api.php?types=url&source… | 200/1650ms/— | 是 | 11161644/—s/mp3/OK | 空结果 | 部分可用 |
| 19 | 全豆要[聚合音源] | 聚合源 | V2603_organized\优质-支持四平台FLAC\全豆要-聚合音源 v4.1 TSS解密版,兼容性处理，.js | GET https://music-api.gdstudio.xyz/api.php?types=url&source… | 200/1650ms/— | 是 | 11161644/—s/mp3/OK | 其他 | 部分可用 |
| 20 | 念心音源 | 自定义源 | V2603_organized\优质-支持四平台FLAC\念心音源 v1.0.0.js | GET http://music.nxinxz.com/kw.php?id=<rid>&level=exhigh&ty… | 200/950ms/— | 是 | 10797030/269s/mp3/OK | 空结果 | 部分可用 |
| 21 | [独家音源] | 其他 | V2603_organized\优质-支持四平台FLAC\洛雪科技[独家音源] v4-会停用.js | （packed 未注册成功，无静态 http 端点） | —/—/无法静态提取端点 | 否 | 未测 | 无法静态提取端点 | 不可用 |
| 22 | 洛雪音乐源 | 其他 | V2603_organized\优质-支持四平台FLAC\洛雪音乐源 1.0.0 v2-fix.js | （jsjiami v7 反调试死循环，无静态可提取端点） | —/—/无法静态提取端点 | 否 | 未测 | 无法静态提取端点 | 不可用 |
| 23 | 聚合API接口 (CF) | 聚合源 | V2603_organized\优质-支持四平台FLAC\聚合API.js | POST https://api.music.lerd.dpdns.org/<source>; init.conf 配… | 429/641ms/反爬 | 否 | 未测 | 反爬 | 不可用 |
| 24 | 长青SVIP音源 | 自定义源 | V2603_organized\优质-支持四平台FLAC\长青SVIP音源.js | GET https://musicapi.haitangw.net/music/kw.php?type=mp3&id=… | 200/925ms/— | 是 | 10797030/269s/mp3/OK | 其他 | 部分可用 |
| 25 | fish_music | 自定义源 | V2603_organized\良好-支持至少两平台FLAC\fish-music音源.js | GET https://m-api.ceseet.me/url/<source>/<id>/<quality>; 路径… | 200/1617ms/其他 | 否 | 未测 | 其他 | 不可用 |
| 26 | lx-玉宁熙 | 自定义源 | V2603_organized\良好-支持至少两平台FLAC\lx-玉宁熙 v1.1.5 需自行配置.js | GET http://api-v2.yuafeng.cn （需先注册获取 YuNingXi key 填入配置）; 需用… | —/—/需登录 | 否 | 未测 | 需登录 | 不可用 |
| 27 | 收集の聚合接口(LX版) | 聚合源 | V2603_organized\良好-支持至少两平台FLAC\收集の聚合接口.js | GET https://cyapi.top/API/qq_music.php?apikey=1ffdf5733f5d5… | 200/630ms/— | 是 | 2641182/—s/m4a/OK | 其他 | 部分可用 |
| 28 | 溯音音源 | 聚合源 | V2603_organized\良好-支持至少两平台FLAC\溯音音源 v1.js | GET https://oiapi.net/api/Kuwo?msg=<kw>&n=1 （仅kw活）；/api/QQ_… | 200/264ms/— | 是 | 2927865/—s/ogg/OK | 其他 | 部分可用 |
| 29 | 春日影 | 平台源 | V2603_organized\较差-支持单平台320k或多平台128k\春日影-单平台128k.js | GET http://itapi.top/API/get_wyyid.php?id=<wyid>; id=网易曲目ID | 404/202ms/404 | 否 | 未测 | 404 | 不可用 |
| 30 | 野花🌷 | 自定义源 | V2603_organized\较差-支持单平台320k或多平台128k\野花音源 .js | GET http://97.64.37.235/flower/v1/url/<platform>/<songmid>/… | 404/—/404 | 否 | 未测 | 404 | 不可用 |
| 31 | 野草🌾 | 自定义源 | V2603_organized\较差-支持单平台320k或多平台128k\野草音源.js | GET http://97.64.37.235/grass/v1/url/<platform>/<songmid>/<… | 404/—/404 | 否 | 未测 | 404 | 不可用 |
| 32 | 星海音乐源 | 聚合源 | v260212\良好-支持至少两平台FLAC\星海音乐源新.js | GET https://music-api.gdstudio.xyz/api.php?use_xbridge3=tru… | 200/1650ms/— | 是 | 11161644/—s/mp3/OK | 空结果 | 部分可用 |
| 33 | lx-玉宁熙 | 自定义源 | v260212\良好-支持至少两平台FLAC\玉宁熙-需自行配置-不推荐.js | GET http://api-v2.yuafeng.cn （需自行配置 key）; v1.1.2 旧版，需注册填key… | —/—/需登录 | 否 | 未测 | 需登录 | 不可用 |

### 3.4 仓库 guoyue2010/lxmusic-（中后期+zip分片，去重后 49 个源；可用 0 / 部分可用 10 / 不可用 39，可用率 0/49=0.0%）

- 去重说明：跨 V260418..V260907 按源名+md5 去重，canonical 取最新目录（优先级 V260907>V260817>V260810>V260716>V260714>V260620>v260511>V260504>v260429>V260418）；yinyuan.zip（15文件）逐文件与目录做 md5 比对，相同即去重仅记入 versions_present，仅测 zip 独有源；目录去重35个 + zip独有14个 = 49。
- 测试曲：周杰伦《晴天》(原版id 网易186016/酷我228908/QQ mid 0039MnYb0qxYhV，约269s)；完整可下载=字节数==Content-Length且时长±10s吻合(纯Python帧扫描)；FLAC=无损，MP3 320k不算无损。
- 关键发现：
  1. 当前网络下唯一完整跑通的是第三方聚合后端：oiapi.net/api/Kuwo(br192/300 ogg完整)、nmobi.kuwo.cn/mobi.s 与 haitangw/c.wwwweb/zddyr 转发的 car-er.kuwo.cn 320k mp3(10,792,943B/269.82s完整)、a.aa.cab 与 cyapi.top 的 QQ m4a(3,283,546B/269.82s完整)；这些均为"仅特定平台"链路，故归部分可用。
  2. 官方/原生直连(网易186016、QQ musicu、咪咕、B站)在当前网络不可用；GD解析器 netease 原版 url 为空(仅翻唱出FLAC)；oiapi Music_163 url=null、QQ_Music 403维护、xcvts咪咕502。
  3. 大量私有/公益后端已死：175.27.166.236、97.64.37.235、88.lxmusic.xn--fiqs8s、lc.guoyue2010.top、sayqz、onrender(503)、bxa241d4.shop、hywmusicsource 超时/连接失败；103.79.184.97 与 shiqianjiang 需卡密(401)；lerd CF免费层日配额429。
  4. jsjiami v7 打包源(#12/#38/#42/#43等)反调试导致无法静态提取端点；#23/#24 实为移动云盘净网占位docx，无代码；#25 作者标注已停用；#30/#49 长青仅远程版本元数据。

| # | 源名称 | 类型 | 脚本路径 | 请求端点(method+URL+参数形态) | 连通探测(状态/延迟/错误) | 可播放URL | 下载验证(字节/时长/格式) | 失败原因 | 归类 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 👖裤佬SVIP音源 | lx-music自定义源 | V260907\(推荐)裤佬SVIP音源（酷狗挂了）.js | GET https://musicapi.haitangw.net/music/kw.php?type=mp3&i… | [200] 811ms OK | 是 | 10792943B/269.82s mp3 match=T… | 其他 | 部分可用 |
| 2 | gdstudio音乐源 | 平台源 | V260907\gdstudio音乐源 v1.0.1（仅支… | GET https://music-api.gdstudio.xyz/api.php?types=search/u… | [200] 1011ms 空结果 | 否 | 未下载 | 空结果 | 部分可用 |
| 3 | lx-玉宁熙-Pro | lx-music自定义源 | V260907\lx-玉宁熙V1.2.2.js | GET http://ynx.de5.net/API/lx-ynx.php?APIKEY=[APIKEY]&sou… | [200] 622ms SSL | 否 | 未下载 | SSL | 不可用 |
| 4 | 星澜聚合音源 (StellarWave) | 聚合源 | V260907\stellarwave-v3.2.0.js | GET https://ffapi.cn/int/v2/songurl?url=<页面链接> | [200] 3356ms 其他 | 否 | 未下载 | 其他 | 不可用 |
| 5 | 全豆要[聚合音源] | 聚合源 | V260907\全豆要-聚合音源-V4.1（酷狗挂了）.js | GET 175.27.166.236/kgqq/wy.php; music.nxinxz.com; api.vsa… | [0] 2195ms 域名失效 | 否 | 未下载 | 域名失效 | 不可用 |
| 6 | 墨澜聚合音源 | 聚合源 | V260907\墨澜音乐源v2.3.0.js | GET http://103.79.184.97; 175.27.166.236; 88.lxmusic.xn--… | [401] 135ms 需登录 | 否 | 未下载 | 需登录 | 不可用 |
| 7 | 屿溪-终章 | lx-music自定义源 | V260907\屿溪-终章.js | GET 端点字符串表混淆,桩环境下全模块报错无法还原 | [0] 0ms 无法静态提取端点 | 否 | 未下载 | 无法静态提取端点 | 不可用 |
| 8 | 幻音音源 | lx-music自定义源 | V260907\幻音音源 v3.js | GET https://api.xcvts.cn/api/music/migu?gm={kw}&n=1&num=1… | [502] 0ms 域名失效 | 否 | 未下载 | 域名失效 | 不可用 |
| 9 | 念心音源 | lx-music自定义源 | V260907\念心音源 v1.0.2.js | GET https://gitee.com/nianxinxz1/emo-music/raw/master/wub… | [200] 380ms 空结果 | 否 | 未下载 | 空结果 | 不可用 |
| 10 | 收集の聚合接口(LX版) | 聚合源 | V260907\收集の聚合接口.js | GET https://cyapi.top/API/qq_music.php?apikey=...&type=js… | [200] 97ms OK | 是 | 3283546B/269.82s m4a match=Tr… | 其他 | 部分可用 |
| 11 | 溯音音源 | lx-music自定义源 | V260907\溯音音源_v1.js | GET https://oiapi.net/api/Kuwo?msg=晴天 周杰伦&n=1&br=2 ; /Mus… | [200] 0ms OK | 是 | 5860576B/269.75s ogg match=Tr… | 其他 | 部分可用 |
| 12 | 独家音源 | lx-music自定义源 | V260907\独家音源V5.js | GET https://88.lxmusic.xn--fiqs8s (SERVER_SCRIPT_CONFIG明文) | [0] 90ms 域名失效 | 否 | 未下载 | 域名失效 | 不可用 |
| 13 | 稳定版音源 v1.0.3 | 聚合源 | V260907\稳定版音源 v1.0.3.js | GET https://cyapi.top/API/qq_music.php; api.injahow.cn/me… | [200] 97ms OK | 是 | 3283546B/269.82s m4a match=Tr… | 其他 | 部分可用 |
| 14 | 统一音乐源 | 平台源 | V260907\统一音乐源.js | GET https://music-api.gdstudio.xyz/api.php?types=url&sour… | [200] 1011ms 空结果 | 否 | 未下载 | 空结果 | 不可用 |
| 15 | 聚合API接口 (CF) | 聚合源 | V260907\聚合API接口 (CF) v3.js | GET https://api.music.lerd.dpdns.org/url/{src}/{id}/{q} (… | [429] 656ms 其他 | 否 | 未下载 | 其他 | 不可用 |
| 16 | 西瓜聚合源 | 聚合源 | V260907\西瓜聚合.js | GET 175.27.166.236; nxinxz; vsaa; cenguigui; chksz; lerd;… | [0] 0ms 域名失效 | 否 | 未下载 | 域名失效 | 不可用 |
| 17 | 非常刀 | 聚合源 | V260907\非常刀 v5.js | GET oiapi.net/api/Kuwo; gdstudio; chksz; xcvts; 175.27; n… | [200] 0ms OK | 是 | 5860576B/269.75s ogg match=Tr… | 其他 | 部分可用 |
| 18 | 𝖧౿ᥣᥣ𝗈 Ԝ𝗈𝗋ᥣᑯ | 聚合源 | V260907\𝖧౿ᥣᥣ𝗈 Ԝ𝗈𝗋ᥣᑯ260809.js | GET https://a.aa.cab/qq.music?msg={kw}&n=1&type={q}; http… | [200] 676ms OK | 是 | 3283546B/269.82s m4a match=Tr… | 其他 | 部分可用 |
| 19 | Hei Music聚合源 | 聚合源 | V260817\其他\Hei Music1.3.1 (1)… | GET cp.chksz.top/api.php?action=sources_config (面板); 加密ur… | [404] 368ms 404 | 否 | 未下载 | 404 | 不可用 |
| 20 | HYWmusic_beta_公益测试 | lx-music自定义源 | V260817\推荐\HYWmusic_beta_公益测试… | GET http://103.79.184.97/api/music/url; /api/releases | [401] 135ms 需登录 | 否 | 未下载 | 需登录 | 不可用 |
| 21 | K×H测试 | lx-music自定义源 | V260817\推荐\K×H测试 v1.7.17.js | GET https://u.y.qq.com/cgi-bin/musicu.fcg (原生直连); 163/mig… | [200] 478ms 需签名 | 否 | 未下载 | 需签名 | 不可用 |
| 22 | 星海音乐源 | 聚合源 | V260817\推荐\xinghai-music-sour… | GET https://yy.zddyr.top/lx/api/?source=kw&songmid={id}&q… | [200] 379ms OK | 是 | 10792943B/269.82s mp3 match=T… | 其他 | 部分可用 |
| 23 | 野花音源_ | 其他 | V260817\未测试\野花音源_.js | 无(打包容器实为docx) | [0] 0ms 其他 | 否 | 未下载 | 其他 | 不可用 |
| 24 | 野草音源 | 其他 | V260817\未测试\野草音源.js | 无(打包容器实为docx) | [0] 0ms 其他 | 否 | 未下载 | 其他 | 不可用 |
| 25 | [独家音源] | 其他 | V260810\未测试\独家音源v4目前已停用.js | 作者标注目前已停用 | [0] 0ms 其他 | 否 | 未下载 | 其他 | 不可用 |
| 26 | fish_music | 平台源 | V260716\其他\fish-music音源.js | GET https://m-api.ceseet.me/url/{source}/{songId}/{qualit… | [200] 760ms 404 | 否 | 未下载 | 404 | 不可用 |
| 27 | Huibq_lxmusic源 | 平台源 | V260716\其他\HUIBQ音源.js | GET https://lxmusicapi.onrender.com/url/{src}/{id}/{q} | [503] 852ms 域名失效 | 否 | 未下载 | 域名失效 | 不可用 |
| 28 | HYW×Koneko-API-Charity | lx-music自定义源 | V260716\其他\hywV1.0.0.js | GET http://hywmusicsource.xn--9tra.work/api/releases; 本地l… | [0] 10018ms 超时 | 否 | 未下载 | 超时 | 不可用 |
| 29 | 忆音音源 | 平台源 | V260716\其他\忆音音源_v1.js | GET https://music.3e0.cn/?server={tencent/netease}&type=u… | [200] 335ms 空结果 | 否 | 未下载 | 空结果 | 不可用 |
| 30 | 长青SVIP音源 | lx-music自定义源 | V260716\推荐\【推荐】长青SVIP音源v1.2.0… | GET https://13413.kstore.vip/lxmusic/changqing.json (远程配置… | [404] 167ms 无法静态提取端点 | 否 | 未下载 | 无法静态提取端点 | 不可用 |
| 31 | 音乐下载器 | 聚合源 | V260716\推荐\音乐下载器_v6.js | GET haitangw kw.php(fallback); 175.27.166.236(死); oiapi K… | [200] 811ms OK | 是 | 10792943B/269.82s mp3 match=T… | 其他 | 部分可用 |
| 32 | 野花🌷 | lx-music自定义源 | V260620\其他\野花音源_.js | GET base 97.64.37.235(明文无,打包) | [0] 10010ms 超时 | 否 | 未下载 | 超时 | 不可用 |
| 33 | 野草🌾 | lx-music自定义源 | V260620\其他\野草音源.js | GET base 97.64.37.235(打包) | [0] 10010ms 超时 | 否 | 未下载 | 超时 | 不可用 |
| 34 | HYWmusic_beta | lx-music自定义源 | v260511\第二批次\HYWmusic_beta_v0… | GET https://music.bxa241d4.shop | [0] 10006ms 超时 | 否 | 未下载 | 超时 | 不可用 |
| 35 | lx-玉宁熙 | lx-music自定义源 | v260511\第二批次\lx-玉宁熙 【kg-flac2… | GET api-v2.yuafeng.cn(需apikey); gitee远程源码; ynx.de5.net | [200] 428ms SSL | 否 | 未下载 | SSL | 不可用 |
| 36 | fish_music | 平台源 | yinyuan.zip/fish-music音源.js | GET https://m-api.ceseet.me/url/{source}/{songId}/{qualit… | [200] 760ms 404 | 否 | 未下载 | 404 | 不可用 |
| 37 | 独家音源 [解密版] | lx-music自定义源 | yinyuan.zip/公众号音源-解密版.js | GET https://88.lxmusic.xn--fiqs8s (解密版配置) | [0] 90ms 域名失效 | 否 | 未下载 | 域名失效 | 不可用 |
| 38 | [独家音源] | lx-music自定义源 | yinyuan.zip/公众号音源.js | jsjiami打包,无明文端点(参考lx-music-api-server) | [0] 0ms 无法静态提取端点 | 否 | 未下载 | 无法静态提取端点 | 不可用 |
| 39 | 收集の聚合接口（落雪插件版） | 聚合源 | yinyuan.zip/收集-聚合接口.js | GET https://cyapi.top/API/qq_music.php?apikey=...&type=js… | [200] 97ms OK | 是 | 3283546B/269.82s m4a match=Tr… | 其他 | 部分可用 |
| 40 | 新澜音源(公益版) | lx-music自定义源 | yinyuan.zip/新澜-公益.js | GET https://source.shiqianjiang.cn/api/music/url?source=&… | [401] 212ms 需登录 | 否 | 未下载 | 需登录 | 不可用 |
| 41 | 星海音乐源 | 聚合源 | yinyuan.zip/星海音乐源.js | GET gdstudio api.php; music-dl.sayqz.com/api/; zrcdy.dpdn… | [500] 276ms 空结果 | 否 | 未下载 | 空结果 | 不可用 |
| 42 | 星空源 | lx-music自定义源 | yinyuan.zip/星空音源.js | jsjiami.com.v7打包,无明文端点 | [0] 0ms 无法静态提取端点 | 否 | 未下载 | 无法静态提取端点 | 不可用 |
| 43 | 洛雪音乐源 | lx-music自定义源 | yinyuan.zip/洛雪音乐源.js | jsjiami.com.v7打包,无明文端点 | [0] 0ms 无法静态提取端点 | 否 | 未下载 | 无法静态提取端点 | 不可用 |
| 44 | lx-玉宁熙 | lx-music自定义源 | yinyuan.zip/玉宁熙音源.js | GET gitee Myn_1/Mao_Yuna raw 远程源码 | [403] 190ms SSL | 否 | 未下载 | SSL | 不可用 |
| 45 | 聆川(公益版) | lx-music自定义源 | yinyuan.zip/聆川-公益.js | GET https://lc.guoyue2010.top/api/music/url?source=&songI… | [0] 15ms 域名失效 | 否 | 未下载 | 域名失效 | 不可用 |
| 46 | 花瓣源（原netease，电脑版亲测有用) | lx-music自定义源 | yinyuan.zip/花瓣音源.js | 打包无明文端点 | [0] 0ms 无法静态提取端点 | 否 | 未下载 | 无法静态提取端点 | 不可用 |
| 47 | 野花🌷 | lx-music自定义源 | yinyuan.zip/野花音源.js | GET base 97.64.37.235(打包) | [0] 10010ms 超时 | 否 | 未下载 | 超时 | 不可用 |
| 48 | 野草🌾 | lx-music自定义源 | yinyuan.zip/野草音源.js | GET base 97.64.37.235(打包) | [0] 10010ms 超时 | 否 | 未下载 | 超时 | 不可用 |
| 49 | 长青SVIP音源 | lx-music自定义源 | yinyuan.zip/长青SVIP音源.js | GET 13413.kstore.vip 远程配置(端点内嵌) | [404] 167ms 无法静态提取端点 | 否 | 未下载 | 无法静态提取端点 | 不可用 |


## 4 多曲目重测（3 类歌曲 × 逐源，2026-10-22 第二轮实测）

> 本轮在首轮 100 条源记录基础上迭代：端点直接复用首轮归档 JSON，不做重复解析；测试曲由 3 类歌曲组成（类A 无版权 / 类B VIP 付费 / 类C 网易云独有），版权状态经跨平台实测验证（证据详见 `github_sources/_results/` 与《测试曲目清单与版权验证表.md》）。主判定按用户定义改为**废源 / 非废源**，原三级归类（可用/部分可用/不可用）保留为子维度。

### 4.1 测试曲目与跨平台版权状态验证（实测，非凭印象）

| 类 | 歌曲 | 网易云 | QQ | 酷狗 | 酷我 | 官方直连（未登录） |
|---|---|---|---|---|---|---|
| A | 晴天/周杰伦 | **无官方原版**（双接口各20条扫描仅 UGC 翻唱/伴奏） | VIP（pay_play=1, price_track=200）mid=0039MnYb0qxYhV | VIP（PayType=3, Price=200）hash=B3A5…18B7 | **免费**（PAY=0）rid=51685512 | 仅酷我 mobi.s 320k 可下（10,797,030B/269s） |
| A | 稻香/周杰伦 | 无官方原版 | VIP mid=003aAYrm3GE0Ac | VIP hash=8909E1…93F0 | **免费**（128k 降级）rid=351583919 | 仅酷我可下（128k） |
| A | 七里香/周杰伦 | 无官方原版 | VIP mid=004Z8Ihr0JIu5s | VIP hash=9218D8…AD6D | **免费**（320k）rid=493628806 | 仅酷我 320k 可下 |
| B | 大鱼/周深 | VIP（fee=1）id=516823132 | VIP mid=004OQ5Mt0EmEzv | VIP hash=913EA1…6E2C | VIP（fpay=1, 官方仅11s试听）rid=7095195 | 全平台不可下（NE code=-110 / QQ purl空 / KG 30020） |
| B | 演员/薛之谦 | VIP（fee=1）id=32507038 | VIP mid=001Qu4I30eVFYb | VIP hash=097E77…9477 | 仅133s半长免费片段 rid=482894392 | 同上 |
| B | 年少有为/李荣浩 | VIP（fee=1）id=1293886117 | VIP mid=004DXFlC0nsTCZ | VIP hash=3A5C1D…08B0 | 无原版 | 同上 |
| C | （网易云独有） | — | — | — | — | **0 首入选**：59 个独立/民谣/乐队候选跨4平台全量搜索验证，凡网易云能搜到原版的歌，QQ 与酷狗均能搜到同一原版，仅酷我普遍缺目录——按"QQ/酷狗/酷我均无结果、仅网易云可搜到"标准搜索层无法证实任何一首；全量证据矩阵见 `test_songs.json` class_c_tested_candidates |

> 版权事实修正（实测）：①"周杰伦曲库网易云独占"前提不成立——网易云当前搜索不到周杰伦官方原版（仅 UGC 翻唱），QQ/酷狗为 VIP 付费，**酷我反而免费且直链可取原版**；②类B 三首在全部主流平台带付费标识（字段原文见上表），官方直连层无一可下。

### 4.2 判定标准与执行方式

- **主判定（用户定义）**：废源 = 3 类测试歌曲全部无法获取音乐；非废源 = 任意一类中任意一首返回可播放/可下载的音乐。类C 实测 0 首入选（见 4.1），故废源判定按**类A 3 首 + 类B 3 首共 6 首**执行；类C 的决策点（接受0首/放宽标准/登录态补测）已在交付说明中向用户明示。
- **命中分级**：`full`=返回可播放 URL 且完整下载验证通过（字节==Content-Length、时长吻合，纯 Python MP3/Ogg/FLAC 解析，本机无 ffmpeg）；`partial`=可播放、时长≥60s 但非完整（如 133s 半长片段、12MB 上限截断）；`fragment`=<30s 试听片段（不计命中，如 KuwoDES 大鱼 5.9s 防盗链片段）；`expected_fail`=平台无此曲/官方层付费无版权（锚点表已证）；`source_fail`=源端点自身超时/404/503/反爬。
- **效率策略（用户允许）**：首轮已确认死亡的 65 条源（DNS 失效、onrender 503 Suspended、jsjiami 混淆无法提取端点、401 需卡密、403/404/SSL/需签名/超时等）直接沿用首轮结论标记废源，不重复超时重测；35 条需重测源全部为首轮"可用/部分可用"或"空结果"中可能因歌而异的源。
- **调用方式**：直接复用首轮提取的端点模板，优先用 4.1 锚点（rid/mid/hash/id）构造取 URL 请求，避免重复搜索；风控同首轮（单端点≤3 次、2s/5s 退避、单请求15s/下载25s、同 host≥1s、全局≤3req/s）。

### 4.3 重测结果统计

| 仓库 | 记录数 | 非废源 | 废源 | 备注 |
|---|---|---|---|---|
| pdone/lx-music-source | 11 | 2 | 9 | 保留：全豆要、星海（多平台命中） |
| Huibq/keep-alive | 7 | 0 | 7 | 全废：取流全部依赖 onrender 代理（503 停用） |
| guoyue2010/lxmusic- V2603家族 | 33 | 19 | 14 | 保留 19（含同 md5 跨版本对） |
| guoyue2010/lxmusic- 中后期+zip | 49 | 12 | 37 | 保留 12（含同 md5 跨版本对） |
| **合计** | **100** | **33** | **67** | 可用率（非废源）33% |

- **与原三级归类交叉**：非废源 33 = 原可用 3 + 原部分可用 28 + 原不可用 2；废源 67 = 原不可用 64 + 原部分可用 3。即首轮"可用"3 条全部保留，"部分可用"28/31 保留，"不可用"仅 2/66 反转（Ciallo s0o1 网易链、统一音乐源 gdstudio 链本轮出全量）。
- **命中分布（33 非废源，155 次平台命中）**：酷我 62 / 网易云 57 / QQ 30 / 酷狗 6；歌曲命中：演员 38、大鱼 36、年少有为 26、晴天 19、七里香 19、稻香 17；类别：类A(无版权) 55 次、类B(VIP) 100 次——**33 个保留源全部命中 VIP 付费类，29 个命中无版权类**，说明第三方代理链普遍具备 VIP 解锁与多平台兜底能力。
- **稻香注记**：酷我系链（nxinxz/haitangw/mobi.s）对 rid=351583919 命中的为"稻香(DJ Ray版)"remix（ID3 实证，完整可播，表中标"(非原版)"）；星海酷狗链可出原版（8,940,938B）。

### 4.4 非废源清单（保留源，33 条；full=完整可下载，partial=≥60s 非完整，(非原版)=ID3/标题实证非原曲）


| # | 仓库 | 源名称 | 命中歌曲（类-歌/平台(级别 字节)） | 首轮归类 |
|---|---|---|---|---|
| 1 | pdone | 全豆要[聚合音源] | A-晴天/酷我(full 10.8MB); A-稻香/酷我(full 3,003,229B(非原版)); A-七里香/酷我(full 11.1MB); B-大鱼/酷我(full 12.6MB); B-大鱼/网易云(partial 12.6MB); B-演员/酷我(partial 5,331,242B); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 可用 |
| 2 | pdone | 星海音乐源 | A-晴天/酷我(full 10.8MB); A-晴天/酷狗(full 10.8MB); A-稻香/酷狗(full 8,940,938B); A-七里香/酷我(full 11.1MB); A-七里香/酷狗(full 12.0MB); B-大鱼/酷我(full 12.6MB); B-大鱼/酷狗(full 12.6MB); B-大鱼/网易云(partial 2,555,904B); B-演员/酷我(partial 5,331,242B); B-演员/酷狗(full 10.5MB); B-演员/网易云(full 10.5MB); B-年少有为/酷狗(full 11.2MB); B-年少有为/网易云(f | 可用 |
| 3 | guoyue | 全豆要 | A-晴天/酷我(full 10.8MB); A-稻香/酷我(full 3,003,229B(非原版)); A-七里香/酷我(full 11.1MB); B-大鱼/酷我(full 12.6MB); B-演员/酷我(partial 5,331,242B) | 部分可用 |
| 4 | guoyue | 全豆要 | A-晴天/酷我(full 10.8MB); A-稻香/酷我(full 3,003,229B(非原版)); A-七里香/酷我(full 11.1MB); B-大鱼/酷我(full 12.6MB); B-演员/酷我(partial 5,331,242B) | 部分可用 |
| 5 | guoyue | 全豆要[聚合音源] | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 部分可用 |
| 6 | guoyue | 全豆要[聚合音源] | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 部分可用 |
| 7 | guoyue | 全豆要[聚合音源] | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 部分可用 |
| 8 | guoyue | 全豆要[聚合音源] | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 部分可用 |
| 9 | guoyue | 全豆要[聚合音源] | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 部分可用 |
| 10 | guoyue | 全豆要[聚合音源] | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 部分可用 |
| 11 | guoyue | 全豆要[聚合音源] | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 部分可用 |
| 12 | guoyue | Ciallo～(∠・ω< )⌒☆ | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(partial 12.6MB); B-年少有为/网易云(partial 12.6MB) | 部分可用 |
| 13 | guoyue | KuwoDES | A-晴天/酷我(full 10.8MB); A-稻香/酷我(full 3,003,229B(非原版)); A-七里香/酷我(full 11.1MB); B-演员/酷我(partial 5,331,242B) | 可用 |
| 14 | guoyue | 星海音乐源 | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 部分可用 |
| 15 | guoyue | 统一音乐源 | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 部分可用 |
| 16 | guoyue | 全豆要[聚合音源] | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 部分可用 |
| 17 | guoyue | 念心音源 | A-晴天/酷我(full 10.8MB); A-稻香/酷我(full 3,003,229B(非原版)); A-七里香/酷我(full 11.1MB); B-大鱼/酷我(full 12.6MB); B-演员/酷我(partial 5,331,242B) | 部分可用 |
| 18 | guoyue | 长青SVIP音源 | A-晴天/酷我(full 10.8MB); A-稻香/酷我(full 3,003,229B(非原版)); A-七里香/酷我(full 11.1MB); B-大鱼/酷我(full 12.6MB); B-演员/酷我(partial 5,331,242B) | 部分可用 |
| 19 | guoyue | 收集の聚合接口(LX版) | A-晴天/QQ(full 3,283,546B); A-稻香/QQ(full 2,743,154B); A-七里香/QQ(full 3,636,813B); B-大鱼/QQ(full 3,837,239B); B-演员/QQ(full 3,206,497B); B-年少有为/QQ(full 3,386,264B) | 部分可用 |
| 20 | guoyue | 溯音音源 | A-晴天/酷我(full 5,860,576B); A-稻香/酷我(full 5,136,737B); A-七里香/酷我(full 12.0MB); B-大鱼/酷我(full 6,143,833B); B-大鱼/网易云(full 5,082,845B); B-演员/酷我(partial 5,638,264B); B-演员/网易云(full 4,180,889B); B-年少有为/网易云(full 4,468,027B) | 部分可用 |
| 21 | guoyue | 星海音乐源 | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 部分可用 |
| 22 | guoyue | 👖裤佬SVIP音源 | A-晴天/酷我(full 10.8MB); A-稻香/酷我(full 3,003,229B); A-七里香/酷我(full 11.1MB); B-大鱼/酷我(full 12.6MB); B-演员/酷我(partial 5,331,242B) | 部分可用 |
| 23 | guoyue | gdstudio音乐源 | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 部分可用 |
| 24 | guoyue | 收集の聚合接口(LX版) | A-晴天/QQ(full 3,283,546B); A-稻香/QQ(full 2,743,154B); A-七里香/QQ(full 3,636,813B); B-大鱼/QQ(full 3,837,239B); B-演员/QQ(full 3,206,497B); B-年少有为/QQ(full 3,386,264B) | 部分可用 |
| 25 | guoyue | 溯音音源 | A-晴天/酷我(full 5,860,576B); A-稻香/酷我(full 5,136,737B); A-七里香/酷我(full 12.0MB); B-大鱼/酷我(full 6,143,833B); B-大鱼/网易云(full 5,082,845B); B-演员/酷我(partial 5,638,264B); B-演员/网易云(full 4,180,889B); B-年少有为/网易云(full 4,468,027B) | 部分可用 |
| 26 | guoyue | 稳定版音源 v1.0.3 | A-晴天/QQ(full 3,283,546B); A-稻香/QQ(full 2,743,154B); A-七里香/QQ(full 3,636,813B); B-大鱼/QQ(full 3,837,239B); B-演员/QQ(full 3,206,497B); B-年少有为/QQ(full 3,386,264B) | 部分可用 |
| 27 | guoyue | 统一音乐源 | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 不可用 |
| 28 | guoyue | 非常刀 | A-晴天/酷我(full 5,860,576B); A-稻香/酷我(full 5,136,737B); A-七里香/酷我(full 12.0MB); B-演员/酷我(full 5,638,264B); B-年少有为/酷我(full 11.1MB) | 部分可用 |
| 29 | guoyue | 𝖧౿ᥣᥣ𝗈 Ԝ𝗈𝗋ᥣᑯ | A-晴天/QQ(full 3,283,546B); A-稻香/QQ(full 2,743,154B); A-七里香/QQ(full 3,636,813B); B-大鱼/QQ(full 3,837,239B); B-演员/QQ(full 3,206,497B); B-年少有为/QQ(full 3,386,264B) | 部分可用 |
| 30 | guoyue | 星海音乐源 | A-晴天/酷我(full 10.8MB); A-七里香/酷我(full 11.1MB); B-大鱼/酷我(full 12.6MB); B-演员/酷我(partial 5,331,242B) | 部分可用 |
| 31 | guoyue | 音乐下载器 | A-晴天/酷我(full 10.8MB); A-稻香/酷我(full 3,003,229B); A-七里香/酷我(full 11.1MB); B-大鱼/酷我(full 12.6MB); B-演员/酷我(partial 5,331,242B) | 部分可用 |
| 32 | guoyue | 收集の聚合接口（落雪插件版） | A-晴天/QQ(full 3,283,546B); A-稻香/QQ(full 2,743,154B); A-七里香/QQ(full 3,636,813B); B-大鱼/QQ(full 3,837,239B); B-演员/QQ(full 3,206,497B); B-年少有为/QQ(full 3,386,264B) | 部分可用 |
| 33 | guoyue | 星海音乐源 | B-大鱼/网易云(partial 12.6MB); B-演员/网易云(full 10.5MB); B-年少有为/网易云(full 11.2MB) | 不可用 |
### 4.5 废源清单（67 条；判废依据为首轮实测失败原因，65 条未重测+2 条重测确认）


| # | 仓库 | 源名称 | 首轮归类 | 判废依据（首轮实测失败原因） |
|---|---|---|---|---|
| 1 | pdone | 长青SVIP音源 | 不可用 | 404 |
| 2 | pdone | 野花🌷 | 不可用 | 反爬 |
| 3 | pdone | 野草🌾 | 不可用 | 反爬 |
| 4 | pdone | 幻音音源 | 不可用 | 空结果 |
| 5 | pdone | Huibq_lxmusic源 | 不可用 | 域名失效 |
| 6 | pdone | ikun音源 | 不可用 | 域名失效 |
| 7 | pdone | 聚合API接口 (CF) | 不可用 | 反爬 |
| 8 | pdone | 独家音源 | 不可用 | 其他 |
| 9 | pdone | 六音音源 | 不可用 | 域名失效 |
| 10 | Huibq | 小枸音乐(酷狗) | 部分可用 | 其他 |
| 11 | Huibq | 小蜜音乐(咪咕) | 不可用 | 其他 |
| 12 | Huibq | 小秋音乐(QQ音乐) | 部分可用 | 其他 |
| 13 | Huibq | 小蜗音乐(酷我) | 部分可用 | 其他 |
| 14 | Huibq | 小芸音乐(网易云) | 不可用 | 反爬 |
| 15 | Huibq | Huibq_lxmusic源(render_api.js) | 不可用 | 其他 |
| 16 | Huibq | keep-alive保活脚本(main.py) | 不可用 | 无法静态提取端点 |
| 17 | guoyue | yibai酷我流式(v4) | 不可用 | 域名失效 |
| 18 | guoyue | 惜缘 | 不可用 | 空结果 |
| 19 | guoyue | Free listen | 不可用 | 需签名 |
| 20 | guoyue | Huibq_lxmusic源 | 不可用 | 其他 |
| 21 | guoyue | 忆音音源 | 不可用 | 空结果 |
| 22 | guoyue | [独家音源] | 不可用 | 无法静态提取端点 |
| 23 | guoyue | 洛雪音乐源 | 不可用 | 无法静态提取端点 |
| 24 | guoyue | 聚合API接口 (CF) | 不可用 | 反爬 |
| 25 | guoyue | fish_music | 不可用 | 其他 |
| 26 | guoyue | lx-玉宁熙 | 不可用 | 需登录 |
| 27 | guoyue | 春日影 | 不可用 | 404 |
| 28 | guoyue | 野花🌷 | 不可用 | 404 |
| 29 | guoyue | 野草🌾 | 不可用 | 404 |
| 30 | guoyue | lx-玉宁熙 | 不可用 | 需登录 |
| 31 | guoyue | lx-玉宁熙-Pro | 不可用 | SSL |
| 32 | guoyue | 星澜聚合音源 (StellarWave) | 不可用 | 其他 |
| 33 | guoyue | 全豆要[聚合音源] | 不可用 | 域名失效 |
| 34 | guoyue | 墨澜聚合音源 | 不可用 | 需登录 |
| 35 | guoyue | 屿溪-终章 | 不可用 | 无法静态提取端点 |
| 36 | guoyue | 幻音音源 | 不可用 | 域名失效 |
| 37 | guoyue | 念心音源 | 不可用 | 空结果 |
| 38 | guoyue | 独家音源 | 不可用 | 域名失效 |
| 39 | guoyue | 聚合API接口 (CF) | 不可用 | 其他 |
| 40 | guoyue | 西瓜聚合源 | 不可用 | 域名失效 |
| 41 | guoyue | Hei Music聚合源 | 不可用 | 404 |
| 42 | guoyue | HYWmusic_beta_公益测试 | 不可用 | 需登录 |
| 43 | guoyue | K×H测试 | 不可用 | 需签名 |
| 44 | guoyue | 野花音源_ | 不可用 | 其他 |
| 45 | guoyue | 野草音源 | 不可用 | 其他 |
| 46 | guoyue | [独家音源] | 不可用 | 其他 |
| 47 | guoyue | fish_music | 不可用 | 404 |
| 48 | guoyue | Huibq_lxmusic源 | 不可用 | 域名失效 |
| 49 | guoyue | HYW×Koneko-API-Charity | 不可用 | 超时 |
| 50 | guoyue | 忆音音源 | 不可用 | 空结果 |
| 51 | guoyue | 长青SVIP音源 | 不可用 | 无法静态提取端点 |
| 52 | guoyue | 野花🌷 | 不可用 | 超时 |
| 53 | guoyue | 野草🌾 | 不可用 | 超时 |
| 54 | guoyue | HYWmusic_beta | 不可用 | 超时 |
| 55 | guoyue | lx-玉宁熙 | 不可用 | SSL |
| 56 | guoyue | fish_music | 不可用 | 404 |
| 57 | guoyue | 独家音源 [解密版] | 不可用 | 域名失效 |
| 58 | guoyue | [独家音源] | 不可用 | 无法静态提取端点 |
| 59 | guoyue | 新澜音源(公益版) | 不可用 | 需登录 |
| 60 | guoyue | 星空源 | 不可用 | 无法静态提取端点 |
| 61 | guoyue | 洛雪音乐源 | 不可用 | 无法静态提取端点 |
| 62 | guoyue | lx-玉宁熙 | 不可用 | SSL |
| 63 | guoyue | 聆川(公益版) | 不可用 | 域名失效 |
| 64 | guoyue | 花瓣源（原netease，电脑版亲测有用) | 不可用 | 无法静态提取端点 |
| 65 | guoyue | 野花🌷 | 不可用 | 超时 |
| 66 | guoyue | 野草🌾 | 不可用 | 超时 |
| 67 | guoyue | 长青SVIP音源 | 不可用 | 无法静态提取端点 |
### 4.6 关键发现与结论

1. **官方直连层全灭，第三方代理链是唯一可用路径**：官方直连（网易 code=-110 / QQ 未登录 purl 空 / 酷狗 30020 / 酷我仅试听）对 6 首测试曲无一可下；33 个非废源全部经第三方代理/聚合后端出链。
2. **三大主力后端链（均实测完整下载）**：酷我系——haitangw/nxinxz/zddyr/oiapi/mobi.s（320k MP3 或 ogg 全量，含 VIP 大鱼 12.6MB/313s）；QQ 系——cyapi.top / a.aa.cab（全量 m4a，6 首全中）；网易云系——gdstudio/oiapi Music_163/s0o1（VIP 全量 mp3/flac，大鱼 12MB 上限截断 partial）。
3. **VIP 解锁能力普遍**：33 个保留源全部命中类B（4 平台付费曲），其中 QQ 源 4 条（cyapi/aa.cab/稳定版/收集系）6 首全量 m4a 全中；酷我源 12 条可下 VIP 大鱼全量（官方仅 11s 试听）。
4. **类A 无版权场景兜底成立**：29 个保留源在"QQ/酷狗 VIP、网易无原版"约束下仍能命中（酷我免费曲 3 首 + 星海酷狗链 6 次），多平台聚合源（全豆要/星海）体现兜底价值。
5. **与首轮结论的差异（行为变化，非首轮错误）**：gdstudio 网易支流首轮"原版空/仅翻唱"，本轮对类B VIP 曲返回全量（10,452,158B 演员、11,170,003B 年少有为）；统一音乐源、Ciallo 由"空结果/部分可用"转非废源。
6. **两类"保留但受限"**：KuwoDES 类A 3 首 full 但大鱼仅 5.9s 防盗链片段（fragment 不计命中）；演员在酷我系全部为 133s 半长 partial（官方酷我无完整原版）。
7. **废源结构**：67 个废源 = 65 个首轮死亡源（DNS 11 + onrender 503 系 7 + jsjiami 无法提取 10 + 401/403/404/SSL/需签名/超时等 37）+ 2 个重测确认（惜缘 yunzhiapi 200 空体、星澜 ffapi"接口已经关闭"）。
8. **测试曲锚点与版权证据**（类A/类B 每平台 exists/paid/直连结果）全部实测并记录于 `test_songs.json` 与《测试曲目清单与版权验证表.md》，未凭印象宣称"无版权/VIP/独有"。

---

## 5 跨仓库去重与版本关系

- **完全重复（同 md5，唯一源只算一个；明细表保留各仓库条目便于溯源）**：
  - pdone ↔ guoyue（字节级一致 4 组）：`野花🌷`（flower/latest.js ↔ V2603_organized/野花音源 .js）、`野草🌾`（grass/latest.js ↔ V2603_organized/野草音源.js）、`Huibq_lxmusic源`（huibq/latest.js ↔ HUIBQ音源.js ↔ keep-alive render_api.js，MD5 53B59E60…，onrender 503 判定一致）、`幻音音源`（huanyin/latest.js ↔ V260907/幻音音源 v3.js，xcvts 502 判定一致）。
  - guoyue 跨分片（V2603 家族 ↔ 中后期版本目录，同内容快照）：`忆音音源`、`统一音乐源`、`全豆要[聚合音源]`（部分版本）、`[独家音源]`、`fish_music`、`收集の聚合接口(LX版)`、`溯音音源` —— 同内容只测一份，判定以最新版本目录为准；其中 `统一音乐源` 在两次探测中结果有差异（部分可用-仅翻唱 / 不可用-空结果），按宽松解释取 **部分可用（仅翻唱）**。
- **同名异版（同名不同 md5，版本演进，各自保留并交叉引用）**：`全豆要*`（12 条 / 10 个不同内容）、`星海音乐源`（5 版）、`lx-玉宁熙`（4 版）、`野花/野草`（各 4 份含 zip）、`长青SVIP音源`（4 版）、`聚合API接口 (CF)`（3 版）、`fish_music`（3 版）、`[独家音源]`（3 版）、`洛雪音乐源`（2 版）、`念心音源`（2 版）、`忆音音源`（2 版）等。
- **同源不同实现/别名**：`qdy(全豆要 9.3)` 与 guoyue 各版本全豆要、裤佬SVIP 同属"haitangw/nxinxz 酷我链"家族（各自实测 10,792,943 B/10,797,030 B 级一致）；`星海音乐源`（pdone xinghai ↔ guoyue 各版本）同属 `yy.zddyr.top/lx/api/` 后端；GD 解析器（music-api.gdstudio.xyz）作为多条源内置支流出现 6 次以上，结论一致。

## 6 失败原因分布（不可用 + 部分可用，共 97 条）

| 失败原因 | 条数 | 典型例子 |
|---|---|---|
| 其他 | 35 | 第三方代理后端停用（onrender 503 Suspended 系列 5+ 条）、上游 521（cenguigui）、落地页无 API（ceseet SPA）、Cloudflare 免费层日配额 429（lerd） |
| 空结果 | 13 | 网易原版 186016 各 GD 系接口 url 为空；3e0/meting 空页；gitee 远程配置仅元数据 |
| 域名失效 | 11 | api.ikunshare.com、sixyin.com、music-dl.sayqz.com、lc.guoyue2010.top、88.lxmusic.xn--fiqs8s（连接重置）、onrender（503）等 |
| 无法静态提取端点 | 10 | jsjiami v7 反调试（洛雪音乐源 v2-fix、星空源、公众号音源等）、VM/AES 混淆（六音、独家音源）、secrets（main.py） |
| 404 | 7 | 长青SVIP 模板（yinyue.haitangw.net）、春日影、Hei Music 面板、野花/野草路由（97.64.37.235） |
| 超时 | 6 | 97.64.37.235 打包基址、bxa241d4.shop、hywmusicsource |
| 反爬 | 5 | 野花/野草（97.64.37.235 403）、juhe/聚合API CF（429）、网易 weapi 空体 |
| 需登录 | 5 | 103.79.184.97 / shiqianjiang / HYWmusic 公益卡密 401、玉宁熙需注册 key |
| SSL | 3 | ynx.de5.net / yuafeng / gitee raw 403 |
| 需签名 | 2 | QQ musicu code500003（K×H、FreeListen）、lx 独家 signSalt |

## 7 与前序审计衔接（《接口归类清单-音乐与歌词.md》）

- **酷我 mobi.s**：本轮 `KuwoDES`（10,797,030 B / 269 s）与前序审计（10,797,030 B / 269.92 s）**字节级一致**，同接口族结论互证；antiserver 同源同文件结论与本轮 car-er.kuwo.cn CDN 重定向链路兼容。
- **GD 解析器**（music-api.gdstudio.xyz）：原版 186016 url 空、翻唱出 FLAC —— 前序审计、pdone 支流、guoyue 多源三处独立复现，结论一致。
- **网易云 / QQ / 咪咕 / B站 / Spoti 直连**：当前网络不可用（网易 186016 url=null、QQ musicu 500003 需签名、咪咕 502）——与前序一致；QQ 仅第三方聚合后端（cyapi.top / a.aa.cab）可出完整 m4a（3,283,546 B / 269.82 s，4 条记录）。
- **归类延续**：本报告全部源均为"返回音乐的接口"；歌词接口结论沿用既有报告（LDDC、LrcApi）。

## 8 局限说明

- **单曲验证**：全部判定基于《晴天》（备用《七里香》）；个别源所测 id 映射到其他曲目（如收集の聚合接口 测到《告白气球》），仅验证链路。
- **单平台验证**：多数"部分可用"源仅验证通酷我/QQ 单平台；缺 songmid 的 QQ/酷狗/咪咕链路未逐一补测。
- **时点性**：第三方个人源后端/域名/卡密随时变更；onrender 代理 2026-10-22 为 503 停用态，恢复后 Huibq 系及引用它的源可能可用；CF 免费层配额次日重置后 lerd 系可能可用。
- **混淆源**：10 条 jsjiami/VM 打包源无法静态提取端点，按可观测行为记录（无请求或宿主探测），未编造端点。
- **下载上限**：FLAC 类（多为翻唱）超 12 MB 截断未完整校验；MP3 320k 按口径不算无损。
- **网络时点抖动**：每端点最多 3 次尝试，个别同内容源两次探测出现判定差异（统一音乐源），按宽松解释取更可用的结论并在 §4 注明。
- **多曲目重测的局限（第二轮）**：①判定按"类A 3 首 + 类B 3 首"执行（类C 实测 0 首入选，见 §4.1，如需登录态/放宽标准可补一轮）；②类A 稻香在酷我系链命中为"稻香(DJ Ray版)"remix（ID3 实证），非原版，已标"(非原版)"；③独立复核（本报告集成时）：酷我 haitangw 链直链为短期签名+防盗链，需浏览器 UA/Referer 头，否则 403（复核时点已加头验证 12,551,167B 与记录一致）；cyapi（QQ m4a 3,837,239B）与 gdstudio（网易 mp3 10,452,158B）按请求签发新签名直链，复核字节与记录一致；④403/限流导致个别端点复核瞬时失败不改变测试时点结论。
- **未测歌词接口**：本任务聚焦音乐源；歌词接口结论见既有报告。

## 9 产物与复现

- 本报告：`C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\GitHub音乐源连通性测试报告.md`；首轮汇总图：同目录 `GitHub音乐源连通性测试-汇总图.html`；**重测汇总图：同目录 `GitHub音乐源多曲目重测-汇总图.html`**。
- 4 个分片明细（JSON 逐源记录 + Markdown 明细节）归档于 `C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\github_sources\_results\`：`pdone_lx-music-source_*`、`Huibq_keep-alive_*`、`guoyue2010_v2603family_*`、`guoyue2010_late_*`（已含 `multi_song_retest` 字段）。
- 重测产物（`_results\` 下）：`retest_shard1.json/.md`、`retest_shard2.json/.md`、`retest_summary.json`（废源/非废源总表）、`test_songs.json` 与《测试曲目清单与版权验证表.md》（6 首测试曲 × 4 平台版权字段与锚点证据）。
- 3 个仓库克隆位于 `github_sources\` 下：`pdone-lx-music-source`、`Huibq-keep-alive`、`guoyue2010-lxmusic`（git clone --depth 1）。
- 探测脚本（各分片代理 artifacts 内 probe_*.py / final_probe.py / lx_harness.js 等）与汇总脚本（aggregate_sources.py、verify_and_project.py、merge_retest.py、gen_sec4_tables.py 等）可复现全部结论。


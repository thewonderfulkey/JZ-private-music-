# 星澜聚合音源 StellarWave v4.0.2 · 解析与连通性实测报告

- 被测文件：`stellarwave音源（推荐）.js`（74,386 B / 1,643 行，署名"星澜团队"，MIT，标注更新时间 2026-11-06）
- 实测时间：2026-11-20 20:11–20:30（Australia/Adelaide）
- 测试机：Windows 工作机 `D:\Projects\Private_music`，Node v24.19.0 / Python 3.14
- 判定口径：**只用真实请求 + 真实字节**，不信接口自报的档位字段（与《JZ音乐助手-v2.1.65-30首实测报告》同口径）
- 复现：`tools/probes/stellarwave/`（`sw_decode.py` 解混淆、`sw_harness.js` 跑真脚本、`sw_summarize.py` 汇总）

---

## 结论先行

**不推荐整体融入。** 它解决的不是我们的问题，而且它自己有一半是坏的。

1. **它给不了"6 个渠道"**——LX 音源只有 `musicUrl` 一个动作（取流），**没有搜索、没有曲库、没有歌词、没有封面**。歌单和搜索结果仍由 LX 自带的服务给。所以它不能让我们"多出 6 个渠道"，只能给"我们已经认识的歌"多几条取流地址。
2. **实测 6 个平台只有 4 个活着**：QQ / 网易 / 酷我 / 酷狗 可用；**咪咕 0/4、汽水 0/2**。
3. **22 个「平台×档位」组合里，真正拿到能播的文件只有 14 个（64%）**，其中还混着两类坏结果：QQ 有一次回**加密 `.mgg`**（HTTP 200、11.2 MB、放不出声），另一次 flac 请求回的是 **320k mp3**（假无损）。
4. **它的货源和我们已有的高度重合**：活下来的只有 `yy.zddyr.top`、`musicserver.haitangw.cc`、`c.wwwweb.top`、`api.vkeys.cn`、`103.79.184.97` 这几个，正是本仓库 2026-10《GitHub音乐源连通性测试报告》已经普查过的同一批。**它没有带来新货源，只带来新的失败方式。**
5. **技术上不能"融"**：三端都没有 JS 引擎，嵌入等于自建一套 LX 插件运行时（沙箱 + 审核 + 崩溃面）。
6. **合规上不能"融"**：脚本里硬编码着别人的付费卡密（`6C1F-53W0-GRKI-EVFG` 等），还用 `_u()` 混淆故意藏凭据。上架审核一旦被翻，这是直接证据。

**唯一值得抄的能力**：**QQ 的真实 320k / FLAC**。这是我们目前最大短板（`cyapi QQ` 实测只有 97 kbps、3,283,546 B；落月给 320k、10,792,943 B，32 倍音质差）。但它只能当"机会性加分源"，不能当主线路——见 §5.3。

---

## 一、它是什么：LX「音源」= 取流器，不是曲库

脚本只向 LX 注册了 6 个 `musicUrl` 动作的源：

```
tx  QQ音乐     qualitys=128k/320k/flac/flac24bit/hires/atmos/atmos_plus/master
wy  网易云音乐  qualitys=128k/320k/flac          ← 未配 Cookie 被裁到 3 档
kw  酷我音乐   qualitys=128k/192k/320k/flac/flac24bit
kg  酷狗音乐   qualitys=128k/320k/flac/hires/atmos/master
mg  咪咕音乐   qualitys=128k/320k/flac/flac24bit/hires/atmos/master
qs  汽水音乐   qualitys=128k/320k/flac/spatial/hires
```

`send(inited)` 的原样输出（仿真器中实测抓到的，不是注释里抄的）。注意 `actions` 里**只有 `musicUrl`**——没有 `search`、`lyric`、`pic`。这是理解全文的前提：**它是"把 LX 已知的 songmid 换成一个能播的 URL"的那前半段，不是"能找到歌"的那后半段。**

对我们的意义：

| 我们的能力 | 脚本能替代吗 |
|---|---|
| 搜索（`SearchAdapters`：官方 / gdstudio / meting / 酷我 r.s） | ❌ 完全没有 |
| 歌单、榜单、艺人、最新单曲 | ❌ 完全没有 |
| 歌词（`lrc-api` / LDDC） | ❌ 完全没有 |
| 封面 | ❌ 完全没有 |
| **取流地址（`SourceAdapters`）** | ✅ 这是它唯一的领域 |

所以"融进我们的音乐软件"这个说法，实际只能落到"替换/扩充 `SourceAdapters` 里那几个 HTTP 适配器"，而不是"接一个 6 平台音乐源"。

---

## 二、结构解析

### 2.1 6 平台 / 53 个后端 / 30 个 host

| 平台 | 后端池大小 | 其中实测活着的 |
|---|---|---|
| QQ (tx) | **13** | 3（落月 / baimusic / HYW） |
| 网易云 (wy) | 9 | 2（ikun / 网易官方·无 Cookie 时只给试听） |
| 酷我 (kw) | **11** | 2（星海 / ikun） |
| 酷狗 (kg) | **11** | 1（星海KG，且排在第 6 位） |
| 咪咕 (mg) | 7 | 0 |
| 汽水 (qs) | 2 | 0 |
| 合计 | **53** | **8** |

调用策略（`resolveFromBackends`）：**前 3 个后端 `Promise.any` 并发，第 4 个起顺序兜底**。实测含义很重要——**尾部那 10 个后端在本次 18 次取流里几乎从未执行**，因为前三名里总有一家先回。它们既没被验证，也不构成有效冗余；真正起作用的冗余度只有 3。

### 2.2 混淆层与端点清单

全文所有第三方域名都套了一层"每字符 +5"的位移混淆：

```js
const _u = (str) => str.split('').map(c => String.fromCharCode(c.charCodeAt(0) + 5)).join('');
_u('cookn5**')          // → "https://"
_u('\\kd)sdibc\\d)^jh*') // → "api.xinghai.com"
```

`sw_decode.py` 解出 **53 处 `_u()` 字面量**，另加 17 处明文 URL，归并出 30 个 host。混淆不是为了压缩（文件反而变大），是为了**让凭据和上游不易被看到**。完整清单见 `tools/probes/stellarwave/inventory.json`；关键 12 个：

| host | 用途 | 备注 |
|---|---|---|
| `api.vkeys.cn` | 落月 QQ（v2 `geturl` / v3 `song/link`） | 脚本自称"主线路" |
| `musicserver.haitangw.cc`、`qt.haitangw.net` | 云记（海堂）`resolve-url` | 脚本自称"备用主线路" |
| `yy.zddyr.top` | 星海主后端 / 星海KG / 星海酷我 / 汽水 / 酷我 flac 跳板 | **唯一真正扛住全场的** |
| `c.wwwweb.top` | ikun 网易云、HelloWorld KW 备用API | 一个个人机 |
| `103.79.184.97` | HYWmusic 全平台、白姬KG、咪咕 proxy | 裸 IP + 卡密 |
| `106.55.0.102` | baimusic QQ（自实现 AES + RC4） | 裸 IP + 明文 http |
| `api.xinghai.com` | 星海"聚合通用"（酷我/酷狗/咪咕） | **DNS 通但永远超时** |
| `a.aa.cab` | HelloWorld QQ | TCP 直接 RST |
| `api.317ak.cn` | 317ak QQ | 靠一个共享 `ckey` |
| `api.cenguigui.cn` | 笒鬼鬼 网易 | Cloudflare 521 |
| `ffapi.cn` | FFAPI 全平台末位兜底 | 拒绝连接 |
| `175.27.166.236:8928` | 酷我流媒体（atmos/master 唯一通道） | TLS 握手失败 |

### 2.3 硬编码的第三方凭据（合规风险集中点）

| 常量 | 值 | 状态 |
|---|---|---|
| `HYW_CARD_KEY` | `6C1F-53W0-GRKI-EVFG` | **别人的付费卡密**，注释写"卡密同步更新" |
| 317ak `ckey` | `ZK76QJCIH5PPICJOOXUH` | 藏在 `_u()` 里，共享 key |
| 残像 `token` | `canxiang_token_2026` | 明文硬编码 |
| 云哥 `key`/`token` | `yunmge_key` / `yunmge_token` | **占位符，从来没通过** |
| `HELLO_WORLD_SECRET_KEY` | `JaJ?a7Nwk_Fgj?2o:znAkst` | **声明了但全文未使用**（死代码泄漏） |

最后一行尤其说明质量：一个自称 MIT 的"团队"版本，把一个密钥常量留在文件里却从不调用。脚本里出现一次的函数还有 `HELLO_WORLD_SCRIPT_MD5`，同样从未使用。

### 2.4 缓存 / 限流 / 超时

- URL 缓存 **20 分钟**（`CACHE_TTL`）、最多 500 条、同 key 并发合并（`INFLIGHT`）。
- 全局滑动窗口 **3 次/秒**，最多等 1.5 s，超了直接抛"请求过于频繁"。
- 所有请求 8–15 s 超时，body 统一 JSON 序列化。

这三条是它写得好的地方（我们 `URLResolver` 的 `quickPick`/预算思路同源）。但 **3 次/秒对我们不够**：我们播放页有"同曲换源 + 预取下一首"，一次切歌就要 3–5 个候选，这里的窗口会直接卡住。

### 2.5 与我们的 ID 体系对照

| 平台 | LX `musicInfo` 字段 | 我们的 `Song.platformID` | 是否直接可对 |
|---|---|---|---|
| QQ | `songmid` | `songmid`（如 `0039MnYb0qxYhV`） | ✅ |
| 网易 | `songmid`（即 songid） | `songid`（如 `32507038`） | ✅ |
| 酷我 | `rid` / `musicrid` | `rid`（去 `MUSIC_` 前缀） | ✅ |
| 酷狗 | `hash` + `albumId` | `hash` | ⚠️ 还缺 `albumId`（酷狗官方链要用） |
| 咪咕 | `copyrightId` / `musicId` | **无此平台** | ❌ |
| 汽水 | `songmid` | **无此平台** | ❌ |

前 4 个能直接对上，这是它对我们唯一"接口形状吻合"的地方。但 `MusicPlatform` 枚举只有 `KUWO/QQ/NETEASE/KUGOU`——后两个平台不是"再接一个后端"，而是要新做搜索、歌单、歌词、封面、下载一整条链。

---

## 三、连通性实测

### 3.1 方法

没有"照着脚本重写一遍"（有一堆池子、`Promise.any`、混淆和拼接 bug，重写必然走样）。做法是**把真脚本跑在 Node 里，只仿 LX 的 `request` / `utils.crypto` / `utils.buffer`**：

- 用 `vm` 造一个沙箱，注入 `globalThis.lx`，`currentScriptInfo.rawScript` 传原文（脚本靠它读 `@tx_cookie`；两者均未配置，等于干净游客态）。
- 每次取流**新建上下文 = 无 URL 缓存**，测的是冷启动真实表现。
- 节流：全局 3 次/秒 + 同 host 间隔 ≥1 s（比脚本更保守，避免把免费后端打挂）。
- 拿到 URL 后**必须验证是真音频**：Range GET 前 8 KB → 认容器魔数 + 取总长算真实码率；**并且跟 302**（星海系给的不是 CDN 直链而是自己的跳板，不跟就会误判"不可播"，第一轮我就踩了这个坑）。
- **归因说明**：`Promise.any` 前三并发，胜出的那一瞬间落败分支可能还没回。所以"这次是哪一家给的"存在歧义；本报告能钉死的是**哪些 host 回了、回了什么字节**，以及失败时脚本自己抛的全池错误清单（那份是权威的）。
- 测试曲用两组，避免"只对这一首歌成立"：

| 组 | QQ mid | 网易 id | 酷我 rid | 酷狗 hash | 咪咕 copyrightId | 版权 |
|---|---|---|---|---|---|---|
| ① 晴天/周杰伦 | `0039MnYb0qxYhV` | `32507038`(演员) | `228908` | `1B56126A…5CBC` | `60054701923` | QQ/酷狗 VIP，酷我免费 |
| ② 大鱼/周深 | `004OQ5Mt0EmEzv` | `516823132` | `7095195` | `BCEC0087…5323` | `64380800312` | 全平台 VIP（pay_type=3） |

### 3.2 端点健康（合并 4 轮取流的每次真实 HTTP 往返）

| 判定 | 成功率 | 次数 | 中位 | 最慢 | host | 失败码 |
|---|---|---|---|---|---|---|
| 通 | 100% | 13 | 738 ms | 1337 ms | `yy.zddyr.top` | — |
| 通 | 100% | 10 | 1005 ms | 2124 ms | `musicserver.haitangw.cc` | — |
| 通 | 100% | 8 | **160 ms** | 462 ms | `api.vkeys.cn` | — |
| 通 | 100% | 8 | 613 ms | 1619 ms | `music.migu.cn` | — |
| 通 | 100% | 6 | 1000 ms | 2961 ms | `qt.haitangw.net` | — |
| 通 | 100% | 6 | 1400 ms | 2188 ms | `c.wwwweb.top` | — |
| 通 | 100% | 4 | 1520 ms | 1632 ms | `interface3.music.163.com` | — |
| 通 | 100% | 4 | 607 ms | 612 ms | `app.c.nf.migu.cn` | — |
| **不稳** | **14%** | 14 | 3196 ms | 10005 ms | `103.79.184.97` | HTTP 500×9、超时×1 |
| 半通 | 0% | 4 | 199 ms | 225 ms | `api.cenguigui.cn` | Cloudflare 521×4 |
| 半通 | 0% | 2 | 8218 ms | 8417 ms | `api.xinghai.com` | 超时×2 |
| 半通 | 0% | 2 | 1043 ms | 1233 ms | `zrcdy.dpdns.org` | HTTP 500×2 |

host 级首轮探测（30 个 host）：**21 个可达、9 个硬失败**。9 个里除 `www.kuwo.cn`（只是 FFAPI 的入参页面）外，其余全是脚本仍在依赖的取流后端：

`api.ygking.cn` DNS 不存在 · `ffapi.cn` 拒绝连接 · `a.aa.cab` TCP RST · `api.xinghai.com` 永远超时 · `api.canxiang.cn` 超时 · `api.cenguigui.cn` 521 · `mcp.nianxinxz.com` 520 · `175.27.166.236:8928` TLS 握手失败

### 3.3 六个平台的真实结果（两首歌 × 两档，真字节校验）

**① 晴天/周杰伦**

| 平台 | 档位 | 耗时 | 实得 | 判定 |
|---|---|---|---|---|
| QQ | 320k | 1158 ms | mp3 **10,792,943 B**（=320 kbps） | ✅ |
| QQ | flac | 1092 ms | **mp3 10,792,943 B** ← 请求 flac 回了 320k | ⚠️ 假无损 |
| 网易 | 320k | 1136 ms | mp3 10,452,158 B | ✅ |
| 网易 | flac | 1288 ms | flac 48,621,867 B | ✅ |
| 酷我 | 320k | 926 ms | mp3 10,792,943 B | ✅ |
| 酷我 | flac | 852 ms | flac 55,397,039 B | ✅ |
| 酷狗 | 320k | 3917 ms | mp3 10,792,943 B | ✅ |
| 酷狗 | flac | 3123 ms | flac 31,633,244 B | ✅ |
| 咪咕 | 320k | 4400 ms | URL 是 HYW proxy，**8 s 超时取不到字节** | ⚠️ 不可播 |
| 咪咕 | flac | 19358 ms | 7 个后端全败 | ❌ |
| 汽水 | 320k | 1601 ms | 2 个后端全败 | ❌ |

**② 大鱼/周深（全平台 VIP）**

| 平台 | 档位 | 耗时 | 实得 | 判定 |
|---|---|---|---|---|
| QQ | 320k | 3172 ms | **`.mgg` 加密包 11,698,595 B**，任意偏移都无容器头 | ⚠️ 放不出声 |
| QQ | flac | 1157 ms | flac 31,314,747 B | ✅ |
| 网易 | 320k | 3243 ms | mp3 12,707,048 B | ✅ |
| 网易 | flac | 1893 ms | flac 30,885,652 B | ✅ |
| 酷我 | 320k | 1085 ms | mp3 12,551,167 B | ✅ |
| 酷我 | flac | 978 ms | flac 31,314,747 B | ✅ |
| 酷狗 | 320k | 5446 ms | mp3 12,551,167 B | ✅ |
| 酷狗 | flac | 3846 ms | flac 31,314,747 B | ✅ |
| 咪咕 | 320k | 4343 ms | proxy 回 **502** | ❌ |
| 咪咕 | flac | 11413 ms | 7 个后端全败 | ❌ |
| 汽水 | 320k | 1434 ms | 2 个后端全败 | ❌ |

**汇总：11 个组合 × 2 首 = 22，真能播 14 个（64%）。按平台：网易 4/4、酷我 4/4、酷狗 4/4、QQ 2/4（另 2 次是假无损和加密包）、咪咕 0/4、汽水 0/2。**

### 3.4 稳定性（每档位冷启动 3 次，无缓存）

| 平台 | 320k | flac |
|---|---|---|
| QQ | 3/3（1157/1160/1172 ms） | 3/3（1172/1165/1161 ms） |
| 网易 | 3/3（1624/1143/2157 ms） | 3/3（808/1649/780 ms） |
| 酷我 | 3/3（734/398/395 ms） | 3/3（388/396/400 ms） |
| 酷狗 | 3/3（3069/2734/2167 ms） | **3/3（10998/2103/1996 ms）** |
| 咪咕 | 3/3「有 URL」但都取不到字节 | **0/3** |
| 汽水 | **0/3** | — |

**能播的 4 个平台，24/24 次冷启动全部命中，成功率 100%。** 抖动主要在酷狗（2.1–11.0 s）和酷我（0.39–0.73 s，很好）。

结论要说准确：**"取到 URL"很稳，"取到能播的文件"不稳**——QQ 那两次坏结果（`.mgg`、假无损）在 3/3 的稳定统计里都被记成了"命中"。

### 3.5 延迟

- 能播的 4 个平台：**0.39 s ～ 11.5 s**，中位约 1.2 s。酷狗最慢，因为它要等前 5 个后端全挂（含两个 500 和一个 10 s 超时）才落到星海KG。
- **咪咕失败要 11–38 秒**——7 个后端逐个超时。用户在这段时间里看到的是"转圈"。
- 酷我 flac 走跳板时，首字节额外多 **1.5–2 s**（跳板 2.4 s vs 直连 0.35 s）。

---

## 四、六个硬伤（都有实测字节支撑）

### 4.1 请求 flac，回 320k mp3（假无损）

QQ 晴天要 `flac`，脚本回 `mp3 10,792,943 B`。同一轮里落月两个线路先 404/空、云记被版本门禁挡掉，最后一个 200 是 `103.79.184.97`（HYWmusic），时间点与结果吻合——**上游对"要 flac"这件事直接降级成了 320k，而脚本把 URL 原样当成 flac 交出去**。

脚本自身还有一处同源的隐患：`HYW_QUALITY_MAP` 把 `hires/atmos/atmos_plus/master` 一律压成 `flac24bit`（QQ、酷狗、网易都是），也就是它自己就在"降级请求、按原档位宣称"。我们 `StreamVerifier` + `QualityFacts` 正是为这个场景写的——这条链路不补校验，UI 就会写"无损"而下到 320k。

### 4.2 回 `.mgg` 加密包（HTTP 200、11.2 MB、放不出声）

QQ 大鱼 320k 回的是：

```
http://wx.music.tc.qq.com/O8M0003ae8GI3mQimV.mgg?guid=yibaihotapi&vkey=…
```

`O8M` 前缀 = QQ 音乐加密 OGG（MGG）。取头部 64 B：`7d552627354e47357456334139519014f1…`，偏移 100000 处同样是随机字节——**任何第三方播放器都解不开**。这是最阴的一类失败：`isHttpUrl()` 通过、Content-Range 正常、体积不小、播放器拿到手才炸。

> 我们已有的护栏能拦住它（`StreamVerifier.sniffHead` 认不出容器 → 判 0 字节/unknown），但 `SourceAdapters` 里目前没有"见到 `.mgg`/`.O8M` 直接拒"的显式规则，移植前要先加。

### 4.3 咪咕、汽水结构性死亡

咪咕 flac 的完整失败清单（脚本自己抛的，不是我的推测）：

```
云记咪咕(海堂): 当前版本已停止服务，请升级到最新版本后重试
星海主后端: 取流失败
Migu直接源: 无数据
Migu API: 无数据
HYWmusic MG: 鉴权失败 / 请求超时 10000ms
星海咪咕: 请求超时 8000ms
FFAPI: 返回无效URL
```

我直接打云记的 `resolve-url` 复核（tx 平台、exhigh 与 lossless 都试）：

```json
{"code":"APP_UPGRADE_REQUIRED",
 "message":"当前版本已停止服务，请升级到最新版本后重试",
 "reason":"sign:missing ticket:missing"}
```

**即 v4.1 的"云记（海堂）主线路"对所有平台都已被版本门禁关掉**，不只是咪咕。v4.0.1/v4.0.2 更新日志把"云记 resolve-url 为主线路"当卖点，这条卖点现在不成立。

汽水：主线路 `上游请求失败（HTTP 500 - upstream HTTP 500）`，备用 `接口无数据`——两条都坏。**说明**：汽水没有公开曲库可以取到 songmid，我用的是占位 id，所以严格说"汽水未验证"；但两条线路在上游层面就报错（不是回空结果），与 id 无关。

### 4.4 "6 个渠道"其实共用同一批文件

字节完全一致（同一首歌、同一档位）：

| 歌 | 档位 | 字节数 | 出现在 |
|---|---|---|---|
| 晴天 | 320k | 10,792,943 | QQ / 酷我 / 酷狗 **三家完全相同** |
| 晴天 | flac | 55,397,039 | QQ / 酷我 相同 |
| 大鱼 | 320k | 12,551,167 | 酷我 / 酷狗 相同（网易 12,707,048 不同） |
| 大鱼 | flac | 31,314,747 | QQ / 酷我 / 酷狗 **三家完全相同**（网易 30,885,652 不同） |

三个"不同平台"给的是同一个文件。**这意味着它们不是三份独立供给，而是三个不同的坏法**：同一份文件可以今天从酷狗拿到、明天酷狗挂了从酷我拿到——冗余是真的；但"6 个渠道"不等于 6 倍覆盖，也不等于 6 倍稳定。

### 4.5 主线路"落月"已被风控

脚本自称 QQ 主线路是落月（`api.vkeys.cn`）。我直接打它：

```
v2 /v2/music/tencent/geturl?quality=8 → {"code":503,"message":"系统运行错误！"}
v3 /music/tencent/song/link?quality=8 → {"code":110001,"message":"cookie异常：账号被风控无法获取"}
```

它在 8 次调用里 7 次回 200、中位 160 ms（确实是全场最快的），但**上游是共享账号，正在被风控**；有时 200 里也没有 URL（脚本靠兜底掩盖了这一点）。这种源只能当"机会性加分"，不能当主线路。

### 4.6 尾部后端是死重量

13 个 QQ 后端里，实测只有 3 个真正被调用到（落月、云记、HYW）；`baimusic` 只在头部全挂时才被用到（并且那次回了 `.mgg`）。其余 `317ak / 念心直链 / FishAPI / ygking / FFAPI / HelloWorld / 星海主后端` **在本次 18 次取流中一次都没成功过**。后端数量制造的是"看起来很稳"的错觉，不是真的韧性。

---

## 五、融不融

### 5.1 结论

**不整体融入。** 分三个层次给结论：

| 方案 | 结论 | 理由 |
|---|---|---|
| A. 把 `.js` 作为插件加载进 App | ❌ 否决 | 三端无 JS 引擎；等于自建 LX 运行时（沙箱、审核、崩溃面、审核风险）；且脚本行为已证明不可靠 |
| B. 按脚本逐平台重写一套 `SourceAdapters` | ❌ 否决 | 复刻 53 个后端里 45 个是坏的；咪咕/汽水是全新平台，光有取流没用 |
| C. **只移植实测活下来、且补我们短板的 1–2 条端点** | ✅ **建议** | 见 §5.3 |

### 5.2 为什么"直接嵌入"是最差选项

- **契约不匹配**：脚本假设 LX 提供 `search` 结果和 `musicInfo`（含 `songmid/license/hash/albumId/interval`）。我们得自己造这个"LX 上下文"，而这层上下文正是我们已有的一大半代码。
- **审计不透明**：全文域名经 `_u()` 混淆，凭据藏在混淆串里（`ckey=ZK76QJCIH5PPICJOOXUH` 就是这样藏的）。要做安全评审，就得先写个解混淆工具——本报告的工具链已经是这个成本了。
- **行为不可控**：`Promise.any` 前三并发 + 3 次/秒限流，与我们 `firstPlayable`（先到先用、≤320k 闸门、同曲换源）会互相打架；一次切歌要吃满限流窗口。
- **合规**：硬编码他人付费卡密 + 故意混淆凭据，一旦上架就是明证。我们现有后端（gdstudio / 妖狐 / 官方链）至少是"未授权聚合"，与"拿别人的付费 key 去调别人的付费网关"不是同一量级。

### 5.3 若要移植：优先级清单（附实测依据）

| 优先级 | 端点 | 平台/档位 | 实测 | 落地条件 |
|---|---|---|---|---|
| **P0** | `https://api.vkeys.cn/v2/music/tencent/geturl?mid=&quality=6/8/10` | QQ 320k / flac | 中位 **160 ms**，200 命中 7/8；320k=**10,792,943 B**、flac=**55,397,039 B** | 只能做**机会性加分源**（上游正被风控）；必须 `StreamVerifier` 校验档位；`quality` 映射 6/8/10/11/13/16/14 |
| P1 | `https://musicserver.haitangw.cc/v1/music/resolve-url`（`{source,rid,level}`） | 酷狗 flac | 酷狗 flac **31,633,244 B**，3/3 命中 | ⚠️ 该 host 今天对 tx/mg 一律回 `APP_UPGRADE_REQUIRED`，只有 `source=kg` 还通；**属同一家 haitangw，我们已在用它的酷我链，等于加单点风险** |
| P2 | `https://yy.zddyr.top/lx/api/?source=kg&mainHash=&quality=` | 酷狗 320k/flac | 13 次 100%、中位 738 ms | 我们已知的星海系；它现在是酷狗唯一活路，但**要等前 5 个后端全挂才轮到它**，得把它放前面 |
| P3 | `https://c.wwwweb.top/music/url`（`ikun` 格式） | 网易 / 酷我 | 6 次 100%、中位 1.4 s | 个人机，不建议进主链 |
| ❌ | `HYW`(103.79.184.97) / `baimusic`(106.55.0.102) / `ffapi.cn` / `a.aa.cab` / `317ak` / `api.xinghai.com` / `api.ygking.cn` / `api.canxiang.cn` / `api.cenguigui.cn` / `mcp.nianxinxz.com` / `api.yunmge.com` / `175.27.166.236` | — | 14% / 42% / 死 / 死 / 未测出 / 超时 / DNS 死 / 超时 / 521 / 520 / 占位密钥 / TLS 失败 | 全部不采纳 |

**净收益判断**：P0 把 QQ 从 97 kbps 提到真 320k（音质差 32 倍，文件 3,283,546 B → 10,792,943 B），这是唯一明显划算的一条。P1/P2 属于"我们已经有的同一批供货商，多一条入口"，收益是边际的。

> **P0 已落地（2026-11-20，iOS v2.4.36 / 214）**：新增 `LuoyueQQAdapter` + 在 `SourceRegistry.all` 注册一行，
> 断言在 `ios/SelfTest/main.swift` 的「落月 QQ 适配器」小节。没有整体引入脚本，也没有引入 JS 运行时。
> P1/P2 暂不做——理由见上：P1 那个 host 今天对 tx/mg 已经一律回 `APP_UPGRADE_REQUIRED`，
> P2 的酷我跳板每次 seek 都要多付 1.5–2 s 首字节。

### 5.4 移植前必须先补的两个护栏

1. **加密容器闸门**：见到 `.mgg` / `.m4a` 且首字节为 `\x00` 系、或 URL 含 `.mgg` / `O8M`/`O4M`/`O6M` 前缀 → 直接判不可用。现有 `StreamVerifier` 靠"认不出容器"间接拦得住，但那是运气好，不是规则。
2. **档位诚实闸门**：请求 `LOSSLESS` 却拿到 mp3/≤320 kbps，要**降级标注并记一次后端劣迹**，不能让 UI 写"无损"。现有 `QualityFacts.of(facts, durationSec:)` 已经能算真实码率，把它接到"拒绝+降级"上即可。

另外：脚本给的 URL 全是 **http**（`ws.stream.qqmusic.qq.com` / `m701.music.126.net` / `car-er.kuwo.cn` / `fsandroid.tx.kugou.com`）。我逐个验了 TLS：**8 个 CDN host 的 https 都正常**，`UrlNormalizer.upgraded` 这条既有做法继续有效。

---

## 六、复现方法

```powershell
cd D:\Projects\Private_music

# 1) 解混淆，导出端点清单（→ tools/probes/stellarwave/inventory.json）
python tools\probes\stellarwave\sw_decode.py -o tools\probes\stellarwave\inventory.json

# 2) 端点可达性（30 个 host，DNS/TLS/HTTP/延迟）
node tools\probes\stellarwave\sw_harness.js --phase hosts

# 3) 6 平台 × 档位 黑盒取流（跑真脚本，含真字节校验与 302 跟随）
node tools\probes\stellarwave\sw_harness.js --phase resolve --songs 1   # 晴天
node tools\probes\stellarwave\sw_harness.js --phase resolve --songs 2   # 大鱼(VIP)

# 4) 稳定性（每档位冷启动 N 次，无缓存）
node tools\probes\stellarwave\sw_harness.js --phase stability --repeat 3

# 5) 端点健康汇总（→ tools/probes/stellarwave/out/endpoint-health.json）
python tools\probes\stellarwave\sw_summarize.py
```

原始结果落 `tools/probes/stellarwave/out/*.json`。脚本路径可用环境变量 `SW_SRC` 覆盖。

### 文件清单

| 文件 | 作用 |
|---|---|
| `sw_decode.py` | 解 `_u()` 字符位移混淆，导出 host 清单 |
| `sw_harness.js` | FX 运行时仿真器 + 三阶段测试（hosts / resolve / stability） |
| `sw_summarize.py` | 线材日志 → 端点健康表 |
| `inventory.json` | 30 个 host 及其行号、样例 |
| `out/report-*.json`、`out/endpoint-health.json` | 原始实测数据 |

---

## 附：与我们现有后端的对比（同一首歌、同一档位）

| 平台 | 我们现在 | 本脚本最好结果 | 差 |
|---|---|---|---|
| QQ 320k | `cyapi` **3,283,546 B / ~97 kbps**（m4a，UI 已如实标"标准 128k"） | 落月 **10,792,943 B / 320 kbps** | **3.3×** 体积、真实 320k |
| QQ 无损 | 无 | 云记/落月 flac 55,397,039 B（**但不稳定**，也曾回 320k mp3） | 新增能力 |
| 网易 320k | `gdstudio` 10.83 MB（诚实分档） | `c.wwwweb.top` 10,452,158 B | 持平，无收益 |
| 酷我 320k | 官方 `anti.s`（~129 kbps）+ 妖狐（恒 FLAC） | 星海 10,792,943 B / 320 kbps | 有收益（我们缺真 320k） |
| 酷狗 320k/flac | 酷狗官方 `playInfo` | 星海KG 10,792,943 B / 31,633,244 B | 待比（未在本轮对照） |
| 咪咕 / 汽水 | 不支持 | 0 命中 | 无 |

> 一句话给老板：**这个文件不是"6 个渠道的音乐源"，是"6 个平台取流地址的兜底清单"，而这份清单今天有一半是坏的。真正值得从里面拿走的只有一件事——QQ 的真实 320k（我们现在只有 97 kbps）。这件事建议按 §5.3 的 P0 单独做一个适配器，加两个护栏，而不是把这个文件搬进 App。**

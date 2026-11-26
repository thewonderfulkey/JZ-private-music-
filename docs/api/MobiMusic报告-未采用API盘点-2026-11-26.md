# MobiMusic 报告里我们「没用、但有用」的 API（2026-11-26）

背景：酷我封面 API 已整条废掉（`wmvpic` 45/45 都是 324×182 横图，`rid_pic` 返回 NO_PIC），
封面链现在只剩 **自带图 → QQ 严格匹配 → iTunes**。而酷我来源的歌（首页热门/新歌/广场/歌单）
**一个自带图都没有**（`ksong.s` 和 `playListInfo` 的歌曲条目都不带图），等于只剩两条腿。

本文把报告里我们**还没采用**的接口逐个过一遍：能补哪个洞、成本多少、有没有前置条件。

---

## 一、封面（最直接的洞）

| 报告里的接口 | 我们的状态 | 能补什么 |
|---|---|---|
| 网易 `api/search/get` → `api/song/detail` 的 `album.picUrl` | ❌ 未用 | **网易封面腿**：按「歌名+歌手」搜一次 → 按 id 取详情 → 拿 `p2.music.126.net` 大图。华语命中率高 |
| 酷狗搜索的 `img` / `trans_param.union_cover` | ⚠️ 只在搜索时顺带取，没做「按歌名查封面」这条腿 | **酷狗封面腿**：复用现成的 `KugouSearchAdapter`，一次搜索就能拿 `union_cover?param=500y500` |
| QQ `y.gtimg.cn/.../T002R500x500M000{albummId}.jpg` | ✅ 已用（严格匹配那级） | — |
| iTunes `artworkUrl100 → 600x600bb` | ✅ 已用 | — |
| 酷我 `img1.kuwo.cn/wmvpic/` | ❌ 已废（横图/剧照） | 别再用 |
| 酷我 `artistpicserver rid_pic` | ❌ 已废（NO_PIC） | 别再用 |

**建议**：封面链补成 4 条腿，顺序
`自带图 → QQ严格 → 酷狗严格 → 网易严格 → iTunes`。
两条新腿都能复用现有搜索适配器，各一次请求，不需要新接口、不需要 key。
身份闸沿用 QQ 那套（歌名完全相等 + 歌手片段有交集），宁可没图也不贴错图。

---

## 二、歌词

| 接口 | 我们的状态 | 能补什么 |
|---|---|---|
| 网易 `api/song/lyric` | ✅ | — |
| QQ `fcg_query_lyric_new` | ✅ | — |
| 酷狗 `lyrics.search` + `download`（KRC 逐字） | ✅ | — |
| 酷我 `songinfoandlrc` | ✅ | — |
| **AMLL TTML 库**（`amll-dev/amll-ttml-db`） | ❌ 未用 | **逐字歌词第三条腿**。现在逐字只有酷狗 KRC + QQ QRC 两条，都在两家自家服务器；AMLL 是社区库，冷门歌/日语歌/新番覆盖互补 |

**成本与风险**：TTML 不是一个"查一下就有"的接口，要先有「歌 → 文件路径」的索引（仓库里是 JSON 清单），
再走 JSDeLivre/GitHub raw 取文件。国内访问 GitHub 系 CDN 经常慢或断。
**建议**：列为 P2，先做「索引命中率」探针（只查清单不发音频请求），命中率高再接入。

---

## 三、榜单 / 发现（单平台的老问题）

| 接口 | 我们的状态 | 能补什么 |
|---|---|---|
| 网易 `api/toplist`（65 个榜） | ❌ | 榜单第二腿（已实测 200） |
| 网易 `api/playlist/detail`（取歌 200 首） | ❌ | 榜单/歌单取歌的第二腿 |
| 网易 `api/homepage/block/page`（15 块） | ❌ | 发现页「推荐/新歌」的第二腿 |
| 网易 `api/playlist/list`（歌单列表） | ❌ | 歌单广场的第二腿 |
| 酷狗 `mobiles/api/v3/rank/list` + `rank/song` | ❌ | 榜单第三腿（已实测 200） |
| 酷我 `ksong.s` / `playListInfo` / `getRcmPlayList` | ✅ 现役 | 目前**全是它一家** |

**结论**：这一块是「单平台」的结构性风险，不是缺接口。三条候选腿都实测可用（见
`docs/api/线路基线实测-2026-11-26.md`），随时可接。

---

## 四、搜索联想（体验缺口，不是稳定性）

| 接口 | 我们的状态 | 能补什么 |
|---|---|---|
| QQ `smartbox_new.fcg` | ❌ | 搜索框输入时的联想词（实测 200、570ms） |
| 酷狗 `searchtip.kugou.com/getSearchTip` | ❌ | 联想词第二腿（实测 200） |

现在搜索框只有"历史记录"，没有联想。两条都是纯 GET、匿名、快。**建议 P2**。

---

## 五、评论（内容模块，先确认要不要做）

| 接口 | 我们的状态 | 能补什么 |
|---|---|---|
| 网易 `api/v1/resource/comments/R_SO_4_{songId}` | ❌ | 歌曲评论（含 hotComments，实测 200） |
| 网易 `api/v1/resource/hotcomments/...` | ❌ | 热门评论单独拉 |
| QQ `fcg_global_comment_h5.fcg` | ❌ | 评论第二腿 |
| 酷我 `ncomment.kuwo.cn/com.s` | ❌ | 评论第三腿 |

我们**完全没有评论模块**。这不是"稳"的问题，是产品功能缺口。
要先确认产品要不要（歌单/播放页放评论会明显增加页面复杂度）。**建议：先不做，等产品决定。**

---

## 六、其余模块（用不上 / 不该用）

| 接口 | 判断 |
|---|---|
| 网易 `weapi/*`、`eapi/*`（afp 加密） | 只有"填 cookie 才能用推荐"才需要；我们不做登录 → 不做 |
| 网易 `api/album/{id}` | 需 cookie（-462），匿名拿不到 → 不做 |
| 网易 `api/artist/*` | 实测 `artist/songs` 参数错误；艺人页已经有酷我 `artistInfo/artistMusic`（在用） |
| B站 `wbi/search/type`、`playurl` | 搜索匿名可通，但 `playurl` 要登录 + wbi，拿到的是视频音轨 → **不做** |
| ACRCloud `/v1/identify` | 识曲第三条腿，但要付费 key + HMAC-SHA1 → 除非愿意花钱，否则不做 |
| Audd `api.audd.io` | 要 api_token、免费额度低 → 不做 |
| Odesli `api.song.link` | 公开入口已废弃（401），我们有自己的 `SameSongCrossResolver` → 不做 |
| smartall.cloud 推荐 | 要 Bearer，401 → 不做 |
| `hk-api.gptbest.vip`（AI 代理） | TLS 被 reset，且我们没这需求 → 不做 |
| `mobi.likegamex.top`（自有后端） | 522 挂了；我们没有账号体系 → 不做 |
| 今日诗词 / loliapi 壁纸 | 纯装饰，与"稳/准"无关 → 不做 |

---

## 七、建议顺序

| 优先级 | 做什么 | 为什么 | 成本 |
|---|---|---|---|
| **P0** | 封面补两条腿：酷狗严格、网易严格 | 酷我来源的歌现在只有 QQ+iTunes 两条腿；这是最直接的洞 | 小（复用现成搜索适配器，各一次请求） |
| **P0** | 榜单/发现补网易 + 酷狗 | 四个页面共用酷我一家（已有实测数据支撑） | 中（解析 + 缓存 + 断言） |
| P2 | 搜索联想（QQ smartbox + 酷狗 searchtip） | 纯体验；两条都匿名可用 | 小 |
| P2 | AMLL TTML 逐字第三腿 | 先做索引命中率探针再决定 | 中 |
| 待定 | 评论模块 | 产品要不要先说清 | 大 |
| 不做 | B站 / ACRCloud / Audd / 自有后端 / AI 代理 | 见 §六 | — |

---

## 附：判断口径

- 「有用」= 能补一个**现有设计里的洞**（少一条腿、错一份数据、缺一层兜底），不是"多一个功能"。
- 封面和榜单是"洞"；评论和联想是"缺功能"；B站/ACRCloud 是"另一个方向"。
- 所有"要用"的接口都必须能**匿名**访问——我们不做登录（2026-11-26 拍板）。

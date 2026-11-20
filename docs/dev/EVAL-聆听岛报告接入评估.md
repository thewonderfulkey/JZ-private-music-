# 聆听岛（com.music.ltds 1.0.3）逆向报告 · 接入价值评估

> 评估对象：`聆听岛com.music.ltds-音乐API逆向与连通性报告.md`（2026-11-21）
> 评估方法：先读本项目 32 个历史会话（`tools/dev/session_digest.py`），再对本报告「净新增」的通道做本机实测（Range 2KB + 真实字节），不信接口自报。
> 探针：`tools/probes/probe_ltds_report_channels.py`（1–3 轮）+ `out/ltds_report_probe{,2,3}.json`
> 结论日期：2026-11-21 · 当前主线 v2.4.39 / 217（`34fcf43`）

---

## 0. 一句话结论

报告本身质量不错（全部标注实测/推断、给了探针代码），但它列的**大部分「最值钱的三件事」我们在 11-17 / 11-20 两轮就已经接完了**——酷我榜单、酷我新歌词端点、qijieya meting 搜索、wwwweb 酷我、zddyr 酷我、rid_pic 封面，都在线上跑。

真正**净新增**、且实测能补洞的只有三件事，外加一件可选的省时改造：

| # | 净新增 | 补的是什么洞 | 实测 | 建议 |
|---|---|---|---|---|
| 1 | **酷狗取流** `yy.zddyr.top/lx/api/?source=kg` | **酷狗曲现在没有原生取流**（官方 playInfo `errcode 1002` 不回 url），全靠跨平台补位 | 4 首 4/4，320k mp3 / flac 28.7MB，首字节 77–181ms | **P0，建议落** |
| 2 | **网易取流** `api.qijieya.cn/meting/?type=url`（同域已在搜索链用） | 网易只有 gdstudio 一条活后端（oiapi 已死） | 6 首 6/6，320k mp3，1.0–2.9s | **P0.5，建议落** |
| 3 | **酷狗歌词** `m.kugou.com/app/i/krc.php`（必须带 `timelength`） | 酷狗词只走 LDDC/KRC，蜂窝网下 KRC 曾整条不通 | 带参 2,615 B LRC；不带参 **200 + 0 字节** | **P1，建议落** |
| 4 | 酷我音质预检 `musicpay.kuwo.cn/music.pay`（MINFO） | 需要多花 1.2–1.9s，只省"anti.s 回 181KB 提示音"那一跳 | 3/3 `MusicPay_OK`，MINFO 全档位 | P2，可先不做 |

---

## 1. 报告逐项对照现状（避免重复劳动）

| 报告里的东西 | 项目现状 | 结论 |
|---|---|---|
| 酷我 `bang/list` + `ksong.s` 榜单 | 已接：`KuwoChart.swift`（含 `sourceid` vs web id 两级坑） | 已做，不重复 |
| 酷我 `lyric/getlyric` 新歌词端点 | 已接：`KwLyrics.swift`（`musicId` 纯数字 + 空 `data` 判空） | 已做 |
| 酷我 `getTagList` / `getTagPlayList` 歌单广场 | 已接：`KuwoPlaylist.swift` | 已做 |
| 酷我 `artistpicserver` / `rid_pic` 封面 | 已接：`CoverResolver.swift`（含坏地址拉黑） | 已做 |
| `qijieya meting` | 已接，但**只在搜索链**（`SearchAdapters.swift` ③ meting 搜索） | 取流那一半是新的 → 见 §0-2 |
| `c.wwwweb.top source=kw` | 已接：`IkunKuwoAdapter`（320k/flac，唯一能给周杰伦整首 320k 的通道） | 已做 |
| `yy.zddyr.top source=kw` | 已接：`XinghaiKuwoAdapter`（跳板，只给 FLAC） | 已做；`source=kg` 是新的 → §0-1 |
| 网易 `v6/playlist/detail` 要 `MUSIC_U` cookie | 我们实测：**Referer 即可，cookie 非必需**（`PlaylistImport.swift`） | 报告这条对我们不成立 |
| 网易 `v3/song/detail` 只认 form `c=[…]` | 我们用 `api/song/detail?ids=`，一直通 | 不需要改 |
| QQ `soso` 搜索 / `fcg_query_lyric_new` 歌词 | 已接（`QQSearchAdapter` / `LyricsService` ①b） | 已做 |
| 酷狗 `song_search_v2` | 已接（但用的是 `mobiles.kugou.com/api/v3/search/song`，同样给 hash） | 已做 |
| 酷狗 `v4/get_other_list_file` 签名 | 报告自己也没复现（20006/20010） | 不投入 |
| `haitangw` 三兄弟 / `nianxinxz` / `wwwweb source=kg` | 见 §3 丢弃清单 | 丢弃 |

---

## 2. 净新增通道的实测证据（本轮新跑）

### 2.1 酷狗取流：现在真的是空的

```
GET m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=B3A52A7A958BF0AED0EBFBA2E9A818B7
→ 200 / 1417ms / keys=[errcode, error, status] / has_url=false / errcode=1002
```
`KugouPlayInfoAdapter` 的注释写着「能搜不能播」，本轮复测仍然如此。酷狗曲的播放现在只能靠
`SameSongCrossResolver` 去别的平台按歌名找同曲——多一跳、慢、且酷狗独家曲会直接没源。

### 2.2 `zddyr source=kg` 档位谱（孤勇者 / 陈奕迅 / 256s）

| quality 参数 | code | Range | 体积 | 魔数 | 实测码率 |
|---|---|---|---|---|---|
| `128k` | 200 | 206 | 4,097,029 B | `ID3` | 128 kbps |
| `320k` | 200 | 206 | 10,242,283 B | `ID3` | 320 kbps |
| `flac` | 200 | 206 | 28,729,042 B | `fLaC` | 898 kbps |
| `master` | 200 | 206 | 108,494,040 B | `fLaC` | 3,390 kbps |

- 4 首不同歌（晴天 / 孤勇者 / 光年之外 / 夜曲）**全部 200 + 真音频**；报告里给的 `songmid=350839&albumId=555864` **不必填**，只给 `mainHash` 一样 200（三种参数变体回的是同一条链）。
- 跳转落在 `fsandroid.tx.kugou.com/…`，首字节 77–181ms，支持 mid-file Range（60s 处 `206 bytes 25427968-25430015/108494040`）。
- **直链寿命是硬约束**：probe1 生成的链约 20 分钟后复测 **403**。→ 不能落库缓存（现有架构本来就是每次播放现取，兼容）；下载长时间暂停后会 403，靠 `AudioPlayer` 已有的「失败重取一次」兜。
- `master` 108MB / 3.4Mbps **不进主链**：播放按 ≤320k 口径取 `320k`，无损取 `flac`（28.7MB），`master` 只在明确要"母带"时才考虑。

### 2.3 网易 `meting` 取流（6 首）

| 歌 | 状态 | 体积 | 魔数 | 码率 |
|---|---|---|---|---|
| 晴天(原唱 周杰伦) | 206 | 10,831,725 B | `ID3` | 321 kbps |
| 孤勇者 | 206 | 10,242,285 B | `ID3` | 320 kbps |
| 有何不可 | 206 | 9,675,799 B | `ID3` | 321 kbps |
| 罗刹海市 | 206 | 13,314,285 B | `ID3` | 321 kbps |
| 遇见 | 206 | 8,392,664 B | `ID3` | 321 kbps |
| 大鱼(唱片版) | 206 | 12,707,048 B | `ID3` | 321 kbps |

- 它**直接吐音频字节**（不是 JSON 链接），最终 302 落到 `m701.music.126.net`，支持 Range 与 mid-file seek。
- **坑（报告第 5 条只提了一半）**：不可用时它回 **HTTP 200 + `text/html` + 0 字节**（实测 id=186016）。所以必须校验 `Content-Type` + 魔数 + 体积三项，不能只看状态码——与我们 `StreamVerifier` 的口径一致。

### 2.4 酷狗歌词

```
GET m.kugou.com/app/i/krc.php?cmd=100&hash=…&timelength=269000  → 200 / 2,615 B / "[ti:晴天][ar:周杰伦][al:叶惠美]…"
GET m.kugou.com/app/i/krc.php?cmd=100&hash=…                    → 200 / 0 B
```
报告的坑属实（缺 `timelength` 就是 200 + 空）。给的是**行级 LRC**，比 LDDC 的 KRC 逐字差一档，所以定位是"LDDC 失败后的兜底"，不是替代。

### 2.5 酷我音质预检

```
GET musicpay.kuwo.cn/music.pay?op=query&action=play&ids=228908
→ 200 / 1268ms / errormsg=MusicPay_OK / MINFO="level:ff,bitrate:2000,format:flac,size:52.83Mb;level:p,bitrate:320,format:mp3,size:10.29Mb;…"
```
三首（晴天/七里香/大鱼）全 `MusicPay_OK`，MINFO 档位齐全。**但 1.2–1.9s 的额外请求**，只换来"事前知道有没有 flac / 会不会回提示音"——现有链路是"取不到再换源"，功能上不缺它。

---

## 3. 建议落地方案（等老板点头再动码）

### P0 · 新增 `XinghaiKugouAdapter`（酷狗原生取流）

- 位置：`SourceAdapters.swift`，形态照抄 `XinghaiKuwoAdapter`（同 host、同 JSON 契约 `{code,msg,url}`）。
- 档位映射：`.standard → 128k`、`.high → 320k`、`.lossless → flac`（**不用 master**）。
- 必带：`StreamEncryptionRules.isEncrypted` 闸、`StreamVerifier.inspect` 实测标注、`PlaybackQualityRules.isPlaceholder`、失败 ≤12s 快速返回、`BackendHealth` 冷却（它是共享账号，落月的 110001 风控就是前车之鉴）。
- 注册：`SourceRegistry.all` 加一行 → 自动成为酷狗并发成员；**回滚 = 删这一行**。
- 收益：酷狗曲从"跨界猜"变成"1 秒级直取 320k"，酷狗独家曲从"没源"变成"有源"。

### P0.5 · 网易补第三条取流（`Gdstudio`/`Oiapi` 之外）

- 新增 `MetingNeteaseAdapter`：请求 `api.qijieya.cn/meting/?server=netease&type=url&id=<neteaseId>`，
  **返回的就是可播 URL 本身**（直接把 meting 的 URL 当流地址，无需二次解析）。
- 闸门必须比别的严一格：`Content-Type` 要含 `audio` **且** 魔数是 mp3/m4a/flac **且** 总体积 > 1MB —— 否则会把上面那种 `200 + text/html` 当成功。
- 收益：gdstudio 限流/挂掉时网易曲不停摆；同一域名已在搜索链用，不是全新信任面。

### P1 · 酷狗歌词轻量兜底（`krc.php` + `timelength`）

- 插在 `LyricsService` ② LDDC 失败之后、③ LRCLIB 之前：`hash` 用 `song.platformID`，`timelength` 用 `durationSec * 1000`（时长未知就不发这条，因为缺参必回 0 字节）。
- 解析复用现有 LRC 解析（行级），`< 3 行` 视为无词。

### 不做（附理由）

| 项 | 理由 |
|---|---|
| 网易 `MUSIC_U` 内置 cookie | 那是**别人 App 的登录态**，会过期；内置他人凭证也有合规风险。我们实测 Referer 就够。 |
| `haitangw` 三兄弟 / `nianxinxz` | 服务端按 App 票据校验（`sign:missing ticket:missing`）/ 站点 520。复现不了，不投入。 |
| `wwwweb source=kg` | 报告当时回 171KB 试听；本轮实测直接 **404「接口不存在」**。 |
| QQ 播放（`musicu` vkey / `zddyr source=qq`） | vkey 需登录（104003），zddyr qq 需卡密（403）。与现状一致：QQ 仍只有 `cyapi`（+落月机会性）。 |
| 360mixup 远程配置 / `mobi.s` 加密 q | 与本项目无关 / 本机 407 且加密串是死的。 |
| 报告"五个坑"里的占位闸门、fingerprint 去重、Range 验真、冷却 | **我们早就有**：`PlaybackQualityRules.isPlaceholder`（181,521 B / `43fe5f64…`）、`fingerprint`、`StreamVerifier`（Range 0-2047）、`BackendHealth`。 |

---

## 4. 风险与代价

| 风险 | 说明 | 缓解 |
|---|---|---|
| 共享账号风控 | zddyr 的 kg 通道若与 kw 共用账号，被风控会一起挂 | 独立 `BackendHealth` 名 + 冷却；连续两轮真机失败就降到"机会性" |
| 直链 20 分钟过期 | 已实测 403 | 不落库、每次现取；下载失败重取一次（已有） |
| `master` 体积 | 108MB / 3.4Mbps | 只接 128k/320k/flac 三档，`master` 不映射 |
| meting 伪装 200 | `text/html` + 0 字节 | 三道校验（ctype / magic / 体积） |
| 新源绕过闸门 | 直接起播提示音 | 新适配器一律走 `PlaybackQualityRules.isPlayable` 全闸 |

**改动量**：1 个新适配器（≈45 行）+ 1 个新适配器（≈40 行）+ 注册 2 行 + 歌词 1 个函数（≈35 行）+ SelfTest 断言（档位映射 / meting 伪装 200 闸门 / krc 缺参判空）≈ 12 条。CI 四道门不变。

---

## 5. 待老板拍板的两件事

1. **落不落**：建议 `P0 + P0.5 + P1` 一起落（都是"加一行注册、删一行回滚"的形状），出 **v2.4.40 / 218** 一包。
2. **真机怎么验**：①搜「孤勇者」点酷狗那一条，看 1 秒内出声且音质标 320k；②搜「罗刹海市」点网易那一条，看不再卡"正在解析音源"；③找一首以前没词的酷狗歌，看歌词有没有了。

> 如果只想先试一条，我建议先落 **P0 酷狗取流**——它是唯一"现在完全没有"的东西，收益最直观，风险面也最小（单文件、单注册行）。

---

## 附录 · 2026-11-21 00:5x 追加：v2.4.39 的两个包**没有打进修复**（字节级证据）

老板 00:42 的录屏仍然出现占位提示音、周杰伦没恢复。查完不是"修错了"，是**包里的代码根本没变**：

| 证据 | 实测 |
|---|---|
| 群里三个 IPA 的主二进制 sha256 | r145(v2.4.38) = r146(34fcf43-r146) = r147(5841733-r147) = `35b718132347121c…`，**同一份 9,980,152 B 二进制** |
| `origin/main` 三个 commit 改了什么 | `34fcf43`、`5841733`、`f06f766` 对 `ios/` 的改动分别是 **空**、仅 `project.pbxproj` 版本号、空 |
| 包内(HEAD)有没有占位闸门 | `git show 34fcf43:…/PlaybackRules.swift` 里 **搜不到 `181` / `占位`** → 内容闸门不在包里 |
| 工作区 | 583 行未提交：占位内容闸门、加密包闸门、ikun/星海适配器、QQ 搜索兜底 —— 全都没进包 |

→ 所以 r146 与 r147 在行为上等于 v2.4.38；"还播占位"是必然，不是新 bug。
→ 流程漏洞：现有 `tools/ios/check_ipa_version.py` 只校验**版本号**，不校验**二进制有没有变**。建议出包闸加一条：包内二进制 sha256 必须 ≠ 上一版。

### 周杰伦实测矩阵（2026-11-21 00:5x，3 首：晴天 / 夜曲 / 稻香）

| 通道 | 结果 | 体积 / 码率 | 接口耗时 |
|---|---|---|---|
| 酷我 `anti.s`（现主链） | **3/3 占位提示音** | 181,521 B | 1.8–2.3 s |
| ikun `wwwweb source=kw`（320k / flac） | **3/3 真音频** | 8.9–10.8 MB / 26–55 MB | 0.9–4.2 s |
| 酷狗 `zddyr source=kg`（128k/320k/flac） | **3/3 真音频**（项目里目前没有这条） | 320k = 8.9–10.8 MB；flac = 26–31 MB | **0.82–1.02 s** |
| 落月 `vkeys`（QQ，quality=8） | **2/3**（夜曲撞 `110001 账号被风控`，重试即恢复） | 320k = 8.9–10.8 MB | 0.4–1.5 s |
| `cyapi`（QQ，现主链） | **0/3 无 url** —— 对杰威尔这批歌它给不出流 | — | 0.5 s |
| 网易 `gdstudio`（跨源补位） | 有文件，但**是翻唱**（10,831,725 B = 「晴天 (原唱 周杰伦) / RyaVocal」） | 320k | 0.5–0.8 s |
| QQ `soso` 搜索 | 4/4 成功，但 **1.5–2.0 s**（App 里 timeout=4 s，蜂窝下必误报"超时"） | — | — |

三条结论：
1. **周杰伦能拿到**，靠的是 ikun（酷我 rid）与酷狗 zddyr（kugou hash）——两者都是**精确 id**，不会错歌；
2. 网易那条是**翻唱**，正好证明"准确性第一"必须靠身份闸（歌手/时长），不能只看"能出声"；
3. QQ 真正能给杰威尔 320k 的是**落月 vkeys**，但它偶发风控 → 只能当机会性 + 重试一次，不能当主链。

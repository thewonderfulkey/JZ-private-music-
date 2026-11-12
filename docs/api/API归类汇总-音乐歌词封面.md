# API 归类汇总：音乐 / 歌词 / 封面（全部可用接口，含历史连通性测试结果）

> 数据来源：《GitHub音乐源连通性测试报告》（100 条音乐源多曲目重测，2026-10 实测）、《GitHub歌词封面API连通性测试报告》（2026-10-28 实测）、《接口归类清单-音乐与歌词.md》。判定口径：废源=测试曲全部无法返回；任一能返回即非废源。

## 一、音乐 API（33 条非废源，含可用 3 / 部分可用 28 / 重测转正 2）

按有效后端链路分组；同链路多版本（同一后端被多个源引用）已标注。测试曲：晴天/稻香/七里香（类A）+ 大鱼/演员/年少有为（类B VIP）。完整可下载 = 字节数==Content-Length 且时长吻合。

### 酷我直连

| # | 源名（记录） | 判定 | 端点 / 后端 | 实测命中 |
|---|---|---|---|---|
| 1 | 星海音乐源 | 可用 | 后端 https://yy.zddyr.top/lx/api/?source=kw&name=晴天&singer=周杰伦&songmid=228908&quality=320k ; GDAPI music-api.gdstudio.xyz/api.php?types=url&source=netease&id=&br=999 ; 本地酷我 mobi.kuwo.cn/mobi.s convert_url_with_sign ; ChKSz api.chksz.com(apike | 晴天: kuwo/full,kugou/full; 稻香: kugou/full; 七里香: kuwo/full,kugou/full; 大鱼: kuwo/full,kugou/full,netease/partial; 演员: kuwo/partial,kugou/full,netease/ful |
| 12 | KuwoDES | 可用 | https://mobi.kuwo.cn/mobi.s?f=web&source=kwplayercar_ar_6.0.0.9_B_jiakong_vh.apk&from=PC&type=convert_url_with_sign&surl=1&br=320kmp3&rid=<rid> ｜ params: query: rid=酷我曲目ID; br=320kmp3; 无签名 | 晴天: kuwo/full; 稻香: kuwo/full; 七里香: kuwo/full; 大鱼: kuwo/fragment; 演员: kuwo/partial |

### 酷我系·haitangw

| # | 源名（记录） | 判定 | 端点 / 后端 | 实测命中 |
|---|---|---|---|---|
| 0 | 全豆要[聚合音源] | 可用 | 多链回退: ①qsvip搜索 api.vsaa.cn/api/music.qishui.vip?act=search&keywords= ②星海主 music-api.gdstudio.xyz/api.php?types=url&source=&id=&br= ③溯音 oiapi.net/api/Kuwo?msg=&n=&br= ④长青SVIP musicapi.haitangw.net/music/kw.php?type=mp3&id=&level=exhigh ⑤念心SV | 晴天: kuwo/full; 稻香: kuwo/full; 七里香: kuwo/full; 大鱼: kuwo/full,netease/partial; 演员: kuwo/partial,netease/full; 年少有为: netease/full |
| 2 | 全豆要 | 部分可用 | http://music.nxinxz.com/kw.php?id=<rid>&level=exhigh&type=mp3 （回退kw链） ｜ params: 多链路自动回退：nxinxz kw / gdstudio netease / oiapi / vsaa汽水 / haitangw / 175.27.166.236 | 晴天: kuwo/full; 稻香: kuwo/full; 七里香: kuwo/full; 大鱼: kuwo/full; 演员: kuwo/partial |
| 3 | 全豆要 | 部分可用 | http://music.nxinxz.com/kw.php?id=<rid>&level=exhigh&type=mp3 （回退kw链） ｜ params: 多链路自动回退：nxinxz kw / gdstudio netease / oiapi / vsaa汽水 / haitangw / 175.27.166.236 | 晴天: kuwo/full; 稻香: kuwo/full; 七里香: kuwo/full; 大鱼: kuwo/full; 演员: kuwo/partial |
| 17 | 长青SVIP音源 | 部分可用 | https://musicapi.haitangw.net/music/kw.php?type=mp3&id=<rid>&level=exhigh （仅kw活） ｜ params: kw.php; tx 175.27.166.236/kgqq/qq.php 403; wy /wy.php 404; kg music.haitangw.cc/kgqq/kg.php 401 has not any level; mg /musicapi/mg.php 404 | 晴天: kuwo/full; 稻香: kuwo/full; 七里香: kuwo/full; 大鱼: kuwo/full; 演员: kuwo/partial |
| 21 | 👖裤佬SVIP音源 | 部分可用 | https://musicapi.haitangw.net/music/kw.php?type=mp3&id={rid}&level=exhigh (fallback); 主链混淆/175.27死 ｜ params: id=rid,level=exhigh,type=mp3 | 晴天: 酷我/full; 稻香: 酷我/full; 七里香: 酷我/full; 大鱼: 酷我/full; 演员: 酷我/partial |
| 27 | 非常刀 | 部分可用 | oiapi.net/api/Kuwo; gdstudio; chksz; xcvts; 175.27; nxinxz; haitangw ｜ params: msg,n,br; id,level | 晴天: 酷我/full; 稻香: 酷我/full; 七里香: 酷我/full; 演员: 酷我/full; 年少有为: 酷我/full |
| 30 | 音乐下载器 | 部分可用 | haitangw kw.php(fallback); 175.27.166.236(死); oiapi Kuwo(fallback) ｜ params: id,level,type=mp3 | 晴天: 酷我/full; 稻香: 酷我/full; 七里香: 酷我/full; 大鱼: 酷我/full; 演员: 酷我/partial |

### 酷我系·nxinxz

| # | 源名（记录） | 判定 | 端点 / 后端 | 实测命中 |
|---|---|---|---|---|
| 16 | 念心音源 | 部分可用 | http://music.nxinxz.com/kw.php?id=<rid>&level=exhigh&type=mp3 （仅kw活） ｜ params: kw.php?id=&level=exhigh&type=mp3; tx/wy/kg/mg 路径均404; gitee配置 wubian.json 403 invalid Referer | 晴天: kuwo/full; 稻香: kuwo/full; 七里香: kuwo/full; 大鱼: kuwo/full; 演员: kuwo/partial |

### 酷我系·oiapi

| # | 源名（记录） | 判定 | 端点 / 后端 | 实测命中 |
|---|---|---|---|---|
| 19 | 溯音音源 | 部分可用 | https://oiapi.net/api/Kuwo?msg=<kw>&n=1 （仅kw活）；/api/QQ_Music 403; /api/Music_163 /Kg 落地页; https://api.xcvts.cn/api/music/migu 502 ｜ params: Kuwo?msg=&n=1; QQ_Music; Music_163; xcvts migu?gm=&n=1&num=1&type=json | 晴天: kuwo/full; 稻香: kuwo/full; 七里香: kuwo/full; 大鱼: kuwo/full,netease/full; 演员: kuwo/partial,netease/full; 年少有为: netease/full |
| 24 | 溯音音源 | 部分可用 | https://oiapi.net/api/Kuwo?msg=晴天 周杰伦&n=1&br=2 ; /Music_163?id=; /QQ_Music; xcvts咪咕 ｜ params: msg,n,br; id | 晴天: kuwo/full; 稻香: kuwo/full; 七里香: kuwo/full; 大鱼: kuwo/full,netease/full; 演员: kuwo/partial,netease/full; 年少有为: netease/full |

### 酷我/网易系·zddyr

| # | 源名（记录） | 判定 | 端点 / 后端 | 实测命中 |
|---|---|---|---|---|
| 29 | 星海音乐源 | 部分可用 | https://yy.zddyr.top/lx/api/?source=kw&songmid={id}&quality=320k (primary); zrcdy备用; gdstudio; chksz vip ｜ params: source,songmid,quality,name | 晴天: 酷我/full; 七里香: 酷我/full; 大鱼: 酷我/full; 演员: 酷我/partial |

### QQ系·cyapi

| # | 源名（记录） | 判定 | 端点 / 后端 | 实测命中 |
|---|---|---|---|---|
| 18 | 收集の聚合接口(LX版) | 部分可用 | https://cyapi.top/API/qq_music.php?apikey=1ffdf5733f5d538760e63d7e46ba17438d9f7b9dfc18c51be1109386fd74c3a1&type=json&mid=<mid> ｜ params: apikey硬编码; type=json; mid=QQ曲目ID; wy api.cenguigui.cn 521; kw kw-api.cenguigui.cn SSL错/http空 | 晴天: QQ/full; 稻香: QQ/full; 七里香: QQ/full; 大鱼: QQ/full; 演员: QQ/full; 年少有为: QQ/full |
| 23 | 收集の聚合接口(LX版) | 部分可用 | https://cyapi.top/API/qq_music.php?apikey=...&type=json&mid={mid}; cenguigui; kw-api.cenguigui.cn ｜ params: apikey,type=json,mid | 晴天: QQ/full; 稻香: QQ/full; 七里香: QQ/full; 大鱼: QQ/full; 演员: QQ/full; 年少有为: QQ/full |
| 25 | 稳定版音源 v1.0.3 | 部分可用 | https://cyapi.top/API/qq_music.php; api.injahow.cn/meting/api/; cenguigui; kw-api.cenguigui ｜ params: apikey,mid; server,type,id,br | 晴天: QQ/full; 稻香: QQ/full; 七里香: QQ/full; 大鱼: QQ/full; 演员: QQ/full; 年少有为: QQ/full |
| 31 | 收集の聚合接口（落雪插件版） | 部分可用 | https://cyapi.top/API/qq_music.php?apikey=...&type=json&mid={mid}; cenguigui; kw-api.cenguigui ｜ params: apikey,type,json,mid | 晴天: QQ/full; 稻香: QQ/full; 七里香: QQ/full; 大鱼: QQ/full; 演员: QQ/full; 年少有为: QQ/full |

### QQ系·aa.cab

| # | 源名（记录） | 判定 | 端点 / 后端 | 实测命中 |
|---|---|---|---|---|
| 28 | 𝖧౿ᥣᥣ𝗈 Ԝ𝗈𝗋ᥣᑯ | 部分可用 | https://a.aa.cab/qq.music?msg={kw}&n=1&type={q}; https://c.wwwweb.top/music/url; yy.zddyr.top/lx/api/?source=migu ｜ params: msg,n,type; source,musicId,quality | 晴天: QQ/full; 稻香: QQ/full; 七里香: QQ/full; 大鱼: QQ/full; 演员: QQ/full; 年少有为: QQ/full |

### 网易系·gdstudio

| # | 源名（记录） | 判定 | 端点 / 后端 | 实测命中 |
|---|---|---|---|---|
| 4 | 全豆要[聚合音源] | 部分可用 | https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=<id>&br=320 （回退）；首链 kw-er.kuwo.cn 410 Gone；api.vsaa.cn 全路径404；oiapi QQ 403维护；music-dl.sayqz.com DNS失效 ｜ params: 多链路自动回退；首链 kw-er.kuwo.cn 直链410，回落 gdstudio netease 翻唱 | 大鱼: netease/partial; 演员: netease/full; 年少有为: netease/full |
| 5 | 全豆要[聚合音源] | 部分可用 | https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=<id>&br=320 （回退）；首链 kw-er.kuwo.cn 410 Gone；api.vsaa.cn 全路径404；oiapi QQ 403维护；music-dl.sayqz.com DNS失效 ｜ params: 多链路自动回退；首链 kw-er.kuwo.cn 直链410，回落 gdstudio netease 翻唱 | 大鱼: netease/partial; 演员: netease/full; 年少有为: netease/full |
| 6 | 全豆要[聚合音源] | 部分可用 | https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=<id>&br=320 （回退）；首链 kw-er.kuwo.cn 410 Gone；api.vsaa.cn 全路径404；oiapi QQ 403维护；music-dl.sayqz.com DNS失效 ｜ params: 多链路自动回退；首链 kw-er.kuwo.cn 直链410，回落 gdstudio netease 翻唱 | 大鱼: netease/partial; 演员: netease/full; 年少有为: netease/full |
| 7 | 全豆要[聚合音源] | 部分可用 | https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=<id>&br=320 （回退）；首链 kw-er.kuwo.cn 410 Gone；api.vsaa.cn 全路径404；oiapi QQ 403维护；music-dl.sayqz.com DNS失效 ｜ params: 多链路自动回退；首链 kw-er.kuwo.cn 直链410，回落 gdstudio netease 翻唱 | 大鱼: netease/partial; 演员: netease/full; 年少有为: netease/full |
| 8 | 全豆要[聚合音源] | 部分可用 | https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=<id>&br=320 （回退）；首链 kw-er.kuwo.cn 410 Gone；api.vsaa.cn 全路径404；oiapi QQ 403维护；music-dl.sayqz.com DNS失效 ｜ params: 多链路自动回退；首链 kw-er.kuwo.cn 直链410，回落 gdstudio netease 翻唱 | 大鱼: netease/partial; 演员: netease/full; 年少有为: netease/full |
| 9 | 全豆要[聚合音源] | 部分可用 | https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=<id>&br=320 （回退）；首链 kw-er.kuwo.cn 410 Gone；api.vsaa.cn 全路径404；oiapi QQ 403维护；music-dl.sayqz.com DNS失效 ｜ params: 多链路自动回退；首链 kw-er.kuwo.cn 直链410，回落 gdstudio netease 翻唱 | 大鱼: netease/partial; 演员: netease/full; 年少有为: netease/full |
| 10 | 全豆要[聚合音源] | 部分可用 | https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=<id>&br=320 （回退）；首链 kw-er.kuwo.cn 410 Gone；api.vsaa.cn 全路径404；oiapi QQ 403维护；music-dl.sayqz.com DNS失效 ｜ params: 多链路自动回退；首链 kw-er.kuwo.cn 直链410，回落 gdstudio netease 翻唱 | 大鱼: netease/partial; 演员: netease/full; 年少有为: netease/full |
| 13 | 星海音乐源 | 部分可用 | https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=<netease｜kuwo｜qq｜kugou｜migu>&id=<id>&br=<128｜192｜320｜740｜999> ｜ params: source平台; id曲目; br音质 | 大鱼: 网易云/partial; 演员: 网易云/full; 年少有为: 网易云/full |
| 14 | 统一音乐源 | 部分可用 | https://music-api.gdstudio.xyz/api.php?types=url&source=<kuwo｜netease>&id=<id>&br= ｜ params: source; id; br | 大鱼: 网易云/partial; 演员: 网易云/full; 年少有为: 网易云/full |
| 15 | 全豆要[聚合音源] | 部分可用 | https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=<id>&br=320 （回退）；首链 kw-er.kuwo.cn 410 Gone；api.vsaa.cn 全路径404；oiapi QQ 403维护；music-dl.sayqz.com DNS失效 ｜ params: 多链路自动回退；首链 kw-er.kuwo.cn 直链410，回落 gdstudio netease 翻唱 | 大鱼: netease/partial; 演员: netease/full; 年少有为: netease/full |
| 20 | 星海音乐源 | 部分可用 | https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest&...&types=url&source=netease&id=<id>&br= ｜ params: 主链gdstudio；备用 https://music-dl.sayqz.com/api/ (DNS失效) | 大鱼: 网易云/partial; 演员: 网易云/full; 年少有为: 网易云/full |
| 22 | gdstudio音乐源 | 部分可用 | https://music-api.gdstudio.xyz/api.php?types=search｜url&source=netease&id={id}&br=320 ｜ params: types=url,source=netease,id=186016,br=320 | 大鱼: 网易云/partial; 演员: 网易云/full; 年少有为: 网易云/full |
| 26 | 统一音乐源 | 不可用 | https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id={id} ｜ params: types=url,source,id,br | 大鱼: 网易云/partial; 演员: 网易云/full; 年少有为: 网易云/full |
| 32 | 星海音乐源 | 不可用 | gdstudio api.php; music-dl.sayqz.com/api/; zrcdy.dpdns.org/lx/api/ ｜ params: source,id,type=url,br | 大鱼: 网易云/partial; 演员: 网易云/full; 年少有为: 网易云/full |

### 网易系·s0o1

| # | 源名（记录） | 判定 | 端点 / 后端 | 实测命中 |
|---|---|---|---|---|
| 11 | Ciallo～(∠・ω< )⌒☆ | 部分可用 | https://api.s0o1.com/API/wyy_music?msg=<kw>&sm=10 （搜索）；取链 ?id=<id>&yz=<1..7> ｜ params: msg=搜索词; id=网易曲目ID; yz=音质档1-7 | 大鱼: 网易云/partial; 演员: 网易云/partial; 年少有为: 网易云/partial |

## 二、歌词 API（3 可用 + 2 部分可用）

| 源 | 判定 | 端点模板 | 实测命中 |
|---|---|---|---|
| LrcApi (本地自部署) | 可用 | `http://127.0.0.1:28883/lyrics?title={title}&artist={artist}` | 晴天=full, 七里香=full, 稻香=full |
| LrcApi 公开实例 (api.lrc.cx) | 可用 | `https://api.lrc.cx/lyrics?title={title}&artist={artist}` | 晴天=full, 七里香=full, 稻香=full |
| LDDC 歌词搜索 (本地自部署) | 部分可用 | `http://127.0.0.1:8000/lyrics?title={title}&artist={artist}&source={lrclib|ne|qm|kg}` | 晴天=full, 七里香=full, 稻香=full |
| LRCLIB (lrclib.net 开源社区歌词库) | 部分可用 | `https://lrclib.net/api/get?track_name={title}&artist_name={artist}&album_name=` | 晴天=partial, 七里香=partial, 稻香=source_fail |
| 网易云官方直连 (api.music.163.com) | 可用 | `https://api.music.163.com/api/song/lyric?id={id}&lv=-1&kv=-1&tv=-1` | 大鱼=full, 演员=full, 年少有为=full |

## 三、封面 API（3 可用 + 2 部分可用）

| 源 | 判定 | 端点模板 | 实测命中 |
|---|---|---|---|
| LrcApi /cover | 可用 | `GET {base}/cover?title={title}&artist={artist}[&album={album}]  -> 直接返回 image/jpeg（302/内容直出）` | 晴天=ok, 七里香=ok, 稻香=ok, 备份曲(大鱼/演员/年少有为)=ok |
| QQ音乐官方 songinfo | 可用 | `GET https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?songmid=<mid>&format=json  -> album.mid；再拼 https://y.gtimg.cn/music/photo_new/T002R300x300M000<album_mid>.jpg` | 晴天=ok, 七里香=ok, 稻香=ok |
| 酷狗官方 getSongInfo | 可用 | `GET https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=<hash>  -> img 字段（含 {size} 占位，需替换为 480）` | 晴天=ok, 七里香=ok, 稻香=ok |
| iTunes Search API (Apple) | 部分可用 | `GET https://itunes.apple.com/search?term=<urlenc 歌名+歌手>&media=music&entity=song&limit=1  -> results[0].artworkUrl100（可把 100x100 换 300x300 升级）` | 晴天=miss, 七里香=miss, 稻香=wrong, 备份曲(大鱼/演员/年少有为)=ok |
| Cover Art Archive (MusicBrainz) | 部分可用 | `两步：1) GET https://musicbrainz.org/ws/2/release-group/?query=release:<曲>%20AND%20artist:<歌手>&fmt=json (需UA) 取 mbid；2) GET https://coverartarchive.org/release-group/<mbid>/front-500.jpg` | 晴天=miss, 七里香=fail, 稻香=wrong, 备份曲(大鱼)=netfail, 备份曲(演员)=miss, 备份曲(年少有为)=fail |

## 四、App 集成配对（音乐源 ↔ 歌词/封面）

| 平台 | 音乐源标识 | 歌词接口 | 封面接口 |
|---|---|---|---|
| 酷我 | `rid` | LrcApi（title+artist 兜底） | LrcApi /cover（兜底）；酷我官方 songinfo 已废 |
| QQ | `songmid` | LrcApi / LDDC qm（官方 lyric.fcg 已下线） | QQ songinfo → y.gtimg.cn（主推） |
| 网易云 | `id` | 网易云官方 /api/song/lyric（主推） | 网易云 /api/song/detail al.picUrl（偶发风控，备选） |
| 酷狗 | `hash` | LDDC kg（239-309ms，主推）；酷狗官方反爬 | 酷狗 getSongInfo（{size}→480，主推） |

> 回退链建议：歌词 LrcApi(公开) → LDDC kg；封面 QQ/酷狗直连 → LrcApi /cover。LrcApi 一个项目同时提供歌词+封面，集成成本最低。

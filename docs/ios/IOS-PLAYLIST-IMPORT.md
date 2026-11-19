# iOS 导入歌单（QQ / 网易云 / 酷我 / 酷狗）

> 2026-11-19 提出并落地。老板口径：**入口只放设置页**；没导入过歌单时发现页保持原样
> （最近播放下面直接就是最新单曲，中间什么都不加、也没有标题）；导入过以后才在两者之间
> 出现「我的歌单」模块，模块样式对齐「最新单曲」（横滑宽卡），右上角「查看全部」；
> 点某个歌单进详情页，样式对齐「热门音乐 → 查看全部」；歌单**加载一次就写死**，往后不再加载。

---

## 1 先回答"可不可行"：四家都实测通了

2026-11-19 在本机（Windows，Australia 出口）用匿名请求逐家验证，**不需要登录、不需要 cookie、
不需要签名**，四家都能把"一个分享链接"变成"歌名 + 歌手 + 专辑 + 时长 + 封面 + 平台歌曲 id"：

| 平台 | 用到的接口 | 实测结果 | 备注 |
|---|---|---|---|
| QQ 音乐 | `GET c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&new_format=1&format=json&disstid=<id>` | 老板给的 `8887675900`（《2001-2010》）返回 **102 首**，`cdlist[0].dissname/nickname/logo` + `songlist[]` 全量 | **必须带 `Referer: https://y.qq.com/`**，否则回 `code=0, subcode=1, msg=invalid referer` |
| 网易云音乐 | `GET music.163.com/api/v6/playlist/detail?id=<id>&n=1000&s=8` | 热歌榜 `3778678` 回 200 首；`name/coverImgUrl/creator.nickname/tracks[]`（`id/name/ar/al/dt`） | `n` = 本次最多回多少首（上限 1000）；**私密歌单 / 别人「我喜欢的音乐」没登录读不到**（404 或空 tracks） |
| 酷我音乐 | 复用现有 `KuwoPlaylist`（`wapi.kuwo.cn/api/www/playlist/playListInfo`，pid + 分页 100） | `1082685104`「每日最新单曲推荐」回 310 首中的第一页 100 首，往后翻页可读满 | 和发现页「最新单曲」「歌单广场」同一接口，零新增风险 |
| 酷狗音乐 | `GET mobiles.kugou.com/api/v3/special/info?specialid=<id>` + `.../special/song?specialid=<id>&page=N&pagesize=100` | 老链接 `yy/special/single/5988470` → 83 首；`special/info` 给名字/作者/封面 | 新版分享链接是 `m.kugou.com/songlist/gcid_xxx/`（没有数字 id）：取这个 H5 页，从内联 state 里抠 `"specialid":数字`（唯一一处读页面） |

**结论：可行。** 四个 Host（`y.qq.com` / `music.163.com` / `wapi.kuwo.cn` / `mobiles.kugou.com`）
本来就在 App 的搜索 / 取流链路上用着，网络可达性与现有功能是同一水位；接口都是公开 GET/JSON，
不需要在 App 里内嵌后端。唯一要接受的三条边界写在下面 §5。

### 链接形态（`PlaylistImport.detect` 覆盖的）

- QQ：`i2.y.qq.com/n3/other/pages/details/playlist.html?...&id=<id>`、`y.qq.com/n/ryqq/playlist/<id>`
- 网易：`music.163.com/playlist?id=<id>`、`music.163.com/#/playlist?id=<id>`（参数在 `#` 后面）、
  `y.music.163.com/m/playlist?id=<id>&userid=...`
- 酷我：`www.kuwo.cn/playlist_detail/<pid>`、`m.kuwo.cn/newh5app/playlist_detail/<pid>`
- 酷狗：`m.kugou.com/songlist/gcid_xxx/`、`www.kugou.com/yy/special/single/<id>.html`
- 短链（`c6.y.qq.com/base/fcgi-bin/u?__=`、`163cn.tv/xxx`、`t1.kugou.com/xxx`）本身不带 id：
  跟一次 302，从落地页 URL 里再认（`PlaylistImport.resolve`）。
- 分享文案（`【QQ音乐】… <链接> 复制打开`）：先抠第一个 http 链接，再切掉中文标点/句末英文标点。

---

## 2 数据模型：一次性快照

`ImportedPlaylist`（`Services/PlaylistImport.swift`）：

```text
platform / sourceID / name / creator / cover / songs[Song] / importedAt
```

- **`songs` 是快照，不是 id 列表**：导入时一次性把歌名/歌手/专辑/时长/封面/平台歌曲 id 全存下来，
  之后进详情页、播放、下载都只用本地数据，不再请求任何歌单接口——老板要的"加载一次后写死"。
- 落盘：`Documents/my_playlists.json`（`MyPlaylistStore`，原子写；和收藏/最近播放同一套文件存储）。
  一个 300 首的歌单约 100~200 KB，不进 UserDefaults，避免拖慢启动。
- 同一家的同一个 `sourceID` 重复导入 = **覆盖**（不产生两条）。
- 上限：一次最多 1000 首 / 10 页（`PlaylistImport.maxSongs` / `maxPages`），与网易 `n=1000` 同口径。

## 3 UI：三处界面 + 一个入口

| 位置 | 文件 | 行为 |
|---|---|---|
| 发现页「我的歌单」模块 | `Views/DiscoverView.swift#myPlaylistsSection` | **只在 `myPlaylists.playlists` 非空时渲染**；标题 + `N 个` + 右上「查看全部」→ `MyPlaylistsView`；横滑 `MyPlaylistCard`（左半封面、右半同图糊底 + 白字，版式同 `NewReleaseCard`） |
| 我的歌单整页 | `Views/MyPlaylistViews.swift#MyPlaylistsView` | 全部导入歌单（52pt 封面 + 名字 + `N 首 · 平台 · 创建者`），长按可删；点进详情 |
| 歌单详情 | `Views/MyPlaylistViews.swift#MyPlaylistDetailView` | 页头（名字 + `N 首 · 平台 · 创建者` + 「播放全部」）+ 统一 `SongRow`（带名次），**零请求零 loading**（本地快照） |
| 设置 → 导入歌单 | `Views/SettingsView.swift` + `ImportPlaylistView` | 粘贴链接（或「从剪贴板粘贴」）→ 导入；失败用 `StatusLine` 说人话；下方是已导入列表（左滑删 / 清空）与支持范围说明 |

**没导入过时**：`myPlaylistsSection` 返回空（`@ViewBuilder` 的 `if`），发现页的模块顺序仍是
`最近播放 → 最新单曲`，不占位、不留标题、也没有"去导入"的引导条。

## 4 解析口径（CI 钉住）

- QQ：`platformID = songlist[].mid`；歌手像搜索一样用 `/` 连接；封面用 `album.mid` 拼
  `T002R300x300M000{mid}.jpg`；缺 `mid` / 缺歌名 / 重复 `mid` 的条目丢掉。
- 网易：`platformID = tracks[].id`；时长 `dt` 毫秒 → 秒；专辑图 `al.picUrl` 升 https；
  `id=0` 的条目丢掉；`code != 200` 或空 tracks 判失败。
- 酷我：直接用 `KuwoPlaylist.Release`（`rid` 去 `MUSIC_` 前缀、封面、时长认 mm:ss 的既有口径）。
- 酷狗：`platformID = hash`；`filename` 是 `"歌手 - 歌名"` 一整条，只切**第一个** ` - `；
  封面 `trans_param.union_cover` 的 `{size}` → 400 并升 https。
- 所有平台：同一条目重复出现按 `Song.id`（平台 + id）只留第一次；`http://` 统一升 https（ATS 严格）。
- 断言在 `ios/SelfTest/main.swift`「导入歌单：链接识别 / 四家解析（纯函数）」两节。

## 5 已知取舍与边界

1. **私密歌单读不到**：QQ/网易的私密歌单、别人「我喜欢的音乐」需要登录态；App 不做登录，
   导入时会以"歌单里没读到歌曲（可能是私密歌单，或链接已失效）"收尾，不会假装成功。
2. **网易 > 1000 首只导前 1000 首**：接口 `n` 上限 1000。要导完得再按 `trackIds` 分批补
   `/api/song/detail`，目前不做（自用歌单基本到不了这个量）。
3. **不跟随平台变化，导入后就是历史快照**：这是老板明确要的语义（"写死，往后不再加载"）。
   想更新就重新导入一次同一个链接（覆盖旧快照）。
4. **酷狗 gcid 链接依赖 H5 页面结构**：数字 id 的老链接走纯 JSON；gcid 链接要从页面内联 state 抠
   `"specialid"`。哪天酷狗改页面，只有这一类链接会失败，其它三家与酷狗老链接不受影响。
5. **QQ 接口要 Referer**：`APIClient` 默认 Referer 是 `music.qq.com`，QQ 歌单接口会拒；所以这条链路
   显式传 `Referer: https://y.qq.com/`（见 `fetchQQ`）。
6. **取流仍走原有适配器**：导入只负责"把歌列出来"，真正播放还是 `URLResolver` 按平台适配器取流，
   失败跨平台补位——VIP 独占曲目可能取不到源，这是既有的、与本次无关的边界。

## 6 验证

- 纯逻辑：`ios/SelfTest/main.swift` 新增约 30 条断言（链接识别 14 条 + 四家解析/去重/请求串 14 条）。
- 装机：设置 → 导入歌单 → 粘一条分享链接 → 发现页「最近播放」下面应出现「我的歌单」；
  点歌单进详情；退出 App 重开，模块与歌曲仍在（本地快照，不联网）。

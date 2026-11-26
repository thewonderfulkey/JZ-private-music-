# 发现页 2.0 + 专辑页 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans（本计划按原生执行：我在本会话逐任务落码）。

**Goal:** 把发现页从"酷我单源"改成"多源聚合并列"，并新增 BANNER、新碟、专辑页，删掉编辑精选。

**Architecture:** 数据层每板块拆成独立 loader（各源并发、独立成败、合并去重、带来源标记），UI 只消费 `SectionData`；单源失败只少那部分，整块空才隐藏。专辑页按专辑 id 走三级数据源兜底。

**Tech Stack:** SwiftUI + Observation，纯逻辑集中在 `*Rules` 文件里以便 CI 断言（本机无 Swift 工具链，测试只在 GitHub Actions 跑）。

**Spec:** `docs/superpowers/specs/2026-11-26-discover-v2-design.md`

## Global Constraints

- 只做 iOS（`ios/JZMusicHelper`）；桌面/Android 不动。
- 全部接口**匿名**可用；不引入 cookie/登录。
- 不做假数据：拿不到就少一块/隐藏，不放假歌占位。
- 同一板块同一首歌不出现两次。
- 所有新增纯逻辑必须进 `ios/SelfTest/main.swift` 断言；CI `logic-tests` 必须全绿。
- 每次提交只动本任务文件，commit message 用中文。

## Review Focus

1. **一个源挂了整块消失** —— 注入坏地址后，板块必须仍显示另一家的内容（Task 4 断言 `SectionData` 的 `sources` 状态）。
2. **去重把不同版本合成一首**（Live vs 原唱）—— 去重键必须带版本类（Task 1 断言）。
3. **专辑页拿错碟** —— 必须按专辑 id 拉，不允许用"专辑名搜"的结果冒充完整曲目（Task 3 断言 fallback 标记）。
4. **BANNER 跳外链** —— 非站内目标必须被过滤（Task 5 断言）。
5. **板块空态残留骨架/空壳** —— 0 条时整块不渲染（Task 4/6 断言 `isVisible`）。

---

### Task 1: 合并与去重规则（纯函数）

**Files:**
- Create: `ios/JZMusicHelper/Services/DiscoverMergeRules.swift`
- Test: `ios/SelfTest/main.swift`（新增 `r280MergeRulesAssertions()`）
- Modify: `.github/workflows/ios-ipa.yml`（swiftc 文件列表加一行）

**Interfaces:**
- Produces:
  - `enum DiscoverSource: String { case kuwo, netease, kugou }`
  - `DiscoverMergeRules.dedupeKey(_ song: Song) -> String`
  - `DiscoverMergeRules.merge(_ groups: [(DiscoverSource, [Song])]) -> [Song]`（交替合并、跨源去重、保留首见）
  - `DiscoverMergeRules.isVisible(_ items: [Song]) -> Bool`

- [ ] **Step 1: 写失败断言**
  - 同一首跨源只留一条：`晴天/周杰伦` 来自酷我与网易 → 合并后 1 条；
  - 不同版本不合并：`晴天` vs `晴天 (Live)` → 2 条；
  - 交替顺序：A1,B1,A2,B2；
  - 空源不影响：`[(.kuwo,[]),(.netease,[x])]` → `[x]`。
- [ ] **Step 2: 推 CI 看红**（`logic-tests` 报 `Cannot find 'DiscoverMergeRules'`）
- [ ] **Step 3: 实现** 上述三个函数（版本类进 key：`NameMatch.versionClass(name).sorted().joined()`）
- [ ] **Step 4: 推 CI 看绿**
- [ ] **Step 5: commit**

### Task 2: 网易发现数据源（解析纯函数 + 网络层）

**Files:**
- Create: `ios/JZMusicHelper/Services/NeteaseDiscover.swift`
- Test: `ios/SelfTest/main.swift`（`r281NeteaseDiscoverAssertions()`）

**Interfaces:**
- Produces:
  - `struct NeteaseAlbum { let id: String; let name: String; let artist: String; let cover: String?; let publishDate: String? }`
  - `struct NeteaseBanner { let image: String; let songID: String?; let title: String }`
  - `NeteaseDiscover.parseChartList(_ json: [String: Any]) -> [ChartBrief]`（name/id/updateFrequency/cover）
  - `NeteaseDiscover.parseChartSongs(_ json: [String: Any]) -> [Song]`（tracks → Song，platform .netease）
  - `NeteaseDiscover.parseNewSongs(_ json: [String: Any]) -> [Song]`
  - `NeteaseDiscover.parseNewAlbums(_ json: [String: Any]) -> [NeteaseAlbum]`
  - `NeteaseDiscover.parsePlaylists(_ json: [String: Any]) -> [PlaylistBrief]`
  - `NeteaseDiscover.parseBanners(_ json: [String: Any]) -> [NeteaseBanner]`（只留 `songID != nil`）
  - 网络层：`charts()/chartSongs(id:)/newSongs()/newAlbums()/playlists()/banners()`，全部匿名、各 8s。

- [ ] **Step 1: 断言**（用 2026-11-26 实测响应结构造 fixtures）：
  - 榜单 65 条、首条含 `id/name`;
  - 取歌 `tracks` 100 条 → `Song.platform == .netease`、`durationSec > 0`；
  - 首页块里 `NEW_ALBUM_NEW_SONG` 能同时抽到新碟与新歌；
  - banner 只保留带 songID 的条目（外链被过滤）。
- [ ] **Step 2: 推 CI 看红** → **Step 3: 实现** → **Step 4: 推 CI 看绿** → **Step 5: commit**

### Task 3: 专辑曲目服务（三级兜底）

**Files:**
- Create: `ios/JZMusicHelper/Services/AlbumService.swift`
- Test: `ios/SelfTest/main.swift`（`r282AlbumServiceAssertions()`）

**Interfaces:**
- `struct AlbumTracks { let albumID: String; let name: String; let artist: String; let cover: String?; let publishDate: String?; let songs: [Song]; let partial: Bool }`
- `AlbumService.parseNeteaseV1(_ json: [String: Any]) -> AlbumTracks?`
- `AlbumService.parseKuwo(_ json: [String: Any]) -> AlbumTracks?`
- `AlbumService.parseQQ(_ json: [String: Any], albumID: String) -> AlbumTracks?`
- `AlbumService.tracks(albumID:platform:) async -> AlbumTracks?`（网易 v1 → 酷我 → QQ；全空才 `partial = true` 的搜索兜底）

- [ ] **Step 1: 断言**：
  - 网易 v1 fixture（叶惠美 11 首）→ 11 条、`partial == false`、歌名首条「以父之名」；
  - 酷我 fixture（U87 12 首）→ 12 条；
  - 搜索兜底结果 `partial == true`（页面要标「曲目可能不全」）；
  - 空 JSON → nil。
- [ ] **Step 2–5:** 红 → 实现 → 绿 → commit

### Task 4: 发现页数据层（板块状态与并发）

**Files:**
- Modify: `ios/JZMusicHelper/Services/DiscoverFeed.swift`
- Test: `ios/SelfTest/main.swift`（`r283SectionRulesAssertions()`）

**Interfaces:**
- `struct SourceState { let source: DiscoverSource; let count: Int; let failed: Bool }`
- `struct SectionData { let items: [Song]; let sources: [SourceState]; var isVisible: Bool { !items.isEmpty } }`
- `DiscoverSectionRules.combine(_ results: [(DiscoverSource, [Song]?, Error?)]) -> SectionData`
- `DiscoverFeed` 增加到：`latest`（酷我+网易）、`hotCharts`（两个榜摘要）、`newAlbums`、`banners`、`square`（酷我+网易）。

- [ ] **Step 1: 断言**：一家 nil + 一家有数据 → `isVisible == true`、`sources` 标 failed；两家都空 → `isVisible == false`；顺序按交替。
- [ ] **Step 2–5:** 红 → 实现（并发 `async let`，单板块总预算 10s）→ 绿 → commit

### Task 5: BANNER 组件

**Files:**
- Create: `ios/JZMusicHelper/Views/DiscoverBanner.swift`
- Modify: `ios/JZMusicHelper/Views/DiscoverView.swift`（顶部插入）

**Interfaces:**
- `struct DiscoverBanner { let image: String; let song: Song; let title: String }`
- `BannerCarousel(banners:onTap:onClose:)`：4s 自动、可滑、右上角关闭、无数据整体不渲染。

- [ ] **Step 1: 断言** `BannerRules.nextIndex(current:count:)`（循环）与 `BannerRules.shouldShow(count:)`。
- [ ] **Step 2–5:** 红 → 实现 → 绿 → commit（UI 部分靠真机验收）

### Task 6: 新碟横滑 + 专辑页

**Files:**
- Create: `ios/JZMusicHelper/Views/NewAlbumsRow.swift`、`ios/JZMusicHelper/Views/AlbumDetailView.swift`
- Modify: `ios/JZMusicHelper/Services/AppRouter.swift`（新增 `.album(platform:id:)` 路由）

- [ ] **Step 1:** 断言 `AlbumRoute.parse`（从新碟条目生成路由）。
- [ ] **Step 2–5:** 实现 → 推 CI 编译绿 → commit

### Task 7: 热门音乐两行 + 榜单页来源切换 + 删编辑精选

**Files:**
- Modify: `ios/JZMusicHelper/Views/DiscoverView.swift`、`ios/JZMusicHelper/Views/ChartSongsView.swift`、`ios/JZMusicHelper/Models/DiscoverCatalog.swift`（停用）

- [ ] **Step 1:** 断言 `ChartSource.all`（酷我/网易两个来源、各自标题与 id）。
- [ ] **Step 2–5:** 实现 → CI 绿 → commit

### Task 8: 出包与真机验收

- [ ] 推 CI → 出包 → 装最新包
- [ ] 验收：断一家源仍显示另一家；BANNER 可轮播/可关/只跳站内；新碟点进专辑页曲目完整；删掉编辑精选后首屏无空洞
- [ ] 记录到 CHANGELOG 与诊断报告

---

## 执行方式

原生执行（本会话逐任务落码），因为任务之间接口耦合紧（`SectionData`、`AlbumTracks` 被 UI 直接消费），subagent 并行反而容易返工。
每个 Task 完成后推一次 CI，绿了再进下一个；出包闸沿用 `jz-ipa-bugfix` 的三道门。

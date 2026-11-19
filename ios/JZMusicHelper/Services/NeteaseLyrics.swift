import Foundation

// MARK: - 网易云歌词兜底（r70 / 口径 r73）
//
// 为什么加这一条：r70 老板反馈《发如雪》"整首没词"。查下来打分没问题
// （用酷狗真实返回的 20 条候选跑一遍：`发如雪 / 周杰伦 / 299s` 是满分 100，第一顺位），
// 真正断掉的是**取词链**——酷狗/QQ 那次一句候选都没回来。一条链抖一下整首歌就没词，
// 代价太大，所以补一个**独立第三条链**：网易云。
//
// r73：选源口径与 LDDC / LRCLIB / 酷我完全统一（`LddcMatch`）：
// 时长差 ≤4s → 标题×0.5 + 歌手×0.5 > 55 → **查询里没有的版本标记一律不收** →
// 分数降序试前 3 个 → 正文过 `commentaryReason` / `contentVersionRejection` 才收。
enum NeteaseLyrics {

    private static let timeout: TimeInterval = 4
    private static let minLines = 6

    /// 网易对"裸请求"（没有浏览器 UA、没有 cookie）经常直接回 405，
    /// 老板真机上"四个源都没取到词"里的那条 ④ 有一半是这个。r77 补齐。
    private static let headers: [String: String] = [
        "Referer": "https://music.163.com/",
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Cookie": "os=pc; appver=8.9.70; NMTID=00O-1uZ0Vf8m5Gq2yY6b8s4k0",
    ]

    static func fallback(_ song: Song, audioSec: Int = 0) async -> LyricsResult? {
        let keyword = song.searchKeyword
        guard !keyword.isEmpty else { return nil }

        let results = await search(keyword, limit: 15)
        guard !results.isEmpty else { return nil }

        let target = audioSec > 0 ? audioSec : song.durationSec
        let pool = results
            .filter {
                LddcMatch.identityRejection(queryTitle: song.name, queryArtist: song.singer,
                                            candidateTitle: $0.name, candidateArtist: $0.singer,
                                            targetSec: target,
                                            candidateSec: $0.durationSec) == nil
                    && LddcMatch.score(title: song.name, candidateTitle: $0.name,
                                       artist: song.singer, candidateArtist: $0.singer)
                        > LddcMatch.minScore
            }
            .sorted {
                let s0 = LddcMatch.score(title: song.name, candidateTitle: $0.name,
                                         artist: song.singer, candidateArtist: $0.singer)
                let s1 = LddcMatch.score(title: song.name, candidateTitle: $1.name,
                                         artist: song.singer, candidateArtist: $1.singer)
                if s0 != s1 { return s0 > s1 }
                return abs($0.durationSec - target) < abs($1.durationSec - target)
            }
        guard !pool.isEmpty else { return nil }

        for best in pool.prefix(3) {
            guard let lines = await officialLines(platformID: best.platformID),
                  lines.count >= minLines else { continue }
            // 正文是文案/字幕，或自报是另一个版本 → 换下一个候选
            guard LyricsCleaning.foreignVersionReason(lines: lines, queryTitle: song.name) == nil else {
                continue
            }
            let note = "《\(best.name)》· 网易云 · 候选 \(best.durationSec)s / 目标 \(target)s"
            return LyricsResult(lines: lines, source: "网易云", matchNote: note)
        }
        return nil
    }

    /// 搜索（**不复用 SearchTab 那个 adapter**）。
    ///
    /// 两个原因：adapter 会顺手补封面（多一个请求、多一两秒，取词链只要 id/歌名/歌手/时长）；
    /// 而且它没有浏览器头。这里主域名不通就换 `interface.music.163.com` 再试一次。
    private static func search(_ keyword: String, limit: Int) async -> [Song] {
        for host in ["music.163.com", "interface.music.163.com"] {
            let url = "https://\(host)/api/search/get?s=\(APIClient.encode(keyword))"
                + "&type=1&offset=0&limit=\(limit)"
            guard let json = try? await APIClient.shared.getJSON(url, headers: headers,
                                                                 timeout: timeout),
                  (json["code"] as? Int) == 200,
                  let list = (json["result"] as? [String: Any])?["songs"] as? [[String: Any]],
                  !list.isEmpty else { continue }
            var songs: [Song] = []
            for item in list {
                guard let id = item["id"] as? Int, id > 0,
                      let name = item["name"] as? String, !name.isEmpty else { continue }
                let artists = (item["artists"] as? [[String: Any]] ?? [])
                    .compactMap { $0["name"] as? String }
                    .joined(separator: "/")
                let album = (item["album"] as? [String: Any])?["name"] as? String ?? ""
                let durMs = (item["duration"] as? Int) ?? 0
                songs.append(Song.make(platform: .netease, platformID: String(id), name: name,
                                       singer: artists, album: album,
                                       duration: Double(durMs / 1000), picURL: nil))
            }
            if !songs.isEmpty { return songs }
        }
        return []
    }

    /// `/api/song/lyric` 返回 `lrc.lyric`（标准 LRC 文本），解析成行级歌词
    ///
    /// r79（2026-11-19）：公开给 `LyricsService` 的「①b 平台官方词」用——
    /// 播放的本来就是网易云那首（`platformID` 是精确的 songId），直接按 id 问官方，
    /// 不用像下面 `fallback` 那样按「歌名+歌手」重新搜。
    /// 为什么必须有这条路：周杰伦的歌 2021 年从网易云**搜索索引**下架，
    /// `search("青花瓷 周杰伦")` 前 15 条全是翻唱、身份闸全拒，可 `/api/song/lyric?id=185811`
    /// 仍然留着完整歌词（实测 1462 字）——只按搜索走，④ 对这类歌永远取不到词。
    static func officialLines(platformID: String) async -> [LyricLine]? {
        guard let id = Int(platformID), id > 0 else { return nil }
        let url = "https://music.163.com/api/song/lyric?id=\(id)&lv=-1&kv=-1&tv=-1"
        guard let json = try? await APIClient.shared.getJSON(
            url, headers: headers, timeout: timeout),
              let lrc = (json["lrc"] as? [String: Any])?["lyric"] as? String,
              !lrc.isEmpty else { return nil }
        let lines = LyricsCleaning.parseLrc(lrc)
        return lines.isEmpty ? nil : lines
    }
}

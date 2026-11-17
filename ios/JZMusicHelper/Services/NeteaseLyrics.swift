import Foundation

// MARK: - 网易云歌词兜底（r70）
//
// 为什么加这一条：r70 老板反馈《发如雪》"整首没词"。查下来打分没问题
// （用酷狗真实返回的 20 条候选跑一遍：`发如雪 / 周杰伦 / 299s` 是满分 100，第一顺位），
// 真正断掉的是**取词链**——酷狗/QQ 那次一句候选都没回来，酷我兜底也没成。
// 一条链抖一下整首歌就没词，代价太大，所以补一个**独立第三条链**：网易云。
//
// 口径与酷我兜底一致：按「歌名 歌手」搜，标题/歌手都要像（`NameMatch`），
// 带"另一版"标记的候选只有在没有正片时才用；取到的是纯 LRC（行级时间，没有逐字）。
enum NeteaseLyrics {

    private static let timeout: TimeInterval = 8
    private static let minLines = 6

    static func fallback(_ song: Song, audioSec: Int = 0) async -> LyricsResult? {
        let keyword = song.searchKeyword
        guard !keyword.isEmpty else { return nil }
        let adapter = NeteaseSearchAdapter()
        guard let results = try? await adapter.search(keyword: keyword, limit: 15),
              !results.isEmpty else { return nil }

        let target = audioSec > 0 ? audioSec : song.durationSec
        let pool = results.filter {
            NameMatch.titleMatches(song.name, $0.name) && NameMatch.singerMatches(song.singer, $0.singer)
                // 候选带「查询没有」的版本标记（live/伴奏/醇享版…）就先排除
                && LddcMatch.versionPenalty(queryTitle: song.name, candidateTitle: $0.name) == 0
        }
        guard let best = pool.min(by: {
            abs($0.durationSec - target) < abs($1.durationSec - target)
        }) else { return nil }

        guard let lines = await lyricLines(platformID: best.platformID), lines.count >= minLines else {
            return nil
        }
        let note = "《\(best.name)》· 网易云兜底 · 候选 \(best.durationSec)s / 目标 \(target)s"
        return LyricsResult(lines: lines, source: "网易云", matchNote: note)
    }

    /// `/api/song/lyric` 返回 `lrc.lyric`（标准 LRC 文本），解析成行级歌词
    static func lyricLines(platformID: String) async -> [LyricLine]? {
        guard let id = Int(platformID), id > 0 else { return nil }
        let url = "https://music.163.com/api/song/lyric?id=\(id)&lv=-1&kv=-1&tv=-1"
        guard let json = try? await APIClient.shared.getJSON(
            url, headers: ["Referer": "https://music.163.com/"], timeout: timeout),
              let lrc = (json["lrc"] as? [String: Any])?["lyric"] as? String,
              !lrc.isEmpty else { return nil }
        let lines = LyricsCleaning.parseLrc(lrc)
        return lines.isEmpty ? nil : lines
    }
}

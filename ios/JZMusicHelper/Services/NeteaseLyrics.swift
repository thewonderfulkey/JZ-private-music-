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

    private static let timeout: TimeInterval = 8
    private static let minLines = 6

    static func fallback(_ song: Song, audioSec: Int = 0) async -> LyricsResult? {
        let keyword = song.searchKeyword
        guard !keyword.isEmpty else { return nil }
        let adapter = NeteaseSearchAdapter()
        guard let results = try? await adapter.search(keyword: keyword, limit: 15),
              !results.isEmpty else { return nil }

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
            guard let lines = await lyricLines(platformID: best.platformID),
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

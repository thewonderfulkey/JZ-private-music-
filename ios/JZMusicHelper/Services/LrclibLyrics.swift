import Foundation

// MARK: - LRCLIB 歌词源（r72）
//
// 为什么加这一条：老板在 PC 上用 LDDC.exe 能取到《发如雪》的词，App 里却是
// 「候选 20 条（酷狗 20），取词成功 0/4 份（两轮），酷狗取词两条通道都没成」——
// 断的是酷狗那条**取词**接口（真机上两个域名都没回），搜索却是好的。
// LRCLIB 是一条**完全独立**的公开源：不要签名、不受酷狗限流影响，返回标准 LRC。
// 实测 2026-11-17：《发如雪》299.28s、《七里香》297s、《晴天》270s 都有**同步**歌词。
//
// 接口（只用两个）：
//   GET https://lrclib.net/api/get?track_name=&artist_name=&duration=   ← 精确命中，最准
//   GET https://lrclib.net/api/search?q=歌名 歌手                        ← 拿一批，自己按 LDDC 口径挑
//
// 口径与 LDDC 一致：标题/歌手都像（>55 分）、时长差 ≤4 秒、歌词正文不能是另一个版本。
enum LrclibLyrics {

    private static let timeout: TimeInterval = 8
    private static let minLines = 6

    /// 一条候选（只留取词要用的字段）
    struct Track: Sendable {
        let title: String
        let artist: String
        let durationSec: Int
        let syncedLyrics: String?
        let instrumental: Bool
    }

    /// 取词：先精确命中，再搜一批按分数挑
    static func fetch(_ song: Song, audioSec: Int = 0) async -> LyricsResult? {
        let title = song.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = LyricsCleaning.cleanArtist(song.singer)
        guard !title.isEmpty else { return nil }
        let target = audioSec > 0 ? audioSec : song.durationSec

        if let track = await get(title: title, artist: artist, durationSec: target),
           let result = adopt(track, song: song, target: target) {
            return result
        }
        let tracks = await search(title: title, artist: artist)
        guard let best = pickBest(tracks, queryTitle: song.name, queryArtist: song.singer,
                                 targetSec: target) else { return nil }
        return adopt(best, song: song, target: target)
    }

    // MARK: 选源（纯函数，CI 可断言）

    /// 从一批候选里挑"确实是同一首、且带时间轴"的那条。
    ///
    /// r73 口径与 LDDC 相同，但**按歌名搜出来的源一律不收变体**（live/现场/伴奏/花絮…）：
    /// 时长差 ≤4 秒 → 分数 >55 → 查询里没有的版本标记直接排除（宁可没词，也不贴另一版）
    /// → 分数降序，同分时"时长更接近"的优先
    /// （LRCLIB 里同一个歌名常既有 299s 的也有 0s 的，0 秒那条不能靠运气赢）。
    static func pickBest(_ tracks: [Track], queryTitle: String, queryArtist: String,
                         targetSec: Int) -> Track? {
        var best: (track: Track, score: Double, delta: Int)?
        for track in tracks {
            guard !track.instrumental else { continue }
            guard let synced = track.syncedLyrics, !synced.isEmpty else { continue }
            guard LddcMatch.durationOK(targetSec: targetSec, candidateSec: track.durationSec) else { continue }
            guard LddcMatch.extraVariantTags(queryTitle: queryTitle,
                                             candidateTitle: track.title).isEmpty else { continue }
            let score = LddcMatch.score(title: queryTitle, candidateTitle: track.title,
                                        artist: queryArtist, candidateArtist: track.artist)
            guard score > LddcMatch.minScore else { continue }
            let delta = (track.durationSec > 0 && targetSec > 0)
                ? abs(track.durationSec - targetSec) : Int.max
            let better = best == nil || score > best!.score
                || (score == best!.score && delta < best!.delta)
            if better { best = (track, score, delta) }
        }
        return best?.track
    }

    /// 把一条候选变成取词结果：同一首校验 → 解析 LRC → 行数门槛 → 正文闸门（文案/别的版本）
    static func adopt(_ track: Track, song: Song, target: Int) -> LyricsResult? {
        let score = LddcMatch.score(title: song.name, candidateTitle: track.title,
                                    artist: song.singer, candidateArtist: track.artist)
        guard score > LddcMatch.minScore,
              LddcMatch.durationOK(targetSec: target, candidateSec: track.durationSec),
              LddcMatch.extraVariantTags(queryTitle: song.name, candidateTitle: track.title).isEmpty else {
            return nil
        }
        guard let synced = track.syncedLyrics, !synced.isEmpty else { return nil }
        let lines = LyricsCleaning.parseLrc(synced)
        guard lines.count >= minLines else { return nil }
        guard LyricsCleaning.foreignVersionReason(lines: lines, queryTitle: song.name) == nil else {
            return nil
        }
        let note = "《\(track.title)》· LRCLIB · 候选 \(track.durationSec)s / 目标 \(target)s"
            + " · 合计 \(Int(score))"
        let aligned = LyricsCleaning.alignedToAudio(lines, declaredMs: 0, audioSec: song.durationSec)
        return LyricsResult(lines: aligned.lines, source: "LRCLIB", matchNote: note)
    }

    // MARK: 网络

    private static func get(title: String, artist: String, durationSec: Int) async -> Track? {
        var url = "https://lrclib.net/api/get?"
            + "track_name=" + APIClient.encode(title)
            + "&artist_name=" + APIClient.encode(artist)
        if durationSec > 0 { url += "&duration=\(durationSec)" }
        guard let json = try? await APIClient.shared.getJSON(
            url, headers: ["Accept": "application/json"], timeout: timeout) else { return nil }
        return track(json)
    }

    private static func search(title: String, artist: String) async -> [Track] {
        let url = "https://lrclib.net/api/search?q=" + APIClient.encode("\(title) \(artist)")
        guard let list = try? await APIClient.shared.getJSONArray(
            url, headers: ["Accept": "application/json"], timeout: timeout) else { return [] }
        return list.compactMap { $0 as? [String: Any] }.compactMap(track)
    }

    private static func track(_ json: [String: Any]) -> Track? {
        let title = (json["trackName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let artist = json["artistName"] as? String ?? ""
        let duration = (json["duration"] as? Double) ?? Double(json["duration"] as? Int ?? 0)
        return Track(title: title,
                     artist: artist,
                     durationSec: Int(duration.rounded()),
                     syncedLyrics: json["syncedLyrics"] as? String,
                     instrumental: json["instrumental"] as? Bool ?? false)
    }
}

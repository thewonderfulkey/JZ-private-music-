import Foundation

// MARK: - 识曲候选 → 搜索结果主结果（纯函数，CI 断言）
//
// 2026-11-28 真机事故（v2.4.138 录屏《夜曲》）：
//   识别候选是对的（酷狗《夜曲》226s），但搜索列表第一条是《夜曲 - A35》108s（1:48 剪辑）。
//   旧逻辑 `songs.first { 歌名像 + 歌手对 + 裸名 }` 不看时长，把剪辑选成主结果——
//   播放、封面、识曲历史全用它；真正的 3:46 就在同一列表里，甚至被「其他版本」标成了原唱。
//
// 主结果必须和候选的**时长**对得上：歌名/歌手只能说明"可能是"，时长才是"同一条录音"最硬的证据。
enum RecognizeResolveRules {

    /// 允许的时长差（秒）。搜索元数据常见 ±1~2s；5s 能挡住剪辑/现场，又不会误杀正常条目。
    static let durationTolerance = 5

    /// 主结果选择：
    /// 1) 先按原身份条件（歌名像 + 歌手对 + 裸名）过滤，再加时长闸门；
    /// 2) 通过里选时长最接近的；
    /// 3) 没有裸名原版就退到"归一化歌名相同 / 歌名像 + 歌手对"，同样加时长闸门；
    /// 4) 都不行返回 nil（调用方再用 `StudioPick.originalVersion` 兜底）。
    static func pick(from songs: [Song], candidate: RecognizeCandidate) -> Song? {
        let studio = songs.filter {
            NameMatch.titleMatches(candidate.title, $0.name)
                && NameMatch.singerMatches(candidate.artist, $0.singer)
                && StudioPick.isCleanTitle($0.name)
                && durationOK($0, candidate)
        }
        if let best = closest(studio, candidate) { return best }

        // 2026-11-29 真机事故（v2.4.140《5:20AM》）：
        //   候选 5:20AM(活凤版) / 礼崩乐不坏 / 193s，搜索里却把
        //   5:20AM (河南话原版) / 夜晚助眠屋 / 191s 选成主结果——点播放时名字歌手全变。
        //   原因是归一化歌名相等这一支**没有要求歌手**：两首去掉括号都是 520am，
        //   时长只差 2s，另一个歌手的翻唱就过了闸。
        // 口径：歌名/时长只负责"像"，歌手才是同一张录音的硬条件；两个分支都必须过歌手。
        let titleOnly = songs.filter {
            (NameMatch.normTitle(candidate.title) == NameMatch.normTitle($0.name)
             || NameMatch.titleMatches(candidate.title, $0.name))
                && NameMatch.singerMatches(candidate.artist, $0.singer)
                && durationOK($0, candidate)
        }
        return closest(titleOnly, candidate)
    }

    /// 合并「歌名 + 候选歌手」与「只搜歌名」两批结果：同一条录音去重，主搜索顺序优先。
    /// 只用于把原唱/别的版本捞进「其他版本」，不参与主结果选择。
    static func mergeSearchResults(primary: [Song], broad: [Song]) -> [Song] {
        var seen = Set<String>()
        var out: [Song] = []
        for song in primary + broad {
            let key = StudioPick.recordingKey(song)
            let dedupeKey = key.isEmpty ? song.id : key
            if seen.insert(dedupeKey).inserted {
                out.append(song)
            }
        }
        return out
    }

    /// 候选有真实时长、搜索结果也有时长时才卡；任一未知不硬拒（排序会排到后面）。
    static func durationOK(_ song: Song, _ candidate: RecognizeCandidate) -> Bool {
        guard candidate.durationSec > 0, song.duration > 0 else { return true }
        return abs(song.duration - Double(candidate.durationSec)) <= Double(durationTolerance)
    }

    /// 时长最接近；同时长时裸名优先；再同时长短的优先（稳定）
    static func closest(_ songs: [Song], _ candidate: RecognizeCandidate) -> Song? {
        songs.min { a, b in
            let da = distance(a, candidate)
            let db = distance(b, candidate)
            if da != db { return da < db }
            let ca = StudioPick.isCleanTitle(a.name)
            let cb = StudioPick.isCleanTitle(b.name)
            if ca != cb { return ca && !cb }
            return a.duration < b.duration
        }
    }

    static func distance(_ song: Song, _ candidate: RecognizeCandidate) -> Double {
        guard candidate.durationSec > 0, song.duration > 0 else { return .greatestFiniteMagnitude }
        return abs(song.duration - Double(candidate.durationSec))
    }
}

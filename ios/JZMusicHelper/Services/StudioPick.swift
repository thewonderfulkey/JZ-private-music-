import Foundation

// MARK: - 录音室原唱优选（Studio Original Picker）
//
// 与 Android `StudioPick.kt`（v2.1.30 起）同口径。背景：同一首《龙文》在各平台同时存在
// 录音棚原唱（谭晶《看见》313s）、节目消音版（243s、无专辑）、春晚现场版（117s）等条目，
// 只按歌名判「原版」会全部放行，必须再看专辑与时长。
//
// 判定口径：
//   ① 歌名是否「裸名」：剥掉括号版本说明与「- Live」「伴奏」等修饰后仍等于原名；
//   ② 专辑名是否现场/节目来源；
//   ③ 时长 vs 同曲共识时长（±10s 分桶取众数）：≤12s 同版，>30s 视为剪辑/片段/串烧；
//   ④ 单歌手优于多歌手串（合唱版/群星版降权）。
enum StudioPick {

    private static let bracket = Pattern.make("（[^）]*）|\\([^)]*\\)|\\[[^\\]]*\\]|【[^】]*】")

    private static let editSuffix = Pattern.make(
        "\\s*[-—–·]?\\s*(" +
        "伴奏|钢琴版|吉他版|翻唱|cover|live|现场版|现场|演唱会|音乐会|remix|dj版|dj|电音|串烧|" +
        "合唱版|合唱|纯音乐|钢琴|混音|重制|ktv|对唱|说唱|beat|instrumental|片段|剪辑|消音|学唱|" +
        "咚鼓|童声|古筝|学唱版|版本[0-9一二三四五六七八九十]+" +
        ").*$",
        options: [.caseInsensitive])

    private static let liveAlbum = Pattern.make(
        "现场|演唱会|音乐会|春晚|春节|联欢|跨年|晚会|盛典|颁奖|综艺|节目|直播|" +
        "live|concert|unplugged|新声代|天赐|蒙面|我们的歌|声生不息|歌手20",
        options: [.caseInsensitive])

    private static let multiSinger = Pattern.make("[/&、,，;；]|\\s{2,}")

    private static let quotedName = Pattern.make("[\"'“”‘’「」『』]([^\"'“”‘’「」『』]*)[\"'“”‘’「」『』]")

    private static let trailingJoiner = Pattern.make("\\s*[-—–·]\\s*$")

    // MARK: 核心歌名

    /// 核心歌名：剥括号版本说明 + 引号包裹名 + 修饰后缀 + 尾部连接符
    static func coreName(_ raw: String) -> String {
        var n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "" }
        n = bracket.stringByReplacingMatches(in: n, range: ns(n), withTemplate: "")
        n = n.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 「周杰伦"夜曲"」这类引号包裹：取引号内原名
        if let m = quotedName.firstMatch(in: n, range: ns(n)),
           m.numberOfRanges > 1,
           let r = Range(m.range(at: 1), in: n) {
            let inner = n[r].trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty { n = inner }
        }
        n = editSuffix.stringByReplacingMatches(in: n, range: ns(n), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        n = trailingJoiner.stringByReplacingMatches(in: n, range: ns(n), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return n
    }

    /// 是否「裸名原版」：核心名与原名一致
    static func isCleanTitle(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return false }
        return coreName(n).compare(n, options: [.caseInsensitive]) == .orderedSame
    }

    /// 专辑是否来自现场/节目（空专辑不算现场，但也不加分）
    static func isLiveAlbum(_ album: String) -> Bool {
        let a = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return false }
        return liveAlbum.firstMatch(in: a, range: ns(a)) != nil
    }

    /// 同曲共识时长：多平台多数条目时长（±10s 分桶取众数；至少 2 条才成立）
    static func consensusDuration(_ cands: [Song]) -> Int? {
        let durs = cands.map(\.durationSec).filter { $0 >= 30 && $0 <= 7200 }
        guard durs.count >= 2 else { return nil }
        var buckets: [Int: [Int]] = [:]
        for d in durs { buckets[d / 10, default: []].append(d) }
        guard let best = buckets.values.max(by: { $0.count < $1.count }), best.count >= 2 else {
            return nil
        }
        return best.sorted()[best.count / 2]
    }

    /// 原唱得分（越高越接近录音棚原唱）。只在同曲候选之间比较，不做跨曲绝对判断
    static func studioScore(_ s: Song, consensusDurSec: Int? = nil) -> Int {
        var score = 0
        score += isCleanTitle(s.name) ? 100 : -60
        if isLiveAlbum(s.album) {
            score -= 80
        } else if !s.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 15
        }
        if let cons = consensusDurSec, s.durationSec > 0 {
            let diff = abs(s.durationSec - cons)
            if diff <= 12 { score += 40 } else if diff > 30 { score -= 70 }
        }
        let singer = s.singer.trimmingCharacters(in: .whitespacesAndNewlines)
        score += multiSinger.firstMatch(in: singer, range: ns(singer)) != nil ? -12 : 10
        score -= s.name.trimmingCharacters(in: .whitespacesAndNewlines).count / 6
        return score
    }

    /// 在一组同曲候选里挑最接近录音室原唱的一条
    static func pickBest(_ cands: [Song]) -> Song? {
        guard let first = cands.first else { return nil }
        if cands.count == 1 { return first }
        let cons = consensusDuration(cands)
        return cands.max { studioScore($0, consensusDurSec: cons) < studioScore($1, consensusDurSec: cons) }
    }

    // MARK: 同一首歌的「其他版本」与原唱标签（第三十三轮）
    //
    // 老板 2026-11-18 真机截图：识曲《阁爱你一摆》的「其他版本」里，六条**不同的歌**
    // （我的未来不是梦 / 敢傻敢冲 / 浪子的路 …）全被打了「原唱」。根因有两层：
    //   ① 搜索关键词是「歌名 + 歌手」，对高产歌手会返回一堆同歌手的别的歌；
    //   ② 旧标签只看「这一行自己的歌名是否裸名 + 歌手是否含原唱」，没看「是不是同一首歌」。
    // 现在：先按核心歌名（繁简折叠 + 去标点）严格过滤出同一首歌，再去重、排除主结果那条录音，
    // 最后最多只给**一条**与原唱时长对得上的裸名版本打「原唱」。

    private static let namePunct = Pattern.make(
        "[\\s·・\\-—_.,，、'\"“”‘’!！?？:：/\\\\&*+()（）\\[\\]【】]")

    /// 核心歌名的比较键：剥版本后缀 → 繁转简 → 小写 → 去标点空白
    static func normalizedCoreName(_ raw: String) -> String {
        let core = coreName(raw)
        guard !core.isEmpty else { return "" }
        let folded = TradToSimpMap.toSimplified(core).lowercased()
        return namePunct.stringByReplacingMatches(in: folded, range: ns(folded), withTemplate: "")
    }

    /// 同一首歌的所有版本（严格核心歌名相等；「阁爱妳一摆」与「阁爱你一摆」视为同一首）
    static func sameSongVersions(_ songs: [Song], matching title: String) -> [Song] {
        let target = normalizedCoreName(title)
        guard !target.isEmpty else { return [] }
        return songs.filter { song in
            let key = normalizedCoreName(song.name)
            return !key.isEmpty && key == target
        }
    }

    /// 同一条录音的键：核心歌名 + 歌手集合 + 时长 5 秒桶。
    /// 跨平台的同一录音（QQ / 网易 / 酷狗各一条）会落到同一个键，只留第一条。
    static func recordingKey(_ song: Song) -> String {
        let singers = NameMatch.singerTokens(song.singer).sorted().joined(separator: "/")
        let bucket = song.durationSec > 0 ? song.durationSec / 5 : 0
        return "\(normalizedCoreName(song.name))|\(singers)|\(bucket)"
    }

    /// 跨平台去重：同一条录音只留一条（不同版本/翻唱时长或歌手不同，不会被合掉）
    static func dedupeRecordings(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        var out: [Song] = []
        for song in songs {
            let key = recordingKey(song)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            out.append(song)
        }
        return out
    }

    /// 把主结果那条录音（含它在别的平台的副本）从「其他版本」里剔掉，
    /// 避免同一首歌在主卡和列表里各出现一次。
    static func excludingRecording(of main: Song?, from songs: [Song]) -> [Song] {
        guard let main else { return songs }
        let key = recordingKey(main)
        guard !key.isEmpty else { return songs }
        return songs.filter { recordingKey($0) != key }
    }

    /// 这一条是否「原唱录音」：同一首歌 + 裸名 + 歌手匹配 + 时长对得上识别时长（±15s）
    static func isOriginalRecording(_ song: Song, title: String, artist: String,
                                    durationSec: Int) -> Bool {
        let target = normalizedCoreName(title)
        guard !target.isEmpty, normalizedCoreName(song.name) == target else { return false }
        guard isCleanTitle(song.name) else { return false }
        guard NameMatch.singerMatches(artist, song.singer) else { return false }
        if durationSec > 0, song.durationSec > 0 {
            return abs(song.durationSec - durationSec) <= 15
        }
        return true
    }

    /// 在一组「其他版本」里挑唯一一条原唱（没有就返回 nil，绝不批量打标签）
    static func originalVersion(in songs: [Song], title: String, artist: String,
                                durationSec: Int) -> Song? {
        let candidates = songs.filter {
            isOriginalRecording($0, title: title, artist: artist, durationSec: durationSec)
        }
        guard !candidates.isEmpty else { return nil }
        if durationSec > 0 {
            return candidates.min {
                abs($0.durationSec - durationSec) < abs($1.durationSec - durationSec)
            }
        }
        return pickBest(candidates)
    }

    /// 候选池按核心歌名归并：同一首歌只保留「最像录音室原唱」的一条
    static func dedupeByCore(_ cands: [Song]) -> [Song] {
        if cands.count <= 1 { return cands }
        var order: [String] = []
        var groups: [String: [Song]] = [:]
        for s in cands {
            var key = coreName(s.name)
            if key.isEmpty { key = s.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            if key.isEmpty { continue }
            if groups[key] == nil {
                groups[key] = []
                order.append(key)
            }
            groups[key]?.append(s)
        }
        var out: [Song] = []
        for key in order {
            guard let g = groups[key] else { continue }
            if let best = pickBest(g) { out.append(best) }
        }
        return out
    }

    private static func ns(_ s: String) -> NSRange {
        NSRange(s.startIndex..<s.endIndex, in: s)
    }
}

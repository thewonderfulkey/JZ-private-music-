import Foundation

// MARK: - 搜索联想（"智能搜索"第一版，2026-11-27 老板选定 A 方案）
//
// 老板口径：「智能搜索」先做**输入联想**：边打边出建议，点一下直接搜。
//
// 这里只放纯逻辑（可 CI 断言），网络在 `SearchService.suggest`，UI 在 `SearchView`。
//
// 三条硬规矩：
//   ① 太短不联想：中文 1 个字就够（"晴"能出《晴天》），英文要 2 个字母（单个字母全是噪音）；
//   ② 结果必须过垃圾过滤：上传者的变速/DJ 条目不许出现在建议里（与搜索页同一口径）；
//   ③ 去重：同一首歌在多个平台都有时只留一条，否则建议里全是《晴天》×4。

enum SearchSuggestRules {

    /// 联想列表最多几条（再多就把屏幕占满了，联想不是结果页）
    static let maxSuggestions = 8

    /// 停下打字多久才发请求（毫秒）——打字过程中不发，避免每个键都打三次网络
    static let debounceMs = 280

    /// 这个输入该不该发联想请求
    static func shouldSuggest(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        // 含 CJK 就按"字数"算，纯拉丁/数字按"长度"算
        let hasCJK = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)     // 基本汉字
                || (0x3040...0x30FF).contains(scalar.value)   // 日文假名
                || (0xAC00...0xD7AF).contains(scalar.value)   // 韩文
        }
        return hasCJK ? text.count >= 1 : text.count >= 2
    }

    /// 去重 + 过滤 + 截断（保持传入顺序：调用方按平台优先级送进来）
    static func refine(_ songs: [Song], limit: Int = maxSuggestions) -> [Song] {
        let clean = JunkAudioRules.filter(songs)
        var seen = Set<String>()
        var out: [Song] = []
        for song in clean {
            let key = dedupeKey(song)
            guard seen.insert(key).inserted else { continue }
            out.append(song)
            if out.count >= max(0, limit) { break }
        }
        return out
    }

    /// 建议里的"同一首歌"：歌名身份键 + 歌手 token（排序后）+ **版本类**
    ///
    /// 不用 `Song.id`：同一个歌名在四个平台有四个 id，建议里出现四条一样的《晴天》就是噪音。
    /// **版本类必须进键**（2026-11-27 断言抓到）：`identityKey` 会把括号里的 `(Live)` 剥掉，
    /// 只留歌名+歌手的话《晴天》和《晴天 (Live)》会被并成一条——联想里少给一条版本可以，
    /// 但用户明明搜的是 Live，点进去变录音室版就是错的。
    static func dedupeKey(_ song: Song) -> String {
        let title = NameMatch.identityKey(song.name)
        let singers = NameMatch.singerTokens(song.singer).sorted().joined(separator: "+")
        let ver = NameMatch.versionClass(song.name).sorted().joined(separator: "+")
        return "\(title)|\(singers)|\(ver)"
    }

    /// 建议行要不要显示歌手（歌名里已经带了同一串歌手时不重复显示）
    static func subtitle(for song: Song) -> String {
        let singer = song.singer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singer.isEmpty else { return "" }
        if song.name.localizedCaseInsensitiveContains(singer) { return "" }
        return singer
    }
}

import Foundation

// MARK: - 歌词数据模型
//
// 与 Android `LyricWord / LyricLine / LyricsResult` 同构。
// 逐字时间来自酷狗 KRC / QQ QRC 明文，`startMs` 已换算成**整首歌的绝对毫秒**，
// 可直接与播放器进度比较；纯 LRC（无逐字时间）的源 `words` 为空，渲染层回退到行内插值。

/// 一个字的起止时间（毫秒，绝对）
struct LyricWord: Hashable, Sendable {
    let text: String
    let startMs: Int
    let durMs: Int
}

/// 一行歌词
struct LyricLine: Hashable, Sendable {
    let timeMs: Int
    let text: String
    let words: [LyricWord]

    init(timeMs: Int, text: String, words: [LyricWord] = []) {
        self.timeMs = timeMs
        self.text = text
        self.words = words
    }

    /// 这一行有没有逐字时间（决定渲染方式：逐字染色 or 行内均分）
    var hasWordTiming: Bool { !words.isEmpty }
}

/// 一次取词的结果：歌词行 + 来源标签（"酷我" / "LDDC"）
struct LyricsResult: Sendable {
    let lines: [LyricLine]
    let source: String
    /// 「为什么选了这份词」——候选标题 / 时长 / 各档分数（r69 起给详情页和日志看）
    var matchNote: String = ""
    /// 这份词是不是**兜底档**拿到的（r71）：分数没过线、只是"有候选就取"。
    /// 兜底档的词常常是另一个剪辑（Live / 醇享版），时间轴对不上——
    /// 所以它只应该在**酷我官方词 / 网易云**都没有的时候才上场（见 `LyricsService.resolve`）。
    var isFallback: Bool = false

    var isEmpty: Bool { lines.isEmpty }

    /// 有没有**逐字**时间（决定播放页能不能做"唱到哪染到哪"）
    var hasWordTiming: Bool { lines.contains { $0.hasWordTiming } }
}

/// 取词失败的原因（给状态行显示，不甩英文异常）
enum LyricsError: Error, Equatable {
    case noCandidate        // 搜不到任何候选
    case tooFewLines        // 候选歌词残缺（<6 行）
    case broken             // 解密出来的文本是乱码
    case network(String)    // 网络层失败
    case decryptFailed      // 解密失败
}

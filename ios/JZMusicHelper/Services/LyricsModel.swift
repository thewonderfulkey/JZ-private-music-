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

    /// 高亮这一行用的时间点。
    ///
    /// 为什么不用 `timeMs`：KRC/QRC 的 `[start,dur]` 是**行**开始，而很多歌词行会在第一个字之前
    /// 留 0.3–1s 的呼吸（前奏/拖音），拿行开始去高亮就会"还没唱就切了"。
    /// 取两者**较晚**的那个：既不会早于行开始，也不会早于第一个字真正唱出来的时刻。
    var highlightStartMs: Int {
        guard let first = words.first else { return timeMs }
        return max(timeMs, first.startMs)
    }
}

/// 一次取词的结果：歌词行 + 来源标签（"酷我" / "LDDC"）
struct LyricsResult: Sendable {
    let lines: [LyricLine]
    let source: String

    var isEmpty: Bool { lines.isEmpty }
}

/// 取词失败的原因（给状态行显示，不甩英文异常）
enum LyricsError: Error, Equatable {
    case noCandidate        // 搜不到任何候选
    case tooFewLines        // 候选歌词残缺（<6 行）
    case broken             // 解密出来的文本是乱码
    case network(String)    // 网络层失败
    case decryptFailed      // 解密失败
}

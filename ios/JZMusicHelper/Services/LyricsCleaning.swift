import Foundation

// MARK: - 歌词文件头元数据
//
// 为什么单独抽一层：搜索接口给的候选时长经常是 0 或差几秒，光靠「标题 + 歌手」打分拦不住
// 「七里香 (Live)」这类同歌手同名的现场版（老板真机反馈：逐行时间总是对不上）。
// 而歌词文件自己（KRC/QRC/LRC）开头就写着 `[total:261000]` / `[length:04:21]`，
// 这才是**这份词**对应哪一版音频的直接证据。结构体放在文件级，是因为 `LddcLyrics`
// 取词后要把它带出来做「文件头验收」。
struct LyricsMeta: Equatable, Sendable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    /// 歌词文件自带的总时长（毫秒）：KRC 的 `[total:261000]`、LRC 的 `[length:04:21]` / `[length:261000]`、`[duration:...]`
    var durationMs: Int = 0
    /// `[offset:±N]`（毫秒），已由现有 lrcOffsetMs 的逻辑覆盖，这里同步带出来
    var offsetMs: Int = 0

    /// 有没有任何可用的头部信息。全空 = 元数据缺失，验收时要放行而不是丢弃（保持原行为）
    var hasHeader: Bool { !title.isEmpty || !artist.isEmpty || durationMs > 0 }
}

// MARK: - 歌词清洗与 LRC 解析
//
// 与 Android `LyricsService` 的 cleanArtist / isBrokenLyrics / cleanLine / parseLrc / indexAt 同口径。
// 这一层的存在原因：三个源的歌词格式差得远（普通 LRC、酷我 LRC、KRC/QRC 明文），
// 而渲染层只该看到「时间 + 干净的行文本 + 可选的逐字时间」。所有脏活在这里做完。
enum LyricsCleaning {

    // MARK: 歌手清洗

    /// 多艺人取第一个（"A20 LITE/A20" → "A20 LITE"），去掉分隔符
    static func cleanArtist(_ singer: String) -> String {
        let parts = singer.split(whereSeparator: { "/／、,，;；".contains($0) })
        return parts.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    // MARK: 歌词文件头元数据

    /// 头部标签：`[ti:...]` / `[ar:...]` / `[al:...]` / `[total:...]` / `[length:...]` 等。
    /// 大小写不敏感；值里不允许出现 `]`/换行，避免把歌词正文吞进来。
    /// QRC/KRC 还有 `[id:$...]` `[hash:...]` `[signature:...]` `[by:]` 之类的标签，
    /// 这里只挑我们认识的四个 key，其余一律忽略。
    private static let metaTag = Pattern.make(
        "\\[([A-Za-z][A-Za-z0-9_]*)\\s*:\\s*([^\\]\\r\\n]*)\\]", options: [.caseInsensitive])

    /// 解析歌词文件头元数据（纯函数）。缺失/非法一律给安全默认值，不 crash。
    ///
    /// 同一个 key 出现多次时只认第一个（头部标签在前，后面的多半是正文/翻译层）；
    /// `[offset:±N]` 交给已有的 `lrcOffsetMs` 解析，保持与 `parseLrc` 完全同口径。
    static func meta(_ text: String) -> LyricsMeta {
        var out = LyricsMeta()
        guard !text.isEmpty else { return out }
        let ns = text as NSString
        for m in metaTag.matches(in: text, range: NSRange(location: 0, length: ns.length))
        where m.numberOfRanges >= 3 {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            let value = ns.substring(with: m.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch key {
            case "ti":
                if out.title.isEmpty { out.title = stripArtistSuffix(value) }
            case "ar":
                if out.artist.isEmpty { out.artist = value }
            case "al":
                if out.album.isEmpty { out.album = value }
            case "total", "length", "duration":
                // 三种写法都见过：KRC 用 total、标准 LRC 用 length、个别源用 duration
                if out.durationMs == 0 { out.durationMs = parseMetaDurationMs(value) }
            default:
                break
            }
        }
        out.offsetMs = lrcOffsetMs(text)
        return out
    }

    /// 标题里的「- 歌手名」后缀（`[ti:七里香 - 周杰伦]` 是常见写法）要剥掉。
    /// 不剥的话拿它跟查询歌名算标题分会被歌手名拖低，反而把正确版本的词判成「不对版」。
    /// 只认带分隔符的写法，不碰 `Bling-Bling` 这种标题内部的连字符。
    private static let titleArtistSeparators = [" - ", " – ", " — ", " － ", "－", "—"]

    private static func stripArtistSuffix(_ title: String) -> String {
        for separator in titleArtistSeparators {
            guard let range = title.range(of: separator) else { continue }
            let head = String(title[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(title[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty && !tail.isEmpty { return head }
        }
        return title
    }

    /// 头部时长 → 毫秒。三种写法：
    ///   · `04:21` / `1:04:21`（可带小数秒）→ 按「时:分:秒」换算
    ///   · 纯数字 > 10000 → 直接当毫秒（KRC 的 `[total:261000]`）
    ///   · 纯数字 ≤ 10000 → 当秒（LRC 的 `[length:261]` 也有源这么写）
    /// `[length:04:21]` = 261s = 261000ms（这是老板点名的判版本依据）。
    private static func parseMetaDurationMs(_ raw: String) -> Int {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 0 }
        if text.contains(":") {
            let parts = text.split(separator: ":")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 || parts.count == 3 else { return 0 }
            var seconds = 0.0
            for part in parts {
                // 小数秒有的源用逗号当小数点
                guard let value = Double(part.replacingOccurrences(of: ",", with: ".")),
                      value >= 0 else { return 0 }
                seconds = seconds * 60 + value
            }
            return seconds > 0 ? Int((seconds * 1000).rounded()) : 0
        }
        guard let value = Double(text), value > 0 else { return 0 }
        return value > 10_000 ? Int(value.rounded()) : Int((value * 1000).rounded())
    }

    // MARK: 损坏判定

    /// 歌词损坏判定：含占位符/危险码点且**同时**含中文 → 损坏。
    ///
    /// 占位符集合：半角 `?`、全角 `？`、U+FFFD、U+FF3F、变体问号（U+FE56/U+FE16/U+2047）、
    /// BOM（U+FEFF）、几何符号全区块 U+25A0–U+25FF（安卓对未覆盖几何符号会渲成"菱形带问号"）、
    /// 私用区 U+E000–F8FF、专用区 U+FFF0–FFFD、代理区 U+D800–DFFF、非字符 U+FFFE/FFFF。
    ///
    /// 只做占位符检测，**不做繁体推断**——粤语/台版歌词是合法的，误判会整首丢词。
    static func isBroken(_ text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        var hasBad = false
        var hasCJK = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0x4E00 && v <= 0x9FFF { hasCJK = true }
            if isBadScalar(v) { hasBad = true }
            if hasBad && hasCJK { return true }
        }
        return false
    }

    private static func isBadScalar(_ v: UInt32) -> Bool {
        switch v {
        case 0x3F, 0xFF1F, 0xFFFD, 0xFF3F, 0xFE56, 0xFE16, 0x2047, 0xFEFF,
             0xFFFE, 0xFFFF:
            return true
        case 0x25A0...0x25FF, 0xE000...0xF8FF, 0xFFF0...0xFFFD, 0xD800...0xDFFF:
            return true
        default:
            return false
        }
    }

    // MARK: 单行清洗

    /// 单行歌词清洗：繁转简 → 剔占位符/危险码点/控制字符 → 含 `<` 的 KRC 碎片行整行丢弃。
    /// 返回 "" 表示该行不可用。
    static func cleanLine(_ raw: String) -> String {
        let simp = TradToSimpMap.toSimplified(raw)
        var out = String()
        out.reserveCapacity(simp.count)
        for scalar in simp.unicodeScalars {
            let v = scalar.value
            if isBadScalar(v) { continue }
            if v < 0x20 || v == 0x7F { continue }
            out.unicodeScalars.append(scalar)
        }
        // KRC 解析失败会留下 `<数字,数字,数字>` 之类的碎片；正常歌词不会有 `<`
        if out.contains("<") { return "" }
        // 中文歌词里出现的 "?" 基本是解码失败的占位符，直接抹掉
        if out.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
            out = out.replacingOccurrences(of: "?", with: "").replacingOccurrences(of: "？", with: " ")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: LRC 解析

    private static let timeTag = Pattern.make(
        "\\[(\\d{1,2}):(\\d{1,2})(?:\\.(\\d{1,3}))?\\]")

    /// LRC 头部的时间轴校正标签 `[offset:+500]`（毫秒）。
    ///
    /// 通行口径：正数 = 歌词**提前**显示。以前完全没解析这个标签，
    /// 带 offset 的那些歌词源会整体偏 0.2~1 秒，用户怎么调设置都对不齐。
    private static let offsetTag = Pattern.make(
        "\\[offset:\\s*([+-]?\\d+)\\s*\\]", options: [.caseInsensitive])

    static func lrcOffsetMs(_ lrc: String) -> Int {
        let ns = lrc as NSString
        guard let m = offsetTag.firstMatch(in: lrc, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return 0 }
        return Int(ns.substring(with: m.range(at: 1))) ?? 0
    }

    /// 点某一句歌词时要跳到的播放位置（毫秒）= 行时间 − 用户偏移。
    /// 这样跳完以后 `indexAt(位置 + 偏移)` 正好落在这一行上，高亮不会串到下一句。
    static func seekTargetMs(lineMs: Int, userOffsetMs: Int) -> Int {
        max(0, lineMs - userOffsetMs)
    }

    /// 解析 LRC 文本为时间戳行。
    /// 注意 `[mm:ss.xxx]` 的 `xxx` 是**毫秒**（三位小数秒），不能乘 10 当"十进制小数"用——
    /// Android 那边曾经踩过，这里直接按毫秒处理。
    static func parseLrc(_ lrc: String) -> [LyricLine] {
        guard !lrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let offset = lrcOffsetMs(lrc)
        var out: [LyricLine] = []
        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let ns = line as NSString
            let matches = timeTag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var times: [Int] = []
            for m in matches where m.numberOfRanges >= 3 {
                let minStr = ns.substring(with: m.range(at: 1))
                let secStr = ns.substring(with: m.range(at: 2))
                var fracStr = ""
                if m.numberOfRanges > 3, m.range(at: 3).location != NSNotFound {
                    fracStr = ns.substring(with: m.range(at: 3))
                }
                let minutes = Int(minStr) ?? 0
                let seconds = Int(secStr) ?? 0
                // 补足/截断到 3 位再当毫秒
                let frac = Int(fracStr.padding(toLength: 3, withPad: "0", startingAt: 0).prefix(3)) ?? 0
                times.append(minutes * 60_000 + seconds * 1000 + frac)
            }
            // 一行可能有多个时间戳（`[00:01.00][00:05.00]同一句词`）
            guard let closeBracket = line.lastIndex(of: "]") else { continue }
            let text = String(line[line.index(after: closeBracket)...])
            let cleaned = cleanLine(text)
            guard !cleaned.isEmpty else { continue }
            for t in times {
                // `[offset:+500]` = 歌词提前 500ms → 每条时间戳减 500
                out.append(LyricLine(timeMs: max(0, t - offset), text: cleaned))
            }
        }
        return out.sorted { $0.timeMs < $1.timeMs }
    }

    // MARK: 时间轴对齐

    /// 把歌词时间轴按**音源实际时长**线性对齐（纯函数），返回 (对齐后的行, 拉伸比例)。
    ///
    /// ## r66 根因修复：**只有拿到「歌词自己写的总长」才允许拉伸**
    ///
    /// r63 加这个函数时，为了"不同剪辑版本（Live / 不同专辑）总长差 8~40 秒"把时间轴整体缩放一遍。
    /// 但绝大多数歌词源（酷我官方、LRC）**根本没有总长字段**，于是退化成
    /// 「总长 = 最后一行时间 + 3 秒」——而真实歌曲几乎都有一段尾奏（10~30 秒）。
    /// 结果就是：**一首完全正常的歌也被"拉长"**，而且误差随时间线性变大：
    ///
    ///   实测《那天下雨了》：最后一行 208s + 3s = 211s，元数据时长 224s
    ///   → ratio = 224/211 = 1.06（播放页顶部当时就写着「已对齐 ×1.06」）
    ///   → 60s 处晚 3.6 秒、120s 处晚 7.2 秒、200s 处晚 12 秒
    ///
    /// 这就是老板三轮都说的"歌词滚动晚了一些"的真正原因——高亮口径一直是对的，
    /// 是**词的时间轴被整体拉长了**。所以现在的口径：
    ///
    ///   · `declaredMs <= 0`（歌词源没写总长，酷我/LRC 都是这种）→ **一律不拉伸**
    ///   · `declaredMs > 0`（KRC/QRC 文件头真写了 total）→ 才按比例对齐，且窗口收紧到 0.88…1.12、
    ///     偏差 ≥ 3% 才动（超过 12% 就更可能是完全另一首歌，宁可不动）
    static func alignedToAudio(_ lines: [LyricLine], declaredMs: Int, audioSec: Int)
        -> (lines: [LyricLine], ratio: Double) {
        guard !lines.isEmpty, audioSec > 0, declaredMs > 0 else { return (lines, 1) }
        let audioMs = Double(audioSec) * 1_000
        let total = Double(declaredMs)
        guard total > 0 else { return (lines, 1) }
        let ratio = audioMs / total
        guard ratio >= 0.88, ratio <= 1.12, abs(ratio - 1) >= 0.03 else { return (lines, 1) }
        func scale(_ ms: Int) -> Int { Int((Double(ms) * ratio).rounded()) }
        let scaled = lines.map { line in
            LyricLine(timeMs: max(0, scale(line.timeMs)), text: line.text,
                      words: line.words.map {
                          LyricWord(text: $0.text, startMs: max(0, scale($0.startMs)),
                                    durMs: max(0, scale($0.durMs)))
                      })
        }
        return (scaled, ratio)
    }

    /// 两版歌词是不是"同一版"：行数相差不超过 ±25%。
    ///
    /// 用途（r68）：酷我官方词只有行级时间，我们想用 LDDC 的 KRC（逐字）去替换它；
    /// 但只允许"明显是同一首"的情况——行数差太多就说明是另一版词（多一段 rap、少了前奏），
    /// 那种情况宁可保留官方词，也不要把别人的逐字贴上来。
    static func lineCountsCompatible(_ reference: Int, _ candidate: Int) -> Bool {
        guard reference > 0, candidate > 0 else { return false }
        let ratio = Double(candidate) / Double(reference)
        return ratio >= 0.75 && ratio <= 1.25
    }

    /// 歌词正文第一两行自报的版本标签检查（纯函数）。
    ///
    /// KRC/QRC/LRC 的第一行经常就是 `歌名（版本）- 歌手`。老板 r69 那次《发如雪》的候选，
    /// 第一行明明白白写着「发如雪（醇享版）- 周杰伦 (Jay Chou)」，但当时只看文件头
    /// `[ti:]`/`[total:]`，正文这行没看。现在把它也当"版本证据"：
    /// 正文带了查询没有的版本标签 → 这份词视为另一个剪辑（仍可兜底，但排在通过的候选之后）。
    static func contentVersionRejection(lines: [LyricLine], queryTitle: String) -> String? {
        for line in lines.prefix(2) {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if LddcMatch.versionPenalty(queryTitle: queryTitle, candidateTitle: text) > 0 {
                return "正文首行「\(text)」带查询没有的版本标签"
            }
        }
        return nil
    }

    // MARK: 定位

    /// 当前播放位置对应的歌词行下标（没有则 -1）
    ///
    /// **与 Android `LyricsService.indexAt` 逐字一致**：`line.timeMs <= positionMs` 就切。
    /// 之前一版为了"等第一个字唱出来"改成了 `max(行时间, 第一个字起点)`，结果整体偏晚，
    /// 也被老板否了（"还是按 APK 的口径来"）。一个字都不改地照抄：
    /// 行时间是 KRC/QRC 的 `[start,dur]`，逐字时间只用来做行内染色，不参与切行。
    /// 用户偏移（±600ms）由调用方加进 positionMs，这里保持纯函数。
    static func indexAt(_ lines: [LyricLine], positionMs: Int) -> Int {
        guard !lines.isEmpty else { return -1 }
        var idx = -1
        for (i, line) in lines.enumerated() {
            if line.timeMs <= positionMs { idx = i } else { break }
        }
        return idx
    }

    /// 该被滚到屏幕中间的那一行——比"亮起来"的那一行**早 `leadMs`**。
    ///
    /// 为什么需要两个下标：高亮要准（行时间到就亮，见 `indexAt`），但滚动有动画，
    /// 等亮起来再滚，新的一行就在"已经开唱之后"才滑到中间（老板 r65：滚动晚了一些）。
    /// 播放页拿 `indexAt` 决定白字，拿这个决定 `scrollTo` 的目标。
    static func scrollAnchorIndex(_ lines: [LyricLine], positionMs: Int, leadMs: Int) -> Int {
        guard !lines.isEmpty else { return -1 }
        let lead = max(0, leadMs)
        return indexAt(lines, positionMs: positionMs + lead)
    }
}

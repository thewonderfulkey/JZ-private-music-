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

    /// 点歌词跳转后："播放头还没唱到被点的那一行"时要不要继续钉住它。
    ///
    /// 为什么需要（老板反复提的那件事：用歌词快进/后退之后，高亮和滚动"闪一下又退回上一句，从此不对"）：
    /// `AVPlayer.seek` 真机上常落到目标**之前**几百毫秒（关键帧对齐 / 远端流分段），
    /// 而 `indexAt` 的口径是「行时间 ≤ 位置」——位置比这一行早 1ms，推出来就是**上一句**。
    /// 于是"点下去高亮是对的（钉住），下一拍 ticker 又按位置算回上一句"，两者打架。
    ///
    /// 这条规则只做一件事：没走到被点那一行之前，继续钉住它；走到了就交还正常推导。
    /// **与歌曲无关**（不看平台/时长/是否逐字），所以所有歌表现一致。
    enum LyricSeekHold: Equatable {
        case hold
        case release
    }

    /// - Parameters:
    ///   - positionMs: 当前歌词位置（毫秒，**含**用户偏移）
    ///   - lineMs: 被点那一行的时间戳（毫秒）
    ///   - toleranceMs: 允许"提前多少毫秒仍算落点正确"；超过这个距离就不信这次钉住
    ///     （用户多半是拖了进度条/换歌，而不是落在目标前后）
    static func lyricSeekHoldDecision(positionMs: Int,
                                      lineMs: Int,
                                      toleranceMs: Int) -> LyricSeekHold {
        guard positionMs < lineMs else { return .release }   // 已经唱到这一行或更晚：交还推导
        return (lineMs - positionMs) <= max(0, toleranceMs) ? .hold : .release
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

    /// 时间轴**不再拉伸**（r74，老板口径：LRC 每句前的中括号时间戳就是该句出现的时刻，
    /// 除非 LRC 文件本身错，否则滚动必须与时间戳严格对应）。
    ///
    /// 历史：r63 为对齐「不同剪辑版本总长差 8~40 秒」加过按总长线性缩放（±12%），
    /// r66 收紧成「只有文件头写了 [total:] 才拉伸」。但它本质是**改时间戳**：
    /// 一首 200 秒的词拉 9%，100 秒处就偏 9 秒。既然口径是「时间戳即唯一依据」，这层一律不做。
    /// 保留函数签名（调用方与 SelfTest 都按这个名字），行为变成恒等，ratio 恒为 1。
    static func alignedToAudio(_ lines: [LyricLine], declaredMs: Int, audioSec: Int)
        -> (lines: [LyricLine], ratio: Double) {
        (lines, 1)
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

    /// 「这不是歌词，是字幕/口播稿」的硬证据（纯函数）。
    ///
    /// 老板 r73 那次的《发如雪》51 行「酷我」词，正文第一句是
    /// 「本字幕由QQ音乐独家AI字幕技术生成」，后面是专辑介绍口播——
    /// 它来自酷我里一条「发如雪 拍摄花絮」的专访视频。行数够、时间轴也有，
    /// 但它是**文案不是歌词**。这类正文一律拒收（宁可空着，也不放一段解说）。
    private static let commentaryMarkers = [
        "本字幕由", "字幕技术生成", "AI字幕", "本视频", "本节目由", "点击订阅",
        "关注我们的频道", "感谢观看", "未经授权禁止", "版权所有",
    ]

    static func commentaryReason(lines: [LyricLine]) -> String? {
        for line in lines.prefix(12) {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let hit = commentaryMarkers.first(where: { text.localizedCaseInsensitiveContains($0) }) {
                return "正文是字幕/文案而不是歌词（命中「\(hit)」）"
            }
        }
        return nil
    }

    /// 一份歌词正文能不能收：先看是不是文案，再看首行有没有自报别的版本。
    /// 所有"按歌名搜出来"的源（LRCLIB / 网易云 / 酷我官方词）都过同一个闸门。
    static func foreignVersionReason(lines: [LyricLine], queryTitle: String) -> String? {
        commentaryReason(lines: lines) ?? contentVersionRejection(lines: lines, queryTitle: queryTitle)
    }

    /// 词自报身份校验（r74）：文件头 `[ti:]/[ar:]`，或（没有头时）正文第一行的「歌名 - 歌手」。
    ///
    /// 老板口径：「`[ti:]`/`[ar:]` 或首行必须与播放曲一致（`发如雪 (粤语版) / 常颖杰`、
    /// `七里香 (Live)` 这类直接判废或按版本类路由）」。
    /// 为什么不能只信候选：酷狗里那条翻唱的 KRC 头写的是 `[ti:发如雪][ar:常颖杰]`——
    /// 歌名对得上，**歌手对不上**，正好被这一层抓住。
    /// 剥掉歌名里的括注：`富士山下 (《爱情转移》粤语版)` → `富士山下`。
    /// 只用于**歌名相似度**；版本类判断仍然看完整标题（`(Live)` 就在括注里）。
    static func coreTitle(_ title: String) -> String {
        let stripped = title.replacingOccurrences(of: "[（(][^）)]*[）)]", with: "",
                                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? title : stripped
    }

    static func selfReportReason(meta: LyricsMeta, firstLine: String?,
                                 songTitle: String, songArtist: String) -> String? {
        let title = songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = songArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !meta.artist.isEmpty, !artist.isEmpty {
            let a = LddcMatch.artistScore(artist, meta.artist)
            if a < LddcMatch.artistGateScore {
                return "词头 [ar:\(meta.artist)] 与播放歌手对不上（\(Int(a)) 分）"
            }
        }
        if !meta.title.isEmpty, !title.isEmpty {
            // 完整标题与剥括注后取较大分：`七里香 (Live)` 的括注里是关键版本词，剥掉反而对不上；
            // `富士山下 (《爱情转移》粤语版)` 的括注是注记，剥掉才对得上。
            let t = max(LddcMatch.titleScore(title, meta.title),
                        LddcMatch.titleScore(title, coreTitle(meta.title)))
            if t < LddcMatch.artistGateScore {
                return "词头 [ti:\(meta.title)] 与播放歌名对不上（\(Int(t)) 分）"
            }
            if LddcMatch.versionClass(meta.title, languageCounts: false)
                != LddcMatch.versionClass(title, languageCounts: false) {
                return "词头 [ti:\(meta.title)] 是另一个版本类"
            }
            return nil
        }
        // 没有头部标签：看首行是不是「歌名 - 歌手」
        guard let firstLine, !firstLine.isEmpty else { return nil }
        let separators = [" - ", " – ", " — ", "－", "-"]
        for sep in separators {
            guard let range = firstLine.range(of: sep) else { continue }
            let head = String(firstLine[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(firstLine[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !head.isEmpty, !tail.isEmpty else { continue }
            if !title.isEmpty,
               max(LddcMatch.titleScore(title, head),
                   LddcMatch.titleScore(title, coreTitle(head))) < LddcMatch.artistGateScore {
                return "首行「\(head)」与播放歌名对不上"
            }
            if !artist.isEmpty, LddcMatch.artistScore(artist, tail) < LddcMatch.artistGateScore {
                return "首行「\(tail)」与播放歌手对不上"
            }
            if LddcMatch.versionClass(head, languageCounts: false)
                != LddcMatch.versionClass(title, languageCounts: false) {
                return "首行「\(head)」是另一个版本类"
            }
            return nil
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

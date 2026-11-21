import Foundation

// MARK: - 下载旁车：歌词 / 封面
//
// 老板反馈 ⑧（真机原话）：「下载歌曲后，把歌词和封面也一起下载了，内嵌为一体，这样当
// 存在于无网络环境的时候点击下载后的歌曲也不至于只能听歌，没有歌词和封面；同理，当删除
// 的时候也要把封面和歌词也同时一一对应删掉。」
//
// 这一层做**双保险**，两条路都走，不是二选一：
//   ① 旁车文件：与音频同目录、同基名的 `.lrc` / `.jpg`。任何容器都能用；
//      播放页在离线时直接读它，不依赖任何标签解析能力。
//   ② 内嵌标签：m4a 走 AVFoundation metadata（iTunes 歌词键），mp3 走 ID3v2.4
//      （APIC 封面 + USLT 歌词，见 `id3Tag`）。文件被拷到别处、或旁车被误删，
//      词和图仍然跟着歌走。
//
// 为什么不是"只内嵌"或"只旁车"：
//   · 只旁车 → 用户把歌拷到别的机器/别的播放器，词图就丢了，"内嵌为一体"没做到；
//   · 只内嵌 → 读标签需要额外的解析与失败分支，而 flac/ogg/wav 没有统一可靠的写法；
//     旁车是零风险的兜底：写坏了最多是没词，绝不会动音频本身一个字节。
//
// 为什么 flac/ogg/wav 只写旁车：这些容器要么标签结构各家不同（FLAC 的 Vorbis Comment
// 要重算整条 metadata block 链），要么干脆没有标准封面位（WAV）。为了"能内嵌"去重写
// 容器头风险极高 —— 宁可少一个能力，也不能把能放的歌写坏。m4a/mp3 有成熟标准写法，
// 所以只对这两种内嵌（`canEmbed` 是唯一判定入口）。
//
// 本文件是**纯 Foundation**：它要进 CI 的 swiftc 纯逻辑自测清单，不能碰 AVFoundation。
// 内嵌那一步由 `AudioTagEmbedder` 负责，这里只产出标准 ID3 字节和可断言的纯函数结果。
enum DownloadCompanion {

    /// 一个音频文件写完旁车后的结果。
    /// `embedded` 不在这里决定（写旁车阶段还没内嵌），由调用方在内嵌后回填。
    struct Sidecars: Equatable {
        var lyricsURL: URL?
        var coverURL: URL?
        var embedded: Bool
    }

    // MARK: - 旁车路径
    //
    // 第四十轮补丁 3（老板："歌曲 / 歌词 / 封面各放一个文件夹"）：
    // 音频、`.lrc`、`.jpg` 不再挤在同一个目录，而是分成
    //   `文件 › JZ 音乐 › Download › Music` / `… › Lyrics` / `… › Cover`
    // 三个同级目录，**基名一致**（`A - B [QQ_cyapi]`），所以"哪个词/哪张图属于哪首歌"
    // 仍然只靠基名推导，不需要额外清单，删除时也天然一一对应。

    /// 音频文件的基名（去掉最后一个扩展名）
    static func baseName(for audio: URL) -> String {
        audio.deletingPathExtension().lastPathComponent
    }

    /// 歌词旁车路径：`<歌词目录>/<基名>.lrc`
    static func lyricsURL(in directory: URL, baseName: String) -> URL {
        directory.appendingPathComponent(baseName).appendingPathExtension("lrc")
    }

    /// 封面旁车路径：`<封面目录>/<基名>.jpg`
    /// 注意：扩展名固定 `.jpg` 只是"我们约定的旁车名"，实际字节可能是 PNG/WebP，
    /// iOS 的 `UIImage(data:)` 按内容解码，不看扩展名。
    static func coverURL(in directory: URL, baseName: String) -> URL {
        directory.appendingPathComponent(baseName).appendingPathExtension("jpg")
    }

    /// 旧版布局：旁车与音频同目录同基名（升级前的下载都是这样）。
    /// 只用于**兼容读取**与清理，新下载不再往这里写。
    static func legacyLyricsURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("lrc")
    }

    static func legacyCoverURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("jpg")
    }

    // MARK: - 写旁车

    /// 写旁车（歌词文本 → 歌词目录，封面二进制 → 封面目录）。
    ///
    /// 约束：
    ///   · 任何一项为 nil/空 → 该项不写，返回 nil（"没拿到"和"写了空文件"必须能区分）；
    ///   · 写失败（目录不可写、磁盘满）→ 该项返回 nil，**不抛错**；
    ///     补料是下载完成后的附加价值，不能因为写旁车失败把整条下载标成失败；
    ///   · 已存在的旧旁车不会被 nil 覆盖删除：同一首歌重下时，上一次的歌词/封面
    ///     依然是这首歌的，留着比删掉更安全（真删只发生在 `removeSidecars`）。
    ///
    /// 不主动创建目录：这两个目录由 `DownloadLocation` 的 `lyricsDirectory()` /
    /// `coverDirectory()` 保证存在；凭空创建只会把"路径算错了"这种 bug 藏起来。
    static func writeSidecars(audio: URL,
                              lyricsText: String?,
                              coverData: Data?,
                              lyricsDirectory: URL,
                              coverDirectory: URL) -> Sidecars {
        var result = Sidecars(lyricsURL: nil, coverURL: nil, embedded: false)
        let base = baseName(for: audio)

        if let lyricsText, !lyricsText.isEmpty {
            let url = lyricsURL(in: lyricsDirectory, baseName: base)
            // .atomic：先写临时文件再 rename，播放端不会读到写了一半的歌词
            if let data = lyricsText.data(using: .utf8),
               (try? data.write(to: url, options: .atomic)) != nil {
                result.lyricsURL = url
            }
        }

        if let coverData, !coverData.isEmpty {
            let url = coverURL(in: coverDirectory, baseName: base)
            if (try? coverData.write(to: url, options: .atomic)) != nil {
                result.coverURL = url
            }
        }

        return result
    }

    // MARK: - 读旁车（离线播放）

    /// 在给定目录里按顺序找歌词旁车并解析成行级时间轴；找不到再回退旧版"音频同目录"。
    /// 文件不存在/为空/解析不出行 → nil（空数组会把"没词"和"有词但坏了"混成一件事）。
    static func readLyrics(from audio: URL, in directories: [URL]) -> [LyricLine]? {
        let base = baseName(for: audio)
        var candidates = directories.map { lyricsURL(in: $0, baseName: base) }
        candidates.append(legacyLyricsURL(for: audio))
        for url in candidates {
            guard let data = try? Data(contentsOf: url), !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { continue }
            if let lines = parseLRC(text) { return lines }
        }
        return nil
    }

    /// 在给定目录里按顺序找封面旁车字节；找不到再回退旧版"音频同目录"。
    static func readCover(from audio: URL, in directories: [URL]) -> Data? {
        let base = baseName(for: audio)
        var candidates = directories.map { coverURL(in: $0, baseName: base) }
        candidates.append(legacyCoverURL(for: audio))
        for url in candidates {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        }
        return nil
    }

    /// LRC 文本 → 行级时间轴（兼容读取用）
    private static func parseLRC(_ text: String) -> [LyricLine]? {
        var text = text
        // 我们自己写的是无 BOM UTF-8；仍容忍 BOM，避免用户用记事本编辑过的文件首行解析失败
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        var lines: [LyricLine] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() } // CRLF 的 \r

            // 一行可以带多个时间标签：`[00:01.00][00:05.00]同一句词`
            var cursor = line.startIndex
            var times: [Int] = []
            while cursor < line.endIndex, line[cursor] == "[" {
                guard let close = line[cursor...].firstIndex(of: "]") else { break }
                let tag = String(line[line.index(after: cursor)..<close])
                // 只认时间标签：像 `[ti:...]` / 歌词正文里的 `[笑]` 都不消费，
                // 否则正文开头的方括号会被当成标签吃掉
                guard let ms = parseTimeTag(tag) else { break }
                times.append(ms)
                cursor = line.index(after: close)
            }
            guard !times.isEmpty else { continue }

            let body = String(line[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            for ms in times {
                lines.append(LyricLine(timeMs: max(0, ms), text: body))
            }
        }

        guard !lines.isEmpty else { return nil }
        return lines.sorted { $0.timeMs < $1.timeMs }
    }

    // MARK: - 删旁车

    /// 删除旁车（音频被删时调用）。新位置 + 旧版位置一起清，文件不存在也算成功，不抛错。
    ///
    /// 为什么必须和音频删除绑在一起：老板要的是"一一对应地删"。
    /// 只删音频会留下"没有歌的歌词/封面"孤儿文件，用户下次搜索又下载同一首时
    /// 还会读到上一份旧旁车 —— 比不删更糟。
    static func removeSidecars(audio: URL, lyricsDirectory: URL, coverDirectory: URL) {
        let fm = FileManager.default
        let base = baseName(for: audio)
        try? fm.removeItem(at: lyricsURL(in: lyricsDirectory, baseName: base))
        try? fm.removeItem(at: coverURL(in: coverDirectory, baseName: base))
        try? fm.removeItem(at: legacyLyricsURL(for: audio))
        try? fm.removeItem(at: legacyCoverURL(for: audio))
    }

    // MARK: - LRC 文本

    /// 歌词数组 → LRC 文本（离线"至少能看词"用，精度按行）。
    ///
    /// 逐字时间（`LyricLine.words`）**不落 LRC**：LRC 标准没有可靠的逐字语法，
    /// 各家私有扩展（`<mm:ss.xx>`）播放器支持不一，写进去只会让第三方播放器显示乱码。
    /// 内嵌/旁车只需要"某一行在什么时候出现"，逐字染色在 App 内仍由歌词服务提供。
    ///
    /// 头部字段：`[ti:]` 标题、`[ar:]` 歌手、`[al:]` 专辑、`[length:]` 总时长。
    /// 本函数签名里没有专辑参数（按老板给的 API 定死），所以 `[al:]` 保持为空标签；
    /// 专辑名仍会写进音频的 TALB / 内嵌 metadata，不会丢。
    ///
    /// 空文本行会被跳过：旁车是给"离线看词"用的，保留一串只有时间戳的空行没有意义；
    /// 跳过也更便于自测做「写出去 → 读回来」的往返断言。
    static func lrcText(from lines: [LyricLine], title: String, artist: String, durationSec: Int) -> String {
        var out = ""
        out += "[ti:\(metadataValue(title))]\n"
        out += "[ar:\(metadataValue(artist))]\n"
        out += "[al:]\n"
        let total = max(0, durationSec)
        out += "[length:\(pad2(total / 60)):\(pad2(total % 60))]\n"

        // 按时间排序并用原始下标破同分：输出稳定，自测才能逐行断言
        let ordered = lines.enumerated().sorted { lhs, rhs in
            if lhs.element.timeMs == rhs.element.timeMs { return lhs.offset < rhs.offset }
            return lhs.element.timeMs < rhs.element.timeMs
        }
        for pair in ordered {
            let text = lineText(pair.element.text)
            guard !text.isEmpty else { continue }
            let ms = max(0, pair.element.timeMs)
            let minutes = ms / 60_000
            let seconds = (ms / 1_000) % 60
            // `[mm:ss.xx]`：xx 是百分秒（毫秒/10），标准 LRC 的两位小数口径
            let centis = (ms % 1_000) / 10
            out += "[\(pad2(minutes)):\(pad2(seconds)).\(pad2(centis))]\(text)\n"
        }
        return out
    }

    // MARK: - ID3v2.4（mp3 内嵌）

    /// 生成 mp3 的完整 ID3v2.4 前置字节（纯函数，便于逐字节断言）。
    ///
    /// 字节布局（**所有长度都是 syncsafe**：4 字节，每字节只用低 7 位）：
    ///
    /// ```text
    /// ID3 头（10 字节）
    ///   0..2  "ID3"
    ///   3     主版本 0x04
    ///   4     修订号 0x00
    ///   5     标志   0x00（无 unsynchronisation / 无扩展头 / 无 footer）
    ///   6..9  帧区总长度（syncsafe）= 下面所有帧的字节数之和
    ///
    /// 每个帧头（10 字节）
    ///   0..3  帧 ID：TIT2 标题 / TPE1 歌手 / TALB 专辑 / APIC 封面 / USLT 歌词
    ///   4..7  帧体长度（syncsafe；ID3v2.3 及以前这里是普通 32 位大端）
    ///   8..9  帧标志 0x0000
    ///
    /// 帧体
    ///   TIT2/TPE1/TALB：0x03(UTF-8) + 文本
    ///   APIC           ：0x03 + MIME + 0x00 + 0x03(front cover) + 空描述 + 0x00 + 图片字节
    ///   USLT           ：0x03 + "zho"(ISO 639-2 中文) + 空描述符 + 0x00 + 歌词
    /// ```
    ///
    /// 两个刻意的选择：
    ///   · 不写 padding：解码方按头里的长度读，有没有 padding 都能读；不写 padding
    ///     让自测可以断言「返回值 = 头 + 帧」正好等于算出来的长度。
    ///   · 空值跳过对应帧（没有封面就不写 APIC、没有歌词就不写 USLT、标题为空就不写 TIT2），
    ///     避免写出"有帧但内容为空"的脏标签。
    static func id3Tag(title: String, artist: String, album: String,
                       coverData: Data?, coverMime: String, lyrics: String) -> Data {
        var frames = Data()

        addTextFrame("TIT2", title, to: &frames)
        addTextFrame("TPE1", artist, to: &frames)
        addTextFrame("TALB", album, to: &frames)

        if let coverData, !coverData.isEmpty {
            var payload = Data([0x03]) // 文本编码：UTF-8
            payload.append(contentsOf: Array(normalizedMime(coverMime).utf8))
            payload.append(0x00) // MIME 以 \0 结束
            payload.append(0x03) // 图片类型：3 = front cover（音频文件正封面）
            payload.append(0x00) // 描述为空串，紧跟结束符
            payload.append(coverData)
            frames.append(frame("APIC", payload))
        }

        let lyricsText = frameText(lyrics)
        if !lyricsText.isEmpty {
            var payload = Data([0x03]) // 文本编码：UTF-8
            payload.append(contentsOf: Array("zho".utf8)) // 语言：中文
            payload.append(0x00) // 内容描述符为空串
            payload.append(contentsOf: Array(lyricsText.utf8))
            frames.append(frame("USLT", payload))
        }

        var tag = Data()
        tag.append(contentsOf: Array("ID3".utf8))
        tag.append(contentsOf: [0x04, 0x00, 0x00]) // v2.4.0，无标志位
        tag.append(contentsOf: syncsafe(frames.count))
        tag.append(frames)
        return tag
    }

    /// 这个扩展名能不能内嵌标签。
    ///
    /// m4a/mp4：AVFoundation metadata（`AudioTagEmbedder.embedM4A`）
    /// mp3    ：ID3v2.4（`AudioTagEmbedder.embedMP3`）
    /// 其它（flac/ogg/wav…）：不能，只能写旁车 —— 理由见文件头注释。
    static func canEmbed(extension ext: String) -> Bool {
        var e = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        switch e {
        case "m4a", "mp4", "mp3":
            return true
        default:
            return false
        }
    }

    // MARK: - 只换封面（内嵌封面替换 / 追加）
    //
    // 老板 2026-11-22 原话：「我已经把导入的歌曲所有封面都替换内置了，那么本地的后台文件
    // 封面并没有和前端内置的对齐，我希望对齐：自动把内置的封面下载下来替换原有文件中该歌曲
    // 的封面，如果该歌曲后台文件中没有封面那么直接添加进去并建联就行了。」
    //
    // 这一步的立场是「**只动封面那一帧**」：
    //   · 除 APIC 以外的帧（TIT2 / TPE1 / TALB / USLT…）原样搬 → 别人写的字段、内嵌歌词一个不丢；
    //   · 音频体（标签之后的所有字节）**一个字节不改** → "能不能放"这件事天然不变；
    //   · 无法安全解析（v2.2 / 带 unsynchronisation / 扩展头 / footer / 帧长度越界）→ 返回 nil，
    //     调用方保持原文件不动。宁可不换封面，也不写坏一首能放的歌。
    //
    // 为什么不复用上面 `id3Tag(...)` 整条重建：那条路只写 TIT2/TPE1/TALB/APIC/USLT，
    // 这次若只取到封面、没取到词，文件里原有的 USLT 就被顺手抹掉了（"对齐封面"不该删歌词）。
    enum ID3Artwork {

        /// 文件里已内嵌的第一张封面（优先 front cover，type = 3）。
        /// 只用于「这张图和前端那张是不是同一张」：相同就跳过重写，662 首里能省多少省多少。
        static func image(inFileData data: Data) -> Data? {
            guard let tag = tagInfo(data) else { return nil }
            let bytes = [UInt8](data)
            guard let list = frames(bytes, tag: tag) else { return nil }
            var fallback: Data?
            for frame in list where frame.id == "APIC" {
                guard let parsed = parseAPIC(bytes, body: frame.body) else { continue }
                if parsed.type == 3 { return Data(bytes[parsed.image]) }
                if fallback == nil { fallback = Data(bytes[parsed.image]) }
            }
            return fallback
        }

        /// 有没有内嵌封面（"替换"和"新增"要分开计数，老板要能看出到底补进去了几张）
        static func hasImage(inFileData data: Data) -> Bool {
            image(inFileData: data) != nil
        }

        /// 把封面替换 / 追加进文件，返回**完整的新文件字节**；无法安全处理 → nil。
        static func replacing(inFileData data: Data, cover: Data, mime: String) -> Data? {
            guard !cover.isEmpty else { return nil }

            guard let tag = tagInfo(data) else {
                // 没有 ID3v2 标签 → 造一条只含 APIC 的 v2.4 标签前置，音频体原样跟在后面。
                // 但"开头是 ID3 却解析不了"（v2.2 / unsync / 长度越界）不能走这条路：
                // 那会在旧标签前面再糊一条新标签，两个标签叠着，解码方读哪个都不算错。
                guard !startsWithID3(data) else { return nil }
                let frame = apicFrame(cover: cover, mime: mime, version: 4)
                var out = tagHeader(version: 4, framesLength: frame.count)
                out.append(frame)
                out.append(data)
                return out
            }

            let bytes = [UInt8](data)
            guard let list = frames(bytes, tag: tag) else { return nil }
            var kept = Data()
            for frame in list where frame.id != "APIC" && frame.id != "PIC" {
                kept.append(data.subdata(in: frame.start..<frame.end))
            }
            kept.append(apicFrame(cover: cover, mime: mime, version: tag.version))

            var out = tagHeader(version: tag.version, framesLength: kept.count)
            out.append(kept)
            out.append(data.subdata(in: tag.end..<data.count))
            return out
        }

        // MARK: 解析

        private struct Tag {
            var version: UInt8
            var framesStart: Int
            var end: Int
        }

        private struct Frame {
            var id: String
            var start: Int
            var end: Int
            var body: Range<Int> { (start + 10)..<end }
        }

        private static func startsWithID3(_ data: Data) -> Bool {
            guard data.count >= 3 else { return false }
            let head = [UInt8](data.prefix(3))
            return head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33
        }

        /// 解析标签头。只认 v2.3 / v2.4 且**无** unsync / 扩展头 / footer：
        /// 这几种会让"帧起点"整体偏移，重排标签等于赌解码器怎么猜，不如干脆不动。
        private static func tagInfo(_ data: Data) -> Tag? {
            guard startsWithID3(data), data.count >= 10 else { return nil }
            let head = [UInt8](data.prefix(10))
            let version = head[3]
            guard version == 3 || version == 4 else { return nil }
            let flags = head[5]
            guard flags & 0x80 == 0, flags & 0x40 == 0 else { return nil }
            if version >= 4, flags & 0x10 != 0 { return nil }
            let size = syncsafeValue(head, at: 6)
            guard size >= 0, 10 + size <= data.count else { return nil }
            return Tag(version: version, framesStart: 10, end: 10 + size)
        }

        /// 逐帧走一遍，返回全部帧的范围；padding（全 0）之后停止；长度越界 → nil（不敢改）。
        private static func frames(_ bytes: [UInt8], tag: Tag) -> [Frame]? {
            var out: [Frame] = []
            var i = tag.framesStart
            while i + 10 <= tag.end {
                guard let id = frameID(bytes, at: i) else { break } // 全 0 = padding 区
                guard let size = frameSize(bytes, at: i, version: tag.version), size >= 0 else { return nil }
                let end = i + 10 + size
                guard end <= tag.end else { return nil }
                out.append(Frame(id: id, start: i, end: end))
                i = end
            }
            return out
        }

        /// 帧 ID：4 个 A-Z / 0-9；第一个字节是 0 → padding，返回 nil（调用方停止扫描）
        private static func frameID(_ bytes: [UInt8], at index: Int) -> String? {
            guard index + 4 <= bytes.count else { return nil }
            var chars: [UInt8] = []
            for k in 0..<4 {
                let b = bytes[index + k]
                guard (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39) else { return nil }
                chars.append(b)
            }
            return String(decoding: chars, as: UTF8.self)
        }

        private static func frameSize(_ bytes: [UInt8], at index: Int, version: UInt8) -> Int? {
            guard index + 10 <= bytes.count else { return nil }
            if version >= 4 { return syncsafeValue(bytes, at: index + 4) }
            let v = (Int(bytes[index + 4]) << 24) | (Int(bytes[index + 5]) << 16)
                | (Int(bytes[index + 6]) << 8) | Int(bytes[index + 7])
            return v >= 0 ? v : nil
        }

        private static func syncsafeValue(_ bytes: [UInt8], at index: Int) -> Int {
            guard index + 3 < bytes.count else { return -1 }
            return (Int(bytes[index] & 0x7F) << 21)
                | (Int(bytes[index + 1] & 0x7F) << 14)
                | (Int(bytes[index + 2] & 0x7F) << 7)
                | Int(bytes[index + 3] & 0x7F)
        }

        /// APIC 帧体 → (图片类型, 图片字节范围)
        /// 帧体布局：编码 1B + MIME\0 + 图片类型 1B + 描述\0 + 图片
        private static func parseAPIC(_ bytes: [UInt8], body: Range<Int>)
            -> (type: UInt8, image: Range<Int>)? {
            var i = body.lowerBound
            guard i < body.upperBound else { return nil }
            let encoding = bytes[i]
            i += 1
            while i < body.upperBound, bytes[i] != 0x00 { i += 1 } // MIME
            guard i < body.upperBound else { return nil }
            i += 1
            guard i < body.upperBound else { return nil }
            let pictureType = bytes[i]
            i += 1
            if encoding == 1 || encoding == 2 {
                // UTF-16 描述：双字节对齐，找 0x00 0x00
                while i + 1 < body.upperBound {
                    if bytes[i] == 0x00, bytes[i + 1] == 0x00 { i += 2; break }
                    i += 2
                }
            } else {
                while i < body.upperBound, bytes[i] != 0x00 { i += 1 }
                guard i < body.upperBound else { return nil }
                i += 1
            }
            guard i < body.upperBound else { return nil }
            return (pictureType, i..<body.upperBound)
        }

        // MARK: 生成

        private static func apicFrame(cover: Data, mime: String, version: UInt8) -> Data {
            // v2.3 的标准里没有 UTF-8（只有 0/1），但这里描述是空串 —— 用 0x00 就完全合规；
            // v2.4 用 0x03（UTF-8）。两种情况描述都不占字节，所以不存在编码风险。
            var payload = Data([version >= 4 ? 0x03 : 0x00])
            payload.append(contentsOf: Array(normalizedMime(mime).utf8))
            payload.append(0x00) // MIME 结束
            payload.append(0x03) // 图片类型：3 = front cover
            payload.append(0x00) // 描述为空串
            payload.append(cover)
            return frameWith("APIC", payload, version: version)
        }

        private static func frameWith(_ id: String, _ payload: Data, version: UInt8) -> Data {
            var data = Data()
            let idBytes = Array(id.utf8)
            guard idBytes.count == 4 else { return data }
            data.append(contentsOf: idBytes)
            if version >= 4 {
                data.append(contentsOf: syncsafe(payload.count))
            } else {
                let size = max(0, min(payload.count, Int(Int32.max)))
                data.append(contentsOf: [UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
                                         UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
            }
            data.append(contentsOf: [0x00, 0x00]) // 帧标志
            data.append(payload)
            return data
        }

        private static func tagHeader(version: UInt8, framesLength: Int) -> Data {
            var head = Data()
            head.append(contentsOf: Array("ID3".utf8))
            head.append(contentsOf: [version, 0x00, 0x00])
            head.append(contentsOf: syncsafe(framesLength))
            return head
        }
    }

    // MARK: - ID3 内部

    private static func addTextFrame(_ id: String, _ value: String, to frames: inout Data) {
        let text = frameText(value)
        guard !text.isEmpty else { return }
        var payload = Data([0x03]) // 文本编码：UTF-8
        payload.append(contentsOf: Array(text.utf8))
        frames.append(frame(id, payload))
    }

    /// 一个 ID3v2.4 帧：4 字节 ID + syncsafe 长度 + 2 字节标志 + 帧体。
    private static func frame(_ id: String, _ payload: Data) -> Data {
        var data = Data()
        let idBytes = Array(id.utf8)
        // 帧 ID 必须是 4 个 ASCII 字符；长度不对就返回空帧（宁可少一个标签，也不写坏帧链）
        guard idBytes.count == 4 else { return data }
        data.append(contentsOf: idBytes)
        data.append(contentsOf: syncsafe(payload.count))
        data.append(contentsOf: [0x00, 0x00]) // 帧标志：无压缩/加密/分组
        data.append(payload)
        return data
    }

    /// syncsafe 整数：ID3v2.4 用 4 个字节、每字节 7 位表示长度（最大 256MB）。
    /// 超出就钳位 —— 真正的封面/歌词远到不了这个量级，钳位只为"绝不写坏头"。
    private static func syncsafe(_ value: Int) -> [UInt8] {
        let v = max(0, min(value, 0x0FFF_FFFF))
        return [
            UInt8((v >> 21) & 0x7F),
            UInt8((v >> 14) & 0x7F),
            UInt8((v >> 7) & 0x7F),
            UInt8(v & 0x7F),
        ]
    }

    /// 帧文本清洗：UTF-8 帧一旦含 NUL 会被解码方当终止符截断，直接去掉；
    /// 首尾空白去掉（内嵌标题不该带换行），中间换行保留（歌词需要）。
    private static func frameText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// APIC 的 MIME 必须是 ASCII；调用方没给/给错时退回 JPEG（封面绝大多数是 JPEG）。
    private static func normalizedMime(_ raw: String) -> String {
        let mime = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !mime.isEmpty, mime.contains("/"),
              mime.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F })
        else { return "image/jpeg" }
        return mime
    }

    // MARK: - LRC 内部

    /// 解析一个时间标签（不含方括号），如 `01:23.45` / `00:05` / `123:04.567`。
    /// 返回毫秒；不是时间标签（`ti`/`ar`/歌词正文 `笑`）→ nil，调用方据此停止消费。
    private static func parseTimeTag(_ tag: String) -> Int? {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Int(parts[0]), minutes >= 0, minutes < 100_000 else { return nil }

        var secondsPart = String(parts[1])
        var fraction = ""
        if let dot = secondsPart.firstIndex(of: ".") {
            fraction = String(secondsPart[secondsPart.index(after: dot)...])
            secondsPart = String(secondsPart[..<dot])
        }
        guard let seconds = Int(secondsPart), seconds >= 0 else { return nil }

        // `[mm:ss.xx]` 的两位是百分秒，`[mm:ss.xxx]` 是毫秒：统一补/截成 3 位再当毫秒，
        // 这样写出去 .xx 读回来 .xxx 不会整体偏 10 倍（Android 那边踩过这个坑）
        var msText = fraction
        if msText.count > 3 { msText = String(msText.prefix(3)) }
        while msText.count < 3 { msText += "0" }
        let ms = Int(msText) ?? 0
        return minutes * 60_000 + seconds * 1_000 + ms
    }

    /// LRC 头部的值：去掉换行与方括号，避免破坏 `[ti:...]` 这类单行标签
    private static func metadataValue(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 歌词正文单行化（LRC 一行就是一句，内嵌换行会让行时间对不上）
    private static func lineText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 两位补零（不用 String(format:)，避免依赖 locale/格式化口径）
    private static func pad2(_ value: Int) -> String {
        let v = max(0, value)
        return v < 10 ? "0\(v)" : "\(v)"
    }
}

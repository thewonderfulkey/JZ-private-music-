import Compression
import Foundation

// MARK: - zlib 解压
//
// 用 Compression 框架的流式接口而不是一次性 `compression_decode_buffer`：
// 真实 KRC/QRC 解出来的 zlib 流后面跟的是补零（8 字节对齐），一次性接口遇到尾部多余字节会判失败，
// 流式接口在 COMPRESSION_STATUS_END 处就能干净收尾。
enum Zlib {

    static func inflate(_ data: Data, maxOutput: Int = 8 * 1024 * 1024) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = compression_stream()
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { return nil }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = data.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = bufferSize - stream.dst_size
                    if produced > 0 {
                        output.append(buffer, count: produced)
                        if output.count > maxOutput { return nil }
                    }
                    if status == COMPRESSION_STATUS_END { return output }
                    // 输入耗尽且没有产出 → 数据被截断，别死循环
                    if stream.src_size == 0 && produced == 0 { return nil }
                default:
                    return nil
                }
            }
        }
    }
}

// MARK: - 酷狗 KRC / QQ QRC 解密与逐字解析
//
// 算法移植自 chenmozhijin/LDDC（GPL-3.0），与 Android `LddcCrypto.kt` 同一套：
//   · KRC：跳 4 字节头 + 逐字节 XOR + zlib 解压
//   · QRC：hex 解码 + **QQ 专用 3DES** 解密 + zlib 解压
//
// 为什么 3DES 要自己写：QQ 用的是 QQMusicDecoder 的非标准 DES 变体（S 盒输入位序反转），
// 与系统 CommonCrypto 的 DESede 不互认（Android 侧用 120 组随机向量验证过双向不一致）。
// 所以这里是从 LDDC 完整移植的软件实现，**不要**图省事换成 CCCrypt。
//
// 验证：`ios/SelfTest` 里有真实酷狗 KRC 样本（4192 字节密文 → 63 行逐字歌词）、
// 合成的 KRC/QRC 样本，以及 6 组 DES 加解密向量（由 Python 独立实现生成）。
enum LddcCrypto {

    // MARK: 密钥

    private static let krcKey: [UInt8] = [
        0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47,
        0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69,
    ]

    private static let qrcKey: [UInt8] = Array("!@#)(*$%123ZXC!@!@#)(NHL".utf8)

    // MARK: KRC

    /// 解密酷狗 KRC（输入为 lyrics.kugou.com/download 返回 content 的 base64 解码字节）
    static func krcDecrypt(_ encrypted: [UInt8]) -> String? {
        let body = encrypted.count > 4 ? Array(encrypted[4...]) : encrypted
        guard !body.isEmpty else { return nil }
        var xored = [UInt8](repeating: 0, count: body.count)
        for i in 0..<body.count {
            xored[i] = body[i] ^ krcKey[i % krcKey.count]
        }
        guard let data = Zlib.inflate(Data(xored)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: QRC

    /// 解密 QQ QRC（输入为 hex 字符串，来自 musicu.fcg GetPlayLyricInfo 的 lyric 字段）
    static func qrcDecrypt(hex: String) -> String? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var cursor = cleaned.startIndex
        while cursor < cleaned.endIndex {
            let next = cleaned.index(cursor, offsetBy: 2)
            guard let byte = UInt8(cleaned[cursor..<next], radix: 16) else { return nil }
            bytes.append(byte)
            cursor = next
        }

        let keys = tripledesKeySetup(qrcKey, mode: Mode.decrypt)
        var plain: [UInt8] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            plain.append(contentsOf: crypt(Array(bytes[offset..<(offset + 8)]), keys))
            offset += 8
        }
        guard !plain.isEmpty, let data = Zlib.inflate(Data(plain)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: 逐字解析

    private static let krcLine = Pattern.make("^\\[(\\d+),(\\d+)\\](.*)$")
    private static let krcWord = Pattern.make("<(\\d+),(\\d+),\\d+>((?:.(?!\\d+,\\d+,\\d+>))*)")

    /// 明文 KRC → 带逐字时间的行。
    /// KRC 词条是 `<start,dur,offset>文字`，其中 start 是**行内相对毫秒**，这里换算成绝对时间。
    static func krcToLines(_ plain: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in plain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("["), let m = krcLine.match(line), m.count >= 3 else { continue }
            guard let start = Int(m[0]) else { continue }
            let content = m[2]
            var words: [LyricWord] = []
            for w in krcWord.allMatches(content) where w.count >= 3 {
                let text = w[2]
                guard !text.isEmpty, let rel = Int(w[0]) else { continue }
                let dur = Int(w[1]) ?? 0
                words.append(LyricWord(text: text, startMs: start + rel, durMs: dur))
            }
            guard !words.isEmpty else { continue }
            let joined = words.map(\.text).joined()
            let cleaned = LyricsCleaning.cleanLine(joined)
            guard !cleaned.isEmpty else { continue }
            out.append(LyricLine(timeMs: start, text: cleaned, words: words))
        }
        return out.sorted { $0.timeMs < $1.timeMs }
    }

    private static let qrcContent = Pattern.make(
        "<Lyric_1 LyricType=\"1\" LyricContent=\"(.*?)\"/>", options: [.dotMatchesLineSeparators])
    private static let qrcWord = Pattern.make("((?:(?!\\(\\d+,\\d+\\)).)*)\\((\\d+),(\\d+)\\)")

    /// 明文 QRC（`<Lyric_1 LyricContent="..."/>`）→ 带逐字时间的行。
    /// QQ 的 word start 一般是绝对毫秒，但也见过行内相对的投放；用「首词时间 < 行首时间」自适应。
    static func qrcToLines(_ plain: String) -> [LyricLine] {
        guard let m = qrcContent.match(plain), m.count >= 1 else { return [] }
        let content = m[0]
        var out: [LyricLine] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("["), let lm = krcLine.match(line), lm.count >= 3 else { continue }
            guard let start = Int(lm[0]) else { continue }
            var rawWords: [(text: String, start: Int, dur: Int)] = []
            for w in qrcWord.allMatches(lm[2]) where w.count >= 3 {
                let text = w[0]
                if text.isEmpty || text == "\r" { continue }
                guard let s = Int(w[1]) else { continue }
                rawWords.append((text, s, Int(w[2]) ?? 0))
            }
            guard let first = rawWords.first else { continue }
            let base = first.start < start ? start : 0
            let words = rawWords.map { LyricWord(text: $0.text, startMs: base + $0.start, durMs: $0.dur) }
            let joined = words.map(\.text).joined()
            let cleaned = LyricsCleaning.cleanLine(joined)
            guard !cleaned.isEmpty else { continue }
            out.append(LyricLine(timeMs: start, text: cleaned, words: words))
        }
        return out.sorted { $0.timeMs < $1.timeMs }
    }

    /// 明文 KRC → 标准 LRC 文本（逐字拼接成整行；逐字解析失败时的兜底）
    static func krcToLrc(_ plain: String) -> String {
        var sb = ""
        for raw in plain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("["), let m = krcLine.match(line), m.count >= 3 else { continue }
            guard let start = Int(m[0]) else { continue }
            let words = krcWord.allMatches(m[2]).compactMap { $0.count >= 3 ? $0[2] : nil }.joined()
            if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sb += "\(formatTime(start))\(words.trimmingCharacters(in: .whitespaces))\n"
            }
        }
        return sb
    }

    /// 明文 QRC → 标准 LRC 文本
    static func qrcToLrc(_ plain: String) -> String {
        guard let m = qrcContent.match(plain), m.count >= 1 else { return "" }
        var sb = ""
        for raw in m[0].split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("["), let lm = krcLine.match(line), lm.count >= 3 else { continue }
            guard let start = Int(lm[0]) else { continue }
            let words = qrcWord.allMatches(lm[2]).compactMap { $0.count >= 1 ? $0[0] : nil }
                .filter { $0 != "\r" }.joined()
            if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sb += "\(formatTime(start))\(words.trimmingCharacters(in: .whitespaces))\n"
            }
        }
        return sb
    }

    private static func formatTime(_ ms: Int) -> String {
        String(format: "[%02d:%02d.%03d]", ms / 60000, (ms % 60000) / 1000, ms % 1000)
    }

    // ==================== QQ 专用 3DES（LDDC tripledes 移植） ====================

    enum Mode { case encrypt, decrypt }
    private static let encryptMode = 1
    private static let decryptMode = 0

    private static let sbox: [[UInt32]] = [
        [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
        [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,15,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
        [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
        [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,10,13,8,9,4,5,11,12,7,2,14],
        [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
        [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
        [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
        [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11],
    ]

    private static func bitnum(_ a: [UInt8], _ b: Int, _ c: Int) -> UInt32 {
        let index = (b / 32) * 4 + 3 - (b % 32) / 8
        guard index >= 0, index < a.count else { return 0 }
        let bit = (UInt32(a[index]) >> UInt32(7 - b % 8)) & 1
        return bit << UInt32(c)
    }

    private static func bitnumIntr(_ a: UInt32, _ b: Int, _ c: Int) -> UInt32 {
        ((a >> UInt32(31 - b)) & 1) << UInt32(c)
    }

    private static func bitnumIntl(_ a: UInt32, _ b: Int, _ c: Int) -> UInt32 {
        (((a << UInt32(b)) & 0x8000_0000) >> UInt32(c))
    }

    private static func sboxBit(_ a: UInt32) -> Int {
        Int((a & 32) | ((a & 31) >> 1) | ((a & 1) << 4))
    }

    private static func initialPermutation(_ input: [UInt8]) -> (UInt32, UInt32) {
        let ipS0 = [57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7]
        let ipS1 = [56,48,40,32,24,16,8,0,58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6]
        var s0: UInt32 = 0
        var s1: UInt32 = 0
        for (i, b) in ipS0.enumerated() { s0 |= bitnum(input, b, 31 - i) }
        for (i, b) in ipS1.enumerated() { s1 |= bitnum(input, b, 31 - i) }
        return (s0, s1)
    }

    private static func inversePermutation(_ s0: UInt32, _ s1: UInt32) -> [UInt8] {
        func one(_ pairs: [(UInt32, Int, Int)]) -> UInt8 {
            var v: UInt32 = 0
            for (src, b, c) in pairs {
                v |= bitnumIntr(src == 0 ? s0 : s1, b, c)
            }
            return UInt8(v & 0xFF)
        }
        var data = [UInt8](repeating: 0, count: 8)
        data[3] = one([(1,7,7),(0,7,6),(1,15,5),(0,15,4),(1,23,3),(0,23,2),(1,31,1),(0,31,0)])
        data[2] = one([(1,6,7),(0,6,6),(1,14,5),(0,14,4),(1,22,3),(0,22,2),(1,30,1),(0,30,0)])
        data[1] = one([(1,5,7),(0,5,6),(1,13,5),(0,13,4),(1,21,3),(0,21,2),(1,29,1),(0,29,0)])
        data[0] = one([(1,4,7),(0,4,6),(1,12,5),(0,12,4),(1,20,3),(0,20,2),(1,28,1),(0,28,0)])
        data[7] = one([(1,3,7),(0,3,6),(1,11,5),(0,11,4),(1,19,3),(0,19,2),(1,27,1),(0,27,0)])
        data[6] = one([(1,2,7),(0,2,6),(1,10,5),(0,10,4),(1,18,3),(0,18,2),(1,26,1),(0,26,0)])
        data[5] = one([(1,1,7),(0,1,6),(1,9,5),(0,9,4),(1,17,3),(0,17,2),(1,25,1),(0,25,0)])
        data[4] = one([(1,0,7),(0,0,6),(1,8,5),(0,8,4),(1,16,3),(0,16,2),(1,24,1),(0,24,0)])
        return data
    }

    private static func f(_ state: UInt32, _ key: [UInt32]) -> UInt32 {
        let t1 = bitnumIntl(state, 31, 0) | ((state & 0xF000_0000) >> 1) | bitnumIntl(state, 4, 5)
            | bitnumIntl(state, 3, 6) | ((state & 0x0F00_0000) >> 3) | bitnumIntl(state, 8, 11)
            | bitnumIntl(state, 7, 12) | ((state & 0x00F0_0000) >> 5) | bitnumIntl(state, 12, 17)
            | bitnumIntl(state, 11, 18) | ((state & 0x000F_0000) >> 7) | bitnumIntl(state, 16, 23)
        let t2 = bitnumIntl(state, 15, 0) | ((state & 0x0000_F000) << 15) | bitnumIntl(state, 20, 5)
            | bitnumIntl(state, 19, 6) | ((state & 0x0000_0F00) << 13) | bitnumIntl(state, 24, 11)
            | bitnumIntl(state, 23, 12) | ((state & 0x0000_00F0) << 11) | bitnumIntl(state, 28, 17)
            | bitnumIntl(state, 27, 18) | ((state & 0x0000_000F) << 9) | bitnumIntl(state, 0, 23)

        var lrg: [UInt8] = [
            UInt8((t1 >> 24) & 0xFF), UInt8((t1 >> 16) & 0xFF), UInt8((t1 >> 8) & 0xFF),
            UInt8((t2 >> 24) & 0xFF), UInt8((t2 >> 16) & 0xFF), UInt8((t2 >> 8) & 0xFF),
        ]
        for i in 0..<6 { lrg[i] ^= UInt8(truncatingIfNeeded: key[i]) }

        let st: UInt32 = (sbox[0][sboxBit(UInt32(lrg[0]) >> 2)] << 28)
            | (sbox[1][sboxBit(((UInt32(lrg[0]) & 0x03) << 4) | (UInt32(lrg[1]) >> 4))] << 24)
            | (sbox[2][sboxBit(((UInt32(lrg[1]) & 0x0F) << 2) | (UInt32(lrg[2]) >> 6))] << 20)
            | (sbox[3][sboxBit(UInt32(lrg[2]) & 0x3F)] << 16)
            | (sbox[4][sboxBit(UInt32(lrg[3]) >> 2)] << 12)
            | (sbox[5][sboxBit(((UInt32(lrg[3]) & 0x03) << 4) | (UInt32(lrg[4]) >> 4))] << 8)
            | (sbox[6][sboxBit(((UInt32(lrg[4]) & 0x0F) << 2) | (UInt32(lrg[5]) >> 6))] << 4)
            | sbox[7][sboxBit(UInt32(lrg[5]) & 0x3F)]

        return bitnumIntl(st, 15, 0) | bitnumIntl(st, 6, 1) | bitnumIntl(st, 19, 2)
            | bitnumIntl(st, 20, 3) | bitnumIntl(st, 28, 4) | bitnumIntl(st, 11, 5)
            | bitnumIntl(st, 27, 6) | bitnumIntl(st, 16, 7) | bitnumIntl(st, 0, 8)
            | bitnumIntl(st, 14, 9) | bitnumIntl(st, 22, 10) | bitnumIntl(st, 25, 11)
            | bitnumIntl(st, 4, 12) | bitnumIntl(st, 17, 13) | bitnumIntl(st, 30, 14)
            | bitnumIntl(st, 9, 15) | bitnumIntl(st, 1, 16) | bitnumIntl(st, 7, 17)
            | bitnumIntl(st, 23, 18) | bitnumIntl(st, 13, 19) | bitnumIntl(st, 31, 20)
            | bitnumIntl(st, 26, 21) | bitnumIntl(st, 2, 22) | bitnumIntl(st, 8, 23)
            | bitnumIntl(st, 18, 24) | bitnumIntl(st, 12, 25) | bitnumIntl(st, 29, 26)
            | bitnumIntl(st, 5, 27) | bitnumIntl(st, 21, 28) | bitnumIntl(st, 10, 29)
            | bitnumIntl(st, 3, 30) | bitnumIntl(st, 24, 31)
    }

    private static func crypt(_ input: [UInt8], _ key: [[UInt32]]) -> [UInt8] {
        var (s0, s1) = initialPermutation(input)
        for idx in 0..<15 {
            let prevS1 = s1
            s1 = f(s1, key[idx]) ^ s0
            s0 = prevS1
        }
        s0 = f(s1, key[15]) ^ s0
        return inversePermutation(s0, s1)
    }

    private static func keySchedule(_ key: [UInt8], _ mode: Int) -> [[UInt32]] {
        var schedule = [[UInt32]](repeating: [UInt32](repeating: 0, count: 6), count: 16)
        let shift = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1]
        let permC = [56,48,40,32,24,16,8,0,57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35]
        let permD = [62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,60,52,44,36,28,20,12,4,27,19,11,3]
        let compression = [13,16,10,23,0,4,2,27,14,5,20,9,22,18,11,3,25,7,15,6,26,19,12,1,40,51,30,36,
                           46,54,29,39,50,44,32,47,43,48,38,55,33,52,45,41,49,35,28,31]
        var c: UInt32 = 0
        var d: UInt32 = 0
        for i in 0..<28 {
            c |= bitnum(key, permC[i], 31 - i)
            d |= bitnum(key, permD[i], 31 - i)
        }
        for i in 0..<16 {
            let sh = UInt32(shift[i])
            c = ((c << sh) | (c >> (28 - sh))) & 0xFFFF_FFF0
            d = ((d << sh) | (d >> (28 - sh))) & 0xFFFF_FFF0
            let target = mode == decryptMode ? 15 - i : i
            for j in 0..<6 { schedule[target][j] = 0 }
            for j in 0..<24 {
                schedule[target][j / 8] |= bitnumIntr(c, compression[j], 7 - (j % 8))
            }
            for j in 24..<48 {
                schedule[target][j / 8] |= bitnumIntr(d, compression[j] - 27, 7 - (j % 8))
            }
        }
        return schedule
    }

    private static func tripledesKeySetup(_ key: [UInt8], mode: Mode) -> [[[UInt32]]] {
        guard key.count >= 24 else { return [] }
        let k0 = Array(key[0..<8])
        let k1 = Array(key[8..<16])
        let k2 = Array(key[16..<24])
        switch mode {
        case .encrypt:
            return [keySchedule(k0, encryptMode), keySchedule(k1, decryptMode), keySchedule(k2, encryptMode)]
        case .decrypt:
            return [keySchedule(k2, decryptMode), keySchedule(k1, encryptMode), keySchedule(k0, decryptMode)]
        }
    }

    private static func tripledesCrypt(_ block: [UInt8], _ keys: [[[UInt32]]]) -> [UInt8] {
        var data = block
        for key in keys { data = crypt(data, key) }
        return data
    }

    // MARK: 仅供测试

    /// 单块 3DES 加密（生产用不到，`SelfTest` 用它对照 Python 生成的向量，双向验证实现正确）
    static func tripledesEncryptBlock(_ block: [UInt8]) -> [UInt8] {
        guard block.count == 8 else { return [] }
        return tripledesCrypt(block, tripledesKeySetup(qrcKey, mode: .encrypt))
    }

    /// 单块 3DES 解密
    static func tripledesDecryptBlock(_ block: [UInt8]) -> [UInt8] {
        guard block.count == 8 else { return [] }
        return tripledesCrypt(block, tripledesKeySetup(qrcKey, mode: .decrypt))
    }
}

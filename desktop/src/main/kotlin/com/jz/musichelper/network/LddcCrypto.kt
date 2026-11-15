package com.jz.musichelper.network

import java.io.ByteArrayOutputStream
import java.util.zip.Inflater

/**
 * LDDC 歌词源移植：酷狗 KRC / QQ QRC 加密歌词的解密与解析。
 * 算法移植自 chenmozhijin/LDDC（GPL-3.0）：
 *   - KRC：跳过 4 字节头 + 逐字节 XOR 密钥 + zlib 解压
 *   - QRC：hex 解码 + 3DES/ECB 解密（密钥 !@#)(*$%123ZXC!@!@#)(NHL）+ zlib 解压
 * 注意：QQ 的 3DES 是 QQMusicDecoder 的非标准 DES 变体（S 盒输入位序反转），与 javax.crypto DESede 不兼容
 * （已用 120 组随机向量验证双向不一致），因此完整移植 LDDC 的 tripledes 软件实现。
 * 32 位语义：全部右移使用逻辑右移 ushr（已验证与原版逐字节一致）。
 * 解析为 App 现有 parseLrc 可直接使用的标准 LRC 文本。
 */
object LddcCrypto {

    private val KRC_KEY = byteArrayOf(
        '@'.code.toByte(), 'G'.code.toByte(), 'a'.code.toByte(), 'w'.code.toByte(),
        '^'.code.toByte(), '2'.code.toByte(), 't'.code.toByte(), 'G'.code.toByte(),
        'Q'.code.toByte(), '6'.code.toByte(), '1'.code.toByte(), '-'.code.toByte(),
        0xCE.toByte(), 0xD2.toByte(), 'n'.code.toByte(), 'i'.code.toByte()
    )

    private val QRC_KEY = "!@#)(*\$%123ZXC!@!@#)(NHL".toByteArray(Charsets.UTF_8)

    /** 解密酷狗 KRC 加密数据（输入为 lyrics.kugou.com/download 返回 content 的 base64 解码字节） */
    fun krcDecrypt(encrypted: ByteArray): String {
        val body = if (encrypted.size > 4) encrypted.copyOfRange(4, encrypted.size) else encrypted
        val xored = ByteArray(body.size) { (body[it].toInt() xor KRC_KEY[it % KRC_KEY.size].toInt()).toByte() }
        return zlibInflate(xored)
    }

    /** 解密 QQ QRC 加密歌词（输入为 hex 字符串，来自 musicu.fcg GetPlayLyricInfo 返回的 lyric 字段） */
    fun qrcDecrypt(hexText: String): String {
        val cleaned = hexText.trim()
        if (cleaned.isEmpty()) return ""
        val bytes = ByteArray(cleaned.length / 2)
        for (i in bytes.indices) {
            val hi = Character.digit(cleaned[i * 2], 16)
            val lo = Character.digit(cleaned[i * 2 + 1], 16)
            bytes[i] = ((hi shl 4) or lo).toByte()
        }
        // LDDC 3DES（EDE）解密：K3 解密 → K2 加密 → K1 解密，按 8 字节块
        val schedule = tripledesKeySetup(QRC_KEY, DECRYPT)
        val out = ByteArrayOutputStream()
        var off = 0
        while (off + 8 <= bytes.size) {
            out.write(tripledesCrypt(bytes.copyOfRange(off, off + 8), schedule))
            off += 8
        }
        return zlibInflate(out.toByteArray())
    }

    private fun zlibInflate(data: ByteArray): String {
        val inflater = Inflater()
        inflater.setInput(data)
        val out = ByteArrayOutputStream()
        val buf = ByteArray(4096)
        while (!inflater.finished()) {
            val n = inflater.inflate(buf)
            if (n == 0) break
            out.write(buf, 0, n)
        }
        inflater.end()
        return out.toString("UTF-8")
    }

    /** 明文 KRC → 带逐字时间的行（v2.1.79）。
     * KRC 词条为三参数 <start,dur,offset>文字，start/dur 是**行内相对毫秒**（实测确认），
     * 这里统一换算成整首绝对毫秒，供悬浮栏按播放位置直接比对。 */
    fun krcToLines(plainKrc: String): List<LyricLine> {
        val lineRe = Regex("""^\[(\d+),(\d+)\](.*)$""")
        val wordRe = Regex("""<(\d+),(\d+),\d+>((?:.(?!\d+,\d+,\d+>))*)""")
        val out = mutableListOf<LyricLine>()
        plainKrc.lineSequence().forEach { raw ->
            val line = raw.trim()
            if (!line.startsWith("[")) return@forEach
            val m = lineRe.matchEntire(line) ?: return@forEach
            val start = m.groupValues[1].toLongOrNull() ?: return@forEach
            val words = wordRe.findAll(m.groupValues[3]).mapNotNull { w ->
                val s = w.groupValues[1].toLongOrNull() ?: return@mapNotNull null
                val d = w.groupValues[2].toLongOrNull() ?: 0L
                val text = w.groupValues[3]
                if (text.isEmpty()) null else LyricWord(text, start + s, d)
            }.toList()
            if (words.isEmpty()) return@forEach
            val joined = words.joinToString("") { it.text }.trimEnd()
            val clean = LyricsService.cleanLine(joined)
            if (clean.isBlank()) return@forEach
            out.add(LyricLine(start, clean, words))
        }
        return out.sortedBy { it.timeMs }
    }

    /** 明文 QRC（<Lyric_1 LyricContent="..."/>）→ 带逐字时间的行（v2.1.79）。
     * 词条形如 文字(start,dur)。QQ 的 word start 一般是绝对毫秒，但为兼容两种投放口径，
     * 这里做自适应：首词时间小于行首时间 → 视为行内相对，统一加上行首。 */
    fun qrcToLines(plainQrc: String): List<LyricLine> {
        val contentRe = Regex("""<Lyric_1 LyricType="1" LyricContent="(.*?)"/>""", RegexOption.DOT_MATCHES_ALL)
        val lineRe = Regex("""^\[(\d+),(\d+)\](.*)$""")
        val wordRe = Regex("""((?:(?!\(\d+,\d+\)).)*)\((\d+),(\d+)\)""")
        val out = mutableListOf<LyricLine>()
        val content = contentRe.find(plainQrc)?.groupValues?.get(1) ?: return emptyList()
        content.lineSequence().forEach { raw ->
            val line = raw.trim()
            if (!line.startsWith("[")) return@forEach
            val m = lineRe.matchEntire(line) ?: return@forEach
            val start = m.groupValues[1].toLongOrNull() ?: return@forEach
            val rawWords = wordRe.findAll(m.groupValues[3]).mapNotNull { w ->
                val text = w.groupValues[1]
                if (text == "\r" || text.isEmpty()) return@mapNotNull null
                val s = w.groupValues[2].toLongOrNull() ?: return@mapNotNull null
                val d = w.groupValues[3].toLongOrNull() ?: 0L
                Triple(text, s, d)
            }.toList()
            if (rawWords.isEmpty()) return@forEach
            // 自适应基准：首词时间 < 行首 → 行内相对
            val base = if (rawWords.first().second < start) start else 0L
            val words = rawWords.map { LyricWord(it.first, base + it.second, it.third) }
            val joined = words.joinToString("") { it.text }.trimEnd()
            val clean = LyricsService.cleanLine(joined)
            if (clean.isBlank()) return@forEach
            out.add(LyricLine(start, clean, words))
        }
        return out.sortedBy { it.timeMs }
    }

    /** 明文 KRC 文本 → 标准 LRC 文本（[mm:ss.xxx]行，逐字拼接） */
    fun krcToLrc(plainKrc: String): String {
        val lineRe = Regex("""^\[(\d+),(\d+)\](.*)$""")
        val wordRe = Regex("""<(\d+),(\d+),\d+>((?:.(?!\d+,\d+,\d+>))*)""")
        val sb = StringBuilder()
        plainKrc.lineSequence().forEach { raw ->
            val line = raw.trim()
            if (line.startsWith("[")) {
                val m = lineRe.matchEntire(line)
                if (m != null) {
                    val start = m.groupValues[1].toIntOrNull() ?: return@forEach
                    val content = m.groupValues[3]
                    val words = wordRe.findAll(content).map { it.groupValues[3] }.joinToString("")
                    if (words.isNotBlank()) {
                        sb.append(formatTime(start)).append(words.trimEnd()).append('\n')
                    }
                }
            }
        }
        return sb.toString()
    }

    /** 明文 QRC 文本（<Lyric_1 LyricContent="..."/>）→ 标准 LRC 文本 */
    fun qrcToLrc(plainQrc: String): String {
        val contentRe = Regex("""<Lyric_1 LyricType="1" LyricContent="(.*?)"/>""", RegexOption.DOT_MATCHES_ALL)
        val lineRe = Regex("""^\[(\d+),(\d+)\](.*)$""")
        val wordRe = Regex("""((?:(?!\(\d+,\d+\)).)*)\((\d+),(\d+)\)""")
        val sb = StringBuilder()
        val content = contentRe.find(plainQrc)?.groupValues?.get(1) ?: return sb.toString()
        content.lineSequence().forEach { raw ->
            val line = raw.trim()
            if (line.startsWith("[")) {
                val m = lineRe.matchEntire(line)
                if (m != null) {
                    val start = m.groupValues[1].toIntOrNull() ?: return@forEach
                    val contentPart = m.groupValues[3]
                    val words = wordRe.findAll(contentPart)
                        .map { it.groupValues[1] }
                        .filter { it != "\r" }
                        .joinToString("")
                    if (words.isNotBlank()) {
                        sb.append(formatTime(start)).append(words.trimEnd()).append('\n')
                    }
                }
            }
        }
        return sb.toString()
    }

    private fun formatTime(ms: Int): String {
        val m = ms / 60000
        val s = (ms % 60000) / 1000
        val milli = ms % 1000
        return String.format("[%02d:%02d.%03d]", m, s, milli)
    }

    // ==================== QQ QRC 3DES（LDDC tripledes 完整移植） ====================
    private const val ENCRYPT = 1
    private const val DECRYPT = 0

    private val SBOX = arrayOf(
        intArrayOf(14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13),
        intArrayOf(15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,15,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9),
        intArrayOf(10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12),
        intArrayOf(7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,10,13,8,9,4,5,11,12,7,2,14),
        intArrayOf(2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3),
        intArrayOf(12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13),
        intArrayOf(4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12),
        intArrayOf(13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11),
    )

    private fun bitnum(a: ByteArray, b: Int, c: Int): Int =
        ((a[(b / 32) * 4 + 3 - (b % 32) / 8].toInt() ushr (7 - b % 8)) and 1) shl c

    private fun bitnumIntr(a: Int, b: Int, c: Int): Int = ((a ushr (31 - b)) and 1) shl c

    private fun bitnumIntl(a: Int, b: Int, c: Int): Int = ((a shl b) and Int.MIN_VALUE) ushr c

    private fun sboxBit(a: Int): Int = (a and 32) or ((a and 31) ushr 1) or ((a and 1) shl 4)

    private fun initialPermutation(input: ByteArray): Pair<Int, Int> {
        val s0 = (bitnum(input,57,31) or bitnum(input,49,30) or bitnum(input,41,29) or bitnum(input,33,28) or
            bitnum(input,25,27) or bitnum(input,17,26) or bitnum(input,9,25) or bitnum(input,1,24) or
            bitnum(input,59,23) or bitnum(input,51,22) or bitnum(input,43,21) or bitnum(input,35,20) or
            bitnum(input,27,19) or bitnum(input,19,18) or bitnum(input,11,17) or bitnum(input,3,16) or
            bitnum(input,61,15) or bitnum(input,53,14) or bitnum(input,45,13) or bitnum(input,37,12) or
            bitnum(input,29,11) or bitnum(input,21,10) or bitnum(input,13,9) or bitnum(input,5,8) or
            bitnum(input,63,7) or bitnum(input,55,6) or bitnum(input,47,5) or bitnum(input,39,4) or
            bitnum(input,31,3) or bitnum(input,23,2) or bitnum(input,15,1) or bitnum(input,7,0))
        val s1 = (bitnum(input,56,31) or bitnum(input,48,30) or bitnum(input,40,29) or bitnum(input,32,28) or
            bitnum(input,24,27) or bitnum(input,16,26) or bitnum(input,8,25) or bitnum(input,0,24) or
            bitnum(input,58,23) or bitnum(input,50,22) or bitnum(input,42,21) or bitnum(input,34,20) or
            bitnum(input,26,19) or bitnum(input,18,18) or bitnum(input,10,17) or bitnum(input,2,16) or
            bitnum(input,60,15) or bitnum(input,52,14) or bitnum(input,44,13) or bitnum(input,36,12) or
            bitnum(input,28,11) or bitnum(input,20,10) or bitnum(input,12,9) or bitnum(input,4,8) or
            bitnum(input,62,7) or bitnum(input,54,6) or bitnum(input,46,5) or bitnum(input,38,4) or
            bitnum(input,30,3) or bitnum(input,22,2) or bitnum(input,14,1) or bitnum(input,6,0))
        return s0 to s1
    }

    private fun inversePermutation(s0: Int, s1: Int): ByteArray {
        val data = ByteArray(8)
        data[3] = (bitnumIntr(s1,7,7) or bitnumIntr(s0,7,6) or bitnumIntr(s1,15,5) or bitnumIntr(s0,15,4) or
            bitnumIntr(s1,23,3) or bitnumIntr(s0,23,2) or bitnumIntr(s1,31,1) or bitnumIntr(s0,31,0)).toByte()
        data[2] = (bitnumIntr(s1,6,7) or bitnumIntr(s0,6,6) or bitnumIntr(s1,14,5) or bitnumIntr(s0,14,4) or
            bitnumIntr(s1,22,3) or bitnumIntr(s0,22,2) or bitnumIntr(s1,30,1) or bitnumIntr(s0,30,0)).toByte()
        data[1] = (bitnumIntr(s1,5,7) or bitnumIntr(s0,5,6) or bitnumIntr(s1,13,5) or bitnumIntr(s0,13,4) or
            bitnumIntr(s1,21,3) or bitnumIntr(s0,21,2) or bitnumIntr(s1,29,1) or bitnumIntr(s0,29,0)).toByte()
        data[0] = (bitnumIntr(s1,4,7) or bitnumIntr(s0,4,6) or bitnumIntr(s1,12,5) or bitnumIntr(s0,12,4) or
            bitnumIntr(s1,20,3) or bitnumIntr(s0,20,2) or bitnumIntr(s1,28,1) or bitnumIntr(s0,28,0)).toByte()
        data[7] = (bitnumIntr(s1,3,7) or bitnumIntr(s0,3,6) or bitnumIntr(s1,11,5) or bitnumIntr(s0,11,4) or
            bitnumIntr(s1,19,3) or bitnumIntr(s0,19,2) or bitnumIntr(s1,27,1) or bitnumIntr(s0,27,0)).toByte()
        data[6] = (bitnumIntr(s1,2,7) or bitnumIntr(s0,2,6) or bitnumIntr(s1,10,5) or bitnumIntr(s0,10,4) or
            bitnumIntr(s1,18,3) or bitnumIntr(s0,18,2) or bitnumIntr(s1,26,1) or bitnumIntr(s0,26,0)).toByte()
        data[5] = (bitnumIntr(s1,1,7) or bitnumIntr(s0,1,6) or bitnumIntr(s1,9,5) or bitnumIntr(s0,9,4) or
            bitnumIntr(s1,17,3) or bitnumIntr(s0,17,2) or bitnumIntr(s1,25,1) or bitnumIntr(s0,25,0)).toByte()
        data[4] = (bitnumIntr(s1,0,7) or bitnumIntr(s0,0,6) or bitnumIntr(s1,8,5) or bitnumIntr(s0,8,4) or
            bitnumIntr(s1,16,3) or bitnumIntr(s0,16,2) or bitnumIntr(s1,24,1) or bitnumIntr(s0,24,0)).toByte()
        return data
    }

    private fun f(state: Int, key: IntArray): Int {
        val t1 = (bitnumIntl(state,31,0) or ((state and 0xf0000000.toInt()) ushr 1) or bitnumIntl(state,4,5) or bitnumIntl(state,3,6) or
            ((state and 0x0f000000) ushr 3) or bitnumIntl(state,8,11) or bitnumIntl(state,7,12) or ((state and 0x00f00000) ushr 5) or
            bitnumIntl(state,12,17) or bitnumIntl(state,11,18) or ((state and 0x000f0000) ushr 7) or bitnumIntl(state,16,23))
        val t2 = (bitnumIntl(state,15,0) or ((state and 0x0000f000) shl 15) or bitnumIntl(state,20,5) or bitnumIntl(state,19,6) or
            ((state and 0x00000f00) shl 13) or bitnumIntl(state,24,11) or bitnumIntl(state,23,12) or ((state and 0x000000f0) shl 11) or
            bitnumIntl(state,28,17) or bitnumIntl(state,27,18) or ((state and 0x0000000f) shl 9) or bitnumIntl(state,0,23))
        val lrgstate = intArrayOf(
            (t1 ushr 24) and 0xff, (t1 ushr 16) and 0xff, (t1 ushr 8) and 0xff,
            (t2 ushr 24) and 0xff, (t2 ushr 16) and 0xff, (t2 ushr 8) and 0xff,
        )
        for (i in 0..5) lrgstate[i] = lrgstate[i] xor key[i]
        val st = (SBOX[0][sboxBit(lrgstate[0] ushr 2)] shl 28) or
            (SBOX[1][sboxBit(((lrgstate[0] and 0x03) shl 4) or (lrgstate[1] ushr 4))] shl 24) or
            (SBOX[2][sboxBit(((lrgstate[1] and 0x0f) shl 2) or (lrgstate[2] ushr 6))] shl 20) or
            (SBOX[3][sboxBit(lrgstate[2] and 0x3f)] shl 16) or
            (SBOX[4][sboxBit(lrgstate[3] ushr 2)] shl 12) or
            (SBOX[5][sboxBit(((lrgstate[3] and 0x03) shl 4) or (lrgstate[4] ushr 4))] shl 8) or
            (SBOX[6][sboxBit(((lrgstate[4] and 0x0f) shl 2) or (lrgstate[5] ushr 6))] shl 4) or
            SBOX[7][sboxBit(lrgstate[5] and 0x3f)]
        return (bitnumIntl(st,15,0) or bitnumIntl(st,6,1) or bitnumIntl(st,19,2) or bitnumIntl(st,20,3) or
            bitnumIntl(st,28,4) or bitnumIntl(st,11,5) or bitnumIntl(st,27,6) or bitnumIntl(st,16,7) or
            bitnumIntl(st,0,8) or bitnumIntl(st,14,9) or bitnumIntl(st,22,10) or bitnumIntl(st,25,11) or
            bitnumIntl(st,4,12) or bitnumIntl(st,17,13) or bitnumIntl(st,30,14) or bitnumIntl(st,9,15) or
            bitnumIntl(st,1,16) or bitnumIntl(st,7,17) or bitnumIntl(st,23,18) or bitnumIntl(st,13,19) or
            bitnumIntl(st,31,20) or bitnumIntl(st,26,21) or bitnumIntl(st,2,22) or bitnumIntl(st,8,23) or
            bitnumIntl(st,18,24) or bitnumIntl(st,12,25) or bitnumIntl(st,29,26) or bitnumIntl(st,5,27) or
            bitnumIntl(st,21,28) or bitnumIntl(st,10,29) or bitnumIntl(st,3,30) or bitnumIntl(st,24,31))
    }

    private fun crypt(input: ByteArray, key: List<IntArray>): ByteArray {
        var (s0, s1) = initialPermutation(input)
        for (idx in 0..14) {
            val prevS1 = s1
            s1 = f(s1, key[idx]) xor s0
            s0 = prevS1
        }
        s0 = f(s1, key[15]) xor s0
        return inversePermutation(s0, s1)
    }

    private fun keySchedule(key: ByteArray, mode: Int): List<IntArray> {
        val schedule = Array(16) { IntArray(6) }
        val keyRndShift = intArrayOf(1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1)
        val keyPermC = intArrayOf(56,48,40,32,24,16,8,0,57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35)
        val keyPermD = intArrayOf(62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,60,52,44,36,28,20,12,4,27,19,11,3)
        val keyCompression = intArrayOf(13,16,10,23,0,4,2,27,14,5,20,9,22,18,11,3,25,7,15,6,26,19,12,1,40,51,30,36,
            46,54,29,39,50,44,32,47,43,48,38,55,33,52,45,41,49,35,28,31)
        var c = 0
        var d = 0
        for (i in 0..27) { c += bitnum(key, keyPermC[i], 31 - i); d += bitnum(key, keyPermD[i], 31 - i) }
        for (i in 0..15) {
            c = ((c shl keyRndShift[i]) or (c ushr (28 - keyRndShift[i]))) and 0xfffffff0.toInt()
            d = ((d shl keyRndShift[i]) or (d ushr (28 - keyRndShift[i]))) and 0xfffffff0.toInt()
            val togen = if (mode == DECRYPT) 15 - i else i
            for (j in 0..5) schedule[togen][j] = 0
            for (j in 0..23) schedule[togen][j / 8] = schedule[togen][j / 8] or bitnumIntr(c, keyCompression[j], 7 - (j % 8))
            for (j in 24..47) schedule[togen][j / 8] = schedule[togen][j / 8] or bitnumIntr(d, keyCompression[j] - 27, 7 - (j % 8))
        }
        return schedule.toList()
    }

    private fun tripledesKeySetup(key: ByteArray, mode: Int): List<List<IntArray>> {
        val k0 = key.copyOfRange(0, 8)
        val k1 = key.copyOfRange(8, 16)
        val k2 = key.copyOfRange(16, 24)
        return if (mode == ENCRYPT) {
            listOf(keySchedule(k0, ENCRYPT), keySchedule(k1, DECRYPT), keySchedule(k2, ENCRYPT))
        } else {
            listOf(keySchedule(k2, DECRYPT), keySchedule(k1, ENCRYPT), keySchedule(k0, DECRYPT))
        }
    }

    private fun tripledesCrypt(data: ByteArray, key: List<List<IntArray>>): ByteArray {
        var d = data
        for (i in 0..2) d = crypt(d, key[i])
        return d
    }
}

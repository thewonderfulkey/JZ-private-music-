package com.jz.musichelper.network

import com.jz.musichelper.model.MusicPlatform
import com.jz.musichelper.model.Song
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import java.util.concurrent.ConcurrentHashMap

// 歌词数据
/**
 * 逐字时间（v2.1.79）：酷狗 KRC / QQ QRC 明文里每个字都带 start（毫秒）与 dur（毫秒）。
 * startMs 已统一换算成**整首歌的绝对时间**，可直接与 PlayerManager.currentPositionMs() 比较。
 * 纯 LRC（无逐字时间的源）该集合为空，渲染层回退到行内插值。
 */
data class LyricWord(val text: String, val startMs: Long, val durMs: Long)

data class LyricLine(val timeMs: Long, val text: String, val words: List<LyricWord> = emptyList())
data class LyricsResult(val lines: List<LyricLine>, val source: String)

/**
 * 歌词服务 v1.7.0：唯一歌词源 = LDDC（Kotlin 内嵌完整逻辑）。
 * v2.1.87：酷我歌曲先走酷我官方 getlyric（平台 ID 精确、行级时间），空词才回退 LDDC。
 * 已废弃：网易官方 id 直连、网易云搜索、LrcApi（用户拍板：劣质+繁体，全部废弃）。
 * 行为：按“歌手+歌名”严格匹配（LDDC 评分选优）取词 → KRC/QRC 解密 → 标准 LRC；
 * 命中后 4h 内存缓存，重复切歌不重新请求（解决加载慢）。
 * 乱码加固：代理区 U+D800–DFFF、非字符 U+FFFE/FFFF、几何符号全区块 U+25A0–U+25FF
 * 纳入损坏判定与清洗（安卓字体对这类码点渲染为“菱形带问号”占位符）。
 */
object LyricsService {

    private const val CACHE_TTL_MS = 4 * 60 * 60 * 1000L

    private data class CacheEntry(val result: LyricsResult, val at: Long)

    private val cache = ConcurrentHashMap<String, CacheEntry>()

    // 同 key 并发请求共享同一 Deferred：全局歌词预取与播放页兜底不重复请求
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val inflight = ConcurrentHashMap<String, Deferred<LyricsResult?>>()

    /** 获取歌词：酷我歌曲先用酷我官方词，拿不到再走 LDDC 双源评分。
     * 先查 4h 缓存，未命中才请求；并发请求共享同一任务。 */
    suspend fun fetch(song: Song): LyricsResult? {
        val key = song.platform.name + "|" + song.platformID
        val now = System.currentTimeMillis()
        cache[key]?.let { if (now - it.at < CACHE_TTL_MS) return it.result }
        val deferred = inflight.computeIfAbsent(key) {
            ioScope.async { resolve(song) }
        }
        val result = try { deferred.await() } finally { inflight.remove(key) }
        if (result == null) return null
        cache[key] = CacheEntry(result, now)
        return result
    }

    /** v2.1.87：酷我歌曲（平台 ID 精确）先用酷我 getlyric（行级时间），空词再回退 LDDC。 */
    private suspend fun resolve(song: Song): LyricsResult? {
        if (song.platform == MusicPlatform.KUWO) {
            val kw = runCatching { KwLyrics.fetch(song.platformID) }.getOrNull()
            if (!kw.isNullOrEmpty()) return LyricsResult(kw, "酷我")
        }
        val lines = runCatching { LddcLyrics.fetch(song) }.getOrNull()
        return if (lines.isNullOrEmpty()) null else LyricsResult(lines, "LDDC")
    }

    /** 歌手名清洗：多艺人取第一个（如 "A20 LITE/A20" → "A20 LITE"），去掉分隔符 */
    fun cleanArtist(singer: String): String {
        return singer.trim().split(Regex("[/／、,，;；]")).firstOrNull()?.trim() ?: ""
    }

    /** 歌词损坏判定：文本含占位符/危险码点且同时含中文 → 损坏。
     * 占位符集合：半角?、全角？、U+FFFD、＿U+FF3F、变体问号（﹖U+FE56/︖U+FE16/⁇U+2047）、
     * BOM（U+FEFF）、几何符号全区块 U+25A0–U+25FF（含 ◇◆□■○●等——安卓对未覆盖几何符号
     * 渲染为“菱形带问号”）、PUA U+E000–F8FF、专用区 U+FFF0–FFFD、代理区 U+D800–DFFF
     * （孤立代理项渲染为菱形问号）、非字符 U+FFFE/FFFF。
     * 只做占位符检测，不做字形/繁体类推断——避免把合法繁体（粤语/台版）歌词误判为劣质。 */
    fun isBrokenLyrics(text: String): Boolean {
        if (text.isBlank()) return true
        val badChars = text.any { c ->
            c == '?' || c == '\uFF1F' || c == '\uFFFD' || c == '\uFF3F' ||
                c == '\uFE56' || c == '\uFE16' || c == '\u2047' || c == '\uFEFF' ||
                c in '\u25A0'..'\u25FF' || c in '\uE000'..'\uF8FF' ||
                c in '\uFFF0'..'\uFFFD' || c in '\uD800'..'\uDFFF' ||
                c == '\uFFFE' || c == '\uFFFF'
        }
        return badChars && text.any { it in '\u4E00'..'\u9FFF' }
    }

    /** 单行歌词清洗：繁转简 → 剔占位符/危险码点/控制字符 → KRC 碎片行整行丢弃。
     * 返回 "" 表示该行不可用（调用方自行跳过）。parseLrc 与逐字解析共用同一口径。 */
    fun cleanLine(raw: String): String {
        val simp = TradToSimpMap.toSimplified(raw)
        var clean = simp.filter { c ->
            c != '\uFFFD' && c != '\uFF3F' && c != '\uFE56' && c != '\uFE16' &&
                c != '\u2047' && c != '\uFEFF' &&
                c !in '\u25A0'..'\u25FF' && c !in '\uE000'..'\uF8FF' &&
                c !in '\uFFF0'..'\uFFFD' && c !in '\uD800'..'\uDFFF' &&
                c != '\uFFFE' && c != '\uFFFF' &&
                c.code >= 0x20 && c.code != 0x7F
        }
        if (clean.contains('<')) return ""
        if (clean.any { it in '\u4E00'..'\u9FFF' }) {
            clean = clean.replace("?", "").replace('\uFF1F', ' ')
        }
        return clean.trim()
    }

    /** 解析 LRC 文本为时间戳行。清洗：占位符/代理区/几何全区块/非字符/控制字符剔除；
     * KRC 解析失败碎片特征（行内含 '<'，正常歌词无）整行丢弃。 */
    fun parseLrc(lrc: String): List<LyricLine> {
        if (lrc.isBlank()) return emptyList()
        val regex = Regex("\\[(\\d{1,2}):(\\d{1,2})(?:\\.(\\d{1,3}))?]")
        val out = mutableListOf<LyricLine>()
        lrc.lineSequence().forEach { line ->
            val matches = regex.findAll(line)
            val timeList = mutableListOf<Long>()
            for (m in matches) {
                val min = m.groupValues[1].toIntOrNull() ?: 0
                val sec = m.groupValues[2].toIntOrNull() ?: 0
                // LRC 时间戳 [mm:ss.xxx] 的 xxx 是毫秒（3 位小数秒），直接作为毫秒，不得放大
                val frac = m.groupValues[3].padEnd(3, '0').take(3).toIntOrNull() ?: 0
                timeList.add(min * 60_000L + sec * 1000L + frac.toLong())
            }
            if (timeList.isNotEmpty()) {
                val text = line.substringAfter(']').trim().ifBlank { "" }
                // 统一转简体 + 清洗；空行丢弃
                val clean = cleanLine(text)
                if (clean.isBlank()) return@forEach
                timeList.forEach { t -> out.add(LyricLine(t, clean)) }
            }
        }
        return out.sortedBy { it.timeMs }
    }

    /** 当前播放位置对应的歌词行下标 */
    fun indexAt(lines: List<LyricLine>, positionMs: Long): Int {
        if (lines.isEmpty()) return -1
        var idx = -1
        for (i in lines.indices) {
            if (lines[i].timeMs <= positionMs) idx = i else break
        }
        return idx
    }
}

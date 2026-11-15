package com.jz.musichelper.ui.desktop

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import com.jz.musichelper.network.LyricLine

/**
 * 逐字歌词染色（PC 右侧歌词面板用）。
 *
 * 与桌面歌词栏同一套口径：优先用 KRC/QRC 的原生逐字毫秒；纯 LRC 就按行内可见字数均分。
 * 唱过的字用墨色，未唱的用淡墨，正在唱的那个字按进度做颜色插值——所以是"一个字一个字"亮起来，
 * 而不是整行一起变。
 */
object Karaoke {

    /** 返回带颜色 Span 的整行文本 */
    fun annotate(
        line: LyricLine,
        nextStartMs: Long,
        posMs: Long,
        unsung: Color,
        sung: Color
    ): AnnotatedString {
        val text = line.text
        if (text.isEmpty()) return AnnotatedString(" ")
        val start = line.timeMs
        val end = if (nextStartMs > start) nextStartMs else start + 4_000L
        val times = charTimes(line, start, end)
        return buildAnnotatedString {
            text.forEachIndexed { i, ch ->
                val s = times.start[i]
                val e = times.end[i]
                val color = when {
                    s < 0L -> unsung                       // 没对齐：保持淡色，不误亮
                    posMs >= e -> sung
                    posMs <= s -> unsung
                    else -> lerpColor(unsung, sung, (posMs - s).toFloat() / (e - s).coerceAtLeast(1L).toFloat())
                }
                // 只改颜色，不用逐字改字重：混合字重会触发额外的字体匹配，
                // 打包后的 jlink 运行时里字体集不全，曾在切歌时把整个 composition 打崩。
                withStyle(SpanStyle(color = color)) { append(ch) }
            }
        }
    }

    /** 行内进度（0..1），用于没有逐字时间的兜底与"整行高亮"判断 */
    fun lineProgress(line: LyricLine, nextStartMs: Long, posMs: Long): Float {
        val start = line.timeMs
        val end = if (nextStartMs > start) nextStartMs else start + 4_000L
        if (posMs <= start) return 0f
        if (posMs >= end) return 1f
        return (posMs - start).toFloat() / (end - start).toFloat()
    }

    private class Times(val start: LongArray, val end: LongArray)

    /** 把 words 映射到每个字符（空格不占时段）；对不齐时退回行内均分 */
    private fun charTimes(line: LyricLine, startMs: Long, endMs: Long): Times {
        val text = line.text
        val s = LongArray(text.length) { -1L }
        val e = LongArray(text.length) { -1L }
        val words = line.words
        if (words.isNotEmpty()) {
            var wi = 0
            var wci = 0
            var matched = 0
            var visible = 0
            for (i in text.indices) {
                if (text[i] == ' ') continue
                visible++
                while (wi < words.size && words[wi].text.isBlank()) { wi++; wci = 0 }
                if (wi >= words.size) break
                val w = words[wi]
                val k = w.text.count { it != ' ' }.coerceAtLeast(1)
                val step = w.durMs / k
                s[i] = w.startMs + step * wci
                e[i] = s[i] + step
                matched++
                wci++
                if (wci >= k) { wi++; wci = 0 }
            }
            if (visible > 0 && matched == visible) return Times(s, e)
        }
        // 兜底：整行按可见字数均分
        val visibleIdx = text.indices.filter { text[it] != ' ' }
        if (visibleIdx.isEmpty()) return Times(s, e)
        val span = (endMs - startMs).coerceAtLeast(1L)
        val step = span / visibleIdx.size
        visibleIdx.forEachIndexed { k, i ->
            s[i] = startMs + step * k
            e[i] = s[i] + step
        }
        return Times(s, e)
    }

    private fun lerpColor(a: Color, b: Color, t: Float): Color {
        val k = t.coerceIn(0f, 1f)
        return Color(
            red = a.red + (b.red - a.red) * k,
            green = a.green + (b.green - a.green) * k,
            blue = a.blue + (b.blue - a.blue) * k,
            alpha = a.alpha + (b.alpha - a.alpha) * k
        )
    }
}

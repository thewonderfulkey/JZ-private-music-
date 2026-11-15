package com.jz.musichelper.ui

import com.jz.musichelper.network.LyricWord
import java.awt.AlphaComposite
import java.awt.BasicStroke
import java.awt.Color
import java.awt.Font
import java.awt.Graphics
import java.awt.Graphics2D
import java.awt.RenderingHints
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import java.awt.geom.Arc2D
import java.awt.geom.Path2D
import java.awt.geom.RoundRectangle2D
import java.io.File
import javax.swing.JComponent
import javax.swing.SwingUtilities
import javax.swing.Timer
import kotlin.math.max
import kotlin.math.min

/** 工具条上的七个动作（六个格子，字号格切成 A- / A+ 两个热区） */
enum class LyricsBarAction { PREV, PLAY_PAUSE, NEXT, FONT_MINUS, FONT_PLUS, LOCK, CLOSE }

/**
 * 桌面歌词栏（独立悬浮窗内部视图）。
 *
 * Android 版是 `View.onDraw(Canvas)` 原生自绘；桌面版一一对应地搬到 Java2D（`JComponent.paintComponent`）——
 * 圆角纸签、上缘压墨线、逐字染色、折行、工具条、拖动吸边这些几何与配色口径全部照搬，
 * 只是把 android.graphics 的 Paint/Path/RectF 换成 Graphics2D/Path2D/RoundRectangle2D。
 *
 * 行为口径不变：
 *  1. 逐字染色按 KRC/QRC 原生逐字毫秒推进；无逐字时间的纯 LRC 回退行内均分
 *  2. 锁定后不响应拖动（但仍可点开工具条，否则锁上就解不掉了）
 *  3. 轻点纸签浮出工具条，3 秒无操作自动收起
 *  4. 三套纸色（素纸/旧黄/夜墨）、五档字号，长句先缩后折行，不出省略号
 */
class DesktopLyricsView : JComponent() {

    var onDragStart: (() -> Unit)? = null
    var onDragMove: ((Float, Float) -> Unit)? = null
    var onDragEnd: (() -> Unit)? = null
    /** 纸签被轻点：展开 / 收起工具条 */
    var onTapBar: (() -> Unit)? = null
    /** 工具条按钮 */
    var onAction: ((LyricsBarAction) -> Unit)? = null

    /**
     * 工具条 3 秒自动收起时回调。
     *
     * 必须交给外部（DesktopLyrics）把**状态**也置回 false：只改视图的话
     * `LyricsBarState.toolbarOpen` 还是 true，下一次点栏体第一次只会把状态关掉，
     * 看起来就是"第一次点不出来、要连点两次"。
     */
    var onRequestCollapse: (() -> Unit)? = null
    /** 需要的窗口高度变了（折行 / 展开工具条），外层据此调整窗口大小 */
    var onHeightChanged: (() -> Unit)? = null

    // 桌面版 dp/sp 就是 Java 用户坐标（HiDPI 由 JVM 统一缩放）。
    // 但手机 308dp 的栏体放在 2560 宽的屏幕上只占 12%，看着像一行小字——桌面歌词是要在屏幕
    // 另一端看清的，所以整栏等比放大 LyricsMetrics.scale 倍（比例、字号档位、折行规则都不变）。
    private fun dp(v: Float): Float = v * LyricsMetrics.scale
    private fun sp(v: Float): Float = v * LyricsMetrics.scale

    private val kai: Font = LyricFonts.kai()

    // ===== 纸色 =====
    private data class Palette(
        val paper: Int, val ink: Int, val light: Int, val sub: Int,
        val rule: Int, val edge: Int, val track: Int, val fill: Int
    )

    private fun rgb(c: Int): Color = Color((c shr 16) and 0xFF, (c shr 8) and 0xFF, c and 0xFF)

    private fun blend(base: Int, ink: Int, a: Float): Int {
        val br = (base shr 16) and 0xFF
        val bg = (base shr 8) and 0xFF
        val bb = base and 0xFF
        val ir = (ink shr 16) and 0xFF
        val ig = (ink shr 8) and 0xFF
        val ib = ink and 0xFF
        val r = (br * (1f - a) + ir * a).toInt()
        val g = (bg * (1f - a) + ig * a).toInt()
        val b = (bb * (1f - a) + ib * a).toInt()
        return (r shl 16) or (g shl 8) or b
    }

    private fun paletteFor(index: Int): Palette = when (index) {
        1 -> {
            val paper = 0xF2E5C4
            Palette(paper, 0x30281C, 0xA89268, 0x967C5C,
                blend(paper, 0x3E2E1A, 0.46f), blend(paper, 0x3E2E1A, 0.28f),
                blend(paper, 0x30281C, 0.10f), blend(paper, 0x30281C, 0.62f))
        }
        2 -> {
            val paper = 0x24211D
            Palette(paper, 0xF0EADA, 0x706A5E, 0x948F82,
                blend(paper, 0xECE4D2, 0.30f), blend(paper, 0xECE4D2, 0.14f),
                blend(paper, 0xECE4D2, 0.12f), blend(paper, 0xECE4D2, 0.55f))
        }
        else -> {
            val paper = 0xFBF7ED
            Palette(paper, 0x2C2822, 0xB0A898, 0x8A8378,
                blend(paper, 0x2C2822, 0.46f), blend(paper, 0x2C2822, 0.26f),
                blend(paper, 0x2C2822, 0.10f), blend(paper, 0x2C2822, 0.62f))
        }
    }

    private var pal: Palette = paletteFor(0)

    // ===== 字号（sp）=====
    private var curSize = sp(17f)
    private var nextSize = sp(11f)
    private var emptySize = sp(13f)
    private var curSpacing = 0.03f
    private var nextSpacing = 0.02f

    private val corner = dp(3f)
    private val edgePad = dp(0.7f)
    private val padH = dp(10f)
    private val gapLine = dp(8f)
    private val toolbarH = dp(46f)
    private val toolbarGap = dp(8f)

    // ===== 状态 =====
    private var themeIdx = 0
    private var fontStep = 0            // -2..2，步进 8%
    private var lockedFlag = false
    private var toolbarOpen = false
    private var toolbarAbove = false
    private var paused = false
    private var karaoke = 0f            // 当前句进度 0..1（无逐字时间时的回退口径）

    // ===== 逐字时间 =====
    private var curWords: List<LyricWord> = emptyList()
    private var posMs = 0L
    private var charS = LongArray(0)
    private var charE = LongArray(0)
    private var timed = false

    private var curText = ""
    private var nextText = ""
    private var emptyText = ""
    private var curLines: List<String> = emptyList()
    private var nextLines: List<String> = emptyList()
    private var barHeight = 0f

    private var animating = false
    private var progress = 0f
    private var prevCur = ""
    private var prevNext = ""
    private var animTimer: Timer? = null
    private var lastNotifiedHeight = -1

    private val hitRects = ArrayList<Pair<java.awt.geom.Rectangle2D.Float, LyricsBarAction>>()

    // 拖动
    private val touchSlop = 4f
    private var downRawX = 0f
    private var downRawY = 0f
    private var dragging = false
    private var movedAway = false
    private var pressedAction: LyricsBarAction? = null

    private val collapseTask = Runnable { onRequestCollapse?.invoke() }
    private val collapseTimer = Timer(3000) { collapseTask.run() }.apply { isRepeats = false }

    init {
        isOpaque = false
        isDoubleBuffered = true
        rebuild()
        installMouse()
    }

    // ===== 外部入口 =====

    fun setTheme(index: Int) {
        if (themeIdx == index) return
        themeIdx = index
        pal = paletteFor(index)
        rebuild()
    }

    fun setFontStep(step: Int) {
        if (fontStep == step) return
        fontStep = step
        rebuild()
    }

    fun setLocked(value: Boolean) {
        if (lockedFlag == value) return
        lockedFlag = value
        repaint()
    }

    fun isToolbarOpen(): Boolean = toolbarOpen

    /** 工具条朝上展开时，窗口应当"底边不动、向上长"，否则会被屏幕底边顶回去 */
    fun growsUpward(): Boolean = toolbarOpen && toolbarAbove

    /** 工具条朝上展开（贴屏幕底部时用），栏体整体下移一个工具条高度，视觉位置不变 */
    fun setToolbarAbove(above: Boolean) {
        if (toolbarAbove == above) return
        toolbarAbove = above
        repaint()
    }

    fun setToolbar(open: Boolean) {
        if (toolbarOpen == open) {
            if (open) scheduleCollapse()
            return
        }
        toolbarOpen = open
        if (open) scheduleCollapse() else collapseTimer.stop()
        notifyHeight()
        repaint()
    }

    private fun scheduleCollapse() {
        collapseTimer.restart()
    }

    fun setPair(cur: String, next: String, animate: Boolean) {
        if (cur == curText && next == nextText) return
        if (animate && curText.isNotEmpty()) {
            prevCur = curText
            prevNext = nextText
            curText = cur
            nextText = next
            emptyText = ""
            rebuild()
            startAnim()
        } else {
            animTimer?.stop()
            animating = false
            curText = cur
            nextText = next
            emptyText = ""
            rebuild()
        }
    }

    fun setEmpty(text: String) {
        animTimer?.stop()
        animating = false
        curText = ""
        nextText = ""
        emptyText = text
        rebuild()
    }

    fun setPaused(value: Boolean) {
        if (paused == value) return
        paused = value
        repaint()
    }

    /** 当前句进度 0..1（只在没有逐字时间的纯 LRC 曲上使用：行内均分回退） */
    fun setKaraoke(ratio: Float) {
        val v = ratio.coerceIn(0f, 1f)
        if (v == karaoke) return
        karaoke = v
        if (!animating) repaint()
    }

    /** 当前句的逐字时间（来自 KRC/QRC 明文，绝对毫秒）。空集合 = 该曲无逐字时间 */
    fun setWordTiming(words: List<LyricWord>) {
        if (words == curWords) return
        curWords = words
        buildCharTimes()
        repaint()
    }

    /** 播放位置（绝对毫秒）；逐字染色按它逐字推进，句尾唱完立即全亮，不等下一行 */
    fun setPosition(ms: Long) {
        if (ms == posMs) return
        posMs = ms
        if (!animating) repaint()
    }

    /** 把 words 映射到 curText 的每个字符上（空格不占时段）；对不齐就让 timed=false 走回退 */
    private fun buildCharTimes() {
        val text = curText
        charS = LongArray(text.length) { -1L }
        charE = LongArray(text.length) { -1L }
        timed = false
        if (text.isEmpty() || curWords.isEmpty()) return

        var wi = 0
        var wci = 0
        var matched = 0
        var visible = 0
        for (i in text.indices) {
            if (text[i] == ' ') continue
            visible++
            while (wi < curWords.size && curWords[wi].text.isBlank()) { wi++; wci = 0 }
            if (wi >= curWords.size) break
            val w = curWords[wi]
            val wordChars = w.text.count { it != ' ' }
            val k = wordChars.coerceAtLeast(1)
            val stepDur = w.durMs / k
            charS[i] = w.startMs + stepDur * wci
            charE[i] = charS[i] + stepDur
            matched++
            wci++
            if (wci >= k) { wi++; wci = 0 }
        }
        timed = visible > 0 && matched == visible
    }

    fun preferredHeightPx(): Int = (barHeight + if (toolbarOpen) toolbarGap + toolbarH else 0f).toInt()

    fun barHeightPx(): Int = barHeight.toInt()

    /** 工具条本身占的高度（含与栏体的间距），给窗口定位用 */
    fun toolbarTotalPx(): Float = if (toolbarOpen) toolbarGap + toolbarH else 0f

    // ===== 排版 =====

    private fun fontOf(size: Float): Font = kai.deriveFont(size)

    /** 带字距的文本宽度（与 Android 的 measureText + letterSpacing*size*len 同口径） */
    private fun measureW(size: Float, spacing: Float, s: String): Float {
        if (s.isEmpty()) return 0f
        val fm = getFontMetrics(fontOf(size))
        var w = 0f
        for (ch in s) w += fm.charWidth(ch)
        return w + spacing * size * s.length
    }

    private fun applySizes(scale: Float) {
        val k = (1f + fontStep * 0.08f) * scale
        curSize = sp(17f) * k
        nextSize = sp(11f) * k
        emptySize = sp(13f) * k
    }

    /** 按宽度折行（优先在空格 / 标点处断），返回每一行 */
    private fun wrap(text: String, size: Float, spacing: Float, maxW: Float): List<String> {
        if (measureW(size, spacing, text) <= maxW) return listOf(text)
        val out = ArrayList<String>()
        var start = 0
        while (start < text.length) {
            var fit = 0
            var i = 1
            while (i <= text.length - start) {
                if (measureW(size, spacing, text.substring(start, start + i)) <= maxW) fit = i else break
                i++
            }
            if (fit == 0) fit = 1
            if (fit < text.length - start) {
                val minBreak = max(1, fit - 5)
                for (j in fit downTo minBreak) {
                    val ch = text[start + j - 1]
                    if (ch == ' ' || ch == '，' || ch == '、' || ch == '。') { fit = j; break }
                }
            }
            out.add(text.substring(start, start + fit))
            start += fit
        }
        return out
    }

    /** 重算字号档位、折行与栏体高度（先缩到一行，仍放不下才折行） */
    private fun rebuild() {
        if (System.getenv("JZ_BAR_NOPAINT") == "1") return
        val w = if (width > 0) width.toFloat() else LyricsMetrics.barWidth
        val maxW = (w - padH * 2).coerceAtLeast(dp(40f))

        curLines = emptyList()
        nextLines = emptyList()
        buildCharTimes()

        if (emptyText.isNotEmpty() || curText.isEmpty()) {
            curLines = emptyList()
            applySizes(1f)
            barHeight = dp(66f)
            notifyHeight()
            repaint()
            return
        }

        var scale = 1f
        var fits = false
        while (scale >= 0.72f) {
            applySizes(scale)
            if (measureW(curSize, curSpacing, curText) <= maxW &&
                measureW(nextSize, nextSpacing, nextText) <= maxW
            ) {
                fits = true
                break
            }
            scale -= 0.03f
        }
        if (!fits) {
            applySizes(0.72f)
            scale = 0.72f
        }

        curLines = if (fits) listOf(curText) else wrap(curText, curSize, curSpacing, maxW).take(4)
        nextLines = if (nextText.isEmpty()) emptyList()
        else if (measureW(nextSize, nextSpacing, nextText) <= maxW) listOf(nextText)
        else wrap(nextText, nextSize, nextSpacing, maxW).take(2)

        val fmCur = getFontMetrics(fontOf(curSize))
        val fmNext = getFontMetrics(fontOf(nextSize))
        val curLineH = (fmCur.ascent + fmCur.descent).toFloat()
        val nextLineH = (fmNext.ascent + fmNext.descent).toFloat()
        val content = curLines.size * curLineH +
            (if (nextLines.isNotEmpty()) gapLine + nextLines.size * nextLineH else 0f)
        val need = content + dp(12f) + dp(10f)
        barHeight = max(dp(66f), need)

        notifyHeight()
        repaint()
    }

    private fun notifyHeight() {
        val h = preferredHeightPx()
        if (h != lastNotifiedHeight) {
            lastNotifiedHeight = h
            onHeightChanged?.invoke()
        }
    }

    override fun setBounds(x: Int, y: Int, w: Int, h: Int) {
        val widthChanged = w != width
        super.setBounds(x, y, w, h)
        if (widthChanged) rebuild()
    }

    private fun startAnim() {
        animTimer?.stop()
        animating = true
        progress = 0f
        val started = System.nanoTime()
        animTimer = Timer(16) { e ->
            val p = ((System.nanoTime() - started) / 1_000_000f / 300f).coerceIn(0f, 1f)
            // DecelerateInterpolator 等价：1 - (1-t)^2
            progress = 1f - (1f - p) * (1f - p)
            if (p >= 1f) {
                (e.source as? Timer)?.stop()
                animating = false
                progress = 1f
            }
            repaint()
        }.apply { start() }
    }

    // ===== 绘制 =====

    override fun paintComponent(g: Graphics) {
        val g2 = g.create() as Graphics2D
        try {
            g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON)
            g2.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON)
            g2.setRenderingHint(RenderingHints.KEY_RENDERING, RenderingHints.VALUE_RENDER_QUALITY)
            drawScene(g2)
        } finally {
            g2.dispose()
        }
    }

    private fun drawScene(g2: Graphics2D) {
        if (System.getenv("JZ_BAR_NOPAINT") == "1") return
        val w = width.toFloat()
        val barH = barHeight
        if (barH <= 0f) return
        // 朝上展开时：整幅画布下移一个工具条高度，栏体留在原来的屏幕位置
        // 工具条朝上时，组件布局是 [工具条][间距][栏体]，
        // 所以把"栏体"整体下移一个工具条高度来画。
        val shift = if (toolbarOpen && toolbarAbove) toolbarGap + toolbarH else 0f
        if (shift > 0f) g2.translate(0.0, shift.toDouble())
        drawPaper(g2, 0f, 0f, w, barH)

        if (emptyText.isNotEmpty()) {
            applySizes(1f)
            val baseline = barH / 2f + emptySize * 0.35f
            drawTracked(g2, emptyText, w / 2f, baseline, emptySize, 0f, withAlpha(rgb(pal.sub), 1f), center = true)
        } else if (animating) {
            drawPairAt(g2, prevCur, prevNext, -dp(10f) * progress, 1f - progress, false, 0f)
            drawPairAt(g2, curText, nextText, dp(10f) * (1f - progress), progress, false, karaoke)
        } else {
            drawPairAt(g2, curText, nextText, 0f, 1f, paused, karaoke)
        }

        drawLock(g2, w)

        // 空态（暂无歌词/加载中）也要能唤出工具条，否则"点不出来"
        if (toolbarOpen) drawToolbar(g2, w, barH, above = toolbarAbove)
    }

    private fun withAlpha(c: Color, a: Float): Color =
        Color(c.red, c.green, c.blue, (a * 255f).toInt().coerceIn(0, 255))

    private fun drawPaper(g2: Graphics2D, x0: Float, y0: Float, x1: Float, y1: Float) {
        g2.color = rgb(pal.paper)
        g2.fill(RoundRectangle2D.Float(x0, y0, x1 - x0, y1 - y0, corner, corner))

        g2.color = rgb(pal.edge)
        g2.stroke = BasicStroke(dp(0.9f))
        val d = edgePad * 2
        g2.draw(RoundRectangle2D.Float(x0 + edgePad, y0 + edgePad, x1 - x0 - d, y1 - y0 - d, corner, corner))

        g2.color = rgb(pal.rule)
        val ruleY = y0 + dp(1.6f)
        g2.fillRect((x0 + dp(7f)).toInt(), ruleY.toInt(), (x1 - x0 - dp(14f)).toInt(), dp(1.3f).toInt().coerceAtLeast(1))
    }

    /**
     * 逐字绘制：先按整体左缘定位，再逐字推进。
     * @param x 若 center=true，x 是整行的中心；否则 x 是左缘
     */
    private fun drawTracked(
        g2: Graphics2D,
        s: String,
        x: Float,
        baseline: Float,
        size: Float,
        spacing: Float,
        color: Color,
        center: Boolean
    ) {
        if (s.isEmpty()) return
        val fm = getFontMetrics(fontOf(size))
        val total = measureW(size, spacing, s)
        var cx = if (center) x - total / 2f else x
        g2.font = fontOf(size)
        g2.color = color
        val orig = g2.color
        for (ch in s) {
            g2.drawString(ch.toString(), cx, baseline)
            cx += fm.charWidth(ch) + spacing * size
        }
        g2.color = orig
    }

    /** 两行作为一块竖直居中；ratio>0 时按进度逐字压深 */
    private var dbgMs2 = 0L

    /** 取"宽度不超过 w 的最长前缀"，用于把已唱部分压成实墨（替代 clipRect，实测裁剪不生效） */
    private fun sungPrefix(text: String, w: Float, size: Float, spacing: Float): String {
        if (w <= 0f) return ""
        var acc = 0f
        val sb = StringBuilder()
        for (ch in text) {
            val cw = measureW(size, spacing, ch.toString())
            if (acc + cw > w + 0.5f) break
            acc += cw
            sb.append(ch)
        }
        return sb.toString()
    }

    private fun drawPairAt(
        g2: Graphics2D, cur: String, next: String, dy: Float, alpha: Float, mark: Boolean, ratio: Float
    ) {
        val fmCur = getFontMetrics(fontOf(curSize))
        val fmNext = getFontMetrics(fontOf(nextSize))
        val curLineH = (fmCur.ascent + fmCur.descent).toFloat()
        val nextLineH = (fmNext.ascent + fmNext.descent).toFloat()

        val maxW = (width.toFloat() - padH * 2).coerceAtLeast(dp(40f))
        val lines = when {
            cur === curText -> curLines
            cur.isEmpty() -> emptyList()
            else -> wrap(cur, curSize, curSpacing, maxW)
        }
        val nLines = when {
            next === nextText -> nextLines
            next.isEmpty() -> emptyList()
            else -> wrap(next, nextSize, nextSpacing, maxW)
        }

        val block = lines.size * curLineH + (if (nLines.isNotEmpty()) gapLine + nLines.size * nextLineH else 0f)
        val top = (barHeight - block) / 2f + dy
        val w = width.toFloat()
        val cx = w / 2f

        // 当前句
        if (lines.isNotEmpty()) {
            val useTimed = timed && cur === curText
            val totalVis = lines.sumOf { l -> l.count { it != ' ' } }
            val sungVis = ratio * totalVis
            var accVis = 0
            var baseIdx = 0
            var y = top + fmCur.ascent
            // 当前句整块淡墨底：远远一眼就能看出"现在唱到这句"（#4）
            if (cur === curText && !mark) {
                val blockTop = top - dp(3f)
                val blockH = lines.size * curLineH + dp(6f)
                val blockW = maxW.coerceAtMost(w - dp(20f))
                g2.color = withAlpha(rgb(pal.ink), 0.06f * alpha)
                g2.fill(RoundRectangle2D.Float(cx - blockW / 2f, blockTop, blockW, blockH, dp(9f), dp(9f)))
            }
            for (line in lines) {
                val textW = measureW(curSize, curSpacing, line)
                var left = cx
                if (mark) {
                    val markW = dp(1f) * 2 + dp(4f)
                    val gapMark = dp(9f)
                    val groupW = textW + gapMark + markW
                    left = w / 2f - groupW / 2f + textW / 2f
                }
                // 未唱部分：淡墨（低对比）；唱过的字会在下面被重新压成实墨
                drawTracked(
                    g2, line, left, y, curSize, curSpacing,
                    withAlpha(rgb(if (mark) pal.sub else pal.ink), (if (mark) 0.85f else 0.30f) * alpha),
                    center = true
                )

                // 已唱部分压深
                if (!mark) {
                    var wSung = 0f
                    var ci = 0
                    var idx = baseIdx
                    if (useTimed) {
                        while (ci < line.length) {
                            val ch = line[ci]
                            val cw = measureW(curSize, curSpacing, ch.toString())
                            if (ch == ' ') {
                                wSung += cw
                            } else {
                                wSung += cw * charFill(idx)
                            }
                            ci++
                            idx++
                        }
                        // 逐字时间缺失/错位时的兜底：按整句进度（ratio）算一遍，取两者较大值。
                        // 不加这个兜底，只要 words 对不齐就会整句停在"未唱"的淡墨上（用户反馈的现象）。
                        if (ratio > 0.02f) {
                            var ci2 = 0
                            var wRatio = 0f
                            var used = 0f
                            val remain = sungVis - accVis
                            while (ci2 < line.length) {
                                val ch = line[ci2]
                                val cw = measureW(curSize, curSpacing, ch.toString())
                                if (ch == ' ') {
                                    wRatio += cw
                                } else if (used + 1f <= remain) {
                                    wRatio += cw
                                    used += 1f
                                } else {
                                    val part = (remain - used).coerceAtLeast(0f)
                                    wRatio += cw * part
                                    break
                                }
                                ci2++
                            }
                            if (wRatio > wSung) wSung = wRatio
                        }
                    } else if (ratio > 0f) {
                        val remain = sungVis - accVis
                        if (remain > 0f) {
                            var used = 0f
                            var done = false
                            while (ci < line.length && !done) {
                                val ch = line[ci]
                                val cw = measureW(curSize, curSpacing, ch.toString())
                                if (ch == ' ') {
                                    wSung += cw
                                    ci++
                                    continue
                                }
                                if (used + 1f <= remain) {
                                    wSung += cw
                                    used += 1f
                                    ci++
                                } else {
                                    val part = remain - used
                                    if (part > 0f) wSung += cw * part
                                    done = true
                                }
                            }
                        }
                    }
                    if (wSung > 0f) {
                        // 唱过的部分：按"前缀"重画一遍实墨。
                        // 之前用 clipRect + 整行重画，在这台机器上实测 clip 没生效（肉眼看仍是淡墨），
                        // 改成直接画前缀子串，不依赖裁剪。
                        val prefix = sungPrefix(line, wSung, curSize, curSpacing)
                        if (prefix.isNotEmpty()) {
                            val startX = left - textW / 2f
                            drawTracked(
                                g2, prefix, startX, y, curSize, curSpacing,
                                withAlpha(rgb(pal.ink), alpha), center = false
                            )
                        }
                    }
                }

                if (mark) drawPauseMark(g2, left + textW / 2f + dp(9f), y, fmCur, alpha)
                accVis += line.count { it != ' ' }
                baseIdx += line.length
                y += curLineH
            }
        }

        // 下一句
        if (nLines.isNotEmpty()) {
            var y = top + (if (lines.isNotEmpty()) lines.size * curLineH + gapLine else 0f) + fmNext.ascent
            for (line in nLines) {
                drawTracked(
                    g2, line, cx, y, nextSize, nextSpacing,
                    withAlpha(rgb(pal.sub), alpha * 0.9f), center = true
                )
                y += nextLineH
            }
        }
    }

    /** 暂停标记「‖」：两条 1dp 竖线，高 14dp */
    private fun drawPauseMark(g2: Graphics2D, left: Float, baseline: Float, fm: java.awt.FontMetrics, alpha: Float) {
        val barW = dp(1f)
        val gap = dp(4f)
        val barH = dp(14f)
        val centerY = baseline - (fm.ascent + fm.descent) / 2f + fm.ascent
        val top = centerY - barH / 2f
        g2.color = withAlpha(rgb(pal.sub), alpha * 0.78f)
        g2.fillRect(left.toInt(), top.toInt(), barW.toInt().coerceAtLeast(1), barH.toInt())
        g2.fillRect((left + barW + gap).toInt(), top.toInt(), barW.toInt().coerceAtLeast(1), barH.toInt())
    }

    /** 逐字染色：优先按每个字自己的起止时间（KRC/QRC），无逐字时间才回退行内均分 */
    private fun charFill(index: Int): Float {
        if (index < 0 || index >= charS.size) return 0f
        val s = charS[index]
        if (s < 0L) return 0f
        val e = charE[index]
        val span = (e - s).coerceAtLeast(1L)
        return when {
            posMs <= s -> 0f
            posMs >= e -> 1f
            else -> (posMs - s).toFloat() / span.toFloat()
        }
    }

    /** 右上角小锁：锁上为实心，未锁为空心 */
    private fun drawLock(g2: Graphics2D, w: Float) {
        if (!lockedFlag) return
        val cx = w - dp(11f)
        val cy = dp(11f)
        val bodyW = dp(6.4f)
        val bodyH = dp(4.6f)
        g2.color = withAlpha(rgb(pal.ink), 210f / 255f)
        g2.fill(RoundRectangle2D.Float(cx - bodyW / 2f, cy + dp(1.6f), bodyW, bodyH, dp(1f), dp(1f)))
        g2.stroke = BasicStroke(dp(1.1f))
        g2.draw(Arc2D.Float(cx - dp(2.5f), cy - dp(2.4f), dp(5f), dp(5.6f), 0f, 180f, Arc2D.OPEN))
    }

    // ===== 工具条 =====

    private fun drawToolbar(g2: Graphics2D, w: Float, barH: Float, above: Boolean = false) {
        // 朝上时画在栏体上方：画布已整体下移，负坐标正好落在工具条区域
        val top = if (above) -(toolbarGap + toolbarH) else barH + toolbarGap
        // 热区必须用**组件坐标**（未平移）：朝上时工具条就在 y=0..toolbarH 这一段，
        // 之前直接拿绘制坐标（负数）当热区，导致"工具条朝上时点不到"。
        val hitTop = if (above) 0f else barH + toolbarGap

        // 工具条自己也要有底：只画图标会透出桌面，看着像"透明的按钮条"
        drawPaper(g2, 0f, top, w, top + toolbarH)

        hitRects.clear()
        val pad = dp(16f)
        val cellW = (w - pad * 2) / 6f
        val cy = top + toolbarH / 2f

        g2.color = rgb(blend(pal.paper, 0x2C2822, 0.10f))
        for (i in 0 until 5) {
            val sx = pad + cellW * (i + 1)
            g2.fillRect(sx.toInt(), (top + dp(9f)).toInt(), 1, (toolbarH - dp(18f)).toInt())
        }

        val ink = rgb(pal.ink)
        g2.color = ink
        g2.stroke = BasicStroke(dp(1.1f))

        // 1 上一句
        var c = pad + cellW * 0.5f
        drawChevron(g2, c, cy, left = true)
        hitRects.add(java.awt.geom.Rectangle2D.Float(c - cellW / 2f, hitTop, cellW, toolbarH) to LyricsBarAction.PREV)

        // 2 播放 / 暂停
        c = pad + cellW * 1.5f
        if (paused) drawPlayTriangle(g2, c, cy) else drawPauseBars(g2, c, cy)
        hitRects.add(java.awt.geom.Rectangle2D.Float(c - cellW / 2f, hitTop, cellW, toolbarH) to LyricsBarAction.PLAY_PAUSE)

        // 3 下一句
        c = pad + cellW * 2.5f
        drawChevron(g2, c, cy, left = false)
        hitRects.add(java.awt.geom.Rectangle2D.Float(c - cellW / 2f, hitTop, cellW, toolbarH) to LyricsBarAction.NEXT)

        // 4 字号 A- / A+（一格两热区）
        c = pad + cellW * 3.5f
        g2.font = fontOf(sp(13f))
        g2.color = ink
        drawCentered(g2, "A-", c - dp(13f), cy + dp(4.5f))
        drawCentered(g2, "A+", c + dp(13f), cy + dp(4.5f))
        hitRects.add(java.awt.geom.Rectangle2D.Float(c - cellW / 2f, hitTop, cellW / 2f, toolbarH) to LyricsBarAction.FONT_MINUS)
        hitRects.add(java.awt.geom.Rectangle2D.Float(c, hitTop, cellW / 2f, toolbarH) to LyricsBarAction.FONT_PLUS)

        // 5 锁定
        c = pad + cellW * 4.5f
        drawLockIcon(g2, c, cy, lockedFlag)
        hitRects.add(java.awt.geom.Rectangle2D.Float(c - cellW / 2f, hitTop, cellW, toolbarH) to LyricsBarAction.LOCK)

        // 6 关闭
        c = pad + cellW * 5.5f
        drawCloseIcon(g2, c, cy)
        hitRects.add(java.awt.geom.Rectangle2D.Float(c - cellW / 2f, hitTop, cellW, toolbarH) to LyricsBarAction.CLOSE)
    }

    private fun drawCentered(g2: Graphics2D, s: String, cx: Float, baseline: Float) {
        val fm = g2.fontMetrics
        g2.drawString(s, cx - fm.stringWidth(s) / 2f, baseline)
    }

    /** 箭头：left=true 指向左（上一句），left=false 指向右（下一句） */
    private fun drawChevron(g2: Graphics2D, cx: Float, cy: Float, left: Boolean) {
        val s = if (left) -1f else 1f
        val dx = dp(3.6f)
        val dy = dp(5.6f)
        val p = Path2D.Float()
        p.moveTo(cx - s * dx, cy - dy)
        p.lineTo(cx + s * dx, cy)
        p.lineTo(cx - s * dx, cy + dy)
        g2.stroke = BasicStroke(dp(1.4f))
        g2.draw(p)
    }

    private fun drawPlayTriangle(g2: Graphics2D, cx: Float, cy: Float) {
        val p = Path2D.Float()
        p.moveTo(cx - dp(4f), cy - dp(6f))
        p.lineTo(cx - dp(4f), cy + dp(6f))
        p.lineTo(cx + dp(6.5f), cy)
        p.closePath()
        g2.fill(p)
    }

    private fun drawPauseBars(g2: Graphics2D, cx: Float, cy: Float) {
        val bw = dp(1.1f).toInt().coerceAtLeast(1)
        val h = dp(12f)
        g2.fillRect((cx - dp(4f)).toInt(), (cy - h / 2f).toInt(), bw, h.toInt())
        g2.fillRect((cx + dp(2.5f)).toInt(), (cy - h / 2f).toInt(), bw, h.toInt())
    }

    private fun drawLockIcon(g2: Graphics2D, cx: Float, cy: Float, on: Boolean) {
        g2.stroke = BasicStroke(dp(1.2f))
        if (on) {
            g2.fill(RoundRectangle2D.Float(cx - dp(5f), cy - dp(1f), dp(10f), dp(7.6f), dp(1.4f), dp(1.4f)))
            g2.draw(Arc2D.Float(cx - dp(3.6f), cy - dp(7.5f), dp(7.2f), dp(8.7f), 0f, 180f, Arc2D.OPEN))
        } else {
            g2.draw(RoundRectangle2D.Float(cx - dp(5f), cy - dp(1f), dp(10f), dp(7.6f), dp(1.4f), dp(1.4f)))
            g2.draw(Arc2D.Float(cx - dp(3.6f), cy - dp(7.5f), dp(7.2f), dp(8.7f), 0f, 180f, Arc2D.OPEN))
        }
    }

    private fun drawCloseIcon(g2: Graphics2D, cx: Float, cy: Float) {
        g2.stroke = BasicStroke(dp(1.2f))
        val p = Path2D.Float()
        p.moveTo(cx - dp(4f), cy - dp(4f))
        p.lineTo(cx + dp(4f), cy + dp(4f))
        p.moveTo(cx + dp(4f), cy - dp(4f))
        p.lineTo(cx - dp(4f), cy + dp(4f))
        g2.draw(p)
    }

    // ===== 鼠标 =====

    private fun installMouse() {
        val handler = object : MouseAdapter() {
            override fun mousePressed(e: MouseEvent) {
                val barH = barHeight
                downRawX = e.xOnScreen.toFloat()
                downRawY = e.yOnScreen.toFloat()
                dragging = false
                movedAway = false
                pressedAction = null
                if (toolbarOpen) {
                    // 工具条在"栏体下方"还是"栏体上方"，命中区域完全不同：
                    // 朝上时它在组件顶部（0..toolbarGap+toolbarH），朝下时在栏体底边之下。
                    val inToolbarArea =
                        if (toolbarAbove) e.y < toolbarGap + toolbarH + 2 else e.y > barH - 2
                    if (inToolbarArea) {
                        val px = e.x.toFloat()
                        val py = e.y.toFloat()
                        pressedAction = hitRects.firstOrNull { it.first.contains(px.toDouble(), py.toDouble()) }?.second
                        collapseTimer.stop()
                    }
                }
            }

            override fun mouseDragged(e: MouseEvent) {
                val dx = e.xOnScreen - downRawX
                val dy = e.yOnScreen - downRawY
                if (pressedAction != null) return
                if (!movedAway && (Math.abs(dx) > touchSlop || Math.abs(dy) > touchSlop)) {
                    movedAway = true
                    if (!lockedFlag) {
                        dragging = true
                        // 拖动前收起工具条：这里也要走回调把**状态**关掉，
                        // 否则状态还停在 true，下一次点击又是"点了没反应"
                        if (toolbarOpen) onRequestCollapse?.invoke()
                        onDragStart?.invoke()
                    }
                }
                if (dragging) onDragMove?.invoke(dx, dy)
            }

            override fun mouseReleased(e: MouseEvent) {
                val action = pressedAction
                pressedAction = null
                if (action != null) {
                    onAction?.invoke(action)
                    scheduleCollapse()
                    return
                }
                val wasDrag = dragging
                dragging = false
                if (wasDrag) {
                    onDragEnd?.invoke()
                } else if (!movedAway) {
                    onTapBar?.invoke()
                }
                movedAway = false
            }
        }
        addMouseListener(handler)
        addMouseMotionListener(handler)
    }

    /** 窗口尺寸/内容变化后在 EDT 上重排（外部线程调用安全） */
    fun requestRebuild() {
        if (SwingUtilities.isEventDispatchThread()) rebuild() else SwingUtilities.invokeLater { rebuild() }
    }
}

/**
 * 桌面歌词栏的整栏缩放：手机 308dp 的版式原样放大到桌面屏宽能看清的程度。
 * 只改"一个 dp 等于多少像素"，栏体比例、字号档位、折行规则全部沿用 Android 版。
 */
object LyricsMetrics {
    /** 相对 1dp 的放大倍数（1600 高的屏幕上一栏约 790×115px，1 米外可读） */
    const val scale: Float = 1.6f

    /** 栏体宽度（用户坐标 px） */
    val barWidth: Float get() = 308f * scale
}

/**
 * 霞鹜文楷（随包分发的 19MB TTF）。每挂一次窗都重新解一遍会明显卡顿，进程内缓存一份。
 * 先从 classpath（jar 内）读，失败再退回系统"楷体"，保证任何情况下都有中文可用。
 */
object LyricFonts {

    @Volatile
    private var cached: Font? = null

    fun kai(): Font {
        cached?.let { return it }
        val f = runCatching {
            val bytes = LyricFonts::class.java.classLoader
                ?.getResourceAsStream("font/lxgw_wenkai_regular.ttf")?.use { it.readBytes() }
                ?: return@runCatching null
            val tmp = File.createTempFile("jz_kai", ".ttf").apply { deleteOnExit() }
            tmp.writeBytes(bytes)
            Font.createFont(Font.TRUETYPE_FONT, tmp)
        }.getOrNull() ?: runCatching {
            // 退回系统楷体（Windows 自带 KaiTi），再不行用黑体
            Font("KaiTi", Font.PLAIN, 17).takeIf { it.family != "Dialog" }
        }.getOrNull() ?: Font(Font.SANS_SERIF, Font.PLAIN, 17)
        cached = f
        return f
    }
}

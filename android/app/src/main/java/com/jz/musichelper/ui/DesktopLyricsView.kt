package com.jz.musichelper.ui

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.text.TextPaint
import android.util.TypedValue
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.DecelerateInterpolator
import androidx.core.content.res.ResourcesCompat
import com.jz.musichelper.R
import com.jz.musichelper.network.LyricWord
import kotlin.math.max
import kotlin.math.min

/** 工具条上的七个动作（六个格子，字号格切成 A- / A+ 两个热区） */
enum class LyricsBarAction { PREV, PLAY_PAUSE, NEXT, FONT_MINUS, FONT_PLUS, LOCK, CLOSE }

/**
 * 桌面歌词栏（悬浮窗内部视图，原生自绘）。v2.1.79 起：
 *
 *  1. 逐字染色：**按 KRC/QRC 的原生逐字毫秒时间**推进（每个字有自己的起止时间，
 *     不再按字数均分）；没有逐字时间的纯 LRC 曲回退到行内插值
 *  2. 底边进度线已移除（v2.1.78 的渐变槽 + 圆头版本整段删除），只留逐字染色
 *  3. 锁定：右上角小锁；锁上后不再响应拖动，避免看视频时把歌词拖飞
 *  4. 工具条：轻点纸签浮出一排按钮（上一句 / 暂停 / 下一句 / 字号 A- A+ / 锁定 / 关闭），
 *     3 秒无操作自动收起
 *  5. 三套纸色：素纸 / 旧黄 / 夜墨，由设置页切换
 *  6. 字号五档：整行等比缩放，配合"按句长自动降档"，彻底不再出现省略号
 *
 * 视觉口径仍是「墨边纸签」：实底纸色、小圆角（不做胶囊）、上缘一道压墨线、外圈细线、
 * 无投影无毛玻璃、霞鹜文楷。
 */
class DesktopLyricsView(context: Context) : View(context) {

    var onDragStart: (() -> Unit)? = null
    var onDragMove: ((Float, Float) -> Unit)? = null
    var onDragEnd: (() -> Unit)? = null
    /** 纸签被轻点：展开 / 收起工具条 */
    var onTapBar: (() -> Unit)? = null
    /** 工具条按钮 */
    var onAction: ((LyricsBarAction) -> Unit)? = null
    /** 需要的窗口高度变了（折行 / 展开工具条），外层据此更新 WindowManager.LayoutParams */
    var onHeightChanged: (() -> Unit)? = null

    private val density = resources.displayMetrics.density
    private fun dp(v: Float): Float = v * density
    private fun sp(v: Float): Float =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, v, resources.displayMetrics)

    private val typeface: Typeface? = kaiTypeface(context)

    // ===== 纸色 =====
    private data class Palette(
        val paper: Int, val ink: Int, val light: Int, val sub: Int,
        val rule: Int, val edge: Int, val track: Int, val fill: Int
    )

    private fun blend(base: Int, ink: Int, a: Float): Int = Color.argb(
        255,
        (Color.red(base) * (1f - a) + Color.red(ink) * a).toInt(),
        (Color.green(base) * (1f - a) + Color.green(ink) * a).toInt(),
        (Color.blue(base) * (1f - a) + Color.blue(ink) * a).toInt()
    )

    private fun paletteFor(index: Int): Palette = when (index) {
        1 -> {
            val paper = Color.parseColor("#F2E5C4")
            Palette(paper, Color.parseColor("#30281C"), Color.parseColor("#A89268"), Color.parseColor("#967C5C"),
                blend(paper, 0x3E2E1A, 0.46f), blend(paper, 0x3E2E1A, 0.28f),
                blend(paper, 0x30281C, 0.10f), blend(paper, 0x30281C, 0.62f))
        }
        2 -> {
            val paper = Color.parseColor("#24211D")
            Palette(paper, Color.parseColor("#F0EADA"), Color.parseColor("#706A5E"), Color.parseColor("#948F82"),
                blend(paper, 0xECE4D2, 0.30f), blend(paper, 0xECE4D2, 0.14f),
                blend(paper, 0xECE4D2, 0.12f), blend(paper, 0xECE4D2, 0.55f))
        }
        else -> {
            val paper = Color.parseColor("#FBF7ED")
            Palette(paper, Color.parseColor("#2C2822"), Color.parseColor("#B0A898"), Color.parseColor("#8A8378"),
                blend(paper, 0x2C2822, 0.46f), blend(paper, 0x2C2822, 0.26f),
                blend(paper, 0x2C2822, 0.10f), blend(paper, 0x2C2822, 0.62f))
        }
    }

    private var pal: Palette = paletteFor(0)

    // ===== 画笔 =====
    private val curPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(17f); letterSpacing = 0.03f
        textAlign = Paint.Align.CENTER; typeface = this@DesktopLyricsView.typeface
    }
    private val nextPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(11f); letterSpacing = 0.02f
        textAlign = Paint.Align.CENTER; typeface = this@DesktopLyricsView.typeface
    }
    private val emptyPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(13f); textAlign = Paint.Align.CENTER; typeface = this@DesktopLyricsView.typeface
    }
    private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val iconStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val rect = RectF()
    private val path = Path()

    private val corner = dp(3f)
    private val edgePad = dp(0.7f)
    private val padH = dp(10f)          // 左右内边（旧版 16dp 是截断主因之一）
    private val gapLine = dp(8f)
    private val toolbarH = dp(46f)
    private val toolbarGap = dp(8f)

    // ===== 状态 =====
    private var themeIdx = 0
    private var fontStep = 0            // -2..2，步进 8%
    private var lockedFlag = false
    private var toolbarOpen = false
    private var paused = false
    private var karaoke = 0f            // 当前句进度 0..1（无逐字时间时的回退口径）

    // ===== 逐字时间（v2.1.79）=====
    private var curWords: List<LyricWord> = emptyList()
    private var posMs = 0L              // 播放位置（绝对毫秒）
    private var charS = LongArray(0)    // 按 curText 字符索引：该字起唱时间
    private var charE = LongArray(0)    // 按 curText 字符索引：该字唱完时间
    private var timed = false           // 逐字时间是否可用（字符数与词条能对上才算）

    private var curText = ""
    private var nextText = ""
    private var emptyText = ""
    private var curLines: List<String> = emptyList()
    private var nextLines: List<String> = emptyList()
    private var barHeight = 0f
    private var contentTop = 0f

    private var animating = false
    private var progress = 0f
    private var prevCur = ""
    private var prevNext = ""
    private var animator: ValueAnimator? = null
    private var lastNotifiedHeight = -1

    private val hitRects = ArrayList<Pair<RectF, LyricsBarAction>>()

    // 拖动
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var downRawX = 0f
    private var downRawY = 0f
    private var dragging = false
    private var movedAway = false
    private var pressedAction: LyricsBarAction? = null

    private val collapseTask = Runnable { setToolbar(false) }

    init {
        setWillNotDraw(false)
        isClickable = true
        rebuild()
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
        invalidate()
    }

    fun isToolbarOpen(): Boolean = toolbarOpen

    fun setToolbar(open: Boolean) {
        if (toolbarOpen == open) {
            if (open) scheduleCollapse()
            return
        }
        toolbarOpen = open
        if (open) scheduleCollapse() else removeCallbacks(collapseTask)
        notifyHeight()
        invalidate()
    }

    private fun scheduleCollapse() {
        removeCallbacks(collapseTask)
        postDelayed(collapseTask, 3000L)
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
            animator?.cancel()
            animating = false
            curText = cur
            nextText = next
            emptyText = ""
            rebuild()
        }
    }

    fun setEmpty(text: String) {
        animator?.cancel()
        animating = false
        curText = ""
        nextText = ""
        emptyText = text
        rebuild()
    }

    fun setPaused(value: Boolean) {
        if (paused == value) return
        paused = value
        invalidate()
    }

    /** 当前句进度 0..1（只在没有逐字时间的纯 LRC 曲上使用：行内均分回退） */
    fun setKaraoke(ratio: Float) {
        val v = ratio.coerceIn(0f, 1f)
        if (v == karaoke) return
        karaoke = v
        if (!animating) invalidate()
    }

    /** 当前句的逐字时间（来自 KRC/QRC 明文，绝对毫秒）。空集合 = 该曲无逐字时间 */
    fun setWordTiming(words: List<LyricWord>) {
        if (words == curWords) return
        curWords = words
        buildCharTimes()
        invalidate()
    }

    /** 播放位置（绝对毫秒）；逐字染色按它逐字推进，句尾唱完立即全亮，不等下一行 */
    fun setPosition(ms: Long) {
        if (ms == posMs) return
        posMs = ms
        if (!animating) invalidate()
    }

    /** 把 words 映射到 curText 的每个字符上（空格不占时段）；对不齐就让 timed=false 走回退，
     * 且未映射的字符用 -1 标记，绝不能被当成"已唱满"（LongArray 默认 0 会导致误亮）。 */
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
            // 跳过不含可见字符的词条
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
        // 只有每个可见字都拿到时间才算"逐字时间可用"，否则整行退回行内插值（宁可粗，不要错）
        timed = visible > 0 && matched == visible
    }

    fun preferredHeightPx(): Int = (barHeight + if (toolbarOpen) toolbarGap + toolbarH else 0f).toInt()

    fun barHeightPx(): Int = barHeight.toInt()

    // ===== 排版 =====

    private fun measureW(p: TextPaint, s: String): Float =
        p.measureText(s) + p.letterSpacing * p.textSize * s.length

    private fun applySizes(scale: Float) {
        val k = (1f + fontStep * 0.08f) * scale
        curPaint.textSize = sp(17f) * k
        nextPaint.textSize = sp(11f) * k
        emptyPaint.textSize = sp(13f) * k
    }

    /** 按宽度折行（优先在空格 / 标点处断），返回每一行 */
    private fun wrap(text: String, p: TextPaint, maxW: Float): List<String> {
        if (measureW(p, text) <= maxW) return listOf(text)
        val out = ArrayList<String>()
        var start = 0
        while (start < text.length) {
            var fit = 0
            var i = 1
            while (i <= text.length - start) {
                if (measureW(p, text.substring(start, start + i)) <= maxW) fit = i else break
                i++
            }
            if (fit == 0) fit = 1
            // 尽量断在空格或标点后，避免把词拆开
            if (fit < text.length - start) {
                val minBreak = max(1, fit - 5)
                for (j in fit downTo minBreak) {
                    val ch = text[start + j - 1]
                    if (ch == ' ' || ch == '，' || ch == '、' || ch == '。' || ch == ' ') { fit = j; break }
                }
            }
            out.add(text.substring(start, start + fit))
            start += fit
        }
        return out
    }

    /**
     * 重算字号档位、折行与栏体高度。
     * 先把整句缩到能放下一行（下限 0.72 倍），仍放不下才折行 —— 一切为了"不出现省略号"。
     */
    private fun rebuild() {
        val w = width.toFloat().takeIf { it > 0f } ?: resources.displayMetrics.widthPixels.toFloat()
        val maxW = (w - padH * 2).coerceAtLeast(dp(40f))

        curLines = emptyList()
        nextLines = emptyList()
        buildCharTimes()

        if (emptyText.isNotEmpty() || curText.isEmpty()) {
            curLines = emptyList()
            applySizes(1f)
            barHeight = dp(66f)
            contentTop = 0f
            notifyHeight()
            invalidate()
            return
        }

        var scale = 1f
        var fits = false
        while (scale >= 0.72f) {
            applySizes(scale)
            if (measureW(curPaint, curText) <= maxW && measureW(nextPaint, nextText) <= maxW) {
                fits = true
                break
            }
            scale -= 0.03f
        }
        if (!fits) {
            applySizes(0.72f)
            scale = 0.72f
        }

        curLines = if (fits) listOf(curText) else wrap(curText, curPaint, maxW).take(4)
        nextLines = if (nextText.isEmpty()) emptyList() else if (measureW(nextPaint, nextText) <= maxW)
            listOf(nextText) else wrap(nextText, nextPaint, maxW).take(2)

        val fmCur = curPaint.fontMetrics
        val fmNext = nextPaint.fontMetrics
        val curLineH = fmCur.descent - fmCur.ascent
        val nextLineH = fmNext.descent - fmNext.ascent
        val content = curLines.size * curLineH +
            (if (nextLines.isNotEmpty()) gapLine + nextLines.size * nextLineH else 0f)
        // 进度线已移除（v2.1.79）：底边不再预留 16dp，收紧为 10dp，文字块更居中
        val need = content + dp(12f) + dp(10f)
        barHeight = max(dp(66f), need)

        notifyHeight()
        invalidate()
    }

    private fun notifyHeight() {
        val h = preferredHeightPx()
        if (h != lastNotifiedHeight) {
            lastNotifiedHeight = h
            onHeightChanged?.invoke()
        }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        rebuild()
    }

    private fun startAnim() {
        animator?.cancel()
        animating = true
        progress = 0f
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 300L
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                progress = it.animatedValue as Float
                invalidate()
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) {
                    animating = false
                    progress = 1f
                    invalidate()
                }
            })
            start()
        }
    }

    // ===== 绘制 =====

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val barH = barHeight
        if (barH <= 0f) return

        drawPaper(canvas, 0f, 0f, w, barH)

        if (emptyText.isNotEmpty()) {
            applySizes(1f)
            emptyPaint.color = pal.sub
            val fm = emptyPaint.fontMetrics
            val baseline = barH / 2f - (fm.ascent + fm.descent) / 2f
            canvas.drawText(emptyText, w / 2f, baseline, emptyPaint)
            drawLock(canvas, w, barH)
            return
        }

        if (animating) {
            // 换句过渡：进场的新句直接用当前 ratio 染色，否则 300ms 动画期间停在 0，看起来总慢半拍
            drawPairAt(canvas, prevCur, prevNext, -dp(10f) * progress, 1f - progress, false, 0f)
            drawPairAt(canvas, curText, nextText, dp(10f) * (1f - progress), progress, false, karaoke)
        } else {
            drawPairAt(canvas, curText, nextText, 0f, 1f, paused, karaoke)
        }

        drawLock(canvas, w, barH)

        if (toolbarOpen) drawToolbar(canvas, w, barH)
    }

    private fun drawPaper(canvas: Canvas, x0: Float, y0: Float, x1: Float, y1: Float) {
        bgPaint.color = pal.paper
        rect.set(x0, y0, x1, y1)
        canvas.drawRoundRect(rect, corner, corner, bgPaint)

        strokePaint.color = pal.edge
        strokePaint.strokeWidth = dp(0.9f)
        rect.set(x0 + edgePad, y0 + edgePad, x1 - edgePad, y1 - edgePad)
        canvas.drawRoundRect(rect, corner, corner, strokePaint)

        linePaint.color = pal.rule
        val ruleY = y0 + dp(1.6f)
        canvas.drawRect(x0 + dp(7f), ruleY, x1 - dp(7f), ruleY + dp(1.3f), linePaint)
    }

    /** 两行作为一块竖直居中；ratio>0 时按进度逐字压深 */
    private fun drawPairAt(
        canvas: Canvas, cur: String, next: String, dy: Float, alpha: Float, mark: Boolean, ratio: Float
    ) {
        val fmCur = curPaint.fontMetrics
        val fmNext = nextPaint.fontMetrics
        val curLineH = fmCur.descent - fmCur.ascent
        val nextLineH = fmNext.descent - fmNext.ascent

        val maxW = (width.toFloat() - padH * 2).coerceAtLeast(dp(40f))
        val lines = when {
            cur === curText -> curLines
            cur.isEmpty() -> emptyList()
            else -> wrap(cur, curPaint, maxW)
        }
        val nLines = when {
            next === nextText -> nextLines
            next.isEmpty() -> emptyList()
            else -> wrap(next, nextPaint, maxW)
        }

        val block = lines.size * curLineH + (if (nLines.isNotEmpty()) gapLine + nLines.size * nextLineH else 0f)
        val top = (barHeight - block) / 2f + dy
        val w = width.toFloat()
        val cx = w / 2f

        // 当前句
        if (lines.isNotEmpty()) {
            // 逐字时间模式：每个字按自己的 start/end 推进；否则回退行内均分
            val useTimed = timed && cur === curText
            val totalVis = lines.sumOf { l -> l.count { it != ' ' } }
            val sungVis = ratio * totalVis
            var accVis = 0
            var baseIdx = 0
            var y = top - fmCur.ascent
            for (line in lines) {
                val textW = measureW(curPaint, line)
                var left = cx
                if (mark) {
                    val markW = dp(1f) * 2 + dp(4f)
                    val gapMark = dp(9f)
                    val groupW = textW + gapMark + markW
                    left = w / 2f - groupW / 2f + textW / 2f
                }
                // 淡墨铺底
                curPaint.color = if (mark) pal.sub else pal.light
                curPaint.alpha = (alpha * 255f).toInt().coerceIn(0, 255)
                canvas.drawText(line, left, y, curPaint)

                // 已唱部分压深
                if (!mark) {
                    var wSung = 0f
                    var ci = 0
                    var idx = baseIdx
                    if (useTimed) {
                        // 逐字时间：字内按 (pos-start)/dur 部分压深；唱完立即整字实心
                        while (ci < line.length) {
                            val ch = line[ci]
                            val cw = measureW(curPaint, ch.toString())
                            if (ch == ' ') {
                                wSung += cw
                            } else {
                                wSung += cw * charFill(idx)
                            }
                            ci++
                            idx++
                        }
                    } else if (ratio > 0f) {
                        // 回退：可见字等权 + 字内连续推进
                        val remain = sungVis - accVis
                        if (remain > 0f) {
                            var used = 0f
                            var done = false
                            while (ci < line.length && !done) {
                                val ch = line[ci]
                                val cw = measureW(curPaint, ch.toString())
                                if (ch == ' ') {
                                    wSung += cw               // 空格不占时段，只带宽度
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
                        canvas.save()
                        canvas.clipRect(left - textW / 2f - dp(4f), y + fmCur.ascent - dp(2f),
                            left - textW / 2f + min(wSung, textW), y + fmCur.descent + dp(2f))
                        curPaint.color = pal.ink
                        canvas.drawText(line, left, y, curPaint)
                        canvas.restore()
                    }
                }

                if (mark) drawPauseMark(canvas, left + textW / 2f + dp(9f), y, fmCur, alpha)
                accVis += line.count { it != ' ' }
                baseIdx += line.length
                y += curLineH
            }
            curPaint.alpha = 255
        }

        // 下一句
        if (nLines.isNotEmpty()) {
            var y = top + (if (lines.isNotEmpty()) lines.size * curLineH + gapLine else 0f) - fmNext.ascent
            nextPaint.color = pal.sub
            nextPaint.alpha = (alpha * 255f * 0.9f).toInt().coerceIn(0, 255)
            for (line in nLines) {
                canvas.drawText(line, cx, y, nextPaint)
                y += nextLineH
            }
            nextPaint.alpha = 255
        }
    }

    /** 暂停标记「‖」：两条 1dp 竖线，高 14dp */
    private fun drawPauseMark(canvas: Canvas, left: Float, baseline: Float, fm: Paint.FontMetrics, alpha: Float) {
        val barW = dp(1f)
        val gap = dp(4f)
        val barH = dp(14f)
        val centerY = baseline + (fm.ascent + fm.descent) / 2f
        val top = centerY - barH / 2f
        linePaint.color = pal.sub
        linePaint.alpha = (alpha * 255f * 0.78f).toInt().coerceIn(0, 255)
        canvas.drawRect(left, top, left + barW, top + barH, linePaint)
        canvas.drawRect(left + barW + gap, top, left + barW + gap + barW, top + barH, linePaint)
        linePaint.alpha = 255
    }

    /** 逐字染色：优先按每个字自己的起止时间（KRC/QRC），无逐字时间才回退行内均分 */
    private fun charFill(index: Int): Float {
        if (index < 0 || index >= charS.size) return 0f
        val s = charS[index]
        if (s < 0L) return 0f                     // 未映射（映射不全时整行已退回均分，这里只防御）
        val e = charE[index]
        val span = (e - s).coerceAtLeast(1L)
        return when {
            posMs <= s -> 0f
            posMs >= e -> 1f
            else -> (posMs - s).toFloat() / span.toFloat()
        }
    }

    /** 右上角小锁：锁上为实心，未锁为空心 */
    private fun drawLock(canvas: Canvas, w: Float, barH: Float) {
        if (!lockedFlag) return
        val cx = w - dp(11f)
        val cy = dp(11f)
        val bodyW = dp(6.4f)
        val bodyH = dp(4.6f)
        iconPaint.color = pal.ink
        iconPaint.alpha = 210
        rect.set(cx - bodyW / 2f, cy + dp(1.6f), cx + bodyW / 2f, cy + dp(1.6f) + bodyH)
        canvas.drawRoundRect(rect, dp(1f), dp(1f), iconPaint)
        iconStroke.color = pal.ink
        iconStroke.strokeWidth = dp(1.1f)
        iconStroke.alpha = 210
        rect.set(cx - dp(2.5f), cy - dp(2.4f), cx + dp(2.5f), cy + dp(3.2f))
        canvas.drawArc(rect, 180f, 180f, false, iconStroke)
        iconPaint.alpha = 255
        iconStroke.alpha = 255
    }

    // ===== 工具条 =====

    private fun drawToolbar(canvas: Canvas, w: Float, barH: Float) {
        val top = barH + toolbarGap
        drawPaper(canvas, 0f, top, w, top + toolbarH)

        hitRects.clear()
        val pad = dp(16f)
        val cellW = (w - pad * 2) / 6f
        val cy = top + toolbarH / 2f

        for (i in 0 until 6) {
            val cellLeft = pad + cellW * i
            val cellRight = cellLeft + cellW
            if (i < 5) {
                val sx = cellRight
                linePaint.color = blend(pal.paper, 0x2C2822, if (themeIdx == 2) 0.10f else 0.10f)
                canvas.drawRect(sx - dp(0.4f), top + dp(9f), sx + dp(0.4f), top + toolbarH - dp(9f), linePaint)
            }
        }

        iconPaint.color = pal.ink
        iconStroke.color = pal.ink
        iconStroke.strokeWidth = dp(1.1f)

        // 1 上一句
        var c = pad + cellW * 0.5f
        drawChevron(canvas, c, cy, left = true)
        hitRects.add(RectF(c - cellW / 2f, top, c + cellW / 2f, top + toolbarH) to LyricsBarAction.PREV)

        // 2 播放 / 暂停
        c = pad + cellW * 1.5f
        if (paused) drawPlayTriangle(canvas, c, cy) else drawPauseBars(canvas, c, cy)
        hitRects.add(RectF(c - cellW / 2f, top, c + cellW / 2f, top + toolbarH) to LyricsBarAction.PLAY_PAUSE)

        // 3 下一句
        c = pad + cellW * 2.5f
        drawChevron(canvas, c, cy, left = false)
        hitRects.add(RectF(c - cellW / 2f, top, c + cellW / 2f, top + toolbarH) to LyricsBarAction.NEXT)

        // 4 字号 A- / A+（一格两热区）
        c = pad + cellW * 3.5f
        val fa = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = sp(13f)
            color = pal.ink
            textAlign = Paint.Align.CENTER
            typeface = this@DesktopLyricsView.typeface
        }
        canvas.drawText("A-", c - dp(13f), cy + dp(4.5f), fa)
        canvas.drawText("A+", c + dp(13f), cy + dp(4.5f), fa)
        hitRects.add(RectF(c - cellW / 2f, top, c, top + toolbarH) to LyricsBarAction.FONT_MINUS)
        hitRects.add(RectF(c, top, c + cellW / 2f, top + toolbarH) to LyricsBarAction.FONT_PLUS)

        // 5 锁定
        c = pad + cellW * 4.5f
        drawLockIcon(canvas, c, cy, lockedFlag)
        hitRects.add(RectF(c - cellW / 2f, top, c + cellW / 2f, top + toolbarH) to LyricsBarAction.LOCK)

        // 6 关闭
        c = pad + cellW * 5.5f
        drawCloseIcon(canvas, c, cy)
        hitRects.add(RectF(c - cellW / 2f, top, c + cellW / 2f, top + toolbarH) to LyricsBarAction.CLOSE)
    }

    /** 箭头：left=true 指向左（上一句），left=false 指向右（下一句） */
    private fun drawChevron(canvas: Canvas, cx: Float, cy: Float, left: Boolean) {
        val s = if (left) -1f else 1f
        val dx = dp(3.6f)
        val dy = dp(5.6f)
        path.reset()
        path.moveTo(cx - s * dx, cy - dy)
        path.lineTo(cx + s * dx, cy)
        path.lineTo(cx - s * dx, cy + dy)
        iconStroke.strokeWidth = dp(1.4f)
        canvas.drawPath(path, iconStroke)
    }

    private fun drawPlayTriangle(canvas: Canvas, cx: Float, cy: Float) {
        path.reset()
        path.moveTo(cx - dp(4f), cy - dp(6f))
        path.lineTo(cx - dp(4f), cy + dp(6f))
        path.lineTo(cx + dp(6.5f), cy)
        path.close()
        canvas.drawPath(path, iconPaint)
    }

    private fun drawPauseBars(canvas: Canvas, cx: Float, cy: Float) {
        val bw = dp(1.1f)
        val h = dp(12f)
        canvas.drawRect(cx - dp(4f), cy - h / 2f, cx - dp(4f) + bw, cy + h / 2f, iconPaint)
        canvas.drawRect(cx + dp(2.5f), cy - h / 2f, cx + dp(2.5f) + bw, cy + h / 2f, iconPaint)
    }

    private fun drawLockIcon(canvas: Canvas, cx: Float, cy: Float, on: Boolean) {
        if (on) {
            rect.set(cx - dp(5f), cy - dp(1f), cx + dp(5f), cy + dp(6.6f))
            canvas.drawRoundRect(rect, dp(1.4f), dp(1.4f), iconPaint)
            iconStroke.strokeWidth = dp(1.2f)
            rect.set(cx - dp(3.6f), cy - dp(7.5f), cx + dp(3.6f), cy + dp(1.2f))
            canvas.drawArc(rect, 180f, 180f, false, iconStroke)
        } else {
            iconStroke.strokeWidth = dp(1.2f)
            rect.set(cx - dp(5f), cy - dp(1f), cx + dp(5f), cy + dp(6.6f))
            canvas.drawRoundRect(rect, dp(1.4f), dp(1.4f), iconStroke)
            rect.set(cx - dp(3.6f), cy - dp(7.5f), cx + dp(3.6f), cy + dp(1.2f))
            canvas.drawArc(rect, 180f, 180f, false, iconStroke)
        }
    }

    private fun drawCloseIcon(canvas: Canvas, cx: Float, cy: Float) {
        iconStroke.strokeWidth = dp(1.2f)
        path.reset()
        path.moveTo(cx - dp(4f), cy - dp(4f))
        path.lineTo(cx + dp(4f), cy + dp(4f))
        path.moveTo(cx + dp(4f), cy - dp(4f))
        path.lineTo(cx - dp(4f), cy + dp(4f))
        canvas.drawPath(path, iconStroke)
    }

    // ===== 触摸 =====

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val barH = barHeight
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downRawX = event.rawX
                downRawY = event.rawY
                dragging = false
                movedAway = false
                pressedAction = null
                if (toolbarOpen && event.y > barH) {
                    pressedAction = hitRects.firstOrNull { it.first.contains(event.x, event.y) }?.second
                    removeCallbacks(collapseTask)
                    return true
                }
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - downRawX
                val dy = event.rawY - downRawY
                if (pressedAction != null) return true
                if (!movedAway && (Math.abs(dx) > touchSlop || Math.abs(dy) > touchSlop)) {
                    movedAway = true
                    // 锁定时只禁拖动，不禁轻点：否则锁上以后连工具条都打不开，就再也解不掉了
                    if (!lockedFlag) {
                        dragging = true
                        setToolbar(false)
                        onDragStart?.invoke()
                    }
                }
                if (dragging) onDragMove?.invoke(dx, dy)
                return true
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val action = pressedAction
                pressedAction = null
                if (action != null) {
                    if (event.actionMasked == MotionEvent.ACTION_UP) onAction?.invoke(action)
                    scheduleCollapse()
                    return true
                }
                val wasDrag = dragging
                dragging = false
                if (wasDrag) {
                    onDragEnd?.invoke()
                } else if (!movedAway) {
                    onTapBar?.invoke()
                }
                movedAway = false
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    private companion object {
        /** 霞鹜文楷 19MB，每挂一次窗都重新解一遍会明显卡顿，这里进程内缓存一份 */
        @Volatile
        private var cachedKai: Typeface? = null

        fun kaiTypeface(context: Context): Typeface? {
            cachedKai?.let { return it }
            val t = runCatching { ResourcesCompat.getFont(context, R.font.lxgw_wenkai_regular) }.getOrNull()
            cachedKai = t
            return t
        }
    }
}

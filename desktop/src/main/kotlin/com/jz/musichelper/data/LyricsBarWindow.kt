package com.jz.musichelper.data

import com.jz.musichelper.ui.DesktopLyricsView
import com.jz.musichelper.ui.LyricsBarAction
import com.jz.musichelper.ui.LyricsMetrics
import java.awt.Window
import javax.swing.JDialog
import javax.swing.SwingUtilities

/**
 * 桌面歌词悬浮栏（工具窗口）。
 *
 * 为什么是 `JDialog(owner) + undecorated + type=UTILITY`：
 *  - `JWindow` 的 peer 会带 `WS_EX_NOACTIVATE`，点击进不了 Swing 派发链（能看不能点）；
 *  - `JFrame` 会在任务栏多出一个"应用"图标（用户反馈"歌词栏变成了新的托盘应用"）；
 *  - `JDialog` + `Type.UTILITY` 对应 `WS_EX_TOOLWINDOW`：**没有任务栏按钮、可获焦点、可点击**，
 *    这正是 QQ 音乐 / 网易云 / 酷狗 桌面歌词窗的做法。
 *
 * 隐藏 = 挪到屏幕外（不 dispose、不 setVisible(false)，避免 AWT 关停）。
 */
object LyricsBarWindow {

    private var window: JDialog? = null
    private var view: DesktopLyricsView? = null

    private var lastCur: String? = null
    private var lastNext: String? = null
    private var lastEmpty: String? = null
    private var lastToolbar = false
    private var lastTheme = -1
    private var lastFont = Int.MIN_VALUE
    private var lastLocked: Boolean? = null
    private var lastPaused: Boolean? = null
    private var lastHeight = 0
    private var lastDbgMs = 0L
    /** 栏体（不含工具条）底边的屏幕 y，用来判断工具条朝上还是朝下 */
    private var anchorBottomY = -1

    private var dragX = 0
    private var dragY = 0

    private fun dp(v: Float): Int = (v * LyricsMetrics.scale).toInt()

    private fun paperFor(theme: Int): java.awt.Color = when (theme) {
        1 -> java.awt.Color(0xF2, 0xE5, 0xC4)
        2 -> java.awt.Color(0x24, 0x21, 0x1D)
        else -> java.awt.Color(0xFB, 0xF7, 0xED)
    }

    fun show() = onEdt {
        ensureCreated()
        val win = window ?: return@onEdt
        val v = view ?: return@onEdt
        if (win.isVisible && win.x > -10000) {
            sync()
            return@onEdt
        }
        val w = LyricsMetrics.barWidth.toInt()
        val h = v.preferredHeightPx().coerceAtLeast(dp(66f))
        val (x, y) = DesktopLyrics.initialPositionPx(w, h)
        win.setBounds(x, y, w, h)
        lastHeight = h
        anchorBottomY = y + v.barHeightPx()
        win.isAlwaysOnTop = true
        win.background = paperFor(LyricsBarState.theme)
        win.isVisible = true
        runCatching { win.toFront() }
        sync()
        JzLog.i("JZ_DL", "bar shown at $x,$y ${w}x$h taskbar=false")
    }

    /** 按当前预设重新定位（位置改了但窗口已可见时用） */
    fun reposition() = onEdt {
        val win = window ?: return@onEdt
        val v = view ?: return@onEdt
        val w = LyricsMetrics.barWidth.toInt()
        val h = v.preferredHeightPx().coerceAtLeast(dp(66f))
        val (x, y) = DesktopLyrics.initialPositionPx(w, h)
        win.setBounds(x, y, w, h)
        lastHeight = h
        anchorBottomY = y + v.barHeightPx()
        win.isVisible = true
        JzLog.i("JZ_DL", "bar repositioned to $x,$y")
    }

    fun hideOffscreen() = onEdt {
        window?.let { w -> if (w.isVisible) w.setLocation(-32000, -32000) }
    }

    fun destroy() = onEdt {
        runCatching { window?.isVisible = false }
        runCatching { window?.dispose() }
        window = null
        view = null
    }

    fun sync() = onEdt {
        val v = view ?: return@onEdt
        val s = LyricsBarState
        val win = window
        // 已收起（挪到屏幕外）时不做任何绘制/尺寸计算：否则每 100ms 都会算一次负坐标，
        // 还会把 anchor 弄负，重新唤起时工具条方向会判断错。
        if (win == null || win.x < -10000) return@onEdt

        if (s.theme != lastTheme) {
            lastTheme = s.theme
            v.setTheme(s.theme)
            win?.background = paperFor(s.theme)
        }
        if (s.fontStep != lastFont) {
            lastFont = s.fontStep
            v.setFontStep(s.fontStep)
        }
        if (s.locked != lastLocked) {
            lastLocked = s.locked
            v.setLocked(s.locked)
        }
        if (s.paused != lastPaused) {
            lastPaused = s.paused
            v.setPaused(s.paused)
        }

        var heightDirty = false
        if (s.emptyText != lastEmpty || s.curText != lastCur || s.nextText != lastNext) {
            lastEmpty = s.emptyText
            lastCur = s.curText
            lastNext = s.nextText
            if (s.emptyText.isNotEmpty()) v.setEmpty(s.emptyText) else v.setPair(s.curText, s.nextText, true)
            heightDirty = true
        }
        if (s.toolbarOpen != lastToolbar) {
            lastToolbar = s.toolbarOpen
            v.setToolbarAbove(s.toolbarAbove)
            v.setToolbar(s.toolbarOpen)
            heightDirty = true
        }
        if (heightDirty) applyHeight()

        v.setWordTiming(s.curLine?.words ?: emptyList())
        v.setPosition(s.positionMs)
        val start = s.curLine?.timeMs ?: 0L
        val span = (s.nextStartMs - start).coerceAtLeast(1L)
        val ratio = ((s.positionMs - start).toFloat() / span).coerceIn(0f, 1f)
        v.setKaraoke(ratio)
        if (System.getenv("JZ_BAR_DBG") == "1") {
            val now = System.currentTimeMillis()
            if (now - lastDbgMs > 1000) {
                lastDbgMs = now
                JzLog.i("JZ_DL", "sync ly cur=${s.curText.take(8)} pos=${s.positionMs} start=$start span=$span ratio=$ratio words=${s.curLine?.words?.size ?: 0} paused=${s.paused}")
            }
        }
    }

    /** 行数/工具条变化后同步窗口高度，保证第二行、工具条不被裁掉 */
    private fun applyHeight() = onEdt {
        val win = window ?: return@onEdt
        val v = view ?: return@onEdt
        val screen = AppEnv.screenBounds
        val bottom = screen.y + screen.height
        val barH = v.barHeightPx().coerceAtLeast(dp(66f))
        // 锚点 = **栏体底边**（不含工具条）。栏体必须始终停在这条线上：
        // 以前工具条收起时窗口沿用旧的顶边，结果"收完被顶上去一节"，越开越高。
        if (anchorBottomY <= 0) anchorBottomY = win.y + barH
        val open = LyricsBarState.toolbarOpen
        val tt = if (open) v.toolbarTotalPx() else 0f
        // 栏体下方放不下工具条就朝上（贴底时必然朝上）
        val above = open && (anchorBottomY + tt > bottom)
        LyricsBarState.toolbarAbove = above
        v.setToolbarAbove(above)
        val h = v.preferredHeightPx().coerceAtLeast(dp(66f))
        val wantY = (if (above) anchorBottomY - h else anchorBottomY - barH).toFloat()
        val y = wantY.toInt().coerceIn(screen.y, (bottom - h).coerceAtLeast(screen.y))
        if (h == lastHeight && win.height == h && win.y == y) return@onEdt
        lastHeight = h
        win.setBounds(win.x, y, win.width, h)
        JzLog.i(
            "JZ_DL",
            "applyHeight ${win.width}x$h at ${win.x},$y barH=$barH anchor=$anchorBottomY " +
                "open=$open above=$above (bottom=$bottom)"
        )
    }

    private fun ensureCreated() {
        if (window != null) return
        val v = DesktopLyricsView().apply {
            setTheme(LyricsBarState.theme)
            setFontStep(LyricsBarState.fontStep)
            setLocked(LyricsBarState.locked)
            onDragStart = { beginDrag() }
            onDragMove = { dx, dy -> dragBy(dx, dy) }
            onDragEnd = { endDrag() }
            onTapBar = { DesktopLyrics.toggleToolbar() }
            onRequestCollapse = { DesktopLyrics.setToolbarOpen(false) }
            onAction = { a -> handleAction(a) }
            onHeightChanged = { applyHeight() }
        }
        val owner = com.jz.musichelper.ui.AppWindow.frame as? java.awt.Frame
        val win = if (owner != null) JDialog(owner, "JZ Music 桌面歌词") else JDialog()
        win.apply {
            isUndecorated = true
            defaultCloseOperation = javax.swing.WindowConstants.DO_NOTHING_ON_CLOSE
            // 工具窗口：任务栏不出现独立图标（对应 WS_EX_TOOLWINDOW）
            runCatching { type = Window.Type.UTILITY }
            contentPane = v
            background = paperFor(LyricsBarState.theme)
            isAlwaysOnTop = true
        }
        view = v
        window = win
        lastTheme = -1
        lastFont = Int.MIN_VALUE
        lastLocked = null
        lastPaused = null
        lastCur = null
        lastNext = null
        lastEmpty = null
        lastHeight = 0
        JzLog.i("JZ_DL", "bar window created (utility dialog)")
    }

    private fun handleAction(action: LyricsBarAction) {
        when (action) {
            LyricsBarAction.PREV -> DesktopLyrics.prevLine()
            LyricsBarAction.NEXT -> DesktopLyrics.nextLine()
            LyricsBarAction.PLAY_PAUSE -> DesktopLyrics.togglePlay()
            LyricsBarAction.FONT_MINUS -> DesktopLyrics.adjustFontStep(-1)
            LyricsBarAction.FONT_PLUS -> DesktopLyrics.adjustFontStep(1)
            LyricsBarAction.LOCK -> DesktopLyrics.toggleLock()
            LyricsBarAction.CLOSE -> DesktopLyrics.closeBar()
        }
    }

    private fun beginDrag() = onEdt {
        window?.let { dragX = it.x; dragY = it.y }
    }

    private fun dragBy(dx: Float, dy: Float) = onEdt {
        val win = window ?: return@onEdt
        val screen = AppEnv.screenBounds
        val maxX = (screen.x + screen.width - win.width).coerceAtLeast(screen.x)
        val maxY = (screen.y + screen.height - win.height).coerceAtLeast(screen.y)
        win.setLocation(
            (dragX + dx.toInt()).coerceIn(screen.x, maxX),
            (dragY + dy.toInt()).coerceIn(screen.y, maxY)
        )
    }

    private fun endDrag() = onEdt {
        val win = window ?: return@onEdt
        anchorBottomY = win.y + (view?.barHeightPx() ?: win.height)
        DesktopLyrics.savePositionPx(win.x, win.y, win.width, win.height)
    }

    private inline fun onEdt(crossinline block: () -> Unit) {
        if (SwingUtilities.isEventDispatchThread()) block() else SwingUtilities.invokeLater { block() }
    }
}

package com.jz.musichelper.data

import java.awt.BasicStroke
import java.awt.Color
import java.awt.Font
import java.awt.Graphics
import java.awt.Graphics2D
import java.awt.GraphicsDevice
import java.awt.GraphicsEnvironment
import java.awt.Point
import java.awt.RenderingHints
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import java.awt.event.WindowAdapter
import java.awt.event.WindowEvent
import java.awt.geom.Arc2D
import java.awt.geom.Path2D
import java.awt.geom.RoundRectangle2D
import javax.swing.JWindow
import javax.swing.SwingUtilities
import javax.swing.Timer

/**
 * 托盘右键菜单（自绘，墨色卡片）。
 *
 * 为什么不用 AWT 的 `PopupMenu`：
 *  ① 中文标签在部分 JDK/Windows 组合下会被按平台编码塞进宽字符 API，显示成乱码；
 *  ② 原生菜单没法跟应用的墨色风格统一。
 *
 * 这里必须是一个**可获焦**的 `JWindow`（不能是 `Window.Type.POPUP`）：
 * POPUP 类型会被设成 `WS_EX_NOACTIVATE`，永远拿不到焦点，于是
 *   - `windowLostFocus` 不触发 → 点别处/关掉托盘面板后菜单赖在屏幕上（用户反馈的 bug）；
 *   - 悬浮高亮时有时无。
 * 可获焦 + 失焦即收，才是系统菜单该有的手感。
 */
internal class TrayMenuWindow(
    private val items: List<Entry>
) {

    enum class Icon { WINDOW, PLAY, PAUSE, PREV, NEXT, POWER }

    class Entry(val label: String, val icon: Icon, val danger: Boolean = false, val action: () -> Unit)

    // —— 尺寸（逻辑像素，随系统缩放一起放大）——
    private val cardW = 224f
    private val rowH = 40f
    private val padV = 7f
    private val corner = 12f
    private val shadow = 9f
    private val sepH = 9f
    private val iconSize = 15f

    /** 退出这类"危险项"上面加一条分隔线 */
    private val sepBefore: Set<Int> = items.indices
        .filter { items[it].danger && it > 0 }
        .toSet()

    private val cardH: Float = padV * 2 + items.size * rowH + sepBefore.size * sepH
    private val winW = (cardW + shadow * 2).toInt()
    private val winH = (cardH + shadow * 2).toInt()

    private val paper = Color(0xFB, 0xF7, 0xED)
    private val edge = Color(0xD6, 0xCE, 0xBC)
    private val ink = Color(0x2C, 0x28, 0x22)
    private val sub = Color(0x57, 0x50, 0x45)
    private val hoverBg = Color(0xF1, 0xE9, 0xDA)
    private val pressedBg = Color(0xE7, 0xDE, 0xCB)
    private val danger = Color(0xB4, 0x4A, 0x3A)

    private var hoverIndex = -1
    private var pressedIndex = -1
    private var translucent = false
    private var shownAt = 0L
    private var lastInsideAt = 0L
    private var everInside = false
    private var outsideSince = 0L
    private var anchorX = 0
    private var anchorY = 0

    private val window: JWindow

    /** 鼠标反馈：悬浮行高亮、按下压深一档（要有反馈，不能一按就消失） */
    private val mouse = object : MouseAdapter() {
        override fun mouseMoved(e: MouseEvent) {
            val idx = indexAt(e.y)
            if (idx != hoverIndex) {
                hoverIndex = idx
                window.repaint()
            }
        }

        override fun mouseExited(e: MouseEvent) {
            hoverIndex = -1
            if (pressedIndex < 0) window.repaint()
        }

        override fun mousePressed(e: MouseEvent) {
            if (!SwingUtilities.isLeftMouseButton(e)) {
                hide()
                return
            }
            pressedIndex = indexAt(e.y)
            window.repaint()
        }

        override fun mouseReleased(e: MouseEvent) {
            val pressed = pressedIndex
            val released = indexAt(e.y)
            pressedIndex = -1
            if (pressed < 0 || pressed != released) {
                window.repaint()
                return
            }
            val entry = items[pressed]
            // 先收窗口再动作：动作里可能会显示主界面/退出，留着菜单会闪一下
            hide()
            entry.action()
        }
    }

    /** 菜单没被点、也没被失焦时（极少数情况下拿不到前台焦点）兜底收起 */
    private val watcher = Timer(300) { watch() }.apply { isRepeats = true }

    init {
        window = JWindow()
        window.isAlwaysOnTop = true
        window.focusableWindowState = true
        window.setAutoRequestFocus(true)
        runCatching {
            val gd = GraphicsEnvironment.getLocalGraphicsEnvironment().defaultScreenDevice
            translucent = gd.isWindowTranslucencySupported(GraphicsDevice.WindowTranslucency.PERPIXEL_TRANSPARENT)
        }
        window.background = if (translucent) Color(0, 0, 0, 0) else paper
        window.setSize(winW, winH)

        val panel = object : javax.swing.JPanel() {
            init {
                isOpaque = false
            }

            override fun paintComponent(g: Graphics) {
                val g2 = g.create() as Graphics2D
                try {
                    g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON)
                    g2.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON)
                    g2.setRenderingHint(RenderingHints.KEY_STROKE_CONTROL, RenderingHints.VALUE_STROKE_PURE)
                    paintCard(g2)
                } finally {
                    g2.dispose()
                }
            }
        }
        panel.addMouseListener(mouse)
        panel.addMouseMotionListener(mouse)
        window.contentPane = panel
        window.addWindowFocusListener(object : WindowAdapter() {
            override fun windowLostFocus(e: WindowEvent?) = hide()
            override fun windowDeactivated(e: WindowEvent?) = hide()
        })
    }

    /** 行号：把 y 换算成"第几项"（分隔线的空间也要算进去） */
    private fun indexAt(y: Int): Int {
        var top = shadow + padV
        items.forEachIndexed { i, _ ->
            if (i in sepBefore) top += sepH
            if (y >= top && y < top + rowH) return i
            top += rowH
        }
        return -1
    }

    private fun rowTop(i: Int): Float {
        var top = shadow + padV
        for (j in 0..i) {
            if (j in sepBefore) top += sepH
            if (j < i) top += rowH
        }
        return top
    }

    private fun paintCard(g2: Graphics2D) {
        val x0 = shadow
        val y0 = shadow

        // 投影：几层低透明度圆角矩形叠出柔和边缘
        if (translucent) {
            for (i in 4 downTo 1) {
                g2.color = Color(0x2C, 0x28, 0x22, 6 + i * 5)
                val d = i * 1.6f
                g2.fill(RoundRectangle2D.Float(x0 - d, y0 - d + 2f, cardW + d * 2, cardH + d * 2, corner + d, corner + d))
            }
        }

        g2.color = paper
        g2.fill(RoundRectangle2D.Float(x0, y0, cardW, cardH, corner, corner))
        g2.color = edge
        g2.stroke = BasicStroke(1f)
        g2.draw(RoundRectangle2D.Float(x0 + 0.5f, y0 + 0.5f, cardW - 1f, cardH - 1f, corner, corner))

        val playing = runCatching { PlayerManager.isPlaying.value }.getOrDefault(false)
        items.forEachIndexed { i, entry ->
            val top = rowTop(i)
            if (i in sepBefore) {
                g2.color = Color(0xE2, 0xDB, 0xCA)
                g2.fillRect((x0 + 14f).toInt(), (top - sepH / 2f).toInt(), (cardW - 28f).toInt(), 1)
            }
            val highlighted = i == pressedIndex || (i == hoverIndex && pressedIndex < 0)
            if (highlighted) {
                g2.color = if (i == pressedIndex) pressedBg else hoverBg
                g2.fill(RoundRectangle2D.Float(x0 + 5f, top + 2f, cardW - 10f, rowH - 4f, 9f, 9f))
            }
            val color = when {
                entry.danger -> danger
                i == hoverIndex || i == pressedIndex -> ink
                else -> sub
            }
            val cy = top + rowH / 2f
            g2.stroke = BasicStroke(1.35f)
            drawIcon(g2, entry.icon, x0 + 17f, cy, color, playing)

            g2.font = Font("Microsoft YaHei", Font.PLAIN, 13)
            val fm = g2.fontMetrics
            g2.color = color
            g2.drawString(entry.label, x0 + 40f, cy + (fm.ascent - fm.descent) / 2f)
        }
    }

    private fun drawIcon(g2: Graphics2D, icon: Icon, cx: Float, cy: Float, color: Color, playing: Boolean) {
        val s = iconSize / 2f
        g2.color = color
        when (icon) {
            Icon.WINDOW -> {
                val w = iconSize
                val h = iconSize * 0.78f
                g2.draw(RoundRectangle2D.Float(cx - w / 2f, cy - h / 2f, w, h, 3f, 3f))
                g2.drawLine(
                    (cx - w / 2f).toInt(), (cy - h / 2f + 3.4f).toInt(),
                    (cx + w / 2f).toInt(), (cy - h / 2f + 3.4f).toInt()
                )
            }

            Icon.PLAY, Icon.PAUSE -> {
                if (playing) {
                    val bw = 1.6f
                    val bh = iconSize * 0.9f
                    g2.fill(RoundRectangle2D.Float(cx - 4.4f, cy - bh / 2f, bw, bh, 0.8f, 0.8f))
                    g2.fill(RoundRectangle2D.Float(cx + 2.2f, cy - bh / 2f, bw, bh, 0.8f, 0.8f))
                } else {
                    val p = Path2D.Float()
                    p.moveTo(cx - s * 0.7f, cy - s * 0.95f)
                    p.lineTo(cx - s * 0.7f, cy + s * 0.95f)
                    p.lineTo(cx + s * 0.95f, cy)
                    p.closePath()
                    g2.fill(p)
                }
            }

            Icon.PREV, Icon.NEXT -> {
                // 上一首 = |<（竖线在左、箭头朝左）；下一首 = >|（箭头朝右、竖线在右）
                val dir = if (icon == Icon.PREV) -1f else 1f
                val apexX = cx + dir * s * 0.6f
                val baseX = cx - dir * s * 0.6f
                val p = Path2D.Float()
                p.moveTo(baseX, cy - s * 0.85f)
                p.lineTo(apexX, cy)
                p.lineTo(baseX, cy + s * 0.85f)
                g2.draw(p)
                val bx = cx + dir * s * 0.95f
                g2.fill(RoundRectangle2D.Float(bx - 0.8f, cy - s * 0.85f, 1.6f, s * 1.7f, 0.6f, 0.6f))
            }

            Icon.POWER -> {
                g2.draw(Arc2D.Float(cx - s * 0.85f, cy - s * 0.85f, s * 1.7f, s * 1.7f, 60f, 240f, Arc2D.OPEN))
                g2.drawLine(cx.toInt(), (cy - s).toInt(), cx.toInt(), (cy + s * 0.1f).toInt())
            }
        }
    }

    /**
     * 在自己附近弹出（托盘图标右键）。
     *
     * DPI 坑：`TrayIcon` 鼠标事件的 `xOnScreen/yOnScreen` 是**物理像素**，
     * 而 AWT 的 `setLocation`/`screenBounds` 是**逻辑像素**（150% 缩放下差 1.5 倍）。
     * 直接拿事件坐标定位，菜单会掉到屏幕右下角外面（看起来"右键没反应"）。
     * 所以统一用 `MouseInfo` 的指针位置；若它落到逻辑屏幕之外，再按缩放比折回来。
     */
    fun showNearCursor() {
        val screen = AppEnv.screenBounds
        var p = runCatching { java.awt.MouseInfo.getPointerInfo()?.location }.getOrNull()
            ?: Point(screen.x + screen.width / 2, screen.y + screen.height / 2)
        if (p.x > screen.x + screen.width || p.y > screen.y + screen.height) {
            val scale = runCatching {
                GraphicsEnvironment.getLocalGraphicsEnvironment()
                    .defaultScreenDevice.defaultConfiguration.defaultTransform.scaleX
            }.getOrDefault(1.0)
            if (scale > 1.01) p = Point((p.x / scale).toInt(), (p.y / scale).toInt())
            JzLog.i("JZ_TRAY", "menu anchor converted to user space: $p (scale=$scale)")
        }
        showAt(p)
    }

    fun showAt(p: Point) {
        val screen = AppEnv.screenBounds
        var x = (p.x - winW / 2).toFloat()
        var y = (p.y - winH - 4).toFloat()
        x = x.coerceIn(screen.x.toFloat(), (screen.x + screen.width - winW).toFloat().coerceAtLeast(screen.x.toFloat()))
        if (y < screen.y) y = (p.y + 14).toFloat()
        y = y.coerceIn(screen.y.toFloat(), (screen.y + screen.height - winH).toFloat().coerceAtLeast(screen.y.toFloat()))
        window.setLocation(x.toInt(), y.toInt())
        hoverIndex = -1
        pressedIndex = -1
        everInside = false
        outsideSince = 0L
        anchorX = p.x
        anchorY = p.y
        shownAt = System.currentTimeMillis()
        window.isVisible = true
        window.toFront()
        runCatching { window.requestFocus() }
        watcher.start()
        JzLog.i("JZ_TRAY", "menu at ${x.toInt()},${y.toInt()} (anchor=$p screen=$screen)")
    }

    /**
     * 兜底收起。
     *
     * 托盘图标右键弹菜单时，Windows 不会把前台焦点交给我们（实测 `GetForegroundWindow`
     * 仍是别的窗口），所以 `windowLostFocus` 收不到——菜单会赖在屏幕上（用户反馈的 bug）。
     * 这里改成盯着鼠标：
     *  - 鼠标进过菜单又出去 → 1 秒收；
     *  - 鼠标跑到离右键位置很远的地方（去干别的了）→ 0.7 秒收；
     *  - 一直没进菜单（只是右键看一眼）→ 2.5 秒收。
     * 指针只要回到菜单里，计时就清零，不会"看着看着自己没了"。
     */
    private fun watch() {
        if (!window.isVisible) {
            watcher.stop()
            return
        }
        val p = runCatching { java.awt.MouseInfo.getPointerInfo()?.location }.getOrNull() ?: return
        val now = System.currentTimeMillis()
        if (window.bounds.contains(p)) {
            everInside = true
            lastInsideAt = now
            outsideSince = 0L
            return
        }
        if (outsideSince == 0L) outsideSince = now
        val outsideMs = now - outsideSince
        val far = Math.abs(p.x - anchorX) + Math.abs(p.y - anchorY) > 80
        val limit = when {
            far -> 700L
            everInside -> 1000L
            else -> 2500L
        }
        if (outsideMs > limit) hide()
    }

    fun hide() {
        watcher.stop()
        hoverIndex = -1
        pressedIndex = -1
        window.isVisible = false
    }
}

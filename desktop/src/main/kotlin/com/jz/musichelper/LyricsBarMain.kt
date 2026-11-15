package com.jz.musichelper

import com.jz.musichelper.data.JzLog
import com.jz.musichelper.network.LyricWord
import com.jz.musichelper.ui.DesktopLyricsView
import com.jz.musichelper.ui.LyricsBarAction
import com.jz.musichelper.ui.LyricsMetrics
import org.json.JSONArray
import org.json.JSONObject
import java.awt.Color
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import javax.swing.JWindow
import javax.swing.SwingUtilities

/**
 * 桌面歌词悬浮栏的**子进程**入口（`JZ Music.exe --lyrics-bar`）。
 *
 * 为什么单独一个进程：主进程里只要歌词窗开始承载内容，约 5 秒后 EDT 上就会出现一次
 * 来路不明的 `System.exit`（已排除我们的代码、Compose 收尾、AWTAutoShutdown 空窗口判定）。
 * 把窗口放到独立进程后，它出任何问题都杀不到播放器。
 *
 * 协议：stdin/stdout 每行一个 JSON。
 *  父 → 子：{"t":"init",...} / {"t":"ly",...}
 *  子 → 父：{"t":"pos","x":..,"y":..} / {"t":"action","a":"PREV"} / {"t":"toolbar","open":bool}
 */
object LyricsBarMain {

    private const val W_SIDE = 10f

    /** 主题纸色：窗口背景也用它，避免 JWindow 默认的半透明底把整条歌词栏洗淡 */
    private fun paperFor(theme: Int): Color = when (theme) {
        1 -> Color(0xF2, 0xE5, 0xC4)
        2 -> Color(0x24, 0x21, 0x1D)
        else -> Color(0xFB, 0xF7, 0xED)
    }

    fun run() {
        val out = PrintWriter(System.out, true)
        fun emit(o: JSONObject) = runCatching { out.println(o.toString()) }

        val reader = BufferedReader(InputStreamReader(System.`in`))
        var win: JWindow? = null
        var view: DesktopLyricsView? = null
        var dragX = 0
        var dragY = 0

        fun applyTheme(theme: Int) {
            view?.setTheme(theme)
            win?.background = paperFor(theme)
            win?.repaint()
        }

        fun ensureWindow(x: Int, y: Int, w: Int, theme: Int, font: Int, locked: Boolean) {
            if (win != null) return
            val v = DesktopLyricsView().apply {
                setTheme(theme)
                setFontStep(font)
                setLocked(locked)
                onDragStart = { win?.let { dragX = it.x; dragY = it.y } }
                onDragMove = { dx, dy ->
                    win?.let { ww ->
                        val nx = (dragX + dx.toInt()).coerceAtLeast(0)
                        val ny = (dragY + dy.toInt()).coerceAtLeast(0)
                        ww.setLocation(nx, ny)
                    }
                }
                onDragEnd = {
                    win?.let { ww -> emit(JSONObject().put("t", "pos").put("x", ww.x).put("y", ww.y)) }
                }
                onTapBar = {
                    val open = isToolbarOpen()
                    setToolbar(!open)
                    // 工具条会加高窗口：必须立刻同步高度，否则工具条画在窗口外面（看不见）
                    win?.let { ww ->
                        val h = preferredHeightPx().coerceAtLeast((66f * LyricsMetrics.scale).toInt())
                        ww.setSize(ww.width, h)
                    }
                    JzLog.i("JZ_LB", "toolbar=${!open} h=${win?.height}")
                    emit(JSONObject().put("t", "toolbar").put("open", !open))
                }
                onAction = { a ->
                    emit(JSONObject().put("t", "action").put("a", a.name))
                }
                onHeightChanged = {
                    SwingUtilities.invokeLater {
                        win?.let { ww ->
                            val h = preferredHeightPx().coerceAtLeast((66f * LyricsMetrics.scale).toInt())
                            ww.setSize(ww.width, h)
                        }
                    }
                }
            }
            val wnd = JWindow().apply {
                isAlwaysOnTop = true
                contentPane = v
                setBounds(x, y, w, v.preferredHeightPx().coerceAtLeast((66f * LyricsMetrics.scale).toInt()))
                background = paperFor(theme)
            }
            view = v
            win = wnd
            wnd.isVisible = true
            JzLog.i("JZ_LB", "child window shown at $x,$y w=$w")
        }

        try {
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isBlank()) continue
                val o = runCatching { JSONObject(line) }.getOrNull() ?: continue
                when (o.optString("t")) {
                    "init" -> {
                        val x = o.optInt("x", 200)
                        val y = o.optInt("y", 600)
                        val w = o.optInt("w", LyricsMetrics.barWidth.toInt())
                        ensureWindow(x, y, w, o.optInt("theme", 0), o.optInt("font", 0), o.optBoolean("lock", false))
                        emit(JSONObject().put("t", "ready"))
                    }

                    "theme" -> applyTheme(o.optInt("theme", 0))

                    "ly" -> {
                        val v = view ?: continue
                        if (System.getenv("JZ_LB_DEBUG") == "1") {
                            JzLog.i("JZ_LB", "ly paused=${o.optBoolean("paused", true)} pos=${o.optLong("pos", 0L)} cur=${o.optString("cur", "").take(10)}")
                        }
                        val empty = o.optString("empty", "")
                        if (empty.isNotEmpty()) {
                            v.setEmpty(empty)
                        } else {
                            val wordsJson = o.optJSONArray("words") ?: JSONArray()
                            val words = ArrayList<LyricWord>(wordsJson.length())
                            for (i in 0 until wordsJson.length()) {
                                val a = wordsJson.optJSONArray(i) ?: continue
                                words.add(
                                    LyricWord(
                                        text = a.optString(2, ""),
                                        startMs = a.optLong(0, 0L),
                                        durMs = a.optLong(1, 0L)
                                    )
                                )
                            }
                            v.setPair(o.optString("cur", ""), o.optString("next", ""), o.optBoolean("animate", false))
                            v.setWordTiming(words)
                        }
                        v.setPaused(o.optBoolean("paused", true))
                        v.setPosition(o.optLong("pos", 0L))
                        val curStart = o.optLong("curStart", 0L)
                        val nextStart = o.optLong("nextStart", curStart + 4000L)
                        val span = (nextStart - curStart).coerceAtLeast(1L)
                        v.setKaraoke(((o.optLong("pos", 0L) - curStart).toFloat() / span).coerceIn(0f, 1f))
                    }

                    "toolbar" -> view?.setToolbar(o.optBoolean("open", false))

                    "quit" -> break
                }
            }
        } catch (e: Exception) {
            JzLog.w("JZ_LB", "child loop ended: ${e.message}")
        } finally {
            runCatching { win?.isVisible = false }
            runCatching { win?.dispose() }
            runCatching { out.flush() }
        }
    }
}

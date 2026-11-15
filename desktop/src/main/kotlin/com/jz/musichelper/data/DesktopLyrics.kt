package com.jz.musichelper.data

import com.jz.musichelper.network.LyricLine
import com.jz.musichelper.network.LyricsService
import com.jz.musichelper.ui.AppState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import javax.swing.SwingUtilities
import javax.swing.Timer
import kotlin.math.roundToInt

/**
 * 桌面歌词（悬浮窗）控制器。
 *
 * 只负责：开关/外观偏好、取词、100ms 推进播放位置、把结果写进 [LyricsBarState]；
 * 窗口与绘制在 `ui/desktop/DesktopLyricsBar.kt`（Compose）。
 *
 * 为什么重写：旧版用独立 AWT `JWindow`，播放/切歌时会被 `AWTAutoShutdown` 判定为
 * "最后一个窗口消失"→ `System.exit(0)`，即"一点歌就退出"。
 */
object DesktopLyrics {

    private const val PREFS = "jz_music_prefs"
    private const val KEY_ON = "dl_enabled"
    private const val KEY_FX = "dl_frac_x"
    private const val KEY_FY = "dl_frac_y"
    private const val KEY_THEME = "dl_theme"
    private const val KEY_FONT = "dl_font"
    private const val KEY_LOCK = "dl_lock"
    private const val TICK_MS = 100

    private const val DEFAULT_BOTTOM_DP = 120f
    private const val EDGE_DP = 12f

    private val _enabled = MutableStateFlow(false)
    val enabled: StateFlow<Boolean> = _enabled

    /** 桌面端没有"悬浮窗权限"概念，恒为可用（保留给旧 UI 调用） */
    private val _canOverlay = MutableStateFlow(true)
    val canOverlay: StateFlow<Boolean> = _canOverlay

    private val _error = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _error

    private val _theme = MutableStateFlow(0)
    val theme: StateFlow<Int> = _theme

    private val _fontStep = MutableStateFlow(0)
    val fontStep: StateFlow<Int> = _fontStep

    private val _locked = MutableStateFlow(false)
    val locked: StateFlow<Boolean> = _locked

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var fetchJob: Job? = null

    private var songKey: String? = null
    private var lines: List<LyricLine> = emptyList()
    private var lastIndex = -1
    private var loading = false
    private var playing = false
    private var appVisible = true
    private var tickerOn = false

    private val prefs get() = AppEnv.prefs(PREFS)

    private val ticker = Timer(TICK_MS) {}

    fun init() {
        runCatching {
            _enabled.value = prefs.getBoolean(KEY_ON, false)
            _theme.value = prefs.getInt(KEY_THEME, 0).coerceIn(0, 2)
            _fontStep.value = prefs.getInt(KEY_FONT, 0).coerceIn(-2, 2)
            _locked.value = prefs.getBoolean(KEY_LOCK, false)
        }
        LyricsBarState.theme = _theme.value
        LyricsBarState.fontStep = _fontStep.value
        LyricsBarState.locked = _locked.value
        LyricsBarState.visible = _enabled.value
        if (_enabled.value) {
            LyricsBarWindow.show()
            startLoop()
        }
        JzLog.i("JZ_DL", "init enabled=${_enabled.value} theme=${_theme.value}")
    }

    fun refreshPermission() {
        _canOverlay.value = true
    }

    fun onResume() {
        if (_enabled.value) startLoop()
    }

    // ===== 开关 / 外观（设置页、侧边栏、播放页三点菜单都调这里）=====

    fun toggleFromUi(on: Boolean): Boolean {
        persist(on)
        return true
    }

    private fun persist(on: Boolean) {
        prefs.edit().putBoolean(KEY_ON, on).apply()
        _enabled.value = on
        LyricsBarState.visible = on
        if (on) {
            LyricsBarWindow.show()
            startLoop()
        } else {
            LyricsBarWindow.hideOffscreen()
            stopTicker()
        }
        JzLog.i("JZ_DL", "toggle=$on")
    }

    fun setTheme(index: Int) {
        val i = index.coerceIn(0, 2)
        if (_theme.value == i) return
        _theme.value = i
        LyricsBarState.theme = i
LyricsBarWindow.sync()
        prefs.edit().putInt(KEY_THEME, i).apply()
    }

    fun adjustFontStep(delta: Int) {
        val next = (_fontStep.value + delta).coerceIn(-2, 2)
        if (next == _fontStep.value) return
        _fontStep.value = next
        LyricsBarState.fontStep = next
LyricsBarWindow.sync()
        prefs.edit().putInt(KEY_FONT, next).apply()
    }

    fun toggleLock() {
        val next = !_locked.value
        _locked.value = next
        LyricsBarState.locked = next
LyricsBarWindow.sync()
        prefs.edit().putBoolean(KEY_LOCK, next).apply()
        if (next) LyricsBarState.toolbarOpen = false
    }

    /** 兼容旧调用：主窗口焦点变化。悬浮窗"开着就一直挂"，这里只记录。 */
    fun setAppVisible(visible: Boolean) {
        appVisible = visible
    }

    fun setPlaying(value: Boolean) {
        if (playing == value) return
        playing = value
        LyricsBarState.paused = !value
LyricsBarWindow.sync()
        if (_enabled.value) startLoop()
    }

    /** 切歌：清空、重新取词（命中缓存时几乎立刻返回） */
    fun onSongChanged(song: com.jz.musichelper.model.Song?) {
        if (song == null) {
            songKey = null
            lines = emptyList()
            lastIndex = -1
            loading = false
            LyricsBarState.clearForSong()
            LyricsBarState.emptyText = "暂无歌词"
            return
        }
        val key = song.platform.name + "|" + song.platformID
        if (key == songKey) return
        songKey = key
        lines = emptyList()
        lastIndex = -1
        loading = true
        LyricsBarState.clearForSong()
        LyricsBarState.emptyText = "歌词加载中…"
        startLoop()

        if (System.getenv("JZ_DL_NOFETCH") == "1") {
            JzLog.w("JZ_DL", "fetch disabled (diagnostic)")
            return
        }
        fetchJob?.cancel()
        fetchJob = scope.launch {
            JzLog.i("JZ_DL", "fetch start ${song.name}")
            val result = runCatching { LyricsService.fetch(song) }.getOrNull()
            JzLog.i("JZ_DL", "fetch done ${song.name} lines=${result?.lines?.size ?: -1}")
            if (songKey != key) return@launch
            lines = result?.lines ?: emptyList()
            loading = false
            lastIndex = if (lines.isEmpty()) -1
            else LyricsService.indexAt(lines, PlayerManager.currentPositionMs())
            if (lines.isEmpty()) {
                LyricsBarState.emptyText = "暂无歌词"
            } else {
                LyricsBarState.emptyText = ""
                render(animate = true)
            }
    LyricsBarWindow.sync()
            JzLog.i("JZ_DL", "lyrics ${song.name}: ${lines.size} lines")
        }
    }

    /** 位置预设：hx/vy ∈ {0,1,2}（左中右 / 上中下）。悬浮窗在这台机器上收不到鼠标事件，
     *  所以位置不靠拖动，改用预设，保证"能放到位"。 */
    fun setPositionPreset(hx: Int, vy: Int) {
        val fxF = (hx.coerceIn(0, 2)) * 0.5f
        val fyF = (vy.coerceIn(0, 2)) * 0.5f
        prefs.edit().putFloat(KEY_FX, fxF).putFloat(KEY_FY, fyF).apply()
        LyricsBarState.positionRevision += 1
        LyricsBarWindow.reposition()
        JzLog.i("JZ_DL", "position preset hx=$hx vy=$vy")
    }

    fun currentPositionPreset(): Pair<Int, Int> {
        val fx = prefs.getFloat(KEY_FX, 0.5f)
        val fy = prefs.getFloat(KEY_FY, -1f)
        val hx = (fx * 2f).roundToInt().coerceIn(0, 2)
        val vy = if (fy < 0f) 2 else (fy * 2f).roundToInt().coerceIn(0, 2)
        return hx to vy
    }

    fun resetPosition() {
        prefs.edit().remove(KEY_FX).remove(KEY_FY).apply()
        LyricsBarState.positionRevision += 1
    }

    fun openOverlaySettings(): Boolean = true

    /** 应用退出时清理（此时没有独立窗口要销毁，只停 ticker） */
    fun destroy() {
        stopTicker()
        fetchJob?.cancel()
        LyricsBarState.visible = false
        LyricsBarWindow.destroy()
    }

    // ===== 子进程悬浮栏 =====

    private fun startBarProcess() {
        val w = com.jz.musichelper.ui.LyricsMetrics.barWidth.toInt()
        val h = (66f * com.jz.musichelper.ui.LyricsMetrics.scale).toInt()
        val (x, y) = initialPositionPx(w, h)
        LyricsBarProcess.onAction = { a -> handleActionByName(a) }
        LyricsBarProcess.onPosition = { px, py -> savePositionPx(px, py, w, h) }
        LyricsBarProcess.start(_theme.value, _fontStep.value, _locked.value, x, y, w)
LyricsBarWindow.sync()
    }

    private fun handleActionByName(name: String) {
        when (name) {
            "PREV" -> prevLine()
            "NEXT" -> nextLine()
            "PLAY_PAUSE" -> togglePlay()
            "FONT_MINUS" -> adjustFontStep(-1)
            "FONT_PLUS" -> adjustFontStep(1)
            "LOCK" -> toggleLock()
            "CLOSE" -> closeBar()
        }
    }

    /** 把当前状态推给子进程 */
    private fun syncBar() {
        if (!_enabled.value) return
        val s = LyricsBarState
        LyricsBarProcess.pushLyrics(
            cur = s.curText,
            next = s.nextText,
            empty = s.emptyText,
            posMs = s.positionMs,
            curStartMs = s.curLine?.timeMs ?: 0L,
            nextStartMs = s.nextStartMs,
            paused = !PlayerManager.isPlaying.value,
            words = s.curLine?.words ?: emptyList()
        )
    }

    // ===== 位置（窗口自己算，控制器只负责存取）=====

    /** 初始位置（px）：横向比例 + 纵向比例；fy < 0 表示默认贴底 */
    fun initialPositionPx(width: Int, height: Int): Pair<Int, Int> {
        val screen = AppEnv.screenBounds
        val maxX = (screen.width - width).coerceAtLeast(0)
        val maxY = (screen.height - height).coerceAtLeast(0)
        val fx = prefs.getFloat(KEY_FX, 0.5f)
        val fy = prefs.getFloat(KEY_FY, -1f)
        val x = (maxX * fx).toInt().coerceIn(0, maxX)
        val y = if (fy < 0f) (maxY - DEFAULT_BOTTOM_DP * com.jz.musichelper.ui.LyricsMetrics.scale)
            .toInt().coerceIn(0, maxY)
        else (maxY * fy).toInt().coerceIn(0, maxY)
        return (screen.x + x) to (screen.y + y)
    }

    /** 拖动结束后保存比例；左右留边距，避免贴在屏幕边缘 */
    fun savePositionPx(x: Int, y: Int, width: Int, height: Int) {
        val screen = AppEnv.screenBounds
        val maxX = (screen.width - width).coerceAtLeast(0)
        val maxY = (screen.height - height).coerceAtLeast(0)
        val edge = EDGE_DP.toInt()
        val relX = (x - screen.x).coerceIn(minOf(edge, maxX / 2), maxOf(maxX - edge, maxX / 2))
        val relY = (y - screen.y).coerceIn(0, maxY)
        prefs.edit()
            .putFloat(KEY_FX, relX.toFloat() / maxX.coerceAtLeast(1))
            .putFloat(KEY_FY, relY.toFloat() / maxY.coerceAtLeast(1))
            .apply()
    }

    // ===== 动作（工具条按钮）=====

    fun prevLine() = seekToLine(lastIndex - 1)

    fun nextLine() = seekToLine(lastIndex + 1)

    fun togglePlay() = PlayerManager.toggle()

    /** 工具条开/关（点栏体、3 秒自动收起、设置页都走这里） */
    fun setToolbarOpen(open: Boolean) {
        if (LyricsBarState.toolbarOpen == open) return
        LyricsBarState.toolbarOpen = open
        LyricsBarProcess.setToolbar(open)
        LyricsBarWindow.sync()
        JzLog.i("JZ_DL", "toolbar open=$open")
    }

    fun toggleToolbar() = setToolbarOpen(!LyricsBarState.toolbarOpen)

    fun closeBar() {
        setToolbarOpen(false)
        toggleFromUi(false)
    }

    private fun seekToLine(index: Int) {
        if (lines.isEmpty()) return
        val i = index.coerceIn(0, lines.size - 1)
        val t = lines[i].timeMs
        PlayerManager.seekTo(t)
        lastIndex = i
        LyricsBarState.positionMs = t
        render(animate = true)
    }

    // ===== 循环 =====

    private fun startLoop() {
        if (System.getenv("JZ_DL_NOTICKER") == "1") { JzLog.w("JZ_DL", "ticker disabled (diagnostic)"); return }
        if (tickerOn) return
        tickerOn = true
        ticker.initialDelay = TICK_MS
        ticker.delay = TICK_MS
        ticker.addActionListener(tickListenerRef)
        ticker.start()
    }

    private val tickListenerRef = java.awt.event.ActionListener { tickOnce() }

    private fun stopTicker() {
        tickerOn = false
        ticker.stop()
        ticker.removeActionListener(tickListenerRef)
    }

    private fun syncFromSources() {
        val song = AppState.lastSong.value
        val key = song?.let { it.platform.name + "|" + it.platformID }
        if (key != songKey) onSongChanged(song)
        val nowPlaying = PlayerManager.isPlaying.value
        if (nowPlaying != playing) setPlaying(nowPlaying)
        LyricsBarState.positionMs = PlayerManager.currentPositionMs()
    }

    private var tickCount = 0

    private fun tickOnce() {
        if (!_enabled.value) return
        val trace = System.getenv("JZ_DL_TICKTRACE") == "1"
        tickCount++
        if (trace) JzLog.i("JZ_DL", "tick $tickCount enter lines=${lines.size}")
        runCatching { syncFromSources() }
        if (trace) JzLog.i("JZ_DL", "tick $tickCount after sync")
        if (lines.isEmpty()) return
        val pos = PlayerManager.currentPositionMs()
        if (trace) JzLog.i("JZ_DL", "tick ${tickCount} pos=$pos")
        LyricsBarState.positionMs = pos
        val idx = LyricsService.indexAt(lines, pos)
        if (idx != lastIndex) {
            lastIndex = idx
            render(animate = true)
        }
        // 逐字染色需要的两个量：当前句 + 下一句开始时间
        val line = lines.getOrNull(idx)
        LyricsBarState.curLine = line
        LyricsBarState.nextStartMs = lines.getOrNull(idx + 1)?.timeMs ?: (line?.timeMs ?: 0L) + 4_000L
        // 每 tick 都同步真实播放状态：paused 残留为 true 时，歌词栏会一直画"暂停标记"、
        // 而且只画淡墨不做逐字染色（用户反馈"悬浮栏没有唱过的渲染"就是这个）
        LyricsBarState.paused = !PlayerManager.isPlaying.value
        LyricsBarWindow.sync()
    }

    private fun render(animate: Boolean) {
        if (lines.isEmpty()) {
            LyricsBarState.emptyText = if (loading) "歌词加载中…" else "暂无歌词"
            return
        }
        LyricsBarState.emptyText = ""
        val idx = lastIndex.coerceIn(0, lines.size - 1)
        val cur = lines.getOrNull(idx)
        LyricsBarState.curText = cur?.text ?: ""
        LyricsBarState.nextText = lines.getOrNull(idx + 1)?.text ?: ""
        LyricsBarState.curLine = cur
        LyricsBarState.nextStartMs = lines.getOrNull(idx + 1)?.timeMs ?: (cur?.timeMs ?: 0L) + 4_000L
        if (animate) LyricsBarState.lineTick += 1
        LyricsBarWindow.sync()
    }

    private inline fun onEdt(crossinline block: () -> Unit) {
        if (SwingUtilities.isEventDispatchThread()) block() else SwingUtilities.invokeLater { block() }
    }
}

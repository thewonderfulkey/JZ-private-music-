package com.jz.musichelper.data

import android.content.Context
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import com.jz.musichelper.model.Song
import com.jz.musichelper.network.LyricLine
import com.jz.musichelper.network.LyricsService
import com.jz.musichelper.ui.DesktopLyricsView
import com.jz.musichelper.ui.LyricsBarAction
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * 桌面歌词：一层 TYPE_APPLICATION_OVERLAY 悬浮窗，由常驻的 PlayerService 期间存活，
 * 窗口内部是自绘的 DesktopLyricsView。
 *
 * 数据全部复用现成链路：
 *  - 取词：LyricsService.fetch(song)（唯一源 LDDC，4h 缓存 + in-flight 去重；App.kt 点击/切歌时已预取）
 *  - 定位：LyricsService.indexAt(lines, position)
 *  - 位置：PlayerManager.currentPositionMs()（直读 MediaPlayer，不用 500ms 的 ticker 粒度）
 *
 * 显示口径：
 *  - 两行：当前行 + 下一行；当前行有逐字染色和底边进度线
 *  - App 在前台时不显示，回到桌面/切到别的应用才出现
 *  - 暂停保留最后一帧、变灰并带「‖」，不整窗消失
 *  - 默认底部居中偏上 120dp，可拖动，松手吸附（左右各留 16dp），位置按屏幕比例记忆
 *  - v2.1.77：轻点纸签浮出工具条（上一句/暂停/下一句/字号/锁定/关闭），锁定后不可拖动
 */
object DesktopLyrics {

    private const val PREFS = "jz_music_prefs"
    private const val KEY_ON = "dl_enabled"
    private const val KEY_FX = "dl_frac_x"
    private const val KEY_FY = "dl_frac_y"
    private const val KEY_THEME = "dl_theme"
    private const val KEY_FONT = "dl_font"
    private const val KEY_LOCK = "dl_lock"
    private const val TICK_MS = 100L

    // v2.1.77：宽度 308dp（旧 274dp 一行只放得下 13 字，是省略号的直接原因）
    private const val W_DP = 308f
    private const val W_SIDE_DP = 10f        // 屏宽不足 308dp 时的最小两侧留白
    private const val DEFAULT_BOTTOM_DP = 120f
    private const val EDGE_DP = 12f

    private lateinit var ctx: Context
    private var wm: WindowManager? = null
    private var view: DesktopLyricsView? = null
    private var lp: WindowManager.LayoutParams? = null

    private val _enabled = MutableStateFlow(false)
    val enabled: StateFlow<Boolean> = _enabled

    private val _canOverlay = MutableStateFlow(false)
    val canOverlay: StateFlow<Boolean> = _canOverlay

    /** 窗口挂不出去时的原因（悬浮窗权限为真但被系统二次拦截等），设置页直接显示出来 */
    private val _error = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _error

    /** 0 素纸 / 1 旧黄 / 2 夜墨 */
    private val _theme = MutableStateFlow(0)
    val theme: StateFlow<Int> = _theme

    /** 字号档位 -2..2，步进 8% */
    private val _fontStep = MutableStateFlow(0)
    val fontStep: StateFlow<Int> = _fontStep

    private val _locked = MutableStateFlow(false)
    val locked: StateFlow<Boolean> = _locked

    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var fetchJob: Job? = null

    private var songKey: String? = null
    private var lines: List<LyricLine> = emptyList()
    private var lastIndex = -1
    private var loading = false
    private var playing = false
    private var appVisible = true     // App 是否在前台（前台时不显示悬浮歌词）
    private var pendingEnable = false // 点了开关但还没拿到悬浮窗权限
    private var tickerOn = false
    private var dragStartX = 0
    private var dragStartY = 0
    private var toolbarOpen = false

    private val ticker = object : Runnable {
        override fun run() {
            if (!tickerOn) return
            syncFromSources()
            if (playing) tickOnce()
            main.postDelayed(this, TICK_MS)
        }
    }

    /**
     * 自己盯播放状态，不依赖 Compose 重组：退到桌面后组合不再出帧，若靠 LaunchedEffect 推状态，
     * 自动连播切歌时歌词栏会停在上一首。这里每 200ms 读一次 AppState.lastSong 与 PlayerManager.isPlaying。
     */
    private fun syncFromSources() {
        val song = com.jz.musichelper.ui.AppState.lastSong.value
        val key = song?.let { it.platform.name + "|" + it.platformID }
        if (key != songKey) onSongChanged(song)
        val nowPlaying = PlayerManager.isPlaying.value
        if (nowPlaying != playing) {
            playing = nowPlaying
            view?.setPaused(!nowPlaying)
        }
    }

    fun init(context: Context) {
        if (::ctx.isInitialized) return
        ctx = context.applicationContext
        wm = ctx.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        _enabled.value = prefs().getBoolean(KEY_ON, false)
        _theme.value = prefs().getInt(KEY_THEME, 0).coerceIn(0, 2)
        _fontStep.value = prefs().getInt(KEY_FONT, 0).coerceIn(-2, 2)
        _locked.value = prefs().getBoolean(KEY_LOCK, false)
        refreshPermission()
        runCatching {
            ctx.registerComponentCallbacks(object : android.content.ComponentCallbacks {
                override fun onConfigurationChanged(newConfig: Configuration) {
                    main.post { relayout() }
                }

                override fun onLowMemory() {}
            })
        }
    }

    private fun prefs() = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun dp(v: Float): Int = (v * ctx.resources.displayMetrics.density).toInt()

    fun refreshPermission() {
        if (!::ctx.isInitialized) return
        val ok = runCatching { Settings.canDrawOverlays(ctx) }.getOrDefault(false)
        _canOverlay.value = ok
    }

    /** App 回到前台：复查权限；若之前因缺权限没开成，现在补上 */
    fun onResume() {
        if (!::ctx.isInitialized) return
        refreshPermission()
        if (pendingEnable && _canOverlay.value) {
            pendingEnable = false
            persist(true)
        }
        if (_enabled.value && !_canOverlay.value) detach() else syncWindow()
    }

    /**
     * 开关入口（设置页与播放页菜单共用）。
     * @return false 表示缺悬浮窗权限——调用方应提示并打开系统权限页
     */
    fun toggleFromUi(on: Boolean): Boolean {
        if (!::ctx.isInitialized) return false
        if (on) {
            refreshPermission()
            if (!_canOverlay.value) {
                pendingEnable = true
                return false
            }
        }
        pendingEnable = false
        persist(on)
        return true
    }

    private fun persist(on: Boolean) {
        prefs().edit().putBoolean(KEY_ON, on).apply()
        if (_enabled.value == on) {
            syncWindow()
            return
        }
        _enabled.value = on
        if (on) syncWindow() else detach()
    }

    // ===== 外观设置（设置页 / 工具条共用）=====

    fun setTheme(index: Int) {
        val i = index.coerceIn(0, 2)
        if (_theme.value == i) return
        _theme.value = i
        if (::ctx.isInitialized) prefs().edit().putInt(KEY_THEME, i).apply()
        view?.setTheme(i)
    }

    fun adjustFontStep(delta: Int) {
        val next = (_fontStep.value + delta).coerceIn(-2, 2)
        if (next == _fontStep.value) return
        _fontStep.value = next
        if (::ctx.isInitialized) prefs().edit().putInt(KEY_FONT, next).apply()
        view?.setFontStep(next)
    }

    fun toggleLock() {
        val next = !_locked.value
        _locked.value = next
        if (::ctx.isInitialized) prefs().edit().putBoolean(KEY_LOCK, next).apply()
        view?.setLocked(next)
    }

    /** App 是否在前台（MainActivity onResume/onPause 驱动） */
    fun setAppVisible(visible: Boolean) {
        if (appVisible == visible) return
        appVisible = visible
        syncWindow()
    }

    fun setPlaying(value: Boolean) {
        if (playing == value) return
        playing = value
        if (view != null) startLoop()
        view?.setPaused(!value)
    }

    /** 切歌：清空、发起取词（命中 4h 缓存时几乎立刻返回） */
    fun onSongChanged(song: Song?) {
        if (!::ctx.isInitialized) return
        if (song == null) {
            songKey = null
            lines = emptyList()
            lastIndex = -1
            loading = false
            // 不能在这里 detach + stopTicker：attach() 里刚把窗口挂上就会立刻被拆掉，
            // 而且循环一停就再也发现不了"从通知栏/自动连播起歌"，桌面歌词会一直是空的。
            view?.setEmpty("暂无歌词")
            syncWindow()
            return
        }
        val key = song.platform.name + "|" + song.platformID
        if (key == songKey) {
            syncWindow()
            return
        }
        songKey = key
        lines = emptyList()
        lastIndex = -1
        loading = true
        view?.setPaused(!playing)
        view?.setEmpty("歌词加载中…")
        syncWindow()
        startLoop()

        fetchJob?.cancel()
        fetchJob = scope.launch {
            val result = runCatching { LyricsService.fetch(song) }.getOrNull()
            if (songKey != key) return@launch
            lines = result?.lines ?: emptyList()
            loading = false
            lastIndex = if (lines.isEmpty()) -1 else LyricsService.indexAt(lines, PlayerManager.currentPositionMs())
            if (lines.isEmpty()) view?.setEmpty("暂无歌词") else render(true)
            syncWindow()
        }
    }

    fun resetPosition() {
        if (!::ctx.isInitialized) return
        prefs().edit().remove(KEY_FX).remove(KEY_FY).apply()
        applyPosition()
    }

    // ===== 窗口 =====

    private fun syncWindow() {
        if (!::ctx.isInitialized) return
        // 不能把 songKey 也算进闸门：songKey 只由 ticker 里的 syncFromSources() 写入，
        // ticker 又只在 attach() 里启动——那样窗口永远挂不出来（v2.1.74 首版即此死锁）。
        val should = _enabled.value && _canOverlay.value && !appVisible
        if (!should) {
            detach()
            return
        }
        attach()
    }

    private fun attach() {
        val manager = wm ?: return
        val dm = ctx.resources.displayMetrics
        val width = dp(W_DP).coerceAtMost(dm.widthPixels - dp(W_SIDE_DP) * 2)

        if (view == null) {
            val v = DesktopLyricsView(ctx)
            v.setTheme(_theme.value)
            v.setFontStep(_fontStep.value)
            v.setLocked(_locked.value)
            v.onDragStart = {
                dragStartX = lp?.x ?: 0
                dragStartY = lp?.y ?: 0
            }
            v.onDragMove = { dx, dy -> move(dx, dy) }
            v.onDragEnd = { settle() }
            v.onTapBar = { toggleToolbar() }
            v.onAction = { action -> handleAction(action) }
            v.onHeightChanged = { main.post { applyHeight() } }

            playing = PlayerManager.isPlaying.value
            if (lines.isEmpty()) v.setEmpty(if (loading) "歌词加载中…" else "暂无歌词") else render(false)

            val height = v.preferredHeightPx()
            val p = WindowManager.LayoutParams(
                width,
                height,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, // minSdk 26 起统一用这个，不再走旧的 TYPE_PHONE
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP or Gravity.START
            }
            positionOf(p)
            val added = runCatching { manager.addView(v, p) }.isSuccess
            if (!added) {
                // 权限刚被收回 / 系统二次拦截：关掉开关，避免状态与画面不一致，并把原因留给设置页显示
                pendingEnable = true
                _canOverlay.value = false
                _error.value = "系统拦截了悬浮窗，请在系统设置里允许「显示在其他应用上层 / 显示悬浮窗」"
                prefs().edit().putBoolean(KEY_ON, false).apply()
                _enabled.value = false
                return
            }
            view = v
            lp = p
            _error.value = null
            // 必须在这里起循环并立刻拉一次当前歌曲：窗口挂上之前没人会调 onSongChanged，
            // 只靠 200ms 循环去等，首帧会空着（这是 v2.1.74 首版不显示的根因）
            startLoop()
            syncFromSources()
            v.setPaused(!playing)
        } else {
            val p = lp ?: return
            if (p.width != width) {
                p.width = width
                runCatching { manager.updateViewLayout(view, p) }
            }
            applyPosition()
        }
    }

    /** 折行 / 工具条展开会让栏体变高：栏体顶端不动，向下长出工具条 */
    private fun applyHeight() {
        val p = lp ?: return
        val v = view ?: return
        val h = v.preferredHeightPx()
        if (p.height == h) return
        val dm = ctx.resources.displayMetrics
        p.height = h
        p.y = p.y.coerceIn(0, (dm.heightPixels - h).coerceAtLeast(0))
        runCatching { wm?.updateViewLayout(v, p) }
    }

    private fun toggleToolbar() {
        val open = view?.isToolbarOpen() ?: false
        toolbarOpen = !open
        view?.setToolbar(!open)
    }

    private fun handleAction(action: LyricsBarAction) {
        when (action) {
            LyricsBarAction.PREV -> seekToLine(lastIndex - 1)
            LyricsBarAction.NEXT -> seekToLine(lastIndex + 1)
            LyricsBarAction.PLAY_PAUSE -> PlayerManager.toggle()
            LyricsBarAction.FONT_MINUS -> adjustFontStep(-1)
            LyricsBarAction.FONT_PLUS -> adjustFontStep(1)
            LyricsBarAction.LOCK -> toggleLock()
            LyricsBarAction.CLOSE -> {
                toolbarOpen = false
                view?.setToolbar(false)
                toggleFromUi(false)
            }
        }
    }

    /** 工具条的上一句 / 下一句：跳到相邻歌词行的时间点，不切歌 */
    private fun seekToLine(index: Int) {
        if (lines.isEmpty()) return
        val i = index.coerceIn(0, lines.size - 1)
        if (i == lastIndex) return
        PlayerManager.seekTo(lines[i].timeMs)
        lastIndex = i
        render(false)
        view?.setKaraoke(0f)
    }

    private fun detach() {
        stopTicker()
        toolbarOpen = false
        val v = view ?: return
        runCatching { wm?.removeView(v) }
        view = null
        lp = null
    }

    private fun relayout() {
        if (view == null) {
            syncWindow()
            return
        }
        attach()
    }

    private fun positionOf(p: WindowManager.LayoutParams) {
        val dm = ctx.resources.displayMetrics
        val maxX = (dm.widthPixels - p.width).coerceAtLeast(0)
        val maxY = (dm.heightPixels - p.height).coerceAtLeast(0)
        val fx = prefs().getFloat(KEY_FX, 0.5f)
        val fy = prefs().getFloat(KEY_FY, -1f)
        p.x = (maxX * fx).toInt().coerceIn(0, maxX)
        p.y = if (fy < 0f) (maxY - dp(DEFAULT_BOTTOM_DP)).coerceIn(0, maxY)
        else (maxY * fy).toInt().coerceIn(0, maxY)
    }

    private fun applyPosition() {
        val p = lp ?: return
        val v = view ?: return
        positionOf(p)
        runCatching { wm?.updateViewLayout(v, p) }
    }

    private fun move(dx: Float, dy: Float) {
        val p = lp ?: return
        val v = view ?: return
        val dm = ctx.resources.displayMetrics
        val maxX = (dm.widthPixels - p.width).coerceAtLeast(0)
        val maxY = (dm.heightPixels - p.height).coerceAtLeast(0)
        p.x = (dragStartX + dx.toInt()).coerceIn(0, maxX)
        p.y = (dragStartY + dy.toInt()).coerceIn(0, maxY)
        runCatching { wm?.updateViewLayout(v, p) }
    }

    /** 松手：左右各留 12dp，位置按屏幕比例记下来（转屏后按比例复位） */
    private fun settle() {
        val p = lp ?: return
        val v = view ?: return
        val dm = ctx.resources.displayMetrics
        val maxX = (dm.widthPixels - p.width).coerceAtLeast(0)
        val maxY = (dm.heightPixels - p.height).coerceAtLeast(0)
        val edge = dp(EDGE_DP)
        p.x = p.x.coerceIn(minOf(edge, maxX / 2), maxOf(maxX - edge, maxX / 2))
        p.y = p.y.coerceIn(0, maxY)
        runCatching { wm?.updateViewLayout(v, p) }
        val maxXf = maxX.coerceAtLeast(1)
        val maxYf = maxY.coerceAtLeast(1)
        prefs().edit()
            .putFloat(KEY_FX, p.x.toFloat() / maxXf)
            .putFloat(KEY_FY, p.y.toFloat() / maxYf)
            .apply()
    }

    // ===== 滚动 =====

    private fun startLoop() {
        if (tickerOn) return
        tickerOn = true
        main.removeCallbacks(ticker)
        main.postDelayed(ticker, TICK_MS)
        view?.setPaused(!playing)
    }

    private fun stopTicker() {
        tickerOn = false
        main.removeCallbacks(ticker)
    }

    private fun tickOnce() {
        if (lines.isEmpty()) return
        val pos = PlayerManager.currentPositionMs()
        val idx = LyricsService.indexAt(lines, pos)
        val line = lines.getOrNull(idx) ?: return
        // 先给新句的逐字时间，再换文本：保证换句那一刻字符映射已对齐（rebuild 会重算映射）
        view?.setWordTiming(line.words)
        if (idx != lastIndex) {
            lastIndex = idx
            render(true)
            // 换句时不要直接归零后等下一拍（那会整整慢半拍）：立刻按当前播放位置算进度
        }
        val start = line.timeMs
        val end = lines.getOrNull(idx + 1)?.timeMs ?: (start + 4000L)
        val span = (end - start).coerceAtLeast(1L)

        // v2.1.79：优先按逐字时间（KRC/QRC 原生毫秒）推进；无逐字时间才用行内均分回退
        view?.setPosition(pos)
        if (line.words.isEmpty()) {
            view?.setKaraoke((pos - start).toFloat() / span.toFloat())
        }
    }

    /** 把当前行/下一行推给窗口；animate=false 用于刚挂窗或换歌后的第一次 */
    private fun render(animate: Boolean) {
        val v = view ?: return
        if (lines.isEmpty()) {
            v.setEmpty(if (loading) "歌词加载中…" else "暂无歌词")
            return
        }
        val idx = lastIndex.coerceIn(0, lines.size - 1)
        val cur = lines.getOrNull(idx)?.text ?: ""
        val next = lines.getOrNull(idx + 1)?.text ?: ""
        v.setPaused(!playing)
        v.setPair(cur, next, animate)
    }

    /** 打开系统「显示在其他应用上层」权限页；国产 ROM 打不开时退到应用详情页 */
    fun openOverlaySettings(context: Context): Boolean {
        val uri = android.net.Uri.parse("package:" + context.packageName)
        val intents = listOf(
            android.content.Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, uri),
            android.content.Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION),
            android.content.Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, uri)
        )
        for (intent in intents) {
            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            if (runCatching { context.startActivity(intent) }.isSuccess) return true
        }
        return false
    }
}

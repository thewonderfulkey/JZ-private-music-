package com.jz.musichelper.data

import android.content.Context
import android.media.MediaPlayer
import android.net.Uri
import com.jz.musichelper.network.ApiClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

// 在线试听：系统 MediaPlayer（带 UA/Referer 头）+ 进度/时长状态流
object PlayerManager {

    private lateinit var appContext: Context
    private var player: MediaPlayer? = null
    // v2.1.68：播放代次。每次 play()/stop() 递增，回调进来先比代次，
    // 防止上一首歌迟到的 onCompletion/onError 把刚响起的新歌又"跳"掉（用户反馈的"刚出声就切下一首"）
    private var gen = 0
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var tickJob: Job? = null

    private val _currentUrl = MutableStateFlow<String?>(null)
    val currentUrl: StateFlow<String?> = _currentUrl

    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying

    private val _position = MutableStateFlow(0L)
    val position: StateFlow<Long> = _position

    private val _duration = MutableStateFlow(0L)
    val duration: StateFlow<Long> = _duration

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error

    // v2.1.7：音源时长不匹配信号（含来源标签与实测/期望时长）——播放层第二道防线：
    // oiapi 可能歌名/歌手伪装正确但音频实为伴奏（"夜曲"正版 226s vs 伴奏 98s），
    // 实际缓冲时长与曲目时长差 >5s 即触发；上层据此标记无源并自动跳过/隐藏
    private val _sourceMismatch = MutableStateFlow<String?>(null)
    val sourceMismatch: StateFlow<String?> = _sourceMismatch

    // 播放完成事件（自增序号，供上层自动连播）
    private val _completed = MutableStateFlow(0L)
    val completed: StateFlow<Long> = _completed

    // v2.1.26：播放失败事件（源加载不出/中途失效，自增序号）——上层据此对该歌换源重试，
    // 不再因 MediaPlayer 错误而静默卡住（后台播放页未打开同样生效）
    private val _playbackFailed = MutableStateFlow(0L)
    val playbackFailed: StateFlow<Long> = _playbackFailed

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /**
     * v2.1.85：startAtMs 用于"缓存好了把播放源从网络切到本地文件"——切过去时从当前位置接着放，
     * 不回到 0 秒、不打断听感。
     */
    /**
     * v2.1.94：识曲期间禁止任何自动起播。
     * 用户实测"点识曲后正常暂停了，但录到一半歌又自己响起来"——来源不止一处：
     * 缓存落盘后切本地源、自动连播、取流兜底重试，最终都会走到 play()。
     * 统一在入口拦住，比逐个调用点堵更可靠。
     */
    @Volatile
    private var holdReason: String? = null

    fun holdPlayback(reason: String) { holdReason = reason }

    fun releaseHold() { holdReason = null }

    fun play(
        url: String,
        expectedDurationSec: Int? = null,
        sourceLabel: String? = null,
        startAtMs: Long = 0L
    ) {
        holdReason?.let {
            android.util.Log.i("JZ_PLAY", "play blocked by $it: ${url.take(80)}")
            return
        }
        // v2.1.5 #5：播放即拉起前台服务（息屏/Doze 下保活，连播链路不被冻结）；
        // 服务已运行时仅刷新通知；后台自动连播时服务仍在运行，不会触发后台启动限制
        PlayerService.start(appContext)
        stop()
        val myGen = gen
        PlayLog.log("play gen=$myGen src=${sourceLabel ?: "?"} url=${url.take(90)}")
        _currentUrl.value = url
        _error.value = null
        _sourceMismatch.value = null
        _position.value = 0L
        try {
            val mp = MediaPlayer()
            // v2.1.70：本地预取文件直接走文件路径；在线源带 UA/Referer
            if (url.startsWith("/") || url.startsWith("file://")) {
                mp.setDataSource(url.removePrefix("file://"))
            } else {
                mp.setDataSource(appContext, Uri.parse(url), mapOf(
                    "User-Agent" to ApiClient.MOBILE_UA,
                    "Referer" to "https://music.qq.com/"
                ))
            }
            mp.setOnPreparedListener {
                if (myGen != gen) { runCatching { mp.release() }; return@setOnPreparedListener }
                // v2.1.7：播放层时长 ±5s 硬校验（第二道防线，针对伪装文本的劣质源）——
                // 实际缓冲时长与曲目时长差 >5s 即判定音源不匹配：不播放、释放、发不匹配信号
                val actualSec = (it.duration / 1000L).toInt()
                if (expectedDurationSec != null && expectedDurationSec > 0 && actualSec > 0 &&
                    kotlin.math.abs(actualSec - expectedDurationSec) > 5
                ) {
                    _isPlaying.value = false
                    _position.value = 0L
                    _currentUrl.value = null   // v2.1.26：时长不符视为该源失效，清空 URL 供上层换源重试（防防重入拦截）
                    _sourceMismatch.value =
                        "${sourceLabel ?: "音源"}时长 ${actualSec}s 与曲目 ${expectedDurationSec}s 不符（±5s），已拒绝"
                    release()
                    return@setOnPreparedListener
                }
                it.start()
                // v2.1.85：换到本地缓存时从原位置接着放
                if (startAtMs > 0L) {
                    runCatching { it.seekTo(startAtMs.coerceAtMost(it.duration.toLong() - 500L).toInt()) }
                    _position.value = startAtMs
                }
                _isPlaying.value = true
                _duration.value = it.duration.toLong().coerceAtLeast(0L)
                // v2.1.69：按曲目时长排"曲终闹铃"——Doze 下播完回调送不到时，靠闹铃到点唤醒推进下一首
                TrackEndAlarm.schedule(appContext, it.duration.toLong() - 2000L)
                startTicker()
                // 切歌后刷新前台服务通知文案（歌名/歌手）
                PlayerService.refresh(appContext)
            }
            mp.setOnCompletionListener {
                if (myGen != gen) return@setOnCompletionListener
                PlayLog.log("completed gen=$myGen pos=${_position.value}")
                TrackEndAlarm.cancel(appContext)
                _isPlaying.value = false
                _position.value = _duration.value
                _completed.value++
            }
            mp.setOnErrorListener { _, _, _ ->
                if (myGen != gen) return@setOnErrorListener true
                PlayLog.log("error gen=$myGen")
                _error.value = "播放失败（源可能已失效）"
                _isPlaying.value = false
                _currentUrl.value = null   // v2.1.26：源失效清空当前 URL，允许上层重新取流换源（后台不卡住）
                _playbackFailed.value++
                release()
                true
            }
            mp.prepareAsync()
            player = mp
        } catch (e: Exception) {
            _error.value = "播放失败：${e.message}"
        }
    }

    fun toggle() {
        val p = player ?: return
        if (_isPlaying.value) {
            p.pause()
            _isPlaying.value = false
        } else {
            p.start()
            _isPlaying.value = true
            startTicker()
        }
    }

    /**
     * v2.1.80：只暂停、不切换曲目。
     * 听歌识曲要开麦克风采集环境音，若此刻本机还在外放，录进去的就是自己正在放的这首，
     * 识曲必然错成"当前歌曲"，所以监听前先把它按停。
     */
    fun pause() {
        val p = player ?: return
        if (_isPlaying.value) {
            runCatching { p.pause() }
            _isPlaying.value = false
        }
    }

    fun seekTo(ms: Long) {        val p = player ?: return
        runCatching { p.seekTo(ms.toInt()) }
        _position.value = ms
    }

    /**
     * v2.1.74：直读当前播放位置（毫秒）。
     * 桌面歌词按行切换对时间很敏感，ticker 的 500ms 粒度会让换行最多晚半拍，所以单独给一个精确读法；
     * 播放器还没准备好（player==null）时退回最近一次 ticker 的位置。
     */
    fun currentPositionMs(): Long =
        runCatching { player?.currentPosition?.toLong() }.getOrNull() ?: _position.value

    private fun startTicker() {
        tickJob?.cancel()
        tickJob = scope.launch {
            while (_isPlaying.value) {
                runCatching { _position.value = player?.currentPosition?.toLong() ?: _position.value }
                delay(500)
            }
        }
    }

    fun stop() {
        tickJob?.cancel()
        release()
        gen++
        runCatching { TrackEndAlarm.cancel(appContext) }
        PlayLog.log("stop gen=$gen")
        _isPlaying.value = false
        _currentUrl.value = null
        _position.value = 0L
        _duration.value = 0L
        _sourceMismatch.value = null
    }

    private fun release() {
        player?.release()
        player = null
    }
}

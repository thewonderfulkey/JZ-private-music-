package com.jz.musichelper.data

import com.jz.musichelper.network.ApiClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.bytedeco.ffmpeg.global.avutil
import org.bytedeco.javacv.FFmpegFrameGrabber
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioSystem
import javax.sound.sampled.DataLine
import javax.sound.sampled.SourceDataLine
import kotlin.math.abs

/**
 * Windows 桌面版播放内核：FFmpeg 解码（mp3 / flac / m4a / ogg / wav 全覆盖）+ Java Sound 输出。
 *
 * 为什么不用 JavaFX Media：它不支持 FLAC，而且**不能给请求加 User-Agent / Referer**——
 * 四平台直链基本都校验这两个头，缺了就直接 403。FFmpeg 原生支持 http(s) 头、Range 与全部容器，
 * 所以取流/缓存/下载这套链路的语义能和 Android 侧保持一致。
 *
 * 对外 API 与 Android 版 `PlayerManager` 完全一致（同一个 StateFlow 集合、同一套 gen 代次防串音），
 * 上层 App.kt / PlayerScreen / DesktopLyrics 一行都不用改。
 *
 * 播放位置口径：取声卡已消费的帧数（`SourceDataLine.longFramePosition`），不是解码进度——
 * 解码永远快于实时，用解码进度画进度条会一路跑飞。
 */
object PlayerManager {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
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

    private val _sourceMismatch = MutableStateFlow<String?>(null)
    val sourceMismatch: StateFlow<String?> = _sourceMismatch

    private val _completed = MutableStateFlow(0L)
    val completed: StateFlow<Long> = _completed

    private val _playbackFailed = MutableStateFlow(0L)
    val playbackFailed: StateFlow<Long> = _playbackFailed

    // 桌面版新增：音量（Android 由系统音量键负责，PC 客户端必须自带一个）
    private val _volume = MutableStateFlow(AppEnv.prefs("jz_music_prefs").getFloat("volume", 0.8f))
    val volume: StateFlow<Float> = _volume

    fun setVolume(v: Float) {
        val target = v.coerceIn(0f, 1f)
        _volume.value = target
        runCatching {
            AppEnv.prefs("jz_music_prefs").edit().putFloat("volume", target).apply()
        }
        applyGain()
    }

    private fun gainDb(v: Float): Float =
        if (v <= 0.0005f) -80f else (20.0 * kotlin.math.log10(v.toDouble())).toFloat().coerceIn(-80f, 6f)

    private fun applyGain() {
        val l = line ?: return
        runCatching {
            (l.getControl(javax.sound.sampled.FloatControl.Type.MASTER_GAIN) as? javax.sound.sampled.FloatControl)
                ?.value = gainDb(_volume.value)
        }
    }

    // 播放代次：每次 play()/stop() 递增，解码线程与回调先比代次，
    // 防止上一首迟到的 EOF/异常把刚响起的新歌又"跳"掉（v2.1.68 的同一个坑）
    @Volatile
    private var gen = 0

    @Volatile
    private var holdReason: String? = null

    fun holdPlayback(reason: String) { holdReason = reason }
    fun releaseHold() { holdReason = null }

    private val audioLock = Any()

    @Volatile
    private var grabber: FFmpegFrameGrabber? = null

    @Volatile
    private var line: SourceDataLine? = null

    @Volatile
    private var decodeThread: Thread? = null

    @Volatile
    private var sampleRate = 44100

    @Volatile
    private var wantPlaying = false

    /** 本次 seek 的起点（毫秒），播放位置 = seekBaseMs + 已消费帧数换算 */
    @Volatile
    private var seekBaseMs = 0L

    /** 待处理的跳转目标（毫秒）；由解码线程消费，UI 线程只写这一个 volatile */
    @Volatile
    private var pendingSeek: Long? = null

    @Volatile
    private var lineBaseFrames = 0L

    /** 给设置页/诊断用：当前解码器的真实容器与采样率 */
    @Volatile
    var engineInfo: String = ""

    fun init() {
        // 预热 ffmpeg 本地库，避免第一次播放时才开始解压 dll（会有 1~2s 空档）
        Thread {
            runCatching { org.bytedeco.javacpp.Loader.load(org.bytedeco.ffmpeg.global.avformat::class.java) }
                .onFailure { JzLog.e("JZ_PLAY", "ffmpeg 本地库加载失败", it) }
        }.apply { isDaemon = true; name = "ffmpeg-warmup" }.start()
    }

    fun play(
        url: String,
        expectedDurationSec: Int? = null,
        sourceLabel: String? = null,
        startAtMs: Long = 0L
    ) {
        holdReason?.let {
            JzLog.i("JZ_PLAY", "play blocked by $it: ${url.take(80)}")
            return
        }
        stop()
        val myGen = gen
        PlayLog.log("play gen=$myGen src=${sourceLabel ?: "?"} url=${url.take(90)}")
        _currentUrl.value = url
        _error.value = null
        _sourceMismatch.value = null
        _position.value = 0L

        val t = Thread {
            val g: FFmpegFrameGrabber
            try {
                g = openGrabber(url)
            } catch (e: Exception) {
                if (myGen != gen) return@Thread
                JzLog.w("JZ_PLAY", "open failed: ${e.message}")
                fail(myGen, "播放失败：${e.message ?: "源不可用"}")
                return@Thread
            }
            synchronized(audioLock) {
                if (myGen != gen) { runCatching { g.close() }; return@Thread }
                grabber = g
                val durMs = (g.lengthInTime / 1000L).coerceAtLeast(0L)
                val actualSec = (durMs / 1000L).toInt()
                // 播放层时长 ±5s 硬校验（第二道防线，针对伪装文本的劣质源）
                if (expectedDurationSec != null && expectedDurationSec > 0 && actualSec > 0 &&
                    abs(actualSec - expectedDurationSec) > 5
                ) {
                    _isPlaying.value = false
                    _position.value = 0L
                    _currentUrl.value = null
                    _sourceMismatch.value =
                        "${sourceLabel ?: "音源"}时长 ${actualSec}s 与曲目 ${expectedDurationSec}s 不符（±5s），已拒绝"
                    runCatching { g.close() }
                    grabber = null
                    return@Thread
                }
                val rate = g.sampleRate.takeIf { it > 0 } ?: 44100
                sampleRate = rate
                engineInfo = "${containerOf(url)} ${rate}Hz/${g.audioChannels}ch"
                if (g.audioChannels <= 0 || g.sampleRate <= 0) {
                    runCatching { g.close() }
                    grabber = null
                    fail(myGen, "播放失败（源可能已失效）")
                    return@Thread
                }
                val fmt = AudioFormat(rate.toFloat(), 16, 2, true, false)
                val info = DataLine.Info(SourceDataLine::class.java, fmt, rate * 4 / 2)
                val l = runCatching { AudioSystem.getLine(info) as SourceDataLine }.getOrNull()
                if (l == null) {
                    runCatching { g.close() }
                    grabber = null
                    fail(myGen, "无法打开音频输出设备")
                    return@Thread
                }
                l.open(fmt, rate * 4 / 3)   // ~0.33s 缓冲：拖动进度条时响应快，又不至于一顿一顿
                line = l
                seekBaseMs = 0L
                lineBaseFrames = 0L
                wantPlaying = true
                _duration.value = if (durMs > 0) durMs else (expectedDurationSec ?: 0).toLong() * 1000L
                if (startAtMs > 0L) {
                    // v2.1.85：从网络源切到本地缓存时接着放，不回 0 秒
                    runCatching { g.setTimestamp(startAtMs * 1000L) }
                    seekBaseMs = startAtMs
                    _position.value = startAtMs
                }
                l.start()
                _isPlaying.value = true
                applyGain()
                startTicker()
            }
            decodeLoop(myGen, g)
        }
        t.isDaemon = true
        t.name = "jz-decode"
        decodeThread = t
        t.start()
    }

    private fun openGrabber(url: String): FFmpegFrameGrabber {
        // Windows 本地路径形如 "C:\..."（盘符开头），不能用 startsWith("/") 判——
        // 否则本地缓存文件会被当成远程流，白白多挂一遍 http 选项
        val isLocal = url.startsWith("file://") || url.startsWith("\\\\") ||
            Regex("^[A-Za-z]:[\\\\/]").containsMatchIn(url)
        val path = if (url.startsWith("file://")) url.removePrefix("file://") else url
        val g = FFmpegFrameGrabber(path)
        // 与 Android 侧 setDataSource(headers) 等价：平台直链校验 UA / Referer
        g.setOption("user_agent", ApiClient.MOBILE_UA)
        g.setOption("referer", "https://music.qq.com/")
        g.setOption("headers", "User-Agent: ${ApiClient.MOBILE_UA}\r\nReferer: https://music.qq.com/\r\n")
        g.setOption("timeout", "10000000")        // µs：连接/读超时 10s
        g.setOption("rw_timeout", "15000000")
        g.setOption("reconnect", "1")
        g.setOption("reconnect_streamed", "1")
        g.setOption("reconnect_delay_max", "5")
        // 统一重采样成 16bit 有符号小端立体声，声卡侧不用再猜格式
        g.sampleFormat = avutil.AV_SAMPLE_FMT_S16
        g.audioChannels = 2
        g.start()
        JzLog.i("JZ_PLAY", "opened ${if (isLocal) "local" else "remote"} rate=${g.sampleRate} len=${g.lengthInTime}")
        return g
    }

    private fun containerOf(url: String): String {
        val u = url.substringBefore('?').lowercase()
        return when {
            u.endsWith(".flac") -> "flac"
            u.endsWith(".m4a") || u.endsWith(".aac") -> "m4a"
            u.endsWith(".ogg") -> "ogg"
            u.endsWith(".wav") -> "wav"
            u.endsWith(".mp3") -> "mp3"
            else -> "audio"
        }
    }

    private fun decodeLoop(myGen: Int, g: FFmpegFrameGrabber) {
        try {
            while (true) {
                if (myGen != gen) return

                // 跳转请求在解码线程里就地处理：不抢锁、不等网络，UI 侧 seekTo 立即返回，
                // 所以"点歌词快进/拖进度条"不会再把界面卡死（旧实现是从 UI 线程 synchronized 抢锁，
                // 而解码线程正卡在 grabSamples()/write() 里，两边互等到天荒地老）。
                pendingSeek?.let { target ->
                    pendingSeek = null
                    runCatching { g.setTimestamp(target * 1000L) }
                    runCatching { line?.flush() }
                    seekBaseMs = target
                    lineBaseFrames = line?.longFramePosition ?: 0L
                    _position.value = target
                    PlayLog.log("seek applied gen=$myGen -> ${target}ms")
                }

                if (!wantPlaying) { Thread.sleep(15); continue }
                val bytes = synchronized(audioLock) {
                    if (myGen != gen) return@synchronized null
                    if (!wantPlaying) return@synchronized ByteArray(0)
                    val frame = runCatching { g.grabSamples() }.getOrElse { e ->
                        if (myGen == gen) fail(myGen, "播放失败：${e.message ?: "解码中断"}")
                        return
                    }
                    if (frame == null) {
                        if (myGen == gen) onCompleted(myGen)
                        return
                    }
                    val buf = frame.samples?.getOrNull(0) as? java.nio.ShortBuffer ?: return@synchronized ByteArray(0)
                    val arr = ByteArray(buf.remaining() * 2)
                    var i = 0
                    while (buf.hasRemaining()) {
                        val s = buf.get().toInt()
                        arr[i] = (s and 0xFF).toByte()
                        arr[i + 1] = ((s shr 8) and 0xFF).toByte()
                        i += 2
                    }
                    arr
                } ?: continue
                if (bytes.isEmpty()) continue

                // 写声卡不占解码锁、也不整块死等：满缓冲就让出 CPU，暂停/切歌/跳转能立刻生效
                var off = 0
                while (off < bytes.size) {
                    if (myGen != gen) return
                    if (pendingSeek != null) break
                    if (!wantPlaying) { Thread.sleep(10); continue }
                    val l = line ?: return
                    val avail = runCatching { l.available() }.getOrDefault(0)
                    if (avail <= 0) { Thread.sleep(4); continue }
                    val n = minOf(avail, bytes.size - off)
                    l.write(bytes, off, n)
                    off += n
                }
            }
        } catch (_: InterruptedException) {
            // 切歌/停止打断，正常路径
        } catch (e: Exception) {
            if (myGen == gen) fail(myGen, "播放失败：${e.message ?: "未知错误"}")
        }
    }

    private fun onCompleted(myGen: Int) {
        PlayLog.log("completed gen=$myGen pos=${_position.value}")
        _isPlaying.value = false
        _position.value = _duration.value
        _completed.value++
        releaseLine()
    }

    private fun fail(myGen: Int, msg: String) {
        PlayLog.log("error gen=$myGen $msg")
        _error.value = msg
        _isPlaying.value = false
        _currentUrl.value = null      // 源失效清空 URL，允许上层重新取流换源
        _playbackFailed.value++
        releaseLine()
    }

    fun toggle() {
        val l = line ?: return
        if (_isPlaying.value) {
            wantPlaying = false
            runCatching { l.stop() }
            _isPlaying.value = false
        } else {
            wantPlaying = true
            runCatching { l.start() }
            _isPlaying.value = true
            startTicker()
        }
    }

    /** 只暂停、不切换曲目（识曲前静音，避免把自己的外放录进去） */
    fun pause() {
        val l = line ?: return
        if (_isPlaying.value) {
            wantPlaying = false
            runCatching { l.stop() }
            _isPlaying.value = false
        }
    }

    /**
     * 跳转：只登记请求 + 立刻更新进度显示，真正的 setTimestamp/flush 由解码线程在下一拍处理。
     *
     * 这一段以前是从 UI 线程 synchronized(audioLock) 里直接操作 grabber 的——解码线程卡在
     * grabSamples()/write() 时两边互等，点歌词就整个界面冻住。现在无论如何都在 1ms 内返回。
     */
    fun seekTo(ms: Long) {
        if (line == null || grabber == null) return
        val target = ms.coerceAtLeast(0L)
        pendingSeek = target
        _position.value = target
        if (!_isPlaying.value && wantPlaying) {
            // 暂停状态下跳转：把声卡重新跑起来，让解码线程能处理这次 seek
            runCatching { line?.start() }
            _isPlaying.value = true
            startTicker()
        }
    }

    /** 桌面歌词按行切换对时间敏感，单独给一个直读（取声卡已消费帧数） */
    fun currentPositionMs(): Long {
        val l = line
        if (l == null) return _position.value
        val frames = l.longFramePosition - lineBaseFrames
        if (frames < 0) return seekBaseMs
        return seekBaseMs + frames * 1000L / sampleRate.coerceAtLeast(1)
    }

    private fun startTicker() {
        tickJob?.cancel()
        tickJob = scope.launch {
            while (_isPlaying.value) {
                _position.value = currentPositionMs()
                delay(500)
            }
        }
    }

    fun stop() {
        tickJob?.cancel()
        gen++
        wantPlaying = false
        decodeThread?.interrupt()
        decodeThread = null
        releaseLine()
        PlayLog.log("stop gen=$gen")
        _isPlaying.value = false
        _currentUrl.value = null
        _position.value = 0L
        _duration.value = 0L
        _sourceMismatch.value = null
    }

    private fun releaseLine() {
        synchronized(audioLock) {
            wantPlaying = false
            runCatching { line?.stop() }
            runCatching { line?.flush() }
            runCatching { line?.close() }
            line = null
            runCatching { grabber?.close() }
            grabber = null
        }
    }

    /** 退出前释放（jpackage 打包的应用被关窗时调用） */
    fun shutdown() {
        runCatching { stop() }
    }
}

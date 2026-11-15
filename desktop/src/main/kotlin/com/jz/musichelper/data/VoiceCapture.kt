package com.jz.musichelper.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioSystem
import javax.sound.sampled.DataLine
import javax.sound.sampled.TargetDataLine
import kotlin.math.sqrt

/**
 * 听歌识曲的麦克风采集（Windows 桌面版）。
 *
 * 采样口径严格对齐酷狗识曲接口：最终送识别的一律是 8kHz / 单声道 / 16bit 小端。
 * 整段 PCM 只留在内存里（ByteArray），不落盘、不进缓存，识别完即随作用域回收。
 *
 * Android 侧用 AudioRecord（VOICE_RECOGNITION 音源 + 原生采样率探测）解决的是「很多机型 8k 只给静音」，
 * 桌面侧对应问题是「声卡只接受特定采样率」——这里同样从高到低探测第一个真正能开的格式，
 * 采完再用多点平均降到 8k（整倍数）或线性插值（44.1k 这类非整倍数）。
 */
object VoiceCapture {

    const val SAMPLE_RATE = 8000

    // 识曲时长可配置（右上角按钮，持久化）；12 是网易通道的最低要求
    const val MAX_SECONDS = 20
    const val MIN_SECONDS = 12
    const val DEFAULT_SECONDS = 12

    /** 拿到足够走酷狗的时长就先问一次酷狗（默认 6 秒），命中就提前收工 */
    const val EARLY_SECONDS = 6

    /** 一次采集的结果：pcm 已降到 8k；raw 是设备原生采样率的原始 PCM16LE（网易指纹用） */
    data class Capture(
        val pcm: ByteArray,
        val peakRms: Float,
        val avgRms: Float,
        val sourceRate: Int,
        val raw: ByteArray = ByteArray(0)
    )

    // 48k 优先（绝大多数声卡的混音格式），再依次退；44100 放在 48k 之后是因为 Windows 默认混音器多为 48k
    private val RATE_CANDIDATES = intArrayOf(48000, 44100, 32000, 16000, 8000)

    @Volatile
    private var cancelFlag = false

    /** 取消本次采集（用户点「取消」/切走页面/识别中再点一次麦克风）：采到的内容作废 */
    fun cancel() {
        cancelFlag = true
    }

    private fun formatOf(rate: Int) = AudioFormat(rate.toFloat(), 16, 1, true, false)

    /** 依次尝试候选采样率，返回第一个能真正打开的采集行 */
    private fun openLine(chunk: Int): Pair<TargetDataLine, Int>? {
        for (rate in RATE_CANDIDATES) {
            val fmt = formatOf(rate)
            val info = DataLine.Info(TargetDataLine::class.java, fmt, chunk * 2)
            if (!AudioSystem.isLineSupported(info)) continue
            val line = runCatching { AudioSystem.getLine(info) as TargetDataLine }.getOrNull() ?: continue
            val ok = runCatching { line.open(fmt, chunk * 2); true }.getOrDefault(false)
            if (ok) {
                line.start()
                return line to rate
            }
            runCatching { line.close() }
        }
        return null
    }

    /**
     * @param seconds 本次要听的时长（12/15/20 秒）
     * @param partialAtSeconds 采到这么多秒时回调一次快照（0 = 不要中途快照），给酷狗先问一次
     * @param onPartial 中途快照回调，在 IO 线程触发；实现方不要在这里做阻塞请求
     */
    suspend fun record(
        seconds: Int = DEFAULT_SECONDS,
        partialAtSeconds: Int = 0,
        onPartial: ((ByteArray) -> Unit)? = null,
        onLevel: (Float) -> Unit = {},
        onProgress: (Float) -> Unit = {}
    ): Capture = withContext(Dispatchers.IO) {
        cancelFlag = false
        val targetSeconds = seconds.coerceIn(MIN_SECONDS, MAX_SECONDS)
        val bytesPerSecGuess = 48_000 * 2
        val chunk = maxOf(bytesPerSecGuess / 5, 4096)   // 每次读约 200ms
        val (line, sourceRate) = openLine(chunk)
            ?: throw IllegalStateException("找不到可用的麦克风（或系统「隐私-麦克风」里未允许本应用）")

        val bytesPerSec = sourceRate * 2
        val needBytes = bytesPerSec * targetSeconds
        val partialBytes = if (partialAtSeconds > 0) bytesPerSec * partialAtSeconds else 0
        var partialSent = false
        val out = ByteArrayOutputStream(needBytes)
        val buf = ByteArray(chunk)
        var smooth = 0f
        var peakRms = 0.0
        var sumSq = 0.0
        var sum = 0.0
        var sumCount = 0L
        try {
            while (out.size() < needBytes && !cancelFlag && currentCoroutineContext().isActive) {
                val n = line.read(buf, 0, chunk)
                if (n <= 0) break
                out.write(buf, 0, n)
                // 逐样本（PCM16 小端有符号）累计，用来算这一段的 AC-RMS
                var cSum = 0.0
                var cSumSq = 0.0
                var cCount = 0L
                var i = 0
                while (i + 1 < n) {
                    val lo = buf[i].toInt() and 0xFF
                    val hi = buf[i + 1].toInt()
                    val s = (hi shl 8) or lo
                    cSum += s.toDouble()
                    cSumSq += s.toDouble() * s.toDouble()
                    cCount++
                    i += 2
                }
                if (cCount > 0) {
                    val mean = cSum / cCount
                    val varSum = cSumSq - cCount * mean * mean
                    val rms = sqrt(if (varSum > 0.0) varSum / cCount else 0.0) / 32768.0
                    if (rms > peakRms) peakRms = rms
                    sum += cSum
                    sumSq += cSumSq
                    sumCount += cCount
                    val norm = (rms * 4.0).coerceIn(0.0, 1.0).toFloat()
                    smooth = smooth * 0.7f + norm * 0.3f
                    onLevel(smooth)
                }
                onProgress((out.size().toFloat() / needBytes).coerceIn(0f, 1f))
                if (!partialSent && partialBytes > 0 && out.size() >= partialBytes) {
                    partialSent = true
                    val cb = onPartial
                    if (cb != null) runCatching { cb(to8k(out.toByteArray(), sourceRate)) }
                }
            }
        } finally {
            runCatching { line.stop() }
            runCatching { line.close() }
        }

        val raw = out.toByteArray()
        val pcm = to8k(raw, sourceRate)
        val avgRms = if (sumCount > 0L) {
            val mean = sum / sumCount
            val varSum = sumSq - sumCount * mean * mean
            (sqrt(if (varSum > 0.0) varSum / sumCount else 0.0) / 32768.0).toFloat()
        } else 0f
        Capture(pcm, peakRms.toFloat(), avgRms, sourceRate, raw)
    }

    /** 任意采集率 → 8k：整倍数走多点平均（顺带做了抗混叠的低通），否则线性插值 */
    private fun to8k(src: ByteArray, sourceRate: Int): ByteArray {
        if (sourceRate == SAMPLE_RATE) return src
        if (src.size < 4) return src
        val samples = src.size / 2
        if (sourceRate % SAMPLE_RATE == 0) {
            val factor = sourceRate / SAMPLE_RATE
            val outSamples = samples / factor
            val dst = ByteArray(outSamples * 2)
            for (o in 0 until outSamples) {
                var acc = 0
                val base = o * factor
                for (k in 0 until factor) {
                    val i = (base + k) * 2
                    val lo = src[i].toInt() and 0xFF
                    val hi = src[i + 1].toInt()
                    acc += (hi shl 8) or lo
                }
                val v = acc / factor
                dst[o * 2] = (v and 0xFF).toByte()
                dst[o * 2 + 1] = ((v shr 8) and 0xFF).toByte()
            }
            return dst
        }
        // 非整倍数（44100 / 22050 这类）：线性插值
        val ratio = sourceRate.toDouble() / SAMPLE_RATE.toDouble()
        val outSamples = (samples / ratio).toInt()
        val dst = ByteArray(outSamples * 2)
        for (o in 0 until outSamples) {
            val pos = o * ratio
            val i0 = pos.toInt().coerceIn(0, samples - 1)
            val i1 = (i0 + 1).coerceIn(0, samples - 1)
            val t = pos - i0
            val a = ((src[i0 * 2 + 1].toInt() shl 8) or (src[i0 * 2].toInt() and 0xFF)).toDouble()
            val b = ((src[i1 * 2 + 1].toInt() shl 8) or (src[i1 * 2].toInt() and 0xFF)).toDouble()
            val v = (a * (1.0 - t) + b * t).toInt()
            dst[o * 2] = (v and 0xFF).toByte()
            dst[o * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        return dst
    }
}

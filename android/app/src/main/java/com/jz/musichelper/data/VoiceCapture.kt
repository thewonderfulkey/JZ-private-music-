package com.jz.musichelper.data

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import kotlin.math.sqrt

/**
 * 听歌识曲的麦克风采集。
 *
 * 采样口径严格对齐酷狗识曲接口：最终送识别的一律是 8kHz / 单声道 / 16bit 小端，最多 10 秒。
 * 整段 PCM 只留在内存里（ByteArray），不落盘、不进缓存，识别完即随作用域回收。
 *
 * v2.1.81：建 AudioRecord 失败隔 350ms 再试一次；8k 不被接受时退 16k 采集再抽点。
 *
 * v2.1.82（本版）：用户反馈"另一台手机外放很大声，却一直提示没听到声音"。两处都是这里的问题：
 *  · 之前固定按 8000Hz 直接采。不少机型 HAL 对 8k 这个legacy 采样率只是"接受但不给数据"
 *    （getMinBufferSize 返回正值、read 也返回字节数，但内容几乎全零），于是我们采到一段"合法的静音"。
 *    现在改成**从设备原生采样率采**（48000 → 32000 → 16000 → 8000 依次探测，取第一个真的能建的），
 *    采完再用多点平均降到 8k 送识别——顺带信噪比比"直接 8k"好得多，识别率也受益。
 *  · 之前用 MediaRecorder.AudioSource.MIC，多数 ROM 在这条路上开了降噪/AGC，音乐被削得很厉害；
 *    改用 VOICE_RECOGNITION（系统按"给识别用"处理：关 AGC、弱降噪），失败再退 MIC。
 *
 * 同时把"到底有多响"如实带出去：peakRms 是分段 AC-RMS 的最大值（0..1，满量程），
 * 上层据此判断"真静音"还是"其实有声音"，不再拿平滑后的显示值当判据。
 */
object VoiceCapture {

    const val SAMPLE_RATE = 8000

    // v2.1.84：识曲时长可配置（右上角按钮，持久化）。
    // v2.1.91：接入网易通道后最短必须 12 秒——网易指纹要 12s 窗口，喂 8s 直接 noMatchReason=10。
    // 酷狗那边不挑长度（5/10/15/20 秒实测都返回 5 条），所以档位统一收成 12/15/20。
    const val MAX_SECONDS = 20
    const val MIN_SECONDS = 12
    const val DEFAULT_SECONDS = 12

    /**
     * v2.1.91：拿到足够走酷狗的时长就先问一次酷狗（默认 6 秒），命中就提前收工。
     * 这样"12 秒档"在常见情况下仍是 6~7 秒出结果，只有酷狗没对上才继续录满 12 秒走网易。
     */
    const val EARLY_SECONDS = 6

    /** 一次采集的结果：pcm 已降到 8k；raw 是设备原生采样率的原始 PCM16LE（网易指纹用） */
    data class Capture(
        val pcm: ByteArray,
        val peakRms: Float,
        val avgRms: Float,
        val sourceRate: Int,
        val raw: ByteArray = ByteArray(0)
    )

    private val RATE_CANDIDATES = intArrayOf(48000, 32000, 16000, 8000)
    private val SOURCE_CANDIDATES = intArrayOf(
        MediaRecorder.AudioSource.VOICE_RECOGNITION,
        MediaRecorder.AudioSource.MIC
    )

    @Volatile
    private var cancelFlag = false

    /** 取消本次采集（用户点「取消」/手势返回/识别中再点一次麦克风）：采到的内容作废 */
    fun cancel() {
        cancelFlag = true
    }

    /** 建 AudioRecord：换音源、失败隔 350ms 再试一次（避开上一轮刚释放的占用窗口） */
    private suspend fun open(rate: Int, chunk: Int): AudioRecord? {
        repeat(2) { attempt ->
            for (src in SOURCE_CANDIDATES) {
                val rec = runCatching {
                    AudioRecord(
                        src,
                        rate,
                        AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT,
                        chunk * 2
                    )
                }.getOrNull()
                if (rec != null && rec.state == AudioRecord.STATE_INITIALIZED) return rec
                runCatching { rec?.release() }
            }
            if (attempt == 0) delay(350)
        }
        return null
    }

    /**
     * @param seconds 本次要听的时长（12/15/20 秒；12 是网易通道的最低要求）
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

        // 选设备真的接受的采集率：从高到低探测，取第一个能建缓冲的
        var sourceRate = 0
        var minBuf = 0
        for (r in RATE_CANDIDATES) {
            val b = AudioRecord.getMinBufferSize(
                r, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
            )
            if (b > 0) {
                sourceRate = r
                minBuf = b
                break
            }
        }
        if (sourceRate <= 0 || minBuf <= 0) throw IllegalStateException("当前设备不支持录音")

        val bytesPerSec = sourceRate * 2
        // 每次读约 200ms，够细的响度刷新，也不会因为块太小而频繁唤醒
        val chunk = maxOf(minBuf, bytesPerSec / 5)
        val rec = open(sourceRate, chunk)
            ?: throw IllegalStateException("麦克风被占用或未授权")

        val needBytes = bytesPerSec * targetSeconds
        val partialBytes = if (partialAtSeconds > 0) bytesPerSec * partialAtSeconds else 0
        var partialSent = false
        val out = ByteArrayOutputStream(needBytes)
        val buf = ByteArray(chunk)
        var smooth = 0f
        var peakRms = 0.0
        var sumSq = 0.0          // 全段 AC 方差累计（sum of (s-mean)^2 的近似：sumSq - sum^2/n）
        var sum = 0.0
        var sumCount = 0L
        try {
            rec.startRecording()
            while (out.size() < needBytes && !cancelFlag && currentCoroutineContext().isActive) {
                val n = rec.read(buf, 0, chunk)
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
                    // 显示用：放大到可视区间（正常说话/音乐外放的 RMS 多在 0.02~0.25）
                    val norm = (rms * 4.0).coerceIn(0.0, 1.0).toFloat()
                    smooth = smooth * 0.7f + norm * 0.3f
                    onLevel(smooth)
                }
                onProgress((out.size().toFloat() / needBytes).coerceIn(0f, 1f))
                // v2.1.91：够 EARLY_SECONDS 就先丢一份 8k 快照出去，让酷狗同时开工
                if (!partialSent && partialBytes > 0 && out.size() >= partialBytes) {
                    partialSent = true
                    val cb = onPartial
                    if (cb != null) runCatching { cb(to8k(out.toByteArray(), sourceRate)) }
                }
            }
        } finally {
            runCatching { rec.stop() }
            runCatching { rec.release() }
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
        // 非整倍数（理论上不会走到，兜底）
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

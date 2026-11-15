package com.jz.musichelper.network

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Base64
import kotlin.math.roundToInt

/**
 * 网易识曲的「本地指纹」引擎（Windows 桌面版）。
 *
 * 算法在 afp.wasm 里，端上必须跑一段 JS 胶水（assets/recognizer.html + afp_wasm_b64.js + sandbox.bundle.js）。
 * Android 用 WebView 承载；桌面版把「谁来回跑 JS」抽成 [Host]，默认没有宿主时网易通道自动跳过，
 * 识曲仍然走酷狗通道（页面上不会出现空结果，只是少了一路交叉验证）。
 *
 * 职责边界与 Android 版一模一样：
 *  原生侧只负责 8k/单声道 Float32 PCM → base64 → 交给宿主 → 收回指纹字符串。
 */
object NeteaseFingerprint {

    /** 网易要 12 秒；喂 8 秒会直接 noMatchReason=10 */
    const val WINDOW_SECONDS = 12
    private const val TARGET_RATE = 8000
    private const val READY_TIMEOUT_MS = 8_000L
    private const val ENCODE_TIMEOUT_MS = 15_000L

    /**
     * 脚本宿主：能把 recognizer.html 跑起来并执行 `window.__encode(pcmBase64)`。
     * 实现见 [JsHost]（内嵌 Chromium/WebView 或系统浏览器桥）。
     */
    interface Host {
        val isReady: Boolean
        fun start()
        suspend fun encode(pcm8kFloatB64: String): String?
        fun dispose() {}
    }

    @Volatile
    private var host: Host? = null

    @Volatile
    private var lastError: String = ""

    /** 引擎是否已就绪（未就绪时识曲仍可走酷狗，不阻塞） */
    val isReady: Boolean get() = host?.isReady == true

    fun install(h: Host?) {
        runCatching { host?.dispose() }
        host = h
        lastError = ""
        runCatching { h?.start() }
    }

    /** 识曲页进入时调一次：预热引擎（首次要编译 wasm，约 60~200ms） */
    fun attach() {
        runCatching { host?.start() }
    }

    /**
     * 把一次采集（源采样率 PCM16LE）裁成最后 12 秒 → 降采样到 8k → Float32LE → base64 → 指纹。
     * 引擎未就绪 / 超时 / 回调失败一律返回 null（调用方据此直接跳过网易通道）。
     */
    suspend fun encode(rawPcm: ByteArray, sourceRate: Int): String? {
        val h = host ?: return null
        if (!h.isReady) {
            // 给 wasm 编译留时间（宿主内部是异步 ready）
            withTimeoutOrNull(READY_TIMEOUT_MS) {
                while (!h.isReady) kotlinx.coroutines.delay(80)
            }
            if (!h.isReady) { lastError = "engine-not-ready"; return null }
        }
        val pcmB64 = to8kFloatB64(rawPcm, sourceRate) ?: return null
        return withTimeoutOrNull(ENCODE_TIMEOUT_MS) {
            runCatching { h.encode(pcmB64) }.getOrNull()
        }?.takeIf { it.isNotBlank() }
    }

    /** 最近一次失败原因（仅内部诊断用，不上界面） */
    fun errorText(): String = lastError

    /**
     * 源采样率 PCM16LE → 8k Float32LE 的 base64。
     * 与 aplayer 一致用「抽点」（不是多点平均）：指纹算法要的是原始波形，平均会削掉高频细节。
     */
    private fun to8kFloatB64(src: ByteArray, sourceRate: Int): String? {
        if (src.size < 4 || sourceRate <= 0) return null
        val samples = src.size / 2
        // 只要最后 12 秒：更靠后的那段才是用户刚听到的
        val needSamples = sourceRate * WINDOW_SECONDS
        val startSample = maxOf(0, samples - needSamples)
        val ratio = sourceRate.toDouble() / TARGET_RATE
        val outCount = ((samples - startSample) / ratio).roundToInt()
        if (outCount < TARGET_RATE) return null    // 不足 1 秒，没意义
        val floats = ByteArray(outCount * 4)
        for (o in 0 until outCount) {
            val pos = startSample + (o * ratio).roundToInt()
            val i = (pos * 2).coerceIn(0, src.size - 2)
            val s = ((src[i + 1].toInt() shl 8) or (src[i].toInt() and 0xFF)).toShort()
            val f = s.toFloat() / 32768f
            val bits = java.lang.Float.floatToIntBits(f)
            floats[o * 4] = (bits and 0xFF).toByte()
            floats[o * 4 + 1] = ((bits shr 8) and 0xFF).toByte()
            floats[o * 4 + 2] = ((bits shr 16) and 0xFF).toByte()
            floats[o * 4 + 3] = ((bits shr 24) and 0xFF).toByte()
        }
        return Base64.getEncoder().encodeToString(floats)
    }
}

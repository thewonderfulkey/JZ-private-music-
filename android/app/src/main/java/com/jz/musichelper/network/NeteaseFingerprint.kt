package com.jz.musichelper.network

import android.annotation.SuppressLint
import android.content.Context
import android.util.Base64
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.roundToInt

/**
 * v2.1.91：网易识曲的「本地指纹」引擎。
 *
 * 网易 audio/match 接口本身不要 key，但它只认自家 afp 指纹（实测把 Shazam 签名原样提交会被判
 * noMatchReason=10），所以指纹必须在端上算。算法在 afp.wasm 里，这里用 WebView 承载
 * assets/recognizer.html（afp_wasm_b64.js + sandbox.bundle.js，约 397KB），
 * 原生侧只负责：8k/单声道 Float32 PCM → base64 → evaluateJavascript → 收回指纹字符串。
 *
 * 桌面 Node 用同一套资产实测：指纹生成 60~64ms、长度 4xx~4xxx 字符，接口返回原唱元数据；
 * 这里不做 wasm 编译时序的轮询（Node 下 processor 是 undefined），只依赖 __NCM__ 自身。
 */
object NeteaseFingerprint {

    /** 网易要 12 秒；喂 8 秒会直接 noMatchReason=10 */
    const val WINDOW_SECONDS = 12
    private const val TARGET_RATE = 8000
    private const val READY_TIMEOUT_MS = 6_000L
    private const val ENCODE_TIMEOUT_MS = 15_000L

    @Volatile
    private var view: WebView? = null

    @Volatile
    private var readySignal: CompletableDeferred<Boolean>? = null

    @Volatile
    private var pending: CompletableDeferred<Pair<Boolean, String>>? = null

    @Volatile
    private var engineReady = false

    @Volatile
    private var lastError: String = ""

    /** 给界面用：引擎是否已就绪（未就绪时识曲仍可走酷狗，不阻塞） */
    val isReady: Boolean get() = engineReady

    /**
     * 由识曲页的 AndroidView 调一次：建 WebView、挂 JS 桥、加载 assets 页。
     * 重复调用返回同一个实例（引擎在进程内复用，避免每次识曲都重编译 wasm）。
     */
    @SuppressLint("SetJavaScriptEnabled")
    fun attach(context: Context): WebView {
        view?.let { return it }
        val ctx = context.applicationContext
        val web = WebView(ctx)
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = true
            mediaPlaybackRequiresUserGesture = false
            // 页面在 file:// 下执行，不再放出别的能力
            allowContentAccess = false
            allowFileAccessFromFileURLs = false
            allowUniversalAccessFromFileURLs = false
        }
        web.setBackgroundColor(0)
        web.isVerticalScrollBarEnabled = false
        web.isHorizontalScrollBarEnabled = false
        web.webViewClient = WebViewClient()
        web.addJavascriptInterface(Bridge(), "AndroidBridge")
        readySignal = CompletableDeferred()
        web.loadUrl("file:///android_asset/recognizer.html")
        view = web
        return web
    }

    private class Bridge {
        @JavascriptInterface
        fun onResult(kind: String, payload: String) {
            when (kind) {
                "ready" -> {
                    engineReady = payload == "1"
                    readySignal?.complete(engineReady)
                }
                "ok" -> pending?.complete(true to payload)
                "error" -> {
                    lastError = payload
                    pending?.complete(false to payload)
                }
            }
        }
    }

    /**
     * 把一次采集（源采样率 PCM16LE）裁成最后 12 秒 → 降采样到 8k → Float32LE → base64 → 指纹。
     * 引擎未就绪 / JS 超时 / 回调失败一律返回 null（调用方据此直接跳过网易通道）。
     */
    suspend fun encode(rawPcm: ByteArray, sourceRate: Int): String? {
        val web = view ?: return null
        val ready = engineReady || withTimeoutOrNull(READY_TIMEOUT_MS) {
            readySignal?.await() ?: false
        } ?: false
        if (!ready) return null

        val pcmB64 = to8kFloatB64(rawPcm, sourceRate) ?: return null
        val signal = CompletableDeferred<Pair<Boolean, String>>()
        pending = signal
        withContext(Dispatchers.Main) {
            web.evaluateJavascript("window.__encode('$pcmB64')", null)
        }
        val result = withTimeoutOrNull(ENCODE_TIMEOUT_MS) { signal.await() } ?: return null
        pending = null
        return if (result.first && result.second.isNotBlank()) result.second else null
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
        return Base64.encodeToString(floats, Base64.NO_WRAP)
    }
}

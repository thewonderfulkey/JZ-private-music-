package com.jz.musichelper.data

import android.content.Context
import com.jz.musichelper.network.ApiClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * v2.1.85 播放缓存（单槽，只缓存"当前正在播的"这一首）。
 *
 * 用户口径：
 *  · 取流器一取到歌，就把这首歌缓存下来；
 *  · 缓存进度在前端播放进度条上渲染（哪一段已经在本地，一眼看得见）；
 *  · 跳转不再等重新搜索、重新取流——已经在本地就直接从本地读；
 *  · 只缓存当前播放的一首，播完 / 切走就释放，不常驻内存。
 *
 * 实现口径（为什么这么做）：
 *  · 落盘不落内存：整首音频写进 `cacheDir/play_cache/cur_<key>.audio`，内存里只有进度与路径两个值，
 *    不会因为缓存把一首 30MB 的歌压在堆上（"不要占用内存"这条按磁盘实现）；
 *  · 单槽：attach() 换歌时先把上一首的文件删掉，进程启动时也清一次残留目录——永远只有一份；
 *  · 播完/切走即删：clear() 取消下载、删文件、把进度归零；上层切歌换源时会自动调用。
 */
object PlayCache {

    /** 缓存状态。frac 就是进度条上要画的那一段（0..1）；localPath 非空表示整首已在本地 */
    data class State(
        val songKey: String? = null,
        val frac: Float = 0f,
        val localPath: String? = null,
        val done: Boolean = false
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null
    private var dir: File? = null

    fun init(context: Context) {
        if (dir != null) return
        val d = File(context.cacheDir, "play_cache")
        runCatching { d.mkdirs() }
        // 上次进程留下的残片一律清掉：只保留"当前正在播的这一首"
        runCatching { d.listFiles()?.forEach { it.delete() } }
        dir = d
    }

    /**
     * 取到流就挂上。已经是本地文件（file:// 或绝对路径）时不用再缓存，直接返回。
     * 同一首歌重复调用（换源重试）不重复下载。
     */
    fun attach(songKey: String, url: String) {
        if (url.startsWith("/") || url.startsWith("file://")) return
        if (_state.value.songKey == songKey && job?.isActive == true) return
        val d = dir ?: return
        // 换歌：先把上一首的残留删干净
        clear()
        val target = File(d, "cur_" + kotlin.math.abs(songKey.hashCode()) + ".audio")
        _state.value = State(songKey = songKey)
        job = scope.launch {
            val complete = runCatching { download(url, target) }.getOrNull() ?: false
            if (!isActive) return@launch
            if (complete && target.length() > 0) {
                _state.value = State(songKey = songKey, frac = 1f, localPath = target.absolutePath, done = true)
            } else {
                // 没下全（断流/服务端不给长度）：只保留已落盘进度，不把它当成本地可播文件
                runCatching { target.delete() }
                _state.value = _state.value.copy(frac = 0f, localPath = null, done = false)
            }
        }
    }

    /**
     * 释放：取消下载、删文件、进度归零。
     * 播放层若正拿着这个文件（Linux 下删除已打开的文件安全，句柄仍可读完），不会打断当前播放。
     */
    fun clear() {
        job?.cancel()
        job = null
        _state.value.localPath?.let { runCatching { File(it).delete() } }
        _state.value = State()
        dir?.listFiles()?.forEach { f -> runCatching { f.delete() } }
    }

    /** 整首下载；返回是否"长度对得上"（服务端不给 Content-Length 时按读到 EOF 视为完成） */
    private fun download(url: String, target: File): Boolean {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout = 20_000
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", ApiClient.MOBILE_UA)
            setRequestProperty("Referer", "https://music.qq.com/")
        }
        var total = -1L
        var read = 0L
        try {
            conn.connect()
            total = conn.contentLengthLong
            conn.inputStream.use { ins ->
                FileOutputStream(target).use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = ins.read(buf)
                        if (n <= 0) break
                        out.write(buf, 0, n)
                        read += n
                        if (total > 0) {
                            val f = (read.toFloat() / total.toFloat()).coerceIn(0f, 1f)
                            // 只动 frac，不动 localPath：整首下完才可切本地
                            if (_state.value.songKey != null) _state.value = _state.value.copy(frac = f)
                        }
                    }
                }
            }
        } finally {
            runCatching { conn.disconnect() }
        }
        return if (total > 0) read >= total else read > 0
    }
}

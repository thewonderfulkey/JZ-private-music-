package com.jz.musichelper.data

import com.jz.musichelper.network.ApiClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File

/**
 * v2.1.71：后台连播用的"下一首本地缓存"（多槽滚动）。
 *
 * 实测确认：加了电池优化白名单后，息屏/后台播完能正常切歌；不加白名单时，系统（Doze / 厂商省电策略）
 * 会冻结应用的后台联网，取下一首的流直接超时——表现就是"明明连着 WiFi，退出前台就不切"。
 *
 * 所以这里做一层兜底：前台有网时，把队列里接下来的几首都下到本地缓存；后台即使一点网都取不到，
 * 也能按缓存继续往下唱若干首。缓存按歌曲 key 分槽保存，命中即用，总槽数有上限、超出按最旧的淘汰，
 * 不累积占空间。
 */
object NextTrackCache {

    private const val MAX_BYTES = 120L * 1024 * 1024   // 单曲上限，超了不预取
    private const val MAX_SLOTS = 4                    // 最多留 4 首（含正在听的下一首若干）

    private var dir: File? = null

    fun init() {
        runCatching {
            dir = File(AppEnv.cacheDir, "prefetch").apply { mkdirs() }
        }
    }

    private fun slot(key: String): File? = dir?.let { File(it, safe(key) + ".bin") }

    private fun safe(key: String): String =
        key.replace(Regex("[^A-Za-z0-9]"), "_").take(64)

    /** 命中的本地路径（文件存在且非空），未命中返回 null */
    fun match(key: String): String? = runCatching {
        val f = slot(key) ?: return null
        if (!f.exists() || f.length() <= 2048L) return null
        f.absolutePath
    }.getOrNull()

    /** 已缓存的总大小（字节），用于设置页展示/自检 */
    fun cachedBytes(): Long = runCatching {
        dir?.listFiles()?.filter { it.isFile }?.sumOf { it.length() } ?: 0L
    }.getOrDefault(0L)

    fun clear() {
        runCatching { dir?.listFiles()?.forEach { if (it.isFile) it.delete() } }
    }

    /** 下载整首到缓存，成功返回本地路径。失败静默（不影响正常取流播放） */
    suspend fun download(url: String, key: String): String? = withContext(Dispatchers.IO) {
        runCatching {
            val f = slot(key) ?: return@runCatching null
            if (!url.startsWith("http")) return@runCatching null
            val tmp = File(f.parentFile, f.name + ".tmp")
            val req = Request.Builder().url(url)
                .header("User-Agent", ApiClient.MOBILE_UA)
                .header("Referer", "https://music.qq.com/")
                .build()
            ApiClient.client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@runCatching null
                val type = resp.body?.contentType()?.toString() ?: ""
                if (type.contains("text") || type.contains("json")) return@runCatching null
                val len = resp.body?.contentLength() ?: -1L
                if (len > MAX_BYTES) return@runCatching null
                resp.body?.byteStream()?.use { input ->
                    tmp.outputStream().use { out -> input.copyTo(out, 8192) }
                }
            }
            if (tmp.length() <= 2048L || tmp.length() > MAX_BYTES) {
                tmp.delete()
                return@runCatching null
            }
            f.delete()
            if (!tmp.renameTo(f)) {
                tmp.copyTo(f, overwrite = true)
                tmp.delete()
            }
            prune()
            f.absolutePath
        }.getOrNull()
    }

    /** 超出槽位上限时，按最后写入时间淘汰最旧的缓存 */
    private fun prune() {
        runCatching {
            val files = dir?.listFiles()?.filter { it.isFile && !it.name.endsWith(".tmp") } ?: return
            if (files.size <= MAX_SLOTS) return
            files.sortedBy { it.lastModified() }
                .take(files.size - MAX_SLOTS)
                .forEach { it.delete() }
        }
    }
}

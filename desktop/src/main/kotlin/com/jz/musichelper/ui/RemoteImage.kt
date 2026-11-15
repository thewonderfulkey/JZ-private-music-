package com.jz.musichelper.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import com.jz.musichelper.network.ApiClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.Request

/**
 * 封面加载器：Coil 的桌面替代品。
 *
 * 必须自己拿到**像素**（VinylDetector 要按四角/圆心颜色判定酷狗软失败黑胶图），
 * 所以走「OkHttp 取字节 → Skia 解码 → ImageBitmap」这条路，比引入 Coil3 的多平台 API 更直接。
 * 内存里做一层 LRU，列表来回滚动不重复下载。
 */
object CoverLoader {

    private const val MAX_ENTRIES = 160
    private val cache = object : LinkedHashMap<String, ImageBitmap>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ImageBitmap>?): Boolean =
            size > MAX_ENTRIES
    }

    suspend fun load(url: String, timeoutMs: Long = 12_000L): ImageBitmap? {
        synchronized(cache) { cache[url] }?.let { return it }
        val bmp = withTimeoutOrNull(timeoutMs) {
            withContext(Dispatchers.IO) {
                runCatching {
                    val req = Request.Builder()
                        .url(url)
                        .header("User-Agent", ApiClient.MOBILE_UA)
                        .header("Referer", "https://music.qq.com/")
                        .build()
                    ApiClient.client.newCall(req).execute().use { resp ->
                        if (!resp.isSuccessful) return@use null
                        val bytes = resp.body?.bytes() ?: return@use null
                        if (bytes.size < 64) return@use null
                        org.jetbrains.skia.Image.makeFromEncoded(bytes).toComposeImageBitmap()
                    }
                }.getOrNull()
            }
        }
        if (bmp != null) synchronized(cache) { cache[url] = bmp }
        return bmp
    }
}

/**
 * 三态封面：loading / error / success(bitmap)。
 * 与 Coil 的 SubcomposeAsyncImage 用法对齐，调用处只换控件名，其余逻辑（兜底、淡入）原样保留。
 */
@Composable
fun CoverImage(
    url: String,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    loading: @Composable () -> Unit = {},
    error: @Composable () -> Unit = {},
    success: @Composable (ImageBitmap) -> Unit
) {
    var state by remember(url) { mutableStateOf<Any?>(null) }   // null=loading, Throwable=error, ImageBitmap=ok
    LaunchedEffect(url) {
        state = null
        val bmp = CoverLoader.load(url)
        state = bmp ?: IllegalStateException("cover load failed")
    }
    when (val s = state) {
        is ImageBitmap -> success(s)
        is Throwable -> error()
        else -> loading()
    }
}

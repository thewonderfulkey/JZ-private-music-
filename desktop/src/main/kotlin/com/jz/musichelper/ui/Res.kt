package com.jz.musichelper.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.graphics.painter.ColorPainter
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.toComposeImageBitmap
import java.util.concurrent.ConcurrentHashMap

/**
 * 资源访问：Android 用 `R.drawable.xxx` + 资源系统，桌面版直接读 classpath 下的同名文件。
 *
 * 打包后资源在 jar 里（jpackage 的 app-image 也一样），所以用 classLoader 读流；
 * 解码结果按名字缓存——同一张底图被几十个列表项引用时不会反复解码。
 */
object Res {

    private val cache = ConcurrentHashMap<String, ImageBitmap>()

    /**
     * @param name classpath 路径，例如 `drawable/ink_bg_player.jpg`
     *
     * 注意：这里**不能**用 `getOrPut`。Kotlin 的 `getOrPut` 在 value 为 null 时会执行
     * `putIfAbsent(key, null)`，ConcurrentHashMap 直接抛 NPE；而这个方法是在 Compose 组合里
     * 被调用的，异常会把整个 composition 干掉、进程静默退出（打包版最难查的那类"点一下就没了"）。
     */
    fun image(name: String): ImageBitmap? {
        cache[name]?.let { return it }
        val bmp = runCatching {
            val bytes = Res::class.java.classLoader?.getResourceAsStream(name)?.use { it.readBytes() }
                ?: return@runCatching null
            org.jetbrains.skia.Image.makeFromEncoded(bytes).toComposeImageBitmap()
        }.getOrNull() ?: return null
        cache[name] = bmp
        return bmp
    }
}

/** `painterResource(R.drawable.xxx)` 的桌面等价物 */
@Composable
fun painterRes(name: String): Painter {
    val bmp = remember(name) { Res.image(name) }
    return remember(name, bmp) {
        if (bmp != null) BitmapPainter(bmp)
        else ColorPainter(Color.Transparent)
    }
}

package com.jz.musichelper.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect

/**
 * 返回手势/返回键的桌面等价物。
 *
 * Android 用 `BackHandler` 接管系统返回键（播放页 → 歌单页 → 主界面 → 退出）；
 * Windows 上没有返回键，这里把同一个"层级回退"语义挂到 Esc 上——
 * 由 Main.kt 的窗口 `onPreviewKeyEvent` 转发进来。
 */
object BackDispatcher {

    /** 当前页面的回退处理器；返回 true 表示已消费（不该继续退出窗口） */
    @Volatile
    private var handler: (() -> Unit)? = null

    fun install(h: (() -> Unit)?) {
        handler = h
    }

    fun hasHandler(): Boolean = handler != null

    /** @return true = 已处理（Esc 被吃掉） */
    fun handle(): Boolean {
        val h = handler ?: return false
        h()
        return true
    }
}

@Composable
fun BackHandler(enabled: Boolean = true, onBack: () -> Unit) {
    DisposableEffect(enabled, onBack) {
        BackDispatcher.install(if (enabled) onBack else null)
        onDispose { BackDispatcher.install(null) }
    }
}

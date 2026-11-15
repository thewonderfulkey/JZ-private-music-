package com.jz.musichelper.ui

import java.awt.Window

/** 主窗口引用（悬浮窗需要 owner，否则 AWT 的可显示窗口计数会出错） */
object AppWindow {
    @Volatile
    var frame: Window? = null
}

package com.jz.musichelper.data

/**
 * Android 侧的媒体前台服务（mediaPlayback + WakeLock + 常驻通知）在 Windows 桌面没有对应物：
 * 桌面进程只要窗口/后台线程活着就一直跑，不存在息屏冻结、Doze 省电、后台启动限制这些问题。
 *
 * 这里保留同名同签名的空实现，让上层（PlayerManager / 播放页）的调用点与 Android 版保持一致，
 * 将来若要做「最小化到托盘继续播」也能直接在这里挂 Tray。
 */
object PlayerService {

    /** 桌面版无操作：进程本身常驻 */
    fun start() {}

    /** 桌面版无操作：Android 用它刷新通知栏歌名 */
    fun refresh() {}
}

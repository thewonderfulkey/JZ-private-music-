package com.jz.musichelper.data

import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * 单实例 + 二次启动唤醒。
 *
 * 第一个实例在 127.0.0.1 的固定端口上监听；之后双击 exe 的进程连上去发一句 `SHOW`，
 * 第一个实例就把主窗口显示出来（从托盘恢复），第二个进程直接退出。
 *
 * 这样"关窗收进托盘"之后，用户再点桌面图标不会看到"已经在运行"的死弹窗，
 * 而是老老实实把窗口叫回来——和网易云/酷狗的行为一致。
 */
object SingleInstance {

    private const val PORT = 51823
    private const val CMD_SHOW = "SHOW"

    private var server: ServerSocket? = null

    /** 抢主实例；抢不到说明已经有实例在跑（会顺手让它显示窗口） */
    fun tryAcquire(): Boolean {
        return try {
            server = ServerSocket(PORT, 4, InetAddress.getLoopbackAddress())
            true
        } catch (_: Exception) {
            false
        }
    }

    /** 通知已在运行的实例把窗口显示出来 */
    fun askExistingToShow() {
        runCatching {
            Socket(InetAddress.getLoopbackAddress(), PORT).use { s ->
                PrintWriter(s.getOutputStream(), true).println(CMD_SHOW)
            }
        }
    }

    /** 在主实例里启动监听；收到 SHOW 就回调（回调里自己切到 EDT） */
    fun startServer(onShow: () -> Unit) {
        val s = server ?: return
        thread(isDaemon = true, name = "jz-single-instance") {
            while (!s.isClosed) {
                val client = runCatching { s.accept() }.getOrNull() ?: break
                thread(isDaemon = true) {
                    runCatching {
                        val cmd = BufferedReader(InputStreamReader(client.getInputStream())).readLine()
                        if (cmd?.trim() == CMD_SHOW) onShow()
                    }
                    runCatching { client.close() }
                }
            }
        }
    }

    fun release() {
        runCatching { server?.close() }
        server = null
    }
}

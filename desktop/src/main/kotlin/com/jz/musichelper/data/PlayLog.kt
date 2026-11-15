package com.jz.musichelper.data

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 播放链路诊断日志（与 Android 版同口径）：写入 `<项目根>/logs/play.log`（不再放 C 盘），
 * 只保留最近约 200KB；设置页「异常诊断」里展示末几行。
 * 全程 runCatching，日志失败绝不影响播放。
 */
object PlayLog {

    private var file: File? = null
    private val fmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    fun init() {
        runCatching {
            file = File(AppEnv.logsDir, "play.log")
            val f = file ?: return
            if (f.exists() && f.length() > 200_000L) {
                val lines = f.readLines()
                f.writeText(lines.takeLast(400).joinToString("\n") + "\n")
            }
        }
    }

    fun log(msg: String) {
        runCatching { JzLog.i("JZPlay", msg) }
        runCatching {
            val f = file ?: return
            f.appendText(fmt.format(Date()) + " " + msg + "\n")
        }
    }

    /** 设置页展示用：最近 n 行 */
    fun tail(n: Int = 12): String = runCatching {
        val f = file ?: return ""
        if (!f.exists()) return ""
        f.readLines().takeLast(n).joinToString("\n")
    }.getOrDefault("")
}

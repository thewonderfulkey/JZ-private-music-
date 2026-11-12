package com.jz.musichelper.data

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * v2.1.68：播放链路诊断日志（息屏连播问题只能靠真机日志定位，本机没有可复现设备）。
 * 写入 filesDir/play.log，只保留最近约 200KB；设置页「异常诊断」里展示末几行，用户截图即可。
 * 全程 runCatching，日志失败绝不影响播放。
 */
object PlayLog {

    private var file: File? = null
    private val fmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    fun init(context: Context) {
        runCatching {
            file = File(context.applicationContext.filesDir, "play.log")
            val f = file ?: return
            if (f.exists() && f.length() > 200_000L) {
                val lines = f.readLines()
                f.writeText(lines.takeLast(400).joinToString("\n") + "\n")
            }
        }
    }

    fun log(msg: String) {
        runCatching { Log.i("JZPlay", msg) }
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

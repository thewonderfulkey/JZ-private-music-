package com.jz.musichelper.network

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/**
 * 出网探测。
 *
 * Android 侧还负责查询「屏幕是否亮 / 是否进 Doze / 是否电池白名单」——这三项在 Windows 桌面上
 * 恒为「可用」：进程不会被系统冻结，网络也不会因锁屏被掐断。保留同名方法让上层诊断代码不用改。
 */
object NetworkProbe {

    fun init() {
        // 桌面版不需要持有 Context
    }

    /** 桌面始终有"系统网络"概念（真实是否通由 isReachable 判断） */
    fun hasNetwork(): Boolean = true

    /** 真实出网：3s 超时，拿到任何 HTTP 响应都算通；连接失败/超时算不通。必须跑在 IO 线程 */
    suspend fun isReachable(): Boolean = withContext(Dispatchers.IO) {
        runCatching {
            val c = ApiClient.client.newBuilder()
                .connectTimeout(3, TimeUnit.SECONDS)
                .readTimeout(3, TimeUnit.SECONDS)
                .build()
            val req = okhttp3.Request.Builder()
                .url("https://music.163.com/")
                .header("User-Agent", ApiClient.MOBILE_UA)
                .head()
                .build()
            c.newCall(req).execute().use { true }
        }.getOrDefault(false)
    }

    /** 桌面没有"息屏"概念 */
    fun isInteractive(): Boolean = true

    fun isDeviceIdle(): Boolean = false

    fun isIgnoringBattery(): Boolean = true

    /** 一行诊断：screen=1/0 idle=1/0 batteryWhitelist=1/0 */
    fun state(): String = "screen=${if (isInteractive()) 1 else 0} idle=${if (isDeviceIdle()) 1 else 0} " +
        "wl=${if (isIgnoringBattery()) 1 else 0}"
}

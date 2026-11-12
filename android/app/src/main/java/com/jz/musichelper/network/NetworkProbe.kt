package com.jz.musichelper.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.PowerManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/**
 * v2.1.68：出网探测。息屏 / Doze 下系统可能掐掉后台网络，
 * 此时取流失败并不等于"这首歌没源"，不能拿它去消耗自动跳过额度。
 *
 * v2.1.69：两处修正。
 *  ① isReachable 改为 suspend + Dispatchers.IO——v2.1.68 里它是阻塞调用，却被
 *     自动连播的协程（Dispatchers.Main）直接调用，网络不通时一次卡主线程 6 秒，
 *     每 4 秒一次，主线程近乎被打死，播完回调和取流编排都排不上队，表现就是"卡住"。
 *  ② 补上屏幕 / Doze / 电池白名单三个系统状态的查询，用于把"网络被限流"和
 *     "CPU 进 Doze 根本没被唤醒"区分开，日志里直接能看出是哪一层。
 */
object NetworkProbe {

    private lateinit var appCtx: Context

    fun init(ctx: Context) {
        appCtx = ctx.applicationContext
    }

    /** 系统侧是否有网络（Doze 限流时仍可能为 true，只作粗判） */
    fun hasNetwork(ctx: Context): Boolean = runCatching {
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        val n = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(n) ?: return false
        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }.getOrDefault(false)

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

    /** 屏幕是否亮着（false = 息屏） */
    fun isInteractive(): Boolean = runCatching {
        (appCtx.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.isInteractive ?: true
    }.getOrDefault(true)

    /** 是否已进入 Doze / 深度待机（此时系统会忽略 wakelock、冻结后台网络） */
    fun isDeviceIdle(): Boolean = runCatching {
        (appCtx.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.isDeviceIdleMode ?: false
    }.getOrDefault(false)

    /** 是否已被用户放行电池优化（Doze 网络限制对白名单内应用不生效） */
    fun isIgnoringBattery(): Boolean = runCatching {
        (appCtx.getSystemService(Context.POWER_SERVICE) as? PowerManager)
            ?.isIgnoringBatteryOptimizations(appCtx.packageName) ?: false
    }.getOrDefault(false)

    /** 一行诊断：screen=1/0 idle=1/0 batteryWhitelist=1/0 */
    fun state(): String = "screen=${if (isInteractive()) 1 else 0} idle=${if (isDeviceIdle()) 1 else 0} " +
        "wl=${if (isIgnoringBattery()) 1 else 0}"
}

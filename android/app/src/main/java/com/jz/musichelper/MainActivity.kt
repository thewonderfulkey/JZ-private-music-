package com.jz.musichelper

import android.content.SharedPreferences
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.jz.musichelper.data.DownloadManager
import com.jz.musichelper.data.PlayerManager
import com.jz.musichelper.ui.App
import java.io.File
import java.util.Date

class MainActivity : ComponentActivity() {

    private val screenOnReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: android.content.Intent?) {
            com.jz.musichelper.ui.AppState.onScreenOn()
        }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(screenOnReceiver) }
        super.onDestroy()
    }

    // v2.1.74：桌面歌词只在 App 不在前台时出现（回到桌面/切到别的应用才显示）。
    // 用 Activity 生命周期而不是 Compose 组合状态来驱动——息屏/后台时组合可能不再重组，会漏掉切换。
    override fun onResume() {
        super.onResume()
        com.jz.musichelper.data.DesktopLyrics.setAppVisible(true)
        com.jz.musichelper.data.DesktopLyrics.onResume()
    }

    override fun onPause() {
        com.jz.musichelper.data.DesktopLyrics.setAppVisible(false)
        super.onPause()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 全局兜底：任何未预期异常写入 crash.log 与偏好（设置页可查诊断），不弹窗、不杀进程
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val f = File(filesDir, "crash.log")
                f.appendText("===== ${Date()} [${thread.name}] =====\n$throwable\n")
                throwable.stackTrace?.forEach { f.appendText("    at $it\n") }
                f.appendText("\n")
                // 同步到偏好，供设置页"异常诊断"直接展示
                val stack = throwable.stackTrace?.take(10)?.joinToString("\n") { "    at $it" } ?: ""
                getSharedPreferences("jz_music_prefs", MODE_PRIVATE)
                    .edit()
                    .putString("last_error", "$throwable\n$stack")
                    .putLong("last_error_time", System.currentTimeMillis())
                    .apply()
            } catch (_: Exception) {
            }
        }
        DownloadManager.init(this)
        PlayerManager.init(this)
        com.jz.musichelper.data.PlayLog.init(this)
        com.jz.musichelper.network.NetworkProbe.init(this)
        com.jz.musichelper.data.NextTrackCache.init(this)
        // v2.1.85：播放缓存（单槽，只存当前这一首）——启动时清掉上次残留，避免磁盘越攒越多
        com.jz.musichelper.data.PlayCache.init(this)
        // v2.1.74：桌面歌词（悬浮窗）初始化——读开关偏好、复查悬浮窗权限、注册转屏回调
        com.jz.musichelper.data.DesktopLyrics.init(this)
        // v2.1.67：自动连播/换源监听挂到应用级（不依赖 Compose 组合与屏幕帧），息屏后照常切歌
        com.jz.musichelper.ui.AppState.startAutoContinue()
        // v2.1.68：亮屏/解锁兜底——息屏时没取到下一首的，回到界面立刻重试续播（并作废排着的自动跳歌）
        runCatching {
            val filter = android.content.IntentFilter().apply {
                addAction(android.content.Intent.ACTION_SCREEN_ON)
                addAction(android.content.Intent.ACTION_USER_PRESENT)
            }
            androidx.core.content.ContextCompat.registerReceiver(
                this,
                screenOnReceiver,
                filter,
                androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED
            )
        }
        // v2.1.5 #5：Android 13+ 请求通知权限（前台服务常驻通知需要；拒绝不影响播放与连播保活）
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            runCatching { requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 100) }
        }
        enableEdgeToEdge()
        setContent {
            App()
        }
        // v2.1.71：装好第一次打开就自动向系统申请「不受电池优化限制」——
        // 这是"息屏/后台能继续联网取歌"的系统级开关，不申请的话 Doze 会冻结后台网络。
        window.decorView.post { ensureBatteryWhitelist() }
        // v2.1.93：冒烟包专用入口——用 assets/fixtures 里的固定 PCM 走一遍识曲，
        // 供模拟器自动化断言。RECOG_TEST_HOOK 是编译期常量（release=false），
        // 正式包里这段分支会被编译器去掉。
        if (BuildConfig.RECOG_TEST_HOOK) {
            // v2.1.94：搜索注入——冒烟里验证"四个平台各返回多少条"（中文没法用 adb input 输）
            val searchKw = intent?.getStringExtra("jz_test_search")
            if (!searchKw.isNullOrBlank()) {
                window.decorView.postDelayed({
                    com.jz.musichelper.ui.AppState.searchForTest(searchKw)
                }, 400)
            }
            val fixture = intent?.getStringExtra("jz_test_pcm")
            if (!fixture.isNullOrBlank()) {
                window.decorView.postDelayed({
                    com.jz.musichelper.ui.AppState.startRecognizeWithFixture(applicationContext, fixture)
                }, 600)
            }
        }
    }

    /**
     * v2.1.71：自动申请电池优化豁免（全自动，用户只需在系统弹框上点一次「允许」）。
     * 已放行则什么都不做；最多自动弹 3 次，避免反复打扰。
     */
    private fun ensureBatteryWhitelist() {
        runCatching {
            val pm = getSystemService(android.os.PowerManager::class.java) ?: return
            if (pm.isIgnoringBatteryOptimizations(packageName)) return
            val prefs = getSharedPreferences("jz_music_prefs", MODE_PRIVATE)
            val asked = prefs.getInt("bo_asked", 0)
            if (asked >= 3) return
            prefs.edit().putInt("bo_asked", asked + 1).apply()
            startActivity(
                android.content.Intent(
                    android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    android.net.Uri.parse("package:$packageName")
                ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }
}

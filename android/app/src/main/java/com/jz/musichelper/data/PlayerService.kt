package com.jz.musichelper.data

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.jz.musichelper.MainActivity
import com.jz.musichelper.R
import com.jz.musichelper.ui.AppState

/**
 * v2.1.5 #5：媒体播放前台服务。
 * 修复"后台息屏后一首歌播完不自动连播、直到打开 App 才加载"：
 * 播放期间保持进程为前台（mediaPlayback 类型 + 常驻通知），息屏/Doze 下
 * MediaPlayer 完成回调、自动连播的解析协程与网络请求不会被系统冻结/挂起。
 * 服务随首次播放启动、随进程终止结束（暂停不停止，保证后台连播链路完整）。
 */
class PlayerService : Service() {

    // v2.1.67：服务存活期间的 CPU 保活锁（息屏后自动连播用）
    private var wakeLock: android.os.PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        instance = this
        startAsForeground()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        releaseWakeLock()
        if (instance === this) instance = null
    }

    /**
     * v2.1.67：息屏自动连播修复的保活一半。
     * 前台服务只保证进程不被回收、音乐不被冻结；但息屏 + Doze 下 CPU 仍会休眠，
     * 一首歌播完（音频流停止、音频层的 wakelock 随之释放）到下一首取流完成之间，
     * MediaPlayer 回调、协程、网络请求全部停摆——表现就是"息屏后播完不切歌，亮屏一看才恢复"。
     * 服务存活期间持有一把 PARTIAL_WAKE_LOCK（不亮屏、只保 CPU），服务销毁即释放。
     */
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        runCatching {
            val pm = getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager ?: return
            wakeLock = pm.newWakeLock(
                android.os.PowerManager.PARTIAL_WAKE_LOCK,
                "JZMusicHelper:playback"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseWakeLock() {
        runCatching { if (wakeLock?.isHeld == true) wakeLock?.release() }
        wakeLock = null
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "播放服务", NotificationManager.IMPORTANCE_LOW).apply {
                    setShowBadge(false)
                }
            )
        }
    }

    private fun startAsForeground() {
        acquireWakeLock()
        val id = NOTIFICATION_ID
        if (Build.VERSION.SDK_INT >= 29) {
            val type = if (Build.VERSION.SDK_INT >= 34) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            } else {
                0
            }
            startForeground(id, buildNotification(), type)
        } else {
            startForeground(id, buildNotification())
        }
    }

    /** 切歌后由 PlayerManager 刷新通知文案（服务常驻时 onStartCommand 也会刷新） */
    fun refreshNotification() {
        runCatching { getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification()) }
    }

    private fun buildNotification(): Notification {
        val song = AppState.lastSong.value
        val title = song?.name ?: "JZ的音乐助手"
        val text = song?.let { it.singer + " · " + it.platform.shortName } ?: "正在播放"
        val pi = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply { flags = Intent.FLAG_ACTIVITY_SINGLE_TOP },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pi)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "jz_music_playback"
        private const val NOTIFICATION_ID = 1001

        @Volatile
        private var instance: PlayerService? = null

        /** 播放时启动前台服务（App 前台调用；服务已运行时仅回调 onStartCommand 刷新通知） */
        fun start(context: Context) {
            runCatching { context.startForegroundService(Intent(context, PlayerService::class.java)) }
        }

        /** 刷新通知文案（切换歌曲后调用） */
        fun refresh(context: Context) {
            instance?.refreshNotification()
        }
    }
}

package com.jz.musichelper.data

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.jz.musichelper.ui.AppState

/**
 * v2.1.69：曲终闹铃。
 *
 * 息屏后系统进入 Doze 时会忽略 wakelock、冻结后台，MediaPlayer 的播完回调可能根本送不到——
 * 音频在音频硬件里放完了，回调要 CPU 醒着才投递，用户看到的就是"卡在上一首、一直不切"。
 * 这里在每首歌开始播放时，按剩余时长排一个"到点唤醒"的闹铃（Doze 下闹铃仍会被投递），
 * 到点由接收器核对进度：确实到底了就直接推进下一首，不再等那个可能永远不来的回调。
 * 播放/切歌/停止都会重排或取消，避免旧闹铃误触。
 */
object TrackEndAlarm {

    private const val REQ = 20261
    private const val ACTION = "com.jz.musichelper.TRACK_END"

    fun schedule(ctx: Context, remainingMs: Long) {
        runCatching {
            val am = ctx.getSystemService(AlarmManager::class.java) ?: return
            val pi = pending(ctx)
            val at = System.currentTimeMillis() + remainingMs.coerceAtLeast(5_000L)
            if (Build.VERSION.SDK_INT >= 31 && am.canScheduleExactAlarms()) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            }
            PlayLog.log("alarm set in=${remainingMs}ms exact=${Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()}")
        }
    }

    fun cancel(ctx: Context) {
        runCatching {
            ctx.getSystemService(AlarmManager::class.java)?.cancel(pending(ctx))
        }
    }

    private fun pending(ctx: Context): PendingIntent = PendingIntent.getBroadcast(
        ctx, REQ,
        Intent(ctx, TrackEndReceiver::class.java).setAction(ACTION),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )
}

class TrackEndReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        // 闹铃可能把已回收的进程重新拉起：这里补一次初始化，避免日志/探测拿到未初始化的上下文
        runCatching { context?.let { PlayLog.init(it); com.jz.musichelper.network.NetworkProbe.init(it) } }
        PlayLog.log("ALARM fire")
        AppState.onTrackEndAlarm()
    }
}

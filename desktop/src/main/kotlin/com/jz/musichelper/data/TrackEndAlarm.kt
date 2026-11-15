package com.jz.musichelper.data

/**
 * Android 的「曲终闹铃」（AlarmManager + 广播接收器）用于 Doze 下把 CPU 叫醒推进下一首。
 *
 * Windows 桌面没有 Doze：解码线程一直在跑，曲终直接走 PlayerManager.completed，
 * 不存在"回调送不到、卡在上一首"的问题。所以这里保留空实现，仅作为调用契约。
 */
object TrackEndAlarm {

    fun schedule(remainingMs: Long) {
        // no-op：桌面端不需要到点唤醒
    }

    fun cancel() {
        // no-op
    }
}

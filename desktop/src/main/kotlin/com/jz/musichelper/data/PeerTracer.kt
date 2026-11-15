package com.jz.musichelper.data

import java.awt.Window
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * 诊断：观察 `sun.awt.AWTAutoShutdown` 的 peerMap。
 *
 * 只要桌面歌词窗口"开始承载内容"，约 5 秒后 JVM 就会在 EDT 上走 System.exit。
 * AWTAutoShutdown 在 peerMap 为空时关掉 toolkit 并让进程退出，所以这里持续打印
 * peerMap 内容，确认主窗口是否被错误移出集合。
 *
 * 仅 `JZ_PEER_TRACE=1` 时启用，需要 JVM 参数 `--add-opens=java.desktop/sun.awt=ALL-UNNAMED`。
 */
object PeerTracer {

    private val started = AtomicBoolean(false)
    private var lastSig = ""

    fun startIfEnabled() {
        if (System.getenv("JZ_PEER_TRACE") != "1") return
        if (!started.compareAndSet(false, true)) return
        runCatching {
            JzLog.i("JZ_PEER", "tracer start, initial=${snapshot()}")
            thread(isDaemon = true, name = "jz-peer-trace") {
                while (true) {
                    runCatching {
                        val s = snapshot()
                        if (s != lastSig) {
                            lastSig = s
                            JzLog.i("JZ_PEER", "peerMap :: $s")
                        }
                    }
                    Thread.sleep(300)
                }
            }
        }.onFailure { JzLog.w("JZ_PEER", "tracer failed: ${it.message}") }
    }

    private fun snapshot(): String {
        return runCatching {
            val cls = Class.forName("sun.awt.AWTAutoShutdown")
            val inst = cls.getDeclaredMethod("getInstance").invoke(null)
            val field = cls.getDeclaredField("peerMap").apply { isAccessible = true }
            val raw = field.get(inst) as java.util.Map<Any?, Any?>
            val parts = ArrayList<String>()
            synchronized(raw) {
                val it2 = raw.entrySet().iterator()
                while (it2.hasNext()) {
                    val entry = it2.next()
                    parts.add(describePeer(entry.key))
                }
            }
            "n=${parts.size} [" + parts.joinToString(" | ") + "]"
        }.getOrElse { "unavailable: ${it.message}" }
    }

    private fun describePeer(peer: Any?): String {
        if (peer == null) return "null"
        val target = runCatching {
            var c: Class<*>? = peer.javaClass
            var f: java.lang.reflect.Field? = null
            while (c != null && f == null) {
                f = runCatching { c.getDeclaredField("target") }.getOrNull()
                if (f == null) c = c.superclass
            }
            f?.apply { isAccessible = true }?.get(peer)
        }.getOrNull()
        val win = target as? java.awt.Window
        val title = runCatching { (win as? java.awt.Frame)?.title ?: "" }.getOrDefault("")
        val cls = target?.javaClass?.simpleName ?: peer.javaClass.simpleName
        return "$cls['$title',show=${win?.isShowing},disp=${win?.isDisplayable}]"
    }
}

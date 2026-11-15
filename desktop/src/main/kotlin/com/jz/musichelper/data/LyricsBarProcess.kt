package com.jz.musichelper.data

import com.jz.musichelper.model.Song
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.PrintWriter
import kotlin.concurrent.thread

/**
 * 桌面歌词悬浮栏的**子进程管理**。
 *
 * 主进程只负责把"当前句/下一句/逐字时间/播放位置"通过 stdin 推给子进程；
 * 子进程（`JZ Music.exe --lyrics-bar`）自己开窗、画字、拖动、点工具条。
 *
 * 这样一来：歌词窗的 AWT 出任何问题都杀不到播放器（原来的 5 秒退出就是这么没的）。
 */
object LyricsBarProcess {

    private const val TAG = "JZ_LBP"

    private var proc: Process? = null
    private var stdin: PrintWriter? = null
    private var lastSendMs = 0L
    private var lastPayload = ""

    private val _ready = MutableStateFlow(false)
    val ready: StateFlow<Boolean> = _ready

    /** 子进程上报的动作，交给 DesktopLyrics 处理 */
    @Volatile
    var onAction: ((String) -> Unit)? = null

    @Volatile
    var onPosition: ((Int, Int) -> Unit)? = null

    fun isRunning(): Boolean = proc?.isAlive == true

    private val NOCHILD = System.getenv("JZ_LBP_NOCHILD") == "1"

    fun start(theme: Int, font: Int, locked: Boolean, x: Int, y: Int, width: Int) {
        if (NOCHILD) { JzLog.w(TAG, "child spawn disabled (diagnostic)"); return }
        if (isRunning()) return
        val cmd = buildCommand() ?: run {
            JzLog.w(TAG, "找不到可执行的 java/自身 exe，放弃子进程方案")
            return
        }
        runCatching {
            val pb = ProcessBuilder(cmd).redirectErrorStream(false)
            val p = pb.start()
            proc = p
            stdin = PrintWriter(p.getOutputStream(), true)
            JzLog.i(TAG, "child started: ${cmd.joinToString(" ")} pid=${p.pid()}")

            // 读子进程输出（事件）
            thread(isDaemon = true, name = "jz-lbp-reader") {
                BufferedReader(InputStreamReader(p.inputStream)).useLines { lines ->
                    lines.forEach { line ->
                        if (line.isBlank()) return@forEach
                        val o = runCatching { JSONObject(line) }.getOrNull() ?: return@forEach
                        when (o.optString("t")) {
                            "ready" -> _ready.value = true
                            "action" -> onAction?.invoke(o.optString("a"))
                            "pos" -> onPosition?.invoke(o.optInt("x"), o.optInt("y"))
                        }
                    }
                }
            }
            // 子进程 stderr 转进主日志，便于排查
            thread(isDaemon = true, name = "jz-lbp-err") {
                runCatching {
                    BufferedReader(InputStreamReader(p.errorStream)).useLines { lines ->
                        lines.forEach { JzLog.w(TAG, "child: $it") }
                    }
                }
            }
            thread(isDaemon = true, name = "jz-lbp-watch") {
                val code = runCatching { p.waitFor() }.getOrDefault(-1)
                JzLog.w(TAG, "child exited code=$code")
                _ready.value = false
                proc = null
                stdin = null
            }

            send(JSONObject().put("t", "init").put("theme", theme).put("font", font).put("lock", locked)
                .put("x", x).put("y", y).put("w", width))
        }.onFailure { JzLog.w(TAG, "start failed: ${it.message}") }
    }

    fun stop() {
        runCatching { send(JSONObject().put("t", "quit")) }
        runCatching { stdin?.close() }
        runCatching { proc?.destroy() }
        proc = null
        stdin = null
        _ready.value = false
    }

    fun setTheme(theme: Int) = send(JSONObject().put("t", "theme").put("theme", theme))

    fun setToolbar(open: Boolean) = send(JSONObject().put("t", "toolbar").put("open", open))

    /**
     * 推送当前歌词行（节流：位置变化才发，且最快 90ms 一次）。
     */
    fun pushLyrics(
        cur: String,
        next: String,
        empty: String,
        posMs: Long,
        curStartMs: Long,
        nextStartMs: Long,
        paused: Boolean,
        words: List<com.jz.musichelper.network.LyricWord>,
        animate: Boolean = false
    ) {
        val now = System.currentTimeMillis()
        val payloadKey = "$cur|$next|$empty|$paused|${words.size}"
        val changed = payloadKey != lastPayload
        if (!changed && now - lastSendMs < 90) return
        lastSendMs = now
        lastPayload = payloadKey

        val o = JSONObject()
            .put("t", "ly")
            .put("cur", cur)
            .put("next", next)
            .put("empty", empty)
            .put("pos", posMs)
            .put("curStart", curStartMs)
            .put("nextStart", nextStartMs)
            .put("paused", paused)
            .put("animate", animate)
        if (changed && words.isNotEmpty()) {
            val arr = JSONArray()
            words.forEach { w ->
                arr.put(JSONArray().put(w.startMs).put(w.durMs).put(w.text))
            }
            o.put("words", arr)
        } else if (words.isNotEmpty()) {
            val arr = JSONArray()
            words.forEach { w -> arr.put(JSONArray().put(w.startMs).put(w.durMs).put(w.text)) }
            o.put("words", arr)
        }
        send(o)
    }

    private fun send(o: JSONObject) {
        if (NOCHILD) return
        val w = stdin ?: return
        runCatching { w.println(o.toString()) }
    }

    /**
     * 子进程怎么启动：
     *  - 打包版：直接再起一个自己（jpackage 的 exe 会把参数透传给 main）
     *  - 开发期：用当前 java + classpath 起 `LyricsBarMain`
     */
    private fun buildCommand(): List<String>? {
        // 子进程也要把日志目录带过去：否则它会从自己的解包目录向上找项目根，找不到就落回 C 盘
        val logArg = "--log-dir=" + AppEnv.logsDir.absolutePath
        val exe = ProcessHandle.current().info().command().orElse(null)
        if (exe != null && exe.endsWith(".exe", ignoreCase = true) &&
            !exe.substringAfterLast('\\').startsWith("java", ignoreCase = true)
        ) {
            return listOf(exe, "--lyrics-bar")
        }
        val javaHome = System.getProperty("java.home") ?: return null
        val java = File(javaHome, "bin/java.exe")
        val cp = System.getProperty("java.class.path") ?: return null
        return listOf(java.absolutePath, "-cp", cp, "com.jz.musichelper.LyricsBarMain")
    }
}

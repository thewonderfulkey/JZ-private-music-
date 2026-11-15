package com.jz.musichelper

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogWindow
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberDialogState
import androidx.compose.ui.window.rememberWindowState
import com.jz.musichelper.data.AppEnv
import com.jz.musichelper.data.DesktopLyrics
import com.jz.musichelper.data.DownloadManager
import com.jz.musichelper.data.HistoryStore
import com.jz.musichelper.data.JzLog
import com.jz.musichelper.data.NextTrackCache
import com.jz.musichelper.data.PlayCache
import com.jz.musichelper.data.PlayLog
import com.jz.musichelper.data.PlayerManager
import com.jz.musichelper.data.SingleInstance
import com.jz.musichelper.data.TrayManager
import com.jz.musichelper.network.NetworkProbe
import com.jz.musichelper.ui.AppState
import com.jz.musichelper.ui.desktop.DeskToast
import com.jz.musichelper.ui.desktop.DesktopShell
import com.jz.musichelper.ui.Res
import java.awt.event.WindowAdapter
import java.awt.event.WindowEvent
import kotlin.system.exitProcess

/**
 * Windows 桌面版入口（对应 Android 的 MainActivity）。
 *
 * 与 Android 的差别只有「宿主」这一层：没有 Activity/Service/权限，窗口就是 Compose 的 ComposeWindow。
 * 启动顺序与 Android 版一致——先初始化存储/日志/缓存/播放器，再挂上自动连播监听，最后进界面。
 *
 * 窗口按手机竖屏的比例开（460×900dp，与 APK 的视觉网格一一对应），可自由拉大：
 * 播放页有「手机竖屏 / 平板画心 / 横屏左右」三套版式，窗口一变大就自动切到后两套。
 */

/**
 * 关闭主窗口（×）的行为：默认收进托盘继续播放；设置里可选「直接退出」。
 *
 * 这是 QQ 音乐 / 网易云 / 酷狗 的默认口径：
 *   ×  = 收进托盘（音乐不断，托盘图标出现，点图标/再双击 exe 都能唤回）
 *   −  = 普通最小化到任务栏（系统行为，不再自己接管）
 */
private fun closeToTray(): Boolean =
    com.jz.musichelper.data.AppEnv.prefs("jz_music_prefs").getString("close_action", "tray") != "exit"

/** 收进托盘前记下的窗口位置；唤回时按原位置摆好（最小化状态下不记，那时 bounds 是 -32000） */
private var hiddenBounds: java.awt.Rectangle? = null

/**
 * 唤回后把用户原来的位置/尺寸压回去。
 *
 * Compose 在窗口重新显示时会再套一遍 `WindowState`（1280×830dp），实测会让窗口在
 * 150% 缩放下"变大"一圈。等它处理完（下一两帧）再设一次 bounds 就稳住了。
 */
private var boundsTimer: javax.swing.Timer? = null
private fun reapplyBoundsLater(w: java.awt.Window) {
    val b = hiddenBounds ?: return
    boundsTimer?.stop()
    boundsTimer = javax.swing.Timer(250) { ev ->
        (ev.source as? javax.swing.Timer)?.stop()
        if (w.isVisible) {
            runCatching { w.bounds = b }
            JzLog.i("JZ_TRAY", "bounds reapplied -> ${w.bounds}")
        }
    }.apply {
        isRepeats = false
        start()
    }
}

/**
 * 把窗口从托盘里叫回来（托盘左键 / 托盘菜单"显示主界面" / 再双击一次 exe 都走这里）。
 *
 * 顺序很重要：先摆位置再显示，否则会看到窗口"从屏幕角落弹过来"。
 */
private fun restoredByUser(w: java.awt.Window) {
    val frame = w as? java.awt.Frame
    hiddenBounds?.let { b ->
        if (b.width > 0 && b.height > 0 && b.x > -10000) w.bounds = b
    }
    w.isVisible = true
    if (frame != null) frame.extendedState = frame.extendedState and java.awt.Frame.ICONIFIED.inv()
    w.toFront()
    w.requestFocus()
    reapplyBoundsLater(w)
    // 窗口已经在前台了，图标就不再属于"收在托盘里"这个状态
    TrayManager.remove()
    JzLog.i("JZ_TRAY", "main window shown (visible=${w.isVisible} bounds=${w.bounds} scale=${(w as? java.awt.Frame)?.graphicsConfiguration?.defaultTransform?.scaleX})")
}

// exitProcessOnExit = false：Compose 在有窗口被销毁时默认会直接 System.exit(0)，
// 我们自己是托盘型应用（关窗只是藏起来、后台继续唱），不能让它替我们决定进程生死。
fun main(args: Array<String>) {
    // 日志目录：显式指定（歌词栏子进程由主进程带过来）优先；其次靠启动位置向上找项目根。
    args.firstOrNull { it.startsWith("--log-dir=") }
        ?.removePrefix("--log-dir=")
        ?.trim('"')
        ?.takeIf { it.isNotBlank() }
        ?.let { System.setProperty("jz.log.dir", it) }
    // 便携启动器会把"用户双击的那个 exe 所在目录"传进来：日志目录要从这里向上找项目根，
    // 而不是从 %LOCALAPPDATA% 里的解包目录找（那样还是落在 C 盘）
    args.firstOrNull { it.startsWith("--launch-dir=") }
        ?.removePrefix("--launch-dir=")
        ?.trim('"')
        ?.takeIf { it.isNotBlank() }
        ?.let { System.setProperty("jz.launch.dir", it) }
    if (args.contains("--lyrics-bar")) {
        com.jz.musichelper.LyricsBarMain.run()
        return
    }
    // 单实例检查必须在这里（组合之外）做。写进 composable 会在每次重组时重跑，
    // 第二次 tryAcquire 必然失败 → exitProcess(0)，表现就是"用着用着软件突然没了"。
    if (!com.jz.musichelper.data.SingleInstance.tryAcquire()) {
        com.jz.musichelper.data.SingleInstance.askExistingToShow()
        exitProcess(0)
    }
    Runtime.getRuntime().addShutdownHook(Thread { com.jz.musichelper.data.SingleInstance.release() })
    runApp()
}

private fun runApp() {
    // —— 下面这些**只能跑一次**：放进 composable 会随每次重组重跑——
    // （曾经把单实例检查写进去，导致"任何重组都可能 exitProcess(0)"，查了很久）
    // 目录布局：安装版把 Download / Log / Cache / Data / Backup 建在安装目录里（见 AppEnv）
    AppEnv.ensureLayout()
    PlayLog.init()
    JzLog.i("JZ_APP", "layout -> ${AppEnv.layoutText()}")
    HistoryStore.init()
    DownloadManager.init()
    PlayerManager.init()
    NetworkProbe.init()
    NextTrackCache.init()
    PlayCache.init()
    DesktopLyrics.init()
    AppState.startAutoContinue()
    com.jz.musichelper.data.PeerTracer.startIfEnabled()

    // 诊断开关：JZ_TRACE_EXIT=1 时拦截退出，把"谁在 System.exit"的调用栈打出来
    if (System.getenv("JZ_TRACE_EXIT") == "1") {
        runCatching {
            @Suppress("DEPRECATION")
            System.setSecurityManager(object : SecurityManager() {
                override fun checkExit(status: Int) {
                    JzLog.e("JZ_EXIT", "System.exit($status) called from", Throwable("exit-trace"))
                }
            })
            JzLog.w("JZ_EXIT", "security manager installed")
        }.onFailure { JzLog.w("JZ_EXIT", "install failed: ${it.message}") }
    }

    Runtime.getRuntime().addShutdownHook(Thread {
        runCatching {
            JzLog.i("JZ_TRAY", "JVM shutdown: windows=${java.awt.Window.getWindows().size}")
            Thread.getAllStackTraces().forEach { (t, st) ->
                if (t.name.startsWith("AWT") || t.name == "main" || t.name.startsWith("jz-") ||
                    st.any { it.className.startsWith("java.lang.Shutdown") || it.methodName == "exit" }
                ) {
                    JzLog.i("JZ_TRAY", "thread ${t.name} state=${t.state} top=${st.take(25).joinToString(" <- ") { it.toString() }}")
                }
            }
        }
        SingleInstance.release()
    })

    // —— 全局兜底（对应 Android MainActivity 里的 setDefaultUncaughtExceptionHandler）——
    Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
        runCatching {
            val f = java.io.File(AppEnv.logsDir, "crash.log")
            f.appendText("===== ${java.util.Date()} [${thread.name}] =====\n$throwable\n")
            throwable.stackTrace.take(20).forEach { f.appendText("    at $it\n") }
            f.appendText("\n")
            val stack = throwable.stackTrace.take(10).joinToString("\n") { "    at $it" }
            AppEnv.prefs("jz_music_prefs").edit()
                .putString("last_error", "$throwable\n$stack")
                .putLong("last_error_time", System.currentTimeMillis())
                .apply()
        }
        JzLog.e("CRASH", "uncaught in ${thread.name}: $throwable", throwable)
    }

    application(exitProcessOnExit = false) {
        AppRoot()
    }
    JzLog.w("JZ_APP", "application returned -> Compose 认为没有窗口了")
}

@androidx.compose.runtime.Composable
private fun androidx.compose.ui.window.ApplicationScope.AppRoot() {
    val icon = remember { Res.image("icon.png")?.let { BitmapPainter(it) } }
    val windowState = rememberWindowState(size = DpSize(1280.dp, 830.dp))
    // onCloseRequest 在 Window 的参数位置求值，那时还没有 FrameWindowScope.window，
    // 所以在内容里把 window 记到这个 state 上，关闭时再用。
    val mainWindow = remember { androidx.compose.runtime.mutableStateOf<java.awt.Window?>(null) }

    // 真退出：停歌词、停播放器、摘托盘、销毁驻留窗口，最后结束进程。
    // 只有"设置=直接退出"或托盘菜单"退出"才会走到这里。
    val quit: () -> Unit = {
        JzLog.w("JZ_APP", "quit: lyrics+player shutdown, then exit")
        runCatching { DesktopLyrics.destroy() }
        runCatching { PlayerManager.shutdown() }
        runCatching { TrayManager.remove() }
        runCatching { TrayManager.destroyKeepAliveWindow() }
        exitApplication()
        exitProcess(0)
    }

    // × 的语义（对齐 QQ 音乐 / 网易云 / 酷狗）：收进托盘继续播放。
    //
    // 这里曾经的两个坑，别再踩：
    //  ① 隐藏动作原来挂在 TrayManager 的 onHide 回调上，而托盘图标只在最小化时装 → 启动后点 ×
    //     回调是 null，× 看上去"完全没反应"（用户反馈的 bug）。现在隐藏动作是自包含的。
    //  ② 不能 dispose、也不能让 AWT 认为"没有可见窗口"（AWTAutoShutdown 会结束 JVM），
    //     所以只 isVisible=false，另有一个常驻的 keeper 窗口撑着。
    val hideToTray: (java.awt.Window) -> Unit = { w ->
        TrayManager.install(show = { restoredByUser(w) }, quit = quit)
        if (!TrayManager.isInstalled) {
            // 托盘不可用（极少数精简系统 / JZ_NO_TRAY=1）：藏了就叫不回来，索性不藏，只提示
            JzLog.w("JZ_APP", "hide-to-tray aborted: tray unavailable")
            DeskToast.show("系统托盘不可用，无法收进托盘继续播放")
        } else {
            val frame = w as? java.awt.Frame
            val iconified = frame != null && (frame.extendedState and java.awt.Frame.ICONIFIED) != 0
            if (!iconified && w.x > -10000) hiddenBounds = w.bounds
            // 真正隐藏：任务栏按钮随窗口一起消失（托盘应用该有的样子）
            w.isVisible = false
            JzLog.w("JZ_APP", "close -> hide to tray (visible=${w.isVisible} bounds=${hiddenBounds})")
            TrayManager.notifyHidden()
        }
    }

    Window(
        onCloseRequest = {
            // × / Alt+F4 的统一入口
            val w = mainWindow.value
            if (w == null || !closeToTray() || !TrayManager.available) {
                JzLog.w("JZ_APP", "onCloseRequest -> exit (setting=exit or no tray)")
                quit()
            } else {
                JzLog.w("JZ_APP", "onCloseRequest -> hide to tray")
                hideToTray(w)
            }
        },
        title = "JZ Music",
        state = windowState,
        icon = icon,
        // Windows 上没有系统返回键，把 Android 的"返回层级"挂到 Esc 上（播放页 → 歌单页 → 主界面）
        onPreviewKeyEvent = { ev ->
            if (ev.type == KeyEventType.KeyDown) {
                com.jz.musichelper.data.JzLog.i("JZ_KEY", "window key=${ev.key} enter=${ev.key == Key.Enter}")
                when (ev.key) {
                    // 选目录浮层开着时，Esc/回车先归它：Esc 先收「新建文件夹」再关窗，
                    // 回车留给路径框/新建框自己处理（不能在这里吃成搜索提交）
                    Key.Escape ->
                        if (com.jz.musichelper.ui.desktop.DirPicker.open) {
                            com.jz.musichelper.ui.desktop.DirPicker.escape()
                            true
                        } else {
                            com.jz.musichelper.ui.BackDispatcher.handle()
                        }
                    Key.Enter, Key.NumPadEnter ->
                        if (com.jz.musichelper.ui.desktop.DirPicker.open) {
                            com.jz.musichelper.ui.desktop.DirPicker.enterPressed()
                            true
                        } else {
                            com.jz.musichelper.ui.desktop.SearchBus.submit()
                        }
                    else -> false
                }
            } else false
        }
    ) {
        androidx.compose.runtime.SideEffect { mainWindow.value = window }
        androidx.compose.runtime.DisposableEffect(window) {
            // Compose 默认 DISPOSE_ON_CLOSE：点 × 会销毁窗口、application 随之退出。
            // 关闭语义由 onCloseRequest 决定，所以这里统一 DO_NOTHING_ON_CLOSE。
            window.defaultCloseOperation = javax.swing.WindowConstants.DO_NOTHING_ON_CLOSE
            val listener = object : WindowAdapter() {
                override fun windowGainedFocus(e: WindowEvent?) {
                    DesktopLyrics.setAppVisible(true)
                }

                override fun windowLostFocus(e: WindowEvent?) {
                    DesktopLyrics.setAppVisible(false)
                }
            }
            window.addWindowFocusListener(listener)
            DesktopLyrics.setAppVisible(true)
            onDispose { window.removeWindowFocusListener(listener) }
        }
        // 二次启动时把窗口叫回来（常驻实例已存在 → 新进程只发一句 SHOW）
        androidx.compose.runtime.DisposableEffect(Unit) {
            SingleInstance.startServer {
                javax.swing.SwingUtilities.invokeLater { restoredByUser(window) }
            }
            onDispose { }
        }
        // 常驻"驻留窗口"：主窗藏起来后，靠它让 AWT 认为还有可见窗口，进程不会被自动关停。
        androidx.compose.runtime.DisposableEffect(Unit) {
            TrayManager.installKeepAliveWindow()
            onDispose { TrayManager.remove() }
        }
        // 诊断：应用作用域结束时打一条，用来确认"是不是 composition 被结束了"
        androidx.compose.runtime.DisposableEffect(Unit) {
            onDispose { JzLog.w("JZ_APP", "application scope disposed -> 进程将退出") }
        }
        window.minimumSize = java.awt.Dimension(980, 640)
        // 2026-11：按用户口径改成 PC 版式（左侧栏 + 宽内容区 + 底部播放条 + 右侧正在播放/歌词），
        // 不再复用手机竖屏版式；App() 仍保留在仓库里作为手机版对照。
        // 桌面壳没套 AppTheme，这里补一份纸墨色板：否则 Material 下拉菜单/开关会退回默认淡紫
        androidx.compose.material3.MaterialTheme(
            colorScheme = com.jz.musichelper.ui.theme.InkColorScheme
        ) {
            DesktopShell()
        }

        // 自动化冒烟入口：设了环境变量才会生效（等价 Android 版 smoke 变体的 intent 注入口）。
        // 用法：JZ_SMOKE_SEARCH=夜曲 JZ_SMOKE_PLAY=1，启动后自动搜索并播第一首，日志里打各平台条数。
        androidx.compose.runtime.LaunchedEffect(Unit) {
            // 位置预设自测：JZ_SMOKE_PRESET=hx,vy（0..2）
            System.getenv("JZ_SMOKE_PRESET")?.split(",")?.let { a ->
                if (a.size == 2) {
                    kotlinx.coroutines.delay(800)
                    com.jz.musichelper.data.DesktopLyrics.setPositionPreset(
                        a[0].trim().toIntOrNull() ?: 0,
                        a[1].trim().toIntOrNull() ?: 0
                    )
                }
            }
            val kw = System.getenv("JZ_SMOKE_SEARCH") ?: System.getProperty("jz.smoke.search")
            if (!kw.isNullOrBlank()) {
                kotlinx.coroutines.delay(1500)
                val playFirst = (System.getenv("JZ_SMOKE_PLAY") ?: System.getProperty("jz.smoke.play")) == "1"
                AppState.searchForTest(kw, playFirst)
            }
            // 选目录浮层自测：JZ_SMOKE_DIRPICKER=D:\some\dir 启动后直接把浮层打开，方便截图/走查
            val dirPicker = System.getenv("JZ_SMOKE_DIRPICKER")
            if (!dirPicker.isNullOrBlank()) {
                kotlinx.coroutines.delay(1200)
                com.jz.musichelper.ui.desktop.DirPicker.request(java.io.File(dirPicker)) { }
            }
        }
    }
    // 桌面歌词悬浮栏（Compose 窗口，替代原来的 AWT JWindow）
    com.jz.musichelper.ui.desktop.DesktopLyricsBarHost()

    // 常驻的隐形"驻留窗口"：Compose Desktop 在最后一个窗口不可见时会结束 application，
    // 托盘模式下必须留一个一直开着的窗口，否则主窗口一收起来进程就退出、音乐也断了。
    // 用 DialogWindow（JDialog）而不是 Window：它不进任务栏、不参与 alt-tab，用户看不到。
    DialogWindow(
        onCloseRequest = {},
        state = rememberDialogState(size = DpSize(1.dp, 1.dp), position = WindowPosition(0.dp, 0.dp)),
        undecorated = true,
        resizable = false,
        title = "JZ Music 后台"
    ) {
        androidx.compose.runtime.DisposableEffect(window) {
            runCatching { window.focusableWindowState = false }
            onDispose { }
        }
        androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.size(1.dp))
    }
}

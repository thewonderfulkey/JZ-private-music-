package com.jz.musichelper.data

import java.awt.AWTException
import java.awt.Color
import java.awt.Font
import java.awt.Image
import java.awt.RenderingHints
import java.awt.SystemTray
import java.awt.TrayIcon
import java.awt.image.BufferedImage
import javax.imageio.ImageIO
import javax.swing.SwingUtilities

/**
 * 系统托盘（PC 端"关掉窗口继续放歌"的关键）。
 *
 * 关窗 = 收进托盘，播放不中断；左键单击恢复窗口，右键弹出自己的菜单。
 * 图标只在"窗口确实收起来了"这段时间存在（见 Main.kt 的 hideToTray），
 * 窗口回到前台就摘掉——不留"幽灵图标"。
 *
 * 两个踩过的坑，这里都绕开了：
 *  ① AWT 的 `PopupMenu` 把中文标签按平台编码塞进宽字符 API，Windows 上会显示乱码 → 改成自绘菜单窗口；
 *  ② `TrayIcon.addActionListener` 只在**双击**时触发，用户以为"要点两次" → 改成鼠标监听单击。
 */
object TrayManager {

    private var trayIcon: TrayIcon? = null
    private var trayMenu: TrayMenuWindow? = null
    private var onShow: (() -> Unit)? = null
    private var onQuit: (() -> Unit)? = null

    val available: Boolean
        get() = runCatching { SystemTray.isSupported() }.getOrDefault(false)

    /** 托盘图标当前是否真的在任务栏右下角 */
    val isInstalled: Boolean
        get() = trayIcon != null

    fun install(show: () -> Unit, quit: () -> Unit) {
        if (System.getenv("JZ_NO_TRAY") == "1") { JzLog.w("JZ_TRAY", "skip install (JZ_NO_TRAY=1)"); return }
        if (!available || trayIcon != null) return
        onShow = show
        onQuit = quit
        try {
            val image = loadIcon() ?: fallbackIcon()
            val menu = TrayMenuWindow(
                listOf(
                    TrayMenuWindow.Entry("显示主界面", TrayMenuWindow.Icon.WINDOW) { toggleWindow() },
                    TrayMenuWindow.Entry("播放 / 暂停", TrayMenuWindow.Icon.PLAY) { onEdt { PlayerManager.toggle() } },
                    TrayMenuWindow.Entry("上一首", TrayMenuWindow.Icon.PREV) { onEdt { com.jz.musichelper.ui.AppState.prevSong() } },
                    TrayMenuWindow.Entry("下一首", TrayMenuWindow.Icon.NEXT) { onEdt { com.jz.musichelper.ui.AppState.nextSong() } },
                    TrayMenuWindow.Entry("退出 JZ Music", TrayMenuWindow.Icon.POWER, danger = true) { quitApp() }                )
            )
            trayMenu = menu
            val tip = TrayIcon(image, "JZ Music", null).apply {
                isImageAutoSize = true
                addMouseListener(object : java.awt.event.MouseAdapter() {
                    override fun mouseReleased(e: java.awt.event.MouseEvent) {
                        when {
                            SwingUtilities.isRightMouseButton(e) || e.isPopupTrigger ->
                                menu.showNearCursor()

                            SwingUtilities.isLeftMouseButton(e) -> {
                                menu.hide()
                                toggleWindow()
                            }
                        }
                    }
                })
            }
            SystemTray.getSystemTray().add(tip)
            trayIcon = tip
            staleIcons.add(tip)
            // 自测钩子：JZ_TEST_TRAY_MENU=1 时直接把菜单弹在屏幕中央，方便截图核对字体/编码
            if ((System.getenv("JZ_TEST_TRAY_MENU") ?: "") == "1") {
                SwingUtilities.invokeLater {
                    val s = AppEnv.screenBounds
                    menu.showAt(java.awt.Point(s.x + s.width / 2, s.y + s.height / 2))
                }
            }
            JzLog.i("JZ_TRAY", "tray installed (custom menu)")
        } catch (_: AWTException) {
            JzLog.w("JZ_TRAY", "系统托盘不可用，关窗将无法驻留后台")
        } catch (e: Exception) {
            JzLog.w("JZ_TRAY", "托盘安装失败：${e.message}")
        }
    }

    /**
     * 一个屏幕外的 1×1 窗口，用来当"驻留窗口"。
     *
     * 为什么要它：主窗口藏起来后，AWT 的 AWTAutoShutdown 会认为"没有窗口可用了"并结束 JVM
     * （实测 packaged exe 里 0.4 秒后进程就没了，播放随之断掉）。留一个一直显示着的窗口，
     * 自动关闭就不会触发；JWindow 不进任务栏、不参与 alt-tab，用户看不到它。
     */
    private var keeper: javax.swing.JWindow? = null

    fun installKeepAliveWindow() {
        if (keeper != null) return
        runCatching {
            val w = javax.swing.JWindow()
            w.focusableWindowState = false
            w.setSize(1, 1)
            w.setLocation(-32000, -32000)
            w.isVisible = true
            keeper = w
            JzLog.i("JZ_TRAY", "keep-alive window installed (JWindow)")
        }.onFailure { JzLog.w("JZ_TRAY", "keep-alive window failed: ${it.message}") }
    }

    /**
     * 只移除**托盘图标**（窗口恢复/关到后台时用）。
     *
     * 注意不能顺手把驻留窗口 dispose 掉：主窗移出屏幕后，AWT 会因为没有可见窗口而结束 JVM。
     * 驻留窗口只在真正退出（[destroyKeepAliveWindow]）时销毁。
     */
    fun remove() {
        runCatching { trayMenu?.hide() }
        trayMenu = null
        // 兜底：万一之前有泄漏的图标，逐个摘掉，避免"点了 × 托盘还留一个"
        val tray = runCatching { SystemTray.getSystemTray() }.getOrNull()
        trayIcon?.let { icon -> runCatching { tray?.remove(icon) } }
        trayIcon = null
        staleIcons.forEach { icon -> runCatching { tray?.remove(icon) } }
        staleIcons.clear()
        JzLog.i("JZ_TRAY", "tray icon removed")
    }

    private val staleIcons = java.util.Collections.synchronizedList(ArrayList<TrayIcon>())

    /** 退出时才销毁驻留窗口 */
    fun destroyKeepAliveWindow() {
        runCatching { keeper?.dispose() }
        keeper = null
    }

    /** 第一次收起窗口时给个气泡提示，避免用户以为程序被关掉了 */
    fun notifyHidden() {
        val tip = trayIcon ?: return
        runCatching {
            tip.displayMessage(
                "JZ Music 还在播放",
                "窗口已收起到托盘。左键单击托盘图标可以恢复窗口，右键有更多操作。",
                TrayIcon.MessageType.INFO
            )
        }
    }

    private fun toggleWindow() = onEdt { onShow?.invoke() }

    private fun quitApp() = onEdt {
        remove()
        onQuit?.invoke()
    }

    private inline fun onEdt(crossinline block: () -> Unit) {
        if (SwingUtilities.isEventDispatchThread()) block() else SwingUtilities.invokeLater { block() }
    }

    private fun loadIcon(): Image? = runCatching {
        val bytes = TrayManager::class.java.classLoader?.getResourceAsStream("icon.png")?.use { it.readBytes() }
            ?: return@runCatching null
        ImageIO.read(bytes.inputStream())?.getScaledInstance(64, 64, Image.SCALE_SMOOTH)
    }.getOrNull()

    private fun fallbackIcon(): Image {
        val img = BufferedImage(64, 64, BufferedImage.TYPE_INT_ARGB)
        val g = img.createGraphics()
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON)
        g.color = Color(0x2E, 0x2A, 0x24)
        g.fillRoundRect(4, 4, 56, 56, 18, 18)
        g.color = Color(0xF7, 0xF5, 0xF0)
        g.font = Font("Microsoft YaHei", Font.BOLD, 30)
        g.drawString("JZ", 10, 44)
        g.dispose()
        return img
    }
}

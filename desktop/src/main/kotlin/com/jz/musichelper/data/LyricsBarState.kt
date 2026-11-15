package com.jz.musichelper.data

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.jz.musichelper.network.LyricLine

/**
 * 桌面歌词悬浮窗的**唯一事实源**（Compose 状态）。
 *
 * 旧实现是 AWT 自绘的 JWindow：窗口在播放/切歌时会被 AWT 判定为"没有可显示窗口"，
 * 触发 AWTAutoShutdown 直接 System.exit(0)——表现就是"一点歌软件就没了"。
 * 现在改成 Compose 窗口，数据走这里，绘制走 `ui/desktop/DesktopLyricsBar.kt`。
 */
object LyricsBarState {

    /** 是否显示悬浮窗（= 用户开关） */
    var visible by mutableStateOf(false)

    /** 当前句 / 下一句文本 */
    var curText by mutableStateOf("")
    var nextText by mutableStateOf("")

    /** 空态文案（"暂无歌词" / "歌词加载中…"） */
    var emptyText by mutableStateOf("暂无歌词")

    /** 当前句（带逐字时间），用于逐字染色 */
    var curLine by mutableStateOf<LyricLine?>(null)

    /** 下一句开始时间（算行内进度用） */
    var nextStartMs by mutableLongStateOf(0L)

    /** 播放位置（毫秒），100ms 更新一次 */
    var positionMs by mutableLongStateOf(0L)

    /** 是否暂停（显示"暂停"标记） */
    var paused by mutableStateOf(true)

    /** 外观：0 素纸 / 1 旧黄 / 2 夜墨 */
    var theme by mutableIntStateOf(0)
    var fontStep by mutableIntStateOf(0)
    var locked by mutableStateOf(false)

    /** 工具条展开状态与朝向（贴屏幕底时朝上） */
    var toolbarOpen by mutableStateOf(false)
    var toolbarAbove by mutableStateOf(false)

    /** 每次换句 +1，UI 用它做一次淡入过渡 */
    var lineTick by mutableIntStateOf(0)

    /** 位置重置信号（设置页"重置位置"用） */
    var positionRevision by mutableIntStateOf(0)

    fun clearForSong() {
        curText = ""
        nextText = ""
        curLine = null
        nextStartMs = 0L
        positionMs = 0L
    }
}

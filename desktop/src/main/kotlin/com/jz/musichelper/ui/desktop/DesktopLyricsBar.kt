package com.jz.musichelper.ui.desktop

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.platform.Font
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.rememberWindowState
import com.jz.musichelper.data.AppEnv
import com.jz.musichelper.data.DesktopLyrics
import com.jz.musichelper.data.JzLog
import com.jz.musichelper.data.LyricsBarState
import com.jz.musichelper.ui.LyricsMetrics
import kotlinx.coroutines.delay

/** 悬浮栏总开关（Compose 版重写验收通过后置 true） */
private const val BAR_ENABLED = false

/**
 * 桌面歌词悬浮栏（Compose 版）。
 *
 * 旧版是 AWT 自绘 JWindow：播放/切歌时会触发 `AWTAutoShutdown` → `System.exit(0)`。
 * 现在用 Compose 的 `Window`，与主窗口同一套渲染与生命周期，不会再让 AWT 误判"没有窗口"。
 *
 * 窗口常驻组合，只切 `visible`；避免反复创建/销毁窗口（那同样会触发 AWT 关停）。
 */
@Composable
fun DesktopLyricsBarHost() {
    // 重写进行中：Compose 版的绘制/逐字染色已经可用，但窗口在"显示→失焦→点不到"这条路径上
    // 还不稳定（见 docs/changelog 记录）。先保持关闭，避免交付一个不能拖、点不动的悬浮窗。
    if (!BAR_ENABLED) return
    val state = LyricsBarState
    val scale = LyricsMetrics.scale

    val barH = 66f * scale          // 栏体高度（dp）
    val toolbarH = 46f * scale      // 工具条高度（dp）
    val gap = 8f * scale            // 工具条与栏体间距（dp）
    val totalH = barH + if (state.toolbarOpen) toolbarH + gap else 0f

    val density = LocalDensity.current.density
    // 初始位置必须在创建窗口时给：Compose 只在创建时应用 WindowPosition，
    // 之后改 winState.position 不会移动窗口（实测），而用 AWT setLocation 又会破坏输入管线。
    val initialPx = remember {
        DesktopLyrics.initialPositionPx(LyricsMetrics.barWidth.toInt(), totalH.toInt())
    }
    var posPx by remember { mutableStateOf(initialPx) }
    val winState = rememberWindowState(
        position = androidx.compose.ui.window.WindowPosition(initialPx.first.dp, initialPx.second.dp),
        size = DpSize(LyricsMetrics.barWidth.dp, totalH.dp)
    )

    Window(
        visible = state.visible,
        onCloseRequest = { DesktopLyrics.toggleFromUi(false) },
        undecorated = true,
        // 透明窗口在 Windows 上实测收不到鼠标事件（点栏体没反应），改成不透明 +
        // 背景直接用纸色：视觉上一样，交互正常
        transparent = false,
        resizable = false,
        focusable = true,
        alwaysOnTop = false,
        title = "JZ Music 桌面歌词",
        state = winState
    ) {
        // 尺寸交给 Compose；位置已在创建窗口时给定（运行期改 WindowPosition 不生效）
        LaunchedEffect(state.visible, state.positionRevision, state.toolbarOpen) {
            if (!state.visible) return@LaunchedEffect
            val wPx = LyricsMetrics.barWidth.toInt()
            val hPx = totalH.toInt()
            winState.size = DpSize(wPx.dp, hPx.dp)
            window.isAlwaysOnTop = true
            JzLog.i(
                "JZ_DL",
                "bar sync size=${wPx}x$hPx showing=${window.isShowing} bounds=${window.bounds} pos=$posPx"
            )
        }

        LyricsBar(
            barH = barH,
            toolbarH = toolbarH,
            gap = gap,
            onTapBar = {
                // 点栏体：开/关工具条；贴近屏幕底部时工具条朝上，避免顶出屏外
                if (state.toolbarOpen) {
                    state.toolbarOpen = false
                } else {
                    val p = posPx
                    val screen = AppEnv.screenBounds
                    val toolbarPx = (toolbarH + gap).toInt()
                    val barPx = barH.toInt()
                    val roomBelow = screen.y + screen.height - ((p?.second ?: 0) + barPx)
                    val above = roomBelow < toolbarPx
                    state.toolbarAbove = above
                    if (above && p != null) {
                        posPx = p.first to (p.second - toolbarPx).coerceAtLeast(screen.y)
                    }
                    state.toolbarOpen = true
                }
            },
            onDrag = { dx, dy ->
                val p = posPx ?: return@LyricsBar
                val wPx = LyricsMetrics.barWidth.toInt()
                val hPx = totalH.toInt()
                val screen = AppEnv.screenBounds
                val nx = (p.first + dx).toInt()
                    .coerceIn(screen.x, (screen.x + screen.width - wPx).coerceAtLeast(screen.x))
                val ny = (p.second + dy).toInt()
                    .coerceIn(screen.y, (screen.y + screen.height - hPx).coerceAtLeast(screen.y))
                posPx = nx to ny
                window.setLocation(nx, ny)
            },
            onDragEnd = {
                val p = posPx ?: return@LyricsBar
                DesktopLyrics.savePositionPx(
                    p.first, p.second,
                    LyricsMetrics.barWidth.toInt(),
                    totalH.toInt()
                )
            }
        )
    }
}

@Composable
private fun LyricsBar(
    barH: Float,
    toolbarH: Float,
    gap: Float,
    onTapBar: () -> Unit,
    onDrag: (Float, Float) -> Unit,
    onDragEnd: () -> Unit
) {
    val state = LyricsBarState
    val pal = barPalette(state.theme)
    val scale = LyricsMetrics.scale
    val kai = remember { kaiFamily() }
    val corner = RoundedCornerShape((3f * scale).dp)

    val baseSize = (17f * scale + state.fontStep * 1.6f * scale).sp
    val nextSize = (11f * scale + state.fontStep * 1.2f * scale).sp

    // 工具条 3 秒后自动收起
    LaunchedEffect(state.toolbarOpen) {
        if (state.toolbarOpen) {
            delay(3000)
            state.toolbarOpen = false
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val e = awaitPointerEvent()
                        JzLog.i("JZ_DL", "ROOT pointer ${e.type} n=${e.changes.size}")
                    }
                }
            },
        verticalArrangement = Arrangement.Bottom
    ) {
        if (state.toolbarOpen && state.toolbarAbove) {
            BarToolbar(pal, toolbarH)
            Spacer(Modifier.height(gap.dp))
        }

        Box(
            Modifier
                .fillMaxWidth()
                .height(barH.dp)
                .pointerInput(Unit) {
                    awaitPointerEventScope {
                        while (true) {
                            val e = awaitPointerEvent()
                            com.jz.musichelper.data.JzLog.i("JZ_DL", "bar pointer ${e.type} changes=${e.changes.size}")
                            break
                        }
                    }
                }
                .clip(corner)
                .background(pal.paper)
                .border((0.9f * scale).dp, pal.edge, corner)
                .clickable(
                    interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                    indication = null
                ) {
                    com.jz.musichelper.data.JzLog.i("JZ_DL", "bar clickable fired, locked=${state.locked}")
                    onTapBar()
                }
                .pointerInput(state.locked) {
                    if (state.locked) return@pointerInput
                    // 拖拽与点击放在同一个手势循环里：两个独立 pointerInput 会互相抢事件
                    //（拖拽把按下消费掉，点击就永远收不到）
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        val start = down.position
                        var dragging = false
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull() ?: break
                            if (change.changedToUpIgnoreConsumed()) break
                            val moved = change.position - start
                            if (!dragging && moved.getDistance() > 6f) dragging = true
                            if (dragging) {
                                val delta = change.positionChange()
                                change.consume()
                                onDrag(delta.x, delta.y)
                            }
                        }
                        if (dragging) onDragEnd() else onTapBar()
                    }
                }
        ) {
            // 顶部细横线
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = (7f * scale).dp, vertical = (1.6f * scale).dp)
                    .height((1.3f * scale).dp)
                    .background(pal.rule)
            )

            Column(
                Modifier
                    .fillMaxSize()
                    .padding(horizontal = (12f * scale).dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                if (state.emptyText.isNotEmpty()) {
                    Text(
                        state.emptyText,
                        color = pal.sub,
                        fontSize = (13f * scale).sp,
                        fontFamily = kai,
                        textAlign = TextAlign.Center
                    )
                } else {
                    val line = state.curLine
                    val annotated: AnnotatedString = if (line != null) {
                        Karaoke.annotate(
                            line = line,
                            nextStartMs = state.nextStartMs,
                            posMs = state.positionMs,
                            unsung = pal.ink.copy(alpha = 0.32f),
                            sung = pal.ink
                        )
                    } else {
                        AnnotatedString(state.curText)
                    }
                    Text(
                        annotated,
                        color = pal.ink,
                        fontSize = baseSize,
                        fontFamily = kai,
                        fontWeight = FontWeight.Medium,
                        textAlign = TextAlign.Center,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        lineHeight = (baseSize.value * 1.26f).sp
                    )
                    if (state.nextText.isNotBlank()) {
                        Spacer(Modifier.height((4f * scale).dp))
                        Text(
                            state.nextText,
                            color = pal.sub,
                            fontSize = nextSize,
                            fontFamily = kai,
                            textAlign = TextAlign.Center,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }

            // 右上角小锁
            Icon(
                if (state.locked) Icons.Filled.Lock else Icons.Filled.LockOpen,
                contentDescription = if (state.locked) "解锁" else "锁定",
                tint = pal.light,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = (6f * scale).dp, end = (8f * scale).dp)
                    .size((11f * scale).dp)
                    .handCursor()
                    .pointerInput(Unit) { detectTapGestures { DesktopLyrics.toggleLock() } }
            )
        }

        if (state.toolbarOpen && !state.toolbarAbove) {
            Spacer(Modifier.height(gap.dp))
            BarToolbar(pal, toolbarH)
        }
    }
}

@Composable
private fun BarToolbar(pal: BarPalette, height: Float) {
    val state = LyricsBarState
    val scale = LyricsMetrics.scale
    val ink = pal.ink
    val corner = RoundedCornerShape((3f * scale).dp)
    Row(
        Modifier
            .fillMaxWidth()
            .height(height.dp)
            .clip(corner)
            .background(pal.paper)
            .border((0.9f * scale).dp, pal.edge, corner),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceEvenly
    ) {
        val iconSize = (17f * scale).dp
        BarIcon(Icons.Filled.SkipPrevious, "上一句", ink, iconSize) { DesktopLyrics.prevLine() }
        BarIcon(
            if (state.paused) Icons.Filled.PlayArrow else Icons.Filled.Pause,
            if (state.paused) "播放" else "暂停",
            ink, iconSize
        ) { DesktopLyrics.togglePlay() }
        BarIcon(Icons.Filled.SkipNext, "下一句", ink, iconSize) { DesktopLyrics.nextLine() }
        Row(verticalAlignment = Alignment.CenterVertically) {
            BarText("A-", ink) { DesktopLyrics.adjustFontStep(-1) }
            Spacer(Modifier.width((12f * scale).dp))
            BarText("A+", ink) { DesktopLyrics.adjustFontStep(1) }
        }
        BarIcon(
            if (state.locked) Icons.Filled.Lock else Icons.Filled.LockOpen,
            "锁定", ink, iconSize
        ) { DesktopLyrics.toggleLock() }
        BarText("关闭", ink.copy(alpha = 0.8f)) { DesktopLyrics.closeBar() }
    }
}

@Composable
private fun BarIcon(icon: ImageVector, label: String, tint: Color, size: androidx.compose.ui.unit.Dp, onClick: () -> Unit) {
    Icon(
        icon,
        contentDescription = label,
        tint = tint,
        modifier = Modifier
            .size(size)
            .handCursor()
            .pointerInput(Unit) { detectTapGestures { onClick() } }
    )
}

@Composable
private fun BarText(text: String, color: Color, onClick: () -> Unit) {
    Text(
        text,
        color = color,
        fontSize = (11f * LyricsMetrics.scale).sp,
        modifier = Modifier.handCursor().pointerInput(Unit) { detectTapGestures { onClick() } }
    )
}

// ===== 配色（与旧版 Java2D 三套主题一致）=====

private class BarPalette(
    val paper: Color,
    val ink: Color,
    val light: Color,
    val sub: Color,
    val rule: Color,
    val edge: Color
)

private fun barPalette(index: Int): BarPalette = when (index) {
    1 -> BarPalette(
        paper = Color(0xFFF2E5C4), ink = Color(0xFF30281C), light = Color(0xFFA89268),
        sub = Color(0xFF967C5C), rule = Color(0xFF8A7040), edge = Color(0xFFDCC79C)
    )
    2 -> BarPalette(
        paper = Color(0xFF24211D), ink = Color(0xFFF0EADA), light = Color(0xFF706A5E),
        sub = Color(0xFF948F82), rule = Color(0xFF4A443A), edge = Color(0xFF3B372F)
    )
    else -> BarPalette(
        paper = Color(0xFFFBF7ED), ink = Color(0xFF2C2822), light = Color(0xFFB0A898),
        sub = Color(0xFF8A8378), rule = Color(0xFFBDB3A0), edge = Color(0xFFE0D8C8)
    )
}

/** 霞鹜文楷（随包分发）；读不到退回系统字体，保证一定显示中文 */
private fun kaiFamily(): FontFamily = runCatching {
    val bytes = LyricsBarState::class.java.classLoader
        ?.getResourceAsStream("font/lxgw_wenkai_regular.ttf")?.use { it.readBytes() }
        ?: return@runCatching FontFamily.Default
    FontFamily(Font("lxgw_wenkai", bytes))
}.getOrDefault(FontFamily.Default)

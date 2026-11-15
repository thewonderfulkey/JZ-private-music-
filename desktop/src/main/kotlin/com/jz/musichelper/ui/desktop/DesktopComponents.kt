package com.jz.musichelper.ui.desktop

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.pointerHoverIcon
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jz.musichelper.model.MusicPlatform
import com.jz.musichelper.model.Song
import com.jz.musichelper.ui.CoverImage
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette

/** 可点元素统一用手型光标（桌面上"能点"的第一视觉信号） */
fun Modifier.handCursor(): Modifier = this.pointerHoverIcon(
    androidx.compose.ui.input.pointer.PointerIcon.Hand, overrideDescendants = false
)

/** PC 版专属的几档中性色：都从既有墨水色板推出来，避免出现"另一套配色" */
object DeskColors {
    val sidebarTop = Color(0xFFF3EEE2)
    val sidebarBottom = Color(0xFFEDE7D8)
    val hover = Color(0x142E2A24)
    val hoverStrong = Color(0x222E2A24)
    val divider = Color(0x1F2E2A24)
    val rowDivider = Color(0x142E2A24)
    val barBg = Color(0xFFF7F3E9)
    val panelBg = Color(0xFAFBF7ED)
    val inkSoft = Color(0x332E2A24)
}

/** 平台标签：四家各给一个"纸上的朱砂/墨色"标记，不用品牌色，保持水墨统一 */
@Composable
fun PlatformTag(platform: MusicPlatform, compact: Boolean = false) {
    val p = LocalPalette.current
    val (bg, fg) = when (platform) {
        MusicPlatform.QQ -> Color(0x1A8C6D3F) to Color(0xFF7A5A2E)
        MusicPlatform.NETEASE -> Color(0x1AB03A2E) to Color(0xFFB03A2E)
        MusicPlatform.KUWO -> Color(0x1A3F6D8C) to Color(0xFF35617D)
        MusicPlatform.KUGOU -> Color(0x1A5A5346) to Color(0xFF5A5346)
    }
    Text(
        platform.shortName,
        fontSize = if (compact) 10.sp else 11.sp,
        color = fg,
        modifier = Modifier
            .background(bg, RoundedCornerShape(4.dp))
            .padding(horizontal = if (compact) 5.dp else 6.dp, vertical = 2.dp)
    )
}

/** 有悬停 + 按下反馈的整行（PC 端必须有 hover，否则一排排歌分不清指向；按下要立刻压暗） */
@Composable
fun HoverRow(
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    onDoubleClick: (() -> Unit)? = null,
    content: @Composable (hovered: Boolean) -> Unit
) {
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val pressed by interaction.collectIsPressedAsState()
    val bg by animateColorAsState(
        when {
            pressed -> DeskColors.hoverStrong
            hovered -> DeskColors.hover
            else -> Color.Transparent
        },
        animationSpec = tween(90),
        label = "rowBg"
    )
    Box(
        modifier = modifier
            .hoverable(interaction)
            .clip(RoundedCornerShape(8.dp))
            .background(bg)
            .then(
                if (onClick != null) Modifier
                    .handCursor()
                    .clickable(interactionSource = interaction, indication = null) { onClick() }
                else Modifier
            )
    ) { content(hovered) }
}

/** 封面（圆角 + 加载失败落"墨色首字"占位） */
@Composable
fun SongCover(
    song: Song,
    size: Dp,
    modifier: Modifier = Modifier,
    corner: Dp = 6.dp,
    onBitmaps: ((ImageBitmap) -> Unit)? = null
) {
    val fallback: @Composable () -> Unit = { CoverPlaceholder(song, size) }
    Box(modifier = modifier.size(size).clip(RoundedCornerShape(corner))) {
        val url = song.picUrl
        if (!url.isNullOrBlank()) {
            CoverImage(
                url = url,
                contentDescription = song.name,
                loading = { fallback() },
                error = { fallback() },
                success = { bmp ->
                    androidx.compose.foundation.Image(
                        bitmap = bmp,
                        contentDescription = song.name,
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                        modifier = Modifier.fillMaxSize()
                    )
                    onBitmaps?.invoke(bmp)
                }
            )
        } else {
            fallback()
        }
    }
}

@Composable
fun CoverPlaceholder(song: Song, size: Dp) {
    Box(
        modifier = Modifier
            .size(size)
            .background(Brush.verticalGradient(listOf(Color(0xFFF1EDE2), Color(0xFFE2DBCB)))),
        contentAlignment = Alignment.Center
    ) {
        val initial = song.name.trim().take(1).ifEmpty { "♪" }
        Text(initial, color = Color(0xFF2E2A24).copy(alpha = 0.8f), fontSize = (size.value * 0.34f).sp, fontFamily = InkTitleFont)
    }
}

/** 分区标题（左标题 + 右操作） */
@Composable
fun SectionHeader(title: String, action: String? = null, onAction: (() -> Unit)? = null, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    Row(
        modifier = modifier.fillMaxWidth().padding(bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = p.text, fontFamily = InkTitleFont)
        Spacer(Modifier.weight(1f))
        if (action != null) {
            Text(
                action,
                fontSize = 12.sp,
                color = p.text3,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .then(if (onAction != null) Modifier.clickable { onAction() } else Modifier)
                    .padding(horizontal = 6.dp, vertical = 3.dp)
            )
        }
    }
}

/** 一行歌曲（表格主体）：序号/封面/歌名/歌手/专辑/时长/平台/收藏/下载 */
@Composable
fun SongTableRow(
    index: Int,
    song: Song,
    playing: Boolean,
    favored: Boolean,
    showAlbum: Boolean = true,
    onPlay: () -> Unit,
    onToggleFavorite: () -> Unit,
    onDownload: (() -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null
) {
    val p = LocalPalette.current
    HoverRow(modifier = Modifier.fillMaxWidth().height(56.dp), onClick = onPlay, onDoubleClick = onPlay) { hovered ->
        Row(
            modifier = Modifier.fillMaxSize().padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(Modifier.width(34.dp), contentAlignment = Alignment.Center) {
                if (hovered || playing) {
                    Icon(
                        Icons.Filled.PlayArrow,
                        contentDescription = "播放",
                        tint = if (playing) p.heartOn else p.text,
                        modifier = Modifier.size(18.dp)
                    )
                } else {
                    Text(
                        if (index > 0) index.toString().padStart(2, '0') else "—",
                        fontSize = 12.sp,
                        color = p.text3
                    )
                }
            }
            SongCover(song, 38.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(2.2f)) {
                Text(
                    song.name,
                    fontSize = 14.sp,
                    color = if (playing) p.heartOn else p.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    fontWeight = if (playing) FontWeight.Medium else FontWeight.Normal
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    song.singer,
                    fontSize = 11.5.sp,
                    color = p.text3,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            if (showAlbum) {
                Text(
                    song.album.ifBlank { "—" },
                    fontSize = 12.sp,
                    color = p.text3,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1.6f).padding(end = 8.dp)
                )
            }
            Text(song.durationText, fontSize = 12.sp, color = p.text3, modifier = Modifier.width(52.dp))
            Box(Modifier.width(56.dp), contentAlignment = Alignment.Center) { PlatformTag(song.platform, compact = true) }
            Icon(
                if (favored) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                contentDescription = "收藏",
                tint = if (favored) p.heartOn else p.text3,
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .clickable { onToggleFavorite() }
                    .padding(6.dp)
            )
            if (onDownload != null) {
                // 点一下 → 直接弹"音质选择"浮层（浮层画在主窗口里，不另开窗口）
                Icon(
                    androidx.compose.material.icons.Icons.Filled.Download,
                    contentDescription = "下载",
                    tint = p.text3,
                    modifier = Modifier
                        .size(28.dp)
                        .clip(CircleShape)
                        .handCursor()
                        .clickable { com.jz.musichelper.ui.desktop.DeskDownloadBus.ask(song) }
                        .padding(6.dp)
                )
            }
            trailing?.invoke()
        }
    }
}

/** 表头（和 SongTableRow 对齐） */
@Composable
fun TableHeader(showAlbum: Boolean = true) {
    val p = LocalPalette.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text("#", fontSize = 11.sp, color = p.text3, modifier = Modifier.width(34.dp))
        Spacer(Modifier.width(38.dp + 12.dp))
        Text("歌曲", fontSize = 11.sp, color = p.text3, modifier = Modifier.weight(2.2f))
        if (showAlbum) Text("专辑", fontSize = 11.sp, color = p.text3, modifier = Modifier.weight(1.6f))
        Text("时长", fontSize = 11.sp, color = p.text3, modifier = Modifier.width(52.dp))
        Text("来源", fontSize = 11.sp, color = p.text3, modifier = Modifier.width(56.dp))
        Spacer(Modifier.width(28.dp))
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(DeskColors.rowDivider))
}

/** 空态：一句话 + 一句补充 */
@Composable
fun EmptyHint(title: String, desc: String = "", modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    Column(
        modifier = modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(Icons.Filled.MusicNote, contentDescription = null, tint = p.text3.copy(alpha = 0.5f), modifier = Modifier.size(38.dp))
        Spacer(Modifier.height(10.dp))
        Text(title, fontSize = 14.sp, color = p.text2)
        if (desc.isNotBlank()) {
            Spacer(Modifier.height(6.dp))
            Text(desc, fontSize = 12.sp, color = p.text3)
        }
    }
}

/** 圆角小按钮（墨底/纸底两种） */
@Composable
fun InkButton(
    text: String,
    primary: Boolean = true,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    val p = LocalPalette.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val bg = when {
        !enabled -> p.surface2
        primary -> p.accent
        else -> Color.Transparent
    }
    val fg = when {
        !enabled -> p.text3
        primary -> Color(0xFFF7F5F0)
        else -> p.text2
    }
    val scale by androidx.compose.animation.core.animateFloatAsState(
        targetValue = if (pressed) 0.96f else 1f,
        animationSpec = tween(80),
        label = "btnScale"
    )
    Box(
        modifier = modifier
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .clip(RoundedCornerShape(8.dp))
            .background(if (pressed && primary) p.accent2 else bg)
            .then(if (!primary) Modifier.border(1.dp, DeskColors.inkSoft, RoundedCornerShape(8.dp)) else Modifier)
            .then(
                if (enabled) Modifier.handCursor().clickable(interactionSource = interaction, indication = null) { onClick() }
                else Modifier
            )
            .padding(horizontal = 14.dp, vertical = 7.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, fontSize = 12.5.sp, color = fg, fontWeight = FontWeight.Medium)
    }
}

/** 小圆图标按钮 */
@Composable
fun IconAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    desc: String,
    size: Dp = 32.dp,
    tint: Color? = null,
    onClick: () -> Unit
) {
    val p = LocalPalette.current
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .handCursor()
            .clickable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = desc, tint = tint ?: p.text2, modifier = Modifier.size(size * 0.52f))
    }
}

/**
 * 播放进度条：已播（墨）/ 已缓存（灰）/ 未加载（浅纸），可点击与拖动。
 *
 * 缓存段来自 PlayCache —— 整首落盘之前，前端就能看出"哪一段已经在本机"，
 * 拖到缓存段内不会再触发一次取流。
 */
@Composable
fun SeekBar(
    progress: Float,
    buffered: Float,
    modifier: Modifier = Modifier,
    trackHeight: Dp = 4.dp,
    onSeek: (Float) -> Unit
) {
    val p = LocalPalette.current
    var dragging by remember { mutableStateOf(false) }
    var dragFrac by remember { mutableStateOf(0f) }
    val shown = (if (dragging) dragFrac else progress).coerceIn(0f, 1f)
    val buf = buffered.coerceIn(0f, 1f)

    BoxWithConstraints(
        modifier
            .height(20.dp)
            .pointerInput(Unit) {
                detectTapGestures { off ->
                    onSeek((off.x / size.width).coerceIn(0f, 1f))
                }
            }
            .pointerInput(Unit) {
                detectHorizontalDragGestures(
                    onDragStart = { off ->
                        dragging = true
                        dragFrac = (off.x / size.width).coerceIn(0f, 1f)
                    },
                    onHorizontalDrag = { change, _ ->
                        dragFrac = (change.position.x / size.width).coerceIn(0f, 1f)
                    },
                    onDragEnd = {
                        val f = dragFrac
                        dragging = false
                        onSeek(f.coerceIn(0f, 1f))
                    },
                    onDragCancel = { dragging = false }
                )
            },
        contentAlignment = Alignment.Center
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val h = trackHeight.toPx()
            val cy = size.height / 2f
            val w = size.width
            val r = androidx.compose.ui.geometry.CornerRadius(h / 2f, h / 2f)
            fun bar(from: Float, to: Float, color: Color) {
                val x = w * from
                val len = w * (to - from)
                if (len <= 0f) return
                drawRoundRect(color, topLeft = Offset(x, cy - h / 2f), size = Size(len, h), cornerRadius = r)
            }
            bar(0f, 1f, p.text3.copy(alpha = 0.18f))          // 轨道
            bar(0f, buf, p.text3.copy(alpha = 0.45f))         // 已缓存
            bar(0f, shown, p.text.copy(alpha = 0.80f))        // 已播放
            drawCircle(
                color = p.heartOn,
                radius = h * 1.65f,
                center = Offset(w * shown, cy)
            )
        }
    }
}

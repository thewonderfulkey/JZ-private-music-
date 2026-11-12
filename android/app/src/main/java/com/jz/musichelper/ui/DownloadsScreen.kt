package com.jz.musichelper.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jz.musichelper.data.DownloadManager
import com.jz.musichelper.model.DownloadItem
import com.jz.musichelper.model.DownloadStatus
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette

// ===== 下载管理页：行点击进播放页 + 垃圾桶删除本地文件 =====
@Composable
fun DownloadsScreen(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val items by DownloadManager.items.collectAsState()

    Column(modifier = modifier.fillMaxSize()) {
        // 左上角返回按钮 + 标题
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 8.dp, top = 8.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .background(p.accent.copy(alpha = 0.16f), RoundedCornerShape(12.dp))
                    .inkClickable { AppState.tab.value = MainTab.HOME },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "返回",
                    tint = p.accent2,
                    modifier = Modifier.size(22.dp)
                )
            }
            Text(
                "下载管理",
                fontSize = 26.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = InkTitleFont,
                color = p.text,
                modifier = Modifier.padding(start = 8.dp, top = 6.dp)
            )
        }

        if (items.isEmpty()) {
            // v2.1.38：空态淡入 + 自 94% 轻放
            var appeared by remember { mutableStateOf(false) }
            LaunchedEffect(Unit) { appeared = true }
            AnimatedVisibility(
                visible = appeared,
                enter = fadeIn(tween(240)) + scaleIn(initialScale = 0.94f, animationSpec = tween(260)),
                modifier = Modifier.fillMaxSize()
            ) {
                Column(
                    modifier = Modifier.fillMaxSize(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Icon(Icons.Filled.MusicNote, contentDescription = null, modifier = Modifier.size(56.dp), tint = p.text3.copy(alpha = 0.5f))
                    Spacer(Modifier.height(12.dp))
                    Text("还没有下载任务", color = p.text2, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(4.dp))
                    Text("播放页点「下载」选择音质即可", color = p.text3, fontSize = 12.sp)
                }
            }
            return
        }

        // v2.1.18：底部预留 60dp（与首页/歌单页一致），修复最后一项被播放悬浮栏遮挡
        LazyColumn(modifier = Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 60.dp)) {
            item {
                Text(
                    "保存位置：系统媒体库 Music/JZ音乐助手",
                    fontSize = 12.sp,
                    color = p.text3,
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 6.dp)
                )
            }
            items(items, key = { it.id }) { item ->
                // v2.1.38：增删/重排由 animateItem 做淡入淡出 + 位置缓动，避免"那条瞬间消失、下面全体跳位"
                Box(modifier = Modifier.animateItem()) {
                    DownloadRowDark(item)
                }
            }
            item { Spacer(Modifier.height(16.dp)) }
        }
    }
}

@Composable
private fun DownloadRowDark(item: DownloadItem) {
    val p = LocalPalette.current
    // v2.1.38：进度不再逐格跳变——进度条属"恒定运动"，按规范用 linear 推进
    val shownProgress by animateFloatAsState(
        targetValue = item.progress.coerceIn(0f, 1f),
        animationSpec = tween(500, easing = LinearEasing),
        label = "downloadProgress"
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .inkClickable { AppState.openSong(item.song) }
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SongCover(song = item.song, size = 48.dp, corner = 8.dp)
        Spacer(Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(item.song.name, color = p.text, fontSize = 15.sp, fontWeight = FontWeight.Medium, fontFamily = InkTitleFont, maxLines = 1)
                Spacer(Modifier.width(6.dp))
                Text(qualityTag(item.quality), color = p.accent2, fontSize = 10.sp)
            }
            Spacer(Modifier.height(2.dp))
            Text(
                "${item.song.singer} · ${item.status.text()}",
                color = p.text2,   // v2.1.13：歌手行提亮 text3→text2 12→13sp；v2.1.14：加纸色描边
                fontSize = 13.sp,
                maxLines = 1,
                style = TextStyle(shadow = Shadow(Color(0xFFF7F5F0).copy(alpha = 0.85f), Offset(0f, 1f), 3f))
            )
            // v2.1.40：下载完成不再整块硬撤——160ms 收起 + 120ms 淡出，行高平滑回落，下方列表不再整体上跳
            AnimatedVisibility(
                visible = item.status == DownloadStatus.DOWNLOADING || item.status == DownloadStatus.PENDING,
                enter = fadeIn(tween(120)) + expandVertically(tween(160)),
                exit = fadeOut(tween(120)) + shrinkVertically(tween(160)),
                label = "dlProgress"
            ) {
                Column {
                    Spacer(Modifier.height(4.dp))
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(4.dp)
                            .clip(RoundedCornerShape(50))
                            .background(p.surface2)
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(4.dp)
                                // v2.1.40：进度改由 scaleX 驱动——原先 fillMaxWidth(shownProgress) 每帧都在改布局宽度，
                                // 等于每帧重新测量排版；scaleX 只走 GPU，原点靠左所以从左边往右长
                                .graphicsLayer {
                                    scaleX = shownProgress
                                    transformOrigin = TransformOrigin(0f, 0.5f)
                                }
                                .clip(RoundedCornerShape(50))
                                .background(p.accent)
                        )
                    }
                    Spacer(Modifier.height(2.dp))
                    Text(item.progressText, color = p.text3, fontSize = 11.sp)
                }
            }
            if (item.status == DownloadStatus.FAILED) {
                Spacer(Modifier.height(2.dp))
                Text(item.errorMessage ?: "下载失败", color = Color(0xFFC0392B), fontSize = 11.sp, maxLines = 2)
            }
            // v2.1.65：体积校验、换源次数一律留在后端（DownloadItem.note 只落库不展示），
            // 行内只留歌名后的档位标签——每一行都挂两行说明会把列表撑得很高
        }

        // 右侧操作
        // v2.1.40：三种状态位（转圈 / 重试 / 删除）160ms 交叉淡变——原先按状态直接对调，
        // 且「下载完成」那一刻与进度区收起同时发生，两处突变叠加会让整行抖一下
        val actTag = when (item.status) {
            DownloadStatus.DOWNLOADING, DownloadStatus.PENDING -> "spinner"
            DownloadStatus.FAILED -> "retry"
            else -> "delete"
        }
        Box(
            modifier = Modifier.size(40.dp),
            contentAlignment = Alignment.Center
        ) {
            Crossfade(
                targetState = actTag,
                animationSpec = tween(160),
                label = "dlAction"
            ) { tag ->
                when (tag) {
                    "spinner" -> CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        color = p.accent,
                        strokeWidth = 2.dp
                    )
                    "retry" -> Icon(
                        Icons.Filled.Refresh,
                        contentDescription = "重试",
                        tint = p.accent2,
                        modifier = Modifier
                            .size(40.dp)
                            // 行本身已是墨色按压，这里保持原生点击避免叠第二层
                            .clickable { DownloadManager.retry(item.id) }
                            .padding(8.dp)
                    )
                    else -> Icon(
                        Icons.Filled.Delete,
                        contentDescription = "删除本地文件",
                        tint = p.text3,
                        modifier = Modifier
                            .size(40.dp)
                            .clickable {
                                DownloadManager.remove(item.id, deleteFile = item.status == DownloadStatus.COMPLETED)
                                toast("已删除《${item.song.name}》")
                            }
                            .padding(8.dp)
                    )
                }
            }
        }
    }
}

private fun DownloadStatus.text(): String = when (this) {
    DownloadStatus.PENDING -> "等待中"
    DownloadStatus.DOWNLOADING -> "下载中"
    DownloadStatus.COMPLETED -> "已完成"
    DownloadStatus.FAILED -> "失败"
    DownloadStatus.CANCELLED -> "已取消"
}

private fun qualityTag(q: com.jz.musichelper.model.QualityLevel): String = when (q) {
    com.jz.musichelper.model.QualityLevel.STANDARD -> "标准"
    com.jz.musichelper.model.QualityLevel.HIGH -> "高品 320k"
    com.jz.musichelper.model.QualityLevel.LOSSLESS -> "无损"
}

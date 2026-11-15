package com.jz.musichelper.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.scaleIn
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
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jz.musichelper.data.HistoryStore
import com.jz.musichelper.model.Song
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette

// ===== 收藏页：我喜欢的音乐 =====
@Composable
fun FavoritesScreen(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    // 直接读响应式事实源：播放页/悬浮栏/列表增删收藏后，收藏页自动联动
    val favs = HistoryStore.loadFavorites()

    Column(modifier = modifier.fillMaxSize()) {
        // 左上角返回按钮 + 标题（返回首页，用强调色突出）
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 8.dp, top = 8.dp, bottom = 6.dp),
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
                "我喜欢的音乐",
                fontSize = 26.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = InkTitleFont,
                color = p.text,
                modifier = Modifier.padding(start = 8.dp, top = 6.dp)
            )
        }

        if (favs.isEmpty()) {
            // v2.1.38：空态淡入 + 自 94% 轻放，不再硬贴上
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
                    Icon(Icons.Filled.Favorite, contentDescription = null, modifier = Modifier.size(60.dp), tint = p.accent.copy(alpha = 0.45f))
                    Spacer(Modifier.height(14.dp))
                    Text("还没有收藏的歌曲", color = p.text2, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(6.dp))
                    Text("点歌曲右侧 / 播放页的心形即可收藏", color = p.text3, fontSize = 13.sp)
                }
            }
            return
        }

        // v2.1.18：底部预留 60dp（与首页/歌单页一致），修复最后一项被播放悬浮栏遮挡
        LazyColumn(modifier = Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 60.dp)) {
            // 头部大卡：收藏数 + 4 格封面拼贴
            item {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp)
                        .clip(RoundedCornerShape(18.dp))
                        .background(
                            Brush.linearGradient(
                                listOf(p.accent.copy(alpha = 0.22f), p.surface2)
                            )
                        )
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // 4 格封面拼贴
                    Box(modifier = Modifier.size(88.dp)) {
                        val tiles = (favs.take(4) + listOf<Song>()).take(4)
                        tiles.forEachIndexed { i, s ->
                            val size = 40.dp
                            val x = if (i % 2 == 0) 0.dp else 44.dp
                            val y = if (i < 2) 0.dp else 44.dp
                            Box(
                                modifier = Modifier
                                    .padding(start = x, top = y)
                                    .size(size)
                            ) {
                                SongCover(song = s, size = size, corner = 6.dp)
                            }
                        }
                        if (tiles.isEmpty()) {
                            Box(modifier = Modifier.size(88.dp).background(p.surface2, RoundedCornerShape(8.dp)), contentAlignment = Alignment.Center) {
                                Icon(Icons.Filled.MusicNote, contentDescription = null, tint = p.text3, modifier = Modifier.size(32.dp))
                            }
                        }
                    }
                    Spacer(Modifier.width(16.dp))
                    Column {
                        Text("我喜欢的音乐", color = p.text, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                        Spacer(Modifier.height(4.dp))
                        Text("${favs.size} 首 · 收藏即得", color = p.text2, fontSize = 13.sp)
                        Spacer(Modifier.height(8.dp))
                        Box(
                            modifier = Modifier
                                .background(p.accent, RoundedCornerShape(50))
                                .inkClickable { if (favs.isNotEmpty()) AppState.openSong(favs[0], favs) }
                                .padding(horizontal = 14.dp, vertical = 6.dp)
                        ) {
                            Text("播放全部", color = Color(0xFFF7F5F0), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
            }

            items(favs, key = { "${it.platform.name}_${it.platformID}" }) { song ->
                // v2.1.38：取消收藏后那一条淡出、下方缓动归位，而不是瞬间消失+整体跳位
                Box(modifier = Modifier.animateItem()) {
                    DarkSongRow(song = song, queue = favs)
                }
            }
            item { Spacer(Modifier.height(16.dp)) }
        }
    }
}

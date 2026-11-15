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
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jz.musichelper.data.HistoryStore
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette

// ===== 历史页：搜索历史 + 最近查看（点击进播放页）=====
@Composable
fun HistoryScreen(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val searchHistory = HistoryStore.loadSearchHistory()
    val recentSongs = HistoryStore.loadRecentSongs()

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
                "历史",
                fontSize = 26.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = InkTitleFont,
                color = p.text,
                modifier = Modifier.padding(start = 8.dp, top = 6.dp)
            )
        }

        // v2.1.18：底部预留 60dp（与首页/歌单页一致），修复最后一项被播放悬浮栏遮挡
        LazyColumn(modifier = Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 60.dp)) {
            if (searchHistory.isNotEmpty()) {
                item {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 18.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("搜索历史", fontWeight = FontWeight.SemiBold, color = p.text2, modifier = Modifier.weight(1f))
                        TextButton(onClick = { HistoryStore.clearSearchHistory() }) {
                            Text("清空", color = p.text3, fontSize = 13.sp)
                        }
                    }
                }
                items(searchHistory, key = { it.keyword }) { item ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 18.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Filled.Search, contentDescription = null, modifier = Modifier.size(16.dp), tint = p.text3)
                        Spacer(Modifier.width(8.dp))
                        Text(item.keyword, color = p.text2)
                    }
                }
            }

            if (recentSongs.isNotEmpty()) {
                item {
                    Text(
                        "最近查看",
                        fontWeight = FontWeight.SemiBold,
                        color = p.text2,
                        modifier = Modifier.padding(horizontal = 18.dp, vertical = 10.dp)
                    )
                }
                items(recentSongs, key = { "${it.platform.name}_${it.platformID}" }) { song ->
                    // v2.1.38：同收藏页——增删与重排走 animateItem，消除瞬间跳位
                    Box(modifier = Modifier.animateItem()) {
                        DarkSongRow(song = song, queue = recentSongs)
                    }
                }
            }

            if (searchHistory.isEmpty() && recentSongs.isEmpty()) {
                item {
                    // v2.1.38：空态淡入 + 自 94% 轻放
                    var appeared by remember { mutableStateOf(false) }
                    LaunchedEffect(Unit) { appeared = true }
                    AnimatedVisibility(
                        visible = appeared,
                        enter = fadeIn(tween(240)) + scaleIn(initialScale = 0.94f, animationSpec = tween(260))
                    ) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 80.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Icon(Icons.Filled.History, contentDescription = null, modifier = Modifier.size(56.dp), tint = p.text3.copy(alpha = 0.5f))
                            Spacer(Modifier.height(12.dp))
                            Text("暂无历史记录", color = p.text3)
                        }
                    }
                }
            }
        }
    }
}

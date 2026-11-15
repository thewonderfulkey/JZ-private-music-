package com.jz.musichelper.ui.desktop

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jz.musichelper.data.AppEnv
import com.jz.musichelper.data.DownloadManager
import com.jz.musichelper.data.HistoryStore
import com.jz.musichelper.model.DownloadItem
import com.jz.musichelper.model.DownloadStatus
import com.jz.musichelper.model.MusicPlatform
import com.jz.musichelper.model.QualityLevel
import com.jz.musichelper.model.Song
import com.jz.musichelper.network.SearchRanker
import com.jz.musichelper.network.SearchService
import com.jz.musichelper.network.StudioPick
import com.jz.musichelper.ui.AppState
import com.jz.musichelper.ui.EditorPlaylist
import com.jz.musichelper.ui.GuessEngine
import com.jz.musichelper.ui.HomeCache
import com.jz.musichelper.ui.HotMusic
import com.jz.musichelper.ui.DynamicPool
import com.jz.musichelper.ui.SongProfile
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.launch

/** 桌面端轻提示（底部播放条上方浮一条） */
object DeskToast {
    var text by mutableStateOf<String?>(null)
        private set
    private var seq = 0
    fun show(msg: String) {
        text = msg
        seq++
        val mine = seq
        kotlinx.coroutines.MainScope().launch {
            kotlinx.coroutines.delay(2600)
            if (mine == seq) text = null
        }
    }
}

// ============================================================================================
// 发现音乐：编辑精选（海报卡）/ 热门音乐（双列）/ 猜你喜欢（封面网格）
// ============================================================================================

@Composable
fun DiscoverPage(onOpenPlaylist: (EditorPlaylist) -> Unit) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    val recents = HistoryStore.loadRecentSongs()
    val searches = HistoryStore.loadSearchHistory()
    val favs = HistoryStore.loadFavorites()
    val downloads = HistoryStore.loadDownloadItems().map { it.song }

    HomeCache.ensureInit()
    DynamicPool.ensureInit()

    // 只有"当天且非空"的缓存才算命中：空列表是上次加载失败留下的，不能拿它短路掉今天的加载
    var hot by remember {
        mutableStateOf<List<Song>?>(
            HomeCache.loadHot()?.takeIf { it.day == HomeCache.today && it.data.isNotEmpty() }?.data
        )
    }
    var guess by remember {
        mutableStateOf<List<GuessEngine.GuessItem>?>(HomeCache.loadGuess()?.first?.takeIf { it.day == HomeCache.today }?.data)
    }
    var loadingHot by remember { mutableStateOf(hot == null) }

    val editor = remember { EditorPlaylist.forToday() }

    LaunchedEffect(Unit) {
        if (hot == null) {
            loadingHot = true
            val loaded = runCatching { HotMusic.load() }.getOrDefault(emptyList())
            hot = loaded
            loadingHot = false
            if (loaded.isNotEmpty()) {
                HomeCache.persistHot(loaded)
                DynamicPool.markShown(loaded)
            }
        } else {
            loadingHot = false
        }
    }
    LaunchedEffect(recents.size, favs.size, searches.size) {
        if (guess == null) {
            val g = runCatching {
                GuessEngine.recommend(recents, searches, favs, downloads, max = 12, includeExpansion = false)
            }.getOrDefault(emptyList())
            guess = g
            if (g.isNotEmpty()) {
                HomeCache.persistGuess(g, "pc")
                DynamicPool.markShown(g.map { it.song })
            }
        }
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 26.dp, end = 26.dp, top = 6.dp, bottom = 28.dp)
    ) {
        // 顶部标题
        item {
            Column {
                Text("发现音乐", fontSize = 26.sp, color = p.text, fontFamily = InkTitleFont, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(4.dp))
                Text(
                    "四平台并发检索 · 多后端取流兜底 · 逐字歌词",
                    fontSize = 12.sp,
                    color = p.text3
                )
                Spacer(Modifier.height(18.dp))
            }
        }

        // 最近搜索（有才显示）
        if (searches.isNotEmpty()) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("最近搜索", fontSize = 12.sp, color = p.text3)
                    Spacer(Modifier.width(10.dp))
                    searches.take(6).forEach { h ->
                        Text(
                            h.keyword,
                            fontSize = 11.5.sp,
                            color = p.text2,
                            modifier = Modifier
                                .padding(end = 6.dp)
                                .clip(RoundedCornerShape(10.dp))
                                .background(p.surface2)
                                .clickable { AppState.search(h.keyword) }
                                .padding(horizontal = 9.dp, vertical = 4.dp)
                        )
                    }
                }
                Spacer(Modifier.height(18.dp))
            }
        }

        // 编辑精选
        item {
            SectionHeader("编辑精选", "每日换一批")
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                editor.forEach { pl ->
                    EditorPosterCard(pl, modifier = Modifier.weight(1f)) { onOpenPlaylist(pl) }
                }
            }
            Spacer(Modifier.height(26.dp))
        }

        // 热门音乐（双列）
        item {
            SectionHeader("热门音乐", if (loadingHot) "加载中…" else "每日更新")
        }
        val hotList = hot ?: emptyList()
        if (hotList.isEmpty()) {
            item {
                Box(Modifier.fillMaxWidth().height(120.dp)) {
                    EmptyHint(if (loadingHot) "正在获取热门歌曲…" else "热门歌曲暂时取不到", "稍后自动重试，或直接搜索")
                }
                Spacer(Modifier.height(24.dp))
            }
        } else {
            items((hotList.size + 1) / 2) { row ->
                Row(Modifier.fillMaxWidth()) {
                    val left = hotList.getOrNull(row * 2)
                    val right = hotList.getOrNull(row * 2 + 1)
                    Box(Modifier.weight(1f)) {
                        if (left != null) HotSongRow(left, onPlay = { playSongs(hotList, row * 2) })
                    }
                    Spacer(Modifier.width(20.dp))
                    Box(Modifier.weight(1f)) {
                        if (right != null) HotSongRow(right, onPlay = { playSongs(hotList, row * 2 + 1) })
                    }
                }
            }
            item { Spacer(Modifier.height(26.dp)) }
        }

        // 猜你喜欢
        item {
            SectionHeader("猜你喜欢", if (guess.isNullOrEmpty()) "" else "按你的播放与搜索推荐")
        }
        val guessList = guess ?: emptyList()
        if (guessList.isEmpty()) {
            item {
                Box(Modifier.fillMaxWidth().height(110.dp)) {
                    EmptyHint("多搜索、多听几首喜欢的歌", "猜你喜欢会根据播放记录与搜索历史在这里推荐")
                }
            }
        } else {
            items((guessList.size + 4) / 5) { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    for (col in 0 until 5) {
                        val idx = row * 5 + col
                        val item = guessList.getOrNull(idx)
                        Box(Modifier.weight(1f)) {
                            if (item != null) {
                                GuessCard(item) { playSongs(guessList.map { it.song }, idx) }
                            }
                        }
                    }
                }
                Spacer(Modifier.height(16.dp))
            }
        }
    }
}

@Composable
private fun EditorPosterCard(pl: EditorPlaylist, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val p = LocalPalette.current
    val hue = Color(pl.themeColor)
    // 类别色只当"一笔墨"用：纸底上淡淡的染色 + 左侧一道窄色条 + 右下角一个大字水印。
    // 之前是整块高饱和渐变色铺满（暖金/宝蓝/玫红/青绿），和全 App 的水墨纸色完全不在一个体系里。
    val wash = lerp(p.surface, hue, 0.10f)
    val accent = lerp(hue, p.accent, 0.18f)
    val mark = pl.title.take(1)
    HoverRow(
        modifier = modifier.height(112.dp).clip(RoundedCornerShape(10.dp)),
        onClick = onClick
    ) { hovered ->
        Box(
            Modifier
                .fillMaxSize()
                .background(Brush.verticalGradient(listOf(wash, p.surface)))
                .border(
                    width = 1.dp,
                    color = if (hovered) accent.copy(alpha = 0.50f) else p.accent.copy(alpha = 0.10f),
                    shape = RoundedCornerShape(10.dp)
                )
        ) {
            // 右下角大字水印（楷体），像盖在纸上的一个印记
            Text(
                mark,
                fontSize = 54.sp,
                color = accent.copy(alpha = if (hovered) 0.18f else 0.12f),
                fontFamily = InkTitleFont,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 8.dp, bottom = 2.dp)
            )
            // 左侧窄色条：只用来"分家"，不做大色块
            Box(
                Modifier
                    .align(Alignment.CenterStart)
                    .padding(start = 12.dp)
                    .width(3.dp)
                    .height(34.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(accent.copy(alpha = 0.80f))
            )
            Column(
                Modifier
                    .fillMaxSize()
                    .padding(start = 24.dp, end = 14.dp, top = 14.dp, bottom = 14.dp),
                verticalArrangement = Arrangement.Bottom
            ) {
                Text(
                    pl.title,
                    fontSize = 17.sp,
                    color = p.text,
                    fontFamily = InkTitleFont,
                    fontWeight = FontWeight.SemiBold
                )
                Spacer(Modifier.height(4.dp))
                Text("${pl.songs.size} 首 · 点开即播", fontSize = 11.sp, color = p.text3)
            }
        }
    }
}

@Composable
private fun HotSongRow(song: Song, onPlay: () -> Unit) {
    val p = LocalPalette.current
    HoverRow(Modifier.fillMaxWidth().height(62.dp), onClick = onPlay) { hovered ->
        Row(Modifier.fillMaxSize().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box {
                SongCover(song, 44.dp)
                if (hovered) {
                    Box(Modifier.size(44.dp).clip(RoundedCornerShape(6.dp)).background(Color(0x662E2A24)), contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.PlayArrow, contentDescription = "播放", tint = Color.White, modifier = Modifier.size(20.dp))
                    }
                }
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(song.name, fontSize = 13.5.sp, color = p.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(3.dp))
                Text(song.singer, fontSize = 11.5.sp, color = p.text3, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            PlatformTag(song.platform, compact = true)
            Spacer(Modifier.width(10.dp))
            Text(song.durationText, fontSize = 11.5.sp, color = p.text3)
        }
    }
}

@Composable
private fun GuessCard(item: GuessEngine.GuessItem, onClick: () -> Unit) {
    val p = LocalPalette.current
    Column(
        Modifier
            .clip(RoundedCornerShape(10.dp))
            .clickable { onClick() }
            .padding(6.dp)
    ) {
        Box(Modifier.fillMaxWidth().height(132.dp).clip(RoundedCornerShape(8.dp))) {
            SongCover(item.song, 132.dp, modifier = Modifier.fillMaxSize())
        }
        Spacer(Modifier.height(8.dp))
        Text(item.song.name, fontSize = 12.5.sp, color = p.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(2.dp))
        Text(item.song.singer, fontSize = 11.sp, color = p.text3, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** 统一播放入口：把整个列表作为队列 */
fun playSongs(list: List<Song>, index: Int) {
    val song = list.getOrNull(index) ?: return
    com.jz.musichelper.data.PlayLog.log("ui: play row -> ${song.name} (${song.singer})")
    // 主动切歌：先把当前这首停掉（不再让上一首继续响到新歌解析完成）
    com.jz.musichelper.data.PlayerManager.stop()
    AppState.playlist.value = list
    AppState.playIndex.value = index
    AppState.openSong(song, queue = list, allowCrossRetry = true)
}

// ============================================================================================
// 编辑精选歌单详情
// ============================================================================================

@Composable
fun PlaylistPage(pl: EditorPlaylist, onBack: () -> Unit) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    var loadingName by remember { mutableStateOf<String?>(null) }
    val c = Color(pl.themeColor)

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier
                .fillMaxWidth()
                .background(Brush.horizontalGradient(listOf(c.copy(alpha = 0.20f), Color.Transparent)))
                .padding(horizontal = 26.dp, vertical = 20.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text(pl.title, fontSize = 24.sp, color = p.text, fontFamily = InkTitleFont, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(4.dp))
                Text("今日精选 ${pl.songs.size} 首 · 点单曲播放", fontSize = 12.sp, color = p.text3)
            }
            InkButton("返回", primary = false) { onBack() }
        }
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(start = 26.dp, end = 26.dp, bottom = 24.dp)) {
            items(pl.songs.withIndex().toList()) { (idx, pair) ->
                val (name, singer) = pair
                val loading = loadingName == name
                HoverRow(Modifier.fillMaxWidth().height(50.dp), onClick = {
                    if (loading) return@HoverRow
                    loadingName = name
                    scope.launch {
                        try {
                            openEditorEntry(pl, idx, scope)
                        } finally {
                            loadingName = null
                        }
                    }
                }) { hovered ->
                    Row(Modifier.fillMaxSize().padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            (idx + 1).toString().padStart(2, '0'),
                            fontSize = 12.sp,
                            color = p.text3,
                            modifier = Modifier.width(34.dp)
                        )
                        Column(Modifier.weight(1f)) {
                            Text(name, fontSize = 13.5.sp, color = p.text)
                            Spacer(Modifier.height(2.dp))
                            Text(singer, fontSize = 11.sp, color = p.text3)
                        }
                        if (loading) {
                            androidx.compose.material3.CircularProgressIndicator(
                                modifier = Modifier.size(14.dp), color = p.text3, strokeWidth = 1.5.dp
                            )
                        } else if (hovered) {
                            Icon(Icons.Filled.PlayArrow, contentDescription = "播放", tint = p.text2, modifier = Modifier.size(18.dp))
                        }
                    }
                }
            }
        }
    }
}

/** 编辑精选点歌：先按"歌名+歌手"搜，再挑原唱版本，播当前并后台补齐整个歌单队列 */
private suspend fun openEditorEntry(pl: EditorPlaylist, idx: Int, scope: CoroutineScope) {
    val (name, singer) = pl.songs[idx]
    val kw = "$name $singer"
    val results = runCatching { SearchService.searchAll(kw, 30) }.getOrDefault(emptyList())
    val pool = results.flatMap { it.songs }.distinctBy { "${it.platform.name}_${it.platformID}" }
    val ranked = SearchRanker.rank(kw, pool)
    val hits = ranked.filter { it.name.contains(name, ignoreCase = true) || name.contains(it.name, ignoreCase = true) }
    val first = StudioPick.pickBest(hits) ?: ranked.firstOrNull()
    if (first == null) {
        DeskToast.show("未找到《$name》的可播放版本")
        return
    }
    playSongs(listOf(first), 0)
    scope.launch {
        val tasks = pl.songs.mapIndexed { i, (n, s) ->
            i to async {
                if (i == idx) first
                else runCatching {
                    val r = SearchService.searchAll("$n $s", 30)
                    val pp = r.flatMap { it.songs }.distinctBy { "${it.platform.name}_${it.platformID}" }
                    val rk = SearchRanker.rank("$n $s", pp)
                    StudioPick.pickBest(rk.filter { it.name.contains(n, ignoreCase = true) || n.contains(it.name, ignoreCase = true) })
                }.getOrNull()
            }
        }
        val best = tasks.map { (i, d) -> i to runCatching { d.await() }.getOrNull() }.toMap()
        val ordered = pl.songs.indices.mapNotNull { i -> best[i] }
        if (ordered.isNotEmpty()) {
            val playIdx = ordered.indexOfFirst { it.platform == first.platform && it.platformID == first.platformID }
            AppState.replaceQueue(ordered, if (playIdx >= 0) playIdx else 0)
        }
    }
}

// ============================================================================================
// 搜索结果
// ============================================================================================

@Composable
fun SearchPage(onPlayAll: (List<Song>, Int) -> Unit) {
    val p = LocalPalette.current
    val results = AppState.searchResults.value
    val searching = AppState.searching.value
    val keyword = AppState.searchKeyword.value
    var filter by remember { mutableStateOf<MusicPlatform?>(null) }

    val all = remember(results) { results.flatMap { r -> r.songs.map { r.platform to it } }.map { it.second } }
    val shown = if (filter == null) all else all.filter { it.platform == filter }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 26.dp, end = 26.dp, top = 16.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    if (keyword.isBlank()) "搜索结果" else "「$keyword」的搜索结果",
                    fontSize = 22.sp,
                    color = p.text,
                    fontFamily = InkTitleFont,
                    fontWeight = FontWeight.SemiBold
                )
                Spacer(Modifier.height(3.dp))
                Text(
                    if (searching) "四平台并发检索中…" else "共 ${all.size} 首 · 已隐藏无音源条目",
                    fontSize = 11.5.sp,
                    color = p.text3
                )
            }
            if (shown.isNotEmpty()) {
                InkButton("播放全部") { playSongs(shown, 0) }
            }
        }

        // 平台筛选
        Row(Modifier.padding(horizontal = 26.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip("全部", filter == null) { filter = null }
            MusicPlatform.entries.forEach { pf ->
                val n = results.firstOrNull { it.platform == pf }?.songs?.size ?: 0
                FilterChip("${pf.shortName} $n", filter == pf) { filter = pf }
            }
        }
        TableHeader()
        Box(Modifier.weight(1f)) {
            when {
                searching && all.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    androidx.compose.material3.CircularProgressIndicator(color = p.text2, strokeWidth = 2.dp)
                }
                shown.isEmpty() -> EmptyHint("没有找到可播放的结果", "换个关键词试试，或检查网络")
                else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 12.dp)) {
                    itemsIndexed(shown) { i, song ->
                        SongTableRow(
                            index = i + 1,
                            song = song,
                            playing = AppState.lastSong.value?.let { it.platform == song.platform && it.platformID == song.platformID } == true,
                            favored = HistoryStore.isFavorite(song),
                            onPlay = { playSongs(shown, i) },
                            onToggleFavorite = { HistoryStore.toggleFavorite(song) },
                            onDownload = { DeskToast.show("在右侧正在播放面板里选择音质下载") }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FilterChip(text: String, selected: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    Text(
        text,
        fontSize = 11.5.sp,
        color = if (selected) Color(0xFFF7F5F0) else p.text2,
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) p.accent else p.surface2)
            .clickable { onClick() }
            .padding(horizontal = 11.dp, vertical = 5.dp)
    )
}

// ============================================================================================
// 我喜欢的
// ============================================================================================

@Composable
fun FavoritesPage() {
    val p = LocalPalette.current
    val favs = HistoryStore.favoritesState
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 26.dp, end = 26.dp, top = 16.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text("我喜欢的音乐", fontSize = 22.sp, color = p.text, fontFamily = InkTitleFont, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(3.dp))
                Text("${favs.size} 首 · 点击红心可取消", fontSize = 11.5.sp, color = p.text3)
            }
            if (favs.isNotEmpty()) InkButton("播放全部") { playSongs(favs.toList(), 0) }
        }
        if (favs.isEmpty()) {
            EmptyHint("还没有收藏的歌", "在任意列表点红心，就会出现在这里")
        } else {
            TableHeader()
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 12.dp)) {
                itemsIndexed(favs.toList()) { i, song ->
                    SongTableRow(
                        index = i + 1,
                        song = song,
                        playing = AppState.lastSong.value?.let { it.platform == song.platform && it.platformID == song.platformID } == true,
                        favored = true,
                        onPlay = { playSongs(favs.toList(), i) },
                        onToggleFavorite = { HistoryStore.toggleFavorite(song) }
                    )
                }
            }
        }
    }
}

// ============================================================================================
// 下载管理
// ============================================================================================

@Composable
fun DownloadsPage() {
    val p = LocalPalette.current
    val dlItems by DownloadManager.items.collectAsState()
    var menuFor by remember { mutableStateOf<String?>(null) }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 26.dp, end = 26.dp, top = 16.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text("下载管理", fontSize = 22.sp, color = p.text, fontFamily = InkTitleFont, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(3.dp))
                Text(
                    "保存在 " + AppEnv.downloadDir.absolutePath,
                    fontSize = 11.5.sp,
                    color = p.text3,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            InkButton("更改下载位置", primary = false) { pickDownloadDir() }
            Spacer(Modifier.width(10.dp))
            InkButton("打开下载目录", primary = false) { AppEnv.openDir(AppEnv.downloadDir) }
        }
        if (dlItems.isEmpty()) {
            EmptyHint("还没有下载任务", "在歌曲上右键或点击下载按钮，选择音质即可")
        } else {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 26.dp, end = 26.dp, bottom = 16.dp)) {
                items(dlItems, key = { it.id }) { item ->
                    DownloadRow(item, menuOpen = menuFor == item.id, onMenu = { menuFor = if (menuFor == item.id) null else item.id })
                }
            }
        }
    }
}

@Composable
private fun DownloadRow(item: DownloadItem, menuOpen: Boolean, onMenu: () -> Unit) {
    val p = LocalPalette.current
    Column(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(p.surface)
            .padding(12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SongCover(item.song, 46.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(item.song.name, fontSize = 13.5.sp, color = p.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Spacer(Modifier.width(8.dp))
                    PlatformTag(item.song.platform, compact = true)
                    Spacer(Modifier.width(6.dp))
                    Text(item.quality.displayName, fontSize = 10.5.sp, color = p.text3)
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    when (item.status) {
                        DownloadStatus.COMPLETED -> "已完成 · " + (item.note ?: item.sizeText)
                        DownloadStatus.FAILED -> "失败 · " + (item.errorMessage ?: "未知原因")
                        DownloadStatus.CANCELLED -> "已取消"
                        else -> "下载中 ${item.progressText}" + (if (item.sizeText.isNotEmpty()) " · ${item.sizeText}" else "")
                    },
                    fontSize = 11.sp,
                    color = when (item.status) {
                        DownloadStatus.FAILED -> Color(0xFF9A4A24)
                        DownloadStatus.COMPLETED -> p.text3
                        else -> p.text2
                    },
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
                if (item.status == DownloadStatus.DOWNLOADING || item.status == DownloadStatus.PENDING) {
                    Spacer(Modifier.height(6.dp))
                    Box(Modifier.fillMaxWidth().height(3.dp).clip(CircleShape).background(p.text3.copy(alpha = 0.2f))) {
                        Box(
                            Modifier
                                .fillMaxWidth(item.progress.coerceIn(0f, 1f))
                                .height(3.dp)
                                .background(p.heartOn)
                        )
                    }
                }
            }
            Spacer(Modifier.width(10.dp))
            // 直接删除（含文件），不用再点三点菜单
            Icon(
                Icons.Filled.Delete,
                contentDescription = "删除（含文件）",
                tint = p.text3,
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .handCursor()
                    .clickable {
                        runCatching { DownloadManager.remove(item.id, deleteFile = true) }
                        DeskToast.show("已删除《${item.song.name}》")
                    }
                    .padding(6.dp)
            )
            Spacer(Modifier.width(4.dp))
            Box {
                Icon(
                    Icons.Filled.MoreVert,
                    contentDescription = "更多",
                    tint = p.text3,
                    modifier = Modifier.size(28.dp).clip(CircleShape).handCursor().clickable { onMenu() }.padding(6.dp)
                )
                DropdownMenu(expanded = menuOpen, onDismissRequest = { onMenu() }) {
                    if (item.status == DownloadStatus.COMPLETED) {
                        DropdownMenuItem(
                            text = { Text("打开所在文件夹", fontSize = 12.5.sp) },
                            onClick = {
                                item.localPath?.let { path ->
                                    AppEnv.openDir(java.io.File(path).parentFile ?: AppEnv.downloadDir)
                                }
                                onMenu()
                            }
                        )
                    }
                    if (item.status == DownloadStatus.FAILED || item.status == DownloadStatus.CANCELLED) {
                        DropdownMenuItem(
                            text = { Text("重新下载", fontSize = 12.5.sp) },
                            onClick = { DownloadManager.retry(item.id); onMenu() }
                        )
                    }
                    DropdownMenuItem(
                        text = { Text("删除记录" + if (item.status == DownloadStatus.COMPLETED) "（含文件）" else "", fontSize = 12.5.sp) },
                        onClick = { DownloadManager.remove(item.id, deleteFile = true); onMenu() }
                    )
                }
            }
        }
    }
}

// ============================================================================================
// 最近播放
// ============================================================================================

@Composable
fun HistoryPage(onSearch: (String) -> Unit) {
    val p = LocalPalette.current
    val recents = HistoryStore.loadRecentSongs()
    val searches = HistoryStore.loadSearchHistory()

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 26.dp, end = 26.dp, top = 16.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text("最近播放", fontSize = 22.sp, color = p.text, fontFamily = InkTitleFont, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(3.dp))
                Text("最近 ${recents.size} 首 · 搜索历史 ${searches.size} 条", fontSize = 11.5.sp, color = p.text3)
            }
            if (recents.isNotEmpty()) InkButton("全部播放") { playSongs(recents, 0) }
        }

        if (searches.isNotEmpty()) {
            Row(
                Modifier.padding(horizontal = 26.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("搜索历史", fontSize = 11.5.sp, color = p.text3)
                Spacer(Modifier.width(10.dp))
                searches.take(8).forEach { h ->
                    Text(
                        h.keyword,
                        fontSize = 11.5.sp,
                        color = p.text2,
                        modifier = Modifier
                            .padding(end = 6.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(p.surface2)
                            .clickable { onSearch(h.keyword) }
                            .padding(horizontal = 9.dp, vertical = 4.dp)
                    )
                }
                Spacer(Modifier.weight(1f))
                Text(
                    "清空",
                    fontSize = 11.sp,
                    color = p.text3,
                    modifier = Modifier.clip(RoundedCornerShape(6.dp))
                        .clickable { HistoryStore.clearSearchHistory(); DeskToast.show("已清空搜索历史") }
                        .padding(horizontal = 6.dp, vertical = 3.dp)
                )
            }
        }

        if (recents.isEmpty()) {
            EmptyHint("还没有播放记录", "听过的歌会自动出现在这里")
        } else {
            TableHeader()
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 12.dp)) {
                itemsIndexed(recents) { i, song ->
                    SongTableRow(
                        index = i + 1,
                        song = song,
                        playing = AppState.lastSong.value?.let { it.platform == song.platform && it.platformID == song.platformID } == true,
                        favored = HistoryStore.isFavorite(song),
                        onPlay = { playSongs(recents, i) },
                        onToggleFavorite = { HistoryStore.toggleFavorite(song) }
                    )
                }
            }
        }
    }
}

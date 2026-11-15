package com.jz.musichelper.ui.desktop

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Lyrics
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material.icons.filled.Whatshot
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jz.musichelper.data.DesktopLyrics
import com.jz.musichelper.data.HistoryStore
import com.jz.musichelper.data.PlayCache
import com.jz.musichelper.data.PlayerManager
import com.jz.musichelper.model.PlayMode
import com.jz.musichelper.network.LyricLine
import com.jz.musichelper.network.LyricsService
import com.jz.musichelper.ui.AppState
import com.jz.musichelper.ui.MainTab
import com.jz.musichelper.ui.theme.InkBrushFont
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette
import kotlinx.coroutines.delay

/**
 * 回车提交搜索的总线：窗口级 onPreviewKeyEvent 拿到的回车交给它
 * "下载这首歌"的请求总线。
 * 行内下载按钮只负责发请求，由 DesktopShell 在主窗口里画音质浮层——
 * 避免 Compose 的 DropdownMenu 另开系统窗口（那个弹窗在桌面版既截不到图，也容易在关闭时触发 AWT 关停）。
 */
object DeskDownloadBus {
    var target by androidx.compose.runtime.mutableStateOf<com.jz.musichelper.model.Song?>(null)
        private set
    fun ask(song: com.jz.musichelper.model.Song) { target = song }
    fun clear() { target = null }
}

object SearchBus {
    @Volatile
    var onSubmit: (() -> Unit)? = null

    fun submit(): Boolean {
        val f = onSubmit ?: return false
        f()
        return true
    }
}

/** PC 端左侧导航 */
enum class NavKey(val label: String, val icon: ImageVector) {
    DISCOVER("发现音乐", Icons.Filled.Whatshot),
    SEARCH("搜索结果", Icons.Filled.Search),
    FAVORITES("我喜欢的", Icons.Filled.Favorite),
    DOWNLOADS("下载管理", Icons.Filled.Download),
    HISTORY("最近播放", Icons.Filled.History),
    SETTINGS("设置", Icons.Filled.Settings)
}

/** 启动页：默认「发现音乐」；设 `JZ_START_PAGE=settings|downloads|favorites|history|search` 可直接落到某一页（截图/排障用） */
private fun initialNav(): NavKey = when (System.getenv("JZ_START_PAGE")?.trim()?.lowercase()) {
    "settings" -> NavKey.SETTINGS
    "downloads" -> NavKey.DOWNLOADS
    "favorites" -> NavKey.FAVORITES
    "history" -> NavKey.HISTORY
    "search" -> NavKey.SEARCH
    else -> NavKey.DISCOVER
}

/**
 * PC 版外壳：左侧导航 + 顶部搜索栏 + 宽内容区 + 右侧正在播放/歌词 + 底部播放条。
 *
 * 结构对齐网易云 / QQ 音乐 / 酷狗 PC 客户端：所有操作都不离开这一屏，
 * 而不再是一个"手机竖屏窗口"。
 */
@Composable
fun DesktopShell() {
    val p = LocalPalette.current
    var nav by remember { mutableStateOf(initialNav()) }
    var panelOpen by remember { mutableStateOf(true) }
    val song = AppState.lastSong.value
    val playingUrl by PlayerManager.currentUrl.collectAsState()
    val playing = playingUrl != null && PlayerManager.isPlaying.collectAsState().value

    // 搜索结果出来时自动切到搜索页
    LaunchedEffect(AppState.searching.value, AppState.searchResults.value) {
        if (AppState.searchActive.value) nav = NavKey.SEARCH
    }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().background(p.bgTop)) {
            Row(Modifier.weight(1f)) {
                Sidebar(nav, onNav = { nav = it })
                Column(Modifier.weight(1f).fillMaxHeight().background(p.bgBottom)) {
                    TopBar(
                        onSearch = { kw ->
                            AppState.search(kw)
                            nav = NavKey.SEARCH
                        },
                        panelOpen = panelOpen,
                        onTogglePanel = { panelOpen = !panelOpen },
                        onOpenSettings = { com.jz.musichelper.data.JzLog.i("JZ_NAV", "gear -> settings"); nav = NavKey.SETTINGS }
                    )
                    Row(Modifier.weight(1f).fillMaxWidth()) {
                        Box(Modifier.weight(1f).fillMaxHeight()) {
                            when (nav) {
                                NavKey.DISCOVER -> DiscoverPage(onOpenPlaylist = { AppState.openPlaylist.value = it })
                                NavKey.SEARCH -> SearchPage(onPlayAll = { _, _ -> })
                                NavKey.FAVORITES -> FavoritesPage()
                                NavKey.DOWNLOADS -> DownloadsPage()
                                NavKey.HISTORY -> HistoryPage(onSearch = { kw ->
                                    AppState.search(kw); nav = NavKey.SEARCH
                                })
                                NavKey.SETTINGS -> {
                                    com.jz.musichelper.data.JzLog.i("JZ_NAV", "rendering SettingsPage")
                                    SettingsPage()
                                }
                            }
                            // 编辑精选歌单：以覆盖层方式打开（不打断导航位置）
                            val openPl = AppState.openPlaylist.value
                            if (openPl != null) {
                                Box(Modifier.fillMaxSize().background(p.bgBottom)) {
                                    PlaylistPage(openPl) { AppState.openPlaylist.value = null }
                                }
                            }
                        }
                        AnimatedVisibility(visible = panelOpen) {
                            NowPlayingPanel(
                                onClose = { panelOpen = false },
                                onOpenDownload = { nav = NavKey.DOWNLOADS }
                            )
                        }
                    }
                }
            }
            BottomPlayerBar(
                song = song,
                playing = playing,
                onOpenPanel = { panelOpen = true },
                onTogglePlay = { PlayerManager.toggle() },
                onPrev = {
                    com.jz.musichelper.data.PlayLog.log("ui: prev (mode=${AppState.playMode.value})")
                    PlayerManager.stop(); AppState.prevSong()
                },
                onNext = {
                    com.jz.musichelper.data.PlayLog.log("ui: next (mode=${AppState.playMode.value})")
                    PlayerManager.stop(); AppState.nextSong()
                }
            )
        }
        // 轻提示浮在底部播放条上方
        DeskToastHost(Modifier.align(Alignment.BottomCenter).padding(bottom = 92.dp))
        // 音质选择浮层（点下载后出现，直接选档 → 开下）
        DeskDownloadBus.target?.let { target ->
            QualityOverlay(target) { DeskDownloadBus.clear() }
        }
        // 选下载目录：应用内自绘的纸墨风文件夹选择器（替代系统 JFileChooser）
        if (DirPicker.open) DirPickerOverlay()
    }
}

/** 音质选择：画在主窗口里的一层浮层（不另开系统窗口） */
@Composable
private fun QualityOverlay(song: com.jz.musichelper.model.Song, onDismiss: () -> Unit) {
    val p = LocalPalette.current
    val levels = com.jz.musichelper.model.QualityLevel.entries
    // 半透明遮罩：点空白处关闭
    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0x33000000))
            .handCursor()
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { onDismiss() },
        contentAlignment = Alignment.Center
    ) {
        Box(
            Modifier
                .width(320.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(p.surface)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { }
                .padding(20.dp)
        ) {
            Column {
                Text("选择音质下载", fontSize = 15.sp, color = p.text, fontWeight = FontWeight.Medium)
                Spacer(Modifier.height(2.dp))
                Text(
                    "${song.name} · ${song.singer}",
                    fontSize = 11.5.sp,
                    color = p.text3,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Spacer(Modifier.height(14.dp))
                levels.forEach { q ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(9.dp))
                            .handCursor()
                            .clickable {
                                com.jz.musichelper.data.JzLog.i("JZ_DLM", "overlay row click q=$q")
                                onDismiss()
                                runCatching {
                                    com.jz.musichelper.data.DownloadManager.startDownload(song, q) { msg ->
                                        DeskToast.show(msg)
                                    }
                                }.onFailure { DeskToast.show("下载失败：${it.message}") }
                            }
                            .padding(horizontal = 12.dp, vertical = 11.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(q.displayName, fontSize = 13.sp, color = p.text)
                        Spacer(Modifier.weight(1f))
                        Text("→", fontSize = 13.sp, color = p.text3)
                    }
                }
                Spacer(Modifier.height(6.dp))
                Text("取消", fontSize = 12.sp, color = p.text3, modifier = Modifier.handCursor().clickable {
                    com.jz.musichelper.data.JzLog.i("JZ_DLM", "overlay cancel")
                    onDismiss()
                })
            }
        }
    }
}

/** 底部浮出的一句话提示 */
@Composable
fun DeskToastHost(modifier: Modifier = Modifier) {
    val msg = DeskToast.text ?: return
    val p = LocalPalette.current
    Box(modifier, contentAlignment = Alignment.Center) {
        Text(
            msg,
            fontSize = 12.5.sp,
            color = Color(0xFFF7F5F0),
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .background(p.accent.copy(alpha = 0.94f))
                .padding(horizontal = 16.dp, vertical = 9.dp)
        )
    }
}

@Composable
private fun Sidebar(nav: NavKey, onNav: (NavKey) -> Unit) {
    val p = LocalPalette.current
    val dlOn by DesktopLyrics.enabled.collectAsState()
    Column(
        Modifier
            .width(196.dp)
            .fillMaxHeight()
            .background(
                androidx.compose.ui.graphics.Brush.verticalGradient(
                    listOf(DeskColors.sidebarTop, DeskColors.sidebarBottom)
                )
            )
            .padding(horizontal = 12.dp, vertical = 16.dp)
    ) {
        // 品牌区
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 8.dp)) {
            Box(
                Modifier.size(6.dp).background(p.heartOn, RoundedCornerShape(1.dp))
            )
            Spacer(Modifier.width(8.dp))
            Column {
                Text("JZ Music", fontSize = 17.sp, color = p.text, fontFamily = InkTitleFont, fontWeight = FontWeight.SemiBold)
                Text("PC · 水墨版", fontSize = 10.sp, color = p.text3, fontFamily = InkBrushFont)
            }
        }
        Spacer(Modifier.height(26.dp))

        listOf(
            NavKey.DISCOVER, NavKey.SEARCH, NavKey.FAVORITES,
            NavKey.DOWNLOADS, NavKey.HISTORY
        ).forEach { key ->
            NavItem(key, selected = nav == key) { onNav(key) }
        }

        Spacer(Modifier.weight(1f))

        // 桌面歌词开关（悬浮字幕）
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .clickable { com.jz.musichelper.data.JzLog.i("JZ_NAV", "sidebar -> toggle lyrics"); DesktopLyrics.toggleFromUi(!dlOn) }
                .padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Filled.Lyrics,
                contentDescription = null,
                tint = if (dlOn) p.heartOn else p.text3,
                modifier = Modifier.size(16.dp)
            )
            Spacer(Modifier.width(8.dp))
            Text(
                if (dlOn) "桌面歌词 · 开" else "桌面歌词 · 关",
                fontSize = 12.sp,
                color = if (dlOn) p.text else p.text3
            )
        }
        NavItem(NavKey.SETTINGS, selected = nav == NavKey.SETTINGS) { com.jz.musichelper.data.JzLog.i("JZ_NAV", "sidebar -> settings"); onNav(NavKey.SETTINGS) }
    }
}

@Composable
private fun NavItem(key: NavKey, selected: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    val interaction = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(
                when {
                    selected -> p.accent
                    pressed -> DeskColors.hoverStrong
                    else -> Color.Transparent
                }
            )
            .clickable(interactionSource = interaction, indication = null) { onClick() }
            .padding(horizontal = 10.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            key.icon,
            contentDescription = null,
            tint = if (selected) Color(0xFFF7F5F0) else p.text2,
            modifier = Modifier.size(17.dp)
        )
        Spacer(Modifier.width(10.dp))
        Text(
            key.label,
            fontSize = 13.sp,
            color = if (selected) Color(0xFFF7F5F0) else p.text2,
            fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal
        )
    }
}

@Composable
private fun TopBar(
    onSearch: (String) -> Unit,
    panelOpen: Boolean,
    onTogglePanel: () -> Unit,
    onOpenSettings: () -> Unit
) {
    val p = LocalPalette.current
    var text by remember { mutableStateOf(if (AppState.searchActive.value) AppState.searchKeyword.value else "") }
    androidx.compose.runtime.DisposableEffect(text) {
        SearchBus.onSubmit = { if (text.isNotBlank()) onSearch(text.trim()) }
        onDispose { SearchBus.onSubmit = null }
    }
    val searching = AppState.searching.value
    Row(
        Modifier
            .fillMaxWidth()
            .height(58.dp)
            .padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 前进/后退感：搜索框左侧放回"发现"
        Text(
            "发现音乐",
            fontSize = 13.sp,
            color = p.text2,
            modifier = Modifier.clickable { AppState.searchActive.value = false }.padding(end = 16.dp)
        )
        Box(
            Modifier
                .width(360.dp)
                .height(34.dp)
                .clip(RoundedCornerShape(17.dp))
                .background(p.surface)
                .padding(horizontal = 14.dp),
            contentAlignment = Alignment.CenterStart
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Search, contentDescription = null, tint = p.text3, modifier = Modifier.size(15.dp))
                Spacer(Modifier.width(8.dp))
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                    if (text.isEmpty()) {
                        Text("搜索歌曲、歌手、专辑", fontSize = 12.5.sp, color = p.text3)
                    }
                    BasicTextField(
                        value = text,
                        onValueChange = { text = it },
                        singleLine = true,
                        textStyle = TextStyle(fontSize = 12.5.sp, color = p.text),
                        cursorBrush = SolidColor(p.text),
                        modifier = Modifier.fillMaxWidth().onPreviewKeyEvent { ev ->
                            // 桌面端回车直接搜：BasicTextField 的 imeAction 在 Windows 上不触发 onSearch
                            if (ev.type == KeyEventType.KeyDown &&
                                (ev.key == Key.Enter || ev.key == Key.NumPadEnter)
                            ) {
                                if (text.isNotBlank()) onSearch(text.trim())
                                true
                            } else false
                        },
                        keyboardActions = androidx.compose.foundation.text.KeyboardActions(
                            onSearch = { if (text.isNotBlank()) onSearch(text.trim()) }
                        ),
                        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                            imeAction = androidx.compose.ui.text.input.ImeAction.Search
                        )
                    )
                }
                if (searching) {
                    androidx.compose.material3.CircularProgressIndicator(
                        modifier = Modifier.size(13.dp),
                        color = p.text3,
                        strokeWidth = 1.5.dp
                    )
                }
            }
        }
        Spacer(Modifier.width(10.dp))
        // 显式搜索按钮：桌面上"回车即搜"依赖键盘焦点，给一个点得到的入口更稳
        InkButton("搜索") { if (text.isNotBlank()) onSearch(text.trim()) }
        Spacer(Modifier.weight(1f))
        IconAction(Icons.Filled.Lyrics, "歌词面板", tint = if (panelOpen) p.heartOn else p.text2) { onTogglePanel() }
        Spacer(Modifier.width(4.dp))
        IconAction(Icons.Filled.Settings, "设置") { onOpenSettings() }
    }
}

/** 底部播放条：封面 / 曲名 / 上一首-播放-下一首 / 进度 / 播放模式 / 音量 */
@Composable
private fun BottomPlayerBar(
    song: com.jz.musichelper.model.Song?,
    playing: Boolean,
    onOpenPanel: () -> Unit,
    onTogglePlay: () -> Unit,
    onPrev: () -> Unit,
    onNext: () -> Unit
) {
    val p = LocalPalette.current
    val position by PlayerManager.position.collectAsState()
    val duration by PlayerManager.duration.collectAsState()
    val volume by PlayerManager.volume.collectAsState()
    val cache by PlayCache.state.collectAsState()
    val mode = AppState.playMode.value
    var dragPos by remember { mutableStateOf<Float?>(null) }

    Box(
        Modifier
            .fillMaxWidth()
            .height(78.dp)
            .background(DeskColors.barBg)
    ) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(DeskColors.divider))
        Row(
            Modifier.fillMaxSize().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // 左：当前歌曲
            Row(Modifier.width(280.dp), verticalAlignment = Alignment.CenterVertically) {
                if (song != null) {
                    SongCover(song, 48.dp, corner = 6.dp, modifier = Modifier.clickable { onOpenPanel() })
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            song.name,
                            fontSize = 13.sp,
                            color = p.text,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.clickable { onOpenPanel() }
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            song.singer + " · " + song.platform.shortName,
                            fontSize = 11.sp,
                            color = p.text3,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    val fav = HistoryStore.isFavorite(song)
                    Icon(
                        if (fav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                        contentDescription = "收藏",
                        tint = if (fav) p.heartOn else p.text3,
                        modifier = Modifier
                            .size(28.dp)
                            .clip(CircleShape)
                            .clickable { HistoryStore.toggleFavorite(song) }
                            .padding(6.dp)
                    )
                } else {
                    Text("还没有播放的歌曲", fontSize = 12.sp, color = p.text3)
                }
            }
            Spacer(Modifier.width(14.dp))

            // 中：控制 + 进度
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconAction(Icons.Filled.SkipPrevious, "上一首", 30.dp) { onPrev() }
                    Spacer(Modifier.width(6.dp))
                    Box(
                        Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(p.accent)
                            .clickable { onTogglePlay() },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = if (playing) "暂停" else "播放",
                            tint = Color(0xFFF7F5F0),
                            modifier = Modifier.size(19.dp)
                        )
                    }
                    Spacer(Modifier.width(6.dp))
                    IconAction(Icons.Filled.SkipNext, "下一首", 30.dp) { onNext() }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(fmtTime((position / 1000f)), fontSize = 10.5.sp, color = p.text3, modifier = Modifier.width(40.dp))
                    // 进度条：墨=已播、灰=已缓存（PlayCache）、浅=未加载
                    SeekBar(
                        progress = if (duration > 0) (position.toFloat() / duration).coerceIn(0f, 1f) else 0f,
                        buffered = cache.frac.coerceIn(0f, 1f),
                        modifier = Modifier.weight(1f),
                        onSeek = { frac -> if (duration > 0) PlayerManager.seekTo((frac * duration).toLong()) }
                    )
                    Text(
                        fmtTime(duration / 1000f),
                        fontSize = 10.5.sp,
                        color = p.text3,
                        modifier = Modifier.width(40.dp).padding(start = 6.dp)
                    )
                }
            }
            Spacer(Modifier.width(14.dp))

            // 右：播放模式（按钮，图标+当前模式名）/ 音量
            Row(Modifier.width(215.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.End) {
                // 播放模式：做成按钮（可点、有悬浮/按下反馈），但**保留模式名**——
                // 只放一个图标时"单曲循环/列表循环/随机"三态肉眼分不出来，用户会以为"设了单曲却在顺序播放"
                ModeButton(mode) {
                    AppState.cyclePlayMode()
                    DeskToast.show("播放模式：" + playModeName(AppState.playMode.value))
                }
                // 音量图标：点一下静音/恢复（原来只是个静态图标，点了没反应）
                var lastVol by remember { mutableStateOf(if (volume > 0.02f) volume else 0.7f) }
                Icon(
                    if (volume <= 0.02f) Icons.Filled.VolumeOff else Icons.Filled.VolumeUp,
                    contentDescription = if (volume <= 0.02f) "取消静音" else "静音",
                    tint = p.text3,
                    modifier = Modifier
                        .size(24.dp)
                        .clip(CircleShape)
                        .handCursor()
                        .clickable {
                            if (volume > 0.02f) {
                                lastVol = volume
                                PlayerManager.setVolume(0f)
                            } else {
                                PlayerManager.setVolume(lastVol)
                            }
                        }
                        .padding(4.dp)
                )
                Slider(
                    value = volume,
                    onValueChange = { PlayerManager.setVolume(it) },
                    colors = SliderDefaults.colors(
                        thumbColor = p.text2,
                        activeTrackColor = p.text3,
                        inactiveTrackColor = p.text3.copy(alpha = 0.22f)
                    ),
                    modifier = Modifier.width(86.dp).height(22.dp)
                )
            }
        }
    }
}

/** 播放模式的中文名（底部条、播放页共用同一套文案） */
private fun playModeName(m: PlayMode): String = when (m) {
    PlayMode.LIST_LOOP -> "列表循环"
    PlayMode.SINGLE_LOOP -> "单曲循环"
    PlayMode.SHUFFLE -> "随机播放"
}

private fun playModeIcon(m: PlayMode): androidx.compose.ui.graphics.vector.ImageVector = when (m) {
    PlayMode.LIST_LOOP -> Icons.Filled.Repeat
    PlayMode.SINGLE_LOOP -> Icons.Filled.RepeatOne
    PlayMode.SHUFFLE -> Icons.Filled.Shuffle
}

/**
 * 播放模式按钮：图标 + **当前模式名**。
 *
 * 只放图标时，"单曲循环"和"列表循环"在 12px 上几乎看不出差别，
 * 用户会以为"我已经设成单曲循环了"，实际在列表/随机上——这是真实踩过的误解。
 * 所以按钮保留四个字的模式名，同时给足悬浮/按下反馈，明确"这是个能点的按钮"。
 */
@Composable
private fun ModeButton(mode: PlayMode, onClick: () -> Unit) {
    val p = LocalPalette.current
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val pressed by interaction.collectIsPressedAsState()
    Row(
        modifier = Modifier
            .padding(end = 4.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(
                when {
                    pressed -> DeskColors.hoverStrong
                    hovered -> DeskColors.hover
                    else -> Color.Transparent
                }
            )
            .handCursor()
            .clickable(interactionSource = interaction, indication = null) { onClick() }
            .padding(horizontal = 8.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            playModeIcon(mode),
            contentDescription = playModeName(mode),
            tint = p.text2,
            modifier = Modifier.size(16.dp)
        )
        Spacer(Modifier.width(5.dp))
        Text(playModeName(mode), fontSize = 11.sp, color = p.text2, maxLines = 1)
    }
}

private fun fmtTime(sec: Float): String {    if (sec.isNaN() || sec <= 0f) return "00:00"
    val s = sec.toInt()
    return "%02d:%02d".format(s / 60, s % 60)
}

/**
 * 右侧面板：正在播放（大封面 + 逐字歌词）与播放队列双页签。
 * 这是 PC 客户端最标志性的一块——点开就有"边听边看词"的完整视图。
 */
@Composable
private fun NowPlayingPanel(onClose: () -> Unit, onOpenDownload: () -> Unit) {
    val p = LocalPalette.current
    val song = AppState.lastSong.value
    var tab by remember { mutableStateOf(0) }

    Column(
        Modifier
            .width(342.dp)
            .fillMaxHeight()
            .background(DeskColors.panelBg)
            .padding(14.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (tab == 0) "正在播放" else "播放队列", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = p.text)
            val pm = AppState.playMode.value
            val loops = AppState.loopCount.value
            if (pm == PlayMode.SINGLE_LOOP) {
                Spacer(Modifier.width(8.dp))
                Text(
                    if (loops > 0) "单曲循环 · 已重播 ${loops} 次" else "单曲循环",
                    fontSize = 10.5.sp,
                    color = p.heartOn
                )
            }
            Spacer(Modifier.weight(1f))
            Text(
                if (tab == 0) "队列" else "收起",
                fontSize = 11.5.sp,
                color = p.text3,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .handCursor()
                    .clickable { tab = if (tab == 0) 1 else 0 }
                    .padding(horizontal = 6.dp, vertical = 3.dp)
            )
            Text(
                "关闭",
                fontSize = 11.5.sp,
                color = p.text3,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .handCursor()
                    .clickable { onClose() }
                    .padding(horizontal = 6.dp, vertical = 3.dp)
            )
        }
        Spacer(Modifier.height(12.dp))
        if (song == null) {
            EmptyHint("还没有开始播放", "从任意列表里点一首歌")
            return
        }
        if (tab == 1) {
            QueueList()
            return
        }
        // 大封面
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            SongCover(song, 210.dp, corner = 10.dp)
        }
        Spacer(Modifier.height(14.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(song.name, fontSize = 16.sp, color = p.text, fontFamily = InkTitleFont, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(3.dp))
                Text(song.singer, fontSize = 12.sp, color = p.text3, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            val fav = HistoryStore.isFavorite(song)
            Icon(
                if (fav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                contentDescription = "收藏",
                tint = if (fav) p.heartOn else p.text3,
                modifier = Modifier
                    .size(30.dp)
                    .clip(CircleShape)
                    .clickable { HistoryStore.toggleFavorite(song) }
                    .padding(7.dp)
            )
            var dlMenu by remember { mutableStateOf(false) }
            Box {
                IconAction(Icons.Filled.Download, "下载") { dlMenu = true }
                androidx.compose.material3.DropdownMenu(expanded = dlMenu, onDismissRequest = { dlMenu = false }) {
                    com.jz.musichelper.model.QualityLevel.entries.forEach { q ->
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text(q.displayName, fontSize = 12.5.sp) },
                            onClick = {
                                dlMenu = false
                                com.jz.musichelper.data.DownloadManager.startDownload(song, q) { msg ->
                                    DeskToast.show(msg)
                                }
                            }
                        )
                    }
                }
            }
        }
        Spacer(Modifier.height(10.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(DeskColors.rowDivider))
        Spacer(Modifier.height(8.dp))
        LyricsPanel(song, Modifier.weight(1f))
    }
}

@Composable
private fun LyricsPanel(song: com.jz.musichelper.model.Song, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    var lines by remember(song.platform.name + song.platformID) { mutableStateOf<List<LyricLine>>(emptyList()) }
    var loading by remember(song.platform.name + song.platformID) { mutableStateOf(true) }
    LaunchedEffect(song.platform.name + song.platformID) {
        loading = true
        lines = runCatching { LyricsService.fetch(song) }.getOrNull()?.lines ?: emptyList()
        loading = false
    }
    val position by PlayerManager.position.collectAsState()
    val idx = if (lines.isEmpty()) -1 else LyricsService.indexAt(lines, position)
    val listState = rememberLazyListState()
    // 用户手动滚动/点歌词后，先"按住"一段时间再自动回位；
    // 否则刚滑到想切的那句，就被播放进度拽回当前唱的那句（用户反馈的核心痛点）。
    val holdUntil = remember { mutableStateOf(0L) }
    LaunchedEffect(listState) {
        androidx.compose.runtime.snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            if (scrolling) holdUntil.value = System.currentTimeMillis() + 8000L
        }
    }
    LaunchedEffect(idx) {
        if (idx < 0) return@LaunchedEffect
        // 等用户松手（最多等 8 秒）
        while (System.currentTimeMillis() < holdUntil.value) kotlinx.coroutines.delay(150)
        runCatching { listState.animateScrollToItem((idx - 3).coerceAtLeast(0)) }
    }
    Box(modifier.fillMaxWidth()) {
        when {
            loading -> Text("歌词加载中…", fontSize = 12.sp, color = p.text3, modifier = Modifier.align(Alignment.Center))
            lines.isEmpty() -> Text("暂无歌词", fontSize = 12.sp, color = p.text3, modifier = Modifier.align(Alignment.Center))
            else -> LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                itemsIndexed(lines) { i, line ->
                    val nextStart = lines.getOrNull(i + 1)?.timeMs ?: (line.timeMs + 4_000L)
                    // 当前行：逐字染色（唱过的字墨色、正在唱的字按进度插值）；其它行淡墨
                    val annotated = if (i == idx) {
                        Karaoke.annotate(line, nextStart, position, p.text3.copy(alpha = 0.45f), p.text)
                    } else {
                        androidx.compose.ui.text.AnnotatedString(line.text.ifBlank { " " })
                    }
                    Text(
                        annotated,
                        fontSize = if (i == idx) 14.5.sp else 12.5.sp,
                        color = if (i == idx) p.text else p.text3.copy(alpha = 0.85f),
                        fontWeight = if (i == idx) FontWeight.Medium else FontWeight.Normal,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(6.dp))
                            .clickable {
                                // 点歌词跳转时也给一点缓冲，别立刻被自动回位拽走
                                holdUntil.value = System.currentTimeMillis() + 3000L
                                PlayerManager.seekTo(line.timeMs)
                            }
                            .padding(vertical = 6.dp, horizontal = 4.dp)
                    )
                }
            }
        }
    }
}

@Composable
private fun QueueList() {
    val p = LocalPalette.current
    val queue = AppState.playlist.value
    val index by AppState.playIndex
    if (queue.isEmpty()) {
        EmptyHint("队列是空的", "播放任意歌曲后，这里会显示接下来的顺序")
        return
    }
    LazyColumn(Modifier.fillMaxSize()) {
        itemsIndexed(queue) { i, s ->
            HoverRow(
                modifier = Modifier.fillMaxWidth().height(44.dp),
                onClick = { AppState.openSong(s, queue = queue, allowCrossRetry = true) }
            ) { hovered ->
                Row(Modifier.fillMaxSize().padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        if (i == index) "▶" else (i + 1).toString(),
                        fontSize = 11.sp,
                        color = if (i == index) p.heartOn else p.text3,
                        modifier = Modifier.width(22.dp)
                    )
                    Text(
                        s.name,
                        fontSize = 12.5.sp,
                        color = if (i == index) p.heartOn else p.text,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                    Text(s.singer, fontSize = 11.sp, color = p.text3, maxLines = 1, modifier = Modifier.width(90.dp))
                }
            }
        }
    }
}

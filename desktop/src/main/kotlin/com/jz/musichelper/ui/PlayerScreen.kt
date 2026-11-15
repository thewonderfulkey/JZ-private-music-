package com.jz.musichelper.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.Image
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Lyrics
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jz.musichelper.data.DesktopLyrics
import com.jz.musichelper.data.DownloadManager
import com.jz.musichelper.data.HistoryStore
import com.jz.musichelper.data.PlayerManager
import com.jz.musichelper.model.PlayMode
import com.jz.musichelper.model.QualityLevel
import com.jz.musichelper.model.Song
import com.jz.musichelper.network.LyricLine
import com.jz.musichelper.network.LyricsService
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette
import kotlinx.coroutines.launch

// ===== 正在播放页 v2.1.73（三套版式：手机竖屏基准 / 平板竖屏填满 / 横屏左右式）=====
// ===== v2.1.48 下载弹层口径不变：三档选了就拿，跨源换源 + 拿不到时如实降级 =====
/** 封面块的度量（v2.1.73：原来是一组固定 dp 的 PlayerTier，平板档画心被 392dp 锁死、
 *  屏幕再高也放不大，余量全堆成底部空白；现在画心不再设死上限，只受真实宽高约束）。 */
private data class CoverMetrics(
    val artCap: Dp,      // 画心边长上限；0.dp = 不设上限（吃满可用宽/高）
    val titleSp: TextUnit,
    val titleLh: TextUnit,
    val artistSp: TextUnit,
    val topGap: Dp,
    val hintGap: Dp,
    val titleGap: Dp,
    val artistGap: Dp
)

private val PHONE_COVER = CoverMetrics(258.dp, 32.sp, 35.sp, 12.sp, 32.dp, 22.dp, 4.dp, 30.dp)
private val TABLET_COVER = CoverMetrics(0.dp, 42.sp, 48.sp, 14.sp, 26.dp, 16.dp, 8.dp, 6.dp)

/** 播放页所有视图共享的状态 + 回调（三套版式各取所需） */
private class PlayerUi(
    val song: Song,
    val showLyrics: Boolean,
    val lyrics: List<LyricLine>,
    val lyricsSource: String?,
    val lyricsLoading: Boolean,
    val position: Long,
    val duration: Long,
    val isResolving: Boolean,
    val resolveErr: String?,
    val playerError: String?,
    val srcText: String,
    val onBack: () -> Unit,
    val onSeek: (Long) -> Unit,
    val onToggleLyrics: () -> Unit,
    val onDownload: () -> Unit
)

@Composable
fun PlayerScreen(song: Song, onBack: () -> Unit) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()

    var showLyrics by remember { mutableStateOf(false) }   // 大歌词模式：true=主体区域显示歌词
    var showSheet by remember { mutableStateOf(false) }
    var lyricsLoading by remember { mutableStateOf(true) } // 歌词是否仍在请求中（加载中提示）
    var lyrics by remember { mutableStateOf<List<LyricLine>>(emptyList()) }
    var lyricsSource by remember { mutableStateOf<String?>(null) }
    var isDownloading by remember { mutableStateOf(false) }

    // 取流状态来自全局播放任务（点击/切歌即开始解析，退出播放页也不中断）；本页只消费，不自行发起请求
    val songKey = song.platform.name + song.platformID
    val isResolving = AppState.resolvingSongKey.value == songKey
    val resolveErr = AppState.resolveError.value?.takeIf { it.first == songKey }?.second

    val position by PlayerManager.position.collectAsState()
    val duration by PlayerManager.duration.collectAsState()
    val isPlaying by PlayerManager.isPlaying.collectAsState()
    val playerErrorFlow by PlayerManager.error.collectAsState()
    var dragValue by remember { mutableStateOf<Float?>(null) }

    // 进入/切歌：取流由 AppState 全局任务完成（见 resolveAndPlayIfNeeded），本页不再持有 LaunchedEffect 取流，
    // 避免"退出播放页即取消请求、永远加载不出来"的问题
    // 加载歌词（网易云官方直连 → 网易云搜索精确匹配 → LrcApi 兜底；统一简体）
    LaunchedEffect(song.platform, song.platformID) {
        lyrics = emptyList()
        lyricsSource = null
        // v2.1.84：识曲点「播放」时先用一条占位歌曲把播放页顶出来（platformID 带 __pending__ 前缀），
        // 这条没有真实曲目，别拿它去打三个歌词接口白等；真候选一到，key 变化会重新加载歌词。
        if (song.platformID.startsWith("__pending__:")) {
            lyricsLoading = false
            return@LaunchedEffect
        }
        lyricsLoading = true
        val r = runCatching { LyricsService.fetch(song) }.getOrNull()
        if (r != null && r.lines.isNotEmpty()) {
            lyrics = r.lines
            lyricsSource = r.source
        }
        lyricsLoading = false
    }

    // 外层：不透明主题渐变背景 → 全屏覆盖主界面，杜绝下层内容透出
    // 空白区域拦截点击，防止点击穿透到下层主界面
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFFF1EDE2))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null
            ) { }
    ) {
        // 水墨山水背景（播放页加深版）+ 纸色遮罩：氛围更强，歌词/封面区仍可读
        Image(
            painter = painterRes("drawable/ink_bg_player.jpg"),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize()
        )
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        listOf(
                            Color(0xDBFAF8F3),
                            Color(0x8CFAF8F3),
                            Color(0xD9F1EDE2)
                        )
                    )
                )
        )
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxSize()
                .background(Brush.radialGradient(listOf(p.glow, Color.Transparent), Offset(0.5f, 0f), 900f))
                // 背景保持全屏，内容避开状态栏与系统手势条
                .safeDrawingPadding()
        ) {
        // ===== v2.1.73 三套版式（以手机竖屏为基准）=====
        //  ① 手机竖屏：原版式，一字未动（用户口径「非常完美」）
        //  ② 平板竖屏：列宽随屏放宽、画心吃满可用高与宽，元素纵向铺满、不留大段空白
        //  ③ 横屏（手机 + 平板统一）：左封面（双击出歌词）/ 右交互按钮
        val ui = PlayerUi(
            song = song,
            showLyrics = showLyrics,
            lyrics = lyrics,
            lyricsSource = lyricsSource,
            lyricsLoading = lyricsLoading,
            position = position,
            duration = duration,
            isResolving = isResolving,
            resolveErr = resolveErr,
            playerError = playerErrorFlow,
            srcText = if (AppState.currentSourceSongKey.value == songKey) {
                AppState.currentSource.value?.let { s ->
                    "音源：${s.backendName} · ${s.quality.displayName} · ${s.format}" +
                        (if (s.directId) " · ID 直连" else " · 搜索式已校验")
                } ?: ""
            } else "",
            onBack = onBack,
            onSeek = { PlayerManager.seekTo(it) },
            onToggleLyrics = { showLyrics = !showLyrics },
            onDownload = { showSheet = true }
        )
        when {
            maxWidth > maxHeight -> PlayerLandscape(ui)          // 横屏：左右式
            maxWidth >= 600.dp -> PlayerTablet(ui)               // 平板竖屏：自适应填满
            else -> PlayerPhone(ui)                              // 手机竖屏：基准版式
        }
        }   // 主内容 Box（背景+避让）闭合

        // 下载弹层
        // v2.1.38：不再凭空出现——淡入 + 自下半屏上滑 260ms，退出 180ms 收走
        // （Modal 类规范 200–500ms；这里取 260 是为了与既有"丝滑慢速"手感同档）
        AnimatedVisibility(
            visible = showSheet,
            enter = fadeIn(tween(160)) + slideInVertically(tween(260, easing = InkEaseOut)) { it / 2 },
            exit = fadeOut(tween(150)) + slideOutVertically(tween(180, easing = InkEaseOut)) { it / 2 },
            label = "downloadSheet"
        ) {
            DownloadSheet(
                song = song,
                isDownloading = isDownloading,
                onCancel = { showSheet = false },
                onConfirm = { q ->
                    // v2.1.64：三档共用同一条下载链——解析多条候选（本平台 → 跨源换源 → 通用搜索后端兜底），
                    // 每条下完都按「容器 + 文件体积换算码率」复核是否真是所选档，不符就丢掉换下一条。
                    // 原先这里是"先 resolve 一条源再交给 DownloadManager"，下载层拿到的档位只是一句话，没人验。
                    DownloadManager.startDownload(song, q) { msg -> scope.launch { toast(msg) } }
                    toast("开始下载《${song.name}》${q.displayName} · 自动换源 + 体积校验")
                    showSheet = false
                }
            )
        }
    }
}

// ===== 封面区（白框装裱 + 方幅画心 + 横排题名/歌手 + 爱心；双击切大歌词）=====
// ===== v2.1.44：尺寸/间距全部走 tier 档位（该版「歌手行后留 weight 弹性」的做法已在 v2.1.46 移除）=====
// ===== v2.1.45：高度自适应（方案A）——已废弃：按常量估文字高、缺口超出上限即截断，iPad 上仍溢出压穿歌手行 =====
@Composable
private fun PlayerCoverBlock(
    song: Song,
    metrics: CoverMetrics,
    onToggle: () -> Unit
) {
    val p = LocalPalette.current
    // ===== v2.1.46 结构性保证：文字先占位、画心吃剩余 =====
    // 提示/题名/歌手在 Column 里是非 weight 子项，按自身真实高度测量、永不参与压缩；
    // 画心放进 weight(1f) 的剩余区，按当前可用宽/高反算边长 —— 结构上不存在溢出。
    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val frameExtraV = 36.dp                 // 白框上下内衬合计（单边 18）
        val frameExtraH = 28.dp                 // 白框左右内衬合计（单边 14）

        // 高度越紧，三处文字间距越收（下限 6 / 6 / 2）；收的只是间距，文字本身不缩、不裁
        val tight = maxHeight < 460.dp
        val hintGap = if (tight) 6.dp else metrics.hintGap
        val titleGap = if (tight) 6.dp else metrics.titleGap
        val artistGap = if (tight) 2.dp else metrics.artistGap
        val topGap = minOf(metrics.topGap, maxHeight * 0.10f)

        Column(
            modifier = Modifier.fillMaxSize().clipToBounds(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Top
        ) {
            Box(
                modifier = Modifier.weight(1f).fillMaxWidth().padding(top = topGap),
                contentAlignment = Alignment.Center
            ) {
                BoxWithConstraints {
                    // v2.1.73：上限只来自"真实可用宽/高"（画心不再被固定 dp 锁死）
                    val widthCap = maxWidth - frameExtraH
                    val heightCap = maxHeight - frameExtraV
                    val art = if (metrics.artCap > 0.dp) {
                        minOf(metrics.artCap, widthCap, heightCap)
                    } else {
                        minOf(widthCap, heightCap)
                    }.coerceAtLeast(0.dp)
                    PlayerCoverArt(song = song, art = art, onToggle = onToggle)
                }
            }

            // 封面提示：白框下方一行小字（始终保留——它是歌词入口的唯一说明，矮屏也不藏）
            Text(
                "双击封面看歌词",
                color = Color(0xFF8A8172),
                fontSize = 11.sp,
                letterSpacing = 1.5.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(top = hintGap)
            )

            Row(
                modifier = Modifier.fillMaxWidth().padding(start = 24.dp, end = 20.dp, top = titleGap),
                verticalAlignment = Alignment.Bottom
            ) {
                Text(
                    song.name,
                    color = p.text,
                    fontSize = metrics.titleSp,
                    lineHeight = metrics.titleLh,
                    letterSpacing = 2.sp,
                    fontFamily = InkTitleFont,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                PlayerFavBtn(song)
            }

            Text(
                song.singer + (if (song.album.isNotBlank()) " · " + song.album else ""),
                color = p.text2,
                fontSize = metrics.artistSp,
                letterSpacing = 0.8.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 24.dp, end = 24.dp, top = artistGap, bottom = 6.dp)
            )
        }
    }
}

/** 白框装裱 + 方幅画心（1:1）+ 内阴影；仅双击切歌词，单击不响应 */
@Composable
private fun PlayerCoverArt(song: Song, art: Dp, onToggle: () -> Unit) {
    val p = LocalPalette.current
    val framePadV = 18.dp
    val framePadH = 14.dp
    Box(
        modifier = Modifier
            .width(art + framePadH * 2)
            .background(p.surface)
            .border(1.dp, Color(0xFFDED7C8))
            .padding(vertical = framePadV, horizontal = framePadH),
        contentAlignment = Alignment.Center
    ) {
        Box(
            modifier = Modifier
                .size(art)
                .pointerInput(Unit) {
                    detectTapGestures(onDoubleTap = { onToggle() })
                }
        ) {
            SongCover(song = song, size = art, corner = 0.dp)
            // 内阴影（纸色向内渗）+ 1px 墨线：让封面陷进纸里，而不是贴上去
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .drawBehind {
                        drawRect(
                            brush = Brush.radialGradient(
                                colors = listOf(Color.Transparent, Color(0x5CFAF8F3)),
                                center = center,
                                radius = size.maxDimension * 0.72f
                            )
                        )
                        drawRect(color = Color(0x172E2A24), style = Stroke(1f))
                    }
            )
        }
    }
}

// ===== 大歌词视图（占播放控制栏上方全部空间；当前行滚动高亮；双击/单击切回封面）=====
@Composable
private fun LyricsLargeView(
    lines: List<LyricLine>,
    source: String?,
    loading: Boolean,
    position: Long,
    onToggle: () -> Unit
) {
    val p = LocalPalette.current
    val listState = rememberLazyListState()
    val hl = LyricsService.indexAt(lines, position)

    // 跟唱滚动（网易云同款实现）：歌词列表上下各加“半个视口高度”的空白占位，
    // 滚动到当前行 index（顶部对齐）后，当前行恰好出现在视口正中间。
    // 旧实现依赖 layoutInfo 计算偏移，歌词不足一屏时无法滚动导致当前行停留在顶部。
    LaunchedEffect(hl) {
        if (hl >= 0) {
            // 等一帧确保列表完成首次布局，再平滑滚动到当前行
            withFrameNanos { }
            listState.animateScrollToItem(hl)
        }
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp, vertical = 6.dp)
            .pointerInput(Unit) {
                // 约定交互：仅双击歌词切回封面；单击不响应
                detectTapGestures(
                    onDoubleTap = { onToggle() }
                )
            }
    ) {
        if (lines.isNotEmpty()) {
            val halfVh = maxHeight / 2
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                contentPadding = PaddingValues(vertical = halfVh)
            ) {
                items(lines.size) { i ->
                    val line = lines[i]
                    val active = i == hl
                    // 当前行：明显变大+变色（tween 320ms 平滑）；唱过后恢复原样
                    val fontSize by animateFloatAsState(
                        targetValue = if (active) 22f else 14f,
                        animationSpec = tween(320),
                        label = "lyricSize"
                    )
                    val textColor by animateColorAsState(
                        targetValue = if (active) p.accent2 else p.text3.copy(alpha = 0.45f),
                        animationSpec = tween(320),
                        label = "lyricColor"
                    )
                    Text(
                        line.text.ifBlank { " " },
                        color = textColor,
                        fontSize = fontSize.sp,
                        fontWeight = if (active) FontWeight.Bold else FontWeight.Normal,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = if (active) 9.dp else 6.dp)
                    )
                }
            }
        } else {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    when {
                        loading -> "歌词加载中…"
                        source != null -> "暂无歌词（$source）"
                        else -> "暂无歌词"
                    },
                    color = p.text3,
                    fontSize = 13.sp
                )
            }
        }
    }
}

// ===== 播放页爱心（右侧进度条上方；空心↔实心，直接读响应式事实源，与悬浮栏/列表全联动）=====
@Composable
private fun PlayerFavBtn(song: Song) {
    val p = LocalPalette.current
    val fav = HistoryStore.isFavorite(song)
    Box(
        modifier = Modifier
            .size(44.dp)
            .clickable { HistoryStore.toggleFavorite(song) },
        contentAlignment = Alignment.Center
    ) {
        // v2.1.38：与列表行共用 InkHeart（溶形 + 弹出），三处心形语言统一
        InkHeart(
            fav = fav,
            size = 26.dp,
            tintOn = p.heartOn,
            tintOff = p.text3.copy(alpha = 0.9f)
        )
    }
}

// ===== 下载弹层：三档音质 + 单个开始下载按钮（隐藏来源，内部按音质自动匹配）=====
@Composable
private fun DownloadSheet(
    song: Song,
    isDownloading: Boolean,
    onCancel: () -> Unit,
    onConfirm: (QualityLevel) -> Unit
) {
    val p = LocalPalette.current
    var quality by remember { mutableStateOf(HistoryStore.loadQuality()) }
    // v2.1.48：去掉下载前的三档预检（用户口径：没必要）。
    // 原来那套预检只判断"有没有源"、从不看源的音质，所以必然出现"无损档亮着、点下去却降级"；
    // 现在三档一律可点，由 DownloadResolver 在真正下载时解析——拿不到目标档就跨源换源，
    // 全部拿不到再降级，并把实际下到的档位如实告诉用户。

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0x88000000))
            .clickable(enabled = !isDownloading, onClick = onCancel),
        contentAlignment = Alignment.BottomCenter
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(p.surface, RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp))
                .padding(horizontal = 22.dp, vertical = 18.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("下载歌曲", color = p.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, fontFamily = InkTitleFont, modifier = Modifier.weight(1f))
                // v2.1.40：热区 32→44dp 并补墨色按压——这是下载弹层里唯一没有反馈的钮
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .inkClickable(enabled = !isDownloading) { onCancel() },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = "取消",
                        tint = p.text3,
                        modifier = Modifier.size(20.dp)
                    )
                }
            }
            Spacer(Modifier.height(2.dp))
            Text(song.name + " · " + song.singer, color = p.text2, fontSize = 13.sp, maxLines = 1)
            Spacer(Modifier.height(16.dp))

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                QualityLevel.entries.forEach { q ->
                    val selected = quality == q
                    // v2.1.48：三档不再按"有没有源"置灰——预检已移除，可点性只取决于是否正在下载
                    val colColor by animateColorAsState(
                        targetValue = if (selected) p.accent.copy(alpha = 0.16f) else p.surface2,
                        animationSpec = tween(180, easing = FastOutSlowInEasing),
                        label = "qualityBg"
                    )
                    val colText by animateColorAsState(
                        targetValue = if (selected) p.accent2 else p.text2,
                        animationSpec = tween(180, easing = FastOutSlowInEasing),
                        label = "qualityText"
                    )
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .background(colColor, RoundedCornerShape(12.dp))
                            .clickable(enabled = !isDownloading) { quality = q }
                            .padding(vertical = 12.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Text(
                            q.displayName,
                            color = colText,
                            fontSize = 13.sp,
                            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal
                        )
                    }
                }
            }
            Spacer(Modifier.height(10.dp))
            // v2.1.48：预检移除后不再有"检测中 / 请选择可用音质"这两种状态。
            // 这一行只负责在动手之前把规则讲清楚，取代原先"先亮后降级"的欺骗感
            Text(
                "拿不到所选音质会自动换源，每条都按文件大小校验；仍然没有就按可得的最高档下载",
                color = p.text3,
                fontSize = 11.sp
            )
            Spacer(Modifier.height(14.dp))

            // v2.1.40：按钮底色从灰到朱砂走 180ms 过渡；内部"开始下载 ↔ 转圈"用 160ms 交叉——
            // 原先这两次硬切都落在同一处，按下瞬间最刺眼
            // v2.1.48：可点性只取决于"是否正在下载"——预检去掉后不存在"某档不可用"这种状态
            val btnReady = !isDownloading
            val btnBg by animateColorAsState(
                targetValue = if (btnReady) p.accent else p.surface2,
                animationSpec = tween(180, easing = FastOutSlowInEasing),
                label = "confirmBg"
            )
            val btnText = Color(0xFFF7F5F0)
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(btnBg, RoundedCornerShape(14.dp))
                    .clickable(enabled = btnReady) { onConfirm(quality) }
                    .padding(vertical = 14.dp),
                contentAlignment = Alignment.Center
            ) {
                Crossfade(
                    targetState = isDownloading,
                    animationSpec = tween(160, easing = FastOutSlowInEasing),
                    label = "confirmContent"
                ) { downloading ->
                    if (downloading) {
                        // 跨源换源可能要跑十几秒，必须让用户看见"在做事情"而不是一个无字的转圈
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color(0xFFF7F5F0), strokeWidth = 2.dp)
                            Text("正在解析音源…", color = Color(0xFFF7F5F0), fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                        }
                    } else {
                        Text(
                            "开始下载",
                            color = btnText,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                    }
                }
            }
            Spacer(Modifier.height(6.dp))
        }
    }
}

// ===== 通用小组件（#7：统一水墨按压反馈）=====
@Composable
private fun IconButtonCompat(icon: androidx.compose.ui.graphics.vector.ImageVector, desc: String, onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(
        modifier = Modifier
            .size(40.dp)
            .inkClickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = desc, tint = p.text2, modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun IconBtnLarge(icon: androidx.compose.ui.graphics.vector.ImageVector, desc: String, onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(
        modifier = Modifier
            .size(48.dp)
            .inkClickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = desc, tint = p.text2, modifier = Modifier.size(32.dp))
    }
}

private fun formatTime(ms: Long): String {
    val totalSec = ms / 1000
    return String.format("%02d:%02d", totalSec / 60, totalSec % 60)
}

// 简易 toast（不依赖系统 Toast 也能在 Compose 内提示）
private var toastText = mutableStateOf<String?>(null)
private var toastJob: kotlinx.coroutines.Job? = null
fun toast(msg: String) {
    toastText.value = msg
    toastJob?.cancel()
    toastJob = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Main).launch {
        kotlinx.coroutines.delay(1800)
        toastText.value = null
    }
}

// v2.1.38：与 App.kt 山水 wipe 同源的 strong ease-out（cubic-bezier(.23,1,.32,1)）
// （App.kt 里的同名常量是 private，跨文件不可见，此处独立声明）
private val InkEaseOut = CubicBezierEasing(0.23f, 1f, 0.32f, 1f)

@Composable
fun ToastHost() {
    val p = LocalPalette.current
    val msg = toastText.value
    // 退出动画期间内容不能瞬间变空，否则 exit 在空容器上空跑、观感等于"没有退出"
    var lastMsg by remember { mutableStateOf("") }
    LaunchedEffect(msg) { if (msg != null) lastMsg = msg }
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        // v2.1.38：TOAST 不再凭空出现/消失——进入从下方 1/3 处浮起 220ms，退出 140ms 收走
        // （系统响应快于主动呈现：出比进短，符合非对称时长）
        AnimatedVisibility(
            visible = msg != null,
            enter = fadeIn(tween(180)) + slideInVertically(tween(220, easing = InkEaseOut)) { it / 3 },
            exit = fadeOut(tween(130)) + slideOutVertically(tween(140, easing = InkEaseOut)) { -it / 4 },
            label = "toast"
        ) {
            Text(
                lastMsg,
                color = Color(0xFFF7F5F0),
                fontSize = 13.sp,
                modifier = Modifier
                    .background(Color(0xE62E2A24), RoundedCornerShape(percent = 50))
                    .padding(horizontal = 18.dp, vertical = 10.dp)
            )
        }
    }
}

// ===== 播放页进度：墨线（干墨 1dp / 湿墨 3dp / 朱砂点 8dp），点按定位 + 拖拽 =====
// v2.1.85：底下一层淡墨带 = 已缓存到本地的段落（PlayCache.frac），缓存越满这条越靠右；
@Composable
private fun InkProgress(
    position: Long,
    duration: Long,
    onSeek: (Long) -> Unit,
    horizontalPad: Dp = 24.dp,
    songKey: String = ""
) {
    val p = LocalPalette.current
    val cache by com.jz.musichelper.data.PlayCache.state.collectAsState()
    val cachedFrac = if (songKey.isNotEmpty() && cache.songKey == songKey) cache.frac else 0f
    // 拖拽中只更新本地预览比例，松手才真正 seek —— 避免拖动过程反复跳音
    var dragFrac by remember { mutableStateOf<Float?>(null) }
    val frac = dragFrac
        ?: if (duration > 0) (position.toFloat() / duration.toFloat()).coerceIn(0f, 1f) else 0f

    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = horizontalPad)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(9.dp)
                .pointerInput(duration) {
                    if (duration <= 0) return@pointerInput
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        dragFrac = (down.position.x / size.width.toFloat()).coerceIn(0f, 1f)
                        down.consume()
                        while (true) {
                            val ev = awaitPointerEvent()
                            val ch = ev.changes.firstOrNull { it.id == down.id } ?: break
                            if (!ch.pressed) break
                            dragFrac = (ch.position.x / size.width.toFloat()).coerceIn(0f, 1f)
                            ch.consume()
                        }
                        dragFrac?.let { f -> onSeek((f * duration).toLong()) }
                        dragFrac = null
                    }
                }
        ) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                val cy = size.height / 2f
                // v2.1.85：已缓存段先铺一层淡墨带（比干墨线粗，但不抢进度线）
                if (cachedFrac > 0f) {
                    drawRoundRect(
                        color = Color(0xFF2E2A24).copy(alpha = 0.13f),
                        topLeft = Offset(0f, cy - 2.5f.dp.toPx()),
                        size = Size(size.width * cachedFrac.coerceIn(0f, 1f), 5.dp.toPx()),
                        cornerRadius = CornerRadius(2.5f.dp.toPx())
                    )
                }
                drawLine(
                    color = Color(0xFFC9C2B2),
                    start = Offset(0f, cy),
                    end = Offset(size.width, cy),
                    strokeWidth = 1.dp.toPx()
                )
                if (frac > 0f) {
                    val w = size.width * frac
                    drawRoundRect(
                        color = Color(0xFF2E2A24),
                        topLeft = Offset(0f, cy - 1.5.dp.toPx()),
                        size = Size(w, 3.dp.toPx()),
                        cornerRadius = CornerRadius(2.dp.toPx())
                    )
                    drawCircle(
                        color = Color(0xFFB03A2E),
                        radius = 4.dp.toPx(),
                        center = Offset(w, cy)
                    )
                }
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 11.dp),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(formatTime(position), color = p.text3, fontSize = 11.sp, letterSpacing = 0.5.sp)
            Text(formatTime(duration), color = p.text3, fontSize = 11.sp, letterSpacing = 0.5.sp)
        }
    }
}

// ===== 播放页暂停/播放：56dp 朱砂方印（v2.1.46 圆角 3→14，方印骨相保留、四角收圆），暂停为双杠、播放为三角 =====
@Composable
private fun PlaySeal(isPlaying: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(56.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFFB03A2E))
            .inkClickable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        // v2.1.38：两态不硬替换——0.82 起缩 + 交叉淡入（不从 scale(0) 起）
        AnimatedContent(
            targetState = isPlaying,
            transitionSpec = {
                (scaleIn(initialScale = 0.82f) + fadeIn(tween(160, easing = InkEaseOut)))
                    .togetherWith(scaleOut(targetScale = 0.82f) + fadeOut(tween(120)))
            },
            label = "playPause"
        ) { playing ->
            if (playing) {
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    Box(Modifier.width(3.dp).height(18.dp).background(Color(0xFFFDFCF9)))
                    Box(Modifier.width(3.dp).height(18.dp).background(Color(0xFFFDFCF9)))
                }
            } else {
                Icon(
                    Icons.Filled.PlayArrow,
                    contentDescription = "播放",
                    tint = Color(0xFFFDFCF9),
                    modifier = Modifier.size(28.dp)
                )
            }
        }
    }
}


// ===================================================================================
// ===== v2.1.73：三套版式 + 共用零件（以手机竖屏为基准，平板/横屏只改容器摆法）=====
// ===================================================================================

@Composable
private fun PlayerTopBar(
    onBack: () -> Unit,
    horizontalPad: Dp = 24.dp,
    onToggleLyrics: () -> Unit
) {
    val p = LocalPalette.current
    var menuOpen by remember { mutableStateOf(false) }
    val desktopOn by DesktopLyrics.enabled.collectAsState()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = horizontalPad, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconButtonCompat(Icons.AutoMirrored.Filled.ArrowBack, "返回", onClick = onBack)
        Text(
            "正在播放",
            modifier = Modifier.weight(1f),
            textAlign = TextAlign.Center,
            color = p.text2,
            fontSize = 14.sp,
            letterSpacing = 3.sp
        )
        // v2.1.74：右上角三点从"演示提示"换成真菜单——桌面歌词开关 + 查看歌词/封面
        Box {
            IconButtonCompat(Icons.Filled.MoreVert, "更多", onClick = { menuOpen = true })
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = {
                        Text(
                            if (desktopOn) "桌面歌词 · 已开" else "桌面歌词",
                            color = p.text,
                            fontSize = 14.sp
                        )
                    },
                    onClick = {
                        menuOpen = false
                        if (desktopOn) {
                            DesktopLyrics.toggleFromUi(false)
                            toast("桌面歌词已关闭")
                        } else if (DesktopLyrics.toggleFromUi(true)) {
                            toast("桌面歌词已开启，回到桌面（或切到别的应用）播放时即可看到")
                        } else {
                            toast("需要「显示在其他应用上层」权限")
                            DesktopLyrics.openOverlaySettings()
                        }
                    }
                )
                DropdownMenuItem(
                    text = { Text("查看歌词 / 封面", color = p.text, fontSize = 14.sp) },
                    onClick = {
                        menuOpen = false
                        onToggleLyrics()
                    }
                )
                // v2.1.83：识曲已独立成底层栏一页——这里直接切到那一页并顺带听一次（不再是浮层）
                DropdownMenuItem(
                    text = { Text("听歌识曲", color = p.text, fontSize = 14.sp) },
                    onClick = {
                        menuOpen = false
                        AppState.openRecognize()
                        AppState.recAutoStart.value = true
                    }
                )
            }
        }
    }
}

/** 五件横排：循环 · 上一 · 朱砂印 · 下一 · 下载（手机两端对齐 / 平板上 evenly 均分） */
@Composable
private fun PlayerControls(
    horizontalPad: Dp = 24.dp,
    evenly: Boolean = false,
    onDownload: () -> Unit
) {
    val p = LocalPalette.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = horizontalPad),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = if (evenly) Arrangement.SpaceEvenly else Arrangement.SpaceBetween
    ) {
        // 循环/随机：图标随档位每次换挡转满整圈，落角恒为 0°（v2.1.47 口径不变）
        val mode = AppState.playMode.value
        val (modeIcon, modeLabel) = when (mode) {
            PlayMode.SINGLE_LOOP -> Icons.Filled.RepeatOne to "单曲循环"
            PlayMode.LIST_LOOP -> Icons.Filled.Repeat to "列表循环"
            PlayMode.SHUFFLE -> Icons.Filled.Shuffle to "随机播放"
        }
        var modeRotTarget by remember { mutableStateOf(0f) }
        var prevPlayMode by remember { mutableStateOf(mode) }
        LaunchedEffect(mode) {
            if (mode != prevPlayMode) {
                prevPlayMode = mode
                modeRotTarget += 360f
            }
        }
        val modeRot by animateFloatAsState(
            targetValue = modeRotTarget,
            animationSpec = tween(300, easing = InkEaseOut),
            label = "modeRot"
        )
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier
                .widthIn(min = 44.dp)
                .heightIn(min = 44.dp)
                .inkClickable { AppState.cyclePlayMode() }
        ) {
            Box(
                modifier = Modifier.rotate(modeRot),
                contentAlignment = Alignment.Center
            ) {
                AnimatedContent(
                    targetState = modeIcon,
                    transitionSpec = { fadeIn(tween(150)) togetherWith fadeOut(tween(120)) },
                    label = "modeIcon"
                ) { mi ->
                    Icon(
                        mi,
                        contentDescription = null,
                        tint = p.text2,
                        modifier = Modifier.size(19.dp)
                    )
                }
            }
            Spacer(Modifier.height(4.dp))
            AnimatedContent(
                targetState = modeLabel,
                transitionSpec = { fadeIn(tween(150)) togetherWith fadeOut(tween(110)) },
                label = "modeLabel"
            ) { lb ->
                Text(lb, color = p.accent2, fontSize = 12.sp, letterSpacing = 0.5.sp)
            }
        }

        // 上一首
        Box(
            modifier = Modifier.size(44.dp).inkClickable { AppState.prevSong() },
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Filled.SkipPrevious,
                contentDescription = "上一首",
                tint = p.accent,
                modifier = Modifier.size(22.dp)
            )
        }

        // 暂停 / 播放：56dp 朱砂方印
        PlaySeal(isPlaying = PlayerManager.isPlaying.collectAsState().value, onClick = { PlayerManager.toggle() })

        // 下一首
        Box(
            modifier = Modifier.size(44.dp).inkClickable { AppState.nextSong() },
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Filled.SkipNext,
                contentDescription = "下一首",
                tint = p.accent,
                modifier = Modifier.size(22.dp)
            )
        }

        // 下载
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier
                .widthIn(min = 44.dp)
                .heightIn(min = 44.dp)
                .inkClickable { onDownload() }
        ) {
            Icon(
                Icons.Filled.Download,
                contentDescription = "下载",
                tint = p.text2,
                modifier = Modifier.size(19.dp)
            )
            Spacer(Modifier.height(4.dp))
            Text("下载", color = p.accent2, fontSize = 12.sp, letterSpacing = 0.5.sp)
        }
    }
}

/** 状态行：固定 20dp 占位（v2.1.47 口径——不可条件渲染，否则切歌瞬间高度塌陷） */
@Composable
private fun PlayerStatusLine(isResolving: Boolean, resolveErr: String?, playerError: String?) {
    val p = LocalPalette.current
    Box(Modifier.fillMaxWidth().height(20.dp), contentAlignment = Alignment.Center) {
        if (isResolving) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    color = p.accent,
                    strokeWidth = 2.dp
                )
                Spacer(Modifier.width(8.dp))
                Text("正在解析音源…", color = p.text3, fontSize = 12.sp)
            }
        } else if (resolveErr != null) {
            Text(
                resolveErr,
                color = Color(0xFFC0392B),
                fontSize = 12.sp,
                textAlign = TextAlign.Center,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth()
            )
        } else if (playerError != null) {
            Text(
                playerError,
                color = Color(0xFFC0392B),
                fontSize = 12.sp,
                textAlign = TextAlign.Center,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

/** 音源行：固定占位（空串也照占），右对齐 */
@Composable
private fun PlayerSourceLine(
    text: String,
    top: Dp,
    bottom: Dp,
    horizontalPad: Dp = 24.dp
) {
    val p = LocalPalette.current
    Text(
        text = text,
        color = p.text3,
        fontSize = 11.sp,
        letterSpacing = 0.5.sp,
        textAlign = TextAlign.End,
        maxLines = 1,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = horizontalPad, end = horizontalPad, top = top, bottom = bottom)
            .heightIn(min = 16.dp)
    )
}

/** ① 手机竖屏：基准版式（与 v2.1.72 完全一致，只把零件抽出来复用） */
@Composable
private fun PlayerPhone(ui: PlayerUi) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .widthIn(max = 500.dp)
        ) {
            PlayerTopBar(ui.onBack, 10.dp, ui.onToggleLyrics)

            Column(
                modifier = Modifier.weight(1f).fillMaxWidth(),
                verticalArrangement = Arrangement.Center
            ) {
                AnimatedContent(
                    targetState = ui.showLyrics,
                    transitionSpec = {
                        (fadeIn(tween(320, easing = FastOutSlowInEasing)))
                            .togetherWith(fadeOut(tween(240, easing = FastOutSlowInEasing)))
                    },
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    label = "cover-lyrics"
                ) { ly ->
                    if (ly) {
                        LyricsLargeView(
                            lines = ui.lyrics,
                            source = ui.lyricsSource,
                            loading = ui.lyricsLoading,
                            position = ui.position,
                            onToggle = { ui.onToggleLyrics() }
                        )
                    } else {
                        PlayerCoverBlock(
                            song = ui.song,
                            metrics = PHONE_COVER,
                            onToggle = { ui.onToggleLyrics() }
                        )
                    }
                }

                InkProgress(ui.position, ui.duration, ui.onSeek, horizontalPad = 24.dp, songKey = ui.song.platform.name + ui.song.platformID)
                Spacer(Modifier.height(30.dp))
                PlayerControls(horizontalPad = 24.dp, evenly = false, onDownload = ui.onDownload)
                PlayerStatusLine(ui.isResolving, ui.resolveErr, ui.playerError)
                PlayerSourceLine(ui.srcText, top = 10.dp, bottom = 0.dp, horizontalPad = 24.dp)
            }
        }
    }
}

/** ② 平板竖屏：画心吃满可用宽高、段落之间按比例分配弹性，
 *  让「封面 → 题名 → 进度 → 控件 → 音源」铺满整屏，而不是把余量全堆在底部。 */
@Composable
private fun PlayerTablet(ui: PlayerUi) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .widthIn(max = 720.dp)
                .padding(horizontal = 24.dp)
        ) {
            PlayerTopBar(ui.onBack, 0.dp, ui.onToggleLyrics)
            Spacer(Modifier.weight(0.05f))

            Box(Modifier.weight(3.30f).fillMaxWidth()) {
                AnimatedContent(
                    targetState = ui.showLyrics,
                    transitionSpec = {
                        (fadeIn(tween(320, easing = FastOutSlowInEasing)))
                            .togetherWith(fadeOut(tween(240, easing = FastOutSlowInEasing)))
                    },
                    modifier = Modifier.fillMaxSize(),
                    label = "cover-lyrics-tablet"
                ) { ly ->
                    if (ly) {
                        LyricsLargeView(
                            lines = ui.lyrics,
                            source = ui.lyricsSource,
                            loading = ui.lyricsLoading,
                            position = ui.position,
                            onToggle = { ui.onToggleLyrics() }
                        )
                    } else {
                        PlayerCoverBlock(
                            song = ui.song,
                            metrics = TABLET_COVER,
                            onToggle = { ui.onToggleLyrics() }
                        )
                    }
                }
            }

            Spacer(Modifier.weight(0.03f))
            InkProgress(ui.position, ui.duration, ui.onSeek, horizontalPad = 0.dp, songKey = ui.song.platform.name + ui.song.platformID)
            Spacer(Modifier.weight(0.05f))
            PlayerControls(horizontalPad = 0.dp, evenly = false, onDownload = ui.onDownload)
            PlayerStatusLine(ui.isResolving, ui.resolveErr, ui.playerError)
            PlayerSourceLine(ui.srcText, top = 6.dp, bottom = 0.dp, horizontalPad = 0.dp)
            Spacer(Modifier.weight(0.04f))
        }
    }
}

/** ③ 横屏（手机 + 平板统一）：左边封面（双击切歌词 / 再双击切回），右边是剩下的交互按钮 */
@Composable
private fun PlayerLandscape(ui: PlayerUi) {
    val p = LocalPalette.current
    Row(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 18.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(18.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 左：封面 / 歌词（同一块区域，双击切换）
        Box(Modifier.weight(0.46f).fillMaxHeight(), contentAlignment = Alignment.Center) {
            BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                val side = minOf(maxWidth, maxHeight)
                AnimatedContent(
                    targetState = ui.showLyrics,
                    transitionSpec = {
                        (fadeIn(tween(320, easing = FastOutSlowInEasing)))
                            .togetherWith(fadeOut(tween(240, easing = FastOutSlowInEasing)))
                    },
                    modifier = Modifier.fillMaxSize(),
                    label = "cover-lyrics-landscape"
                ) { ly ->
                    if (ly) {
                        LyricsLargeView(
                            lines = ui.lyrics,
                            source = ui.lyricsSource,
                            loading = ui.lyricsLoading,
                            position = ui.position,
                            onToggle = { ui.onToggleLyrics() }
                        )
                    } else {
                        PlayerCoverArt(
                            song = ui.song,
                            art = (side - 30.dp).coerceAtLeast(0.dp),
                            onToggle = { ui.onToggleLyrics() }
                        )
                    }
                }
            }
        }

        // 右：题名 → 进度 → 五件 → 状态 → 音源
        Column(Modifier.weight(0.54f).fillMaxHeight()) {
            PlayerTopBar(ui.onBack, 0.dp, ui.onToggleLyrics)
            Spacer(Modifier.weight(0.04f))

            Row(
                modifier = Modifier.fillMaxWidth().padding(end = 4.dp),
                verticalAlignment = Alignment.Bottom
            ) {
                Text(
                    ui.song.name,
                    color = p.text,
                    fontSize = 26.sp,
                    lineHeight = 31.sp,
                    letterSpacing = 2.sp,
                    fontFamily = InkTitleFont,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                PlayerFavBtn(ui.song)
            }
            Text(
                ui.song.singer + (if (ui.song.album.isNotBlank()) " · " + ui.song.album else ""),
                color = p.text2,
                fontSize = 13.sp,
                letterSpacing = 0.8.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth().padding(top = 2.dp)
            )

            Spacer(Modifier.weight(0.07f))
            InkProgress(ui.position, ui.duration, ui.onSeek, horizontalPad = 0.dp, songKey = ui.song.platform.name + ui.song.platformID)
            Spacer(Modifier.weight(0.12f))
            PlayerControls(horizontalPad = 0.dp, evenly = true, onDownload = ui.onDownload)
            PlayerStatusLine(ui.isResolving, ui.resolveErr, ui.playerError)
            PlayerSourceLine(ui.srcText, top = 4.dp, bottom = 0.dp, horizontalPad = 0.dp)
            Spacer(Modifier.weight(0.03f))
        }
    }
}

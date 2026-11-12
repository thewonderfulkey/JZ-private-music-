# -*- coding: utf-8 -*-
"""v2.1.73：把 PlayerScreen 的内容列换成三套版式（手机竖屏 / 平板竖屏 / 横屏左右式），
并把封面块、进度条、顶栏、控件行、状态行、音源行抽成可复用 composable。"""
import io
import re

PATH = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper\ui\PlayerScreen.kt"

src = io.open(PATH, encoding="utf-8").read()

# ============ 1) 版式分派：替换 PlayerScreen 里原来那段「分档 + 单列 Column」 ============
start_marker = "        // 系统自适应分档（跟随可用宽/高，横竖屏切换自动重组）；矮屏（手机横屏等）一律回退手机档"
end_marker = "        }   // 主内容 Box（背景+避让）闭合"
si = src.index(start_marker)
ei = src.index(end_marker)
new_dispatch = '''        // ===== v2.1.73 三套版式（以手机竖屏为基准）=====
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
                    "音源：${'$'}{s.backendName} · ${'$'}{s.quality.displayName} · ${'$'}{s.format}" +
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
'''
src = src[:si] + new_dispatch + src[ei:]

# ============ 2) 档位枚举 → 封面度量 ============
enum_start = "// ===== 正在播放页 v2.1.48（下载弹层去掉预检"
enum_end = "@Composable\nfun PlayerScreen(song: Song, onBack: () -> Unit) {"
enum_new = '''// ===== 正在播放页 v2.1.73（三套版式：手机竖屏基准 / 平板竖屏填满 / 横屏左右式）=====
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

'''
src = src[:src.index(enum_start)] + enum_new + src[src.index(enum_end):]

# ============ 3) 封面块改用 CoverMetrics，并把白框封面抽成 PlayerCoverArt ============
block_start = "@Composable\nprivate fun PlayerCoverBlock("
block_end = "// ===== 大歌词视图"
block_new = '''@Composable
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

'''
src = src[:src.index(block_start)] + block_new + src[src.index(block_end):]

io.open(PATH, "w", encoding="utf-8", newline="").write(src)
print("spliced ok, length", len(src))

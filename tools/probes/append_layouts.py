# -*- coding: utf-8 -*-
import io

PATH = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper\ui\PlayerScreen.kt"
src = io.open(PATH, encoding="utf-8").read()

# --- InkProgress：横向内边距参数化（平板/横屏的列自身已有内缩）---
src = src.replace(
    "private fun InkProgress(position: Long, duration: Long, onSeek: (Long) -> Unit) {",
    "private fun InkProgress(\n"
    "    position: Long,\n"
    "    duration: Long,\n"
    "    onSeek: (Long) -> Unit,\n"
    "    horizontalPad: Dp = 24.dp\n"
    ") {"
)
src = src.replace(
    "    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp)) {\n"
    "        Box(\n",
    "    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = horizontalPad)) {\n"
    "        Box(\n"
)

APPEND = r'''

// ===================================================================================
// ===== v2.1.73：三套版式 + 共用零件（以手机竖屏为基准，平板/横屏只改容器摆法）=====
// ===================================================================================

@Composable
private fun PlayerTopBar(onBack: () -> Unit, horizontalPad: Dp = 24.dp) {
    val p = LocalPalette.current
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
        IconButtonCompat(Icons.Filled.MoreVert, "更多", onClick = { toast("更多操作（演示）") })
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
            PlayerTopBar(ui.onBack, 10.dp)

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

                InkProgress(ui.position, ui.duration, ui.onSeek, horizontalPad = 24.dp)
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
            PlayerTopBar(ui.onBack, 0.dp)
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
            InkProgress(ui.position, ui.duration, ui.onSeek, horizontalPad = 0.dp)
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
            PlayerTopBar(ui.onBack, 0.dp)
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
            InkProgress(ui.position, ui.duration, ui.onSeek, horizontalPad = 0.dp)
            Spacer(Modifier.weight(0.12f))
            PlayerControls(horizontalPad = 0.dp, evenly = true, onDownload = ui.onDownload)
            PlayerStatusLine(ui.isResolving, ui.resolveErr, ui.playerError)
            PlayerSourceLine(ui.srcText, top = 4.dp, bottom = 0.dp, horizontalPad = 0.dp)
            Spacer(Modifier.weight(0.03f))
        }
    }
}
'''

src = src.rstrip("\n") + "\n" + APPEND
io.open(PATH, "w", encoding="utf-8", newline="").write(src)
print("appended; len", len(src))

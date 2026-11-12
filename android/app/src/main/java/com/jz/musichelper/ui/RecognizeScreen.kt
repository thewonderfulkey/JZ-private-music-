package com.jz.musichelper.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import androidx.core.content.ContextCompat
import com.jz.musichelper.data.VoiceCapture
import com.jz.musichelper.network.NeteaseFingerprint
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette
import kotlin.math.sin

/** 识曲界面的阶段（状态本体在 AppState，UI 只读） */
enum class RecPhase { PREPARE, LISTEN, THINK, RESULT, EMPTY, ERROR, NOPERM }

// ===================== 识曲页（v2.1.83：从首页入口条改成底层栏独立页） =====================
/**
 * 整页结构自上而下：题字「听歌识曲」+ 发丝线 → 圆形麦克风（唯一可点目标，外围三道墨圈随响度呼吸）
 * → 阶段文案 → 下方内容区（结果卡 / 失败说明 / 最近识过）。
 *
 * 留白规则：麦克风左右不摆任何元件，一屏只有竖轴一条视觉线；其余内容全部压在下方内容区，
 * 结果卡与「最近识过」用同一种纸签（1px 墨线 + 纸色渐变），和首页的编辑精选是同一套语言。
 */
@Composable
fun RecognizePage() {
    val p = LocalPalette.current
    val ctx = LocalContext.current
    val phase = AppState.recPhase.value
    val level = AppState.recLevel.value
    val progress = AppState.recProgress.value
    val hits = AppState.recHits.value
    val errMsg = AppState.recError.value
    val busy = AppState.recPlayBusy.value
    val recent = AppState.recRecent.value
    val seconds = AppState.recSeconds.value
    val listeningNow = phase == RecPhase.LISTEN || phase == RecPhase.THINK
    // v2.1.84：右上角「听十秒」从纯文本改成可配置按钮（位置不变），点开在下面弹出时长选择
    var durOpen by remember { mutableStateOf(false) }

    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { ok ->
        if (ok) AppState.startRecognize() else AppState.recPhase.value = RecPhase.NOPERM
    }

    fun start() {
        val granted = ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) AppState.startRecognize() else permLauncher.launch(Manifest.permission.RECORD_AUDIO)
    }

    // 播放页三点菜单进来：进页即听一次
    LaunchedEffect(AppState.recAutoStart.value) {
        if (AppState.recAutoStart.value) {
            AppState.recAutoStart.value = false
            start()
        }
    }
    // 离开这个 Tab 就收掉采集，不在后台留一段录音
    DisposableEffect(Unit) {
        onDispose { AppState.cancelRecognize() }
    }

    Column(modifier = Modifier.fillMaxSize().padding(horizontal = 22.dp)) {
        // v2.1.91：网易指纹引擎的承载页（1dp 不可见）。进页即预热 wasm，
        // 点麦克风时引擎已就绪；进程内复用同一个 WebView，不每次重编译。
        AndroidView(
            factory = { c -> NeteaseFingerprint.attach(c) },
            modifier = Modifier.size(1.dp)
        )
        Spacer(Modifier.height(8.dp))
        Box {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "听歌识曲",
                    fontSize = 23.sp,
                    fontFamily = InkTitleFont,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.sp,
                    color = p.text
                )
                Spacer(Modifier.weight(1f))
                // v2.1.84：原「听十秒」纯文本 → 同位置的墨线小按钮；点开选听多久（聆听中不可改）
                DurationButton(
                    seconds = seconds,
                    open = durOpen,
                    enabled = !listeningNow,
                    onClick = { durOpen = !durOpen }
                )
            }
            if (durOpen) {
                Popup(
                    alignment = Alignment.TopEnd,
                    offset = IntOffset(0, with(LocalDensity.current) { 36.dp.roundToPx() }),
                    onDismissRequest = { durOpen = false },
                    properties = PopupProperties(focusable = true)
                ) {
                    DurationMenu(current = seconds) { v ->
                        AppState.setRecSeconds(v)
                        durOpen = false
                    }
                }
            }
        }
        Spacer(Modifier.height(7.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(p.text.copy(alpha = 0.13f)))
        Spacer(Modifier.height(10.dp))

        // ---- 麦克风舞台：唯一点击目标 ----
        val listening = listeningNow
        // v2.1.86：出结果后麦克风缩到 0.72，把竖轴上方那 70dp 还给结果与版本列表（重听仍点这里）
        val micScale = if (phase == RecPhase.RESULT) 0.72f else 1f
        Box(
            modifier = Modifier.fillMaxWidth().height(252.dp * micScale),
            contentAlignment = Alignment.Center
        ) {
            MicField(phase = phase, level = level, scale = micScale) {
                // v2.1.84：识别过程中再点一次 = 取消这次识别（停采集、这段音频直接丢掉，不做识别），
                // 上一版这里是 if(!listening) start()，聆听中点麦克风完全没反应——正是用户反馈的那条
                if (listening) AppState.cancelRecognize() else start()
            }
        }

        // ---- 阶段文案 ----
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            when (phase) {
                RecPhase.PREPARE, RecPhase.EMPTY, RecPhase.ERROR, RecPhase.NOPERM -> {
                    Text(
                        "点一下麦克风，开始听",
                        fontSize = 13.sp,
                        color = p.text2
                    )
                }
                RecPhase.RESULT -> {
                    Text("再点一下麦克风，可以重听", fontSize = 11.5.sp, color = p.text3)
                }
                RecPhase.LISTEN -> {
                    val total = seconds.toFloat()
                    val left = ((1f - progress) * total).toInt().coerceAtLeast(0)
                    Text("正在聆听…", fontSize = 14.sp, color = p.text, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(3.dp))
                    Text("还能听 $left 秒", fontSize = 11.5.sp, color = p.text3)
                    Spacer(Modifier.height(5.dp))
                    Text("再点一下麦克风，就取消这次识别", fontSize = 10.5.sp, color = p.text3.copy(alpha = 0.85f))
                }
                RecPhase.THINK -> {
                    Text("正在辨认…", fontSize = 14.sp, color = p.text, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(3.dp))
                    Text("比对曲库中，稍等；再点一下麦克风就取消", fontSize = 11.5.sp, color = p.text3)
                }
            }
        }

        // v2.1.86：结果态这条间距收到 10dp，让「其他版本」至少完整露出两行（悬浮栏以上）
        Spacer(Modifier.height(if (phase == RecPhase.RESULT) 10.dp else 16.dp))

        // ---- 下方内容区 ----
        Column(modifier = Modifier.fillMaxWidth().weight(1f)) {
            when (phase) {
                RecPhase.RESULT -> ResultBlock(
                    hit = hits.firstOrNull(),
                    others = hits.drop(1),
                    busy = busy,
                    noExact = AppState.recNoExact.value,
                    note = errMsg,
                    versions = AppState.recVersions.value,
                    originals = AppState.recOriginals.value,
                    versionsBusy = AppState.recVersionsBusy.value,
                    onPlay = { hit -> AppState.playRecognizedHit(hit) },
                    onAgain = { start() },
                    onLoadVersions = { hits.firstOrNull()?.let { AppState.loadRecVersions(it) } },
                    onPlayVersion = { s ->
                        AppState.openSong(
                            s,
                            queue = AppState.recVersions.value
                        )
                    }
                )
                RecPhase.EMPTY -> NoteBlock("没听清", errMsg, primary = "再听一次", onPrimary = { start() })
                RecPhase.ERROR -> NoteBlock("识别失败", errMsg, primary = "再试一次", onPrimary = { start() })
                RecPhase.NOPERM -> NoteBlock(
                    "没拿到麦克风权限",
                    "识曲只采环境音，用完就丢。点「再授一次」重新申请，或在系统设置里放开麦克风。",
                    primary = "再授一次",
                    onPrimary = { permLauncher.launch(Manifest.permission.RECORD_AUDIO) }
                )
                else -> RecentBlock(
                    recent = recent,
                    seconds = seconds,
                    onPlay = { hit -> AppState.playRecognizedHit(hit) },
                    modifier = Modifier.weight(1f)
                )
            }
            if (phase != RecPhase.PREPARE && phase != RecPhase.EMPTY &&
                phase != RecPhase.ERROR && phase != RecPhase.NOPERM
            ) Spacer(Modifier.weight(1f))
            // 页脚：把下方余白收成"版面留白"而不是空着（说明数据怎么处理，不堆装饰）
            Text(
                "${seconds} 秒采样只用于曲库比对，本机不留存",
                fontSize = 10.5.sp,
                color = p.text3.copy(alpha = 0.85f)
            )
        }
        Spacer(Modifier.height(10.dp))
    }
}

/**
 * 右上角时长按钮（v2.1.84）：位置就是原来那行「听十秒」，但从纯文本变成一个墨线小钮——
 * 看得出可点、点开能选听多久。聆听/辨认中不可点（中途改时长会和已采长度对不上）。
 */
@Composable
private fun DurationButton(seconds: Int, open: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    val a = if (enabled) 1f else 0.4f
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .height(32.dp)
            .clip(RoundedCornerShape(2.dp))
            .border(1.dp, p.text.copy(alpha = 0.24f * a), RoundedCornerShape(2.dp))
            .then(if (enabled) Modifier.inkClickable { onClick() } else Modifier)
            .padding(horizontal = 10.dp)
    ) {
        Text("听 $seconds 秒", fontSize = 11.sp, color = p.text2.copy(alpha = a))
        Spacer(Modifier.width(5.dp))
        Text(if (open) "▴" else "▾", fontSize = 9.sp, color = p.text3.copy(alpha = a))
    }
}

/** 时长选择卡：纸面 + 1px 墨线，四档竖排；当前档用墨字加粗 + 一枚朱砂点 */
@Composable
private fun DurationMenu(current: Int, onPick: (Int) -> Unit) {
    val p = LocalPalette.current
    Column(
        modifier = Modifier
            .width(124.dp)
            .clip(RoundedCornerShape(2.dp))
            .background(Brush.verticalGradient(listOf(p.surface, p.surface2)))
            .border(1.dp, p.text.copy(alpha = 0.18f), RoundedCornerShape(2.dp))
    ) {
        Text(
            "听多久",
            fontSize = 10.5.sp,
            letterSpacing = 1.sp,
            color = p.text3,
            modifier = Modifier.padding(start = 12.dp, top = 9.dp, bottom = 5.dp)
        )
        // v2.1.91：档位收成 12/15/20——12 秒是网易指纹的最低窗口，5/10 秒已不再可选
        listOf(12, 15, 20).forEach { s ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .inkClickable { onPick(s) }
                    .padding(horizontal = 12.dp, vertical = 9.dp)
            ) {
                Text(
                    "$s 秒",
                    fontSize = 13.sp,
                    fontWeight = if (s == current) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (s == current) p.text else p.text2
                )
                Spacer(Modifier.weight(1f))
                if (s == current) {
                    Box(Modifier.size(4.dp).clip(CircleShape).background(p.heartOn))
                }
            }
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp)
                    .height(1.dp)
                    .background(p.text.copy(alpha = 0.10f))
            )
        }
        Spacer(Modifier.height(3.dp))
    }
}

/** 圆形麦克风：三道墨圈（呼吸 + 随响度涨落）+ 墨线圆盘，只有这一块可点 */
@Composable
private fun MicField(phase: RecPhase, level: Float, scale: Float = 1f, onClick: () -> Unit) {
    val p = LocalPalette.current
    val active = phase == RecPhase.LISTEN || phase == RecPhase.THINK
    val breathe = rememberInfiniteTransition(label = "micField")
    val t by breathe.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(2000, easing = LinearEasing), RepeatMode.Restart),
        label = "t"
    )
    val ringAlpha by breathe.animateFloat(
        initialValue = 0.14f,
        targetValue = 0.30f,
        animationSpec = infiniteRepeatable(tween(1700, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "ringAlpha"
    )

    Box(
        modifier = Modifier.size(236.dp * scale).inkClickable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        // 外围墨圈：越外越淡，随响度一起涨
        Canvas(modifier = Modifier.fillMaxSize()) {
            val cx = size.width / 2f
            val cy = size.height / 2f
            val base = 62.dp.value * density * scale
            val amp = if (active) 0.92f + 0.55f * level.coerceIn(0f, 1f) else 0.86f + 0.03f * sin(t * 2f * Math.PI.toFloat())
            for (i in 0..2) {
                val r = base * amp * (1f + i * 0.44f)
                val alpha = (0.17f - i * 0.045f) * (if (active) 1f else 0.72f)
                drawCircle(
                    color = p.text.copy(alpha = alpha.coerceAtLeast(0.03f)),
                    radius = r,
                    center = Offset(cx, cy),
                    style = Stroke(width = (1f + i * 0.22f) * density)
                )
            }
        }
        // 墨线圆盘：外一圈呼吸墨线，内一层极淡墨底，中心一枚麦克风
        Box(
            modifier = Modifier
                .size(146.dp * scale)
                .clip(CircleShape)
                .background(p.text.copy(alpha = 0.035f)),
            contentAlignment = Alignment.Center
        ) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                val r = size.minDimension / 2f - 1f * density
                drawCircle(
                    color = p.text.copy(alpha = if (active) 0.42f else ringAlpha * 2.2f),
                    radius = r,
                    style = Stroke(1.3f * density)
                )
            }
            Icon(
                Icons.Filled.Mic,
                contentDescription = "开始听",
                tint = p.text.copy(alpha = if (active) 0.42f else 0.86f),
                modifier = Modifier.size(54.dp * scale)
            )
        }
    }
}

/**
 * 结果块（v2.1.86 重做主结果版式）
 *
 * 版式口径：一张纸签（方角、纸色、1px 淡墨线）＋ 眉标「识 所 得」＋ 朱砂小印「识」；
 * 歌名走 26sp 霞鹜文楷、下面一段短墨线断开，"歌手／专辑"分层不当一行挤；
 * 主操作是一条墨底「播放这首歌」（唯一实心块），其余动作降级成文字链，不再并排两块矩形；
 * 「其他版本／同批候选」用"标签 + 贯通细线 + 条数"的书页式小标题，行与行之间只留发丝线。
 */
@Composable
private fun ResultBlock(
    hit: com.jz.musichelper.network.RecognizeAdapter.Hit?,
    others: List<com.jz.musichelper.network.RecognizeAdapter.Hit>,
    busy: Boolean,
    noExact: Boolean,
    note: String,
    versions: List<com.jz.musichelper.model.Song>,
    originals: Set<String>,
    versionsBusy: Boolean,
    onPlay: (com.jz.musichelper.network.RecognizeAdapter.Hit) -> Unit,
    onAgain: () -> Unit,
    onLoadVersions: () -> Unit,
    onPlayVersion: (com.jz.musichelper.model.Song) -> Unit
) {
    val p = LocalPalette.current
    if (hit == null) return
    val artistTokens = hit.artist.split(Regex("[/、,，&·|]")).map { it.trim() }.filter { it.isNotBlank() }
    val artistLine = artistTokens.joinToString("、").ifBlank { "未知歌手" }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
    ) {
        // ---- 纸签本体 ----
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(p.surface)
                .border(1.dp, p.text.copy(alpha = 0.10f))
                .padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "识 所 得",
                    fontSize = 10.5.sp,
                    letterSpacing = 3.sp,
                    color = p.text3
                )
                Spacer(Modifier.width(8.dp))
                Box(Modifier.width(26.dp).height(1.dp).background(p.text.copy(alpha = 0.22f)))
                Spacer(Modifier.weight(1f))
                SealMark("识")
            }
            Spacer(Modifier.height(10.dp))
            Text(
                hit.title,
                fontSize = 26.sp,
                lineHeight = 33.sp,
                fontFamily = InkTitleFont,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 0.5.sp,
                color = p.text,
                maxLines = 2
            )
            Spacer(Modifier.height(9.dp))
            Box(Modifier.width(28.dp).height(1.dp).background(p.text.copy(alpha = 0.30f)))
            Spacer(Modifier.height(9.dp))
            Text(
                artistLine,
                fontSize = 13.sp,
                lineHeight = 20.sp,
                color = p.text2,
                maxLines = 2
            )
            if (hit.album.isNotBlank()) {
                Spacer(Modifier.height(3.dp))
                Text(
                    "《${hit.album}》",
                    fontSize = 11.sp,
                    lineHeight = 17.sp,
                    color = p.text3,
                    maxLines = 1
                )
            }
        }

        // 同名但没有这一位歌手的版本：先说清发生了什么（左侧一道朱砂细签，和"错误框"区分开）
        if (noExact && note.isNotBlank()) {
            Spacer(Modifier.height(12.dp))
            Row(modifier = Modifier.fillMaxWidth()) {
                Box(Modifier.width(2.dp).height(38.dp).background(p.heartOn.copy(alpha = 0.55f)))
                Spacer(Modifier.width(10.dp))
                Text(note, fontSize = 11.5.sp, lineHeight = 19.sp, color = p.text2)
            }
        }

        Spacer(Modifier.height(12.dp))

        // ---- 主操作：整条墨块，只此一处实心 ----
        val primaryText = when {
            noExact -> if (versionsBusy) "正在找其他版本…" else "看看其他版本"
            busy -> "正在起播…"
            else -> "播放这首歌"
        }
        val primaryEnabled = if (noExact) !versionsBusy else !busy
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp)
                .background(p.text.copy(alpha = if (primaryEnabled) 1f else 0.42f))
                .then(
                    if (primaryEnabled)
                        Modifier.inkClickable { if (noExact) onLoadVersions() else onPlay(hit) }
                    else Modifier
                ),
            contentAlignment = Alignment.Center
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (!noExact) {
                    Icon(
                        Icons.Filled.PlayArrow,
                        contentDescription = null,
                        tint = p.surface.copy(alpha = if (primaryEnabled) 1f else 0.6f),
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(Modifier.width(8.dp))
                }
                Text(
                    primaryText,
                    fontSize = 14.5.sp,
                    letterSpacing = 1.5.sp,
                    fontWeight = FontWeight.Medium,
                    color = p.surface.copy(alpha = if (primaryEnabled) 1f else 0.6f)
                )
            }
        }

        // ---- 次级动作：文字链，不再用第二个矩形 ----
        Spacer(Modifier.height(10.dp))
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            TextLink(if (busy) "再听一次（会中断起播）" else "再听一次", enabled = !busy) { onAgain() }
            if (!noExact) {
                Spacer(Modifier.width(20.dp))
                Box(Modifier.width(1.dp).height(18.dp).background(p.text.copy(alpha = 0.18f)))
                Spacer(Modifier.width(20.dp))
                TextLink(
                    when {
                        versionsBusy -> "正在找其他版本…"
                        versions.isNotEmpty() -> "其他版本 · ${versions.size} 条"
                        else -> "其他版本"
                    },
                    enabled = !versionsBusy
                ) { onLoadVersions() }
            }
        }

        // ---- 其他版本：只标「原唱」（判定在 App.loadRecVersions，排序与标记同一份口径）----
        if (versions.isNotEmpty()) {
            Spacer(Modifier.height(14.dp))
            SectionHead("其他版本", "${versions.size} 条")
            Column(modifier = Modifier.fillMaxWidth()) {
                versions.forEach { s ->
                    val original = ("${s.platform.name}_${s.platformID}") in originals
                    VersionRow(song = s, badge = if (original) "原唱" else null) { onPlayVersion(s) }
                }
            }
        } else if (!noExact && others.isNotEmpty() && versionsBusy.not()) {
            // 指纹同批给出的其他候选：只在还没找过"其他版本"时作为补充展示
            Spacer(Modifier.height(14.dp))
            SectionHead("同批候选", null)
            Column(modifier = Modifier.fillMaxWidth()) {
                others.take(4).forEach { h -> HitRow(h) { onPlay(h) } }
            }
        }
        // v2.1.85：底部让位——播放悬浮栏约占 72dp，留 84dp 保证最后一条不被压住
        Spacer(Modifier.height(84.dp))
    }
}

/** 朱砂小印：19dp 见方，细朱线 + 9sp 单字，只做标识不抢戏 */
@Composable
private fun SealMark(ch: String) {
    val p = LocalPalette.current
    Box(
        modifier = Modifier
            .size(19.dp)
            .background(p.heartOn.copy(alpha = 0.05f))
            .border(1.dp, p.heartOn.copy(alpha = 0.52f)),
        contentAlignment = Alignment.Center
    ) {
        Text(ch, fontSize = 9.sp, color = p.heartOn, letterSpacing = 0.5.sp)
    }
}

/** 书页式小标题：标签 + 一根贯通到底的细线 + 条数 */
@Composable
private fun SectionHead(label: String, count: String?) {
    val p = LocalPalette.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, fontSize = 10.5.sp, letterSpacing = 2.sp, color = p.text3)
        Spacer(Modifier.width(10.dp))
        Box(Modifier.weight(1f).height(1.dp).background(p.text.copy(alpha = 0.12f)))
        if (count != null) {
            Spacer(Modifier.width(10.dp))
            Text(count, fontSize = 10.sp, color = p.text3.copy(alpha = 0.75f))
        }
    }
}

/** 文字链：墨字、可点、无框；禁用时退到淡墨 */
@Composable
private fun TextLink(text: String, enabled: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(
        modifier = Modifier
            .then(if (enabled) Modifier.inkClickable { onClick() } else Modifier)
            .padding(vertical = 4.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text,
            fontSize = 12.5.sp,
            letterSpacing = 0.5.sp,
            color = p.text2.copy(alpha = if (enabled) 1f else 0.42f)
        )
    }
}

/** 一行版本：朱砂细签（仅「原唱」）+ 歌名 + 小印 + 歌手 · 平台，整行可点直接起播 */
@Composable
private fun VersionRow(
    song: com.jz.musichelper.model.Song,
    badge: String?,
    onClick: () -> Unit
) {
    val p = LocalPalette.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .inkClickable { onClick() }
            .padding(top = 10.dp, bottom = 9.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .width(2.dp)
                    .height(24.dp)
                    .background(if (badge == "原唱") p.heartOn.copy(alpha = 0.75f) else Color.Transparent)
            )
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        song.name,
                        fontSize = 14.5.sp,
                        color = p.text,
                        maxLines = 1,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (badge != null) {
                        Spacer(Modifier.width(7.dp))
                        Text(
                            badge,
                            fontSize = 9.sp,
                            color = p.heartOn,
                            letterSpacing = 0.5.sp,
                            modifier = Modifier
                                .border(1.dp, p.heartOn.copy(alpha = if (badge == "原唱") 0.50f else 0.26f))
                                .padding(horizontal = 3.dp, vertical = 1.dp)
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    listOf(song.singer.ifBlank { "未知歌手" }, song.platform.name).joinToString(" · "),
                    fontSize = 11.sp,
                    color = p.text3,
                    maxLines = 1
                )
            }
        }
        Spacer(Modifier.height(11.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(p.text.copy(alpha = 0.07f)))
    }
}

/** 失败/无权限：一句结论 + 一句怎么改 + 一个主按钮（不做情绪化措辞） */
@Composable
private fun NoteBlock(title: String, body: String, primary: String, onPrimary: () -> Unit) {
    val p = LocalPalette.current
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(title, fontSize = 17.sp, fontFamily = InkTitleFont, fontWeight = FontWeight.SemiBold, color = p.text)
        Spacer(Modifier.height(6.dp))
        Text(body, fontSize = 12.5.sp, lineHeight = 19.sp, color = p.text2)
        Spacer(Modifier.height(14.dp))
        InkButton(primary, primary = true, enabled = true, modifier = Modifier.fillMaxWidth()) { onPrimary() }
    }
}

/** 最近识过：本页的记录清单（点一行直接起播）；记录已持久化，最多 50 条，列表可滚 */
@Composable
private fun RecentBlock(
    recent: List<com.jz.musichelper.network.RecognizeAdapter.Hit>,
    seconds: Int,
    onPlay: (com.jz.musichelper.network.RecognizeAdapter.Hit) -> Unit,
    modifier: Modifier = Modifier
) {
    val p = LocalPalette.current
    Column(modifier = modifier.fillMaxWidth()) {
        if (recent.isEmpty()) {
            Text("第一次用？", fontSize = 17.sp, fontFamily = InkTitleFont, fontWeight = FontWeight.SemiBold, color = p.text)
            Spacer(Modifier.height(6.dp))
            Text(
                "把手机靠近正在外放的音箱，点上面的麦克风，听满 $seconds 秒就会出结果。",
                fontSize = 12.5.sp,
                lineHeight = 19.sp,
                color = p.text2
            )
            Spacer(Modifier.height(16.dp))
            Text("三件小事", fontSize = 11.sp, letterSpacing = 1.sp, color = p.text3)
            Spacer(Modifier.height(6.dp))
            listOf(
                "外放不用开满，能听清就行，太吵反而听不准。",
                "离音箱一米内、中间别挡着，成功率最高。",
                "地铁、街边这类环境噪音大的地方，换个安静点的地方再听。"
            ).forEach { tip ->
                Text("· $tip", fontSize = 11.5.sp, lineHeight = 18.sp, color = p.text2)
                Spacer(Modifier.height(4.dp))
            }
        } else {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text("最近识过", fontSize = 11.sp, letterSpacing = 1.sp, color = p.text3)
                Spacer(Modifier.weight(1f))
                Text("点一条直接播放", fontSize = 10.5.sp, color = p.text3.copy(alpha = 0.85f))
            }
            Spacer(Modifier.height(4.dp))
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
            ) {
                recent.forEach { h -> HitRow(h) { onPlay(h) } }
                // v2.1.85：底部让位——播放悬浮栏高约 72dp（宽度/5，且压在底栏之上），
                // 留 84dp 才能保证"最近识过"最后一条不被播放条压住（与首页/收藏/下载/历史的 60dp 口径同源，这里按实测多留一圈）
                Spacer(Modifier.height(84.dp))
            }
        }
    }
}

/** 一行候选：歌名 + 歌手，整行可点（底部发丝线，不用卡片） */
@Composable
private fun HitRow(hit: com.jz.musichelper.network.RecognizeAdapter.Hit, onClick: () -> Unit) {
    val p = LocalPalette.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .inkClickable { onClick() }
            .padding(vertical = 11.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                hit.title,
                fontSize = 14.sp,
                color = p.text,
                maxLines = 1,
                modifier = Modifier.weight(1f)
            )
            Text(hit.artist.ifBlank { "未知歌手" }, fontSize = 11.5.sp, color = p.text3, maxLines = 1)
        }
        Spacer(Modifier.height(8.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(p.text.copy(alpha = 0.08f)))
    }
}

/** 墨边按钮：主按钮墨底纸字，次按钮纸底墨字；禁用时整体退到淡墨 */
@Composable
private fun InkButton(
    text: String,
    primary: Boolean,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    val p = LocalPalette.current
    val alpha = if (enabled) 1f else 0.45f
    Box(
        modifier = modifier
            .height(44.dp)
            .clip(RoundedCornerShape(2.dp))
            .background(if (primary) p.text.copy(alpha = alpha) else Color.Transparent)
            .border(1.dp, p.text.copy(alpha = if (primary) 0f else 0.28f * alpha), RoundedCornerShape(2.dp))
            .then(if (enabled) Modifier.inkClickable { onClick() } else Modifier),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text,
            fontSize = 14.sp,
            fontWeight = if (primary) FontWeight.SemiBold else FontWeight.Normal,
            color = if (primary) p.surface.copy(alpha = alpha) else p.text2.copy(alpha = alpha),
            textAlign = TextAlign.Center
        )
    }
}

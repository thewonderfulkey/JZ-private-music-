package com.jz.musichelper.ui

import android.graphics.BitmapFactory
import android.provider.Settings
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.composed
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.drawable.toBitmap
import com.jz.musichelper.R
import com.jz.musichelper.data.HistoryStore
import com.jz.musichelper.data.NextTrackCache
import com.jz.musichelper.data.PlayerManager
import com.jz.musichelper.data.PlayCache
import com.jz.musichelper.data.PlayLog
import com.jz.musichelper.data.VoiceCapture
import com.jz.musichelper.model.PlayMode
import com.jz.musichelper.model.Song
import com.jz.musichelper.model.MusicPlatform
import com.jz.musichelper.model.StreamSource
import com.jz.musichelper.network.ApiError
import com.jz.musichelper.network.CoverResolver
import com.jz.musichelper.network.LyricsService
import com.jz.musichelper.network.NameMatch
import com.jz.musichelper.network.NetworkProbe
import com.jz.musichelper.network.RecognizeAdapter
import com.jz.musichelper.network.RecognizeScore
import com.jz.musichelper.network.NeteaseFingerprint
import com.jz.musichelper.network.NeteaseRecognizer
import com.jz.musichelper.network.asCand
import com.jz.musichelper.network.toHit
import com.jz.musichelper.network.SearchService
import com.jz.musichelper.network.SameSongCrossResolver
import com.jz.musichelper.network.SourcePicker
import com.jz.musichelper.network.StudioPick
import com.jz.musichelper.network.UrlResolver
import com.jz.musichelper.network.YaohuKuwoAdapter
import com.jz.musichelper.ui.theme.AppBackground
import com.jz.musichelper.ui.theme.PaperBrush
import com.jz.musichelper.ui.theme.AppTheme
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.flow.first
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.roundToInt

// v2.1.9：底栏实际高度（4 top + 44 icon + 2 + 12 label 行高 + 2 + 6 bottom = 70dp）。
// MiniPlayer 的 bottomPad 与此常量同一来源，保证播放条底边与底栏顶 0 间隙严丝合缝
private val BOTTOM_BAR_HEIGHT = 70.dp

// ===== 全局导航与播放状态 =====
object AppState {
    val currentSong = mutableStateOf<Song?>(null)          // 正在播放页覆盖
    val lastSong = mutableStateOf<Song?>(null)             // MiniPlayer 显示（最近打开的歌曲）
    val playlist = mutableStateOf<List<Song>>(emptyList()) // 播放队列
    val playIndex = mutableStateOf(-1)
    val playMode = mutableStateOf(
        runCatching { PlayMode.valueOf(HistoryStore.loadPlayMode()) }.getOrDefault(PlayMode.LIST_LOOP)
    )
    val tab = mutableStateOf(MainTab.HOME)                 // 底部 Tab（提升到全局：返回键需要感知）
    val searchActive = mutableStateOf(false)               // 首页是否处于搜索结果态（返回键用于清空结果）
    // 首页搜索态数据（方案A：提升为全局与 searchActive 同生命周期——切 Tab 离开首页不销毁，返回后恢复搜索结果）
    val searchKeyword = mutableStateOf("")
    val searchResults = mutableStateOf<List<SearchService.PlatformResult>>(emptyList())
    val searching = mutableStateOf(false)
    val openPlaylist = mutableStateOf<EditorPlaylist?>(null) // 编辑精选歌单页覆盖（本地内置歌曲，点单曲才搜索）
    // v2.1.83：听歌识曲从首页入口条/全屏浮层改成底层栏独立页（第 2 格）
    val recAutoStart = mutableStateOf(false)               // 从播放页三点菜单进来时，进页即听一次
    val recPlayBusy = mutableStateOf(false)                // 识别结果正在后台检索取流（防重复点击）
    // v2.1.84：识曲历史持久化（退出 App 再进来仍在），条数与底层栏「历史」一致（50 条）
    val recRecent = mutableStateOf(
        runCatching { HistoryStore.loadRecHistory() }
            .getOrDefault(emptyList())
    )
    // v2.1.84：识曲时长可配置（右上角按钮，5/10/15/20 秒，持久化）
    val recSeconds = mutableStateOf(
        runCatching { HistoryStore.loadRecSeconds() }.getOrDefault(VoiceCapture.DEFAULT_SECONDS)
    )
    // v2.1.81：识曲状态机整体搬到应用级作用域。
    // 上一版把采集跑在浮层的 LaunchedEffect 里，浮层一被移除（重试 / 授权返回 / 关浮层）Compose 就取消该协程，
    // 而 runCatching 把 CancellationException 一起吞了 → 界面上直接显示 "The coroutine scope left the composition"。
    val recPhase = mutableStateOf(RecPhase.PREPARE)
    val recLevel = mutableStateOf(0f)
    val recProgress = mutableStateOf(0f)
    val recHits = mutableStateOf<List<RecognizeAdapter.Hit>>(emptyList())
    val recError = mutableStateOf("")
    // v2.1.92：双通道打分的"识别依据"（酷狗 xx ／ 网易 xx → 采用谁），显示在结果卡上
    val recScoreNote = mutableStateOf("")
    // v2.1.85：识别结果的「其他版本」——按歌名重新检索各平台，原唱（=识别到的这位歌手）排最上方
    val recVersions = mutableStateOf<List<Song>>(emptyList())
    // v2.1.90：「原唱」判定结果（歌曲 key 集合），App 排序与界面小印共用这一份，避免两处口径漂移
    val recOriginals = mutableStateOf<Set<String>>(emptySet())
    val recVersionsBusy = mutableStateOf(false)
    val recVersionsTitle = mutableStateOf("")
    // v2.1.85：识别出的这一版在曲库里没有（只有同名不同曲/别人翻唱）→ 不硬播，改成让用户挑版本
    val recNoExact = mutableStateOf(false)
    private var recJob: Job? = null
    val lastPlayedKey = mutableStateOf("")                 // 最近一次已解析播放的歌曲 key（防退出播放页后重播）
    val resolvingSongKey = mutableStateOf<String?>(null)    // 正在后台解析取流的歌曲 key（全局，不随播放页销毁）
    val resolveError = mutableStateOf<Pair<String, String>?>(null)  // (songKey, 错误信息)：最近一次解析失败
    val deadSongKeys = mutableStateOf<Set<String>>(emptySet())      // 已确认无源的歌曲 key（搜索列表据此自动隐藏）
    val currentSource = mutableStateOf<StreamSource?>(null)         // 最近一次解析成功并开始播放的音源（播放页"音源来源"提示条）
    val currentSourceSongKey = mutableStateOf<String?>(null)        // currentSource 对应的歌曲 key（防显示错歌）
    private var consecutiveFailures = 0                    // 连续无源失败次数（自动跳过无源歌的上限控制）
    private const val AUTO_SKIP_MAX = 3                    // 无源时自动切歌最多连跳 3 首，避免空列表死循环
    private const val AUTO_SKIP_DELAY_MS = 600L            // 失败提示展示时长，再自动切下一首
    // v2.1.92：网易通道最长等待——WebView 起不来或网络打摆子时只走酷狗，不把整次识别拖死
    private const val NETEASE_WAIT_MS = 7_000L
    // v2.1.84：识曲点「播放」时先顶出来的占位歌曲 ID 前缀（只存活到真正候选解析完成）
    private const val PENDING_HIT_PREFIX = "__pending__:"
    // v2.1.29：无源时换源重试参数——每首歌走完三级解析：本平台后端 → 妖狐酷我 → 搜索同曲全平台候选；
    // 只有当"搜索结果里所有同歌手同歌曲的条目"都解析失败，才计入跳过额度（连跳上限 3 首，严格保持队列顺序）
    private const val RESOLVE_RETRY_MAX = 3
    private val RESOLVE_RETRY_DELAYS_MS = longArrayOf(2000L, 2500L, 3000L)
    // v2.1.68：网络不可用时（息屏 / Doze 被系统限流）不消耗跳过额度、不自动跳歌，
    // 原地等网络恢复再重试本曲——每 4s 探一次（v2.1.69 起 1 分钟后转 10s、5 分钟后转 30s 退避），最长等 45 分钟
    private const val NETWORK_WAIT_MAX_MS = 45 * 60 * 1000L
    private const val NETWORK_WAIT_STEP_MS = 4000L
    private var skipJob: Job? = null            // 待执行的"超时自动跳歌"任务（新歌起播时必须作废）
    private var networkWaitJob: Job? = null     // 等待网络恢复的续播任务
    private var prefetchJob: Job? = null        // 下一首本地预取任务

    // 取流/播放任务跑在应用级作用域：回退退出播放页也不中断解析
    private val globalScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** 首页搜索统一入口：状态全全局 + 应用级作用域执行（切 Tab 离开首页不中断搜索，返回后恢复结果与加载态） */
    fun search(keyword: String) {
        val k = keyword.trim()
        if (k.isEmpty()) return
        searchKeyword.value = k
        searchActive.value = true
        searching.value = true
        HistoryStore.recordSearch(k)
        globalScope.launch {
            try {
                searchResults.value = SearchService.searchAll(k, 50)
            } catch (e: Exception) {
                searchResults.value = emptyList()
            } finally {
                searching.value = false
            }
        }
    }

    /** 打开识曲页（只重置界面态；是否开录由页面上的麦克风决定） */
    fun openRecognize() {
        recPhase.value = RecPhase.PREPARE
        recError.value = ""
        recScoreNote.value = ""
        recHits.value = emptyList()
        recLevel.value = 0f
        recProgress.value = 0f
        clearRecVersions()
        // 从播放页三点菜单进来时，播放页是全屏覆盖层——不收掉它，识曲页会被一直盖着
        currentSong.value = null
        tab.value = MainTab.RECOGNIZE
    }

    /** 停掉正在跑的识曲（离开页面 / 切歌时用）：采集先停、再取消任务 */
    fun cancelRecognize() {
        VoiceCapture.cancel()
        recJob?.cancel()
        recJob = null
        if (recPhase.value == RecPhase.LISTEN || recPhase.value == RecPhase.THINK) {
            recPhase.value = RecPhase.PREPARE
        }
    }

    /**
     * 设听多久（5/10/15/20 秒）：写进偏好，下次进 App 还是这个值。
     * 只在非聆听态可用（聆听中途改时长会让进度与采样长度对不上）。
     */
    fun setRecSeconds(seconds: Int) {
        val v = seconds.coerceIn(VoiceCapture.MIN_SECONDS, VoiceCapture.MAX_SECONDS)
        recSeconds.value = v
        runCatching { HistoryStore.saveRecSeconds(v) }
    }

    /**
     * 开始一次识曲。取消异常一律向上抛（那是主动取消，不是失败）；
     * 其余异常统一收敛成中文提示——界面上绝不再出现英文异常原文。
     *
     * v2.1.91：酷狗 / 网易两条通道互为兜底。
     *  · 先录到 6 秒就发一次酷狗（EARLY_SECONDS），命中就立刻收工——常见情况仍是 6~7 秒出结果；
     *  · 6 秒没对上，继续录满 12 秒（网易指纹的最低窗口），然后用完整片段同时打酷狗 + 网易；
     *  · 酷狗优先，酷狗空才用网易——即「酷狗找不到的网易找」；
     *  · 网易这条同时也在跑酷狗第二遍（更长的片段更稳），所以「网易找不到的酷狗找」同样成立。
     */
    fun startRecognize() {
        recJob?.cancel()
        recHits.value = emptyList()
        recError.value = ""
        recScoreNote.value = ""
        clearRecVersions()
        recLevel.value = 0f
        recProgress.value = 0f
        recPhase.value = RecPhase.LISTEN
        recJob = globalScope.launch {
            // 录自己正在放的歌必然认成当前歌曲，先按停本机播放
            if (PlayerManager.isPlaying.value) PlayerManager.pause()

            // v2.1.92：不再"6 秒酷狗命中就立刻收工"。
            // 那条捷径的代价是：酷狗把歌认成别人的翻唱时直接错到底（张杰《我们都一样》一直播成翻唱），
            // 而网易手里的原唱根本没机会参与比较。现在录满窗口，两条通道都跑完再统一打分。
            val cap = try {
                VoiceCapture.record(
                    seconds = maxOf(recSeconds.value, VoiceCapture.MIN_SECONDS),
                    partialAtSeconds = 0,
                    onPartial = { },
                    onLevel = { recLevel.value = it },
                    onProgress = { recProgress.value = it }
                )
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                recError.value = recHint(e)
                recPhase.value = RecPhase.ERROR
                return@launch
            }
            if (cap.pcm.size < VoiceCapture.SAMPLE_RATE * 2) {
                recError.value = "这次没录到声音，检查手机是否静音、麦克风是否被别的应用占着"
                recPhase.value = RecPhase.EMPTY
                return@launch
            }
            // v2.1.82：判据从"平滑显示值 ×4"（等于要求 RMS>1.25% 满量程）改成实测 AC-RMS 的峰值，
            // 只有低到 -48dB 才算真静音——老判据在"对方手机外放很大声"时也会误判成没听到声音。
            if (cap.peakRms < 0.004f) {
                recError.value = "几乎没听到声音（峰值 ${dbOf(cap.peakRms)}）：把手机靠近声源，或调大外放音量"
                recPhase.value = RecPhase.EMPTY
                return@launch
            }
            recPhase.value = RecPhase.THINK
            val hits = try {
                // 两条通道并行：酷狗吃 8k 裸 PCM，网易吃本地指纹（12 秒窗口）。
                // v2.1.92：两边都等回来，统一交给 RecognizeScore 打分选最可信的一条。
                val kugouDeferred = async {
                    runCatching { RecognizeAdapter.recognize(cap.pcm) }.getOrNull().orEmpty()
                }
                val neteaseDeferred = async {
                    // 网易指纹只认 12 秒窗口：用户选 15/20 秒时也只取前 12 秒，避免指纹口径漂移
                    val pcm12 = trimToSeconds(cap.raw, cap.sourceRate, NeteaseFingerprint.WINDOW_SECONDS)
                    val fp = runCatching { NeteaseFingerprint.encode(pcm12, cap.sourceRate) }.getOrNull()
                    if (fp.isNullOrBlank()) emptyList()
                    else runCatching { NeteaseRecognizer.recognize(fp) }.getOrDefault(emptyList())
                }
                val kugou = kugouDeferred.await()
                // 网易最多等 7 秒：WebView 起不来时只走酷狗，不把整次识别拖死
                val netease = withTimeoutOrNull(NETEASE_WAIT_MS) { neteaseDeferred.await() }.orEmpty()
                if (neteaseDeferred.isActive) neteaseDeferred.cancel()
                fuseRecognize(kugou, netease)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                recError.value = recHint(e)
                recPhase.value = RecPhase.ERROR
                return@launch
            }
            if (hits.isEmpty()) {
                recError.value = "两条通道都没对上：贴近音箱、换安静点的地方再试一次（峰值 ${dbOf(cap.peakRms)}）"
                recPhase.value = RecPhase.EMPTY
            } else {
                recHits.value = hits
                recPhase.value = RecPhase.RESULT
            }
        }
    }

    /**
     * v2.1.92：两条通道 → 一份排序结果。
     * 打分规则全部在 RecognizeScore 里（纯函数、可单测），这里只做协议转换与"识别依据"落库。
     */
    private fun fuseRecognize(
        kugou: List<RecognizeAdapter.Hit>,
        netease: List<RecognizeAdapter.Hit>
    ): List<RecognizeAdapter.Hit> {
        val fused = RecognizeScore.fuse(
            kugou.map { it.asCand() },
            netease.map { it.asCand() }
        ) ?: return emptyList()
        recScoreNote.value = fused.note
        return fused.ranked.map { it.rep.toHit(it.score) }
    }

    /** 只保留前 N 秒的原始 PCM（16bit 单声道）；不足则原样返回 */
    private fun trimToSeconds(raw: ByteArray, rate: Int, seconds: Int): ByteArray {
        if (rate <= 0 || raw.isEmpty()) return raw
        val want = rate * 2 * seconds
        return if (raw.size > want) raw.copyOf(want) else raw
    }

    /** 异常 → 一句人话（不暴露英文异常、不把"被占用"说成"未授权"） */
    private fun recHint(e: Throwable): String = when (e) {
        is ApiError.HTTP -> when {
            e.code == 401 || e.code == 403 -> "识曲服务拒绝访问（${e.code}），稍后再试"
            else -> "识曲服务返回 ${e.code}，稍后再试"
        }
        is ApiError.Parse -> "识曲返回内容不认识，稍后再试"
        is java.io.IOException -> "网络不通，检查网络后再试"
        else -> {
            val m = e.message.orEmpty()
            when {
                m.contains("error_code") -> "识曲服务没认这条请求（${m.substringAfter('=')}），稍后再试"
                m.contains("麦克风") || m.contains("录音") || m.contains("AudioRecord") ->
                    "麦克风被占用或系统没放开（关掉录屏 / 语音通话再试）"
                else -> "识别失败，稍后再试"
            }
        }
    }

    /** 0..1 的 RMS → "-24dB"：失败提示带上实测响度，真静音还是阈值误判一眼能分清 */
    private fun dbOf(rms: Float): String {
        val db = 20.0 * log10(max(rms.toDouble(), 1e-6))
        return "${db.roundToInt()}dB"
    }

    /**
     * v2.1.83：识别结果直接起播。
     * 之前点「去播放」只是把「歌名 歌手」丢进首页搜索框，用户被甩到搜索结果、还得再点一次。
     * 现在在后台按「歌名+歌手」检索（与搜索同一套适配器），先按"歌名一致 → 歌手一致"收窄，
     * 再用 StudioPick 的录音室原唱得分挑一条，直接 openSong 起播并展开播放页。
     * 队列取同曲候选前 6 条，方便连听；选不到任何条目才报错，不静默失败。
     *
     * v2.1.84：顺序反过来——先弹播放页，再后台检索。用户点「播放」/点历史条目要"立刻看到播放页"，
     * 不能等搜索+取流完成才滑上来。
     *
     * v2.1.85：收窄匹配——歌名对、歌手也必须对。上一版第二级放宽到"只要歌名对"，
     * 于是《IVORY TOWER》被认成「泽野弘之 / SennaRin / 龙族 动画OST」后，真正起播的却是
     * 另一位歌手（Blackmore）的同名曲——用户录屏 t04 实证"识别对、放的不是同一首"。
     * 现在：同歌名 + 歌手（任一位命中即可，处理"甲、乙"多歌手）才起播；
     * 同名但只有别人的版本时，不硬播，保留结果卡并把「其他版本」直接列给用户挑。
     */
    fun playRecognizedHit(hit: RecognizeAdapter.Hit) {
        if (recPlayBusy.value) return
        recPlayBusy.value = true
        recError.value = ""
        recNoExact.value = false
        // v2.1.84：点「播放」/点历史条目要"立刻弹出播放页"——先去把播放页顶出来（占位歌曲 + 解析中态），
        // 检索与取流放到后台。上一版是先 searchAll 再 openSong，用户点完要等好几秒才滑上播放页。
        val pendingId = PENDING_HIT_PREFIX + System.currentTimeMillis()
        val pendingKey = MusicPlatform.QQ.name + pendingId
        val placeholder = Song(
            platform = MusicPlatform.QQ,
            platformID = pendingId,
            name = hit.title,
            singer = hit.artist,
            album = hit.album,
            durationSec = 0,
            picUrl = null
        )
        lastSong.value = placeholder
        currentSong.value = placeholder          // 全屏播放页随即滑入，页内显示「正在解析音源…」
        resolvingSongKey.value = pendingKey
        resolveError.value = null
        val titleCore = coreNameOf(hit.title)
        // v2.1.89：识曲给多人合作/节目版时，只用第一位歌手当查询词（见下方注释）
        val primaryArtist = hit.artist.split(Regex("[/、,，&·|]")).firstOrNull()?.trim().orEmpty()
        globalScope.launch {
            try {
                // v2.1.89：识曲起播的查询词从「歌名 + 全部歌手」改成「歌名 + 第一位歌手」。
                // 用户反馈：识别到张杰《我们都一样》后只能播到翻唱。实测识曲给的是综艺合作版
                // （张杰、胡迪、范如臣 /《异口同声 第十二期》），拿这三个人一起搜，网易只回 1 条——
                // 就是那条节目 Live，张杰 2008 录音室原唱（网易《明天过后》302s）根本进不了候选池，
                // 于是无论怎么点都落到节目版。改用「我们都一样 张杰」后，网易第一条即原唱，
                // 再交给 StudioPick 的录音室口径择优即可。全歌手查询保留为兜底（单人查不到时才发）。
                val kwPrimary = listOf(hit.title, primaryArtist).filter { it.isNotBlank() }.joinToString(" ")
                val kwFull = listOf(hit.title, hit.artist).filter { it.isNotBlank() }.joinToString(" ")
                val searchPool: suspend (String) -> List<Song> = { k ->
                    runCatching { SearchService.searchAll(k, 30) }.getOrNull().orEmpty()
                        .asSequence().flatMap { it.songs.asSequence() }.toList()
                }

                // v2.1.89：识曲命中的若是综艺/现场/DJ 这类版本（指纹接口给谁就是谁），
                // 先按**裸歌名**检索——不能带着那位翻唱歌手一起搜：「我们都一样 神仙哥哥」在网易前十条全是他的 DJ 版，
                // 原唱一条都进不来。裸歌名检索把整首曲子的所有版本收进池子，再挑录音室版。
                val hitVariant = RecognizeAdapter.Judge.isVariantHit(hit.title, hit.album)
                var pool = searchPool(if (hitVariant) hit.title else kwPrimary)
                // v2.1.88：同曲判定从"歌名整串相等"放宽到"核心歌名相等"。
                // 识别给的是裸名《IVORY TOWER》，各平台条目名常带 (feat. SennaRin) / - Orchestra Ver. - 这类括号或后缀，
                // 旧口径整串比较直接判"没有可播条目"——用户录屏里第一条原唱就是同一首，却只能看到「看看其他版本」。
                val coreOf: (List<Song>) -> List<Song> = { src ->
                    if (titleCore.isEmpty()) emptyList() else src.filter { coreNameOf(it.name) == titleCore }
                }
                // 歌手对得上才算这次识别的这首；同时排掉伴奏/现场/翻唱/片段等变体——
                // 它们剥括号后核心名与原名相同，不排会"识别对了却放出伴奏版"
                val bothOf: (List<Song>) -> List<Song> = { src ->
                    coreOf(src)
                        .filter { NameMatch.singerMatches(hit.artist, it.singer) }
                        .filterNot { REC_VARIANT_MARK.containsMatchIn(it.name) }
                }
                var sameCore = coreOf(pool)
                var sameBoth = bothOf(pool)
                if (sameBoth.isEmpty() && kwFull != kwPrimary) {
                    pool = pool + searchPool(kwFull)
                    sameCore = coreOf(pool)
                    sameBoth = bothOf(pool)
                }
                // 命中变体版时，若池子里还没有一条"干净录音室版"，再用「歌名＋第一位歌手」补一轮
                var studioCand = sameCore.filter {
                    !REC_VARIANT_MARK.containsMatchIn(it.name) && !StudioPick.isLiveAlbum(it.album)
                }
                if (hitVariant && studioCand.isEmpty()) {
                    pool = pool + searchPool(kwPrimary)
                    sameCore = coreOf(pool)
                    sameBoth = bothOf(pool)
                    studioCand = sameCore.filter {
                        !REC_VARIANT_MARK.containsMatchIn(it.name) && !StudioPick.isLiveAlbum(it.album)
                    }
                }
                val playable = if (hitVariant) {
                    // 有可信原唱（≥2 张正式专辑、时长一致）时，起播优先落到它身上，而不是随便一条干净版
                    val canon = RecognizeAdapter.Judge.canonicalSingers(sameCore, hit.title)
                    val cleanStudio = studioCand.filter { StudioPick.isCleanTitle(it.name) }.ifEmpty { studioCand }
                    if (canon.isEmpty()) cleanStudio
                    else cleanStudio.filter { s -> canon.any { normForMatch(s.singer).contains(it) } }.ifEmpty { cleanStudio }
                } else {
                    sameBoth
                }
                // 宽松集只用于"列其他版本"，不参与起播判定
                val sameTitle = pool.filter { NameMatch.titleMatches(hit.title, it.name) }
                val best = if (playable.isNotEmpty()) StudioPick.pickBest(playable) else null
                // 占位页是否还挂着：用户中途按返回收起播放页后，不再把他强行拽回来
                val stillPending = currentSong.value?.platformID == pendingId
                if (best == null) {
                    if (stillPending) currentSong.value = null
                    if (lastSong.value?.platformID == pendingId) lastSong.value = null
                    if (resolvingSongKey.value == pendingKey) resolvingSongKey.value = null
                    rememberHit(hit)
                    if (sameCore.isNotEmpty() || sameTitle.isNotEmpty()) {
                        // 同名、但没有这一位歌手的版本：不硬播别人的同名曲/翻唱，改成列版本让用户挑
                        recNoExact.value = true
                        recError.value =
                            "听出了《${hit.title}》· ${hit.artist}，但曲库里没有这一位歌手的可播条目——下面是别的版本，点一条播放"
                        recPhase.value = RecPhase.RESULT
                        loadRecVersions(hit)
                    } else {
                        recError.value = "听出了《${hit.title}》，但这几平台都没给出可播的条目，过会儿再试一次"
                        recPhase.value = RecPhase.EMPTY
                    }
                    return@launch
                }
                rememberHit(hit)
                if (stillPending) {
                    val queue = playable.distinctBy { "${it.platform.name}_${it.platformID}" }.take(6)
                    openSong(best, queue = queue.ifEmpty { listOf(best) })
                } else if (lastSong.value?.platformID == pendingId) {
                    lastSong.value = null
                }
            } finally {
                if (resolvingSongKey.value == pendingKey) resolvingSongKey.value = null
                recPlayBusy.value = false
            }
        }
    }

    /** 歌手串拆词：一个识别结果常带"甲、乙"或"甲/乙"多位歌手，任一命中即算同一位 */
    private fun splitArtists(raw: String): List<String> =
        raw.split(Regex("[/、,，&·|]")).map { normForMatch(it) }.filter { it.isNotBlank() }

    /** v2.1.85：清掉上一次的「其他版本」列表（重新识别 / 离开页面时） */
    fun clearRecVersions() {
        recVersions.value = emptyList()
        recOriginals.value = emptySet()
        recVersionsBusy.value = false
        recVersionsTitle.value = ""
        recNoExact.value = false
    }

    /**
     * v2.1.85：「其他版本」——按歌名重新检索（不限歌手），把同名的其他歌手版本收拢，
     * 原唱（=识别到的这位歌手）排最上方，其余按平台返回顺序；同一位歌手只留一条。
     * 用户点这个按钮的诉求就是"识别对了但播放的不是同一首，我要自己挑一版"。
     */
    fun loadRecVersions(hit: RecognizeAdapter.Hit) {
        if (recVersionsBusy.value) return
        if (recVersions.value.isNotEmpty() && recVersionsTitle.value == hit.title) return
        recVersionsBusy.value = true
        recVersionsTitle.value = hit.title
        val tokens = splitArtists(hit.artist)
        val titleNorm = normForMatch(hit.title)
        globalScope.launch {
            try {
                val results = runCatching { SearchService.searchAll(hit.title, 40) }.getOrNull().orEmpty()
                val pool = results.asSequence().flatMap { it.songs.asSequence() }.toList()
                val same = pool.filter {
                    val n = normForMatch(it.name)
                    n == titleNorm || (titleNorm.length >= 2 && n.contains(titleNorm))
                }
                // v2.1.90：「原唱」按 D 口径判——
                //  C：识曲命中本身是录音室版 → 识曲歌手就是原唱（此时可信）；
                //  A：命中综艺/现场/改编版 → 用「同一歌手 ≥2 张正式专辑、时长一致」推断（Judge.canonicalSingers）。
                val hitVariant = RecognizeAdapter.Judge.isVariantHit(hit.title, hit.album)
                val canonicalSingers =
                    if (hitVariant) RecognizeAdapter.Judge.canonicalSingers(same, hit.title) else emptySet()
                val isOriginal = { s: Song ->
                    val sn = normForMatch(s.singer)
                    if (!hitVariant) {
                        tokens.isNotEmpty() && tokens.any { sn.contains(it) || it.contains(sn) }
                    } else {
                        canonicalSingers.any { sn.contains(it) || it.contains(sn) }
                    }
                }
                // 正式专辑（专辑名不是歌名本身、也不是现场/综艺）——只用于把可靠的版本排前面
                val isFormal = { s: Song ->
                    s.album.isNotBlank() &&
                        !RecognizeAdapter.Judge.isSameAlbumAsTitle(s.album, hit.title) &&
                        !StudioPick.isLiveAlbum(s.album) && !RecognizeAdapter.Judge.isVarietyAlbum(s.album)
                }
                val ordered = same
                    // 按「歌手 + 专辑 + 时长」去重：同一位歌手的不同录音要各自留在列表里
                    // （张杰《明天过后》302s 与《One Chance》303s 是同一版录音的两条收录，
                    //   原唱判定靠这两条互证；旧口径按歌手去重会把《明天过后》直接顶掉）
                    .distinctBy {
                        normForMatch(it.singer) + "|" + normForMatch(it.album) + "|" + it.durationSec
                    }
                    .sortedWith(
                        compareByDescending<Song> { isOriginal(it) }
                            .thenByDescending { isFormal(it) }
                    )
                recOriginals.value = ordered.filter { isOriginal(it) }
                    .map { "${it.platform.name}_${it.platformID}" }
                    .toSet()
                recVersions.value = ordered.take(12)
            } finally {
                recVersionsBusy.value = false
            }
        }
    }

    /** 比对用归一化：去空格、标点、括号（(Live)【伴奏】这类尾巴不参与匹配） */
    private fun normForMatch(s: String): String =
        s.lowercase().replace(Regex("[\\s\\p{Punct}·、，。（）()【】《》\\[\\]、]"), "")

    /**
     * v2.1.88：核心歌名——先让 StudioPick 剥掉「(feat. xxx)」「(龙族动画OP)」「- Orchestra Ver. -」这类
     * 括号/改编后缀，再归一化（小写 + 去标点空格）。识曲给的是裸名，各平台条目名普遍带后缀，
     * 只有按核心名比较才不会把同一首原唱判成"没有可播条目"；而《IVORY》这种真的不同的短名仍然对不上。
     */
    private fun coreNameOf(raw: String): String =
        StudioPick.coreName(raw).lowercase()
            .replace(Regex("[\\s\\p{Punct}·、，。（）()【】《》\\[\\]、]"), "")

    /** v2.1.88：伴奏/现场/翻唱/片段这类"同一首歌的另一个版本"标记——识曲自动起播时一律跳过 */
    private val REC_VARIANT_MARK = Regex(
        "伴奏|伴唱|纯音乐|instrumental|钢琴|翻唱|cover|remix|live|现场|演唱会|片段|剪辑|ktv|dj|消音|合唱",
        RegexOption.IGNORE_CASE
    )

    /** 记一条「最近识过」：同歌同歌手去重，最多 50 条（与底层栏「历史」同口径），并即时落盘 */
    private fun rememberHit(hit: RecognizeAdapter.Hit) {
        val cur = recRecent.value
        val next = (listOf(hit) + cur.filterNot { it.title == hit.title && it.artist == hit.artist })
            .take(HistoryStore.REC_HISTORY_MAX)
        recRecent.value = next
        runCatching { HistoryStore.saveRecHistory(next) }
    }

    /** 打开播放页（并立即后台取流，回退不中断）；queue 为空时沿用已有队列 */
    fun openSong(song: Song, queue: List<Song>? = null, allowCrossRetry: Boolean = false) {
        // v2.1.30：兜底成单曲队列——此前 queue=null 且 playlist 为空时 playlist 一直空着，
        // 悬浮栏左右切歌第一行就 return（点上去毫无反应）
        val q = (queue ?: playlist.value).ifEmpty { listOf(song) }
        val idx = q.indexOfFirst { it.platform == song.platform && it.platformID == song.platformID }
        playIndex.value = if (idx >= 0) idx else 0
        playlist.value = q
        lastSong.value = song
        currentSong.value = song
        HistoryStore.recordSong(song)
        resolveAndPlayIfNeeded(song, allowCrossRetry)
    }

    /** 歌单顺序队列替换（编辑精选点歌后后台补齐）：保持当前播放下标对齐，列表循环严格按队列顺序切歌 */
    fun replaceQueue(queue: List<Song>, playIndex: Int) {
        if (queue.isEmpty()) return
        playlist.value = queue
        this.playIndex.value = playIndex.coerceIn(0, queue.size - 1)
    }

    /**
     * v2.1.30：切歌队列兜底。
     * 现象（用户 11:38 录屏）：从猜你喜欢点进《龙文》后，悬浮栏左右切歌点了完全没反应。
     * 代码侧的两条确定成因都在这里兜住：
     *   ① playlist 为空（编辑精选点歌时曾传 queue=null，若此前没有队列，nextSong 第一行就 return）；
     *   ② playlist 只有 1 首（后台补队列还没回来时点切歌，(idx±1)%1 原地不动）。
     * 兜底：用「当前歌 + 收藏 + 最近播放」组成至少 2 首的队列；仍不足则返回原队列。
     */
    private fun ensureQueue(): List<Song> {
        val cur = playlist.value
        if (cur.size >= 2) return cur
        val current = lastSong.value
        val backup = buildList {
            current?.let { add(it) }
            addAll(HistoryStore.favoritesState.toList())
            runCatching { HistoryStore.loadRecentSongs() }.getOrNull()?.let { addAll(it) }
        }.distinctBy { "${it.platform.name}_${it.platformID}" }
        if (backup.size >= 2) {
            playlist.value = backup
            playIndex.value = current?.let { c ->
                backup.indexOfFirst { it.platform == c.platform && it.platformID == c.platformID }
            }?.coerceAtLeast(0) ?: 0
            return backup
        }
        return cur
    }

    fun nextSong() {
        val q = ensureQueue()
        if (q.isEmpty()) return
        // v2.1.30：单曲队列 → 原逻辑取模回原位，视觉上等于「点了没反应」，改为对当前曲重新取流
        if (q.size == 1) {
            resolveAndPlayIfNeeded(q[0], allowCrossRetry = true)
            return
        }
        val from = playIndex.value.coerceIn(0, q.size - 1)
        // 随机模式下手动切下一首也随机（不重复当前）；其余模式按顺序取模
        val idx = if (playMode.value == PlayMode.SHUFFLE) {
            var r = from
            while (r == from) r = (0 until q.size).random()
            r
        } else {
            (from + 1) % q.size
        }
        playIndex.value = idx
        val s = q[idx]
        lastSong.value = s
        // 只有播放页已打开时才同步 currentSong（避免悬浮条切歌弹出播放页）
        if (currentSong.value != null) currentSong.value = s
        // v2.1.27：切歌同样启用跨平台兜底（妖狐酷我首轮即补搜），与点击/自动连播行为一致
        resolveAndPlayIfNeeded(s, allowCrossRetry = true)
    }

    fun prevSong() {
        val q = ensureQueue()
        if (q.isEmpty()) return
        if (q.size == 1) {
            resolveAndPlayIfNeeded(q[0], allowCrossRetry = true)
            return
        }
        val from = playIndex.value.coerceIn(0, q.size - 1)
        // v2.1.30：随机模式下「上一曲」此前永远走顺序取模，与模式不一致，这里与 nextSong 对齐
        val idx = if (playMode.value == PlayMode.SHUFFLE) {
            var r = from
            while (r == from) r = (0 until q.size).random()
            r
        } else {
            (from - 1 + q.size) % q.size
        }
        playIndex.value = idx
        val s = q[idx]
        lastSong.value = s
        if (currentSong.value != null) currentSong.value = s
        // v2.1.27：上一曲同样启用跨平台兜底
        resolveAndPlayIfNeeded(s, allowCrossRetry = true)
    }

    /**
     * 全局取流任务：点击/切歌/自动连播统一入口（搜索、猜你喜欢、热门、收藏、历史全部走这里）。
     * 应用级协程 + 防重入；解析成功后播放，失败记录错误（播放页/悬浮条可展示）。
     * v2.1.29：解析逻辑统一为三级，任何入口行为一致——
     *   ① 本平台后端（按平台 ID 直连）
     *   ② 妖狐酷我（按"歌名+歌手"搜索同曲，官方直链 + 身份校验）
     *   ③ 同曲跨平台补源（与搜索同一个 SearchService，把"搜索同样的歌"能命中的全部平台条目逐条取流）
     * 只有当 ①②③ 全部失败（即搜索结果里所有同歌手同歌曲的条目都解析失败了）才允许跳过，
     * 保证"明明能解析的歌绝不被跳过"。跨平台结果跳过 ±5s 时长硬校验（平台间时长存在合法差异）。
     * allowCrossRetry 参数保留仅为兼容既有调用点，v2.1.29 起不再决定行为。
     */
    @Suppress("UNUSED_PARAMETER")
    fun resolveAndPlayIfNeeded(song: Song, allowCrossRetry: Boolean = false) {
        val key = song.platform.name + song.platformID
        if (resolvingSongKey.value == key) return          // 同一首歌解析中，不重复发起
        // v2.1.69：加 isPlaying 条件——播完/暂停后同一首歌（单曲队列循环）也要允许重新取流，
        // 否则"队列只有一首歌"时会一直停在状态上，点了没反应
        if (lastPlayedKey.value == key && PlayerManager.currentUrl.value != null &&
            PlayerManager.isPlaying.value
        ) return  // 已在播
        resolvingSongKey.value = key
        resolveError.value = null
        PlayLog.log("resolve start key=$key cross=$allowCrossRetry")
        // 与取流并发的歌词预取：点击/切歌瞬间即开始请求歌词（4h 缓存 + in-flight 去重），
        // 播放页打开时直接读缓存，歌出声时歌词已就绪；失败静默，不影响取流
        globalScope.launch { runCatching { LyricsService.fetch(song) } }
        globalScope.launch {
            val q = HistoryStore.loadQuality()
            var attempts = 0
            var waitingNetwork = false
            // v2.1.29：记录本轮已尝试过的"同曲候选"（跨重试轮次复用，避免重复打同一批候选）
            val triedCandidates = mutableSetOf<String>()
            while (true) {
                // ① 第 1 级：本平台后端 与 妖狐酷我（按"歌名+歌手"搜索同曲，官方直链+身份校验）并发首发，
                //    谁先解析成功用谁——不再串行等两边都超时（原来单后端 12s + 妖狐 12s 最坏 24s，用户会以为卡死）
                // ② 第 2 级：同曲跨平台补源（见 resolveSourceOnce）
                val src = resolveSourceOnce(song, q, triedCandidates)
                if (src != null) {
                    AppState.lastPlayedKey.value = key
                    consecutiveFailures = 0
                    skipJob?.cancel()          // 新歌起播，作废上一轮排着的"超时自动跳歌"
                    networkWaitJob?.cancel()   // 已取到源，网络等待任务收工
                    PlayLog.log("resolve OK key=$key backend=${src.backendName}")
                    resolveError.value = null   // v2.1.70：成功起播必须清掉"暂无可用的播放源"红字（此前重试轮成功没清，界面会一直挂着）
                    // v2.1.7：记录实际音源（播放页"音源来源"提示条）；播放时带曲目时长做 ±5s 硬校验（绝对准确）
                    currentSource.value = src
                    currentSourceSongKey.value = key
                    // 跨平台兜底结果（平台不一致）时长存在合法差异，跳过硬校验；同平台仍严格 ±5s
                    val expected = if (src.platform == song.platform) song.durationSec else null
                    PlayerManager.play(src.url, expectedDurationSec = expected, sourceLabel = src.backendName)
                    // v2.1.85：取到流就把这一首整首缓存到本地（单槽，切歌/播完即删）；
                    // 缓存进度由播放页进度条渲染，整首落盘后把播放源切到本地文件——跳转不再重新取流。
                    PlayCache.attach(key, src.url)
                    switchToCachedWhenReady(key)
                    // v2.1.70：前台有网时就把下一首整首下到本地，播完直接从本地起播——
                    // 后台/息屏系统会限制联网，这一步提前做掉，切歌就不再依赖当场能不能联网
                    prefetchNext()
                    break
                }
                // 本平台 + 妖狐 + 全部同曲候选都无解：提示换源中，有限轮次等待网络抖动后重试
                AppState.resolveError.value = key to "暂无可用的播放源，正在换源重试…"
                if (attempts >= RESOLVE_RETRY_MAX) {
                    // v2.1.68：先判"是不是网络被系统掐了"。息屏 / Doze 下后台出网可能被限流，
                    // 此时取流失败 ≠ 这首歌没源；不能拿它去消耗跳过额度，否则会一首接一首静默跳过。
                    // 判定为网络问题：原地等网络恢复后重试本曲，不自动跳歌。
                    // v2.1.69：息屏本身就按"网络可能不通"处理（Doze 下探测也会失败，甚至探不动），
                    // 只要屏幕是黑的就不判无源、不跳歌；探测改为 IO 线程，绝不阻塞主线程。
                    val screenOff = !NetworkProbe.isInteractive()
                    val online = NetworkProbe.isReachable()
                    PlayLog.log("resolve failed key=$key screenOff=$screenOff online=$online ${NetworkProbe.state()}")
                    if (screenOff || !online) {
                        PlayLog.log("resolve NETBLOCK key=$key")
                        AppState.resolveError.value =
                            key to if (screenOff) "息屏中取流受阻，等待网络恢复后自动续播…"
                            else "网络暂时不可用，恢复后自动续播…"
                        waitingNetwork = true
                        waitNetworkThenRetry(song)
                        break
                    }
                    // 确认"所有同歌手同歌曲的条目都解析失败"后才计入无源（搜索列表据此隐藏该歌）
                    deadSongKeys.value = deadSongKeys.value + "${song.platform.name}_${song.platformID}"
                    PlayLog.log("resolve NOSOURCE key=$key")
                    break
                }
                attempts += 1
                delay(RESOLVE_RETRY_DELAYS_MS.getOrElse(attempts - 1) { 3000L })
                if (resolvingSongKey.value != key) break          // 期间用户已切到别的歌，放弃本歌重试
            }
            // 本歌重试耗尽仍无源：计入一次跳过额度，短暂提示后自动切下一首（不再依赖播放页是否打开，后台同样自动继续）
            // v2.1.68：等网络的情况下不跳歌（waitingNetwork=true），避免"看不见的时候把队列连跳 3 首"
            if (!waitingNetwork && lastSong.value != null && resolveError.value?.first == key) {
                consecutiveFailures += 1
                if (consecutiveFailures <= AUTO_SKIP_MAX) {
                    PlayLog.log("autoSkip schedule key=$key failures=$consecutiveFailures")
                    skipJob?.cancel()
                    skipJob = globalScope.launch {
                        delay(AUTO_SKIP_DELAY_MS)
                        // 双重确认：没有别的歌在解析、且失败提示仍是本歌——否则说明情况已变（已起播/已换歌），不能跳
                        if (resolvingSongKey.value == null && resolveError.value?.first == key &&
                            !PlayerManager.isPlaying.value
                        ) {
                            PlayLog.log("autoSkip fire key=$key")
                            nextSong()
                        }
                    }
                }
            }
            if (AppState.resolvingSongKey.value == key) AppState.resolvingSongKey.value = null
        }
    }

    /**
     * v2.1.85：等整首缓存落盘，把播放源从在线 URL 切到本地文件（从当前位置接着放）。
     * 切过去之后 seek 是本地读取，不再发 HTTP Range、不再等网络——这正是用户要的"跳的时候不用等"。
     * 只在"还停在这首歌"时切：中间切过歌，key 已变，直接作废（文件也被 attach 清掉）。
     */
    private fun switchToCachedWhenReady(key: String) {
        globalScope.launch {
            val ready = withTimeoutOrNull(120_000L) {
                PlayCache.state.first { it.songKey == key && it.done && it.localPath != null }
            } ?: return@launch
            val local = ready.localPath ?: return@launch
            if (lastPlayedKey.value != key) return@launch
            val curUrl = PlayerManager.currentUrl.value
            if (curUrl == null || curUrl.startsWith("/") || curUrl.startsWith("file://")) return@launch
            val pos = PlayerManager.currentPositionMs().coerceAtLeast(0L)
            PlayLog.log("cache switch key=$key pos=$pos local=$local")
            PlayerManager.play(
                local,
                expectedDurationSec = null,      // 本地文件就是刚才那段流，时长校验没必要再跑
                sourceLabel = "本地缓存",
                startAtMs = pos
            )
        }
    }

    /**
     * v2.1.70：纯取流（不播放），供正式播放与"下一首预取"共用。
     * ① 本平台后端 + 妖狐酷我并发首发（13s 上限，谁先成功用谁）
     * ② 同曲跨平台补源：搜索同样的歌能命中的全部平台条目逐条取流，任意一条成功即返回
     */
    private suspend fun resolveSourceOnce(
        song: Song,
        q: com.jz.musichelper.model.QualityLevel,
        tried: MutableSet<String>
    ): com.jz.musichelper.model.StreamSource? {
        var src: com.jz.musichelper.model.StreamSource? = kotlinx.coroutines.coroutineScope {
            val ch = kotlinx.coroutines.channels.Channel<com.jz.musichelper.model.StreamSource>(2)
            val a = launch {
                runCatching { UrlResolver.resolveAll(song, q) }.getOrNull()
                    ?.let { SourcePicker.pick(it.sources, q) }?.let { ch.trySend(it) }
            }
            val b = launch {
                if (song.platform != MusicPlatform.KUWO) {
                    runCatching { YaohuKuwoAdapter().resolve(song, q) }.getOrNull()?.let { ch.trySend(it) }
                }
            }
            val first = kotlinx.coroutines.withTimeoutOrNull(13_000L) { ch.receive() }
            a.cancel(); b.cancel(); ch.close()
            first
        }
        if (src == null) {
            src = runCatching { SameSongCrossResolver.resolve(song, q, tried) }.getOrNull()
        }
        return src
    }

    /**
     * v2.1.71：后台连播缓存窗口。
     * 只对"能确定后面是谁"的模式预取：单曲循环预取当前曲，列表循环预取后面 3 首；随机不预取。
     * 这样即便系统在后台冻结联网，也能按缓存继续往下唱几首，不会一首就断。
     */
    private fun prefetchNext() {
        val q = playlist.value
        if (q.isEmpty()) return
        val idx = playIndex.value
        if (idx !in q.indices) return
        val targets = when (playMode.value) {
            PlayMode.SINGLE_LOOP -> listOf(q[idx])
            PlayMode.LIST_LOOP -> (1..3).map { q[(idx + it) % q.size] }
                .distinctBy { it.platform.name + it.platformID }
            PlayMode.SHUFFLE -> return
        }
        val missing = targets.filter { NextTrackCache.match(it.platform.name + it.platformID) == null }
        if (missing.isEmpty()) {
            PlayLog.log("prefetch hit all n=${targets.size}")
            return
        }
        prefetchJob?.cancel()
        prefetchJob = globalScope.launch {
            delay(1200)                       // 先让当前这首起播，别抢带宽
            val quality = runCatching { HistoryStore.loadQuality() }
                .getOrDefault(com.jz.musichelper.model.QualityLevel.LOSSLESS)
            for (song in missing) {
                if (!isActive) return@launch
                val key = song.platform.name + song.platformID
                var done = false
                for (round in 0 until 2) {
                    if (done) break
                    val src = runCatching { resolveSourceOnce(song, quality, mutableSetOf()) }.getOrNull()
                    if (src == null) {
                        PlayLog.log("prefetch nosource key=$key round=$round")
                    } else {
                        val path = NextTrackCache.download(src.url, key)
                        PlayLog.log("prefetch ${if (path != null) "done" else "fail"} key=$key backend=${src.backendName}")
                        if (path != null) done = true
                    }
                    if (!done) delay(4000)
                }
            }
        }
    }

    /** v2.1.70：从本地预取文件起播（播完切歌不再依赖当场联网） */
    private fun playFromCache(song: Song, path: String, tag: String) {
        val key = song.platform.name + song.platformID
        PlayLog.log("play cache key=$key tag=$tag")
        AppState.lastPlayedKey.value = key
        consecutiveFailures = 0
        skipJob?.cancel()
        networkWaitJob?.cancel()
        resolveError.value = null
        currentSource.value = null
        currentSourceSongKey.value = null
        resolvingSongKey.value = null
        PlayerManager.play(path, expectedDurationSec = song.durationSec, sourceLabel = "本地预取")
        prefetchNext()
    }

    /**
     * v2.1.68：网络不可用时原地等待恢复，再重试本曲（不跳歌）。
     * 覆盖"息屏播完 → 取流被 Doze 掐断 → 长时间无声"的场景：网络一回来就续播同一首。
     */
    private fun waitNetworkThenRetry(song: Song) {
        val key = song.platform.name + song.platformID
        if (networkWaitJob?.isActive == true) return
        networkWaitJob = globalScope.launch {
            var waited = 0L
            var probes = 0
            PlayLog.log("waitNetwork start key=$key ${NetworkProbe.state()}")
            while (waited < NETWORK_WAIT_MAX_MS) {
                // v2.1.69：退避——1 分钟内 4s 一探，5 分钟内 10s，之后 30s；息屏整夜也别把电和主线程耗掉
                val step = when {
                    waited < 60_000L -> NETWORK_WAIT_STEP_MS
                    waited < 300_000L -> 10_000L
                    else -> 30_000L
                }
                delay(step)
                waited += step
                val cur = lastSong.value
                if (cur == null || (cur.platform.name + cur.platformID) != key) {
                    PlayLog.log("waitNetwork abandon key=$key")
                    return@launch
                }
                probes += 1
                val online = NetworkProbe.isReachable()
                if (probes % 5 == 1) {
                    PlayLog.log("waitNetwork probe#$probes waited=${waited}ms online=$online ${NetworkProbe.state()}")
                }
                if (online) {
                    PlayLog.log("network back after ${waited}ms key=$key")
                    if (AppState.resolvingSongKey.value == key) AppState.resolvingSongKey.value = null
                    resolveAndPlayIfNeeded(song, allowCrossRetry = true)
                    return@launch
                }
                // v2.1.70：不再要求"屏幕亮"才续播——上一版这条硬条件会让息屏后永远等不到续播，
                // 正是"一息屏就彻底不切"的死锁点。联网恢复即可起播，起播后被掐再走换源兜底。
            }
            PlayLog.log("waitNetwork timeout key=$key waited=$waited")
        }
    }

    /**
     * v2.1.68：亮屏/解锁时兜底重试。
     * 息屏时取流失败的歌，用户一回到界面就立刻重新取流并续播，不必再手动点歌；
     * 同时新起播成功会作废排着的自动跳歌任务，避免"刚出声又被切走"。
     */
    fun onScreenOn() {
        PlayLog.log(
            "SCREEN_ON url=${PlayerManager.currentUrl.value != null} playing=${PlayerManager.isPlaying.value} " +
                "pos=${PlayerManager.position.value} dur=${PlayerManager.duration.value} ${NetworkProbe.state()}"
        )
        val dur = PlayerManager.duration.value
        val pos = PlayerManager.position.value
        // v2.1.69：息屏后 CPU 进了 Doze，播完回调可能压根没被投递——状态停在"播放中、进度到底"，
        // 亮屏必须当成"这首已经放完"继续切下一首，否则会一直卡在这一首上
        if (PlayerManager.isPlaying.value) {
            if (dur > 0 && pos >= dur - 1000) {
                PlayLog.log("SCREEN_ON stuck-at-end pos=$pos dur=$dur")
                PlayerManager.stop()
                advanceAfterTrackEnd("screen_on")
            }
            return
        }
        if (resolvingSongKey.value != null) return
        val s = lastSong.value ?: return
        val key = s.platform.name + s.platformID
        val needRetry = PlayerManager.currentUrl.value == null || resolveError.value?.first == key
        if (!needRetry) return
        PlayLog.log("SCREEN_ON retry key=$key")
        resolveAndPlayIfNeeded(s, allowCrossRetry = true)
    }

    /**
     * v2.1.69：曲终闹铃到点（Doze 下播完回调可能根本送不到，靠闹铃把 CPU 唤醒）。
     * 只在"确实已经到底/已停"时才推进，避免闹铃提前或迟到误切歌。
     */
    fun onTrackEndAlarm() {
        val dur = PlayerManager.duration.value
        val pos = PlayerManager.position.value
        val playing = PlayerManager.isPlaying.value
        PlayLog.log("ALARM check dur=$dur pos=$pos playing=$playing ${NetworkProbe.state()}")
        if (dur <= 0L || pos <= 0L) return
        if (pos < dur - 4000L) return          // 闹铃提前了，这首还在放，不动
        if (PlayerManager.currentUrl.value == null && !playing) return
        if (playing) PlayerManager.stop()
        advanceAfterTrackEnd("alarm")
    }

    /**
     * v2.1.7：播放层音源时长不匹配（PlayerManager.sourceMismatch）——按"无可用源"同口径处理：
     * 该歌标记为无源（搜索列表自动隐藏）、提示原因、允许重试并自动切歌（最多连跳 3 首）。绝不兜底播放劣质音源。
     */
    fun onSourceMismatch(message: String) {
        val s = lastSong.value ?: return
        val key = s.platform.name + s.platformID
        deadSongKeys.value = deadSongKeys.value + "${s.platform.name}_${s.platformID}"
        currentSource.value = null
        currentSourceSongKey.value = null
        resolveError.value = key to message
        resolvingSongKey.value = null
        // v2.1.26：时长不符的劣质源同样换源重试（含跨平台兜底），不再直接跳过——PlayerManager 已清 currentUrl，
        // 防重入检查通过后重新取流直到拿到可用源
        resolveAndPlayIfNeeded(s, allowCrossRetry = true)
    }

    /** v2.1.26：播放层加载失败（源加载不出/中途失效）→ 对该歌换源重试（含跨平台兜底），后台播放页未打开同样生效 */
    fun onTrackPlaybackFailed() {
        val s = lastSong.value ?: return
        resolveAndPlayIfNeeded(s, allowCrossRetry = true)
    }

    /**
     * v2.1.67：自动连播与换源监听从 Compose 组合搬到应用级。
     *
     * 复现路径（用户反馈 100%）：点最近播放的一首歌 → 退到后台（进程与前台服务都还在）→ 不锁屏时能正常连播；
     * 一锁屏就停在当前歌不再切歌，亮屏后立刻恢复。
     *
     * 根因：这三个 collect 原先写在 App() 的 LaunchedEffect 里，跑在 Compose 组合的协程上下文
     * （AndroidUiDispatcher + 帧时钟）上。息屏后窗口不可见，系统不再产生帧，MediaPlayer 的
     * onCompletion 虽然已经把 completed 置位，协程却排在帧后面迟迟得不到调度——所以只是"不切歌"，
     * 音频链路本身是好的。不锁屏时帧一直在走，所以看不出问题。
     *
     * 现在改挂 object 自身的应用级协程（Dispatchers.Main 普通主线程 Handler，与帧无关），
     * 只要进程活着就照常推进；再配合 PlayerService 的 PARTIAL_WAKE_LOCK 防 CPU 休眠，
     * 息屏期间也能完成"下一首的取流 → 播放"。
     */
    private var autoContinueStarted = false

    fun startAutoContinue() {
        if (autoContinueStarted) return
        autoContinueStarted = true

        // 播完自动连播：单曲循环重播当前；列表/随机切歌统一走全局取流任务
        globalScope.launch {
            var lastSeq = 0L
            PlayerManager.completed.collect { seq ->
                if (seq == lastSeq) return@collect
                lastSeq = seq
                advanceAfterTrackEnd("completed")
            }
        }

        // v2.1.69：播完兜底看门狗。息屏后 CPU 进 Doze，MediaPlayer 的完成回调可能根本没被投递
        // （音频在硬件层放完了，回调要 CPU 醒着才送达），状态就停在"播放中、进度到底"，
        // 于是永远不切歌。这里每 3 秒核对一次：播放中 + 进度到底 + 两个周期没动 → 按播完处理。
        globalScope.launch {
            var lastPos = -1L
            while (true) {
                delay(3000)
                runCatching {
                    val dur = PlayerManager.duration.value
                    val pos = PlayerManager.position.value
                    val s = lastSong.value
                    if (!PlayerManager.isPlaying.value || PlayerManager.currentUrl.value == null ||
                        dur <= 0L || s == null
                    ) {
                        lastPos = pos
                        return@runCatching
                    }
                    val stuck = pos == lastPos && pos >= dur - 1000L
                    lastPos = pos
                    if (stuck) {
                        PlayLog.log(
                            "GAP key=${s.platform.name}${s.platformID} pos=$pos dur=$dur ${NetworkProbe.state()}"
                        )
                        PlayerManager.stop()
                        advanceAfterTrackEnd("gap-watchdog")
                        lastPos = -1L
                    }
                }
            }
        }

        // 播放层时长校验失败（劣质音源/伪装伴奏）→ 标记无源、提示、换源重试（绝对准确，不兜底）
        globalScope.launch {
            var lastMsg: String? = null
            PlayerManager.sourceMismatch.collect { msg ->
                if (msg == null) {
                    lastMsg = null          // 每次 play() 都会先清空，允许同一句提示在下一首再次触发
                } else if (msg != lastMsg) {
                    lastMsg = msg
                    onSourceMismatch(msg)
                }
            }
        }

        // 播放层加载失败（源失效/加载不出）→ 换源重试，不再静默卡住（后台播放页未打开同样生效）
        globalScope.launch {
            var lastFail = 0L
            PlayerManager.playbackFailed.collect { seq ->
                if (seq == lastFail) return@collect
                lastFail = seq
                onTrackPlaybackFailed()
            }
        }
    }

    fun cyclePlayMode() {
        val next = when (playMode.value) {
            PlayMode.SINGLE_LOOP -> PlayMode.LIST_LOOP
            PlayMode.LIST_LOOP -> PlayMode.SHUFFLE
            PlayMode.SHUFFLE -> PlayMode.SINGLE_LOOP
        }
        playMode.value = next
        HistoryStore.savePlayMode(next.name)
    }

    /**
     * v2.1.69：一首歌"结束"的统一处理（回调送达 / 看门狗判定 / 亮屏发现卡在末尾 三个入口共用）。
     * 单曲循环重播当前；其余模式按队列顺序推进，走统一取流任务。
     * 后台自动连播与猜你喜欢点击行为完全一致——首轮即启用跨平台兜底，源失败持续换源。
     */
    private fun advanceAfterTrackEnd(tag: String) {
        // v2.1.85：这首放完就释放播放缓存（"播完即忘、不占空间"）
        PlayCache.clear()
        val s = lastSong.value
        val key = s?.let { it.platform.name + it.platformID } ?: "-"
        PlayLog.log("trackEnd tag=$tag key=$key ${NetworkProbe.state()}")
        if (onTrackCompleted()) {
            // 单曲循环：优先复用仍在的在线 URL，其次本地预取文件，最后重新取流
            val cur = lastSong.value
            val cached = cur?.let { NextTrackCache.match(it.platform.name + it.platformID) }
            val url = PlayerManager.currentUrl.value
                // v2.1.85：缓存文件刚被清掉，本地路径不能再复用（否则单曲循环会静默失败）
                ?.takeIf { !it.startsWith("/") || java.io.File(it).exists() }
            when {
                url != null -> PlayerManager.play(url)
                cached != null && cur != null -> playFromCache(cur, cached, "single")
                else -> cur?.let { resolveAndPlayIfNeeded(it, allowCrossRetry = true) }
            }
        } else {
            // 队列已推进到下一首：命中本地预取就直接起播（后台/息屏下无需联网，这是"播完立刻切"的关键）
            val next = lastSong.value
            val cached = next?.let { NextTrackCache.match(it.platform.name + it.platformID) }
            if (next != null && cached != null) {
                playFromCache(next, cached, "next")
            } else {
                next?.let { resolveAndPlayIfNeeded(it, allowCrossRetry = true) }
            }
        }
    }

    /** 一首歌自然播完后的自动处理。返回 true 表示需要重播当前曲目（单曲循环） */
    fun onTrackCompleted(): Boolean {
        val q = playlist.value
        if (q.isEmpty()) return false
        when (playMode.value) {
            PlayMode.SINGLE_LOOP -> return true
            PlayMode.LIST_LOOP -> goto((playIndex.value + 1) % q.size)
            PlayMode.SHUFFLE -> {
                if (q.size <= 1) {
                    goto(0)
                } else {
                    var r = playIndex.value
                    while (r == playIndex.value) r = (0 until q.size).random()
                    goto(r)
                }
            }
        }
        return false
    }

    /** 切到指定索引：更新队列位置与 lastSong；播放页开着时同步刷新 currentSong（PlayerScreen 自动取流） */
    private fun goto(idx: Int) {
        val q = playlist.value
        if (q.isEmpty() || idx !in q.indices) return
        playIndex.value = idx
        val s = q[idx]
        lastSong.value = s
        if (currentSong.value != null) currentSong.value = s
    }
}

enum class MainTab(val label: String, val icon: ImageVector) {
    HOME("首页", Icons.Filled.Home),
    // v2.1.83：识曲从首页入口条改成独立一页，位置在首页右边（最常点的一格）
    RECOGNIZE("识曲", Icons.Filled.Mic),
    FAVORITES("收藏", Icons.Filled.Favorite),
    DOWNLOADS("下载", Icons.Filled.Download),
    HISTORY("历史", Icons.Filled.History),
    SETTINGS("设置", Icons.Filled.Settings)
}

@Composable
fun App() {
    AppTheme {
        AppBackground {
            Box(modifier = Modifier.fillMaxSize()) {
                // MainScaffold 常驻：各 Tab（含搜索态/结果列表）状态不因播放页打开而丢失
                MainScaffold()
                // 歌单页：自底部滑入、返回向下滑出（纯滑动，慢速丝滑）
                // v2.1.5 #6：内容按"最后非空值"缓存——visible=false 时若直接读 value 会瞬间变空内容，
                // exit 动画在空容器上空跑，观感"没有退出动画"；缓存后退出动画期间页面仍完整可见（播放页同款修复）
                var retainedPlaylist by remember { mutableStateOf<EditorPlaylist?>(null) }
                val curPlaylist = AppState.openPlaylist.value
                if (curPlaylist != null) retainedPlaylist = curPlaylist
                AnimatedVisibility(
                    visible = curPlaylist != null,
                    // v2.1.4：纯滑动（自底部滑入/向下滑出），去掉淡入淡出——用户要求"滑动而不是渐变"
                    enter = slideInVertically(tween(440, easing = FastOutSlowInEasing)) { it },
                    exit = slideOutVertically(tween(300, easing = FastOutSlowInEasing)) { it },
                    modifier = Modifier.fillMaxSize()
                ) {
                    retainedPlaylist?.let { pl ->
                        PlaylistScreen(pl = pl, onBack = { AppState.openPlaylist.value = null })
                    }
                }
                // 悬浮播放条：绘制在歌单页覆盖层之上（编辑精选点歌后常驻可见）、播放页之下（播放页全屏让位）
                // v2.1.39：首次播放不再凭空弹出——自底栏上方 240ms 升起 + 淡入（底栏随之上移的观感被抹平）；
                // 退出 180ms、只下移自身 1/4 并淡出，比整条滑出更轻
                AnimatedVisibility(
                    visible = AppState.lastSong.value != null,
                    enter = slideInVertically(tween(240, easing = StrongEaseOut)) { it } +
                        fadeIn(tween(200, easing = FastOutSlowInEasing)),
                    exit = slideOutVertically(tween(180, easing = FastOutSlowInEasing)) { -it / 4 } +
                        fadeOut(tween(140, easing = FastOutSlowInEasing)),
                    modifier = Modifier.align(Alignment.BottomCenter)
                ) {
                    MiniPlayer()
                }
                // v2.1.5 #6：同歌单页——缓存最后歌曲，退出动画期间内容保留（否则 exit 空跑、看起来无退出动画）
                var retainedSong by remember { mutableStateOf<Song?>(null) }
                val curSong = AppState.currentSong.value
                if (curSong != null) retainedSong = curSong
                // 播放页：全屏自底部滑入（点悬浮条展开）、关闭向下滑出（纯滑动，慢速丝滑）
                AnimatedVisibility(
                    visible = curSong != null,
                    // v2.1.4：纯滑动（全屏自底部滑入/向下滑出），去掉淡入淡出
                    enter = slideInVertically(tween(460, easing = FastOutSlowInEasing)) { it },
                    exit = slideOutVertically(tween(320, easing = FastOutSlowInEasing)) { it },
                    modifier = Modifier.fillMaxSize()
                ) {
                    retainedSong?.let { song ->
                        PlayerScreen(song = song, onBack = { AppState.currentSong.value = null })
                    }
                }
                ToastHost()

                // v2.1.83：识曲已从浮层改成底层栏第 2 格（RecognizePage），不再有覆盖层


                // v2.1.50：山水水墨开场（InkSplash.kt）——替代冷启动后约 1.67s 的纯白空屏。
                // 声明在最后 → 覆盖在全部层级之上；首页首帧就绪即开始收束（最短 1.2s、最长 2.2s 兜底），
                // 动画结束回调置 false，整层连同位图一并从组合中移除（不占内存、不挡点击）。
                var showSplash by remember { mutableStateOf(true) }
                if (showSplash) {
                    InkSplash(onFinished = { showSplash = false })
                }

                // v2.1.67：播完自动连播 / 时长校验 / 加载失败三个监听已从本组合搬到
                // AppState.startAutoContinue()（应用级协程，不跟帧时钟走）。
                // 原因见该函数注释：挂在 LaunchedEffect 上时息屏不再产生帧，回调排不上队，自动连播停摆。

                // 返回键层级：播放页→歌单页→主界面；搜索结果态→清空回首页初始；非首页 Tab→回首页；否则系统默认退出
                val canBack = AppState.currentSong.value != null || AppState.openPlaylist.value != null || AppState.searchActive.value || AppState.tab.value != MainTab.HOME
                androidx.activity.compose.BackHandler(enabled = canBack) {
                    when {
                        AppState.currentSong.value != null -> AppState.currentSong.value = null
                        AppState.openPlaylist.value != null -> AppState.openPlaylist.value = null
                        AppState.searchActive.value -> AppState.searchActive.value = false
                        AppState.tab.value != MainTab.HOME -> {
                            // 离开识曲页时把还在跑的采集收掉
                            if (AppState.tab.value == MainTab.RECOGNIZE) AppState.cancelRecognize()
                            AppState.tab.value = MainTab.HOME
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MainScaffold() {
    // safeDrawingPadding：顶出状态栏/底出系统手势条，避免底部导航被系统导航条区域吞掉点击
    Column(modifier = Modifier.fillMaxSize().safeDrawingPadding()) {
        Box(modifier = Modifier.weight(1f)) {
            // Tab 切换：水平滑动主导（新页从右滑入、旧页向左退出，慢速丝滑）——v2.1.4 由"淡入上移"改为"纯滑动"
            AnimatedContent(
                targetState = AppState.tab.value,
                transitionSpec = {
                    // v2.1.7：页面与动画完全同向（用户拍板"无论是页面还是动画都从右向左"）——
                    // 前进（Tab 序增大，如首页→下载）：新页从右滑入、旧页同向轻推退出；
                    // 后退（Tab 序减小，如下载→首页）整体镜像（左→右）。
                    // 250ms strong ease-out（cubic-bezier(.23,1,.32,1)），与山水 wipe 进入同步，纯滑动无淡入淡出。
                    val forward = targetState.ordinal > initialState.ordinal
                    if (forward)
                        (slideInHorizontally(tween(250, easing = StrongEaseOut)) { it })
                            .togetherWith(slideOutHorizontally(tween(250, easing = StrongEaseOut)) { -it / 4 })
                    else
                        (slideInHorizontally(tween(250, easing = StrongEaseOut)) { -it })
                            .togetherWith(slideOutHorizontally(tween(250, easing = StrongEaseOut)) { it / 4 })
                },
                label = "tabSwitch"
            ) { tab ->
                // v2.1.60（录屏 11.1–11.3s 取证）：切 Tab 时新旧两页同屏，而页面本身是透明底
                // （纸色来自全局 AppBackground），于是两页文字互相穿透——首页「发现音乐」和收藏页
                // 「我喜欢的音乐」叠在一起，看起来像排版错乱。原来这条 250ms 滑动被整幅山水 wipe 遮着，
                // v2.1.59 把 wipe 停用后问题露出来。现在每页各铺一层不透明纸底，新页滑入即盖住旧页。
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(PaperBrush)
                ) {
                    when (tab) {
                        MainTab.HOME -> HomeScreen()
                        MainTab.RECOGNIZE -> RecognizePage()
                        MainTab.FAVORITES -> FavoritesScreen()
                        MainTab.DOWNLOADS -> DownloadsScreen()
                        MainTab.HISTORY -> HistoryScreen()
                        MainTab.SETTINGS -> SettingsScreen()
                    }
                }
            }
            // v2.1.7：水墨"山水卷轴"全屏切换——整幅山水贴图从右到左覆盖全屏（前进）、停留一瞬、
            // 再同方向从右到左逐渐消失露出新页（后退镜像）；与主页内容自身滑动切换并存且方向一致。
            // 声明在 AnimatedContent 之后 → 绘制于内容层之上；不拦截任何输入，动画结束即卸载。
            // v2.1.59：Tab 切换的"整幅山水贴图 wipe"停用——它和"首页 0 处具象山水"直接冲突，
            // 每次切 Tab 都有一整幅山水砸到脸上。页面自身的同向滑动（250ms）保留，转场仍然连贯。
            // LandscapeWipeOverlay()
        }
        BottomNav(tab = AppState.tab.value, onSelect = { AppState.tab.value = it })
    }
}

// ===== 底部导航（水墨：纸色渐变底 + 顶部发丝墨线 + 选中墨印滑动定位 + 朱砂落款点/捺线）=====
// v2.1.5 #1b：选中"墨印印章"从旧 Tab 位置平滑滑动到新 Tab（420ms 丝滑），与主页内容切换动画
// （全屏滑动 + 笔触扫帘）刻意不同；#7 点击按压反馈改水墨墨晕收缩（inkClickable）
@Composable
private fun BottomNav(tab: MainTab, onSelect: (MainTab) -> Unit) {
    val p = LocalPalette.current
    BoxWithConstraints(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                // 纸面渐变：从米白到底部略深的淡墨纸，与搜索栏/播放条同语言
                Brush.verticalGradient(listOf(p.surface, p.surface2))
            )
            .drawBehind {
                // 顶部 1px 淡墨发丝线
                drawLine(
                    color = Color(0x332E2A24),
                    start = Offset(0f, 0f),
                    end = Offset(size.width, 0f),
                    strokeWidth = 1f
                )
            }
    ) {
        val colW = maxWidth / MainTab.entries.size
        val idx = MainTab.entries.indexOf(tab)
        // 墨印印章水平位置：目标 Tab 列居中（40dp 印章）
        val inkX by animateDpAsState(
            targetValue = (colW * idx) + (colW - 40.dp) / 2f,
            animationSpec = tween(420, easing = FastOutSlowInEasing),
            label = "inkSlide"
        )
        // 墨印层（先声明 → 绘制在内容之下，作图标衬底；随 tab 平滑滑动）
        Box(
            modifier = Modifier
                .offset(x = inkX)
                .padding(top = 5.dp)
                .size(40.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(p.accent.copy(alpha = 0.92f))
        )
        Box(
            modifier = Modifier
                .offset(x = inkX)
                .padding(top = 5.dp)
                .size(40.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(
                    Brush.verticalGradient(
                        listOf(Color(0x1AFFFFFF), Color.Transparent)
                    )
                )
        )
        Row(modifier = Modifier.fillMaxWidth()) {
            MainTab.entries.forEach { t ->
                val selected = tab == t
                // v2.1.39：图标配色跟随墨印一起走同一条 420ms 曲线——原先瞬间换色，
                // 墨印还在滑动途中图标就已经变白，颜色与位置节奏断裂
                val color by animateColorAsState(
                    targetValue = if (selected) Color(0xFFF7F5F0) else p.text3,
                    animationSpec = tween(420, easing = FastOutSlowInEasing),
                    label = "tabTint"
                )
                // v2.1.39：朱砂落款点随选中淡入 + 自 0.6 轻放大，取消时淡出（不再瞬间弹出/消失）
                val dotProg by animateFloatAsState(
                    targetValue = if (selected) 1f else 0f,
                    animationSpec = tween(180, easing = StrongEaseOut),
                    label = "tabDot"
                )
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier
                        .weight(1f)
                        // #7：水墨按压反馈（收缩 + 墨晕圈），替代原先 indication=null 的无反馈点击
                        .inkClickable { onSelect(t) }
                        .padding(top = 4.dp, bottom = 6.dp)
                ) {
                    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(44.dp)) {
                        Icon(
                            t.icon,
                            contentDescription = t.label,
                            tint = color,
                            modifier = Modifier.size(20.dp)
                        )
                        // 选中：右上角 4dp 朱砂落款点（印章感，呼应播放钮"一点红"）
                        // v2.1.39：不再 if 硬弹出——始终绘制，由 dotProg 控 alpha 与 scale，取消时淡出
                        Box(
                            modifier = Modifier
                                .align(Alignment.TopEnd)
                                .padding(top = 3.dp, end = 4.dp)
                                .size(4.dp)
                                .graphicsLayer {
                                    alpha = dotProg
                                    val s = 0.6f + 0.4f * dotProg
                                    scaleX = s
                                    scaleY = s
                                }
                                .clip(CircleShape)
                                .background(p.heartOn)
                        )
                    }
                    Spacer(Modifier.height(2.dp))
                    // v2.1.9：显式 lineHeight=12sp——此前未设 style 导致继承 M3 默认 bodyLarge 24sp 行高，
                    // 10sp 字配 24sp 行高使底栏实际 ≈86dp（偏高），现修正为 70dp（4+44+2+12+2+6）
                    // v2.1.59：标签 10sp→11sp（lineHeight 13sp，底栏总高仍 ≈70dp），小字不再像注释
                    // v2.1.84：标签在墨印下方、压在纸面上——之前直接沿用 selected 的纸白色，
                    // 选中项标签等于白字写白纸，「识曲」两个字几乎看不见。改成选中=墨色。
                    Text(
                        t.label,
                        fontSize = 11.sp,
                        lineHeight = 13.sp,
                        color = if (selected) p.text else p.text3
                    )
                    Spacer(Modifier.height(2.dp))
                }
            }
        }
    }
}

// ===== 底部播放条（MiniPlayer）：v2.1.28 画卷 v29 只画纯山水幕布（无黑胶盘、无预绘钮框、无阴影），四钮全部由功能层绘制 =====
// 画卷素材（mini_roll.jpg，4579×915，v2.1.28 定稿=以 v2.1.25 为底清盘清钮框重绘）：实测坐标（归一化 0-1）：
//   盘区（原 0.117w~0.203w）与盘影（0.20w~0.30w）已擦为纸色山水，无任何黑胶痕迹；歌名起点 0.26w
//   文字区（0.26w-0.49w）与按钮区（0.50w-0.95w）均为干净山水幕布，无预绘钮框/纹理阴影
// 四钮重新排版：圆心 = 0.56 / 0.672 / 0.784 / 0.896w（cy=0.504h）——等距 0.112w（40.3dp，互不重叠），
//   整体右对齐轴杆内侧（右钮右缘 0.949w，轴杆 0.957w 留呼吸间隙）；
//   v2.1.29 按反馈：收藏去掉心形大边框、左/右切歌去掉墨线圆环，只留 24dp 图标（40dp 点击区），
//   仅暂停保留 44dp 朱砂圆（略大）
// 功能层全部用 offset(x,y) 绝对定位：不得与 .align(Center) 混用——
// align 会先把元素居中再按 offset 平移，导致整体右移 0.5w（v2.1.22 嵌套错位根因）。

@Composable
private fun MiniPlayer(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val song = AppState.lastSong.value ?: return
    val playingUrl by PlayerManager.currentUrl.collectAsState()
    val isPlaying by PlayerManager.isPlaying.collectAsState()
    val playing = playingUrl != null && isPlaying
    val fav = HistoryStore.isFavorite(song)
    val ctx = LocalContext.current
    val roll = remember { BitmapFactory.decodeResource(ctx.resources, R.drawable.mini_roll)?.asImageBitmap() }
    val bottomPad = if (AppState.openPlaylist.value != null) 10.dp else BOTTOM_BAR_HEIGHT

    BoxWithConstraints(
        modifier = modifier
            .navigationBarsPadding()
            .padding(bottom = bottomPad)
            .fillMaxWidth()
            .aspectRatio(5f)
            .clip(RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp))
            .drawBehind {
                // 幕布：画卷素材全幅铺底（轴杆/卷面山水/唱片圈/按钮圈/朱砂印全由图承载）
                // v2.1.45 B1：等比放大约 10% 并居中裁边——素材顶部纸色留白（约 6%）移出可视区，
                // 山水同时放大更清晰；功能层（封面/文字/按钮）绝对定位不动，视觉位置不变
                if (roll != null) {
                    val scale = 1.10f
                    val dw = size.width * scale
                    val dh = size.height * scale
                    drawImage(
                        image = roll,
                        srcOffset = IntOffset.Zero,
                        srcSize = IntSize(roll.width, roll.height),
                        dstOffset = IntOffset(((size.width - dw) / 2f).roundToInt(), ((size.height - dh) / 2f).roundToInt()),
                        dstSize = IntSize(dw.roundToInt(), dh.roundToInt())
                    )
                }
            }
    ) {
        val w = maxWidth
        val h = maxHeight
        // ⓪ v2.1.32：整条点击层（最底层，必须第一个声明）——「点悬浮栏任意位置都打开播放页」+ 彻底拦住穿透
        //    背景：v2.1.31 撤掉浮层后只有封面、歌名区、四个钮可点，悬浮栏其余区域
        //    （上下山水留白、封面左侧、钮与钮之外的空隙、最右轴杆）都没有点击处理，
        //    手指落在空白处会击穿到下层歌曲列表，直接切播列表里那一首 —— 正是用户反馈的现象。
        //    这里在最底层铺一层全条 clickable：
        //      · 点空白 → AppState.openSong(song) 打开当前歌播放页（已在播则不会重新取流、不打断播放）
        //      · 四钮/封面/歌名区在上层先命中，行为不变，互不干扰
        //      · indication = null：不整幅压暗，画卷视觉保持干净
        Box(
            modifier = Modifier
                .matchParentSize()
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null
                ) { AppState.openSong(song) }
        )
        // ① 封面：42dp 圆角封面浮于画卷左侧纸色山水区（原黑胶盘位 0.16w，点按回播放页）
        Box(
            modifier = Modifier
                .offset(x = w * 0.16f - 21.dp, y = h * 0.504f - 21.dp)
                .size(42.dp)
                .inkClickable { AppState.openSong(song) },
            contentAlignment = Alignment.Center
        ) {
            // v2.1.38：切歌时封面交叉淡变（200ms），不再硬替换成另一张图
            Crossfade(
                targetState = song,
                animationSpec = tween(200, easing = StrongEaseOut),
                label = "miniCover"
            ) { s ->
                SongCover(song = s, size = 42.dp, corner = 21.dp)
            }
        }
        // ② 歌名 + 歌手：卷面留白区（封面右缘≈0.246w 与钮1框左缘≈0.507w 之间），起点 0.26w 宽 0.23w
        // v2.1.38：歌名/歌手随切歌交叉淡变（200ms），与封面同步；不再"字突然换掉"
        Crossfade(
            targetState = song,
            animationSpec = tween(200, easing = StrongEaseOut),
            modifier = Modifier
                .offset(x = w * 0.26f, y = h * 0.504f - 22.dp)
                .width(w * 0.23f)
                .inkClickable { AppState.openSong(song) },
            label = "miniMeta"
        ) { s ->
            Column(verticalArrangement = Arrangement.Center) {
                Text(
                    s.name,
                    color = p.text,
                    fontSize = 14.sp,
                    fontFamily = InkTitleFont,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    // v2.1.30：切歌/取流期间显示「正在取流…」，把「已生效但还在解析」与「点了没反应」区分开
                    if (AppState.resolvingSongKey.value == s.platform.name + s.platformID) "正在取流…"
                    else s.singer + " · " + s.platform.shortName,
                    color = p.text2,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
        // ③④⑤⑥ v2.1.31：四个钮的热区改为「按分区连续铺满」的矩形（高 = 按钮行 0.18~0.82h，约 50dp），
        //    每个热区宽 44~45dp、彼此不重叠也不留缝（覆盖 0.50w~0.952w），任意落点都归属唯一一个钮，
        //    且都挂 inkClickable —— 反馈与点击歌曲完全同一套（按下缩放 0.93 + 墨色压暗 26%）。
        //    热区中心 = 原钮圆心（0.558/0.672/0.784/0.896w），图标居中渲染，视觉位置不变。
        val zoneH = h * 0.64f
        val zoneY = h * 0.18f

        // ③ 收藏（钮1，圆心 0.56w）：无外框，仅爱心图标（v2.1.29 按反馈去掉心形大边框）
        Box(
            modifier = Modifier
                .offset(x = w * 0.50f, y = zoneY)
                .width(w * 0.116f)
                .height(zoneH)
                .inkClickable { HistoryStore.toggleFavorite(song) },
            contentAlignment = Alignment.Center
        ) {
            // v2.1.38：悬浮栏爱心同样走 InkHeart（这是全 App 最常看到的一颗心）
            InkHeart(
                fav = fav,
                size = 24.dp,
                tintOn = p.heartOn,
                tintOff = p.text2
            )
        }
        // ④ 上一曲（钮2，圆心 0.672w）：无圆环，仅图标（v2.1.29 按反馈去掉圆环）
        Box(
            modifier = Modifier
                .offset(x = w * 0.616f, y = zoneY)
                .width(w * 0.112f)
                .height(zoneH)
                .inkClickable { AppState.prevSong() },
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Filled.SkipPrevious, contentDescription = "上一曲", tint = p.text2, modifier = Modifier.size(24.dp))
        }
        // ⑤ 播放 / 暂停（钮3，圆心 0.784w）：朱砂实心圆视觉仍 44dp（v2.1.29 确认尺寸），
        //    v2.1.31 热区取整段 0.728~0.840w，视觉不变、任意落点都能命中
        Box(
            modifier = Modifier
                .offset(x = w * 0.728f, y = zoneY)
                .width(w * 0.112f)
                .height(zoneH)
                .inkClickable {
                    if (PlayerManager.currentUrl.value != null) PlayerManager.toggle()
                    else AppState.openSong(song)
                },
            contentAlignment = Alignment.Center
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(p.accent),
                contentAlignment = Alignment.Center
            ) {
                // v2.1.40：与播放页那颗键同一套动作——交叉淡入 + 自 0.82 轻起（不从"无"里长出来），
                // 不再是 if 硬换图标。悬浮栏这颗是全 App 最常按到的播放键，手感必须和播放页一致
                AnimatedContent(
                    targetState = playing,
                    transitionSpec = {
                        (fadeIn(tween(180, easing = FastOutSlowInEasing)) +
                            scaleIn(tween(180, easing = FastOutSlowInEasing), initialScale = 0.82f))
                            .togetherWith(fadeOut(tween(140, easing = FastOutSlowInEasing)))
                    },
                    label = "miniPlayPause"
                ) { isPlaying ->
                    Icon(
                        if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                        contentDescription = if (isPlaying) "暂停" else "播放",
                        tint = Color(0xFFF7F5F0),
                        modifier = Modifier.size(26.dp)
                    )
                }
            }
        }
        // ⑥ 下一曲（钮4，圆心 0.896w）：无圆环，仅图标（v2.1.29 按反馈去掉圆环）
        Box(
            modifier = Modifier
                .offset(x = w * 0.840f, y = zoneY)
                .width(w * 0.112f)
                .height(zoneH)
                .inkClickable { AppState.nextSong() },
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Filled.SkipNext, contentDescription = "下一曲", tint = p.text2, modifier = Modifier.size(24.dp))
        }
        // ⑦ v2.1.31：撤销 v2.1.30 的「整条手势通道」——它作为最上层 child 独占了指针事件，
        //    四个钮的 clickable 收不到 down，表现为「点了完全没反馈」（封面与歌名区也一并失效）。
        //    现在不加任何浮层，热区由四个钮自身按分区铺满承担。
    }
}

// v2.1.31 说明：v2.1.30 引入的「悬浮栏横向分区手势层」已整体移除。
// 它作为最上层 child 独占了指针事件（Compose hit test 只投递给最上层命中元素），
// 导致四个钮的 clickable 收不到 down、按压反馈全部消失；热区改由四个钮自身按分区铺满承担。

// ===== 封面显示（v2.1.59：原色直出）=====
// v2.1.42–v2.1.58 的四层处理（饱和 72% + 暖偏 R+7/G+5/B-9 + 16% 纸色混合 + 径向淡到纸色）整体撤掉：
// 实测三张封面平均饱和只有 0.16/0.22/0.28、一张亮度动态范围只剩 110，"像褪色的旧照片"——这是首页"老气"的头号来源。
// 现在只保留 Coil 原图 + 220ms 淡入；不做任何色彩矩阵、不叠任何纸色蒙版。封面自己就是视觉中心。

// ===== 封面：Coil 加载真实封面；无封面先落「平台渐变+歌名首字+音符」本地占位（离线可用），
//      同时异步走 QQ 同歌名+歌手复用兜底（命中后直接换真图，不做闪烁动画）=====
@Composable
fun SongCover(song: Song, size: androidx.compose.ui.unit.Dp, corner: androidx.compose.ui.unit.Dp) {
    Box(modifier = Modifier.size(size).clip(RoundedCornerShape(corner))) {
        SongCoverContent(song = song)
    }
}

/** 宽度自适应的方形封面（热门音乐双列网格用）；调用方需保证外层宽度确定 */
@Composable
fun SongCoverBox(song: Song, corner: androidx.compose.ui.unit.Dp, modifier: Modifier = Modifier) {
    Box(modifier = modifier.clip(RoundedCornerShape(corner))) {
        SongCoverContent(song = song)
    }
}

@Composable
private fun SongCoverContent(song: Song) {
    val ctx = androidx.compose.ui.platform.LocalContext.current.applicationContext
    val scope = rememberCoroutineScope()
    CoverResolver.ensureInit(ctx)
    // 2.0.1：酷狗旧版 imgessl album_id 路径判死——CDN 已软失败为固定黑胶（HTTP 200），初始即弃用，直接走 QQ 兜底换真封面
    val legacyDeadPic = song.platform == com.jz.musichelper.model.MusicPlatform.KUGOU &&
        song.picUrl?.contains("imgessl", ignoreCase = true) == true
    var pic by remember(song.platform.name + song.platformID) { mutableStateOf(if (legacyDeadPic) null else song.picUrl) }
    // ④ 修复：原封面 URL 加载失败/挂起时，强制走 QQ 同歌名+歌手复用兜底（换真图，最多触发一次）
    var fallbackPic by remember(song.platform.name + song.platformID) { mutableStateOf<String?>(null) }
    var fallbackTried by remember(song.platform.name + song.platformID) { mutableStateOf(false) }
    var loadedOk by remember(song.platform.name + song.platformID) { mutableStateOf(false) }
    // 统一兜底入口：error 与挂起超时共用；兜底失败自动重试 1 次（网络抖动/偶发超时自愈）
    val triggerFallback = {
        if (!fallbackTried) {
            fallbackTried = true
            scope.launch {
                fallbackPic = CoverResolver.resolveForce(song)
                if (fallbackPic.isNullOrBlank()) {
                    kotlinx.coroutines.delay(800)
                    fallbackPic = CoverResolver.resolveForce(song)
                }
            }
        }
    }
    LaunchedEffect(song.platform.name + song.platformID, song.name, song.singer) {
        if (pic.isNullOrBlank()) {
            pic = CoverResolver.resolve(song)
            // ④ 修复：兜底失败自动重试 1 次（网络抖动/偶发超时自愈），仍失败才落本地占位
            if (pic.isNullOrBlank()) {
                kotlinx.coroutines.delay(800)
                pic = CoverResolver.resolve(song)
            }
        }
    }
    // ④ 修复：原 URL 加载挂起（Coil 既不成功也不报错）→ 4s 后强制触发 QQ 兜底换真图
    LaunchedEffect(song.platform.name + song.platformID, song.name, song.singer) {
        kotlinx.coroutines.delay(4000)
        if (!loadedOk && !fallbackTried) triggerFallback()
    }
    // ④ 修复：兜底真封面优先显示——原 URL 是失效/挂起 URL 时，兜底结果才能真正替换显示
    val url = fallbackPic ?: pic
    if (!url.isNullOrBlank()) {
        // 2.0.2：allowHardware(false) 强制软件位图——Coil 默认硬件位图上 Bitmap.getPixel() 抛异常，
        // 导致黑胶检测被 catch 吞掉返回 false、酷狗软失败黑胶（union_cover 也是黑胶图）直接显示；改为软件位图后检测恢复
        val request = coil.request.ImageRequest.Builder(ctx).data(url).allowHardware(false).build()
        coil.compose.SubcomposeAsyncImage(
            model = request,
            contentDescription = song.name,
            modifier = Modifier.fillMaxSize(),
            loading = { CoverPlaceholder(song) },
            error = {
                triggerFallback()
                CoverPlaceholder(song)
            },
            success = { state ->
                // 2.0.0：识别酷狗软失败的黑胶默认图 → 触发 QQ 兜底（期间显示本地占位）；真封面才标记成功
                val bmp = runCatching { state.result.drawable.toBitmap() }.getOrNull()
                if (bmp != null && VinylDetector.isVinyl(bmp)) {
                    triggerFallback()
                    CoverPlaceholder(song)
                } else {
                    loadedOk = true
                    // v2.1.39：真封面 220ms 淡入——原先"占位图 → 真封面"是硬切，每张封面首次出现都会啪一下。
                    // 占位图继续垫在最底层，淡入过程中底下始终有内容，不会闪出空块。
                    var coverIn by remember(url) { mutableStateOf(false) }
                    LaunchedEffect(url) { coverIn = true }
                    val coverAlpha by animateFloatAsState(
                        targetValue = if (coverIn) 1f else 0f,
                        animationSpec = tween(220, easing = StrongEaseOut),
                        label = "coverFade"
                    )
                    // v2.1.59：原色直出——占位图垫底，真封面按 220ms 淡入，不叠任何色彩矩阵与纸色蒙版
                    Box(modifier = Modifier.fillMaxSize()) {
                        CoverPlaceholder(song)
                        androidx.compose.foundation.Image(
                            state.painter,
                            contentDescription = song.name,
                            modifier = Modifier
                                .fillMaxSize()
                                .graphicsLayer { alpha = coverAlpha }
                        )
                    }
                }
            }
        )
    } else {
        CoverPlaceholder(song)
    }
}

/**
 * 黑胶默认图识别（2.0.0，2.0.1 增强为区域均值版）。酷狗 CDN 对无封面/失效路径不返回 404，而是 HTTP 200 + 固定黑胶图（软失败），
 * Coil 会当成功。这里按像素特征确定性识别：四角区域均值浅色 + 黑色圆盘 + 蓝色圆心，命中即判软失败、走 QQ 兜底。
 * 2.0.1 增强：背景改 5×5 区域均值（抗单点噪声/JPEG 噪点）、圆心改 3×3 邻域计数（抗圆心位置偏移），
 * 已用 12 张已知图回归验证（5 黑胶均命中、7 真封面均不误伤）。
 */
private object VinylDetector {
    private fun px(b: android.graphics.Bitmap, fx: Float, fy: Float): Int =
        b.getPixel((fx * (b.width - 1)).toInt().coerceIn(0, b.width - 1),
                   (fy * (b.height - 1)).toInt().coerceIn(0, b.height - 1))
    private fun lum(c: Int): Double =
        0.299 * android.graphics.Color.red(c) + 0.587 * android.graphics.Color.green(c) +
        0.114 * android.graphics.Color.blue(c)
    private fun isLight(c: Int): Boolean = lum(c) > 190
    private fun isDark(c: Int): Boolean = lum(c) < 70
    private fun isBlue(c: Int): Boolean {
        val r = android.graphics.Color.red(c); val g = android.graphics.Color.green(c)
        val bl = android.graphics.Color.blue(c)
        return bl > 110 && bl - r > 40 && bl - g > 15
    }
    fun isVinyl(b: android.graphics.Bitmap): Boolean = try {
        // 背景：四角 5×5 区域均值亮度，≥3 角浅(>185)
        fun regionLum(fx0: Float, fy0: Float, fx1: Float, fy1: Float): Double {
            var r = 0.0; var g = 0.0; var bl = 0.0
            for (i in 0..4) for (j in 0..4) {
                val c = px(b, fx0 + (fx1 - fx0) * i / 4f, fy0 + (fy1 - fy0) * j / 4f)
                r += android.graphics.Color.red(c); g += android.graphics.Color.green(c); bl += android.graphics.Color.blue(c)
            }
            return 0.299 * r / 25.0 + 0.587 * g / 25.0 + 0.114 * bl / 25.0
        }
        val corners = listOf(
            regionLum(.03f, .03f, .10f, .10f), regionLum(.90f, .03f, .97f, .10f),
            regionLum(.03f, .90f, .10f, .97f), regionLum(.90f, .90f, .97f, .97f)
        )
        if (corners.count { it > 185 } < 3) false
        else {
            val disk = listOf(px(b, .5f, .30f), px(b, .30f, .5f), px(b, .70f, .5f), px(b, .5f, .70f))
            if (disk.count { isDark(it) } < 3) false
            else {
                var blueN = 0
                for (i in 0..2) for (j in 0..2)
                    if (isBlue(px(b, .44f + .06f * i, .44f + .06f * j))) blueN++
                blueN >= 6
            }
        }
    } catch (_: Exception) { false }
}

/** 本地占位：宣纸底 + 墨色歌名首字 + 墨色音符小标（水墨观感，无网络也可用） */
@Composable
private fun CoverPlaceholder(song: Song) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(Color(0xFFF1EDE2), Color(0xFFE0DACB))))
    ) {
        val initial = song.name.trim().take(1).ifEmpty { "♪" }
        Text(
            text = initial,
            color = Color(0xFF2E2A24).copy(alpha = 0.85f),
            fontSize = 26.sp,
            fontFamily = InkTitleFont,
            modifier = Modifier.align(Alignment.Center)
        )
        Icon(
            Icons.Filled.MusicNote,
            contentDescription = null,
            tint = Color(0xFF2E2A24).copy(alpha = 0.26f),
            modifier = Modifier.align(Alignment.BottomEnd).padding(5.dp).size(16.dp)
        )
    }
}

/**
 * 水墨按压反馈（v2.1.17，A 方案「墨纸按压」——对标 iOS 系统级按压即时压暗，用户拍板）：
 * 期望录屏（iOS 深色音乐 App）效果 = 手指落下的瞬间整行立即压暗、对比强烈、松手恢复。
 * 实施：保留 v2.1.14 事件驱动（快击/长按每击必现）；按下【立即】整行墨色压暗 26%（snap 无延迟）
 * + 缩放 93%（v2.1.16→95%、v2.1.17→93%，用户逐档微调）；抬起 120ms 回弹、压暗层 220ms 淡出。
 * 删除墨晕扩散/行底浸染，反馈主体改为整行压暗。全站复用：歌曲行/小卡/榜行/迷你条/播放页。
 */
fun Modifier.inkClickable(enabled: Boolean = true, onClick: () -> Unit): Modifier = composed {
    val interactionSource = remember { MutableInteractionSource() }
    val pressScale = remember { Animatable(1f) }   // 缩放：按下立即 0.93，抬起 120ms 回弹
    val wash = remember { Animatable(0f) }         // 整行压暗：按下即时出现，抬起 220ms 淡出
    LaunchedEffect(interactionSource) {
        interactionSource.interactions.collect { i ->
            when (i) {
                is PressInteraction.Press -> {
                    pressScale.snapTo(0.93f)
                    wash.snapTo(1f)
                }
                is PressInteraction.Release, is PressInteraction.Cancel -> {
                    pressScale.animateTo(1f, tween(120, easing = FastOutSlowInEasing))
                    wash.animateTo(0f, tween(220, easing = FastOutSlowInEasing))
                }
            }
        }
    }
    graphicsLayer {
        scaleX = pressScale.value
        scaleY = pressScale.value
    }
        .drawBehind {
            if (wash.value > 0f) {
                // 整行墨色压暗 26%（按下即时、抬起淡出）——水墨版「纸被墨按沉」，对标 iOS 按压高亮
                drawRect(
                    color = Color(0xFF2E2A24).copy(alpha = 0.26f * wash.value)
                )
            }
        }
        .clickable(
            enabled = enabled,
            interactionSource = interactionSource,
            indication = null,
            onClick = onClick
        )
}

/**
 * v2.1.38：收藏爱心「墨点弹开」——空心↔实心不再硬替换（全站复用：列表行/播放页）。
 * 硬切的两个毛病：① 两个图标资源直接换形，像画面闪了一下；② 颜色从灰跳到朱砂，没有过渡。
 * 做法：空心层按进度淡出、实心层淡入（180ms strong ease-out）形成"形在溶"；
 * 收藏瞬间实心层 1 → 1.22（140ms）再 spring 落回 1（轻弹，bounce 0.42→受控不夸张）；
 * 取消时先压到 0.90 再回 1，像被按了一下缩回去，与 inkClickable 的按压语言一致。
 * 只动 alpha / scale（GPU），不触发布局。
 */
@Composable
fun InkHeart(
    fav: Boolean,
    size: Dp,
    tintOn: Color,
    tintOff: Color
) {
    val prog by animateFloatAsState(
        targetValue = if (fav) 1f else 0f,
        animationSpec = tween(180, easing = StrongEaseOut),
        label = "heartProg"
    )
    val pop = remember { Animatable(1f) }
    var prevFav by remember { mutableStateOf(fav) }
    LaunchedEffect(fav) {
        if (fav != prevFav) {
            prevFav = fav
            if (fav) {
                pop.snapTo(1f)
                pop.animateTo(1.22f, tween(140, easing = StrongEaseOut))
                pop.animateTo(1f, spring(dampingRatio = 0.42f, stiffness = Spring.StiffnessMediumLow))
            } else {
                pop.animateTo(0.90f, tween(90, easing = FastOutSlowInEasing))
                pop.animateTo(1f, tween(130, easing = StrongEaseOut))
            }
        }
    }
    Box(modifier = Modifier.size(size), contentAlignment = Alignment.Center) {
        Icon(
            Icons.Filled.FavoriteBorder,
            contentDescription = null,
            tint = tintOff,
            modifier = Modifier
                .size(size)
                .graphicsLayer { alpha = 1f - prog }
        )
        Icon(
            Icons.Filled.Favorite,
            contentDescription = if (fav) "取消收藏" else "收藏",
            tint = tintOn,
            modifier = Modifier
                .size(size)
                .graphicsLayer {
                    alpha = prog
                    scaleX = pop.value
                    scaleY = pop.value
                }
        )
    }
}

/**
 * v2.1.7：水墨“山水卷轴”全屏切换动画（已确认方案，替代 v2.1.5 笔触扫帘）。
 * Tab 切换时整幅水墨山水画（drawable-nodpi/landscape.jpg，远山层叠/云雾/扁舟/飞鸟）
 * 从右到左覆盖全屏（前进），停留一瞬再同方向从右到左逐渐消失，露出切屏后的页面；后退整体镜像。
 * 规格：Reveal → Hold → Reveal-out（进入/退出同一条 clip 窗口、同方向）· 250 + 60 + 230ms ·
 * strong ease-out cubic-bezier(.23,1,.32,1) · 页面滑动同步同向（见 AnimatedContent transitionSpec）。
 * 只裁剪绘制窗口，不拦截任何输入；动画结束即卸载（v2.1.6 教训：扫帘常驻吞点击致全功能失效）。
 * v2.1.11：修正退出阶段方向——此前进入/退出共用同一公式导致退出从左侧收窄（视觉左→右），
 * 现退出阶段与进入同向（前进全程右→左：进入左缘向左展开、退出右缘向左收窄；后退全程左→右镜像）。
 * v2.1.12：修正前进退出公式 right 误用 w*q（p=1 时窗口 0 宽→首帧闪现，且 0→w 反向扩大）——
 * 改 w*p（w→0 向左收窄、首帧全屏连续），前进全程右→左无闪现；后退镜像保持。
 */
internal val StrongEaseOut = CubicBezierEasing(0.23f, 1f, 0.32f, 1f)

@Composable
private fun LandscapeWipeOverlay() {
    val ctx = LocalContext.current
    val bitmap = remember {
        BitmapFactory.decodeResource(ctx.resources, R.drawable.landscape)?.asImageBitmap()
    }
    if (bitmap == null) return
    var seq by remember { mutableStateOf(0) }
    var prevTab by remember { mutableStateOf(AppState.tab.value) }
    var visible by remember { mutableStateOf(false) }
    var forward by remember { mutableStateOf(true) }
    var exiting by remember { mutableStateOf(false) }   // v2.1.11：区分进入/退出阶段，修正退出方向与进入同向
    val progress = remember { Animatable(0f) }
    LaunchedEffect(AppState.tab.value) {
        val cur = AppState.tab.value
        if (cur != prevTab) {
            forward = cur.ordinal > prevTab.ordinal
            prevTab = cur
            seq++
        }
    }
    // 系统“移除动画”（ANIMATOR_DURATION_SCALE=0）→ 直切，不播 wipe（对应演示页 reduced-motion）
    val reduceMotion = remember {
        try {
            Settings.Global.getFloat(ctx.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
        } catch (e: Exception) { false }
    }
    LaunchedEffect(seq) {
        if (seq == 0) return@LaunchedEffect
        visible = true
        if (reduceMotion) { visible = false; return@LaunchedEffect }
        exiting = false
        progress.snapTo(0f)
        progress.animateTo(1f, tween(250, easing = StrongEaseOut))   // 进入：窗口向对侧展开覆盖全屏
        delay(60L)                                                   // hold：整幅山水停驻
        exiting = true
        progress.animateTo(0f, tween(230, easing = StrongEaseOut))   // 退出：窗口同方向收窄消失（v2.1.11 修正）
        visible = false
    }
    if (visible) {
        Canvas(modifier = Modifier.fillMaxSize()) {   // 无 pointerInput：不消费任何点击
            val w = size.width
            val h = size.height
            val p = progress.value
            // v2.1.11：进入/退出分阶段计算窗口位置，保证退出与进入同向——
            // 前进（右→左）：进入左缘 w→0 向右展开覆盖；退出右缘 w→0 向左收窄消失（视觉全程右→左）；
            // 后退（左→右）镜像：进入右缘 0→w 向左展开；退出左缘 0→w 向右收窄。
            // 此前进入/退出共用同一公式，退出阶段窗口从左侧收窄（视觉左→右），方向与进入相反，已修正。
            val left: Float
            val right: Float
            if (!exiting) {
                left = if (forward) w * (1f - p) else 0f
                right = if (forward) w else w * p
            } else {
                val q = 1f - p   // 退出时 p:1→0，q:0→1 单调递增
                // v2.1.12：前进退出 right 用 w*p（p:1→0 → w→0）向左收窄，与进入同向且首帧全屏连续（无闪现）；
                // 此前误用 w*q（0→w 反向扩大）且 p=1 时窗口 0 宽瞬间消失（闪现）——用户反馈"动画向右有闪现 bug"根因。
                left = if (forward) 0f else w * q
                right = if (forward) w * p else w
            }
            clipRect(left = left, top = 0f, right = right, bottom = h) {
                val scale = max(w / bitmap.width, h / bitmap.height)   // cover 铺满全屏
                val iw = bitmap.width * scale
                val ih = bitmap.height * scale
                drawImage(
                    image = bitmap,
                    dstOffset = IntOffset(((w - iw) / 2f).roundToInt(), ((h - ih) / 2f).roundToInt()),
                    dstSize = IntSize(iw.roundToInt(), ih.roundToInt())
                )
            }
        }
    }
}

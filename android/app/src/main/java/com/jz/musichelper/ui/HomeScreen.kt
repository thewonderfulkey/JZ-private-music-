package com.jz.musichelper.ui

import android.graphics.BitmapFactory
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import com.jz.musichelper.R
import com.jz.musichelper.data.HistoryStore
import com.jz.musichelper.model.MusicPlatform
import com.jz.musichelper.model.SearchHistoryItem
import com.jz.musichelper.model.Song
import com.jz.musichelper.network.SearchRanker
import com.jz.musichelper.network.SearchService
import com.jz.musichelper.network.StudioPick
import com.jz.musichelper.ui.theme.InkBrushFont
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import java.util.Calendar

// 搜索平台（v2.1.88：改读 SearchService.platforms——平台行、圆点与「N 平台并发」全部由实际注册的适配器决定，
// 不再在这里写死三个名字；以后增删平台只改 SearchService 一处，界面文案不会再说谎）
private val searchPlatforms: List<MusicPlatform> get() = SearchService.platforms

// ===== 首页 v1.9.0：渐变品牌区 + 搜索栏展开历史 + 阶段化模块（个性化置顶 / 基础层固定）=====
@Composable
fun HomeScreen(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    // v2.1.50：开场动画的就绪信号——首页真正画出第一帧后放行，开场据此收束（不再干等固定时长）
    LaunchedEffect(Unit) {
        withFrameNanos { }
        SplashGate.markReady()
    }
    // 搜索态状态提升为 AppState 全局（方案A）：切 Tab 离开首页时 HomeScreen 组合销毁，但
    // keyword/isSearching/results 随全局驻留，切回首页可恢复搜索关键词与结果，不再命中空态
    var keyword by AppState.searchKeyword
    var isSearching by AppState.searching
    var results by AppState.searchResults
    var showHistory by remember { mutableStateOf(false) }
    val kb = LocalSoftwareKeyboardController.current
    val searched by AppState.searchActive

    // 已确认无源的歌曲（点击解析失败后由 AppState 自动记录）从搜索结果隐藏；其余歌曲立即可点、零等待
    val dead = AppState.deadSongKeys.value
    val effResults = remember(results, dead) {
        results.map { pr -> pr.copy(songs = pr.songs.filterNot { "${it.platform.name}_${it.platformID}" in dead }) }
    }
    // 方案一：去掉平台分组，全平台合并按匹配度（歌名/歌手/专辑多维打分）全局排序，平铺展示
    // v2.1.10：跨平台去重——同一歌手同一首歌（归一化歌名+歌手）只保留匹配度最高的一条，
    // 被合并的其他平台源在播放时由 allowCrossRetry 妖狐酷我兜底换源（见 DarkSongRow）
    val flatRanked = remember(effResults, keyword) {
        SearchRanker.rank(keyword, effResults.flatMap { it.songs })
            .distinctBy { songDedupeKey(it) }
    }

    Column(modifier = modifier.fillMaxSize()) {
        // 非搜索态：品牌一行（v2.1.59）——朱砂方印 + 「发现音乐」书法体（全 App 唯一一处毛笔字）
        // 旧版三行题字（问候语 / 高山流水 + 印章 / 发现音乐）+ 整幅山水当背景，书法体一屏铺满才像"个人画册"。
        // 现在压成一行、总高 ≈54dp（口径 ≤96dp），面积留给下面的榜单。
        if (!searched) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 18.dp, end = 18.dp, top = 8.dp, bottom = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                // 朱砂方印：全页唯一强调色的一点
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .background(p.heartOn, RoundedCornerShape(1.5.dp))
                        .rotate(4f)
                )
                Text(
                    "发现音乐",
                    fontSize = 26.sp,
                    fontFamily = InkBrushFont,
                    letterSpacing = 2.sp,
                    color = p.text,
                    modifier = Modifier.padding(start = 10.dp, top = 2.dp)
                )
            }
        } else {
            // 搜索结果态：返回按钮 + 标题
            Row(
                modifier = Modifier.fillMaxWidth().padding(start = 8.dp, top = 8.dp, bottom = 14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        // v2.1.39：与收藏/历史/下载/设置四处返回钮统一为墨色按压
                        .inkClickable {
                            AppState.searchActive.value = false
                            keyword = ""
                            results = emptyList()
                        },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "返回",
                        tint = p.text2,
                        modifier = Modifier.size(22.dp)
                    )
                }
                Text(
                    "发现音乐",
                    fontSize = 26.sp,
                    fontFamily = InkBrushFont,
                    letterSpacing = 1.5.sp,
                    color = p.text,
                    modifier = Modifier.padding(start = 2.dp, top = 6.dp).rotate(-0.4f)
                )
            }
        }

        // 搜索逻辑统一入口（状态写入与异步搜索收敛到 AppState.search：应用级作用域，切 Tab 不中断）
        val doSearch: (String) -> Unit = { raw ->
            if (raw.trim().isNotEmpty()) {
                showHistory = false
                kb?.hide()   // 搜索后自动收起键盘：避免键盘顶起底部导航挡住 Tab 点击
                AppState.search(raw)
            }
        }

        // 搜索栏（v2.1.59）：白底 44dp 真输入框——放大镜 + 占位文案 + 有字才出现的清除钮。
        // 原先是"一幅水墨横幅"（山水 + 红日当按钮，96dp 高），被一眼看成装饰画框，没人知道能打字。
        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            InkSearchBar(
                keyword = keyword,
                onKeywordChange = { keyword = it },
                onSearch = { doSearch(keyword) },
                isSearching = isSearching,
                // 聚焦即展开搜索历史（关键词为空时由输入框内部触发）；关闭走历史面板自己的关闭钮
                onToggleHistory = { if (!searched) showHistory = true },
                onClear = {
                    // 清空=输入框 + 搜索结果 + 退出搜索态（回首页初始）
                    keyword = ""
                    results = emptyList()
                    AppState.searchActive.value = false
                }
            )
            // 搜索历史展开区（点击搜索栏向下展开）
            // v2.1.38：从搜索栏下方"长出来"（高度展开 220ms + 淡入），而不是整块突然贴上
            AnimatedVisibility(
                visible = showHistory && !searched,
                enter = expandVertically(tween(220, easing = StrongEaseOut)) { it } + fadeIn(tween(180)),
                exit = shrinkVertically(tween(180, easing = StrongEaseOut)) { it } + fadeOut(tween(130)),
                label = "searchHistory"
            ) {
                SearchHistoryPanel(onSearch = doSearch, onClose = { showHistory = false })
            }
        }

        // 平台状态行（搜索后显示）
        if (searched) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                searchPlatforms.forEach { pl ->
                    val pr = effResults.firstOrNull { it.platform == pl }
                    // v2.1.41：三颗平台灯原先是"搜索中灰蓝 → 墨色 / 朱红"同时硬闪，
                    // 8dp 的小圆点一起跳色比单点更扎眼；改为 180ms 过渡，与底栏图标配色同一套语言
                    val color by animateColorAsState(
                        targetValue = when {
                            isSearching -> p.accent2
                            pr == null -> p.text3.copy(alpha = 0.5f)
                            pr.songs.isNotEmpty() -> p.accent
                            pr.error != null -> Color(0xFFC0392B)
                            else -> p.text3
                        },
                        animationSpec = tween(180, easing = FastOutSlowInEasing),
                        label = "platformDot"
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(8.dp).background(color, CircleShape))
                        Spacer(Modifier.width(4.dp))
                        Text(pl.shortName, fontSize = 12.sp, color = p.text2)
                        // v2.1.88：标出每个平台本次实际返回的条数——"酷我到底回没回"从此一眼可查，
                        // 不用翻列表猜（用户这次反馈正卡在这个判断上）
                        if (searched && !isSearching) {
                            Spacer(Modifier.width(3.dp))
                            Text("${pr?.songs?.size ?: 0}", fontSize = 10.5.sp, color = p.text3)
                        }
                    }
                }
                // v2.1.95：恢复四平台后「4 平台并发」会换行，占位也没有信息量——去掉，
                // 左侧每个平台自己的条数已经说明一切
                Spacer(Modifier.weight(1f))
            }
        }

        // 内容区
        // v2.1.41：转圈 → 结果原本是整块硬替换（转圈停住那一帧、结果凭空铺满）。
        // 这里只把「搜索中 / 无结果 / 有结果」三态做 200ms 交叉；退出搜索回首页仍按原样直切，
        // 不把 HomeRecommend 拉进交叉（首页列表与猜你喜欢会双份组合，代价大于观感收益）
        val resultPhase = when {
            isSearching -> "loading"
            searched && effResults.all { it.songs.isEmpty() } -> "empty"
            searched -> "results"
            else -> "home"
        }
        if (resultPhase == "home") {
            HomeRecommend(onOpenPlaylist = { AppState.openPlaylist.value = it })
        } else {
            Crossfade(
                targetState = resultPhase,
                modifier = Modifier.fillMaxSize(),
                animationSpec = tween(200, easing = FastOutSlowInEasing),
                label = "searchContent"
            ) { phase ->
                when (phase) {
                    "loading" -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = p.accent)
                    }

                    "empty" -> EmptyHint("没有找到结果", "换个关键词试试")

                    else -> {
                        // 平铺：全平台合并、按匹配度排序（每条自带平台标签），无平台分组标题
                        // 2.0.3：底部 contentPadding 60dp（与首页一致）——此前无底部预留，最后一条滚动到底被播放悬浮栏遮挡
                        LazyColumn(
                            modifier = Modifier.fillMaxSize(),
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 60.dp)
                        ) {
                            items(flatRanked, key = { "${it.platform.name}_${it.platformID}" }) { song ->
                                DarkSongRow(song, queue = flatRanked, allowCrossRetry = true)
                            }
                            item { Spacer(Modifier.height(8.dp)) }
                        }
                    }
                }
            }
        }
    }
}

// ===== 搜索历史展开面板（chips）=====
// v2.1.10 跨平台去重键：归一化歌名+歌手（小写、去 &nbsp;/HTML 实体、去标点空格），
// "Letting Go(QQ)" 与 "Letting Go(网易)" 归并为一条，保留匹配度最高者
private fun songDedupeKey(s: Song): String {
    fun norm(v: String): String = v.lowercase()
        .replace("&nbsp;", " ")
        .replace("\\u0026", "&")
        .replace(Regex("[^0-9a-z\\u4e00-\\u9fff]"), "")
    return norm(s.name) + "|" + norm(s.singer)
}

// ===== 搜索历史展开面板（chips）=====
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SearchHistoryPanel(onSearch: (String) -> Unit, onClose: () -> Unit) {
    val p = LocalPalette.current
    val his = HistoryStore.loadSearchHistory()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp)
            .background(p.surface2.copy(alpha = 0.5f), RoundedCornerShape(14.dp))
            .padding(12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("搜索历史", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.text)
            Spacer(Modifier.weight(1f))
            if (his.isNotEmpty()) {
                Text(
                    "清空",
                    fontSize = 12.sp,
                    color = p.text3,
                    // v2.1.41：全站最后一处裸 clickable 的可点文字，统一为墨色按压
                    modifier = Modifier
                        .inkClickable {
                            HistoryStore.clearSearchHistory()
                            onClose()
                        }
                        .padding(4.dp)
                )
            }
        }
        Spacer(Modifier.height(8.dp))
        if (his.isEmpty()) {
            Text("暂无搜索历史 · 搜索过的关键词会显示在这里", fontSize = 12.sp, color = p.text3)
        } else {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                his.take(20).forEach { h ->
                    Text(
                        h.keyword,
                        fontSize = 13.sp,
                        color = p.accent2,
                        modifier = Modifier
                            .background(p.surface, RoundedCornerShape(20.dp))
                            // v2.1.39：热门词条补按压反馈（原先点上去毫无回应）
                            .inkClickable { onSearch(h.keyword) }
                            .padding(horizontal = 13.dp, vertical = 6.dp)
                    )
                }
            }
        }
    }
}

// ===== 首页模块：编辑精选（最上）→ 个性化层（最近播放/猜你喜欢）→ 热门音乐 =====
enum class HomeStage { PURE, EARLY, MATURE }

// 首页模块缓存：当天首次加载后缓存，当天内切回首页秒开、不重新请求；跨天才刷新
private object HomeCache {
    data class Cached<T>(val data: T, val day: Int)
    var hot: Cached<List<Song>>? = null
    var guess: Cached<List<GuessEngine.GuessItem>>? = null
    var guessUpdatedAt: Long = 0L       // 最近一次猜你喜欢重算时间戳（行为触发节流）
    var lastGuessSig: String = ""       // 上次重算时的行为签名
    var lastEditorInjDay: Int = -1      // 编辑精选池最近一次扩展注入的日期（跨天一次）
    val today: Int get() = (System.currentTimeMillis() / 86_400_000L).toInt()

    // ---- 持久化（v1.9.6：重启后秒开，不再每次全量重搜）----
    private const val P_HOT = "home_hot_cache"
    private const val P_GUESS = "home_guess_cache"
    // ③/④ 修复：缓存版本号——词库/封面解析等逻辑升级后，旧版缓存（无 ver 或 ver<2）一律作废，
    // 覆盖安装当天即强制用新逻辑重建（否则同天命中旧缓存，新代码不执行）
    // 1.9.9：热门取歌改为逐词取歌（v3 强制重建当天生效，不再显示旧榜）
    // 2.0.0：热门改为动态池（持续增长、每日 20 首、跨天换新），v4 强制重建旧的 8 首缓存
    // 2.1.61：热门改分页后需要 21 首（7 页 × 3 首），v7 强制重建缓存里只有 20 首的旧榜
    private const val HOT_VER = 7
    // 2.1.30：猜你喜欢候选池改为「录音棚原唱优选」（StudioPick），旧缓存里的节目消音版（如《龙文》243s）
    // 当天仍会命中显示，故升版强制重建
    private const val GUESS_VER = 3
    private var prefs: android.content.SharedPreferences? = null

    fun ensureInit(ctx: android.content.Context) {
        if (prefs != null) return
        synchronized(this) {
            if (prefs != null) return
            prefs = ctx.getSharedPreferences("jz_home_cache", android.content.Context.MODE_PRIVATE)
        }
    }

    private fun songToJson(s: Song) = org.json.JSONObject()
        .put("platform", s.platform.name)
        .put("id", s.platformID)
        .put("name", s.name)
        .put("singer", s.singer)
        .put("album", s.album)
        .put("dur", s.durationSec)
        .put("pic", s.picUrl ?: "")

    private fun songFromJson(o: org.json.JSONObject): Song {
        val platform = runCatching { MusicPlatform.valueOf(o.optString("platform")) }.getOrDefault(MusicPlatform.QQ)
        return Song(platform, o.optString("id"), o.optString("name"), o.optString("singer"),
            o.optString("album"), o.optInt("dur"), o.optString("pic").takeIf { it.isNotEmpty() })
    }

    fun persistHot(songs: List<Song>) {
        hot = Cached(songs, today)
        val p = prefs ?: return
        runCatching {
            val arr = org.json.JSONArray()
            songs.take(60).forEach { arr.put(songToJson(it)) }
            p.edit().putString(P_HOT, org.json.JSONObject().put("day", today).put("ver", HOT_VER).put("list", arr).toString()).apply()
        }
    }

    fun loadHot(): Cached<List<Song>>? {
        hot?.let { return it }
        val p = prefs ?: return null
        val j = runCatching { org.json.JSONObject(p.getString(P_HOT, "{}") ?: "{}") }.getOrNull() ?: return null
        // ③ 修复：版本不符（旧版缓存）→ 作废返回 null，强制用新逻辑重载
        if (j.optInt("ver") != HOT_VER) { hot = null; return null }
        return runCatching {
            val arr = j.optJSONArray("list") ?: org.json.JSONArray()
            val songs = (0 until arr.length()).map { songFromJson(arr.getJSONObject(it)) }
            Cached(songs, j.optInt("day")).also { hot = it }
        }.getOrNull()
    }

    fun persistGuess(items: List<GuessEngine.GuessItem>, sig: String) {
        guess = Cached(items, today)
        guessUpdatedAt = System.currentTimeMillis()
        lastGuessSig = sig
        val p = prefs ?: return
        runCatching {
            val arr = org.json.JSONArray()
            items.forEach { it.song.let { s -> arr.put(songToJson(s).put("reason", it.reason)) } }
            p.edit().putString(P_GUESS, org.json.JSONObject()
                .put("day", today).put("ver", GUESS_VER).put("sig", sig).put("updated", guessUpdatedAt).put("list", arr).toString()).apply()
        }
    }

    fun loadGuess(): Pair<Cached<List<GuessEngine.GuessItem>>, String>? {
        guess?.let { return it to lastGuessSig }
        val p = prefs ?: return null
        val j = runCatching { org.json.JSONObject(p.getString(P_GUESS, "{}") ?: "{}") }.getOrNull() ?: return null
        // ④ 修复：版本不符（旧版缓存里的酷狗歌仍是旧封面字段）→ 作废强制重算
        if (j.optInt("ver") != GUESS_VER) { guess = null; return null }
        return runCatching {
            val arr = j.optJSONArray("list") ?: org.json.JSONArray()
            val items = (0 until arr.length()).map { idx ->
                val o = arr.getJSONObject(idx)
                GuessEngine.GuessItem(songFromJson(o), o.optString("reason", "为你精选"))
            }
            val c = Cached(items, j.optInt("day"))
            guess = c
            lastGuessSig = j.optString("sig")
            guessUpdatedAt = j.optLong("updated")
            c to lastGuessSig
        }.getOrNull()
    }
}

// ===== 动态候选池：种子 + 每次刷新注入新歌；三重循环控制（近 7 天不推 / 首见 3 天优先 / 超 30 天旧歌低频）；本地持久化 =====
private data class PoolSong(
    val key: String,          // 平台_id 或 seed_歌名|歌手
    val name: String,
    val singer: String,
    val category: String,     // 华语经典/粤语金曲/影视 OST/欧美热单/热门/guess
    val firstSeenDay: Int,    // 加入池的天数（UTC）
    var lastShownDay: Int,    // 最近一次被推荐展示的天数（-1 从未）
    var shownCount: Int
)

private object DynamicPool {
    private const val MAX_SIZE = 2000
    private const val PREFS_NAME = "jz_home_pool"
    private var pool = mutableListOf<PoolSong>()
    private var hotWords = mutableListOf<String>()
    private var inited = false
    private var prefs: android.content.SharedPreferences? = null

    fun ensureInit(ctx: android.content.Context) {
        if (inited) return
        prefs = ctx.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
        try {
            val arr = org.json.JSONArray(prefs?.getString("pool", "[]") ?: "[]")
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                pool += PoolSong(o.getString("key"), o.getString("name"), o.getString("singer"),
                    o.getString("cat"), o.getInt("f"), o.getInt("l"), o.getInt("c"))
            }
        } catch (_: Exception) { pool.clear() }
        try {
            val arr = org.json.JSONArray(prefs?.getString("words", "[]") ?: "[]")
            for (i in 0 until arr.length()) hotWords += arr.getString(i)
        } catch (_: Exception) { hotWords.clear() }
        // ③ 修复：一次清洗——只保留种子词 + STYLE 白名单歌手词，旧版残留的网红/翻唱歌手词全部剔除并持久化
        val known = SongProfile.STYLE.keys
        val cleaned = hotWords.filter { w -> HotMusic.SEED_WORDS.contains(w) || known.contains(w) }
        if (cleaned.size != hotWords.size) {
            hotWords = cleaned.toMutableList()
            prefs?.edit()?.putString("words", org.json.JSONArray(hotWords).toString())?.apply()
        }
        if (pool.isEmpty()) seed()
        inited = true
    }

    /** 首装种子：120 首预置歌 + 10 个热门种子词；首见/最近展示设为 14 天前（不算新鲜，避免首日全推种子） */
    private fun seed() {
        val day = HomeCache.today
        EditorPlaylist.ALL.forEach { pl -> pl.songs.forEach { (n, s) ->
            pool += PoolSong("seed_$n|$s", n, s, pl.title, day - 14, day - 14, 0)
        } }
        hotWords += HotMusic.SEED_WORDS
        save()
    }

    private fun keyOf(s: Song): String =
        if (s.platformID.isNotBlank()) "${s.platform.name}_${s.platformID}" else "seed_${s.name}|${s.singer}"

    /** 注入新歌：新 key 入池记录首见日；超上限只淘汰最近展示最旧的歌。
     *  2.0.2：热门池按原唱标准注入——同核心歌名只入原版（name≠核心名的 Live/翻唱/DJ/伴奏等剔除），
     *  保证动态池只积累原唱、稳定自动增加，不与展示侧原唱标准脱节 */
    fun inject(songs: List<Song>, category: String) {
        val day = HomeCache.today
        val items = if (category == "热门") {
            val best = LinkedHashMap<String, Song>()
            songs.forEach { s ->
                val k = HotMusic.coreName(s.name)
                if (k.isEmpty() || s.singer.isBlank() || s.name.trim() != k) return@forEach
                val prev = best[k]
                if (prev == null || HotMusic.plainScore(s.name) > HotMusic.plainScore(prev.name)) best[k] = s
            }
            best.values.toList()
        } else songs
        items.forEach { s ->
            val k = keyOf(s)
            if (pool.none { it.key == k }) pool += PoolSong(k, s.name, s.singer, category, day, -1, 0)
        }
        if (pool.size > MAX_SIZE) {
            val old = pool.filter { it.lastShownDay >= 0 }.sortedBy { it.lastShownDay }.take(pool.size - MAX_SIZE)
            old.forEach { pool.remove(it) }
        }
        save()
    }

    /** 近 window 天推荐展示过的 key 集合（三重控制①：近期排除） */
    fun recentShown(day: Int, window: Int = 7): Set<String> =
        pool.filter { it.lastShownDay >= day - window }.map { it.key }.toSet()

    /** 标记推荐展示（防明日重复推同一批） */
    fun markShown(songs: List<Song>) {
        val day = HomeCache.today
        songs.forEach { s ->
            pool.firstOrNull { it.key == keyOf(s) }?.let { it.lastShownDay = day; it.shownCount += 1 }
        }
        save()
    }

    fun markShownPairs(songs: List<Pair<String, String>>) {
        val day = HomeCache.today
        songs.forEach { (n, s) ->
            pool.firstOrNull { it.key == "seed_$n|$s" }?.let { it.lastShownDay = day; it.shownCount += 1 }
        }
        save()
    }

    /** 每类当天候选：排除近 7 天已推，首见 ≤3 天新歌优先（三重控制②），其余按推荐少/久未推优先（三重控制③ 低频怀旧） */
    fun categorySongs(category: String, day: Int, limit: Int): List<Pair<String, String>> {
        val shown = recentShown(day, 7)
        val cands = pool.filter { it.category == category && it.key !in shown }
        val fresh = cands.filter { it.firstSeenDay >= day - 3 }.sortedByDescending { it.firstSeenDay }
        val rest = cands.filter { it.firstSeenDay < day - 3 }.sortedWith(compareBy({ it.shownCount }, { it.lastShownDay }))
        return (fresh + rest).take(limit).map { it.name to it.singer }
    }

    /** 热门词库：种子词（2.0.0 扩到 24，随天平移主导）+ 白名单动态注入词（上限 30，超出种子数才补充） */
    fun wordsForToday(count: Int = 20): List<String> {
        if (hotWords.isEmpty()) hotWords += HotMusic.SEED_WORDS
        val day = HomeCache.today
        val seeds = HotMusic.SEED_WORDS
        val extras = hotWords.filter { it !in seeds }
        return (0 until count).map { i ->
            if (i < seeds.size) seeds[(day + i) % seeds.size]
            else if (extras.isNotEmpty()) extras[(day + i) % extras.size]
            else seeds[(day + i) % seeds.size]
        }
    }

    /** 每 3 天把搜索结果中的「知名歌手」注入热门词库（③b 修复：白名单过滤，网红/翻唱歌手不进库；上限收紧到 30，保护种子词主导） */
    fun injectWords(names: List<String>) {
        if (HomeCache.today % 3 != 0) return
        val known = SongProfile.STYLE.keys
        names.forEach { n -> if (n.isNotBlank() && hotWords.size < 30 && n !in hotWords && n in known) hotWords += n }
        save()
    }

    /** 探索候选：从未推荐过且不在近期排除内的歌（猜你喜欢 20% 探索位） */
    fun explorationKeys(day: Int, limit: Int): List<Pair<String, String>> {
        val shown = recentShown(day, 7)
        return pool.filter { it.shownCount == 0 && it.key !in shown }
            .sortedByDescending { it.firstSeenDay }
            .take(limit).map { it.name to it.singer }
    }

    private fun save() {
        val arr = org.json.JSONArray()
        pool.forEach { p ->
            arr.put(org.json.JSONObject().put("key", p.key).put("name", p.name).put("singer", p.singer)
                .put("cat", p.category).put("f", p.firstSeenDay).put("l", p.lastShownDay).put("c", p.shownCount))
        }
        prefs?.edit()?.putString("pool", arr.toString())?.putString("words", org.json.JSONArray(hotWords).toString())?.apply()
    }
}

@Composable
private fun HomeRecommend(onOpenPlaylist: (EditorPlaylist) -> Unit) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current.applicationContext
    // 持久化缓存必须在 remember 读缓存之前初始化（否则重启秒开失效）
    HomeCache.ensureInit(ctx)
    DynamicPool.ensureInit(ctx)
    val recents = HistoryStore.loadRecentSongs()
    val searches = HistoryStore.loadSearchHistory()
    val favs = HistoryStore.loadFavorites()
    // 下载记录也作为推荐参考因素（与收藏同档权重，进兴趣向量/查询/推荐理由）；与播放/收藏/搜索一致，每次重组重读
    val downloads = HistoryStore.loadDownloadItems().map { it.song }

    // 成熟度：草案阈值（起步 ≥3 播放 或 ≥5 搜索；成熟 ≥10 播放 且 ≥15 搜索），后续可调
    val stage = remember(recents.size, searches.size) {
        when {
            recents.size >= 10 && searches.size >= 15 -> HomeStage.MATURE
            recents.size >= 3 || searches.size >= 5 -> HomeStage.EARLY
            else -> HomeStage.PURE
        }
    }

    // 编辑精选（动态池每日取歌：排除近 7 天已推 + 新注入优先；跨天换新一批）——展示即标记，防明日重复
    val todayKey = HomeCache.today
    val editorPlays = remember(todayKey) { EditorPlaylist.forToday() }

    // 热门音乐（动态词库按日期取 8 词并发搜索）——持久化缓存命中直接显示，未命中才加载
    var hotSongs by remember { mutableStateOf(HomeCache.loadHot()?.takeIf { it.day == HomeCache.today }?.data) }
    // 猜你喜欢（行为信号混合打分）——持久化缓存当天命中直接显示；跨天或行为签名变化（节流 5 分钟）才重算
    var guessItems by remember { mutableStateOf(HomeCache.loadGuess()?.first?.takeIf { it.day == HomeCache.today }?.data) }
    val behaviorSig = buildString {
        recents.takeLast(3).forEach { append(it.platform.name).append('_').append(it.platformID).append('|') }
        searches.takeLast(3).forEach { append(it.keyword).append('|') }
        append(favs.size)
        downloads.takeLast(3).forEach { append(it.platform.name).append('_').append(it.platformID).append('|') }
    }

    // 统一调度：首帧初始化动态池 + 编辑精选池跨天扩展注入 + 热门加载（跨天才刷新缓存）
    LaunchedEffect(Unit) {
        DynamicPool.ensureInit(ctx)
        if (HomeCache.lastEditorInjDay != HomeCache.today) {
            // 编辑精选池扩展注入：每类用代表歌手搜索新歌回填该类（跨天一次）
            EditorPlaylist.ALL.forEach { pl ->
                val probe = pl.songs.map { it.second }.distinct().take(2).joinToString(" ")
                runCatching { SearchService.searchAll(probe, 20) }.getOrNull()
                    ?.flatMap { it.songs }?.let { DynamicPool.inject(it, pl.title) }
            }
            HomeCache.lastEditorInjDay = HomeCache.today
        }
        DynamicPool.markShownPairs(editorPlays.flatMap { it.songs })
        // 热门：持久化缓存秒开（含跨天旧数据先显示）；③ 修复：无论命中与否（含当天旧缓存）都后台重载一次覆盖——
        // 词库/封面解析等新逻辑升级后同天立即生效，不再被旧缓存短路
        if (hotSongs == null) {
            val cached = HomeCache.loadHot()
            if (cached != null) hotSongs = cached.data
            val loaded = HotMusic.load()
            hotSongs = loaded
            HomeCache.persistHot(loaded)
            DynamicPool.markShown(loaded)
        }
    }

    // 猜你喜欢调度：PURE 清空；持久化缓存当天命中且行为未变 → 秒开；跨天或行为变化（>5 分钟节流）→ 先显示旧缓存，后台重算 + 补齐探索位
    LaunchedEffect(stage, behaviorSig) {
        if (stage == HomeStage.PURE) {
            guessItems = emptyList()
            HomeCache.guess = null
            return@LaunchedEffect
        }
        val now = System.currentTimeMillis()
        val cachedPair = HomeCache.loadGuess()
        val cached = cachedPair?.first
        val sameDay = cached?.day == HomeCache.today
        val behaviorChanged = cachedPair?.second != behaviorSig
        if (sameDay && !behaviorChanged) {
            guessItems = cached!!.data
            return@LaunchedEffect
        }
        if (sameDay && now - HomeCache.guessUpdatedAt < 5 * 60 * 1000L) {
            guessItems = cached!!.data
            return@LaunchedEffect
        }
        val maxGuess = if (stage == HomeStage.MATURE) 12 else 6
        val compute: suspend () -> Unit = {
            // 第一段：主推荐（行为搜索）先出，秒显
            val g = GuessEngine.recommend(recents, searches, favs, downloads, max = maxGuess, includeExpansion = false)
            guessItems = g
            HomeCache.persistGuess(g, behaviorSig)
            DynamicPool.markShown(g.map { it.song })
            DynamicPool.inject(recents + favs, "guess")
            // 第二段：后台补齐探索位 + 编辑池补歌（不阻塞首屏）
            val full = GuessEngine.expand(g, maxGuess)
            if (full.size > g.size) {
                guessItems = full
                HomeCache.persistGuess(full, behaviorSig)
                DynamicPool.markShown(full.map { it.song })
            }
        }
        if (cached != null) {
            // 跨天/行为变化：先秒开旧缓存，后台重算
            guessItems = cached.data
            launch { compute() }
        } else {
            // 无缓存（首次）：同步算，主推荐出现即显示
            compute()
        }
    }

    val openSong: (Song, List<Song>) -> Unit = { song, queue ->
        val r = runCatching { AppState.openSong(song, queue) }
        if (r.isFailure) toast("打开失败：" + (r.exceptionOrNull()?.message ?: "未知异常"))
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        // ② 修复（2.0.1）：底部预留 = 悬浮条体系(56 高 + 62 抬升 + 手势条 ≈118dp) − 底部导航(≈58dp) ≈ 60dp，
        // 滚动到底时最后一首歌底边正好紧贴播放悬浮栏顶部（零空隙），不再有 178dp 时代的大段空白
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 60.dp)
    ) {
        // ===== 首屏结构（v2.1.62 口径，用户指定自上而下）：编辑精选 → 最近播放 → 猜你喜欢 → 热门音乐 =====
        // v2.1.83：听歌识曲入口条撤出首页（改到底层栏第 2 格独立页），首页恢复原样
        // ===== 编辑精选（v2.1.59：撤水墨海报缩略图，改纸面文字卡；横向滑动看 4 类歌单）=====
        item {
            SectionTitle("编辑精选", "每日换一批")
        }
        item {
            LazyRow(contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(EditorPlaylist.forToday()) { pl ->
                    EditorCard(pl = pl, onOpen = { onOpenPlaylist(pl) })
                }
            }
        }
        // ===== 最近播放（v2.1.59：大封面横排；meta 不再露内部字段名 recent_songs）=====
        if (stage != HomeStage.PURE) {
            item {
                SectionTitle("最近播放", "${recents.size} 首")
            }
            item {
                LazyRow(contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(recents.take(8), key = { "${it.platform.name}_${it.platformID}" }) { song ->
                        SmallCard(song = song, size = 112.dp) { openSong(song, recents) }
                    }
                }
            }
        }
        if (stage != HomeStage.PURE) {
        // 猜你喜欢（网易云式：一屏 3 首横排列表行为一组，整页左右滑动翻组；无页码/提示/换一批）
            item {
                Text(
                    "猜你喜欢",
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = InkTitleFont,
                    color = p.text,
                    modifier = Modifier.padding(start = 18.dp, end = 18.dp, top = 20.dp, bottom = 10.dp)
                )
            }
            item {
                // v2.1.41：加载中 → 内容原本是硬切（转圈停住那一帧、三行歌凭空出现）。
                // 只做 200ms 交叉，不做高度动画——在 LazyColumn 里每帧改高度等于每帧重排整列
                val g = guessItems
                Crossfade(
                    targetState = when {
                        g == null -> "loading"
                        g.isEmpty() -> "empty"
                        else -> "content"
                    },
                    animationSpec = tween(200, easing = FastOutSlowInEasing),
                    label = "guessContent"
                ) { phase ->
                    when (phase) {
                        "loading" -> Box(Modifier.fillMaxWidth().height(190.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(modifier = Modifier.size(22.dp), color = p.accent, strokeWidth = 2.dp)
                        }
                        "empty" -> GuessEmptyGuide()
                        else -> {
                            val gg = guessItems
                            if (gg != null && gg.isNotEmpty()) {
                                val pages = gg.chunked(3)
                                val pagerState = rememberPagerState(pageCount = { pages.size })
                                HorizontalPager(
                                    state = pagerState,
                                    modifier = Modifier.fillMaxWidth()
                                ) { page ->
                                    Column(modifier = Modifier.fillMaxWidth()) {
                                        pages[page].forEach { item ->
                                            // v2.1.9：仅猜你喜欢入口启用"换源重试至解析成功"（allowCrossRetry）——
                                            // 一个源解析失败自动换妖狐酷我继续解析同一首歌，直到成功；其他模块不变
                                            GuessRow(item = item, onClick = { AppState.openSong(item.song, gg.map { it.song }, allowCrossRetry = true) })
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ===== 热门音乐（v2.1.62：整块挪到最末；分页口径仍是 v2.1.61——一页 3 首、左右滑动、7 页 21 首）=====
        item {
            SectionTitle("热门音乐", "每日更新")
        }
        item {
            // v2.1.41：转圈直接长成榜单——只做 200ms 交叉，不碰高度
            // v2.1.61：加载占位高度对齐 3 行（48+16×3 = 192dp），榜单从转圈长出来时不跳
            Crossfade(
                targetState = hotSongs != null,
                animationSpec = tween(200, easing = FastOutSlowInEasing),
                label = "hotContent"
            ) { ready ->
                val h = hotSongs
                if (!ready || h == null) {
                    Box(Modifier.fillMaxWidth().height(192.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(modifier = Modifier.size(22.dp), color = p.accent, strokeWidth = 2.dp)
                    }
                } else {
                    // 与「猜你喜欢」同一套分页：每页 3 行、HorizontalPager 左右滑、无页码无提示
                    val pages = h.chunked(3)
                    val hotPagerState = rememberPagerState(pageCount = { pages.size })
                    HorizontalPager(
                        state = hotPagerState,
                        modifier = Modifier.fillMaxWidth()
                    ) { page ->
                        Column(modifier = Modifier.fillMaxWidth()) {
                            pages[page].forEach { song ->
                                HotListRow(song = song, onClick = { openSong(song, h) })
                            }
                        }
                    }
                }
            }
        }

        item {
            Spacer(Modifier.height(20.dp))
        }
        // 纯净版无个性化数据：猜你喜欢引导收尾
        if (stage == HomeStage.PURE) {
            item {
                GuessEmptyGuide()
            }
            item {
                Spacer(Modifier.height(16.dp))
            }
        }
    }
}

@Composable
private fun SectionTitle(title: String, meta: String) {
    val p = LocalPalette.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(start = 18.dp, top = 18.dp, end = 18.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, fontFamily = InkTitleFont, color = p.text)
        Spacer(Modifier.weight(1f))
        Text(meta, fontSize = 11.sp, color = p.text3)
    }
}

// ===== 小卡（封面 + 歌名 + 歌手）=====
// v2.1.59：圆角 14→10（封面的圆角不必比卡片更大）、歌名 Medium、歌手 11.5sp 次文字；
// 去掉纸色 Shadow——那是为了在山水底图上把字抠出来，现在底是平纸，描边只会让字发糊。
@Composable
private fun SmallCard(song: Song, size: androidx.compose.ui.unit.Dp, onClick: () -> Unit) {
    val p = LocalPalette.current
    Column(modifier = Modifier.inkClickable { onClick() }) {
        SongCover(song = song, size = size, corner = 10.dp)
        Spacer(Modifier.height(7.dp))
        Text(song.name, color = p.text, fontSize = 13.sp, fontWeight = FontWeight.Medium, fontFamily = InkTitleFont, maxLines = 1, modifier = Modifier.width(size))
        Spacer(Modifier.height(2.dp))
        Text(song.singer, color = p.text2, fontSize = 11.5.sp, maxLines = 1, modifier = Modifier.width(size))
    }
}

// ===== 热门音乐榜单行（与「猜你喜欢」行同一套排布：48dp 封面 + 歌名 + 副行 + 播放）=====
// v2.1.60：按反馈「热门音乐样式改为和猜你喜欢一样」，去掉左侧序号列，封面 44→48dp、圆角 8→10、
// 行内上下留白 6→8dp，与 GuessRow 完全同高同宽（副行只有歌手，猜你喜欢的副行是推荐理由 + 歌手）。
@Composable
private fun HotListRow(song: Song, onClick: () -> Unit) {
    val p = LocalPalette.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .inkClickable { onClick() }
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SongCover(song = song, size = 48.dp, corner = 10.dp)
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(song.name, color = p.text, fontSize = 15.sp, fontWeight = FontWeight.Medium, fontFamily = InkTitleFont, maxLines = 1)
            Spacer(Modifier.height(3.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(song.singer, color = p.text2, fontSize = 12.sp, maxLines = 1)
            }
        }
        Icon(Icons.Filled.PlayArrow, contentDescription = "播放", tint = p.text3, modifier = Modifier.size(22.dp))
    }
}

// ===== 猜你喜欢行卡（网易云式横排列表行：小封面 + 歌名 + 推荐理由/歌手 + 播放钮）=====
// v2.1.59：推荐理由已经含歌手名时（"因为你在听 周杰伦" + 右侧又写一遍"周杰伦"）就不再重复一次；
// 播放三角改灰、歌手去掉纸色描边，与榜单行同语言。
@Composable
private fun GuessRow(item: GuessEngine.GuessItem, onClick: () -> Unit) {
    val p = LocalPalette.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .inkClickable { onClick() }
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SongCover(song = item.song, size = 48.dp, corner = 10.dp)
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(item.song.name, color = p.text, fontSize = 15.sp, fontWeight = FontWeight.Medium, fontFamily = InkTitleFont, maxLines = 1)
            Spacer(Modifier.height(3.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    item.reason,
                    color = p.accent2,
                    fontSize = 12.sp,
                    maxLines = 1,
                    modifier = Modifier.weight(1f, fill = false)
                )
                if (!item.reason.contains(item.song.singer)) {
                    Spacer(Modifier.width(8.dp))
                    Text(item.song.singer, color = p.text2, fontSize = 12.sp, maxLines = 1)
                }
            }
        }
        Icon(Icons.Filled.PlayArrow, contentDescription = "播放", tint = p.text3, modifier = Modifier.size(22.dp))
    }
}

// ===== 猜你喜欢引导（纯净版）=====
@Composable
private fun GuessEmptyGuide() {
    val p = LocalPalette.current
    // v2.1.38：引导卡随个性化层出现时淡入 + 自 96% 轻放
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }
    AnimatedVisibility(
        visible = appeared,
        enter = fadeIn(tween(220)) + scaleIn(initialScale = 0.96f, animationSpec = tween(240, easing = StrongEaseOut))
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .background(p.surface2.copy(alpha = 0.4f), RoundedCornerShape(14.dp))
                .padding(18.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text("猜你喜欢", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.text)
            Spacer(Modifier.height(6.dp))
            Text("多搜索、多听几首喜欢的歌", fontSize = 13.sp, color = p.text2)
            Spacer(Modifier.height(4.dp))
            Text("猜你喜欢会根据你的播放记录与搜索历史，在这里为你推荐", fontSize = 12.sp, color = p.text3)
        }
    }
}

// ===== 编辑精选歌单（每类预置 30 首真实歌曲，每天按日期轮换取 20 首展示；点单曲才搜索播放；每类固定 AI 海报）=====
data class EditorPlaylist(val title: String, val posterRes: Int, val themeColor: Long, val songs: List<Pair<String, String>>) {
    val count: String get() = "${songs.size} 首"
    companion object {
        /** 每类固定海报（AI 生成，入库 drawable-xxhdpi） */
        private fun posterOf(title: String): Int = when (title) {
            "华语经典" -> R.drawable.editor_chinese
            "粤语金曲" -> R.drawable.editor_cantonese
            "影视 OST" -> R.drawable.editor_ost
            else -> R.drawable.editor_western
        }

        /** 每类同主题边框色：与类别气质一致，便于一眼区分（① 需求） */
        private fun themeColorOf(title: String): Long = when (title) {
            "华语经典" -> 0xFFF0B45A  // 暖金
            "粤语金曲" -> 0xFF5A7DF0  // 宝蓝
            "影视 OST" -> 0xFFE0608E  // 玫红
            else -> 0xFF3EC6A8       // 青绿（欧美热单）
        }

        /** 每类完整池（24~30 首），供每日轮换取子集 */
        private val POOLS: List<Pair<String, List<Pair<String, String>>>> = listOf(
            "华语经典" to listOf(
                "晴天" to "周杰伦", "七里香" to "周杰伦", "青花瓷" to "周杰伦", "告白气球" to "周杰伦",
                "稻香" to "周杰伦", "夜曲" to "周杰伦", "安静" to "周杰伦", "演员" to "薛之谦",
                "丑八怪" to "薛之谦", "动物世界" to "薛之谦", "后来" to "刘若英", "成都" to "赵雷",
                "理想" to "赵雷", "光年之外" to "邓紫棋", "泡沫" to "邓紫棋", "小幸运" to "田馥甄",
                "平凡之路" to "朴树", "江南" to "林俊杰", "曹操" to "林俊杰", "童话" to "光良",
                "隐形的翅膀" to "张韶涵", "勇气" to "梁静茹", "听海" to "张惠妹", "红豆" to "王菲",
                "十年" to "陈奕迅", "好久不见" to "陈奕迅", "模特" to "李荣浩", "年少有为" to "李荣浩",
                "消愁" to "毛不易", "像我这样的人" to "毛不易"
            ),
            "粤语金曲" to listOf(
                "光辉岁月" to "Beyond", "海阔天空" to "Beyond", "喜欢你" to "Beyond", "真的爱你" to "Beyond",
                "不再犹豫" to "Beyond", "灰色轨迹" to "Beyond", "冷雨夜" to "Beyond", "Amani" to "Beyond",
                "富士山下" to "陈奕迅", "浮夸" to "陈奕迅", "单车" to "陈奕迅", "明年今日" to "陈奕迅",
                "K歌之王" to "陈奕迅", "Shall We Talk" to "陈奕迅", "红日" to "李克勤", "月半小夜曲" to "李克勤",
                "千千阙歌" to "陈慧娴", "处处吻" to "杨千嬅", "遥远的她" to "张学友", "每天爱你多一些" to "张学友",
                "只想一生跟你走" to "张学友", "暗涌" to "王菲", "约定" to "王菲", "一生所爱" to "卢冠廷",
                "上海滩" to "叶丽仪", "万水千山总是情" to "汪明荃", "沧海一声笑" to "许冠杰", "倩女幽魂" to "张国荣",
                "风继续吹" to "张国荣", "沉默是金" to "张国荣"
            ),
            "影视 OST" to listOf(
                "体面" to "于文文", "后会无期" to "邓紫棋", "年轮" to "张碧晨", "大鱼" to "周深",
                "凉凉" to "张碧晨 杨宗纬", "时间煮雨" to "郁可唯", "只要平凡" to "张杰 张碧晨",
                "My Heart Will Go On" to "Celine Dion", "爱如潮水" to "张信哲", "匆匆那年" to "王菲",
                "画心" to "张靓颖", "默" to "那英", "传奇" to "李健", "贝加尔湖畔" to "李健",
                "卷珠帘" to "霍尊", "不将就" to "李荣浩", "说散就散" to "袁娅维", "卡路里" to "火箭少女101",
                "追光者" to "岑宁儿", "我们" to "陈奕迅", "终于等到你" to "张靓颖", "当爱已成往事" to "张国荣",
                "滚滚红尘" to "陈淑桦", "甜蜜蜜" to "邓丽君", "新不了情" to "万芳", "星语心愿" to "张柏芝",
                "我愿意" to "王菲", "人间" to "王菲", "萱草花" to "张小斐", "这世界那么多人" to "莫文蔚"
            ),
            "欧美热单" to listOf(
                "Shape of You" to "Ed Sheeran", "Perfect" to "Ed Sheeran", "Thinking Out Loud" to "Ed Sheeran",
                "Photograph" to "Ed Sheeran", "See You Again" to "Wiz Khalifa", "Let It Go" to "Idina Menzel",
                "Hello" to "Adele", "Someone Like You" to "Adele", "Rolling in the Deep" to "Adele",
                "Counting Stars" to "OneRepublic", "Secrets" to "OneRepublic", "Sugar" to "Maroon 5",
                "Memories" to "Maroon 5", "Payphone" to "Maroon 5", "Faded" to "Alan Walker",
                "Alone" to "Alan Walker", "Havana" to "Camila Cabello", "Señorita" to "Camila Cabello  Shawn Mendes",
                "Bad Guy" to "Billie Eilish", "Happier" to "Marshmello", "Thunder" to "Imagine Dragons",
                "Believer" to "Imagine Dragons", "Numb" to "Linkin Park", "In the End" to "Linkin Park",
                "Yellow" to "Coldplay", "Viva La Vida" to "Coldplay", "Uptown Funk" to "Bruno Mars",
                "Just the Way You Are" to "Bruno Mars", "Blinding Lights" to "The Weeknd", "Shallow" to "Lady Gaga  Bradley Cooper"
            )
        )

        /** 当天展示的 20 首：优先动态池（排除近 7 天已推 + 首见 3 天新歌优先 + 低频怀旧）；不足用种子池按日期滑窗补足 */
        fun forToday(): List<EditorPlaylist> {
            val day = (System.currentTimeMillis() / 86_400_000L).toInt()
            return POOLS.map { (title, pool) ->
                val dynamic = DynamicPool.categorySongs(title, day, 20)
                val today = if (dynamic.size >= 20) dynamic
                else {
                    val used = dynamic.map { it.first + it.second }.toSet()
                    val start = (day % pool.size).toInt()
                    val fill = (0 until pool.size).map { pool[(start + it) % pool.size] }
                        .filter { (it.first + it.second) !in used }
                        .take(20 - dynamic.size)
                    dynamic + fill
                }
                EditorPlaylist(title, posterOf(title), themeColorOf(title), today)
            }
        }

        /** 完整池（供猜你喜欢冷启动兜底取候选） */
        val ALL: List<EditorPlaylist> = POOLS.map { (title, pool) -> EditorPlaylist(title, posterOf(title), themeColorOf(title), pool) }
    }
}

// ===== 编辑精选卡（v2.1.59：撤掉 AI 水墨海报缩略图，改纸面文字卡）=====
// 原来每张卡是一幅 AI 生成的山水海报 + 右侧纸色渐变压字 + 类色描边：一屏 4 张 = 又一次"山水重复"，
// 而且海报里既没有歌单信息也没有真实封面，纯装饰。现在就是一张白卡：歌单名 + 首数 + 展开箭头。
@Composable
private fun EditorCard(pl: EditorPlaylist, onOpen: () -> Unit) {
    val p = LocalPalette.current
    Row(
        modifier = Modifier
            .width(150.dp)
            .height(66.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Color(0xFFFFFFFF))
            .border(1.dp, Color(0x1422201B), RoundedCornerShape(10.dp))
            .inkClickable { onOpen() },
        verticalAlignment = Alignment.CenterVertically
    ) {
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(pl.title, color = p.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, fontFamily = InkTitleFont, maxLines = 1)
            Spacer(Modifier.height(4.dp))
            Text(pl.count, color = p.text3, fontSize = 11.sp, maxLines = 1)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = p.text3,
            modifier = Modifier.size(18.dp)
        )
        Spacer(Modifier.width(12.dp))
    }
}

// ===== 热门音乐：与「猜你喜欢」同一套分页（每页 3 首 × 7 页 = 21 首）=====
// 取歌仍走动态词库（种子 24 + 每 3 天注入新歌手）按日期并发搜索，再按原版口径择优；
// v2.1.61：条数 20 → 21，正好 7 页 × 3 首。
private object HotMusic {
    val SEED_WORDS = listOf(
        "晴天 周杰伦", "孤勇者 陈奕迅", "七里香 周杰伦", "海阔天空 Beyond",
        "演员 薛之谦", "光年之外 邓紫棋", "夜曲 周杰伦", "平凡之路 朴树",
        "后来 刘若英", "成都 赵雷",
        // 2.0.0 扩充：更多风格/歌手/语种，支撑每日 20 首的多样性
        "江南 林俊杰", "红豆 王菲", "遇见 孙燕姿", "富士山下 陈奕迅",
        "千千阙歌 陈慧娴", "蓝莲花 许巍", "消愁 毛不易", "隐形的翅膀 张韶涵",
        "说谎 林宥嘉", "年少有为 李荣浩", "大鱼 周深", "漠河舞厅 柳爽",
        "万疆 李玉刚", "朋友 周华健"
    )

    /** 热门词库已知歌手集合（种子词指定歌手 + 风格白名单），用于识别“歌手-歌名/歌名-歌手”结构 */
    val KNOWN_SINGERS: Set<String> by lazy {
        (SEED_WORDS.mapNotNull { it.split(' ').lastOrNull()?.trim()?.ifEmpty { null } }.toSet() + SongProfile.STYLE.keys)
    }

    /** 核心歌名归一化：剥离括号版本、(DJ版/Live/伴奏/翻唱)等修饰后缀与“歌手-歌名”前缀，识别“同一首歌”的不同版本 */
    fun coreName(raw: String): String {
        var n = raw.trim()
        if (n.isEmpty()) return ""
        n = n.replace(Regex("[(（\\[【][^)）\\]】]*[)）\\]】]"), "")   // 去括号内容（含中英文括号）
        n = n.replace(Regex("\\s+"), " ")                              // 归一空白
        // 2.0.2：引号包裹歌名提取——「周杰伦“夜曲”hip-pop beat」取引号内原曲名「夜曲」，与原唱同核心名去重
        val quoted = Regex("[\"'“”‘’「」『』]([^\"'“”‘’「」『』]*)[\"'“”‘’「」『』]").find(n)
        if (quoted != null && quoted.groupValues[1].isNotBlank()) n = quoted.groupValues[1].trim()
        // 2.0.2：空格分隔“歌手 歌名”/“歌名 歌手”识别（已知歌手在首/尾则剥离，忽略大小写）
        KNOWN_SINGERS.firstOrNull { n.startsWith(it, ignoreCase = true) && n.length > it.length }
            ?.let { n = n.removePrefix(it).trim() }
        KNOWN_SINGERS.firstOrNull { n.endsWith(it, ignoreCase = true) && n.length > it.length }
            ?.let { n = n.removeSuffix(it).trim() }
        val dash = n.indexOf('-')
        if (dash > 0 && dash < n.length - 1) {                         // “歌手-歌名”或“歌名-歌手”
            val left = n.substring(0, dash).trim()
            val right = n.substring(dash + 1).trim()
            n = when {
                left in KNOWN_SINGERS -> right
                right in KNOWN_SINGERS -> left
                else -> n
            }
        }
        n = n.replace(Regex("(伴奏|钢琴版|吉他版|翻唱|Cover|Live|现场|Remix|DJ版|DJ|电音|串烧|合唱版|纯音乐|钢琴|混音|重制|LIVE|REMIX|COVER|beat|Beat|BEAT|hip-hop|hip-pop|HIP-HOP|HIP-POP|instrumental|Rap|rap|RAP|说唱|KTV|对唱|合唱|remix).*$"), "")
        // 2.0.2：剥后缀后清理尾部残留连接符（“七里香 - 纯音乐版”→“七里香”），避免与纯名版本重复上榜
        n = n.replace(Regex("\\s*[-—–·]\\s*$"), "")
        return n.trim()
    }

    /** 歌名“原版程度”评分：完全无修饰/短名优先（越高越接近原唱版本，同曲多版本择优） */
    fun plainScore(name: String): Int {
        val n = name.trim()
        var s = 0
        if (n == coreName(n)) s += 100
        if (!n.contains('(') && !n.contains('（')) s += 30
        if (!n.contains('-')) s += 10
        s -= n.length / 6
        return s
    }

    suspend fun load(limit: Int = 21): List<Song> = coroutineScope {
        val words = DynamicPool.wordsForToday(limit)
        // ① 逐词并行实时搜索（不同词=不同风格歌手）；结果回填「热门」动态池——池子持续增长（上限 2000、淘汰最旧）
        val perWord = words.map { w -> async {
            runCatching { SearchService.searchAll(w, 20) }.getOrNull()?.flatMap { it.songs } ?: emptyList()
        } }.awaitAll()
        val all = perWord.flatten().distinctBy { "${it.platform.name}_${it.platformID}" }
        DynamicPool.inject(all, "热门")
        DynamicPool.injectWords(all.map { it.singer })
        // 2.0.2：候选表只保留「原版」——Live/翻唱/DJ/伴奏/beat 等修饰名（name≠核心名）直接剔除；
        // 某曲搜不到原版时整曲跳过（用户确认：无原唱则弃曲），原唱优先由 plainScore 择优保证
        val available = LinkedHashMap<String, Song>()   // coreName → 最优原版
        all.forEach { s ->
            val key = coreName(s.name)
            if (key.isEmpty() || s.singer.isBlank()) return@forEach
            if (s.name.trim() != key) return@forEach          // 2.0.2：非原版不进入候选
            val prev = available[key]
            if (prev == null || plainScore(s.name) > plainScore(prev.name)) available[key] = s
        }

        val picked = mutableListOf<Song>()
        val seen = mutableSetOf<String>()
        val singerCount = mutableMapOf<String, Int>()
        // 2.0.2：主歌手归一（「陈奕迅/华语群星」按「陈奕迅」计；已知歌手按白名单名匹配），同歌手≤2 与相邻判定用归一结果
        fun singerKey(s: Song): String {
            val s0 = s.singer.split('/', '、', '&', '，', ';').firstOrNull()?.trim()?.ifEmpty { null } ?: s.singer
            return KNOWN_SINGERS.firstOrNull { s0.contains(it) } ?: s0
        }
        // 统一挑选：核心歌名去重（同曲只留 1 首）+ 同歌手最多 2 首 + 2.0.2 相邻歌手不挨着（blockAdjacent 时）
        fun tryPick(s: Song, blockAdjacent: Boolean): Boolean {
            val key = coreName(s.name)
            if (key.isEmpty() || s.singer.isBlank()) return false
            if (!seen.add(key)) return false
            val sk = singerKey(s)
            if (singerCount.getOrDefault(sk, 0) >= 2) return false
            if (blockAdjacent && picked.isNotEmpty() && singerKey(picked.last()) == sk) return false
            picked.add(s); singerCount[sk] = singerCount.getOrDefault(sk, 0) + 1
            return true
        }

        // ② 动态池给出期望顺序（新歌优先 + 久未展示低频怀旧，已排除近 7 天），映射回本次真实原版 Song
        val poolOrder = DynamicPool.categorySongs("热门", HomeCache.today, limit * 2)
        // 各词搜索结果排名（2.0.2：所有挑选统一映射到该核心歌名的原版，不再直接取原始第 1 名）
        val rankedPerWord = words.indices.map { i ->
            SearchRanker.rank(words[i], perWord[i].distinctBy { "${it.platform.name}_${it.platformID}" })
        }
        // 第一遍：优先不挨着（同歌手相邻拒收，同一歌手不同歌曲至少隔一位）
        for ((n, _) in poolOrder) {
            if (picked.size >= limit) break
            available[coreName(n)]?.let { tryPick(it, blockAdjacent = true) }
        }
        rankedPerWord.forEach { ranked ->
            if (picked.size >= limit) return@forEach
            ranked.firstOrNull { r -> available[coreName(r.name)]?.let { tryPick(it, blockAdjacent = true) } == true }
        }
        // 仍不足：按各词排名第 2、3… 名映射原版补位
        var cursor = 1
        while (picked.size < limit && cursor < 30) {
            rankedPerWord.forEach { ranked ->
                if (picked.size >= limit) return@forEach
                if (ranked.size > cursor) {
                    val cand = ranked[cursor].let { r -> available[coreName(r.name)] }
                    if (cand != null) tryPick(cand, blockAdjacent = true)
                }
            }
            cursor++
        }
        // 第二遍：仍不足 → 允许相邻兜底凑满（用户确认：轮空时允许相邻），严格保证 21 首填满（7 页 × 3 首）
        if (picked.size < limit) {
            val cands = poolOrder.mapNotNull { (n, _) -> available[coreName(n)] } +
                rankedPerWord.flatten().mapNotNull { r -> available[coreName(r.name)] }
            for (c in cands) {
                if (picked.size >= limit) break
                tryPick(c, blockAdjacent = false)
            }
        }
        picked
    }
}

// ===== 歌曲特征画像：歌手风格标签 + 歌名词元(bigram) + 语种，稀疏向量 + 余弦相似度 =====
private object SongProfile {
    // 歌手 → 风格标签（内置小型映射；未收录歌手用语种标签兜底）
    val STYLE: Map<String, Set<String>> = mapOf(
        "周杰伦" to setOf("华语流行", "R&B", "中国风"),
        "薛之谦" to setOf("华语流行", "情歌"),
        "刘若英" to setOf("华语流行", "情歌"),
        "赵雷" to setOf("民谣"),
        "邓紫棋" to setOf("华语流行", "摇滚"),
        "田馥甄" to setOf("华语流行", "情歌"),
        "朴树" to setOf("民谣", "摇滚"),
        "林俊杰" to setOf("华语流行"),
        "光良" to setOf("华语流行", "情歌"),
        "张韶涵" to setOf("华语流行"),
        "梁静茹" to setOf("华语流行", "情歌"),
        "张惠妹" to setOf("华语流行"),
        "王菲" to setOf("华语流行", "粤语流行", "影视OST"),
        "陈奕迅" to setOf("华语流行", "粤语流行", "情歌"),
        "李荣浩" to setOf("华语流行"),
        "毛不易" to setOf("民谣", "华语流行"),
        "孙燕姿" to setOf("华语流行"),
        "莫文蔚" to setOf("华语流行"),
        "Beyond" to setOf("粤语摇滚", "摇滚"),
        "李克勤" to setOf("粤语流行"),
        "陈慧娴" to setOf("粤语流行"),
        "杨千嬅" to setOf("粤语流行"),
        "张学友" to setOf("粤语流行", "华语流行"),
        "卢冠廷" to setOf("粤语流行", "影视OST"),
        "叶丽仪" to setOf("粤语流行"),
        "汪明荃" to setOf("粤语流行"),
        "许冠杰" to setOf("粤语流行"),
        "张国荣" to setOf("粤语流行", "影视OST"),
        "于文文" to setOf("华语流行", "影视OST"),
        "张碧晨" to setOf("华语流行", "影视OST"),
        "周深" to setOf("华语流行", "影视OST"),
        "张杰" to setOf("华语流行", "影视OST"),
        "张信哲" to setOf("情歌", "华语流行"),
        "张靓颖" to setOf("华语流行", "影视OST"),
        "那英" to setOf("华语流行", "影视OST"),
        "李健" to setOf("民谣", "影视OST"),
        "霍尊" to setOf("国风"),
        "袁娅维" to setOf("R&B", "影视OST"),
        "火箭少女101" to setOf("华语流行"),
        "岑宁儿" to setOf("影视OST", "华语流行"),
        "陈淑桦" to setOf("华语流行"),
        "邓丽君" to setOf("华语流行", "粤语流行"),
        "万芳" to setOf("华语流行"),
        "张柏芝" to setOf("华语流行", "影视OST"),
        "张小斐" to setOf("影视OST"),
        "杨宗纬" to setOf("华语流行"),
        "Ed Sheeran" to setOf("欧美流行"),
        "Wiz Khalifa" to setOf("欧美说唱"),
        "Idina Menzel" to setOf("音乐剧", "欧美"),
        "Adele" to setOf("欧美流行", "灵魂乐"),
        "OneRepublic" to setOf("欧美流行", "摇滚"),
        "Maroon 5" to setOf("欧美流行"),
        "Alan Walker" to setOf("电音"),
        "Camila Cabello" to setOf("欧美流行", "拉丁"),
        "Shawn Mendes" to setOf("欧美流行"),
        "Billie Eilish" to setOf("欧美流行"),
        "Marshmello" to setOf("电音"),
        "Imagine Dragons" to setOf("摇滚", "欧美"),
        "Linkin Park" to setOf("摇滚", "欧美"),
        "Coldplay" to setOf("英伦摇滚", "欧美"),
        "Bruno Mars" to setOf("欧美流行", "放克"),
        "The Weeknd" to setOf("R&B", "欧美"),
        "Lady Gaga" to setOf("欧美流行")
    )

    /** 语种标签：歌手名含拉丁字母或歌名为全拉丁 → 欧美，否则华语（粤语由歌手标签补充） */
    private fun langTag(name: String, singer: String): String =
        if (singer.any { it in 'A'..'z' } || name.all { it == ' ' || it in 'A'..'z' || it in '0'..'9' || "!&'-.,".contains(it) }) "欧美" else "华语"

    /** 歌曲特征词项：歌手 + 风格标签 + 语种 + 歌名相邻字 bigram */
    fun features(song: Song): Map<String, Double> {
        val f = mutableMapOf<String, Double>()
        f["singer:" + song.singer] = 2.0
        f["lang:" + langTag(song.name, song.singer)] = 1.0
        STYLE[song.singer]?.forEach { f["tag:$it"] = 1.5 }
        val n = song.name.trim()
        if (n.isNotEmpty()) for (i in 0 until n.length - 1) f["ng:${n.substring(i, i + 2)}"] = 1.0
        return f
    }

    /** 稀疏向量余弦相似度 */
    fun cosine(a: Map<String, Double>, b: Map<String, Double>): Double {
        if (a.isEmpty() || b.isEmpty()) return 0.0
        var dot = 0.0
        val (small, large) = if (a.size <= b.size) a to b else b to a
        small.forEach { (k, v) -> large[k]?.let { dot += v * it } }
        val na = Math.sqrt(a.values.sumOf { it * it })
        val nb = Math.sqrt(b.values.sumOf { it * it })
        return if (na == 0.0 || nb == 0.0) 0.0 else dot / (na * nb)
    }
}

// ===== 猜你喜欢：内容推荐（歌曲特征向量+余弦相似度）混合行为信号（播放/收藏/搜索）+ 平台序，加权排序 + 多样性去重 =====
object GuessEngine {
    data class GuessItem(val song: Song, val reason: String)

    private const val W_CONTENT = 0.5   // 内容相似度权重
    private const val W_BEHAVIOR = 0.3  // 行为信号权重
    private const val W_BASE = 0.2      // 平台搜索序权重

    /** 冷启动补歌：用歌名+歌手搜索取真实可播音源（点播不失败） */
    private suspend fun searchBackup(name: String, singer: String): Song? {
        // v2.1.30：limit 10→30 —— 原版条目常被 Live/翻唱挤出前 10，取不到就只能回落节目版
        val r = runCatching { SearchService.searchAll("$name $singer", 30) }.getOrNull() ?: return null
        val all = r.flatMap { it.songs }.distinctBy { "${it.platform.name}_${it.platformID}" }
        val ranked = SearchRanker.rank("$name $singer", all)
        val hits = ranked.filter {
            it.name.contains(name, ignoreCase = true) || name.contains(it.name, ignoreCase = true)
        }
        // v2.1.30：同名多版本（Live/伴奏/节目消音版）时取最接近录音棚原唱的一条
        return StudioPick.pickBest(hits)
    }

    suspend fun recommend(
        recents: List<Song>,
        searches: List<SearchHistoryItem>,
        favs: List<Song>,
        downloads: List<Song>,
        max: Int = 6,
        includeExpansion: Boolean = true
    ): List<GuessItem> {
        if (recents.isEmpty() && searches.isEmpty() && favs.isEmpty() && downloads.isEmpty()) return emptyList()

        // ① 用户兴趣向量：播放特征 ×1、收藏 ×2、下载 ×1.5、搜索关键词 ×1.5 累加
        val userVec = mutableMapOf<String, Double>()
        recents.forEach { s -> SongProfile.features(s).forEach { (k, v) -> userVec[k] = (userVec[k] ?: 0.0) + v } }
        favs.forEach { s -> SongProfile.features(s).forEach { (k, v) -> userVec[k] = (userVec[k] ?: 0.0) + v * 2.0 } }
        downloads.forEach { s -> SongProfile.features(s).forEach { (k, v) -> userVec[k] = (userVec[k] ?: 0.0) + v * 1.5 } }
        searches.take(5).forEach { kw -> userVec["ng:$kw"] = (userVec["ng:$kw"] ?: 0.0) + 1.5 }

        val topSingers = recents.groupingBy { it.singer }.eachCount().entries.sortedByDescending { it.value }.take(3).map { it.key }
        val favSingers = favs.map { it.singer }.toSet()
        val downloadSingers = downloads.map { it.singer }.toSet()
        val searchKeywords = searches.take(5).map { it.keyword }

        // ② 生成查询：top 歌手 + 下载歌手 + 搜索关键词 + 热门扩展
        val queries = buildList {
            topSingers.forEach { add(it) }
            downloadSingers.firstOrNull()?.let { add(it) }
            searchKeywords.take(2).forEach { add(it) }
            topSingers.firstOrNull()?.let { add("$it 热门") }
        }.distinct().take(4)

        // ③ 候选池：并发搜索合并去重，并过滤掉动态池近 7 天已推荐过的（三重控制①：近期不重复）
        val pool = mutableListOf<Song>()
        queries.forEach { q -> runCatching { SearchService.searchAll(q, 30) }.getOrNull()?.forEach { pr -> pool += pr.songs } }
        val shown = DynamicPool.recentShown(HomeCache.today, 7)
        val merged = pool.distinctBy { "${it.platform.name}_${it.platformID}" }
            .filterNot { s -> shown.contains(if (s.platformID.isNotBlank()) "${s.platform.name}_${s.platformID}" else "seed_${s.name}|${s.singer}") }
        if (merged.isEmpty()) return emptyList()

        // v2.1.30：同一首歌只保留「最接近录音棚原唱」的一条。
        // 此前节目消音版与录音室原唱同时入池（歌名都叫《龙文》），滚动一次就可能抽到带掌声的版本。
        val studioPool = StudioPick.dedupeByCore(merged)
        if (studioPool.isEmpty()) return emptyList()

        // ④ 混合打分：content（余弦相似度×100）×0.5 + behavior（命中信号）×0.3 + base（平台序）×0.2
        val ranked = SearchRanker.rank(queries.firstOrNull() ?: "", studioPool)
        val scored = ranked.mapIndexed { idx, song ->
            val content = SongProfile.cosine(userVec, SongProfile.features(song)) * 100
            var behavior = 0.0
            val reason: String
            if (song.singer in topSingers) {
                behavior += 100
                reason = "因为你在听 ${song.singer}"
            } else if (favSingers.contains(song.singer)) {
                behavior += 80
                reason = "你收藏了 ${song.singer} 的歌"
            } else if (downloadSingers.contains(song.singer)) {
                behavior += 80
                reason = "你下载过 ${song.singer} 的歌"
            } else {
                val kw = searchKeywords.firstOrNull { song.name.contains(it, ignoreCase = true) || song.singer.contains(it, ignoreCase = true) }
                if (kw != null) {
                    behavior += 60
                    reason = "搜过「$kw」"
                } else {
                    val tags = SongProfile.STYLE[song.singer]
                    reason = if (tags != null) "与你喜欢的「${tags.first()}」相关" else "为你精选"
                }
            }
            val base = maxOf(0, 60 - idx * 6)
            val final = W_CONTENT * content + W_BEHAVIOR * behavior + W_BASE * base
            GuessItem(song, reason) to final
        }

        // ⑤ 多样性：同歌手最多 2 首、与已选歌特征相似度 >0.9 跳过
        val picked = mutableListOf<Pair<GuessItem, Double>>()
        val singerCount = mutableMapOf<String, Int>()
        for (pair in scored.sortedByDescending { it.second }) {
            if (picked.size >= max) break
            val s = pair.first.song
            if (singerCount.getOrDefault(s.singer, 0) >= 2) continue
            if (picked.any { p -> SongProfile.cosine(SongProfile.features(p.first.song), SongProfile.features(s)) > 0.9 }) continue
            singerCount[s.singer] = singerCount.getOrDefault(s.singer, 0) + 1
            picked += pair
        }

        // ⑥⑦ 探索位 + 编辑池补歌：v1.9.6 抽成 expand()，主推荐先出、扩展后台补
        return if (includeExpansion) expand(picked.map { it.first }, max) else picked.map { it.first }
    }

    /** 探索位（20% 新歌）+ 编辑池补歌（数量硬保证）：用于后台补齐，不阻塞首屏 */
    suspend fun expand(base: List<GuessItem>, max: Int): List<GuessItem> {
        val result = base.toMutableList()
        val used = result.map { it.song.name + it.song.singer }.toMutableSet()
        // ⑥ 探索位（20%）：从动态池"从未推荐过"的新歌真实搜索填充，让用户听到从没见过的歌
        if (result.size < max) {
            val explore = DynamicPool.explorationKeys(HomeCache.today, maxOf(1, max / 5))
            for ((n, s) in explore) {
                if (result.size >= max) break
                if (used.contains(n + s)) continue
                val real = searchBackup(n, s) ?: continue
                result += GuessItem(real, "为你探索")
                used += n + s
            }
        }
        // ⑦ 数量硬保证：仍不足 max 时用编辑精选池真实搜索补歌（保证可翻页）
        if (result.size < max) {
            for (pl in EditorPlaylist.ALL) {
                for ((n, s) in pl.songs) {
                    if (result.size >= max) break
                    if ((n + s) in used) continue
                    val real = searchBackup(n, s) ?: continue
                    result += GuessItem(real, "为你精选")
                    used += n + s
                }
            }
        }
        return result
    }
}

// ===== 深色歌曲行：封面 + 歌名/歌手 + 平台 + 时长 + 收藏爱心 =====
@Composable
fun DarkSongRow(
    song: Song,
    queue: List<Song>? = null,
    showPlatform: Boolean = true,
    showDuration: Boolean = true,
    // v2.1.10：搜索结果条目启用跨平台换源——本平台取流失败时自动用妖狐酷我按歌名+歌手补搜兜底，直到成功
    allowCrossRetry: Boolean = false
) {
    val p = LocalPalette.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .inkClickable {
                // 打开播放页；若内部异常则 toast 显示原因（诊断），不静默失败
                val r = runCatching { AppState.openSong(song, queue, allowCrossRetry) }
                if (r.isFailure) toast("打开失败：" + (r.exceptionOrNull()?.message ?: "未知异常"))
            }
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SongCover(song = song, size = 48.dp, corner = 8.dp)
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(song.name, color = p.text, fontSize = 15.sp, fontWeight = FontWeight.Medium, fontFamily = InkTitleFont, maxLines = 1)
            Spacer(Modifier.height(2.dp))
            Text(
                song.singer + (if (song.album.isNotBlank()) " · " + song.album else ""),
                color = p.text2,   // v2.1.13：歌手行 text3→text2 提亮，从 12sp 升 13sp；v2.1.14：加纸色描边与水墨背景分离
                fontSize = 13.sp,
                maxLines = 1,
                style = TextStyle(shadow = Shadow(Color(0xFFF7F5F0).copy(alpha = 0.85f), Offset(0f, 1f), 3f))
            )
        }
        // v2.1.95：时长与平台标签都定宽、各自居中/右对齐。
        // 之前两者宽度随内容变（04:23 / --:-- / QQ / 网易），红心和标签的横向位置每行都不一样。
        if (showDuration) {
            Text(
                song.durationText,
                color = p.text3,
                fontSize = 11.sp,
                modifier = Modifier.width(42.dp),
                textAlign = TextAlign.End,
                maxLines = 1
            )
            Spacer(Modifier.width(8.dp))
        }
        FavoriteBtn(song = song)
        if (showPlatform) {
            Spacer(Modifier.width(8.dp))
            Text(
                song.platform.shortName,
                color = p.accent2,
                fontSize = 10.sp,
                textAlign = TextAlign.Center,
                maxLines = 1,
                modifier = Modifier
                    .width(44.dp)
                    .background(p.accent.copy(alpha = 0.14f), RoundedCornerShape(50))
                    .padding(vertical = 2.dp)
            )
        }
    }
}

// ===== 收藏爱心按钮（实心=已收藏，点击切换带动画；直接读响应式事实源，与播放页/悬浮栏全联动）=====
@Composable
fun FavoriteBtn(song: Song, size: androidx.compose.ui.unit.Dp = 24.dp) {
    val p = LocalPalette.current
    val fav = HistoryStore.isFavorite(song)
    Box(
        modifier = Modifier
            .size(size + 16.dp)
            // v2.1.39 评估后维持原样：外壳不加按压——内层 InkHeart 的 1.22 弹跳已是反馈，
            // 外壳再 0.93 会让"外壳缩、心放大"两个变换叠加打架（与"列表行不叠第二层按压"同一道理）
            .clickable {
                HistoryStore.toggleFavorite(song)
            }
            .padding((size + 16.dp) / 2 - size / 2),
        contentAlignment = Alignment.Center
    ) {
        // v2.1.38：空心↔实心由 InkHeart 做「溶形 + 弹出」，不再硬替换图标资源
        InkHeart(
            fav = fav,
            size = size,
            tintOn = p.heartOn,
            tintOff = p.text3
        )
    }
}

// ===== 空态提示 =====
@Composable
fun EmptyHint(title: String, subtitle: String) {
    val p = LocalPalette.current
    // v2.1.38：空态不再生硬贴上——整体自 94% 轻放 + 淡入（罕见场景，允许一点愉悦感；
    // 不复用循环动画，出现一次就停）
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }
    AnimatedVisibility(
        visible = appeared,
        enter = fadeIn(tween(240)) + scaleIn(initialScale = 0.94f, animationSpec = tween(260, easing = StrongEaseOut)),
        modifier = Modifier.fillMaxSize()
    ) {
        Column(
            modifier = Modifier.fillMaxSize().padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Icon(Icons.Filled.MusicNote, contentDescription = null, modifier = Modifier.size(56.dp), tint = p.text3.copy(alpha = 0.5f))
            Spacer(Modifier.height(12.dp))
            Text(title, color = p.text2, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(4.dp))
            Text(subtitle, color = p.text3, fontSize = 12.sp)
        }
    }
}

// ===== 编辑精选歌单页：本地内置歌曲秒开，点单曲才搜索播放 =====
@Composable
fun PlaylistScreen(pl: EditorPlaylist, onBack: () -> Unit) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    var loadingName by remember { mutableStateOf<String?>(null) }

    // ① 修复：歌单页是覆盖层（盖在 MainScaffold 之上），自身无系统栏内边距导致标题顶格；
    // 加 statusBarsPadding 让标题落到状态栏下方（各机型自适应），顶部自然留白
    Column(modifier = Modifier.fillMaxSize().statusBarsPadding().background(p.surface)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 8.dp, top = 8.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    // v2.1.40：歌单页返回钮是最后一处没统一的——补上墨色按压，六处返回钮手感一致
                    .inkClickable { onBack() },
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回", tint = p.text2, modifier = Modifier.size(22.dp))
            }
            Column(modifier = Modifier.padding(start = 4.dp)) {
                Text(pl.title, fontSize = 22.sp, fontFamily = InkTitleFont, color = p.text)
                Text("今日精选 ${pl.songs.size} 首 · 点单曲播放", fontSize = 12.sp, color = p.text3)
            }
        }
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            // 2.0.3：底部留白 128→60dp（与首页一致）——128dp 过大导致最后一条与播放悬浮栏间出现大段空隙
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 60.dp)
        ) {
            items(pl.songs.withIndex().toList(), key = { it.index }) { (idx, pair) ->
                val (name, singer) = pair
                val loading = loadingName == name
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        // v2.1.40：歌单行原本点了毫无反馈——补墨色按压；行内没有第二个可点元素，不涉及叠层
                        .inkClickable(enabled = !loading) {
                            loadingName = name
                            scope.launch {
                                try {
                                    val results = SearchService.searchAll("$name $singer", 30)
                                    val pool = results.flatMap { it.songs }.distinctBy { "${it.platform.name}_${it.platformID}" }
                                    val ranked = SearchRanker.rank("$name $singer", pool)
                                    // v2.1.30：同名多版本（Live/伴奏/节目消音版）时取录音棚原唱
                                    val hits = ranked.filter {
                                        it.name.contains(name, ignoreCase = true) || name.contains(it.name, ignoreCase = true)
                                    }
                                    val first = StudioPick.pickBest(hits) ?: ranked.firstOrNull()
                                    if (first != null) {
                                        val clicked = first
                                        // ① 秒播当前歌最佳版本（打开播放页/悬浮条）
                                        //    v2.1.30：队列先落单曲，保证 playlist 非空（此前传 null 时若 playlist 为空，
                                        //    悬浮栏左右切歌会直接 return，点上去毫无反应）
                                        AppState.openSong(clicked, listOf(clicked))
                                        // ② 后台并发补齐歌单其余歌曲，构成「歌单顺序队列」；
                                        //    列表循环严格按歌单下一首切（替换原「搜索候选排名」队列）
                                        scope.launch {
                                            // v2.1.30：先抢「下一首」占位，2 首队列立即可用，切歌不再等全量补齐
                                            val nIdx = if (pl.songs.size > 1) (idx + 1) % pl.songs.size else idx
                                            val (nName, nSinger) = pl.songs[nIdx]
                                            if (nIdx != idx) {
                                                val neighbor = runCatching {
                                                    val r = SearchService.searchAll("$nName $nSinger", 30)
                                                    val pp = r.flatMap { it.songs }.distinctBy { "${it.platform.name}_${it.platformID}" }
                                                    val rk = SearchRanker.rank("$nName $nSinger", pp)
                                                    StudioPick.pickBest(rk.filter {
                                                        it.name.contains(nName, ignoreCase = true) || nName.contains(it.name, ignoreCase = true)
                                                    })
                                                }.getOrNull()
                                                if (neighbor != null && (neighbor.platform != clicked.platform || neighbor.platformID != clicked.platformID)) {
                                                    AppState.replaceQueue(listOf(clicked, neighbor), 0)
                                                }
                                            }
                                            val tasks = pl.songs.mapIndexed { i, (n, s) ->
                                                i to async {
                                                    if (i == idx) clicked
                                                    else runCatching {
                                                        val r = SearchService.searchAll("$n $s", 30)
                                                        val pp = r.flatMap { it.songs }.distinctBy { "${it.platform.name}_${it.platformID}" }
                                                        val rk = SearchRanker.rank("$n $s", pp)
                                                        StudioPick.pickBest(rk.filter {
                                                            it.name.contains(n, ignoreCase = true) || n.contains(it.name, ignoreCase = true)
                                                        })
                                                    }.getOrNull()
                                                }
                                            }
                                            val bestByIndex = tasks.map { (i, d) -> i to (runCatching { d.await() }.getOrNull()) }.toMap()
                                            val ordered = pl.songs.indices.mapNotNull { i -> bestByIndex[i] }
                                            if (ordered.isNotEmpty()) {
                                                val playIdx = ordered.indexOfFirst { it.platform == first.platform && it.platformID == first.platformID }
                                                AppState.replaceQueue(ordered, if (playIdx >= 0) playIdx else 0)
                                            }
                                        }
                                    } else {
                                        toast("未找到可播放版本")
                                    }
                                } catch (e: Exception) {
                                    toast("搜索失败：" + (e.message ?: "未知异常"))
                                } finally {
                                    loadingName = null
                                }
                            }
                        }
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("%02d".format(idx + 1), color = p.text3, fontSize = 13.sp, modifier = Modifier.width(28.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(name, color = p.text, fontSize = 15.sp, fontWeight = FontWeight.Medium, fontFamily = InkTitleFont, maxLines = 1)
                        Spacer(Modifier.height(2.dp))
                        Text(singer, color = p.text3, fontSize = 12.sp, maxLines = 1)
                    }
                    if (loading) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), color = p.accent, strokeWidth = 2.dp)
                    } else {
                        Icon(Icons.Filled.PlayArrow, contentDescription = "播放", tint = p.accent2, modifier = Modifier.size(22.dp))
                    }
                }
            }
            item { Spacer(Modifier.height(16.dp)) }
        }
    }
}

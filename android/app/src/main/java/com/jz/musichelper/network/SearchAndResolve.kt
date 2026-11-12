package com.jz.musichelper.network

import com.jz.musichelper.model.MusicPlatform
import com.jz.musichelper.model.QualityLevel
import com.jz.musichelper.model.Song
import com.jz.musichelper.model.StreamSource
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull

// 并发搜索服务：所有平台同时搜，先返回的先进结果列表；单平台超时/失败自动忽略
// 硬约束：任何单个平台的任何异常都不得外抛（否则整个 App 崩溃），就地转为失败结果
object SearchService {

    private val adapters: List<SearchAdapter> = listOf(
        QQSearchAdapter(),
        NeteaseSearchAdapter(),
        KuwoSearchAdapter()
        // v2.1.9：废弃酷狗——取流后端从未实现（SourceRegistry 无酷狗适配器，跨平台兜底为空），
        // 官方三接口匿名全被风控（wwwapi 30020 / mobilecdn Access Deny / m.kugou url 为空），
        // 第三方通道（妖狐/gdstudio/oiapi/V7）实测全不可用，修取流无现成实现，按用户拍板废弃
    )

    private const val PER_SOURCE_TIMEOUT_MS = 8_000L   // v2.1.9：6s→8s，酷我慢网/大响应（rn=20≈45KB）更稳

    /** v2.1.88：当前真正参与并发搜索的平台——UI 的平台行与"N 平台并发"文案都读这里，不再写死 */
    val platforms: List<MusicPlatform> get() = adapters.map { it.platform }

    // 每个平台的搜索结果（保持平台维度）
    data class PlatformResult(val platform: MusicPlatform, val songs: List<Song>, val error: String?)

    /** 并发搜索全部平台，等待所有完成（每个平台独立超时；单平台失败只标记 error，不抛出） */
    suspend fun searchAll(keyword: String, limit: Int = 20): List<PlatformResult> = coroutineScope {
        adapters.map { adapter ->
            async {
                try {
                    val result = withTimeoutOrNull(PER_SOURCE_TIMEOUT_MS) {
                        adapter.search(keyword, limit)
                    }
                    if (result != null) {
                        PlatformResult(adapter.platform, result, null)
                    } else {
                        PlatformResult(adapter.platform, emptyList(), "超时")
                    }
                } catch (e: Exception) {
                    // 捕获一切异常（含取消副作用 / SSL / 解析失败），转为该平台失败，绝不外抛
                    PlatformResult(adapter.platform, emptyList(), e.message ?: "失败")
                }
            }
        }.awaitAll()
    }
}

// 并发取流解析：一首歌同时尝试所有可用后端，收集全部成功结果
// 硬约束：单个后端失败只计入 failed，不外抛
object UrlResolver {

    private const val PER_BACKEND_TIMEOUT_MS = 12_000L

    data class ResolveResult(val sources: List<StreamSource>, val failed: Map<String, String>)

    suspend fun resolveAll(song: Song, quality: QualityLevel): ResolveResult = coroutineScope {
        val adapters = SourceRegistry.adaptersFor(song)
        val sources = mutableListOf<StreamSource>()
        val failed = mutableMapOf<String, String>()

        adapters.map { adapter ->
            async {
                val r = try {
                    withTimeoutOrNull(PER_BACKEND_TIMEOUT_MS) {
                        adapter.resolve(song, quality)
                    }
                } catch (e: Exception) {
                    null
                }
                adapter.name to r
            }
        }.awaitAll().forEach { (name, src) ->
            if (src != null) sources.add(src) else failed[name] = "失败或超时"
        }
        ResolveResult(sources, failed)
    }
}

// 按用户所选音质从多个可用源中挑选最匹配的一个（防“选无损却拿到 128k m4a”）
// 评分：无损优先 flac/ape/wav 真无损 → 标注无损 → 高品 → 标准；m4a 一律最低优先级
object SourcePicker {
    fun pick(sources: List<StreamSource>, want: QualityLevel): StreamSource? {
        if (sources.isEmpty()) return null
        // v2.1.4：同档分数下优先"按平台 ID 直连"的后端（身份可靠），搜索式取流后置——
        // 避免 HIGH 档 320k 标注的搜索式 mp3 压过同平台 QQ m4a 直链（"夜曲"曾因此播到伴奏）
        return sources.maxWithOrNull(
            compareBy<StreamSource> { score(it, want) }
                .thenByDescending { if (it.directId) 1 else 0 }
        )
    }

    internal fun score(src: StreamSource, want: QualityLevel): Int {
        val isLosslessFmt = src.format.contains("flac") || src.format.contains("ape") || src.format.contains("wav")
        return when (want) {
            QualityLevel.LOSSLESS -> when {
                src.quality == QualityLevel.LOSSLESS && isLosslessFmt -> 5
                src.quality == QualityLevel.LOSSLESS -> 4
                src.quality == QualityLevel.HIGH -> 2
                src.quality == QualityLevel.STANDARD -> 1
                else -> 0
            }
            QualityLevel.HIGH -> when {
                src.quality == QualityLevel.HIGH && !src.format.contains("m4a") -> 4
                src.quality == QualityLevel.HIGH -> 3
                src.quality == QualityLevel.LOSSLESS -> 3
                src.quality == QualityLevel.STANDARD -> 1
                else -> 0
            }
            QualityLevel.STANDARD -> if (src.quality == QualityLevel.STANDARD) 2 else 1
        } - if (src.directId) 0 else 1
    }
}

/**
 * v2.1.29：同曲跨平台补源——猜你喜欢/热门/自动连播与搜索共用同一套解析逻辑。
 * 背景：猜你喜欢只带"来源平台"的 ID，UrlResolver 默认只问本平台后端（SourceRegistry 的 cross 恒为空），
 * 本平台后端一挂就判无源并跳过；而同一首歌在其它平台的条目（搜索里能秒解析的那条）从未被尝试。
 * 做法：按"歌名+歌手"调用与搜索完全相同的 SearchService.searchAll（同适配器、同超时、同过滤），
 * 取出所有平台中"同歌手 / 同歌曲"的候选，逐个用候选自己平台的后端解析；
 * 只有全部候选都解析失败才返回 null —— 由调用方（AppState）决定是否跳过，
 * 从而保证"明明能解析的歌绝不被跳过"。
 */
object SameSongCrossResolver {

    private const val MAX_CANDIDATES = 8          // 单轮最多试 8 条同曲候选，避免长尾拖死队列
    private const val MAX_EXACT_KEEP = 3          // v2.1.64：目标档最多留 3 条备选（首条体积不合规时还能接着换）
    private const val TOTAL_TIMEOUT_MS = 40_000L  // 整轮补源硬超时（搜索 8s + 候选逐个 12s）
    private const val MAX_DURATION_DIFF_SEC = 12  // 双方都有时长时，差 >12s 视为不同版本（live/remix/伴奏）
    private const val STRICT_DURATION_DIFF_SEC = 3 // v2.1.48：原唱换到 live/节目变体时的严阈值（差 >3s 一律否决）

    /**
     * @param triedKeys 已尝试过的候选 key 集合（跨轮次复用，避免重复打同一批候选）
     * @return 可用音源；所有同曲候选都失败时返回 null
     */
    suspend fun resolve(
        song: Song,
        quality: QualityLevel,
        triedKeys: MutableSet<String>
    ): StreamSource? = withTimeoutOrNull(TOTAL_TIMEOUT_MS) {
        val kw = (song.name + " " + song.singer).trim()
        if (kw.isBlank()) return@withTimeoutOrNull null
        val results = runCatching { SearchService.searchAll(kw, 30) }.getOrNull()
            ?: return@withTimeoutOrNull null
        val cands = results.asSequence()
            .flatMap { it.songs.asSequence() }
            .filter { sameSong(song, it) }
            .filter { candKey(it) !in triedKeys }
            // v2.1.30：同平台取流更稳优先；同平台内再按「录音棚原唱」得分排——
            // 避免先试到同平台的 (Live)/节目版，白跑一轮后端
            .sortedWith(
                compareBy<Song> { if (it.platform == song.platform) 0 else 1 }
                    .thenByDescending { StudioPick.studioScore(it) }
            )
            .distinctBy { candKey(it) }
            .take(MAX_CANDIDATES)
            .toList()
        for (c in cands) {
            triedKeys.add(candKey(c))
        }
        // 候选分批（每批 3 条）并发解析：单批约 1 个后端超时（12s）即可出结果，避免 8 条串行拖到分钟级
        var picked: StreamSource? = null
        for (batch in cands.chunked(3)) {
            if (picked != null) break
            coroutineScope {
                val got = batch.map { c ->
                    async {
                        val r = runCatching { UrlResolver.resolveAll(c, quality) }.getOrNull()
                        if (r != null) SourcePicker.pick(r.sources, quality) else null
                    }
                }.awaitAll()
                picked = got.firstOrNull { it != null }
            }
        }
        picked
    }

    /**
     * 跨源补源的产出：exacts=所有正好是目标档的源（v2.1.64 起收多条，前一条下载后被体积校验判不合规时还能换下一条）；
     * best=能拿到的最高档（降级兜底用）。exact 保留为"第一条目标档"，兼容旧调用。
     */
    data class CrossOutcome(
        val exact: StreamSource?,
        val best: StreamSource?,
        val exacts: List<StreamSource> = emptyList()
    )

    /**
     * v2.1.48 下载专用：一次遍历同时求「目标档」与「最高可得档」。
     * 与 [resolve] 的差别——resolve 拿到一条源就返回（播放够用即可），
     * 而下载必须先知道"拿到的到底是不是用户要的那一档"，否则就是"说能下无损、实际下 128k"。
     */
    suspend fun resolveForDownload(
        song: Song,
        want: QualityLevel,
        triedKeys: MutableSet<String>
    ): CrossOutcome? = withTimeoutOrNull(TOTAL_TIMEOUT_MS) {
        val kw = (song.name + " " + song.singer).trim()
        if (kw.isBlank()) return@withTimeoutOrNull CrossOutcome(null, null)
        val results = runCatching { SearchService.searchAll(kw, 30) }.getOrNull()
            ?: return@withTimeoutOrNull CrossOutcome(null, null)
        val cands = results.asSequence()
            .flatMap { it.songs.asSequence() }
            .filter { sameSong(song, it) }
            .filter { candKey(it) !in triedKeys }
            // v2.1.65：候选排序改为"能出目标档的平台优先"——
            // 只有网易侧的后端（gdstudio/oiapi）真能给出 320k/128k；QQ 与酷我的候选对这两档不可能命中，
            // 一旦排在前面只会白耗 12s/条，把 40s 整轮预算吃光，导致能出 320k 的网易候选根本轮不到。
            // 无损档仍按"同平台优先"（酷我妖狐恒给无损、同平台换源更稳）。
            .sortedWith(
                if (want == QualityLevel.LOSSLESS)
                    compareBy<Song> { if (it.platform == song.platform) 0 else 1 }
                        .thenByDescending { StudioPick.studioScore(it) }
                else
                    compareBy<Song> { if (tierCapable(it.platform, want)) 0 else 1 }
                        .thenBy { if (it.platform == song.platform) 0 else 1 }
                        .thenByDescending { StudioPick.studioScore(it) }
            )
            .distinctBy { candKey(it) }
            .take(MAX_CANDIDATES)
            .toList()
        for (c in cands) triedKeys.add(candKey(c))

        var exact: StreamSource? = null
        var best: StreamSource? = null
        val exacts = mutableListOf<StreamSource>()
        for (batch in cands.chunked(3)) {
            if (exacts.size >= MAX_EXACT_KEEP) break   // 目标档已攒够几条备选，剩下的不再打
            val got = coroutineScope {
                batch.map { c ->
                    async {
                        val r = runCatching { UrlResolver.resolveAll(c, want) }.getOrNull()
                        if (r != null) SourcePicker.pick(r.sources, want) else null
                    }
                }.awaitAll()
            }
            for (s in got) {
                if (s == null) continue
                if (s.quality == want) {
                    if (exact == null) exact = s
                    if (exacts.none { it.url == s.url }) exacts.add(s)
                }
                val cur = best
                if (cur == null || s.quality.ordinal > cur.quality.ordinal) best = s
            }
        }
        CrossOutcome(exact, best, exacts)
    }

    private fun candKey(s: Song) = s.platform.name + "_" + s.platformID

    /**
     * v2.1.65：这个平台的取流后端还能不能真的产出该档位。
     * 依据实测（30 首 × 三档）：网易 gdstudio 诚实分档（flac / 320k / 128k 都给），网易 oiapi 三档同一条 128k；
     * 酷我妖狐恒无损（没有 320/128 字段）；QQ cyapi 域名级不可达。
     * 因此 320k / 128k 只有网易候选有戏，其它平台的候选排到队尾，别占 40s 预算的坑。
     */
    private fun tierCapable(platform: MusicPlatform, want: QualityLevel): Boolean =
        if (want == QualityLevel.LOSSLESS) true else platform == MusicPlatform.NETEASE


    /** 同曲判定（统一口径见 NameMatch）：歌名匹配 + 歌手匹配 + 时长不差一个版本 */
    private fun sameSong(src: Song, cand: Song): Boolean {
        if (src.platform == cand.platform && src.platformID == cand.platformID) return false  // 自己不算候选
        if (!NameMatch.titleMatches(src.name, cand.name)) return false
        if (!NameMatch.singerMatches(src.singer, cand.singer)) return false
        if (src.durationSec > 0 && cand.durationSec > 0) {
            val diff = kotlin.math.abs(src.durationSec - cand.durationSec)
            // v2.1.48 版本防线（对应"换源不能下错版本"）：源是干净原唱、候选却是 live/综艺/节目变体时，
            // 换源就等于把别人的版本下给用户。只有时长几乎一致（≤3s，通常就是同一录音的不同码率转出）才认。
            val candIsVariant = !StudioPick.isCleanTitle(cand.name) ||
                (cand.album.isNotBlank() && StudioPick.isLiveAlbum(cand.album))
            if (StudioPick.isCleanTitle(src.name) && candIsVariant && diff > STRICT_DURATION_DIFF_SEC) return false

            if (diff > MAX_DURATION_DIFF_SEC) {
                // v2.1.30：源条目本身是「现场/节目变体」（歌名带 (Live)/（央视春晚现场版）等非裸名前缀），
                // 而候选是干净的录音室条目（裸名 + 正式专辑 + 更长），视为同一首歌的原唱版，允许跨越时长差。
                // 例如源《龙文 (Live)》236s → 候选《龙文》/专辑《看见》313s。
                val srcIsVariant = !StudioPick.isCleanTitle(src.name)
                val candIsStudio = StudioPick.isCleanTitle(cand.name) &&
                    cand.album.isNotBlank() && !StudioPick.isLiveAlbum(cand.album) &&
                    cand.durationSec > src.durationSec
                if (!(srcIsVariant && candIsStudio)) return false
            }
        }
        return true
    }
}

/**
 * v2.1.48 下载取源编排，v2.1.64 改为「候选清单」并让三档共用同一套换源链条。
 *
 * 为什么单独一层：原来下载直接调 SourcePicker.pick，而 pick 用 maxWithOrNull，列表非空必返回一条，
 * 于是"选了无损却拿到 128k"成为必然。这里把"是否真的拿到目标档"变成一个明确的返回值。
 *
 * v2.1.64 的两处补齐（用户口径：320k / 128k 也要像无损一样自动换源 + 按文件大小校验）：
 *  1. 通用搜索式后端（妖狐酷我）不再只服务无损——高品/标准在"本平台 + 跨源都没有目标档"时也会兜底打一次，
 *     拿到的东西至少是个可听的真文件，而不是直接报"没有音源"；
 *  2. 目标档不再按"档位桶"判，而是按 `QualityFacts.matches(容器, 码率)` 判——320k 必须真的落在 256–600k，
 *     128k 必须落在 48–255k，无损必须真是 flac/wav 容器。判定不过就换下一条，直到清单走完。
 */
object DownloadResolver {

    private const val GENERIC_TIMEOUT_MS = 12_000L  // 通用搜索式后端（妖狐酷我）单次硬超时
    private const val MAX_EXACT = 3                 // 目标档最多留 3 条给下载层逐条试

    /**
     * @param exact    已按"容器+码率"核实就是目标档的音源（按可信度排序，可多条）
     * @param fallback 目标档拿不到时的最高可得档（降级保存用，null = 一条源都没有）
     * @param switched 是否靠换源（换平台/换条目/换后端）得到
     * @param crossTried 本轮换源试过多少条同曲候选
     */
    data class Plan(
        val want: QualityLevel,
        val exact: List<StreamSource>,
        val fallback: StreamSource?,
        val switched: Boolean,
        val crossTried: Int
    ) {
        val empty: Boolean get() = exact.isEmpty() && fallback == null
    }

    suspend fun plan(song: Song, want: QualityLevel): Plan {
        val duration = song.durationSec
        val pool = mutableListOf<StreamSource>()

        // 第一轮：本平台自己的后端（QQ 只有 cyapi、网易有 gdstudio+oiapi、酷我有妖狐）
        val local = runCatching { UrlResolver.resolveAll(song, want) }.getOrNull()
        local?.sources?.let { pool += it }

        // 第二轮：跨源换源——同歌名 + 同歌手，StudioPick 排掉 live/节目版，逐个换到拿到目标档为止
        val tried = mutableSetOf<String>()
        val cross = runCatching { SameSongCrossResolver.resolveForDownload(song, want, tried) }.getOrNull()
        cross?.exacts?.let { pool += it }
        cross?.best?.let { pool += it }

        // 第三轮：通用搜索式后端（妖狐酷我，按"歌名+歌手"取流，跟歌来自哪个平台无关）
        // v2.1.65：无损档照旧打（妖狐恒给无损，是"无损几乎都能下"的那条兜底）；
        // 320k/128k 只在"一条源都没有"时才打——妖狐给不出这两档，前两轮已有源时再打它只是白等 12s。
        val hasExact = pool.any { isExact(it, want, duration) }
        val hasAny = pool.any { it.url.isNotBlank() }
        val generic: StreamSource? = if (!hasExact && song.platform != MusicPlatform.KUWO &&
            (want == QualityLevel.LOSSLESS || !hasAny)
        ) {
            runCatching {
                withTimeoutOrNull(GENERIC_TIMEOUT_MS) {
                    YaohuKuwoAdapter().resolve(song, QualityLevel.LOSSLESS)
                }
            }.getOrNull()
        } else null
        generic?.let { pool += it }

        val uniq = pool.filter { it.url.isNotBlank() }.distinctBy { it.url }
        val exact = uniq.filter { isExact(it, want, duration) }
            .sortedWith(
                compareBy<StreamSource> { if (it.platform == song.platform) 0 else 1 }
                    .thenBy { if (it.directId) 0 else 1 }
                    .thenByDescending { it.kbps }
            )
            .take(MAX_EXACT)
        val fallback = uniq.filterNot { s -> exact.any { it.url == s.url } }
            .maxWithOrNull(
                compareBy<StreamSource> { it.quality.ordinal }
                    .thenBy { it.kbps }
                    .thenBy { if (it.directId) 1 else 0 }
            )
        return Plan(
            want = want,
            exact = exact,
            fallback = fallback,
            switched = (exact + listOfNotNull(fallback)).any { it.platform != song.platform },
            crossTried = tried.size
        )
    }

    /**
     * 目标档判定：容器 + 码率都由取流阶段实测得到。
     * 时长未知时算不出码率，只能退回"档位桶"这一层近似（否则整条链路会因缺时长永远判不合规）。
     */
    fun isExact(src: StreamSource, want: QualityLevel, durationSec: Int): Boolean {
        if (durationSec <= 0 || src.kbps <= 0) return src.quality == want
        return QualityFacts.matches(want, src.format, src.kbps)
    }
}


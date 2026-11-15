package com.jz.musichelper.network

import com.jz.musichelper.model.Song

/**
 * v2.1.30：录音室原唱优选（Studio Original Picker）。
 *
 * 背景（用户反馈）：「猜你喜欢 / 编辑精选」里点开的《龙文》开头有掌声，是某节目消音后的版本，
 * 不是录音棚原唱；而「热门」一直是按原版口径取歌的（v2.0.2 起）。
 * 实测（2026-11-05）同一首《龙文》在各平台同时存在：
 *   - 谭晶《看见》专辑 313s（QQ mid 001RBlzR3ZEQhK / 网易 id 26217044）—— 录音棚原唱
 *   - 谭晶;陈奕迅 243s、无专辑 —— 节目剪辑/消音版（封面为现场照，开头有掌声）
 *   - 谭晶 2010 央视春晚现场版 117s、多个 (Live) 条目 236~310s —— 现场版
 * 只按歌名判定「原版」会全部放行（它们歌名都叫「龙文」），因此必须再看专辑与时长。
 *
 * 判定口径（与热门 v2.0.2 的 coreName/plainScore 一致，并补充专辑与时长维度）：
 *   ① 歌名是否「裸名」：剥掉括号版本说明（（Live）/（版本1）/（2010央视春晚现场版））与
 *      「- Live」「伴奏」等修饰后仍等于原名 → 才算原版名；
 *   ② 专辑名是否现场/节目来源（现场/演唱会/春晚/晚会/盛典/综艺/Live/新声代/天赐/蒙面…）；
 *   ③ 时长 vs 同曲共识时长（多平台多数条目的时长，±10s 分桶取众数）：
 *      ≤12s 视为同版，>30s 视为剪辑/片段/串烧；
 *   ④ 单歌手优于多歌手串（合唱版/群星版降权）。
 *
 * 注意：本对象只做「条目优选」，不改动播放链路；调用点决定是过滤（猜你喜欢候选池）
 * 还是择优（编辑精选取歌 / 跨平台补源候选排序）。
 */
object StudioPick {

    /** 括号说明（中英文括号/书名号方括号） */
    private val BRACKET = Regex("（[^）]*）|\\([^)]*\\)|\\[[^]]*]|【[^】]*】")

    /** 修饰后缀：命中即说明该条不是裸名（版本说明/伴奏/现场/翻唱/改编等） */
    private val EDIT_SUFFIX = Regex(
        "\\s*[-—–·]?\\s*(" +
            "伴奏|钢琴版|吉他版|翻唱|cover|live|现场版|现场|演唱会|音乐会|remix|dj版|dj|电音|串烧|" +
            "合唱版|合唱|纯音乐|钢琴|混音|重制|ktv|对唱|说唱|beat|instrumental|片段|剪辑|消音|学唱|" +
            "咚鼓|童声|古筝|学唱版|版本[0-9一二三四五六七八九十]+" +
            ").*$",
        RegexOption.IGNORE_CASE
    )

    /** 现场/节目来源的专辑名（命中即判定为非录音室专辑） */
    private val LIVE_ALBUM = Regex(
        "现场|演唱会|音乐会|春晚|春节|联欢|跨年|晚会|盛典|颁奖|综艺|节目|直播|" +
            "live|concert|unplugged|新声代|天赐|蒙面|我们的歌|声生不息|歌手20",
        RegexOption.IGNORE_CASE
    )

    private val MULTI_SINGER = Regex("[/&、,，;；]|\\s{2,}")

    /**
     * 核心歌名：剥括号版本说明 + 引号包裹名 + 修饰后缀 + 尾部连接符。
     * 与热门 HotMusic.coreName 同口径（不含歌手白名单剥离，避免跨包依赖）。
     */
    fun coreName(raw: String): String {
        var n = raw.trim()
        if (n.isEmpty()) return ""
        n = n.replace(BRACKET, "")
        n = n.replace(Regex("\\s+"), " ").trim()
        // 「周杰伦“夜曲”"] 这类引号包裹：取引号内原名
        val quoted = Regex("[\"'“”‘’「」『』]([^\"'“”‘’「」『』]*)[\"'“”‘’「」『』]").find(n)
        if (quoted != null && quoted.groupValues[1].isNotBlank()) n = quoted.groupValues[1].trim()
        n = EDIT_SUFFIX.replace(n, "").trim()
        n = n.replace(Regex("\\s*[-—–·]\\s*$"), "").trim()
        return n
    }

    /** 是否「裸名原版」：核心名与原名一致 */
    fun isCleanTitle(name: String): Boolean {
        val n = name.trim()
        if (n.isEmpty()) return false
        return coreName(n).equals(n, ignoreCase = true)
    }

    /** 专辑是否来自现场/节目（空专辑不算现场，但也不加分） */
    fun isLiveAlbum(album: String): Boolean =
        album.isNotBlank() && LIVE_ALBUM.containsMatchIn(album)

    /** 同曲共识时长：多平台多数条目时长（±10s 分桶取众数；至少 2 条才成立） */
    fun consensusDuration(cands: List<Song>): Int? {
        val durs = cands.map { it.durationSec }.filter { it in 30..7200 }
        if (durs.size < 2) return null
        val buckets = durs.groupBy { it / 10 }
        val best = buckets.entries.maxByOrNull { it.value.size } ?: return null
        if (best.value.size < 2) return null
        return best.value.sorted()[best.value.size / 2]
    }

    /**
     * 原唱得分（越高越接近录音棚原唱）。仅在「同曲候选」之间比较，
     * 不做跨曲绝对判断，因此不需要归一化。
     */
    fun studioScore(s: Song, consensusDurSec: Int? = null): Int {
        var score = 0
        // ① 歌名必须是裸名；带（Live）/（版本1）等后缀直接重罚
        if (isCleanTitle(s.name)) score += 100 else score -= 60
        // ② 专辑：现场/节目来源重罚；有正式专辑小加分（节目/剪辑条目通常无专辑）
        if (isLiveAlbum(s.album)) score -= 80 else if (s.album.isNotBlank()) score += 15
        // ③ 时长与同曲共识对齐程度
        if (consensusDurSec != null && s.durationSec > 0) {
            val diff = kotlin.math.abs(s.durationSec - consensusDurSec)
            score += when {
                diff <= 12 -> 40
                diff <= 30 -> 0
                else -> -70
            }
        }
        // ④ 单歌手优于合唱/群星（原唱多为单人；合唱版、群星版降权）
        score += if (MULTI_SINGER.containsMatchIn(s.singer.trim())) -12 else 10
        // ⑤ 同分时短名优先（与热门 plainScore 一致）
        score -= s.name.trim().length / 6
        return score
    }

    /** 在一组同曲候选里挑最接近录音室原唱的一条 */
    fun pickBest(cands: List<Song>): Song? {
        if (cands.isEmpty()) return null
        if (cands.size == 1) return cands[0]
        val cons = consensusDuration(cands)
        return cands.maxByOrNull { studioScore(it, cons) }
    }

    /**
     * 候选池按核心歌名归并：同一首歌只保留「最像录音室原唱」的一条。
     * 用于猜你喜欢候选池（此前同一首《龙文》的节目版与录音室版会同时入池，随机命中节目版）。
     */
    fun dedupeByCore(cands: List<Song>): List<Song> {
        if (cands.size <= 1) return cands
        val groups = LinkedHashMap<String, MutableList<Song>>()
        for (s in cands) {
            val key = coreName(s.name).ifBlank { s.name.trim() }
            if (key.isEmpty()) continue
            groups.getOrPut(key) { mutableListOf() }.add(s)
        }
        val out = ArrayList<Song>(groups.size)
        for ((_, g) in groups) {
            val cons = consensusDuration(g)
            g.maxByOrNull { studioScore(it, cons) }?.let { out.add(it) }
        }
        return out
    }
}

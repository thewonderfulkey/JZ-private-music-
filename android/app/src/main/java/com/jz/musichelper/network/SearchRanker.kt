package com.jz.musichelper.network

import com.jz.musichelper.model.MusicPlatform
import com.jz.musichelper.model.Song
import kotlin.math.max

/**
 * 跨平台搜索结果全局排序（v1.8.2 校准，方案三）：
 * 打分 = 歌名匹配×0.5 + 歌手匹配×0.3 + 专辑匹配×0.2；
 * 每个维度取所有关键词词元对该字段的最高匹配分；
 * 词匹配分档：完全相等 100 / 前缀 60 / 包含 40 / 未命中 0（前缀 80→60，拉开"晴天 (Live)"等变体与纯原版的差距）。
 * 改编/翻唱后缀降权（B）：歌名命中但标题含"钢琴/翻唱/DJ/Live"等改编标记时，歌名分×0.8；匹配忽略大小写（修复 "Live" 不触发降权）。
 * 专辑维度收敛：仅多词查询参与；排除"专辑=歌名"的 UGC 伪命中与空专辑；只按精确/包含匹配，不按前缀。
 * 平台位置先验（C）：各平台 API 返回位次前 4 名分别 +10/+6/+3/+1，以平台排好的"文本相关+热度"顺序作为热度代理。
 * 同分按平台优先级（QQ→网易→酷我→酷狗）+ 原始顺序稳定排序，保证结果不跳动。
 */
object SearchRanker {

    private val PLATFORM_ORDER = mapOf(
        MusicPlatform.QQ to 0,
        MusicPlatform.NETEASE to 1,
        MusicPlatform.KUWO to 2,
        MusicPlatform.KUGOU to 3,
    )

    // 改编/翻唱/变奏标记：命中则歌名匹配分衰减，让"晴天"纯原版压过"晴天(深情版)"等变体
    private val REMIX_MARKERS = listOf(
        "翻唱", "钢琴", "吉他", "伴奏", "纯音乐", "纯乐", "dj", "live", "串烧",
        "深情", "史诗", "女声", "男声", "版本", "改编", "现场", "演唱会",
        "交响", "大提琴", "萨克斯", "片段", "降调", "升调", "remix", "cover",
        "独奏", "变奏", "翻录",
    )

    fun rank(keyword: String, songs: List<Song>): List<Song> {
        val words = keyword.trim().split(Regex("\\s+")).filter { it.isNotBlank() }
        if (words.isEmpty()) return songs
        // 同平台同 ID 去重（分页/重复返回保护，LazyColumn key 需唯一）
        val dedup = songs.distinctBy { "${it.platform.name}_${it.platformID}" }
        // 平台内位次先验 + 原始顺序稳定排序
        val counters = mutableMapOf<MusicPlatform, Int>()
        val scored = dedup.mapIndexed { originalIndex, s ->
            val platformIdx = counters.getOrDefault(s.platform, 0)
            counters[s.platform] = platformIdx + 1
            Scored(s, score(s, words) + positionBonus(platformIdx), originalIndex)
        }
        return scored.sortedWith(
            compareByDescending<Scored> { it.score }
                .thenBy { PLATFORM_ORDER[it.song.platform] ?: 9 }
                .thenBy { it.originalIndex }
        ).map { it.song }
    }

    private fun positionBonus(platformIndex: Int): Double = when (platformIndex) {
        0 -> 10.0
        1 -> 6.0
        2 -> 3.0
        3 -> 1.0
        else -> 0.0
    }

    private fun score(s: Song, words: List<String>): Double {
        val title = s.name.uppercase()
        val artist = s.singer.uppercase()
        val album = s.album.uppercase()
        var bestTitle = 0.0
        var bestArtist = 0.0
        var bestAlbum = 0.0
        // 专辑维度收敛：仅多词查询参与；排除"专辑=歌名"的 UGC 伪命中与空专辑
        val albumActive = words.size > 1 && album.isNotEmpty() && album != title
        for (w in words) {
            val u = w.uppercase()
            bestTitle = max(bestTitle, match(u, title))
            bestArtist = max(bestArtist, match(u, artist))
            if (albumActive) {
                bestAlbum = max(bestAlbum, when {
                    album == u -> 100.0
                    album.contains(u) -> 40.0
                    else -> 0.0
                })
            }
        }
        // B：改编/翻唱后缀降权（忽略大小写，修复 "晴天 (Live)" 不触发降权）
        if (REMIX_MARKERS.any { title.contains(it, ignoreCase = true) }) bestTitle *= 0.8
        // v2.1.88：标题只是查询串的一部分时不许拿满分——查 "IVORY TOWER" 却把叫 "IVORY" 的另一首歌排在首行，
        // 就是这里给了"词元完全相等 100 分"。整串更长且包含该标题 → 只是部分命中，分数封顶 40。
        val phrase = words.joinToString(" ")
        if (title.isNotEmpty() && phrase.length > title.length && phrase.contains(title)) {
            bestTitle = minOf(bestTitle, 40.0)
        }
        return bestTitle * 0.5 + bestArtist * 0.3 + bestAlbum * 0.2
    }

    // A：包含分档 40（相等 100 / 前缀 60 / 包含 40 / 缺失 0）
    private fun match(word: String, field: String): Double = when {
        field == word -> 100.0
        field.startsWith(word) -> 60.0
        field.contains(word) -> 40.0
        else -> 0.0
    }

    private data class Scored(val song: Song, val score: Double, val originalIndex: Int)
}

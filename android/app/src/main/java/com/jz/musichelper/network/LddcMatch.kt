package com.jz.musichelper.network

import kotlin.math.max

/**
 * LDDC 歌词候选匹配评分算法移植（chenmozhijin/LDDC，GPL-3.0，core/algorithm.py）。
 * 方案 A 的“严格匹配选优”层：对三源搜索到的全部候选按
 *   titleScore × 0.5 + artistScore × 0.5  排序选最优（标题分 < 30 重罚 -35，对齐 auto_fetch 的 min_score=55）。
 * 目标行为：完全匹配候选（如《稻香》原版）≈100 分独占榜首；
 * 现场版/纯音乐/翻唱等（歌手组合不同、标题带 tag）评分显著降低或被时长过滤排除。
 */
object LddcMatch {

    // ---------- 标题评分（calculate_title_score） ----------

    // 对齐 LDDC TITLE_TAG_PATTERN（三组捕获）：
    //   1) 括号内 tag：[-<(\[～]([～\]^)>-]*)
    //   2) 词 tag：\w+ ?(?:(?:solo |size )?ver(?:sion)?\.?|size|style|mix(?:ed)?|edit(?:ed)?|版|solo)
    //   3) 纯音乐/inst/off vocal
    // 注意：Python \w 是 Unicode，Kotlin/Java 默认 ASCII → 用 [\p{L}\p{N}_]+ 替代
    private val TITLE_TAG_PATTERN = Regex(
        """[-<(\[～]([～\]^)>-]*)|([\p{L}\p{N}_]+ ?(?:(?:solo |size )?ver(?:sion)?\.?|size|style|mix(?:ed)?|edit(?:ed)?|版|solo))|(纯音乐|inst\.?(?:rumental)|off ?vocal(?: ?[Vv]er.))"""
    )

    private const val TAG_SYMBOL_CLASS = """[-><)(\]\[～]"""

    /** 提取 not_same 中的 tag 并归一，返回 (tags, 剩余文本)。对齐 LDDC get_tags */
    private fun titleTags(notSame: String): Pair<List<String>, String> {
        val tags = mutableListOf<String>()
        TITLE_TAG_PATTERN.findAll(notSame).forEach { m ->
            m.groupValues.drop(1).forEach { g -> if (g.isNotBlank()) tags.add(g.trim()) }
        }
        // tags 为空：LDDC re.sub("|[...]", "", s) 的空分支不删任何字符 → 剩余文本原样
        val other = if (tags.isEmpty()) notSame
        else notSame.replace(Regex(tags.joinToString("|") + "|" + TAG_SYMBOL_CLASS), "")
        // 归一化 tags（逐项对齐 LDDC）
        for (i in tags.indices) {
            var t = tags[i]
            if ("ver" in t || t == "伴奏" || t == "纯音乐") {
                t = t.replace(Regex("""ver(?:sion)?\.?|伴奏|纯音乐|inst\.?(?:rumental)|off ?vocal(?: ?[Vv]er.)?"""), "inst")
            }
            if ("ver" in t) {
                t = t.replace(Regex("""ver(?:sion)?\.?"""), "ver")
            }
            t = t.replace("mixed", "mix").replace("edited", "edit")
            if ("solo" in t || "mix" in t || "edit" in t || "style" in t || "size" in t) {
                t = t.replace(Regex("""(solo|mix|edit|style|size) ver"""), "$1")
            }
            if ("tv" in t || "anime" in t) {
                t = t.replace(Regex("""(?:tv|anime) ?(?:サイズ|size)?(?: ?edit)?(?: ?ver)?"""), "tv size")
            }
            tags[i] = t
        }
        return Pair(tags, other)
    }

    /** 标题评分（0..100）。对齐 LDDC calculate_title_score 主路径 */
    fun calculateTitleScore(title1: String, title2: String): Double {
        val t1 = unifiedSymbol(title1).lowercase()
        val t2 = unifiedSymbol(title2).lowercase()
        if (t1 == t2) return 100.0
        val score0 = max(textDifference(t1, t2), 0.0) * 100.0
        var sameBegin = ""
        for (i in t1.indices) {
            if (i < t2.length && t1[i] == t2[i]) sameBegin += t1[i] else break
        }
        if (sameBegin == t1 || sameBegin == t2 || sameBegin.isEmpty()) return score0

        val (tags1, other1) = titleTags(t1.substring(sameBegin.length))
        val (tags2, other2) = titleTags(t2.substring(sameBegin.length))

        val tag1NoMatch = mutableListOf<String>()
        val tag2NoMatch = tags2.toMutableList()
        var other1Adj = other1
        var other2Adj = other2
        for (tag1 in tags1) {
            if (tag1 in tag2NoMatch) {
                tag2NoMatch.remove(tag1)
            } else if (Regex("""(?:solo|mix|edit|style|size|edit|inst)$""").containsMatchIn(tag1)) {
                tag1NoMatch.add(tag1)
            } else if (tag1 in other2Adj) {
                other1Adj += tag1
            }
        }
        val remove2 = mutableListOf<String>()
        for (tag2 in tag2NoMatch) {
            if (!Regex("""(?:solo|mix|edit|style|size|edit|inst)$""").containsMatchIn(tag2) && tag2 in other1Adj) {
                other2Adj += tag2
                remove2.add(tag2)
            }
        }
        tag2NoMatch.removeAll(remove2.toSet())

        val kp = sameBegin.length.toDouble() /
            (((other1Adj.length + other2Adj.length) / 2.0) + sameBegin.length)
        val score1 = 100.0 * kp + max(textDifference(other1Adj, other2Adj), 0.0) * (1 - kp)

        if (tag1NoMatch.isEmpty() && tag2NoMatch.isEmpty()) {
            return max(score1 * 0.7 + 30.0, score0)
        }
        var score2 = 0.0
        var score3 = 0.0
        if (tag1NoMatch.isNotEmpty() && tag2NoMatch.isNotEmpty()) {
            for (tag1 in tag1NoMatch) {
                var best = 0.0
                for (tag2 in tag2NoMatch) best = max(best, textDifference(tag1, tag2))
                score2 += best * (30.0 / tag1NoMatch.size)
            }
            for (tag2 in tag2NoMatch) {
                var best = 0.0
                for (tag1 in tag1NoMatch) best = max(best, textDifference(tag1, tag2))
                score3 += best * (30.0 / tag2NoMatch.size)
            }
        }
        return max(score1 * 0.7 + max(score2, score3), score0)
    }

    // ---------- 歌手评分（calculate_artist_score） ----------

    /** 全角符号 → 半角 + 去首尾空白 + 空白归一（LDDC unified_symbol） */
    fun unifiedSymbol(text: String): String {
        val sb = StringBuilder(text.trim())
        for (i in sb.indices) {
            when (sb[i]) {
                '（' -> sb[i] = '('
                '）' -> sb[i] = ')'
                '：' -> sb[i] = ':'
                '！' -> sb[i] = '!'
                '？' -> sb[i] = '?'
                '／' -> sb[i] = '/'
                '＆' -> sb[i] = '&'
                '＊' -> sb[i] = '*'
                '＠' -> sb[i] = '@'
                '＃' -> sb[i] = '#'
                '＄' -> sb[i] = '$'
                '％' -> sb[i] = '%'
                '＼' -> sb[i] = '\\'
                '｜' -> sb[i] = '|'
                '＝' -> sb[i] = '='
                '＋' -> sb[i] = '+'
                '－' -> sb[i] = '-'
                '＜' -> sb[i] = '<'
                '＞' -> sb[i] = '>'
                '［' -> sb[i] = '['
                '］' -> sb[i] = ']'
                '｛' -> sb[i] = '{'
                '｝' -> sb[i] = '}'
            }
        }
        return sb.toString().trim().replace(Regex("""\s+"""), " ")
    }

    /** 文本相似度（0..1）：完全相等 1.0；否则 LCS 长度比 2·LCS/(n+m)。对齐 SequenceMatcher 语义 */
    fun textDifference(a: String, b: String): Double {
        if (a == b) return 1.0
        if (a.isEmpty() || b.isEmpty()) return 0.0
        val n = a.length
        val m = b.length
        val dp = Array(n + 1) { IntArray(m + 1) }
        for (i in 1..n) {
            for (j in 1..m) {
                dp[i][j] = if (a[i - 1] == b[j - 1]) dp[i - 1][j - 1] + 1
                else max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        val lcs = dp[n][m].toDouble()
        return 2.0 * lcs / (n + m)
    }

    /**
     * 歌手字符串拆分为歌手列表；每项可能含 [原名, 括号别名]（对齐 LDDC artist_str2list 主路径：
     * 按 [,、/\\&] 分隔；括号内为别名/角色 → 拆出）。日系组织名/角色/CV 分支不做（中文流行歌场景）。
     */
    fun artistStr2List(artist: String): List<List<String>> {
        val unified = artist.trim()
            .replace('·', '・').replace('（', '(').replace('）', ')').replace('：', ':')
        val parts = unified.split(Regex("""[,、/\\&]""")).map { it.trim() }.filter { it.isNotEmpty() }
        if (parts.isEmpty()) return emptyList()
        val result = mutableListOf<List<String>>()
        for (p in parts) {
            val m = Regex("""^(.*?)\s?\(([^()]*)\)$""").matchEntire(p)
            if (m != null) {
                val name1 = m.groupValues[1].trim()
                val name2 = m.groupValues[2].trim()
                    .removePrefix("CV:").removePrefix("CV：").removePrefix("VO:").trim()
                if (name1.isNotEmpty()) {
                    val names = mutableListOf(name1)
                    if (name2.isNotEmpty() && name2 != name1) names.add(name2)
                    result.add(names)
                } else if (name2.isNotEmpty()) {
                    result.add(listOf(name2))
                }
            } else {
                result.add(listOf(p))
            }
        }
        return result
    }

    /** 两个歌手列表的最大匹配相似度（LDDC list_max_difference：贪心取最高分对，除以 max(len)） */
    fun listMaxDifference(origList1: List<List<String>>, origList2: List<List<String>>): Double {
        val l1 = origList1.map { it.filter { s -> s.isNotEmpty() } }.filter { it.isNotEmpty() }
        val l2 = origList2.map { it.filter { s -> s.isNotEmpty() } }.filter { it.isNotEmpty() }
        if (l1.isEmpty() || l2.isEmpty()) return 0.0
        val scores = mutableListOf<Triple<Int, Int, Double>>()
        for (i1 in l1.indices) {
            for (i2 in l2.indices) {
                var best = 0.0
                for (s1 in l1[i1]) for (s2 in l2[i2]) best = max(best, textDifference(s1, s2))
                scores.add(Triple(i1, i2, best))
            }
        }
        scores.sortWith(compareByDescending { it.third })
        val used1 = mutableSetOf<Int>()
        val used2 = mutableSetOf<Int>()
        var total = 0.0
        for ((i1, i2, s) in scores) {
            if (i1 in used1 || i2 in used2) continue
            used1.add(i1); used2.add(i2); total += s
            if (used1.size == l1.size || used2.size == l2.size) break
        }
        return total / max(l1.size, l2.size)
    }

    /** 歌手评分（0..100）。对齐 LDDC calculate_artist_score：列表匹配与整体文本相似取 max */
    fun calculateArtistScore(artist1: String, artist2: String): Double {
        if (artist1.isBlank() || artist2.isBlank()) return 0.0
        // 单对单完全相等（忽略大小写）→ 100
        val flat1 = artistStr2List(artist1).map { it.firstOrNull() ?: "" }.filter { it.isNotEmpty() }
        val flat2 = artistStr2List(artist2).map { it.firstOrNull() ?: "" }.filter { it.isNotEmpty() }
        if (flat1.size == 1 && flat2.size == 1 && flat1[0].equals(flat2[0], ignoreCase = true)) return 100.0
        val listScore = listMaxDifference(artistStr2List(artist1), artistStr2List(artist2))
        val joined = textDifference(flat1.joinToString(""), flat2.joinToString(""))
        return max(listScore, joined) * 100.0
    }
}

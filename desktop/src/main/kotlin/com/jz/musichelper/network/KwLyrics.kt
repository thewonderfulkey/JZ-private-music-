package com.jz.musichelper.network

/**
 * 酷我歌词源（v2.1.87）。
 *
 * 端点：`https://www.kuwo.cn/openapi/v1/www/lyric/getlyric?musicId=<纯数字>&httpsStatus=1`
 * 返回：`data.lrclist[{lineLyric, time}]`，`time` 为**秒**（两位小数），只有行级时间、没有逐字。
 *
 * 只对 KUWO 歌曲生效：平台 ID 是精确的 MUSICRID，不需要像 LDDC 那样按「歌名+歌手」猜。
 * 两个实测坑：
 *  1. 参数必须纯数字，带 `MUSIC_` 前缀服务端返回「参数错误」；
 *  2. 该曲无词时返回 `data:{}` 且 code 仍为 200，必须判空，交给 LDDC 兜底。
 */
object KwLyrics {

    private const val NET_TIMEOUT = 8L
    private const val BASE = "https://www.kuwo.cn/openapi/v1/www/lyric/getlyric"

    suspend fun fetch(platformID: String): List<LyricLine>? {
        val rid = platformID.filter { it.isDigit() }
        if (rid.isBlank()) return null
        val url = "$BASE?musicId=$rid&httpsStatus=1"
        val json = runCatching {
            ApiClient.getJson(
                url,
                headers = mapOf("Referer" to "https://www.kuwo.cn/"),
                timeoutSec = NET_TIMEOUT,
            )
        }.getOrNull() ?: return null
        if (json.optInt("code", -1) != 200) return null
        val arr = json.optJSONObject("data")?.optJSONArray("lrclist") ?: return null

        val out = ArrayList<LyricLine>(arr.length())
        for (i in 0 until arr.length()) {
            val item = arr.optJSONObject(i) ?: continue
            val text = LyricsService.cleanLine(item.optString("lineLyric", ""))
            if (text.isBlank()) continue
            val timeMs = parseTimeMs(item.opt("time")) ?: continue
            out.add(LyricLine(timeMs, text))
        }
        if (out.isEmpty()) return null
        // 个别曲目行序有跳，按时间重排；行数太少的（残缺词）不接，交给兜底
        return out.sortedBy { it.timeMs }.takeIf { it.size >= 3 }
    }

    /** time 可能是数字 0.12，也可能是字符串 "0.12"；统一换成整首绝对毫秒 */
    private fun parseTimeMs(v: Any?): Long? {
        val d = when (v) {
            is Number -> v.toDouble()
            is String -> v.trim().toDoubleOrNull()
            else -> null
        } ?: return null
        if (d < 0) return null
        return (d * 1000).toLong()
    }
}

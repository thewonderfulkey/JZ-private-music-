package com.jz.musichelper.network

import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.security.MessageDigest

/**
 * v2.1.80：听歌识曲（方案 A——复用酷狗指纹识曲接口）
 *
 * 实测结论（2026-10，本机 8k/单声道/16bit PCM 10s 实测通过）：
 *  · 入口不是 kmr/mobilekmr，而是统一网关 https://gateway.kugou.com
 *  · 路径 /fingerprint.service/v1/music_trackid_mulit（多结果），POST 体为裸 PCM
 *  · PCM 必须是 **8kHz**、单声道、16bit 小端（16k 实测返回空 data）
 *  · 签名 = md5(salt + 排序后 k=v 拼接 + **请求体字节** + salt)，salt 与取词链路同一个 KG_SALT
 *  · 返回 data[] 每项含 songname / singername / album[].albumname
 * 该接口只用来拿「歌名 + 歌手」，随后交给现有 3 平台搜索链路解析取流。
 */
object RecognizeAdapter {

    private const val SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
    private const val ENDPOINT = "https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit"
    private const val UA = "KuGou/11490 (Android)"
    private const val APPID = "3116"
    private const val CLIENTVER = "11070"

    /** 识别到的一首歌（只保留够搜索用的字段） */
    data class Hit(val title: String, val artist: String, val album: String = "")

    object Judge {
        /** 歌名里带这些词 = 编曲/现场/翻唱类版本，本身就不是录音室原版 */
        private val VARIANT_TITLE = Regex(
            "伴奏|伴唱|纯音乐|instrumental|钢琴|翻唱|cover|remix|live|现场|演唱会|片段|剪辑|ktv|dj|消音|合唱",
            RegexOption.IGNORE_CASE
        )

        /** 专辑名带这些词 = 综艺/节目/现场专辑（如《异口同声 第十二期》），同样不是录音室原版 */
        private val VARIETY_ALBUM = Regex(
            "综艺|异口同声|节目|第[0-9一二三四五六七八九十]+期|演唱会|音乐节|晚会|春晚|live|现场",
            RegexOption.IGNORE_CASE
        )

        /**
         * v2.1.89：指纹接口（酷狗）返回的是"它曲库里匹配到的那一条"，可能是综艺合唱版、DJ 版。
         * 这种命中不能当原唱用：起播要改走"同曲录音室版择优"，「原唱」标签也不能落在它身上。
         */
        fun isVariantHit(title: String, album: String): Boolean =
            VARIANT_TITLE.containsMatchIn(title) || VARIETY_ALBUM.containsMatchIn(album)

        /** 歌名本身带改编/现场词 */
        fun isVariantTitle(name: String): Boolean = VARIANT_TITLE.containsMatchIn(name)

        /** 专辑是综艺/节目/现场（《异口同声 第十二期》《中国新声代 第三季 第十三期》） */
        fun isVarietyAlbum(album: String): Boolean = VARIETY_ALBUM.containsMatchIn(album)

        private fun norm(s: String): String =
            s.lowercase().replace(Regex("[\\s\\p{Punct}·、，。（）()【】《》\\[\\]\\-]"), "")

        /**
         * 专辑名"就是歌名"（含「我们都一样 EP」「我们都一样 (回忆版)」「我们都一样-阿莫」这类）——
         * 这类几乎都是同名合集/翻唱合集，不能当正式专辑看。
         */
        fun isSameAlbumAsTitle(album: String, title: String): Boolean {
            val a = norm(album)
            val t = norm(title)
            if (a.isEmpty() || t.isEmpty()) return false
            return a == t || a.startsWith(t)
        }

        /** v2.1.90：指纹接口一次给多条候选，优先选非综艺/非改编的那条（现在只用了第 1 条） */
        fun rankCandidates(hits: List<Hit>): List<Hit> =
            hits.sortedBy { if (isVariantHit(it.title, it.album)) 1 else 0 }

        /**
         * v2.1.91：网易通道的候选排序。网易一次最多回 3 条，且**同时给翻唱与原唱**
         * （实测《晴天》同一条音频会回「晴天(深情版)/Lucky小爱」+「晴天/周杰伦/叶惠美」），
         * 所以除了过滤变体，还要压两类"同名合集"：
         *  · 专辑名就是歌名本身（《晴天(深情版)》这类自建合集）
         *  · 标题里加了前缀后缀（「丹尼尔在的晴天」这类二创标题）
         * 排序键：变体 → 同名合集 → 标题长度，越靠前越像原版。
         */
        fun rankNetease(hits: List<Hit>): List<Hit> =
            hits.sortedWith(
                compareBy(
                    { if (isVariantHit(it.title, it.album)) 1 else 0 },
                    { if (isSameAlbumAsTitle(it.album, it.title)) 1 else 0 },
                    { it.title.length }
                )
            )

        /** 比对归一化：小写 + 去空格标点 */
        fun normName(s: String): String = norm(s)

        /**
         * v2.1.90「原唱」判定 A 分支——只在识曲本身命中的是综艺/现场/改编版时用：
         * 同一歌手有 ≥2 张不同的**正式专辑**（专辑名不是歌名本身、不是现场/综艺），
         * 且这些条目的时长互相 ≤3 秒 → 说明是同一版录音被反复收录，即录音室原版。
         * 实测《我们都一样》：张杰《明天过后》302s + 《One Chance》303s 命中；
         * 棉花糖/王理文等只有一张专辑，不命中；橘子妹/胡小斐等的专辑就叫《我们都一样》，不命中。
         */
        fun canonicalSingers(versions: List<com.jz.musichelper.model.Song>, title: String): Set<String> {
            val titleNorm = norm(title)
            if (titleNorm.isEmpty()) return emptySet()
            val exact = versions.filter { norm(it.name) == titleNorm }
            return exact.groupBy { norm(it.singer) }.mapNotNull { (singer, items) ->
                val formal = items.filter {
                    it.album.isNotBlank() && it.durationSec > 60 &&
                        !isSameAlbumAsTitle(it.album, title) &&
                        !StudioPick.isLiveAlbum(it.album) && !isVarietyAlbum(it.album)
                }
                val clusters = ArrayList<MutableList<com.jz.musichelper.model.Song>>()
                for (s in formal.sortedBy { it.durationSec }) {
                    val last = clusters.lastOrNull()
                    if (last != null && s.durationSec - last.last().durationSec <= 3) last.add(s)
                    else clusters.add(mutableListOf(s))
                }
                val hitCluster = clusters.firstOrNull { c -> c.map { norm(it.album) }.distinct().size >= 2 }
                if (hitCluster != null) singer else null
            }.toSet()
        }
    }

    /**
     * 上传 PCM 识别。返回按相似度排好序的候选（最多 5 条）；空列表 = 没听清。
     * 网络/解析异常以 Throwable 抛出，由 UI 层兜成"识别失败"。
     */
    suspend fun recognize(pcm: ByteArray): List<Hit> {
        require(pcm.size >= 8000 * 2) { "PCM 太短（至少 1 秒）" }
        val now = System.currentTimeMillis()
        val mid = md5Hex(now.toString())
        // 参数集照抄实测通过的一版（顺序无关，签名前会排序）
        val params = linkedMapOf(
            "fpid" to now.toString(),
            "area_code" to "1",
            "include_unpublish" to "1",
            "useid" to "0",
            "multi_result" to "1",
            "dfid" to "-",
            "mid" to mid,
            "uuid" to "-",
            "appid" to APPID,
            "clientver" to CLIENTVER,
            "clienttime" to (now / 1000).toString()
        )
        val joined = params.entries.sortedBy { it.key }
            .joinToString("") { (k, v) -> "$k=$v" }
        val signature = md5Signature(joined, pcm)
        val query = params.entries.sortedBy { it.key }
            .joinToString("&") { (k, v) -> "$k=${URLEncoder.encode(v, "UTF-8")}" } +
            "&signature=$signature"

        val resp = ApiClient.postBytes(
            "$ENDPOINT?$query",
            pcm,
            contentType = "application/octet-stream",
            headers = mapOf("User-Agent" to UA, "mid" to mid, "dfid" to "-"),
            timeoutSec = 25
        )
        return parse(resp)
    }

    private fun parse(resp: String): List<Hit> {
        val root = JSONObject(resp)
        val code = root.optInt("error_code", -1)
        val data = root.optJSONArray("data") ?: JSONArray()
        if (data.length() == 0) {
            // error_code=0 + 空 data 是"没识别到"，不是错误；其余码才算失败
            if (code != 0) throw IllegalStateException("识曲服务返回 error_code=$code")
            return emptyList()
        }
        val out = ArrayList<Hit>(data.length())
        for (i in 0 until data.length()) {
            val o = data.optJSONObject(i) ?: continue
            val title = o.optString("songname", "").trim()
            if (title.isEmpty()) continue
            val artist = o.optString("singername", "").trim()
            val album = o.optJSONArray("album")?.optJSONObject(0)?.optString("albumname", "").orEmpty()
            // 同歌同歌手去重（multi_result 会给多个版本）
            if (out.any { it.title == title && it.artist == artist }) continue
            out.add(Hit(title, artist, album))
            if (out.size >= 5) break
        }
        return out
    }

    /** md5(salt + 参数串 + 请求体 + salt)——body 参与签名，缺了服务端一律判签名错 */
    private fun md5Signature(paramsString: String, body: ByteArray): String {
        val md = MessageDigest.getInstance("MD5")
        md.update(SALT.toByteArray(Charsets.UTF_8))
        md.update(paramsString.toByteArray(Charsets.UTF_8))
        md.update(body)
        md.update(SALT.toByteArray(Charsets.UTF_8))
        return md.digest().joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    }

    private fun md5Hex(s: String): String =
        MessageDigest.getInstance("MD5").digest(s.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xFF) }
}

package com.jz.musichelper.network

import com.jz.musichelper.model.Song
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.security.MessageDigest
import java.util.Base64
import kotlin.math.abs
import kotlin.math.max
import kotlin.random.Random

/**
 * LDDC 歌词源本地移植（v1.7.0 完整内嵌版，对齐 LDDC auto_fetch 机制）：
 * 双源（酷狗 KG / QQ QM）并行搜索**全部候选** → LDDC 评分算法
 * （标题×0.5 + 歌手×0.5，标题<30 重罚 -35，min_score=55，时长±4s 过滤）严格匹配选优 →
 * 按分数排序逐个尝试取歌词（最多前 2 个）→ KRC/QRC 解密 → 标准 LRC。
 *
 * 对照 LDDC 原版（chenmozhijin/LDDC，GPL-3.0）：
 *  - 源优先级对齐 sources=(QM, KG)：QQ → 酷狗（lrclib 国内不可达，v1.7.9 起废弃）
 *  - 酷狗 Lyric 模块签名只含 appid/clientver + 业务参数（塞公共参数会签名失配）
 *  - download 返回 contenttype==2 时 content 是 base64 纯文本 LRC（非 KRC）
 *  - QQ 歌词可用性判断：qrc_t≠0 用 qrc_t，否则用 lrc_t
 *  - KRC 明文词条为三参数 <s,d,o>（实测 dump 确认），krcToLrc 正则与 LDDC 官方一致
 */
object LddcLyrics {

    private const val KG_SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
    private const val NET_TIMEOUT = 8L
    private const val MIN_SCORE = 55.0
    private const val DURATION_TOLERANCE_MS = 4000L

    @Volatile
    private var cachedDfid: String? = null
    private var cachedDfidAt = 0L

    /** QQ 会话（uid/sid/userip）缓存：搜索与取词共用，避免重复 GetSession */
    @Volatile
    private var cachedQqSession: JSONObject? = null

    /** 搜索候选（含各源句柄），交由评分层选优 */
    data class LyricsCandidate(
        val source: String,          // "kg" / "qq"
        val title: String,
        val artist: String,
        val durationSec: Int,
        val kgId: String? = null,
        val kgHash: String? = null,
        val qqId: String? = null,
        val qqSinger: String? = null,
        val qqAlbum: String? = null,
    )

    /** 统一入口：双源并行搜索全量候选 → 评分选优 → 逐候选取歌词（对齐 LDDC auto_fetch） */
    suspend fun fetch(song: Song): List<LyricLine>? {
        val title = song.name.trim()
        val artist = LyricsService.cleanArtist(song.singer)
        if (title.isBlank()) return null
        return withTimeoutOrNull(8000) {
            coroutineScope {
                val kg = async { runCatching { searchKg(title, artist) }.getOrDefault(emptyList()) }
                val qq = async { runCatching { searchQq(title, artist) }.getOrDefault(emptyList()) }
                val candidates = kg.await() + qq.await()
                pickBest(candidates, song, title, artist)
            }
        }
    }

    /** 评分 + 过滤 + 排序 + 逐候选取歌词（LDDC auto_fetch：score>55，排序降序，最多尝试前 2 个） */
    private suspend fun pickBest(
        candidates: List<LyricsCandidate>,
        song: Song,
        title: String,
        artist: String
    ): List<LyricLine>? {
        val targetDurMs = song.durationSec.toLong() * 1000L
        val scored = mutableListOf<Pair<Double, LyricsCandidate>>()
        for (cand in candidates) {
            // 时长过滤：目标已知且候选已知，相差 >4s 忽略（对齐 LDDC ±4000ms）
            if (targetDurMs > 0 && cand.durationSec > 0) {
                if (abs(targetDurMs - cand.durationSec * 1000L) > DURATION_TOLERANCE_MS) continue
            }
            val titleScore = LddcMatch.calculateTitleScore(title, cand.title)
            val artistScore =
                if (artist.isNotBlank()) LddcMatch.calculateArtistScore(artist, cand.artist) else null
            var score = if (artistScore != null) titleScore * 0.5 + artistScore * 0.5 else titleScore
            // 标题完全对不上重罚（对齐 LDDC：title_score < 30 → score -= 35）
            if (titleScore < 30) score = max(0.0, score - 35)
            if (score > MIN_SCORE) scored.add(Pair(score, cand))
        }
        if (scored.isEmpty()) return null
        // 分数降序；同分按源优先级 QQ → 酷狗（对齐 LDDC sources=(QM, KG)）
        scored.sortWith(
            compareByDescending<Pair<Double, LyricsCandidate>> { it.first }
                .thenBy { sourcePriority(it.second.source) }
        )
        // B：前 2 个候选取词并行发起（谁先成功用谁）；coroutineScope 结束时未完成协程自动取消
        val top = scored.take(2)
        return coroutineScope<List<LyricLine>?> {
            val deferreds = top.map { (_, cand) -> async { fetchOne(cand) } }
            for (d in deferreds) {
                val lines = d.await() ?: continue
                if (lines.size >= 6) return@coroutineScope lines
            }
            null
        }
    }

    /** 单个候选取词：取词 + 损坏校验；返回 ≥6 行歌词（带逐字时间，无则为空集合） */
    private suspend fun fetchOne(cand: LyricsCandidate): List<LyricLine>? {
        val lines = when (cand.source) {
            "kg" -> runCatching { fetchKgLines(cand) }.getOrNull()
            "qq" -> runCatching { fetchQqLines(cand) }.getOrNull()
            else -> null
        } ?: return null
        if (lines.isEmpty()) return null
        if (LyricsService.isBrokenLyrics(lines.joinToString("\n") { it.text })) return null
        return lines.takeIf { it.size >= 6 }
    }

    private fun sourcePriority(source: String): Int = when (source) {
        "qq" -> 0
        else -> 1
    }

    // ==================== 酷狗 KG：搜索全量候选 ====================
    private suspend fun searchKg(title: String, artist: String): List<LyricsCandidate> {
        val dfid = kgRegisterDfid() ?: "-"
        val mid = md5Hex(System.currentTimeMillis().toString())
        val searchParams = sortedMapOf<String, Any>(
            "sorttype" to "0",
            "keyword" to "$title $artist".trim(),
            "pagesize" to 20,
            "page" to 1,
        )
        val searchUrl = "http://complexsearch.kugou.com/v2/search/song?" + kgQuery(searchParams, "SearchSong", mid)
        val searchJson = runCatching {
            ApiClient.getJson(searchUrl, headers = kgHeaders("SearchSong", mid), timeoutSec = NET_TIMEOUT)
        }.getOrNull() ?: return emptyList()
        val lists = searchJson.optJSONObject("data")?.optJSONArray("lists") ?: return emptyList()
        val out = mutableListOf<LyricsCandidate>()
        for (i in 0 until lists.length()) {
            val it = lists.optJSONObject(i) ?: continue
            val name = it.optString("SongName", "").trim()
            val id = it.optString("ID", "")
            val hash = it.optString("FileHash", "")
            if (name.isBlank() || id.isBlank() || hash.isBlank()) continue
            val singers = runCatching {
                val arr = it.optJSONArray("Singers")
                (0 until (arr?.length() ?: 0)).joinToString("/") { j ->
                    arr?.optJSONObject(j)?.optString("name", "") ?: ""
                }
            }.getOrDefault("")
            out.add(LyricsCandidate("kg", name, singers, it.optInt("Duration", 0), kgId = id, kgHash = hash))
        }
        return out
    }

    /** 按已评分候选取酷狗歌词（Lyric 模块签名只含 appid/clientver + 业务参数）。
     * v2.1.79：contenttype!=2 的 KRC 直接解出**逐字时间**，不再压平成整行 LRC。 */
    private suspend fun fetchKgLines(cand: LyricsCandidate): List<LyricLine>? {
        val id = cand.kgId ?: return null
        val hash = cand.kgHash ?: return null
        val mid = md5Hex(System.currentTimeMillis().toString())
        val durMs = cand.durationSec.toLong() * 1000L
        val lrcParams = sortedMapOf<String, Any>(
            "album_audio_id" to id,
            "duration" to durMs,
            "hash" to hash,
            "keyword" to "${cand.artist} - ${cand.title}",
            "lrctxt" to "1",
            "man" to "no",
        )
        val lrcListUrl = "https://lyrics.kugou.com/v1/search?" + kgQuery(lrcParams, "Lyric", mid)
        val lrcListJson = runCatching {
            ApiClient.getJson(lrcListUrl, headers = kgHeaders("Lyric", mid), timeoutSec = NET_TIMEOUT)
        }.getOrNull() ?: return null
        val candidates = lrcListJson.optJSONArray("candidates") ?: return null
        if (candidates.length() == 0) return null
        val cand0 = candidates.optJSONObject(0) ?: return null
        val cid = cand0.optString("id", "")
        val accesskey = cand0.optString("accesskey", "")
        if (cid.isBlank() || accesskey.isBlank()) return null
        val dlParams = sortedMapOf<String, Any>(
            "accesskey" to accesskey,
            "charset" to "utf8",
            "client" to "mobi",
            "fmt" to "krc",
            "id" to cid,
            "ver" to "1",
        )
        val dlUrl = "http://lyrics.kugou.com/download?" + kgQuery(dlParams, "Lyric", mid)
        val dlJson = runCatching {
            ApiClient.getJson(dlUrl, headers = kgHeaders("Lyric", mid), timeoutSec = NET_TIMEOUT)
        }.getOrNull() ?: return null
        val content = dlJson.optString("content", "")
        if (content.isBlank()) return null
        val decoded = runCatching { Base64.getDecoder().decode(content) }.getOrNull() ?: return null
        // contenttype==2：content 为 base64 纯文本 LRC（无逐字时间）；否则为 KRC 加密数据（带逐字时间）
        return if (dlJson.optInt("contenttype", -1) == 2) {
            LyricsService.parseLrc(String(decoded, Charsets.UTF_8)).ifEmpty { null }
        } else {
            runCatching { LddcCrypto.krcDecrypt(decoded) }.getOrNull()?.let { plain ->
                LddcCrypto.krcToLines(plain).ifEmpty {
                    // 极端兜底：逐字解析失败但明文能压成整行 LRC
                    LyricsService.parseLrc(LddcCrypto.krcToLrc(plain))
                }
            }?.ifEmpty { null }
        }
    }

    private suspend fun kgRegisterDfid(): String? {
        // dfid 缓存 30 分钟（对齐 LDDC cache expire=1800）
        val now = System.currentTimeMillis()
        val cacheHit = cachedDfid
        if (cacheHit != null && now - cachedDfidAt < 30 * 60 * 1000L) return cacheHit
        val mid = md5Hex(now.toString())
        val values = listOf("1014", "4", mid).sorted()
        val signature = md5Hex("1014" + values.joinToString("") + "1014")
        val url = "https://userservice.kugou.com/risk/v1/r_register_dev?appid=1014&platid=4&mid=$mid&signature=$signature"
        val body = Base64.getEncoder().encodeToString("{\"uuid\":\"\"}".toByteArray())
        val resp = runCatching {
            ApiClient.post(url, body, headers = mapOf("Content-Type" to "text/plain"), timeoutSec = NET_TIMEOUT)
        }.getOrNull() ?: return null
        val dfid = runCatching {
            JSONObject(resp).optJSONObject("data")?.optString("dfid", "")?.takeIf { it.isNotEmpty() }
        }.getOrNull() ?: return null
        cachedDfid = dfid
        cachedDfidAt = now
        return dfid
    }

    private fun kgHeaders(module: String, mid: String): Map<String, String> = mapOf(
        "User-Agent" to "Android14-1070-11070-201-0-$module-wifi",
        "Connection" to "Keep-Alive",
        "KG-Rec" to "1",
        "KG-RC" to "1",
        "KG-CLIENTTIMEMS" to System.currentTimeMillis().toString(),
        "mid" to mid,
        // 注意：不设 Accept-Encoding —— OkHttp 手动设置后不会自动解压 gzip，会导致响应解析失败
    )

    /** 酷狗签名参数生成。module==Lyric 只含 appid+clientver+业务参数；其余含完整公共参数（对齐 LDDC） */
    private fun kgQuery(extra: Map<String, Any>, module: String, mid: String): String {
        val params = sortedMapOf<String, Any>()
        params.putAll(extra)
        if (module == "Lyric") {
            params["appid"] = "3116"
            params["clientver"] = "11070"
        } else {
            params["userid"] = "0"
            params["appid"] = "3116"
            params["token"] = ""
            params["clienttime"] = System.currentTimeMillis() / 1000
            params["iscorrection"] = "1"
            params["uuid"] = "-"
            params["mid"] = mid
            params["dfid"] = "-"
            params["clientver"] = "11070"
            params["platform"] = "AndroidFilter"
        }
        val signature = md5Hex(KG_SALT + params.entries.joinToString("") { (k, v) -> "$k=$v" } + KG_SALT)
        return params.entries.joinToString("&") { (k, v) -> "$k=${urlEncode(v.toString())}" } + "&signature=$signature"
    }

    private fun md5Hex(s: String): String =
        MessageDigest.getInstance("MD5").digest(s.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    // ==================== QQ QM：搜索全量候选 ====================
    private fun qqComm(): JSONObject = JSONObject().apply {
        put("ct", 11); put("cv", "1003006"); put("v", "1003006")
        put("os_ver", "15"); put("phonetype", "24122RKC7C")
        put("rom", "Redmi/miro/miro:15/AE3A.240806.005/OS2.0.105.0.VOMCNXM:user/release-keys")
        put("tmeAppID", "qqmusiclight"); put("nettype", "NETWORK_WIFI"); put("udid", "0")
    }

    private suspend fun searchQq(title: String, artist: String): List<LyricsCandidate> {
        val comm = qqComm()
        qqEnsureSession(comm)
        val searchId = Random.nextInt(1, 20) * 18014398509481984L +
            Random.nextInt(0, 4194305) * 4294967296L +
            System.currentTimeMillis() % 86400000
        val searchData = qqRequest(comm, "DoSearchForQQMusicLite", "music.search.SearchCgiService", JSONObject().apply {
            put("search_id", searchId.toString())
            put("remoteplace", "search.android.keyboard")
            put("query", "$title $artist".trim())
            put("search_type", 0); put("num_per_page", 20); put("page_num", 1)
            put("highlight", 0); put("nqc_flag", 0); put("page_id", 1); put("grp", 1)
        }) ?: return emptyList()
        val items = searchData.optJSONObject("body")?.optJSONArray("item_song") ?: return emptyList()
        val out = mutableListOf<LyricsCandidate>()
        for (i in 0 until items.length()) {
            val it = items.optJSONObject(i) ?: continue
            val t = it.optString("title", "").trim()
            val qid = it.optString("id", "")
            if (t.isBlank() || qid.isBlank()) continue
            val singer = runCatching {
                it.optJSONArray("singer")?.optJSONObject(0)?.optString("name", "") ?: ""
            }.getOrDefault("")
            val album = runCatching {
                it.optJSONObject("album")?.optString("name", "") ?: ""
            }.getOrDefault("")
            out.add(LyricsCandidate("qq", t, singer, it.optInt("interval", 0),
                qqId = qid, qqSinger = singer, qqAlbum = album))
        }
        return out
    }

    /** 按已评分候选取 QQ 歌词（GetPlayLyricInfo → QRC 3DES 解密）。
     * v2.1.79：QRC 直接解出**逐字时间**；会话复用搜索阶段的缓存。 */
    private suspend fun fetchQqLines(cand: LyricsCandidate): List<LyricLine>? {
        val qid = cand.qqId ?: return null
        val comm = qqComm()
        qqEnsureSession(comm)
        val lyricData = qqRequest(comm, "GetPlayLyricInfo", "music.musichallSong.PlayLyricInfo", JSONObject().apply {
            put("albumName", b64(cand.qqAlbum ?: ""))
            put("crypt", 1); put("ct", 19); put("cv", 2111)
            put("interval", cand.durationSec.toLong())
            put("lrc_t", 0); put("qrc", 1); put("qrc_t", 0)
            put("roma", 1); put("roma_t", 0)
            put("singerName", b64(cand.qqSinger ?: cand.artist))
            put("songID", qid.toLongOrNull() ?: 0L)
            put("songName", b64(cand.title))
            put("trans", 1); put("trans_t", 0); put("type", 0)
        }) ?: return null
        val encryptedHex = lyricData.optString("lyric", "")
        // 对齐 LDDC：qrc_t ≠ 0 用 qrc_t，否则用 lrc_t；该值 != "0" 才解密
        val qrcT = lyricData.optInt("qrc_t", 0)
        val lrcT = lyricData.optString("lrc_t", "0")
        val effectiveT = if (qrcT != 0) qrcT.toString() else lrcT
        if (encryptedHex.isBlank() || effectiveT == "0") return null
        val plain = runCatching { LddcCrypto.qrcDecrypt(encryptedHex) }.getOrNull() ?: return null
        val words = LddcCrypto.qrcToLines(plain)
        if (words.isNotEmpty()) return words
        // 兜底：该曲只投了整行 LRC（无逐字），退化为行级时间
        return LyricsService.parseLrc(LddcCrypto.qrcToLrc(plain)).ifEmpty { null }
    }

    /** QQ 会话获取/复用：缓存命中直接注入 comm，未命中才发 GetSession（成功后缓存） */
    private suspend fun qqEnsureSession(comm: JSONObject) {
        val cached = cachedQqSession
        if (cached != null) {
            comm.put("uid", cached.optString("uid", ""))
            comm.put("sid", cached.optString("sid", ""))
            comm.put("userip", cached.optString("userip", ""))
            return
        }
        val sessionResp = qqRequest(comm, "GetSession", "music.getSession.session", JSONObject().apply {
            put("caller", 0); put("uid", "0"); put("vkey", 0)
        }) ?: return
        val session = sessionResp.optJSONObject("session") ?: return
        val snapshot = JSONObject()
            .put("uid", session.optString("uid", ""))
            .put("sid", session.optString("sid", ""))
            .put("userip", session.optString("userip", ""))
        cachedQqSession = snapshot
        comm.put("uid", snapshot.optString("uid", ""))
        comm.put("sid", snapshot.optString("sid", ""))
        comm.put("userip", snapshot.optString("userip", ""))
    }

    private suspend fun qqRequest(comm: JSONObject, method: String, module: String, param: JSONObject): JSONObject? {
        val body = JSONObject().apply {
            put("comm", comm)
            put("request", JSONObject().apply {
                put("method", method); put("module", module); put("param", param)
            })
        }.toString()
        val resp = runCatching {
            ApiClient.post(
                "https://u.y.qq.com/cgi-bin/musicu.fcg",
                body,
                headers = mapOf(
                    "Content-Type" to "application/json",
                    "Cookie" to "tmeLoginType=-1;",
                    // 注意：不设 Accept-Encoding —— OkHttp 手动设置后不会自动解压 gzip
                ),
                timeoutSec = NET_TIMEOUT,
            )
        }.getOrNull() ?: return null
        val json = runCatching { JSONObject(resp) }.getOrNull() ?: return null
        val request = json.optJSONObject("request") ?: return null
        if (json.optInt("code", -1) != 0 || request.optInt("code", -1) != 0) return null
        return request.optJSONObject("data")
    }

    private fun b64(s: String): String = Base64.getEncoder().encodeToString(s.toByteArray(Charsets.UTF_8))
}

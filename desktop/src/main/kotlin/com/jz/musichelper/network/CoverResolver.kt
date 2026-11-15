package com.jz.musichelper.network

import com.jz.musichelper.data.AppEnv
import com.jz.musichelper.model.Song
import kotlinx.coroutines.async
import org.json.JSONArray
import org.json.JSONObject

// 封面三级兜底第 2 级：本平台无封面时，用「同歌名 + 同歌手」去 QQ 搜索复用其封面。
// 约束：只兜无封面歌曲；异步执行；结果进内存 + SharedPreferences 持久化（跨会话免重复请求）；
// 命中后由调用方（SongCover）直接换图展示，不做占位→真图的闪烁动画。
object CoverResolver {

    private const val PREFS = "jz_music_prefs"
    private const val KEY = "cover_qq_cache"
    private const val MAX = 300
    private const val MAX_CONCURRENT = 3            // 全局并发上限：首屏大量无封面卡不产生请求风暴
    private val mem = java.util.concurrent.ConcurrentHashMap<String, String>()
    // 同 key 进行中去重：同一首歌只发起一次 QQ 搜索，其余调用共享结果
    private val inFlight = java.util.concurrent.ConcurrentHashMap<String, kotlinx.coroutines.Deferred<String?>>()
    private val gate = java.util.concurrent.Semaphore(MAX_CONCURRENT)
    private val ioScope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO)

    private val prefsLoaded = java.util.concurrent.atomic.AtomicBoolean(false)

    fun ensureInit() {
        if (prefsLoaded.get()) return
        synchronized(this) {
            if (prefsLoaded.get()) return
            prefsLoaded.set(true)
            val prefs = AppEnv.prefs("$PREFS")
            runCatching {
                val arr = JSONArray(prefs.getString(KEY, null) ?: "[]")
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    val k = o.optString("k")
                    val v = o.optString("v")
                    if (k.isNotEmpty() && v.isNotEmpty()) mem[k] = v
                }
            }
        }
    }

    private fun keyOf(song: Song): String = "${song.name}|${song.singer}"

    /** 返回可复用封面 URL；song 已有封面时直接返回原值。失败/未命中返回 null（由 UI 落本地占位） */
    suspend fun resolve(song: Song): String? {
        // 2.0.1：酷狗旧版 imgessl album_id 路径（v1.9.9 之前历史/缓存产物）已被 CDN 软失败（HTTP 200+固定黑胶），
        // 一律判死：忽略原 URL，强制走 QQ 同歌名+歌手兜底换真封面
        val legacyDead = song.platform == com.jz.musichelper.model.MusicPlatform.KUGOU &&
            song.picUrl?.contains("imgessl", ignoreCase = true) == true
        if (!song.picUrl.isNullOrBlank() && !legacyDead) return song.picUrl
        return resolveIgnoringPic(song)
    }

    /** ④ 修复：忽略原 picUrl（原图加载失败场景），强制走 QQ 同歌名+歌手复用兜底 */
    suspend fun resolveForce(song: Song): String? = resolveIgnoringPic(song)

    private suspend fun resolveIgnoringPic(song: Song): String? {
        val key = keyOf(song)
        mem[key]?.let { return it }
        // 进行中共享：同 key 并发只发一次 QQ 搜索
        inFlight[key]?.let { return it.await() }
        val d = ioScope.async {
            gate.acquire()
            try {
                // 未命中缓存：去 QQ 按「歌名+歌手」搜；2.0.0 严格匹配（歌名相等 + 歌手任一片段相等），
                // QQ 无精确结果时返回 null，不再拿模糊首条张冠李戴；超时放宽到 5s（弱网更稳）
                val url = runCatching {
                    kotlinx.coroutines.withTimeout(5000) {
                        val r = QQSearchAdapter().search("${song.name} ${song.singer}", 10)
                        val songSingers = song.singer.split('/').map { it.trim() }.filter { it.isNotEmpty() }
                        r.firstOrNull { x ->
                            !x.picUrl.isNullOrBlank() &&
                                x.name.trim().equals(song.name.trim(), ignoreCase = true) &&
                                x.singer.split('/').map { it.trim() }.any { xs ->
                                    songSingers.any { it.equals(xs, ignoreCase = true) }
                                }
                        }?.picUrl
                    }
                }.getOrNull()
                if (!url.isNullOrBlank()) {
                    mem[key] = url
                    persist()
                }
                url
            } finally {
                gate.release()
            }
        }
        inFlight[key] = d
        return try { d.await() } finally { inFlight.remove(key, d) }
    }

    private fun persist() {
        if (!prefsLoaded.get()) return
        val arr = JSONArray()
        mem.entries.toList().takeLast(MAX).forEach { (k, v) -> arr.put(JSONObject().put("k", k).put("v", v)) }
        AppEnv.prefs("$PREFS").edit().putString(KEY, arr.toString()).apply()
    }
}

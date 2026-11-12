package com.jz.musichelper.data

import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import com.jz.musichelper.model.DownloadItem
import com.jz.musichelper.model.DownloadStatus
import com.jz.musichelper.model.QualityLevel
import com.jz.musichelper.model.SearchHistoryItem
import com.jz.musichelper.model.Song
import org.json.JSONArray
import org.json.JSONObject

// 历史与偏好存储：SharedPreferences + JSON（收藏/下载为 Compose 响应式内存事实源，改动即时持久化并联动所有界面）
object HistoryStore {

    private const val PREFS = "jz_music_prefs"
    private const val KEY_SEARCH_HISTORY = "search_history"
    private const val KEY_RECENT_SONGS = "recent_songs"
    private const val KEY_DOWNLOADS = "downloads"
    private const val KEY_QUALITY = "quality"
    private const val KEY_THEME = "theme"
    private const val KEY_PLAY_MODE = "play_mode"
    private const val KEY_FAVORITES = "favorites"
    // v2.1.84：识曲历史 + 识曲时长
    private const val KEY_REC_HISTORY = "rec_history"
    private const val KEY_REC_SECONDS = "rec_seconds"

    private lateinit var prefs: android.content.SharedPreferences
    private val maxSearchHistory = 20
    private val maxRecentSongs = 50

    /** 识曲历史上限：与底层栏「历史」的 maxRecentSongs 对齐（50 条） */
    const val REC_HISTORY_MAX = 50

    // 识曲历史条数与底层栏「历史」一致（用户口径：历史存多少，识曲历史就存多少）
    private val maxRecHistory = REC_HISTORY_MAX

    /** 识曲时长默认值（秒），与 VoiceCapture.DEFAULT_SECONDS 对齐 */
    private const val DEFAULT_REC_SECONDS = 12

    // 收藏 / 下载内存事实源（SnapshotStateList）：任何界面增删后，所有读取处自动重组
    val favoritesState: SnapshotStateList<Song> = mutableStateListOf()
    val downloadsState: SnapshotStateList<DownloadItem> = mutableStateListOf()

    fun init(context: Context) {
        prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        favoritesState.clear()
        favoritesState.addAll(loadFavoritesFromPrefs())
        downloadsState.clear()
        downloadsState.addAll(loadDownloadsFromPrefs())
    }

    // ---------- 搜索历史 ----------

    fun loadSearchHistory(): List<SearchHistoryItem> {
        val raw = prefs.getString(KEY_SEARCH_HISTORY, null) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                SearchHistoryItem(o.optString("keyword"), o.optLong("createdAt"))
            }
        }.getOrDefault(emptyList())
    }

    fun recordSearch(keyword: String) {
        val kw = keyword.trim()
        if (kw.isEmpty()) return
        val list = loadSearchHistory().filterNot { it.keyword == kw }
        val newList = listOf(SearchHistoryItem(kw, System.currentTimeMillis())) + list
        val trimmed = newList.take(maxSearchHistory)
        saveSearchHistory(trimmed)
    }

    fun clearSearchHistory() {
        prefs.edit().remove(KEY_SEARCH_HISTORY).apply()
    }

    private fun saveSearchHistory(list: List<SearchHistoryItem>) {
        val arr = JSONArray()
        list.forEach { arr.put(JSONObject().put("keyword", it.keyword).put("createdAt", it.createdAt)) }
        prefs.edit().putString(KEY_SEARCH_HISTORY, arr.toString()).apply()
    }

    // ---------- 最近歌曲 ----------

    fun loadRecentSongs(): List<Song> {
        val raw = prefs.getString(KEY_RECENT_SONGS, null) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { i -> songFromJson(arr.getJSONObject(i)) }
        }.getOrDefault(emptyList())
    }

    fun recordSong(song: Song) {
        val list = loadRecentSongs().filterNot {
            it.platform == song.platform && it.platformID == song.platformID
        }
        val newList = listOf(song) + list
        val trimmed = newList.take(maxRecentSongs)
        val arr = JSONArray()
        trimmed.forEach { arr.put(songToJson(it)) }
        prefs.edit().putString(KEY_RECENT_SONGS, arr.toString()).apply()
    }

    // ---------- 下载记录（响应式内存事实源）----------

    fun loadDownloadItems(): List<DownloadItem> = downloadsState

    fun saveDownloadItems(items: List<DownloadItem>) {
        downloadsState.clear()
        downloadsState.addAll(items)
        persistDownloads()
    }

    private fun loadDownloadsFromPrefs(): List<DownloadItem> {
        val raw = prefs.getString(KEY_DOWNLOADS, null) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { i -> itemFromJson(arr.getJSONObject(i)) }
        }.getOrDefault(emptyList())
    }

    private fun persistDownloads() {
        val arr = JSONArray()
        downloadsState.forEach { arr.put(itemToJson(it)) }
        prefs.edit().putString(KEY_DOWNLOADS, arr.toString()).apply()
    }

    // ---------- 识曲历史（v2.1.84）----------

    /**
     * 识曲历史：退出 App 再进来仍在。
     * 之前只存在内存里（AppState.recRecent），进程一结束就清空——用户反馈"退出后历史没了"。
     * 条数与底层栏「历史」一致（50 条），同一首歌（歌名+歌手相同）只留最新一条。
     */
    fun loadRecHistory(): List<com.jz.musichelper.network.RecognizeAdapter.Hit> {
        val raw = prefs.getString(KEY_REC_HISTORY, null) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                val title = o.optString("title")
                if (title.isBlank()) return@mapNotNull null
                com.jz.musichelper.network.RecognizeAdapter.Hit(
                    title = title,
                    artist = o.optString("artist"),
                    album = o.optString("album")
                )
            }
        }.getOrDefault(emptyList()).take(maxRecHistory)
    }

    fun saveRecHistory(list: List<com.jz.musichelper.network.RecognizeAdapter.Hit>) {
        val arr = JSONArray()
        list.take(maxRecHistory).forEach {
            arr.put(
                JSONObject()
                    .put("title", it.title)
                    .put("artist", it.artist)
                    .put("album", it.album)
            )
        }
        prefs.edit().putString(KEY_REC_HISTORY, arr.toString()).apply()
    }

    // ---------- 识曲时长（v2.1.91：12/15/20 秒，默认 12；旧的 5/10 一律归到 12）----------

    fun loadRecSeconds(): Int {
        val v = prefs.getInt(KEY_REC_SECONDS, DEFAULT_REC_SECONDS)
        return if (v == 12 || v == 15 || v == 20) v else DEFAULT_REC_SECONDS
    }

    fun saveRecSeconds(seconds: Int) {
        prefs.edit().putInt(KEY_REC_SECONDS, seconds).apply()
    }

    // ---------- 设置 ----------

    fun saveQuality(q: QualityLevel) {
        prefs.edit().putString(KEY_QUALITY, q.name).apply()
    }

    fun loadQuality(): QualityLevel {
        val name = prefs.getString(KEY_QUALITY, null) ?: return QualityLevel.HIGH
        return runCatching { QualityLevel.valueOf(name) }.getOrDefault(QualityLevel.HIGH)
    }

    // ---------- 主题 ----------

    fun loadTheme(): String {
        return prefs.getString(KEY_THEME, null) ?: "NIGHTINGALE"
    }

    fun saveTheme(name: String) {
        prefs.edit().putString(KEY_THEME, name).apply()
    }

    // ---------- 播放模式 ----------

    fun savePlayMode(mode: String) {
        prefs.edit().putString(KEY_PLAY_MODE, mode).apply()
    }

    fun loadPlayMode(): String {
        return prefs.getString(KEY_PLAY_MODE, null) ?: "LIST_LOOP"
    }

    // ---------- 收藏（响应式内存事实源）----------

    fun loadFavorites(): List<Song> = favoritesState

    private fun loadFavoritesFromPrefs(): List<Song> {
        val raw = prefs.getString(KEY_FAVORITES, null) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { i -> songFromJson(arr.getJSONObject(i)) }
        }.getOrDefault(emptyList())
    }

    fun saveFavorites(list: List<Song>) {
        favoritesState.clear()
        favoritesState.addAll(list)
        persistFavorites()
    }

    private fun persistFavorites() {
        val arr = JSONArray()
        favoritesState.forEach { arr.put(songToJson(it)) }
        prefs.edit().putString(KEY_FAVORITES, arr.toString()).apply()
    }

    fun isFavorite(song: Song): Boolean =
        favoritesState.any { it.platform == song.platform && it.platformID == song.platformID }

    fun toggleFavorite(song: Song): Boolean {
        val exists = favoritesState.any { it.platform == song.platform && it.platformID == song.platformID }
        if (exists) {
            favoritesState.removeAll { it.platform == song.platform && it.platformID == song.platformID }
        } else {
            favoritesState.add(0, song)
        }
        persistFavorites()
        return !exists
    }

    // ---------- JSON 序列化 ----------

    private fun songToJson(s: Song): JSONObject = JSONObject()
        .put("platform", s.platform.name)
        .put("platformID", s.platformID)
        .put("name", s.name)
        .put("singer", s.singer)
        .put("album", s.album)
        .put("durationSec", s.durationSec)
        .put("picUrl", s.picUrl)

    private fun songFromJson(o: JSONObject): Song {
        val platform = com.jz.musichelper.model.MusicPlatform.valueOf(o.optString("platform", "QQ"))
        return Song(
            platform = platform,
            platformID = o.optString("platformID"),
            name = o.optString("name"),
            singer = o.optString("singer"),
            album = o.optString("album"),
            durationSec = o.optInt("durationSec"),
            picUrl = o.optString("picUrl").takeIf { it.isNotEmpty() && it != "null" }
        )
    }

    private fun itemToJson(it: DownloadItem): JSONObject = JSONObject()
        .put("id", it.id)
        .put("song", songToJson(it.song))
        .put("streamUrl", it.streamUrl)
        .put("backendName", it.backendName)
        .put("quality", it.quality.name)
        .put("fileName", it.fileName)
        .put("status", it.status.name)
        .put("progress", it.progress)
        .put("receivedBytes", it.receivedBytes)
        .put("totalBytes", it.totalBytes)
        .put("createdAt", it.createdAt)
        .put("errorMessage", it.errorMessage)
        .put("localPath", it.localPath)
        .put("requestedQuality", it.requestedQuality.name)
        .put("note", it.note)

    private fun itemFromJson(o: JSONObject): DownloadItem = DownloadItem(
        id = o.optString("id"),
        song = songFromJson(o.optJSONObject("song") ?: JSONObject()),
        streamUrl = o.optString("streamUrl"),
        backendName = o.optString("backendName"),
        quality = runCatching { QualityLevel.valueOf(o.optString("quality", "HIGH")) }.getOrDefault(QualityLevel.HIGH),
        fileName = o.optString("fileName"),
        status = runCatching { DownloadStatus.valueOf(o.optString("status", "PENDING")) }.getOrDefault(DownloadStatus.PENDING),
        progress = o.optDouble("progress", 0.0).toFloat(),
        receivedBytes = o.optLong("receivedBytes"),
        totalBytes = o.optLong("totalBytes"),
        createdAt = o.optLong("createdAt"),
        errorMessage = o.optString("errorMessage").takeIf { it.isNotEmpty() && it != "null" },
        localPath = o.optString("localPath").takeIf { it.isNotEmpty() && it != "null" },
        // v2.1.64：老数据没有这两个字段——requestedQuality 回落到实际档位，note 留空
        requestedQuality = runCatching {
            QualityLevel.valueOf(o.optString("requestedQuality", o.optString("quality", "HIGH")))
        }.getOrDefault(QualityLevel.HIGH),
        note = o.optString("note").takeIf { it.isNotEmpty() && it != "null" }
    )
}

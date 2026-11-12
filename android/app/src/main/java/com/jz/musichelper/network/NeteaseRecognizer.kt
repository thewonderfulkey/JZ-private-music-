package com.jz.musichelper.network

import org.json.JSONObject
import java.net.URLEncoder

/**
 * v2.1.91：网易云识曲通道（免费、无需 key）。
 *
 * 协议（桌面实测确认 2026-11）：
 *  · POST https://interface.music.163.com/api/music/audio/match，form-urlencoded
 *  · sessionId 用官方浏览器扩展的固定值；algorithmCode=shazam_v2（网易对自家指纹的算法名）
 *  · rawdata = 端上 afp.wasm 生成的指纹（NeteaseFingerprint），duration=12
 *  · code=200 + data.noMatchReason=0 才是命中，>0 一律当"没识别到"，不报错
 *
 * 与酷狗互补：酷狗给 8k 裸 PCM、中文元数据；这一路要 12s + 本地指纹，返回中文元数据，
 * 但没有可播直链——播放仍走现有跨平台搜索（与酷狗命中完全同一套）。
 */
object NeteaseRecognizer {

    private const val ENDPOINT = "https://interface.music.163.com/api/music/audio/match"
    private const val SESSION_ID = "441df692-afea-4a54-8aff-f5f20fd34f12"
    private const val CHROME_UA =
        "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/124.0.0.0 Mobile Safari/537.36"

    /**
     * @param fingerprint 端上生成的指纹 base64
     * @return 命中的候选（最多 5 条，未做变体过滤，交给 Judge 排序）
     */
    suspend fun recognize(fingerprint: String, seconds: Int = NeteaseFingerprint.WINDOW_SECONDS): List<RecognizeAdapter.Hit> {
        if (fingerprint.isBlank()) return emptyList()
        val body = listOf(
            "sessionId" to SESSION_ID,
            "algorithmCode" to "shazam_v2",
            "duration" to seconds.toString(),
            "rawdata" to fingerprint,
            "times" to "2",
            "decrypt" to "1"
        ).joinToString("&") { (k, v) -> "$k=${URLEncoder.encode(v, "UTF-8")}" }

        val resp = ApiClient.postForm(
            url = ENDPOINT,
            body = body,
            headers = mapOf(
                "User-Agent" to CHROME_UA,
                "Accept" to "application/json",
                "Origin" to "chrome-extension://pgphbbekcgpfaekhcbjamjjkegcclhhd"
            ),
            timeoutSec = 20
        )
        return parse(resp)
    }

    private fun parse(resp: String): List<RecognizeAdapter.Hit> {
        val root = runCatching { JSONObject(resp) }.getOrNull() ?: return emptyList()
        if (root.optInt("code", -1) != 200) return emptyList()
        val data = root.optJSONObject("data") ?: return emptyList()
        // noMatchReason 用字符串/数字都可能，统一按字符串比对"0"
        val reason = data.opt("noMatchReason")?.toString().orEmpty()
        if (reason.isNotEmpty() && reason != "0") return emptyList()
        val arr = data.optJSONArray("result") ?: return emptyList()

        val out = ArrayList<RecognizeAdapter.Hit>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val song = o.optJSONObject("song") ?: continue
            val title = song.optString("name", "").trim()
            if (title.isEmpty()) continue
            val artists = song.optJSONArray("artists")
            val artist = if (artists != null && artists.length() > 0) {
                (0 until artists.length())
                    .mapNotNull { artists.optJSONObject(it)?.optString("name", "")?.trim() }
                    .filter { it.isNotEmpty() }
                    .joinToString("、")
            } else ""
            val album = song.optJSONObject("album")?.optString("name", "").orEmpty().trim()
            if (out.any { it.title == title && it.artist == artist }) continue
            out.add(RecognizeAdapter.Hit(title, artist, album))
            if (out.size >= 5) break
        }
        return out
    }
}

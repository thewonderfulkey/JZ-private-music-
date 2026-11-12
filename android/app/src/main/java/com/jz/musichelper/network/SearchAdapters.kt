package com.jz.musichelper.network

import com.jz.musichelper.model.MusicPlatform
import com.jz.musichelper.model.Song
import org.json.JSONArray
import org.json.JSONObject

// 搜索适配器：每个平台一个实现
interface SearchAdapter {
    val platform: MusicPlatform
    suspend fun search(keyword: String, limit: Int): List<Song>
}

// ---------- QQ 音乐搜索 ----------
// https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=10&w=关键词&format=json
class QQSearchAdapter : SearchAdapter {
    override val platform = MusicPlatform.QQ

    override suspend fun search(keyword: String, limit: Int): List<Song> {
        val url = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=$limit&w=${urlEncode(keyword)}&format=json"
        val json = ApiClient.getJson(url, headers = mapOf("Referer" to "https://y.qq.com/"))
        val list = json.optJSONObject("data")?.optJSONObject("song")?.optJSONArray("list") ?: JSONArray()
        val songs = mutableListOf<Song>()
        for (i in 0 until list.length()) {
            val item = list.optJSONObject(i) ?: continue
            val songname = item.optString("songname") ?: continue
            val songmid = item.optString("songmid") ?: continue
            if (songname.isEmpty() || songmid.isEmpty()) continue
            val singers = (item.optJSONArray("singer") ?: JSONArray()).let { arr ->
                buildString {
                    for (j in 0 until arr.length()) {
                        if (j > 0) append("/")
                        append(arr.optJSONObject(j)?.optString("name") ?: "")
                    }
                }
            }
            val album = item.optString("albumname", "")
            val dur = item.optInt("interval", 0)
            val albumMid = item.optString("albummid", "")
            val pic = if (albumMid.isNotEmpty()) "https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg" else null
            songs.add(Song(MusicPlatform.QQ, songmid, songname, singers, album, dur, pic))
        }
        return songs
    }
}

// ---------- 网易云搜索 ----------
// 2026-10-31 实测：老接口 /api/search/get/web?csrf_token= 已被风控（code=405），改用 /api/search/get（code=200）
class NeteaseSearchAdapter : SearchAdapter {
    override val platform = MusicPlatform.NETEASE

    override suspend fun search(keyword: String, limit: Int): List<Song> {
        val url = "https://music.163.com/api/search/get?s=${urlEncode(keyword)}&type=1&offset=0&limit=$limit"
        val json = ApiClient.getJson(url, headers = mapOf("Referer" to "https://music.163.com/"))
        if (json.optInt("code") != 200) return emptyList()
        val list = json.optJSONObject("result")?.optJSONArray("songs") ?: JSONArray()
        val songs = mutableListOf<Song>()
        for (i in 0 until list.length()) {
            val item = list.optJSONObject(i) ?: continue
            val id = item.optLong("id", -1)
            val name = item.optString("name", "")
            if (id <= 0 || name.isEmpty()) continue
            val artists = (item.optJSONArray("artists") ?: JSONArray()).let { arr ->
                buildString {
                    for (j in 0 until arr.length()) {
                        if (j > 0) append("/")
                        append(arr.optJSONObject(j)?.optString("name") ?: "")
                    }
                }
            }
            val albumObj = item.optJSONObject("album")
            val album = albumObj?.optString("name", "") ?: ""
            val durMs = item.optLong("duration", 0)
            // 封面：/api/search/get 只返回 picId 无 picUrl，且 p1.music.126.net/{picId}.jpg 实测全 404（死路）
            // → 置空交给第 2 级「QQ 同歌名+歌手复用」，QQ 也找不到才落本地渐变占位
            songs.add(Song(MusicPlatform.NETEASE, id.toString(), name, artists, album, (durMs / 1000).toInt(), null))
        }
        return songs
    }
}

// ---------- 酷我搜索 ----------
// https://search.kuwo.cn/r.s?all=关键词&ft=music&rn=10&pn=1&rformat=json&encoding=utf8
// 注意：返回的是 Python 风格单引号 dict 文本（非标准 JSON），需特殊解析
class KuwoSearchAdapter : SearchAdapter {
    override val platform = MusicPlatform.KUWO

    override suspend fun search(keyword: String, limit: Int): List<Song> {
        // v2.1.10：酷我 r.s 必须带老客户端参数 vipver=MUSIC_8.7.8.0_WX——
        // 不带时对歌手查询返回集为 UGC 翻唱/节目/DJ（实测"蔡健雅" rn=50 全 50 条无原曲、翻 5 页 0 原曲），
        // 带后头部即官方原曲（实测 rn=20 保留 16 条原曲：无底洞/陌生人/思念/纪念/抛物线等）；
        // rn 保持 20 + 相关性过滤（歌手/歌名含词 + 变体剔除）
        val rn = minOf(limit, 20)
        val url = "https://search.kuwo.cn/r.s?all=${urlEncode(keyword)}&ft=music&rn=$rn&pn=1&rformat=json&encoding=utf8&vipver=MUSIC_8.7.8.0_WX"
        val text = ApiClient.get(url, headers = mapOf("Referer" to "https://www.kuwo.cn/"))
        val records = extractAbsList(text)
        // v2.1.88：相关性过滤改为「大小写 + 空白不敏感」。酷我返回的标题是 "IVORY TOWER(...)" 与 "Ivory Tower"
        // 混排，原来直接 name.contains(kw)：用户输小写时整平台一条都匹配不上，界面就表现为"酷我 0 条"。
        val kw = loose(keyword)
        val songs = mutableListOf<Song>()
        for (item in records) {
            val name = item["SONGNAME"]?.trim().orEmpty()
            val rawRid = item["MUSICRID"].orEmpty().replace("MUSIC_", "")
            if (name.isEmpty() || rawRid.isEmpty()) continue
            val artist = item["ARTIST"].orEmpty()
            // 相关性过滤：仅保留歌手或歌名含搜索词、且非变体标记的原曲（伴奏/KTV/现场/DJ 等一律剔除）
            if (kw.isNotEmpty() && !loose(name).contains(kw) && !loose(artist).contains(kw)) continue
            if (isKuwoVariant(name)) continue
            val album = item["ALBUM"].orEmpty()
            val dur = parseDuration(item["DURATION"].orEmpty())
            // v2.1.87：MVPIC 是酷我曲图路径（形如 324/s4s36/41/926857763.jpg），直接拼 img1 的 wmvpic 出图；
            // 该字段实测约 78% 有值（60 条抽样 47 条有），空值仍交给 CoverResolver 走 QQ 兜底。
            val mvpic = item["MVPIC"]?.trim().orEmpty().trimStart('/')
            val pic = if (mvpic.isNotEmpty()) "https://img1.kuwo.cn/wmvpic/$mvpic" else null
            songs.add(Song(MusicPlatform.KUWO, rawRid, name, artist, album, dur, pic))
        }
        return songs
    }

    /** 相关性比较用的宽松归一化：小写 + 多空白压成一个 + 去首尾（v2.1.88） */
    private fun loose(s: String): String = s.lowercase().replace(Regex("\\s+"), " ").trim()

    /** 酷我变体标记：伴奏/KTV/现场/DJ/Live/翻唱/MV/纯音乐/串烧/合唱/网友改编/咚鼓版等（匿名搜索头部以变体为主） */
    private fun isKuwoVariant(name: String): Boolean {
        val s = name.lowercase()
        return listOf(
            "伴奏", "ktv", "现场", "dj", "live", "翻唱", "纯音乐", "钢琴",
            "remix", "串烧", "mv版", "合唱", "网友改编", "咚鼓"
        ).any { s.contains(it) }
    }

    /** 从 Python 单引号 dict 文本中抽取 abslist 记录 */
    private fun extractAbsList(text: String): List<Map<String, String>> {
        val absIdx = text.indexOf("'abslist'")
        if (absIdx < 0) return emptyList()
        val rest = text.substring(absIdx)
        val open = rest.indexOf('[')
        val close = rest.lastIndexOf(']')
        if (open < 0 || close <= open) return emptyList()
        val listText = rest.substring(open, close + 1)
        val chunks = splitTopLevel(listText)
        return chunks.mapNotNull { parseSingleQuotedDict(it) }
    }

    private fun splitTopLevel(s: String): List<String> {
        val inner = s.removePrefix("[").removeSuffix("]")
        var depth = 0
        var current = StringBuilder()
        val chunks = mutableListOf<String>()
        for (ch in inner) {
            when (ch) {
                '[', '{' -> depth++
                ']', '}' -> depth--
                ',' -> if (depth == 0) {
                    val c = current.toString()
                    if (c.isNotBlank()) chunks.add(c)
                    current = StringBuilder()
                } else current.append(ch)
                else -> current.append(ch)
            }
        }
        if (current.toString().isNotBlank()) chunks.add(current.toString())
        return chunks
    }

    /** 解析单引号键值对：'key':'value' */
    private fun parseSingleQuotedDict(text: String): Map<String, String>? {
        val trimmed = text.trim()
        if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) return null
        val inner = trimmed.removePrefix("{").removeSuffix("}")
        val map = mutableMapOf<String, String>()
        val regex = Regex("'([^']*)':\\s*'((?:[^'\\\\]|\\\\.)*)'")
        regex.findAll(inner).forEach { m ->
            val key = m.groupValues[1]
            var value = m.groupValues[2].replace("\\'", "'")
            // 酷我 r.s 里标题/专辑带 HTML 实体，不还原就会变成 "IVORY&nbsp;TOWER"，相关性比较整条漏掉
            value = value.replace("&nbsp;", " ").replace("&amp;", "&")
                .replace("&quot;", "\"").replace("&#39;", "'")
                .replace("&lt;", "<").replace("&gt;", ">")
            map[key] = value
        }
        return map.ifEmpty { null }
    }

    private fun parseDuration(s: String): Int {
        val parts = s.split(":")
        return when (parts.size) {
            2 -> parts[0].toIntOrNull()?.times(60)?.plus(parts[1].toIntOrNull() ?: 0) ?: 0
            3 -> {
                val h = parts[0].toIntOrNull() ?: 0
                val m = parts[1].toIntOrNull() ?: 0
                val sec = parts[2].toIntOrNull() ?: 0
                h * 3600 + m * 60 + sec
            }
            else -> 0
        }
    }
}

// ---------- 酷狗搜索 ----------
// https://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=关键词&page=1&pagesize=10&showtype=1
class KugouSearchAdapter : SearchAdapter {
    override val platform = MusicPlatform.KUGOU

    override suspend fun search(keyword: String, limit: Int): List<Song> {
        val url = "https://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=${urlEncode(keyword)}&page=1&pagesize=$limit&showtype=1"
        val json = ApiClient.getJson(url, headers = mapOf("Referer" to "https://www.kugou.com/"))
        val list = json.optJSONObject("data")?.optJSONArray("info") ?: JSONArray()
        val songs = mutableListOf<Song>()
        for (i in 0 until list.length()) {
            val item = list.optJSONObject(i) ?: continue
            val songname = item.optString("songname", "")
            val hash = item.optString("hash", "")
            if (songname.isEmpty() || hash.isEmpty()) continue
            val singer = item.optString("singername", "")
            val album = item.optString("album_name", "")
            val dur = item.optInt("duration", 0)
            val albumId = item.optLong("album_id", -1)
            // ④ 修复：优先用 API 实际返回的 trans_param.union_cover（实测 200 可用，{size} 占位 → 500，http→https）。
            // 2.0.1：删除 imgessl album_id 拼接兜底——实测该路径已被酷狗 CDN 软失败（HTTP 200 + 固定黑胶默认图 17853B），
            // 无 union_cover 时直接返回 null，由上层 CoverResolver 走 QQ 同歌名+歌手兜底换真封面
            val unionCover = item.optJSONObject("trans_param")?.optString("union_cover", "") ?: ""
            val pic = if (unionCover.isNotBlank()) unionCover.replace("{size}", "500").replace("http://", "https://") else null
            songs.add(Song(MusicPlatform.KUGOU, hash, songname, singer, album, dur, pic))
        }
        return songs
    }
}

internal fun urlEncode(s: String): String {
    return java.net.URLEncoder.encode(s, "UTF-8").replace("+", "%20")
}

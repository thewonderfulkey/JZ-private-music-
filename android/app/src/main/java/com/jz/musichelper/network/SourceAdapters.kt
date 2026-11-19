package com.jz.musichelper.network

import com.jz.musichelper.model.MusicPlatform
import com.jz.musichelper.model.QualityLevel
import com.jz.musichelper.model.Song
import com.jz.musichelper.model.StreamSource
import okhttp3.Request

// 取流校验 + 真实音质探测：一次 Range GET 同时回答两件事——
//  ① 这个 URL 到底是不是音频（而不是 HTML 落地页 / JSON 错误页）
//  ② 它是哪种容器、有多大（体积 + 时长就能算出真实码率）
// v2.1.48 为什么必须做：实测 oiapi 对 lossless / exhigh / standard 三档返回的是同一个 128k mp3，
// cyapi 只给 m4a 且实际 ~98kbps。只信接口自报的话，UI 就会"说能下无损、实际下到 128k"。
object StreamVerifier {

    /** 探测结果：真实容器名（flac/ogg/m4a/mp3/wav/unknown）+ 总字节数（服务端没给 Content-Range 时为 0） */
    data class AudioFacts(val container: String, val totalBytes: Long)

    suspend fun inspect(urlString: String, timeoutSec: Long = 8): AudioFacts? {
        return kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            try {
                val req = Request.Builder()
                    .url(urlString)
                    .header("Range", "bytes=0-4095")
                    .header("User-Agent", ApiClient.MOBILE_UA)
                    .header("Referer", refererFor(urlString))
                    .build()
                ApiClient.client.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful && resp.code != 206) return@withContext null
                    val ct = resp.header("Content-Type")?.lowercase() ?: ""
                    val cr = resp.header("Content-Range") ?: ""
                    // v2.1.49：服务端忽略 Range 直接回 200 时没有 Content-Range，此时 Content-Length 就是总长。
                    // 少了这一步，totalBytes 恒为 0 → kbps 恒为 0 → 一律被判成 128k（"选了无损变标准"的另一条路径）
                    val total = cr.substringAfterLast('/', "").toLongOrNull()
                        ?: resp.header("Content-Length")?.toLongOrNull()
                        ?: 0L
                    // v2.1.49：只读容器头 16 字节。原来 bytes() 会把整个响应体吃下来——万一服务端忽略 Range
                    // 回 200，这里就要下载几十 MB 的 FLAC，8s 超时直接失败，反倒让"有无损"被判成"没源"
                    val body = resp.body
                    val head = if (body == null) ByteArray(0)
                    else runCatching { body.source().readByteArray(16) }.getOrElse { ByteArray(0) }
                    val container = sniffHead(head)
                    // 容器头认得出就按音频算；Content-Type 只作辅助（部分 CDN 会返回 octet-stream / text/plain）
                    val looksAudio = ct.startsWith("audio/") || ct.contains("octet-stream") || container != "unknown"
                    if (!looksAudio) return@withContext null
                    AudioFacts(container, total)
                }
            } catch (_: Exception) {
                null
            }
        }
    }

    /**
     * r122：按域名给 Referer——以前所有源都发 music.qq.com，126.net / 酷我 CDN 偶尔因此回 403。
     * iOS 侧同名实现见 StreamVerifier.referer(forHost:)。
     */
    fun refererFor(urlString: String): String {
        val host = runCatching { java.net.URI(urlString).host?.lowercase() ?: "" }.getOrDefault("")
        return when {
            host.contains("126.net") || host.contains("163.com") -> "https://music.163.com/"
            host.contains("kuwo") -> "https://www.kuwo.cn/"
            host.contains("kugou") -> "https://m.kugou.com/"
            host.contains("qq.com") || host.contains("gtimg") -> "https://y.qq.com/"
            else -> "https://music.qq.com/"
        }
    }

    suspend fun isAudioUrl(urlString: String, timeoutSec: Long = 8): Boolean =
        inspect(urlString, timeoutSec) != null

    /** v2.1.64：读本地文件头判容器——下载完成后按"体积 + 容器"复核档位时用（不再只看服务端自报） */
    fun sniffFileHead(file: java.io.File): String = runCatching {
        java.io.RandomAccessFile(file, "r").use { raf ->
            val b = ByteArray(16)
            val n = raf.read(b, 0, 16)
            if (n <= 0) "unknown" else sniffHead(if (n == 16) b else b.copyOf(n))
        }
    }.getOrDefault("unknown")

    /**
     * 前 16 字节容器头判定真实容器；认不出回 unknown（HTML / JSON 错误页会落到这里）。
     *
     * r120（iOS《연애의 조건》事故同步修这里）：126.net 的部分 fLaC 前面挂了一段 ID3v2 标签，
     * 真正的 `fLaC` 不在偏移 0。只认偏移 0 会把它判成 "unknown → mp3"，
     * 档位跟着掉成 320k、下载弹层显示"没有无损"。现在在整段头里找特征串。
     */
    fun sniffHead(b: ByteArray): String {
        fun at(i: Int): Byte = if (b.size > i) b[i] else 0.toByte()
        fun eq(c: Char, i: Int): Boolean = at(i) == c.code.toByte()
        fun has(s: String, from: Int = 0): Boolean {
            val bytes = s.toByteArray(Charsets.US_ASCII)
            if (b.size < from + bytes.size) return false
            for (k in bytes.indices) if (at(from + k) != bytes[k]) return false
            return true
        }
        // 1) 容器特征串：标准位置 + 任意偏移都算（ID3v2 前缀后面才是真容器）。
        //    顺序很重要：**先**找真实容器——"ID3" 只说明前面挂了标签，不代表就是 mp3。
        if (has("fLaC")) return "flac"
        if (has("OggS")) return "ogg"
        if (has("RIFF")) return "wav"
        if (b.size >= 8 && has("ftyp", 4)) return "m4a"
        for (offset in 1 until b.size) {
            if (has("fLaC", offset)) return "flac"
            if (has("OggS", offset)) return "ogg"
            if (has("RIFF", offset)) return "wav"
            if (has("ftyp", offset)) return "m4a"
        }
        // 2) 认不出容器才看标签 / 帧同步
        if (b.size >= 3 && has("ID3")) return "mp3"
        if (b.size >= 2 && at(0) == 0xFF.toByte() &&
            (at(1) == 0xFB.toByte() || at(1) == 0xF3.toByte() ||
                at(1) == 0xF2.toByte() || at(1) == 0xFA.toByte())) return "mp3"
        return "unknown"
    }
}

// 由容器与体积反推真实档位——接口自报的音质一律不信，只认探测到的事实
object QualityFacts {
    /** @return 真实档位 + 实际容器后缀（下载文件名据此生成，杜绝 ".flac 里装 mp3" 的坏文件） */
    fun of(facts: StreamVerifier.AudioFacts, durationSec: Int): Pair<QualityLevel, String> {
        val ext = extOf(facts.container)
        // 无损容器不需要算码率就能定档
        if (facts.container == "flac" || facts.container == "wav") return QualityLevel.LOSSLESS to ext
        val kbps = kbps(facts.totalBytes, durationSec)
        // r120：容器认不出但码率已是无损量级（CDN 改容器头 / 前面挂 ID3）→ 按无损标。
        // 与 matches() 的"无损：容器或 ≥601kbps"同一口径，避免"命中无损、界面显示 320k"。
        if (kbps >= 601) return QualityLevel.LOSSLESS to ext
        // 算不出码率时宁可往低标——"没有无损却标无损"正是这一版要消灭的问题
        return (if (kbps >= 256) QualityLevel.HIGH else QualityLevel.STANDARD) to ext
    }

    /** v2.1.64：容器 → 文件后缀 */
    fun extOf(container: String): String = when (container) {
        "flac" -> "flac"
        "wav" -> "wav"
        "m4a" -> "m4a"
        "ogg" -> "ogg"
        else -> "mp3"
    }

    /** 码率（kbps）：总字节 × 8 ÷ 时长。任一为 0 时回 0（表示算不出） */
    fun kbps(totalBytes: Long, durationSec: Int): Long =
        if (durationSec > 0 && totalBytes > 0) totalBytes * 8 / durationSec / 1000 else 0L

    /**
     * v2.1.64：目标档校验——按"容器 + 码率"判断这份音源/文件是不是用户选的那一档。
     * 这是三档共用的唯一口径：无损看容器，320k/128k 看码率区间（±容差），
     * 所以"选了 320k 下到 128k"这类问题会在这里被判定为不匹配，交给上层换源。
     *
     * 区间（按常见编码实测取值，宁可放宽一点也别把真货判成假货）：
     *  - 无损：flac / wav 容器；容器认不出但码率 ≥600k 也认（个别 CDN 会把头截掉）
     *  - 高品 320k：256–600k（不含无损容器）
     *  - 标准 128k：48–255k（不含无损容器）
     * kbps = 0 表示算不出（时长缺失或服务端没给长度）→ 一律不算命中，由上层按业务决定降级与否。
     */
    fun matches(want: QualityLevel, container: String, kbps: Long): Boolean {
        val isLosslessContainer = container == "flac" || container == "wav"
        return when (want) {
            QualityLevel.LOSSLESS -> isLosslessContainer || kbps >= 600
            QualityLevel.HIGH -> !isLosslessContainer && kbps in 256..600
            QualityLevel.STANDARD -> !isLosslessContainer && kbps in 48..255
        }
    }
}

// 取流后端：给定歌曲与音质，返回可用流地址
interface StreamSourceAdapter {
    val name: String
    val platform: MusicPlatform
    suspend fun resolve(song: Song, quality: QualityLevel): StreamSource
}

// ---------- QQ 系 ----------

// cyapi.top QQ 直链
class CyapiQQAdapter : StreamSourceAdapter {
    override val name = "cyapi QQ"
    override val platform = MusicPlatform.QQ

    override suspend fun resolve(song: Song, quality: QualityLevel): StreamSource {
        val url = "https://cyapi.top/API/qq_music.php?apikey=1ffdf5733f5d538760e63d7e46ba17438d9f7b9dfc18c51be1109386fd74c3a1&type=json&mid=${song.platformID}"
        val json = ApiClient.getJson(url, headers = mapOf("Referer" to "https://y.qq.com/"), timeoutSec = 12)
        val stream = json.optString("url", "")
        if (stream.isEmpty()) throw ApiError.Parse("cyapi 未返回 URL")
        val facts = StreamVerifier.inspect(stream) ?: throw ApiError.HTTP(0)
        // v2.1.48：不再恒标高品——实测 cyapi 给的是 ~98kbps m4a，按探测事实标注
        val (q, fmt) = QualityFacts.of(facts, song.durationSec)
        return StreamSource(stream, name, platform, q, fmt, "VIP 全量 $fmt（实测标注）", directId = true,
            kbps = QualityFacts.kbps(facts.totalBytes, song.durationSec), totalBytes = facts.totalBytes)
    }
}

// ---------- 网易云系 ----------

// gdstudio 网易
class GdstudioNeteaseAdapter : StreamSourceAdapter {
    override val name = "gdstudio 网易"
    override val platform = MusicPlatform.NETEASE

    override suspend fun resolve(song: Song, quality: QualityLevel): StreamSource {
        val br = when (quality) {
            QualityLevel.STANDARD -> "128"
            QualityLevel.HIGH -> "320"
            QualityLevel.LOSSLESS -> "740"
        }
        val url = "https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest&need_sec_link=1&sec_link_scene=im&theme=light&types=url&source=netease&id=${song.platformID}&br=$br"
        val json = ApiClient.getJson(url, headers = mapOf("User-Agent" to "LX-Music-Mobile"), timeoutSec = 12)
        val stream = json.optString("url", "")
        if (stream.isEmpty()) throw ApiError.Parse("gdstudio 未返回 URL")
        val facts = StreamVerifier.inspect(stream) ?: throw ApiError.HTTP(0)
        // v2.1.48：format / 档位一律按实际返回判定——不再"请求 flac 就把返回标成 flac"。
        // 实测本通道是诚实分档的（br=740 得 fLaC 容器、800~1490kbps），但标注不能靠假设
        val (q, fmt) = QualityFacts.of(facts, song.durationSec)
        return StreamSource(stream, name, platform, q, fmt, "VIP 全量 mp3/FLAC（实测标注）", directId = true,
            kbps = QualityFacts.kbps(facts.totalBytes, song.durationSec), totalBytes = facts.totalBytes)
    }
}

// oiapi Music_163（溯音 key 版，K×H v1.7.17 实测可用通道：网易「演员」290ms 返回 m801 官方直链）
// v2.1.8：按 K×H 移植增强——补 key/type/level/n=1 参数，音质档位映射 standard/exhigh/lossless
class OiapiNeteaseAdapter : StreamSourceAdapter {
    override val name = "oiapi 网易"
    override val platform = MusicPlatform.NETEASE

    override suspend fun resolve(song: Song, quality: QualityLevel): StreamSource {
        val level = quality.levelName()
        val url = "https://oiapi.net/api/Music_163?key=oiapi-ef6133b7-ac2f-dc7d-878c-d3e207a82575&type=json&level=$level&n=1&id=${song.platformID}"
        val json = ApiClient.getJson(url, timeoutSec = 12)
        if (json.optInt("code") != 0) throw ApiError.Parse("oiapi 网易 code != 0")
        var stream: String? = null
        val data = json.optJSONArray("data")
        if (data != null && data.length() > 0) {
            stream = data.optJSONObject(0)?.optString("url", "")
        }
        if (stream.isNullOrEmpty()) stream = json.optString("url", "")
        if (stream.isNullOrEmpty()) throw ApiError.Parse("oiapi 网易未返回 URL")
        val facts = StreamVerifier.inspect(stream) ?: throw ApiError.HTTP(0)
        // v2.1.48：实测本通道 level 三档返回同一个 128k mp3（字节数完全一致），
        // 原来"请求 lossless 就标 flac"正是假无损的来源——改为按事实标注
        val (q, fmt) = QualityFacts.of(facts, song.durationSec)
        return StreamSource(stream, name, platform, q, fmt, "ID 直查（溯音 key 版，实测标注）", directId = true,
            kbps = QualityFacts.kbps(facts.totalBytes, song.durationSec), totalBytes = facts.totalBytes)
    }
}

// ---------- 酷我系 ----------

// 妖狐酷我（K×H v1.7.17 实测可用通道：酷我「夜曲」484ms 返回 car-er.kuwo.cn 官方无损直链）
// v2.1.8：按 K×H 移植。按歌名搜索取流（与已废弃的 oiapi 酷我同为"搜索式"），
// 但返回 kuwo.cn 官方 CDN 直链且必须通过歌名/歌手身份匹配才放行，不匹配即丢弃（用户要求绝对准确）
class YaohuKuwoAdapter : StreamSourceAdapter {
    override val name = "妖狐酷我"
    override val platform = MusicPlatform.KUWO

    override suspend fun resolve(song: Song, quality: QualityLevel): StreamSource {
        // 与 K×H 同款拼接：歌名+歌手（无空格），如"夜曲周杰伦"
        val searchKey = (song.name + song.singer).trim()
        if (searchKey.isEmpty()) throw ApiError.Parse("妖狐酷我：无歌名")
        val encoded = java.net.URLEncoder.encode(searchKey, "UTF-8")
        val url = "https://api.yaohud.cn/api/music/kuwo?key=nvgKtvzw7CFSNFrDhA6&action=search&msg=$encoded&n=1"
        val json = ApiClient.getJson(url, headers = mapOf("X-Client-Software" to "lx"), timeoutSec = 12)
        if (json.optInt("code") != 200) throw ApiError.Parse("妖狐酷我 code != 200")
        val data = json.optJSONObject("data") ?: throw ApiError.Parse("妖狐酷我无 data")
        // 身份校验：搜索结果歌名/歌手必须与请求匹配，否则视为劣质候选直接丢弃
        // v2.1.29：改用 NameMatch 统一口径——多歌手串（"谭晶/陈奕迅"）与版本后缀歌名不再误杀
        val respSong = data.optString("songtitle", "").ifEmpty { data.optString("name", "") }
        val respSinger = data.optString("songname", "")
        val titleOk = NameMatch.titleMatches(song.name, NameMatch.yaohuTitle(respSong))
        val singerOk = NameMatch.singerMatches(song.singer, respSinger)
        if (!titleOk || !singerOk) throw ApiError.Parse("妖狐酷我结果不匹配：$respSong/$respSinger")
        // v2.1.49 版本防线：妖狐是"按歌名搜索"取流，会把 (Live)/现场/伴奏/翻唱/DJ 版一并搜出来。
        // 歌名段不是裸名（如"外婆 (Live)"）就当场拒绝——宁可不下，也不把别人的现场版当成原唱下给用户。
        val titlePart = NameMatch.yaohuTitle(respSong)
        if (!StudioPick.isCleanTitle(titlePart)) throw ApiError.Parse("妖狐酷我返回变体版本：$titlePart")
        val vm = data.optJSONObject("vipmusic") ?: throw ApiError.Parse("妖狐酷我无 vipmusic")
        val stream = vm.optString("url", "")
        if (stream.isEmpty()) throw ApiError.Parse("妖狐酷我未返回 URL")
        val facts = StreamVerifier.inspect(stream) ?: throw ApiError.HTTP(0)
        val declared = vm.optString("level", "")
        // v2.1.48：以容器事实为准（本通道实测自报与实际一致），level 只写进 note 备查
        val (q, fmt) = QualityFacts.of(facts, song.durationSec)
        return StreamSource(stream, name, platform, q, fmt, "官方直链（按歌名搜索，自报 $declared）", directId = false,
            kbps = QualityFacts.kbps(facts.totalBytes, song.durationSec), totalBytes = facts.totalBytes)
    }
}

// ---------- 酷狗 ----------

/**
 * v2.1.94：酷狗官方 playInfo（hash 直查）。
 * 实测 `https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=<HASH>` 匿名 200，
 * 直接给 sharefs.kugou.com 的音频直链（带短期签名，交给 StreamVerifier 校验容器与体积）。
 */
class KugouPlayInfoAdapter : StreamSourceAdapter {
    override val name = "酷狗官方"
    override val platform = MusicPlatform.KUGOU

    override suspend fun resolve(song: Song, quality: QualityLevel): StreamSource {
        val hash = song.platformID.trim()
        if (hash.isEmpty()) throw ApiError.Parse("酷狗：无 hash")
        val url = "https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=$hash"
        val json = ApiClient.getJson(
            url,
            headers = mapOf("Referer" to "https://m.kugou.com/"),
            timeoutSec = 12
        )
        val stream = json.optString("url", "")
        if (stream.isEmpty()) {
            throw ApiError.Parse("酷狗未返回 URL（付费/版权曲常如此，码 ${json.optInt("errcode", -1)}）")
        }
        // 与其它后端同口径：不信自报，用 Range 探测真实容器与体积
        val facts = StreamVerifier.inspect(stream) ?: throw ApiError.HTTP(0)
        val (q, fmt) = QualityFacts.of(facts, song.durationSec)
        return StreamSource(
            stream, name, platform, q, fmt, "酷狗官方 playInfo（hash 直查）", directId = false,
            kbps = QualityFacts.kbps(facts.totalBytes, song.durationSec),
            totalBytes = facts.totalBytes
        )
    }
}

// ---------- 后端注册表 ----------
object SourceRegistry {

    val all: List<StreamSourceAdapter> = listOf(
        CyapiQQAdapter(),
        GdstudioNeteaseAdapter(),
        OiapiNeteaseAdapter(),
        YaohuKuwoAdapter(),
        KugouPlayInfoAdapter()
    )

    // 某首歌可用的后端：同平台后端 + 跨平台搜索式后端
    // v2.1.8：oiapi 酷我（搜索式）已按用户要求废弃（实测返回劣质翻唱/伴奏且 time 字段失真）；
    // 酷我改由妖狐酷我（K×H 实测可用通道，官方直链+身份匹配校验）承担，注册在 all 中按平台命中
    fun adaptersFor(song: Song): List<StreamSourceAdapter> {
        val cross = emptyList<StreamSourceAdapter>()
        val result = mutableListOf<StreamSourceAdapter>()
        val seen = mutableSetOf<String>()
        for (a in all.filter { it.platform == song.platform } + cross) {
            if (seen.add(a.name)) result.add(a)
        }
        return result
    }
}

internal fun QualityLevel.levelName(): String = when (this) {
    QualityLevel.STANDARD -> "standard"
    QualityLevel.HIGH -> "exhigh"
    QualityLevel.LOSSLESS -> "lossless"
}

/**
 * v2.1.29：歌名/歌手归一化匹配（解析链路的身份校验统一口径）。
 * 解决两类"明明能解析却被跳过"的误杀：
 *  ① 多歌手串顺序/分隔符不一致（"谭晶/陈奕迅" vs "陈奕迅、谭晶" vs "谭晶 陈奕迅"）；
 *  ② 歌名带版本后缀（"富士山下（Live）""龙文 - Live"）与搜索结果裸歌名不同。
 * 口径：歌名去括号版本说明与标点后 相等，或长度差 ≤6 字且互相包含；歌手拆成单人 token 后取交集。
 */
internal object NameMatch {

    private val BRACKET = Regex("（[^）]*）|\\([^)]*\\)|\\[[^]]*]|【[^】]*】")
    private val PUNCT = Regex("[\\s·・\\-—_.,，、'\"“”‘’!！?？:：/\\\\&*+]")
    private val SINGER_SEP = Regex("[/&、,，\\s]+")

    /** 纯歌名归一化：去版本括号 + 去标点空白 */
    fun normTitle(raw: String): String = raw.trim().lowercase()
        .replace(BRACKET, "").replace(PUNCT, "")

    fun titleMatches(a: String, b: String): Boolean {
        val x = normTitle(a)
        val y = normTitle(b)
        if (x.isEmpty() || y.isEmpty()) return false
        return x == y || (kotlin.math.abs(x.length - y.length) <= 6 && (x.contains(y) || y.contains(x)))
    }

    /** 歌手拆分为单人 token（去括号说明、按 / & 、 ， 空格 拆） */
    fun singerTokens(raw: String): Set<String> = raw.trim().lowercase()
        .replace(BRACKET, "")
        .split(SINGER_SEP)
        .map { it.replace(PUNCT, "") }
        .filter { it.isNotEmpty() }
        .toSet()

    /** 歌手匹配：只要有一名共同歌手即视为同一曲（合唱/独唱版本差异交给时长校验兜底） */
    fun singerMatches(a: String, b: String): Boolean {
        val ta = singerTokens(a)
        val tb = singerTokens(b)
        if (ta.isEmpty() || tb.isEmpty()) return true          // 任一方无歌手信息时不拦
        if (ta.any { it in tb }) return true
        // 组合名整体包含（如 "凤凰传奇" vs "凤凰传奇/曾毅"）
        val sa = ta.joinToString("")
        val sb = tb.joinToString("")
        return sa.contains(sb) || sb.contains(sa)
    }

    /** 妖狐酷我返回的 songtitle 形如 "歌名 — 歌手 * 专辑"，取短横线/星号前的歌名段 */
    fun yaohuTitle(raw: String): String =
        raw.replace("—", "-").replace("–", "-").split("-", "*").firstOrNull()?.trim() ?: raw
}


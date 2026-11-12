package com.jz.musichelper.model

// 平台枚举
enum class MusicPlatform(val displayName: String, val shortName: String) {
    KUWO("酷我音乐", "酷我"),
    QQ("QQ音乐", "QQ"),
    NETEASE("网易云音乐", "网易"),
    KUGOU("酷狗音乐", "酷狗")
}

// 音质档位
enum class QualityLevel(val displayName: String) {
    STANDARD("标准 128k"),
    HIGH("高品 320k"),
    LOSSLESS("无损 FLAC")
}

// 歌曲模型：platformID 为对应平台歌曲 ID
// 酷我 rid（去掉 MUSIC_ 前缀）、QQ songmid、网易 songid、酷狗 hash
data class Song(
    val platform: MusicPlatform,
    val platformID: String,
    val name: String,
    val singer: String,
    val album: String,
    val durationSec: Int,
    val picUrl: String?
) {
    // 搜索关键字（歌名+歌手）；v2.1.8：妖狐酷我（K×H 移植通道）取流时使用"歌名+歌手"无空格拼接
    // （实测带空格会被服务端转成 "&" 返回错歌，故取流侧不用本属性，本属性仅供 UI 展示）
    val searchKeyword: String
        get() = if (name.isBlank()) "" else (name + " " + singer).trim()

    val durationText: String
        get() = if (durationSec <= 0) "--:--"
        else String.format("%02d:%02d", durationSec / 60, durationSec % 60)
}

// 一个可用流地址（后端解析出的可播放/可下载 URL）
// directId=true：按歌曲平台 ID 直连解析（QQ mid / 网易 id），身份可靠；false：搜索式取流（按歌名+歌手重新搜索），需配合身份校验
// v2.1.64：补 kbps / totalBytes——取流阶段已探测过真实体积，下载前就能按"体积+容器"预校验档位
data class StreamSource(
    val url: String,
    val backendName: String,
    val platform: MusicPlatform,
    val quality: QualityLevel,
    val format: String,
    val note: String,
    val directId: Boolean = false,
    val kbps: Long = 0,
    val totalBytes: Long = 0
)

// 下载状态
enum class DownloadStatus {
    PENDING, DOWNLOADING, COMPLETED, FAILED, CANCELLED
}

// 下载条目
data class DownloadItem(
    val id: String,
    val song: Song,
    val streamUrl: String,
    val backendName: String,
    val quality: QualityLevel,
    var fileName: String,
    var status: DownloadStatus,
    var progress: Float,
    var receivedBytes: Long,
    var totalBytes: Long,
    var createdAt: Long,
    var errorMessage: String? = null,
    var localPath: String? = null,
    // v2.1.64：requestedQuality = 用户在弹层里选的那一档（quality 会如实回填实际下到的档位）
    //  note = 完成后的一句话交代（"已校验 320k" / "该曲最高只有标准 128k，已降级保存"）
    var requestedQuality: QualityLevel = quality,
    var note: String? = null
) {
    val progressText: String
        get() = if (totalBytes <= 0) "--%" else String.format("%.0f%%", progress * 100)

    val sizeText: String
        get() {
            val mb = totalBytes / 1_000_000.0
            return if (mb >= 1) String.format("%.1f MB", mb) else ""
        }
}

// 搜索历史条目
data class SearchHistoryItem(val keyword: String, val createdAt: Long)

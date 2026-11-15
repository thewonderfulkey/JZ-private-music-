package com.jz.musichelper.data

import com.jz.musichelper.model.DownloadItem
import com.jz.musichelper.model.DownloadStatus
import com.jz.musichelper.model.QualityLevel
import com.jz.musichelper.model.Song
import com.jz.musichelper.model.StreamSource
import com.jz.musichelper.network.ApiClient
import com.jz.musichelper.network.ApiError
import com.jz.musichelper.network.DownloadResolver
import com.jz.musichelper.network.QualityFacts
import com.jz.musichelper.network.StreamVerifier
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

// 下载管理器：先解析候选（自动换源）+ 下载后按文件体积复核档位，再把合格文件写进公共 Music 目录
// App 切后台/锁屏不中断（全局作用域）；进程被杀则中断，可在下载页重试
object DownloadManager {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _items = MutableStateFlow<List<DownloadItem>>(emptyList())
    val items: StateFlow<List<DownloadItem>> = _items

    val activeJobs = mutableMapOf<String, Job>()

    // v2.1.64：目标档最多按清单逐条试几个音源（每条都要过一次体积校验）
    private const val MAX_VERIFY_ATTEMPTS = 3
    // 实收字节少于服务端声明的 95% → 视为截断，宁可不收
    private const val TRUNCATED_RATIO = 0.95

    fun init() {
        HistoryStore.init()
        _items.value = repairLocalPaths(HistoryStore.loadDownloadItems())
    }

    /**
     * 默认下载目录从「音乐\JZ Music」换成「安装目录\Download」后，老记录里的 localPath
     * 还指着旧地方。启动时按文件名在新默认目录里找一次：找到就把记录改过去，
     * 「打开所在文件夹 / 删除（含文件）」才不会指空。
     */
    private fun repairLocalPaths(items: List<DownloadItem>): List<DownloadItem> {
        if (items.isEmpty()) return items
        var changed = false
        val fixed = items.map { item ->
            val path = item.localPath
            if (path == null || File(path).exists()) return@map item
            val candidate = File(AppEnv.downloadDir, item.fileName)
            if (item.fileName.isNotBlank() && candidate.isFile) {
                changed = true
                item.copy(localPath = candidate.absolutePath)
            } else {
                item
            }
        }
        if (changed) runCatching { HistoryStore.saveDownloadItems(fixed) }
        return fixed
    }

    private fun sanitizeFileName(s: String): String =
        s.replace(Regex("[/\\\\:*?\"<>|]"), "_")

    private fun extensionFor(format: String, url: String): String {
        val f = format.lowercase()
        if (f.contains("flac")) return "flac"
        if (f.contains("m4a") || f.contains("aac")) return "m4a"
        if (f.contains("ogg")) return "ogg"
        if (f.contains("wav")) return "wav"
        if (f.contains("mp3")) return "mp3"
        val ext = url.substringAfterLast('.', "").take(5)
        if (ext.isNotEmpty() && !ext.contains('/')) return ext
        return "mp3"
    }

    private fun fileNameOf(song: Song, backend: String, ext: String): String =
        sanitizeFileName("${song.singer} - ${song.name} [$backend].$ext")

    /**
     * v2.1.64：入口改成"用户选的档位"，不再由 UI 先解析一条源再交进来。
     *
     * 这样做才能把"自动换源"和"按文件大小校验"闭环在一起：
     * 解析出多条候选 → 下一条 → 用文件体积/容器复核是否真是这档 → 不符就丢掉再换下一条。
     *
     * @param onMessage 一句话反馈（在 IO 线程回调，UI 自行切主线程）
     */
    fun startDownload(song: Song, want: QualityLevel, onMessage: (String) -> Unit = {}) {
        val id = UUID.randomUUID().toString()
        val item = DownloadItem(
            id = id,
            song = song,
            streamUrl = "",
            backendName = "",
            quality = want,
            requestedQuality = want,
            fileName = fileNameOf(song, song.platform.shortName, "mp3"),
            status = DownloadStatus.DOWNLOADING,
            progress = 0f,
            receivedBytes = 0,
            totalBytes = 0,
            createdAt = System.currentTimeMillis()
        )
        JzLog.i("JZ_DLM", "startDownload ${song.name} q=$want dir=${AppEnv.downloadDir}")
        appendItem(item)
        JzLog.i("JZ_DLM", "appendItem ok, launching job")
        activeJobs[id] = scope.launch {
            try {
                runDownload(id, song, want, onMessage)
            } catch (e: Exception) {
                updateItem(id) { it.copy(status = DownloadStatus.FAILED, errorMessage = e.message ?: "下载失败") }
                onMessage("《${song.name}》下载失败：${e.message ?: "未知错误"}")
            } finally {
                activeJobs.remove(id)
            }
        }
    }

    private data class Fetched(
        val source: StreamSource,
        val file: File,
        val bytes: Long,
        val container: String,
        val kbps: Long,
        val quality: QualityLevel,
        val ext: String
    )

    private suspend fun runDownload(id: String, song: Song, want: QualityLevel, onMessage: (String) -> Unit) {
        JzLog.i("JZ_DLM", "plan start ${song.name} q=$want")
        val plan = runCatching { DownloadResolver.plan(song, want) }
            .onFailure { JzLog.w("JZ_DLM", "plan failed: ${it.message}") }
            .getOrNull()
        JzLog.i("JZ_DLM", "plan done exact=${plan?.exact?.size} empty=${plan?.empty}")
        if (plan == null || plan.empty) {
            updateItem(id) { it.copy(status = DownloadStatus.FAILED, errorMessage = "暂无可用音源") }
            onMessage("《${song.name}》暂无可用音源")
            return
        }

        val rejects = mutableListOf<String>()
        // 被校验打回、但已是目前最高档的那份文件先留着：万一最后要降级，直接用它，不必重下一遍
        var keptBest: Fetched? = null
        // 一、逐条验证目标档候选；不合格的文件直接删除，换下一条
        for (src in plan.exact.take(MAX_VERIFY_ATTEMPTS)) {
            if (activeJobs[id]?.isActive == false) return
            val got = fetch(id, song, src)
            if (got == null) {
                rejects += "${src.backendName} 未能下载"
                continue
            }
            if (accepts(got, want, song.durationSec)) {
                keptBest?.file?.delete()
                complete(id, song, got, want, null, onMessage)
                return
            }
            rejects += "${src.backendName} 实测 ${got.kbps}kbps，不符合${want.displayName}"
            updateItem(id) {
                it.copy(
                    errorMessage = "换源中：${src.backendName} 实测 ${got.kbps}kbps，不符合${want.displayName}",
                    progress = 0f, receivedBytes = 0, totalBytes = 0
                )
            }
            val prev = keptBest
            if (prev == null || got.quality.ordinal > prev.quality.ordinal ||
                (got.quality == prev.quality && got.kbps > prev.kbps)
            ) {
                prev?.file?.delete()
                keptBest = got
            } else {
                got.file.delete()
            }
        }

        // 二、目标档一个都没过 → 如实降级到最高可得档（并把实际档位/原因写清楚）
        // 已经留着一份更高档的文件就直接用它，不再重复下载
        val kept = keptBest
        val fb = plan.fallback
        if (kept != null && (fb == null || kept.quality.ordinal > fb.quality.ordinal)) {
            val why = if (rejects.isEmpty()) {
                "该曲没有${want.displayName}音源，已按${kept.quality.displayName}保存"
            } else {
                "换源 ${rejects.size} 次仍未拿到${want.displayName}，已按${kept.quality.displayName}保存"
            }
            complete(id, song, kept, want, why, onMessage)
            return
        }
        kept?.file?.delete()
        if (fb != null) {
            updateItem(id) {
                it.copy(errorMessage = "目标档未命中，改用 ${fb.backendName}（${fb.quality.displayName}）")
            }
            val got = fetch(id, song, fb)
            if (got != null) {
                val why = if (rejects.isEmpty()) {
                    "该曲没有${want.displayName}音源，已按${got.quality.displayName}保存"
                } else {
                    "换源 ${rejects.size} 次仍未拿到${want.displayName}，已按${got.quality.displayName}保存"
                }
                complete(id, song, got, want, why, onMessage)
                return
            }
            rejects += "${fb.backendName} 未能下载"
        }

        updateItem(id) {
            it.copy(
                status = DownloadStatus.FAILED,
                errorMessage = rejects.joinToString("；").ifEmpty { "所有音源都没能下到合格文件" }
            )
        }
        onMessage("《${song.name}》下载失败：所有音源都没拿到合格文件")
    }

    /**
     * v2.1.64 的校验核心：文件已经完整落盘，用「容器头 + 体积换算码率」确认它是不是所选档。
     * 做到这一步才算数——取流阶段的自报与探测都可能和真实文件不一致。
     */
    private fun accepts(got: Fetched, want: QualityLevel, durationSec: Int): Boolean {
        // 时长与体积都有 → 按真实码率 + 容器判档，这是主路径
        if (durationSec > 0 && got.kbps > 0) return QualityFacts.matches(want, got.container, got.kbps)
        // 时长缺失（少数接口不给 duration）→ 无损至少得真是 flac/wav 容器，其余退回档位桶
        if (want == QualityLevel.LOSSLESS) return got.container == "flac" || got.container == "wav"
        return got.source.quality == want
    }

    /** 下载一条音源到临时文件；失败/截断返回 null（不写媒体库） */
    private suspend fun fetch(id: String, song: Song, src: StreamSource): Fetched? {
        val req = Request.Builder()
            .url(src.url)
            .header("User-Agent", "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Mobile Safari/604.1")
            .header("Referer", "https://music.qq.com/")
            .build()
        val resp = runCatching { ApiClient.client.newCall(req).execute() }.getOrNull() ?: return null
        if (!resp.isSuccessful) {
            resp.close()
            return null
        }
        val total = resp.body?.contentLength() ?: 0L
        updateItem(id) {
            it.copy(
                streamUrl = src.url,
                backendName = src.backendName,
                quality = src.quality,
                fileName = fileNameOf(song, src.backendName, extensionFor(src.format, src.url)),
                totalBytes = total,
                receivedBytes = 0,
                progress = 0f
            )
        }

        // 先写临时文件（用 InputStream 标准 API，避免 okio 特殊 API）
        val tmpFile = File(AppEnv.cacheDir, "dl_${id}_${System.nanoTime()}.part")
        var downloaded = 0L
        try {
            resp.body!!.byteStream().use { input ->
                val sink = FileOutputStream(tmpFile).buffered()
                val buf = ByteArray(64 * 1024)
                var lastPublish = 0L
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    sink.write(buf, 0, n)
                    downloaded += n
                    // 进度刷新节流：每 150ms 一次即可（原来每 64KB 刷一次，桌面端会把
                    // Compose 的快照写放大成每秒上百次，白白拖慢 UI 线程）
                    val now = System.currentTimeMillis()
                    if (now - lastPublish >= 150) {
                        lastPublish = now
                        val p = if (total > 0) downloaded.toFloat() / total else 0f
                        updateItem(id) { it.copy(receivedBytes = downloaded, progress = p.coerceIn(0f, 1f)) }
                    }
                }
                val p = if (total > 0) downloaded.toFloat() / total else 0f
                updateItem(id) { it.copy(receivedBytes = downloaded, progress = p.coerceIn(0f, 1f)) }
                sink.flush()
                sink.close()
            }
        } catch (e: Exception) {
            resp.close()
            tmpFile.delete()
            return null
        } finally {
            runCatching { resp.close() }
        }

        if (downloaded <= 0) {
            tmpFile.delete()
            return null
        }
        // 截断防线：服务端声明了总长而实收明显不足 → 这份文件本身就是坏的，不算数
        if (total > 0 && downloaded < total * TRUNCATED_RATIO) {
            tmpFile.delete()
            updateItem(id) { it.copy(errorMessage = "实收 ${downloaded}B / 声明 ${total}B，文件不完整") }
            return null
        }

        val container = StreamVerifier.sniffFileHead(tmpFile)
        val kbps = QualityFacts.kbps(downloaded, song.durationSec)
        val (quality, ext) = QualityFacts.of(StreamVerifier.AudioFacts(container, downloaded), song.durationSec)
        return Fetched(src, tmpFile, downloaded, container, kbps, quality, ext)
    }

    /** 校验通过（或降级接受）→ 落进媒体库并如实写档位/说明 */
    private suspend fun complete(
        id: String,
        song: Song,
        got: Fetched,
        want: QualityLevel,
        note: String?,
        onMessage: (String) -> Unit
    ) {
        val fileName = fileNameOf(song, got.source.backendName, got.ext)
        val verified = note == null
        val finalPath = runCatching { saveToPublicMusic(got.file, fileName) }.getOrNull()
        got.file.delete()
        if (finalPath == null) {
            updateItem(id) { it.copy(status = DownloadStatus.FAILED, errorMessage = "写入媒体库失败") }
            onMessage("《${song.name}》写入媒体库失败")
            return
        }
        updateItem(id) {
            it.copy(
                status = DownloadStatus.COMPLETED,
                progress = 1f,
                fileName = fileName,
                quality = got.quality,
                localPath = finalPath,
                receivedBytes = got.bytes,
                totalBytes = got.bytes,
                errorMessage = null,
                note = note ?: "已按体积校验：${got.container.uppercase()} / ${got.kbps}kbps，符合${want.displayName}"
            )
        }
        onMessage(
            if (verified) "已完成《${song.name}》${want.displayName}（体积校验 ${got.kbps}kbps）"
            else "已保存《${song.name}》${got.quality.displayName}（所选 ${want.displayName} 未命中，$note）"
        )
    }

    // 桌面版：直接写进系统「音乐」目录下的 JZ音乐助手\（%USERPROFILE%\Music\JZ音乐助手）。
    // 与 Android 的 MediaStore 写入等价——文件落在用户能找到的标准位置，不进 App 私有目录。
    private fun saveToPublicMusic(tmpFile: File, fileName: String): String {
        val dir = AppEnv.downloadDir.apply { mkdirs() }
        val dest = File(dir, fileName)
        tmpFile.copyTo(dest, overwrite = true)
        return dest.absolutePath
    }

    private fun mimeFor(fileName: String): String = when (fileName.substringAfterLast('.', "").lowercase()) {
        "flac" -> "audio/flac"
        "m4a" -> "audio/mp4"
        "ogg" -> "audio/ogg"
        "wav" -> "audio/wav"
        else -> "audio/mpeg"
    }

    fun cancel(id: String) {
        activeJobs[id]?.cancel()
        updateItem(id) { it.copy(status = DownloadStatus.CANCELLED) }
        activeJobs.remove(id)
    }

    /** 已删除的 id 墓碑：防止下载任务的收尾回调把记录又加回来 */
    private val removedIds = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    fun remove(id: String, deleteFile: Boolean) {
        JzLog.i("JZ_DLM", "remove id=$id deleteFile=$deleteFile")
        removedIds.add(id)
        val item = _items.value.find { it.id == id } ?: return
        if (deleteFile) {
            // 文件可能正被系统/播放器占用，删不掉也只当尽力而为——记录一定要移除，
            // 否则用户点了"删除"却没反应（之前就是这么把界面点崩的）
            item.localPath?.let { path -> runCatching { File(path).delete() } }
        }
        _items.value = _items.value.filterNot { it.id == id }
        JzLog.i("JZ_DLM", "removed from state, persisting")
        runCatching { HistoryStore.saveDownloadItems(_items.value) }
        JzLog.i("JZ_DLM", "persisted")
    }


    /** v2.1.64：重试不再复用可能已失效的 streamUrl，按原选中档位重新走一遍换源 + 体积校验 */
    fun retry(id: String) {
        val item = _items.value.find { it.id == id } ?: return
        val newId = UUID.randomUUID().toString()
        val newItem = item.copy(
            id = newId,
            streamUrl = "",
            status = DownloadStatus.DOWNLOADING,
            quality = item.requestedQuality,
            progress = 0f,
            receivedBytes = 0,
            totalBytes = 0,
            errorMessage = null,
            note = null,
            localPath = null
        )
        appendItem(newItem)
        activeJobs[newId] = scope.launch {
            try {
                runDownload(newId, item.song, item.requestedQuality) {}
            } catch (e: Exception) {
                updateItem(newId) { it.copy(status = DownloadStatus.FAILED, errorMessage = e.message ?: "下载失败") }
            } finally {
                activeJobs.remove(newId)
            }
        }
    }

    private fun appendItem(item: DownloadItem) {
        // 已被用户删掉的 id 不允许再被"迟到的任务回调"加回来
        if (removedIds.contains(item.id)) return
        _items.value = listOf(item) + _items.value
        HistoryStore.saveDownloadItems(_items.value)
    }

    private fun updateItem(id: String, transform: (DownloadItem) -> DownloadItem) {
        if (removedIds.contains(id)) return
        _items.value = _items.value.map {
            if (it.id == id) transform(it) else it
        }
        HistoryStore.saveDownloadItems(_items.value)
    }
}

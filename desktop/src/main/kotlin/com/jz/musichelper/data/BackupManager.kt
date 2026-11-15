package com.jz.musichelper.data

import com.jz.musichelper.model.DownloadStatus
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 一键备份：把「设置 + 收藏 + 历史 + 下载记录」做成一份可带走的快照放进 `Backup\`。
 *
 * 音乐文件本身不复制（体积大，而且 `Download\` 本来就是可见目录，直接拷走即可），
 * 但会导出一份 `已下载.m3u` 歌单和 `我的收藏.txt`——换机后能直接交给任意播放器。
 *
 * 备份目录跟着 [AppEnv.backupDir] 走：安装版是 `<安装目录>\Backup`。
 */
object BackupManager {

    data class Result(val dir: File, val copied: Int, val songs: Int)

    fun backupNow(): Result? = runCatching {
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val root = File(AppEnv.backupDir, "backup-$stamp").apply { mkdirs() }

        // 1) 配置与记录：Data\prefs_*.json 原样拷一份
        val data = File(root, "Data").apply { mkdirs() }
        var copied = 0
        AppEnv.dataDir.listFiles()?.filter { it.isFile && it.name.endsWith(".json") }?.forEach { f ->
            runCatching {
                f.copyTo(File(data, f.name), overwrite = true)
                copied++
            }
        }

        // 2) 已下载歌单：只收文件还在的（路径写绝对路径，播放器能直接打开）
        val m3u = StringBuilder("#EXTM3U\r\n")
        var songs = 0
        DownloadManager.items.value
            .filter { it.status == DownloadStatus.COMPLETED }
            .forEach { item ->
                val path = item.localPath?.let { File(it) } ?: File(AppEnv.downloadDir, item.fileName)
                if (!path.isFile) return@forEach
                m3u.append("#EXTINF:-1,").append(item.song.singer).append(" - ").append(item.song.name).append("\r\n")
                m3u.append(path.absolutePath).append("\r\n")
                songs++
            }
        File(root, "已下载.m3u").writeText(m3u.toString())

        // 3) 收藏清单（收藏是线上曲目，没有本地文件，导成文本方便找回）
        val favText = StringBuilder()
        HistoryStore.loadFavorites().forEachIndexed { i, s ->
            favText.append(i + 1).append(". ").append(s.name).append(" - ").append(s.singer).append("\r\n")
        }
        File(root, "我的收藏.txt").writeText(favText.toString().ifEmpty { "（还没有收藏）\r\n" })

        // 4) 说明：怎么恢复
        File(root, "备份说明.txt").writeText(
            buildString {
                appendLine("JZ Music 数据备份")
                appendLine("时间：${Date()}")
                appendLine("程序版本：${versionName()}")
                appendLine()
                appendLine("这份备份里有：")
                appendLine("  Data\\          设置、收藏、播放历史、下载记录（prefs_*.json）")
                appendLine("  已下载.m3u     已下载歌曲的播放列表（绝对路径，共 $songs 首）")
                appendLine("  我的收藏.txt   收藏清单")
                appendLine()
                appendLine("恢复方法：")
                appendLine("  1. 关掉 JZ Music；")
                appendLine("  2. 把 Data\\ 里的 prefs_*.json 拷回 <安装目录>\\Data\\（覆盖同名文件）；")
                appendLine("  3. 把 Download\\ 里的音乐放回 <安装目录>\\Download\\；")
                appendLine("  4. 重新打开 JZ Music，收藏/历史/下载记录就都回来了。")
            }
        )
        Result(root, copied, songs)
    }.onFailure { JzLog.w("JZ_BACKUP", "backup failed: $it") }.getOrNull()

    private fun versionName(): String = runCatching {
        val cfg = File(AppEnv.installDir ?: File("."), "app/JZ Music.cfg")
        if (cfg.isFile) {
            cfg.readLines().firstOrNull { it.trimStart().startsWith("app.version") }?.substringAfter("=")?.trim()
                ?: "2.1.95"
        } else "2.1.95"
    }.getOrDefault("2.1.95")
}

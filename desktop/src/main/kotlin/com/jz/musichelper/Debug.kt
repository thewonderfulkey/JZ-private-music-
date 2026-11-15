package com.jz.musichelper

import com.jz.musichelper.model.MusicPlatform
import com.jz.musichelper.model.Song
import com.jz.musichelper.network.KwLyrics
import com.jz.musichelper.network.LddcLyrics
import com.jz.musichelper.network.LyricsService
import com.jz.musichelper.network.SearchService
import com.jz.musichelper.network.StreamVerifier
import kotlinx.coroutines.runBlocking

/**
 * 桌面版诊断入口（不进分发包界面，用 Gradle 任务跑）：
 *   gradle debugRun -Pargs="search 周深"
 *   gradle debugRun -Pargs="lyrics 红豆#方大同#QQ"
 *   gradle debugRun -Pargs="song Red+Bean#方大同#QQ#000xxx#专辑#240"
 *   gradle debugRun -Pargs="probe <音频URL>"
 */
fun main(args: Array<String>) = runBlocking {
    when (val mode = args.firstOrNull() ?: "help") {
        "search" -> {
            val kw = args.getOrNull(1) ?: "周深"
            val t0 = System.currentTimeMillis()
            val results = SearchService.searchAll(kw, 50)
            println("SEARCH kw=$kw  (${System.currentTimeMillis() - t0}ms)")
            results.forEach { r ->
                println("  ${r.platform.name.padEnd(8)} songs=${r.songs.size} error=${r.error}")
                r.songs.take(3).forEach { s ->
                    println("      - ${s.name} / ${s.singer} / ${s.durationSec}s / id=${s.platformID}")
                }
            }
        }

        "lyrics" -> {
            val parts = (args.getOrNull(1) ?: "红豆#方大同#QQ").replace("|", "#").split("#").map { it.replace("+", " ") }
            val name = parts.getOrElse(0) { "" }
            val singer = parts.getOrElse(1) { "" }
            val plat = runCatching { MusicPlatform.valueOf(parts.getOrElse(2) { "QQ" }) }.getOrDefault(MusicPlatform.QQ)
            val pool = SearchService.searchAll("$name $singer", 20).flatMap { it.songs }
            val r = pool.filter { it.platform == plat }.sortedBy { if (it.name.contains(name, true)) 0 else 1 }
            println("candidates=${r.size}")
            val song = r.firstOrNull()
            if (song == null) {
                println("!! 没搜到条目，改用 song 模式直接给条目")
                return@runBlocking
            }
            probeLyrics(song)
        }

        "song" -> {
            // Windows 下 .bat 会把 | 当管道，所以分隔符用 #；也兼容 |
            val p = (args.getOrNull(1) ?: "").replace("|", "#").split("#").map { it.replace("+", " ") }
            val song = Song(
                platform = runCatching { MusicPlatform.valueOf(p.getOrElse(2) { "QQ" }) }.getOrDefault(MusicPlatform.QQ),
                platformID = p.getOrElse(3) { "" },
                name = p.getOrElse(0) { "" },
                singer = p.getOrElse(1) { "" },
                album = p.getOrElse(4) { "" },
                durationSec = p.getOrNull(5)?.toIntOrNull() ?: 0,
                picUrl = null
            )
            probeLyrics(song)
        }

        "probe" -> {
            val url = args.getOrNull(1) ?: return@runBlocking
            println("PROBE $url -> ${StreamVerifier.inspect(url)}")
        }

        else -> println(
            """
            用法：
              gradle debugRun -Pargs="search <关键词>"
              gradle debugRun -Pargs="lyrics <歌名>#<歌手>#<平台>"
              gradle debugRun -Pargs="song <歌名>#<歌手>#<平台>#<ID>#<专辑>#<秒>"
              gradle debugRun -Pargs="probe <音频URL>"
            """.trimIndent()
        )
    }
}

private suspend fun probeLyrics(song: Song) {
    println("SONG ${song.name} / ${song.singer} / ${song.platform} id=${song.platformID} dur=${song.durationSec}")
    val lddc = runCatching { LddcLyrics.fetch(song) }
    if (lddc.isFailure) {
        println("LDDC 异常: ${lddc.exceptionOrNull()}")
    }
    println("LDDC   -> lines=${lddc.getOrNull()?.size ?: "ERR"} first=${lddc.getOrNull()?.firstOrNull()?.text ?: "-"}")
    val kw = runCatching { KwLyrics.fetch(song.platformID) }
    println("KW(id) -> lines=${kw.getOrNull()?.size ?: "ERR"} first=${kw.getOrNull()?.firstOrNull()?.text ?: "-"}")
    val svc = runCatching { LyricsService.fetch(song) }
    println("SVC    -> lines=${svc.getOrNull()?.lines?.size ?: "null"} src=${svc.getOrNull()?.source ?: "-"} first=${svc.getOrNull()?.lines?.firstOrNull()?.text ?: "-"}")
}

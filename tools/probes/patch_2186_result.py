# -*- coding: utf-8 -*-
import io

p = r"JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper\ui\RecognizeScreen.kt"
src = io.open(p, encoding="utf-8").read()

start_mark = "/** 结果块："
end_mark = "/** 失败/无权限："
i = src.index(start_mark)
j = src.index(end_mark)

new = r'''/**
 * 结果块（v2.1.86 重做主结果版式）
 *
 * 版式口径：一张纸签（方角、纸色、1px 淡墨线）＋ 眉标「识 所 得」＋ 朱砂小印「识」；
 * 歌名走 28sp 霞鹜文楷、下面一段短墨线断开，"歌手／专辑"分层不当一行挤；
 * 主操作是一条墨底「播放这首歌」（唯一实心块），其余动作降级成文字链，不再并排两块矩形；
 * 「其他版本／同批候选」用"标签 + 贯通细线 + 条数"的书页式小标题，行与行之间只留发丝线。
 */
@Composable
private fun ResultBlock(
    hit: com.jz.musichelper.network.RecognizeAdapter.Hit?,
    others: List<com.jz.musichelper.network.RecognizeAdapter.Hit>,
    busy: Boolean,
    noExact: Boolean,
    note: String,
    versions: List<com.jz.musichelper.model.Song>,
    versionsBusy: Boolean,
    onPlay: (com.jz.musichelper.network.RecognizeAdapter.Hit) -> Unit,
    onAgain: () -> Unit,
    onLoadVersions: () -> Unit,
    onPlayVersion: (com.jz.musichelper.model.Song) -> Unit
) {
    val p = LocalPalette.current
    if (hit == null) return
    val artistTokens = hit.artist.split(Regex("[/、,，&·|]")).map { it.trim() }.filter { it.isNotBlank() }
    val artistLine = artistTokens.joinToString("、").ifBlank { "未知歌手" }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
    ) {
        // ---- 纸签本体 ----
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(p.surface)
                .border(1.dp, p.text.copy(alpha = 0.10f))
                .padding(start = 18.dp, end = 18.dp, top = 14.dp, bottom = 16.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "识 所 得",
                    fontSize = 10.5.sp,
                    letterSpacing = 3.sp,
                    color = p.text3
                )
                Spacer(Modifier.width(8.dp))
                Box(Modifier.width(26.dp).height(1.dp).background(p.text.copy(alpha = 0.22f)))
                Spacer(Modifier.weight(1f))
                SealMark("识")
            }
            Spacer(Modifier.height(12.dp))
            Text(
                hit.title,
                fontSize = 28.sp,
                lineHeight = 36.sp,
                fontFamily = InkTitleFont,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 0.5.sp,
                color = p.text,
                maxLines = 2
            )
            Spacer(Modifier.height(11.dp))
            Box(Modifier.width(28.dp).height(1.dp).background(p.text.copy(alpha = 0.30f)))
            Spacer(Modifier.height(10.dp))
            Text(
                artistLine,
                fontSize = 13.sp,
                lineHeight = 20.sp,
                color = p.text2,
                maxLines = 2
            )
            if (hit.album.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(
                    "《${hit.album}》",
                    fontSize = 11.sp,
                    lineHeight = 17.sp,
                    color = p.text3,
                    maxLines = 1
                )
            }
        }

        // 同名但没有这一位歌手的版本：先说清发生了什么（左侧一道朱砂细签，和"错误框"区分开）
        if (noExact && note.isNotBlank()) {
            Spacer(Modifier.height(12.dp))
            Row(modifier = Modifier.fillMaxWidth()) {
                Box(Modifier.width(2.dp).height(38.dp).background(p.heartOn.copy(alpha = 0.55f)))
                Spacer(Modifier.width(10.dp))
                Text(note, fontSize = 11.5.sp, lineHeight = 19.sp, color = p.text2)
            }
        }

        Spacer(Modifier.height(14.dp))

        // ---- 主操作：整条墨块，只此一处实心 ----
        val primaryText = when {
            noExact -> if (versionsBusy) "正在找其他版本…" else "看看其他版本"
            busy -> "正在起播…"
            else -> "播放这首歌"
        }
        val primaryEnabled = if (noExact) !versionsBusy else !busy
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(46.dp)
                .background(p.text.copy(alpha = if (primaryEnabled) 1f else 0.42f))
                .then(
                    if (primaryEnabled)
                        Modifier.inkClickable { if (noExact) onLoadVersions() else onPlay(hit) }
                    else Modifier
                ),
            contentAlignment = Alignment.Center
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (!noExact) {
                    Icon(
                        Icons.Filled.PlayArrow,
                        contentDescription = null,
                        tint = p.surface.copy(alpha = if (primaryEnabled) 1f else 0.6f),
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(Modifier.width(8.dp))
                }
                Text(
                    primaryText,
                    fontSize = 14.5.sp,
                    letterSpacing = 1.5.sp,
                    fontWeight = FontWeight.Medium,
                    color = p.surface.copy(alpha = if (primaryEnabled) 1f else 0.6f)
                )
            }
        }

        // ---- 次级动作：文字链，不再用第二个矩形 ----
        Spacer(Modifier.height(12.dp))
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            TextLink(if (busy) "再听一次（会中断起播）" else "再听一次", enabled = !busy) { onAgain() }
            if (!noExact) {
                Spacer(Modifier.width(20.dp))
                Box(Modifier.width(1.dp).height(18.dp).background(p.text.copy(alpha = 0.18f)))
                Spacer(Modifier.width(20.dp))
                TextLink(
                    when {
                        versionsBusy -> "正在找其他版本…"
                        versions.isNotEmpty() -> "其他版本 · ${versions.size} 条"
                        else -> "其他版本"
                    },
                    enabled = !versionsBusy
                ) { onLoadVersions() }
            }
        }

        // ---- 其他版本：原唱（识别到的这位歌手）排最上方并标注 ----
        if (versions.isNotEmpty()) {
            Spacer(Modifier.height(18.dp))
            SectionHead("其他版本", "${versions.size} 条")
            Column(modifier = Modifier.fillMaxWidth()) {
                versions.forEach { s ->
                    val isOriginal = artistTokens.any { t ->
                        val tn = t.lowercase().replace(Regex("[\\s\\p{Punct}·、，。（）()【】《》\\[\\]]"), "")
                        val sn = s.singer.lowercase().replace(Regex("[\\s\\p{Punct}·、，。（）()【】《》\\[\\]]"), "")
                        sn.contains(tn) || tn.contains(sn)
                    }
                    VersionRow(song = s, original = isOriginal) { onPlayVersion(s) }
                }
            }
        } else if (!noExact && others.isNotEmpty() && versionsBusy.not()) {
            // 指纹同批给出的其他候选：只在还没找过"其他版本"时作为补充展示
            Spacer(Modifier.height(18.dp))
            SectionHead("同批候选", null)
            Column(modifier = Modifier.fillMaxWidth()) {
                others.take(4).forEach { h -> HitRow(h) { onPlay(h) } }
            }
        }
        // v2.1.85：底部让位——播放悬浮栏约占 72dp，留 84dp 保证最后一条不被压住
        Spacer(Modifier.height(84.dp))
    }
}

/** 朱砂小印：11dp 见方，细朱线 + 五个点的字号，只做标识不抢戏 */
@Composable
private fun SealMark(ch: String) {
    val p = LocalPalette.current
    Box(
        modifier = Modifier
            .size(19.dp)
            .background(p.heartOn.copy(alpha = 0.05f))
            .border(1.dp, p.heartOn.copy(alpha = 0.52f)),
        contentAlignment = Alignment.Center
    ) {
        Text(ch, fontSize = 9.sp, color = p.heartOn, letterSpacing = 0.5.sp)
    }
}

/** 书页式小标题：标签 + 一根贯通到底的细线 + 条数 */
@Composable
private fun SectionHead(label: String, count: String?) {
    val p = LocalPalette.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, fontSize = 10.5.sp, letterSpacing = 2.sp, color = p.text3)
        Spacer(Modifier.width(10.dp))
        Box(Modifier.weight(1f).height(1.dp).background(p.text.copy(alpha = 0.12f)))
        if (count != null) {
            Spacer(Modifier.width(10.dp))
            Text(count, fontSize = 10.sp, color = p.text3.copy(alpha = 0.75f))
        }
    }
}

/** 文字链：墨字、可点、无框；禁用时退到淡墨 */
@Composable
private fun TextLink(text: String, enabled: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(
        modifier = Modifier
            .then(if (enabled) Modifier.inkClickable { onClick() } else Modifier)
            .padding(vertical = 6.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text,
            fontSize = 12.5.sp,
            letterSpacing = 0.5.sp,
            color = p.text2.copy(alpha = if (enabled) 1f else 0.42f)
        )
    }
}

/** 一行版本：朱砂细签（仅原唱）+ 歌名 + 原唱印 + 歌手 · 平台，整行可点直接起播 */
@Composable
private fun VersionRow(
    song: com.jz.musichelper.model.Song,
    original: Boolean,
    onClick: () -> Unit
) {
    val p = LocalPalette.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .inkClickable { onClick() }
            .padding(top = 12.dp, bottom = 11.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .width(2.dp)
                    .height(24.dp)
                    .background(if (original) p.heartOn.copy(alpha = 0.75f) else Color.Transparent)
            )
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        song.name,
                        fontSize = 14.5.sp,
                        color = p.text,
                        maxLines = 1,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (original) {
                        Spacer(Modifier.width(7.dp))
                        Text(
                            "原唱",
                            fontSize = 9.sp,
                            color = p.heartOn,
                            letterSpacing = 0.5.sp,
                            modifier = Modifier
                                .border(1.dp, p.heartOn.copy(alpha = 0.50f))
                                .padding(horizontal = 3.dp, vertical = 1.dp)
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    listOf(song.singer.ifBlank { "未知歌手" }, song.platform.name).joinToString(" · "),
                    fontSize = 11.sp,
                    color = p.text3,
                    maxLines = 1
                )
            }
        }
        Spacer(Modifier.height(11.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(p.text.copy(alpha = 0.07f)))
    }
}

'''

src = src[:i] + new + src[j:]
io.open(p, "w", encoding="utf-8", newline="\n").write(src)
print("patched", len(src))

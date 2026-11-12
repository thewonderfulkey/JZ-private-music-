package com.jz.musichelper.network

/**
 * v2.1.92：听歌识曲「双通道统一打分」。
 *
 * 背景：v2.1.91 是「酷狗有结果就直接返回，网易只做兜底」。问题是酷狗经常把某首歌认成
 * 别人的翻唱/综艺版（指纹接口只回它曲库里最像的那一条），而网易那边有原唱——
 * 典型例子是张杰《我们都一样》：酷狗给的是翻唱，网易给的是《明天过后》302s 与
 * 《One Chance》303s（同一版录音被两张正式专辑收录）。旧口径下网易根本没机会说话。
 *
 * 现在改成：两条通道都跑完，把候选放进同一个池子，按「同一首歌」聚类后统一打分，
 * 取最高分。评分只用可解释的结构特征，不依赖"哪家先返回"：
 *
 *  1. is_original（仅酷狗提供）：1=原唱 +45，2=翻唱/他人版本 −30，0/未知 0。这是最硬的单点证据。
 *  2. 歌名是否裸名：`StudioPick.isCleanTitle` 为真 +12，带 (Live)/(伴奏)/【AI翻唱】这类 −35。
 *  3. 专辑：正式的独立专辑 +15；专辑名就是歌名（同名合集/自建合集）−20；现场/综艺/节目 −28；
 *     完全没有专辑信息 −8。
 *  4. 时长：能拿到合理时长（30s~30min）+4；时长只作为"互证"的原料，不单独判好坏。
 *  5. 通道内位次：第 1 条 +7，之后每条 −2（0→7/1→5/2→3/3→1/4→0）。
 *  6. 元数据完整度：网易多给专辑 + 时长 + songId，+2。
 *
 * 身份级加成（跨候选）：
 *  7. 两条通道都命中同一"曲目身份"（核心歌名 + 第一歌手）+50——互证比任何单点特征都可信。
 *  8. 同一歌手有 ≥2 张不同的正式专辑、且这些条目的时长互差 ≤3s（v2.1.90 的 D 口径）+22
 *     ——"同一版录音被反复收录"是原唱最可靠的推断。
 *
 * 「曲目身份」= StudioPick.coreName(歌名) 归一化 + 第一位歌手归一化（繁转简）。
 * 所以「张杰、胡迪、范如臣」与「张杰」算同一位，「凌霄(庄云霄)」与「周杰伦」分开。
 *
 * 设计取舍：不做"网易优先"这种按渠道拍脑袋的规则。渠道只在证据相当时靠 +2 的完整度微调，
 * 以及靠跨通道互证来决定胜负——这样换通道、加通道都不用重调一堆阈值。
 */
object RecognizeScore {

    const val SOURCE_KUGOU = "kugou"
    const val SOURCE_NETEASE = "netease"

    /** 打分输入：两条通道归一化后的候选 */
    data class Cand(
        val title: String,
        val artist: String,
        val album: String,
        val durationSec: Int,
        val source: String,
        /** 通道内位次（0 = 该通道第一条） */
        val rank: Int,
        /** 仅酷狗有：1 原唱 / 2 翻唱·他人版本 / 0 未知 / -1 通道不提供 */
        val isOriginal: Int
    )

    /** 一个"曲目身份"的打分结果 */
    data class Item(
        val rep: Cand,
        val score: Int,
        val channels: Set<String>,
        val formalAlbums: Int,
        val durationConfirmed: Boolean
    )

    data class Result(
        val ranked: List<Item>,
        /** 每个通道自己最好的那条分数（用于界面说明"谁给的更可信"） */
        val bestByChannel: Map<String, Int>,
        /** 一句话结论，直接显示在结果卡上 */
        val note: String
    )

    fun fuse(kugou: List<Cand>, netease: List<Cand>): Result? {
        val all = (kugou + netease).filter { it.title.isNotBlank() }
        if (all.isEmpty()) return null

        // 1) 归并同一曲目身份
        val groups = LinkedHashMap<String, MutableList<Cand>>()
        for (c in all) {
            val key = identityKey(c)
            if (key.isEmpty()) continue
            groups.getOrPut(key) { mutableListOf() }.add(c)
        }
        if (groups.isEmpty()) return null

        // 2) 逐身份打分
        val items = groups.values.mapNotNull { members -> scoreIdentity(members) }

        // 3) 排序：分数 → 原唱标记 → 标题更短（原版多为裸名）→ 通道内位次
        val ordered = items.sortedWith(
            compareByDescending<Item> { it.score }
                .thenBy { originalRank(it.rep.isOriginal) }
                .thenBy { it.rep.title.length }
                .thenBy { it.rep.rank }
                .thenBy { if (it.rep.source == SOURCE_KUGOU) 0 else 1 }
        )
        if (ordered.isEmpty()) return null

        // 4) 通道各自最好的分数（按"单条候选"算，不含互证加成，便于比较）
        val bestByChannel = LinkedHashMap<String, Int>()
        for (c in all) {
            val s = memberScore(c)
            val cur = bestByChannel[c.source]
            if (cur == null || s > cur) bestByChannel[c.source] = s
        }

        return Result(ordered, bestByChannel, noteOf(ordered.first(), bestByChannel))
    }

    private fun originalRank(isOriginal: Int): Int = when (isOriginal) {
        1 -> 0
        0, -1 -> 1
        else -> 2
    }

    /** 曲目身份键：核心歌名 + 第一位歌手（归一化、繁转简） */
    fun identityKey(c: Cand): String {
        val core = norm(StudioPick.coreName(c.title).ifBlank { c.title })
        val singer = norm(firstArtist(c.artist))
        return if (core.isEmpty()) "" else "$core|$singer"
    }

    fun firstArtist(raw: String): String =
        raw.split(Regex("[/、,，&·|]")).firstOrNull()?.trim().orEmpty()

    /** 单条候选得分（不含身份级加成） */
    fun memberScore(c: Cand): Int {
        var s = 0
        // ① 原唱标记（只有酷狗给）
        //    v2.1.93：实测出现第 4 种取值（《晴天》周杰伦的演唱会 Live CD 版、《我们都一样》张杰的
        //    综艺收录版都是 4），语义是"原唱，但不是这张录音室录音"，所以轻降权而不是加分。
        s += when (c.isOriginal) {
            1 -> 45
            2 -> -30
            4 -> -8
            else -> 0
        }
        // ② 歌名是否裸名
        s += if (StudioPick.isCleanTitle(c.title)) 12 else -35
        // ③ 专辑
        val album = c.album.trim()
        if (album.isEmpty()) {
            s -= 8
        } else when {
            RecognizeAdapter.Judge.isSameAlbumAsTitle(album, c.title) -> s -= 20
            RecognizeAdapter.Judge.isVarietyAlbum(album) || StudioPick.isLiveAlbum(album) -> s -= 28
            else -> s += 15
        }
        // ④ 时长可用
        if (c.durationSec in 30..1800) s += 4
        // ⑤ 通道内位次
        s += maxOf(0, 7 - c.rank * 2)
        // ⑥ 元数据完整度
        if (c.source == SOURCE_NETEASE) s += 2
        return s
    }

    private fun scoreIdentity(members: List<Cand>): Item? {
        if (members.isEmpty()) return null
        val rep = members.maxByOrNull { memberScore(it) } ?: return null
        var score = memberScore(rep)

        val channels = members.map { it.source }.toSet()
        // ⑦ 两通道互证
        if (channels.size >= 2) score += 50

        // ⑧ 同歌手多张正式专辑 + 时长一致（D 口径）
        val formalAlbums = members.mapNotNull { c ->
            val a = c.album.trim()
            if (a.isEmpty()) return@mapNotNull null
            if (RecognizeAdapter.Judge.isSameAlbumAsTitle(a, c.title)) return@mapNotNull null
            if (RecognizeAdapter.Judge.isVarietyAlbum(a) || StudioPick.isLiveAlbum(a)) return@mapNotNull null
            norm(a)
        }.distinct()
        val durs = members.map { it.durationSec }.filter { it > 0 }.sorted()
        val durationConfirmed = durs.size >= 2 && durs.last() - durs.first() <= 3
        if (formalAlbums.size >= 2 && durationConfirmed) score += 22

        return Item(rep, score, channels, formalAlbums.size, durationConfirmed)
    }

    private fun noteOf(top: Item, best: Map<String, Int>): String {
        val kg = best[SOURCE_KUGOU]?.toString() ?: "—"
        val ne = best[SOURCE_NETEASE]?.toString() ?: "—"
        val how = when {
            top.channels.size >= 2 -> "双通道互证"
            top.rep.source == SOURCE_KUGOU -> "采用酷狗"
            top.rep.source == SOURCE_NETEASE -> "采用网易"
            else -> "采用最高分"
        }
        return "识别依据：酷狗 $kg ／ 网易 $ne → $how"
    }

    /** 归一化：繁转简 + 小写 + 去空白/标点/括号 */
    private fun norm(s: String): String =
        TradToSimpMap.toSimplified(s).lowercase()
            .replace(Regex("[\\s\\p{Punct}·、，。（）()【】《》\\[\\]、]"), "")
}

/** 通道结果 → 打分输入（Hit 自带 source/rank/isOriginal，转换是幂等的） */
fun RecognizeAdapter.Hit.asCand(): RecognizeScore.Cand = RecognizeScore.Cand(
    title = title,
    artist = artist,
    album = album,
    durationSec = durationSec,
    source = source.ifBlank { "unknown" },
    rank = rank,
    isOriginal = isOriginal
)

/** 打分结果 → 界面/历史用的 Hit（把分数带上，便于结果卡显示与事后排查） */
fun RecognizeScore.Cand.toHit(score: Int): RecognizeAdapter.Hit = RecognizeAdapter.Hit(
    title = title,
    artist = artist,
    album = album,
    durationSec = durationSec,
    source = source,
    score = score,
    isOriginal = isOriginal,
    rank = rank
)

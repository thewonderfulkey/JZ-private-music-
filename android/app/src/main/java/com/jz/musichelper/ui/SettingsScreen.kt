package com.jz.musichelper.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jz.musichelper.data.DesktopLyrics
import com.jz.musichelper.data.HistoryStore
import com.jz.musichelper.data.PlayLog
import com.jz.musichelper.model.QualityLevel
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// ===== 设置页：音质 + 主题（水墨单主题展示）+ 数据管理 + 关于 =====
@Composable
fun SettingsScreen(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    var quality by remember { mutableStateOf(HistoryStore.loadQuality()) }

    // v2.1.66：底部留白与播放悬浮栏同一口径——悬浮栏高度 = 屏宽 1/5（约 82dp），
    // 出现时留 96dp（栏高 + 14dp 呼吸），未出现时留 60dp（与其他列表页一致），末行不再被压住
    val playerShown = AppState.lastSong.value != null
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(start = 18.dp, end = 18.dp, bottom = if (playerShown) 96.dp else 60.dp)
    ) {
        // 左上角返回按钮 + 标题
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 8.dp, top = 8.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .background(p.accent.copy(alpha = 0.16f), RoundedCornerShape(12.dp))
                    .inkClickable { AppState.tab.value = MainTab.HOME },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "返回",
                    tint = p.accent2,
                    modifier = Modifier.size(22.dp)
                )
            }
            Text(
                "设置",
                fontSize = 26.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = InkTitleFont,
                color = p.text,
                modifier = Modifier.padding(start = 8.dp, top = 6.dp)
            )
        }

        // 主题（水墨 · 简约山水：全 App 统一水墨风格，无切换）
        Text("主题外观", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.text)
        Spacer(Modifier.height(8.dp))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(p.surface2, RoundedCornerShape(12.dp))
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(34.dp)
                    .clip(CircleShape)
                    .background(
                        Brush.radialGradient(
                            colors = listOf(Color(0x2E2E2A24), Color(0x002E2A24)),
                            radius = 500f
                        )
                    ),
                contentAlignment = Alignment.Center
            ) {
                Box(Modifier.size(12.dp).background(p.accent, CircleShape))
            }
            Spacer(Modifier.width(12.dp))
            Column {
                Text("水墨 · 简约山水", color = p.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text("米白纸底 · 墨色点缀（参考概念图 v2 第 5 格）", color = p.text3, fontSize = 12.sp)
            }
        }
        Spacer(Modifier.height(20.dp))

        // 下载设置
        Text("下载设置", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.text)
        Spacer(Modifier.height(6.dp))
        Text("默认音质", color = p.text2, fontSize = 13.sp)
        QualityLevel.entries.forEach { q ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
            ) {
                RadioButton(
                    selected = quality == q,
                    onClick = {
                        quality = q
                        HistoryStore.saveQuality(q)
                    },
                    colors = RadioButtonDefaults.colors(selectedColor = p.accent, unselectedColor = p.text3)
                )
                Text(q.displayName, color = p.text, fontSize = 14.sp)
                if (q == QualityLevel.HIGH || q == QualityLevel.LOSSLESS) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        if (q == QualityLevel.HIGH) "320k" else "FLAC",
                        color = p.text3,
                        fontSize = 11.sp
                    )
                }
            }
        }
        Spacer(Modifier.height(20.dp))

        // 保存位置
        Text("保存位置", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.text)
        Spacer(Modifier.height(8.dp))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(p.surface2, RoundedCornerShape(12.dp))
                .padding(12.dp)
        ) {
            Text("下载的音乐保存在系统媒体库：", color = p.text2, fontSize = 13.sp)
            Text("Music / JZ音乐助手", color = p.accent2, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(4.dp))
            Text("可在「音乐」或「文件」App 中查看，支持导入其他播放器。", color = p.text3, fontSize = 12.sp)
        }
        Spacer(Modifier.height(20.dp))

        // 数据管理
        Text("数据管理", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.text)
        Spacer(Modifier.height(8.dp))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(p.surface2, RoundedCornerShape(12.dp))
                .padding(horizontal = 12.dp, vertical = 4.dp)
        ) {
            Text(
                "清空搜索历史",
                fontSize = 14.sp,
                color = Color(0xFFC0392B),
                modifier = Modifier
                    .inkClickable {
                        HistoryStore.clearSearchHistory()
                        toast("已清空搜索历史")
                    }
                    .padding(vertical = 12.dp)
            )
        }
        Spacer(Modifier.height(20.dp))

        // 异常诊断（全局未捕获异常在此展示，方便反馈根因）
        val ctx = androidx.compose.ui.platform.LocalContext.current
        val lastError = remember {
            ctx.getSharedPreferences("jz_music_prefs", android.content.Context.MODE_PRIVATE)
                .getString("last_error", null)
        }
        val lastErrorTime = remember {
            ctx.getSharedPreferences("jz_music_prefs", android.content.Context.MODE_PRIVATE)
                .getLong("last_error_time", 0L)
        }
        if (lastError != null) {
            Text("异常诊断", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.text)
            Spacer(Modifier.height(8.dp))
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(p.surface2, RoundedCornerShape(12.dp))
                    .padding(12.dp)
            ) {
                Text(
                    "最近一次未捕获异常：" + if (lastErrorTime > 0)
                        SimpleDateFormat("MM-dd HH:mm:ss", Locale.getDefault()).format(Date(lastErrorTime))
                    else "时间未知",
                    fontSize = 12.sp,
                    color = p.text,
                    fontWeight = FontWeight.SemiBold
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    lastError,
                    fontSize = 10.sp,
                    color = p.text2,
                    maxLines = 14
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "将以上内容发给开发者即可定位问题；点击下方按钮可清空。",
                    fontSize = 11.sp,
                    color = p.text3
                )
                Text(
                    "清空诊断",
                    fontSize = 13.sp,
                    color = Color(0xFFC0392B),
                    modifier = Modifier
                        .inkClickable {
                            ctx.getSharedPreferences("jz_music_prefs", android.content.Context.MODE_PRIVATE)
                                .edit().remove("last_error").apply()
                        }
                        .padding(top = 8.dp)
                )
            }
            Spacer(Modifier.height(20.dp))
        }

        // 桌面歌词（v2.1.74）：开关 + 实时授权状态 + 去授权 / 重置位置。
        // 与播放页右上角三点菜单共用同一个开关状态（DesktopLyrics.enabled）。
        val dlOn by DesktopLyrics.enabled.collectAsState()
        val dlAllowed by DesktopLyrics.canOverlay.collectAsState()
        Text("桌面歌词", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.text)
        Spacer(Modifier.height(8.dp))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(p.surface2, RoundedCornerShape(12.dp))
                .padding(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("在桌面显示滚动歌词", fontSize = 14.sp, color = p.text, fontWeight = FontWeight.Medium)
                    Text(
                        "退到桌面或切到其他应用时，屏幕底部出现一栏歌词，跟着播放滚动；App 内不显示。",
                        fontSize = 12.sp,
                        color = p.text3
                    )
                }
                Spacer(Modifier.width(8.dp))
                Switch(
                    checked = dlOn,
                    onCheckedChange = { on ->
                        if (on) {
                            if (DesktopLyrics.toggleFromUi(true)) {
                                toast("桌面歌词已开启，回到桌面（或切到别的应用）播放时即可看到")
                            } else {
                                toast("需要「显示在其他应用上层」权限")
                                DesktopLyrics.openOverlaySettings(ctx)
                            }
                        } else {
                            DesktopLyrics.toggleFromUi(false)
                        }
                    },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = p.surface,
                        checkedTrackColor = p.accent,
                        uncheckedThumbColor = p.surface,
                        uncheckedTrackColor = p.text3.copy(alpha = 0.4f)
                    )
                )
            }
            Spacer(Modifier.height(6.dp))
            val dlError by DesktopLyrics.lastError.collectAsState()
            Text(
                when {
                    !dlAllowed -> "未授权：系统里需允许「显示在其他应用上层 / 显示悬浮窗」，否则歌词不会出现。"
                    dlOn -> "已开启：回到桌面即可看到；拖动歌词栏可调整位置，松手自动留出边距。"
                    else -> "已授权，当前未开启。"
                },
                fontSize = 12.sp,
                color = if (dlAllowed) p.text2 else Color(0xFF9A4A24)
            )
            dlError?.let { msg ->
                Spacer(Modifier.height(4.dp))
                Text(msg, fontSize = 12.sp, color = Color(0xFF9A4A24))
            }
            Spacer(Modifier.height(10.dp))
            val dlTheme by DesktopLyrics.theme.collectAsState()
            val dlFont by DesktopLyrics.fontStep.collectAsState()
            val dlLocked by DesktopLyrics.locked.collectAsState()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("纸色", fontSize = 13.sp, color = p.text2)
                Spacer(Modifier.width(10.dp))
                listOf("素纸", "旧黄", "夜墨").forEachIndexed { i, name ->
                    Text(
                        name,
                        fontSize = 12.sp,
                        color = if (dlTheme == i) p.surface else p.text3,
                        modifier = Modifier
                            .padding(end = 6.dp)
                            .background(if (dlTheme == i) p.accent2 else p.surface, RoundedCornerShape(6.dp))
                            .padding(horizontal = 9.dp, vertical = 4.dp)
                            .inkClickable { DesktopLyrics.setTheme(i) }
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("字号", fontSize = 13.sp, color = p.text2)
                Spacer(Modifier.width(10.dp))
                Text(
                    "A-",
                    fontSize = 14.sp,
                    color = if (dlFont > -2) p.accent2 else p.text3.copy(alpha = 0.5f),
                    modifier = Modifier
                        .inkClickable { DesktopLyrics.adjustFontStep(-1) }
                        .padding(horizontal = 6.dp, vertical = 2.dp)
                )
                Text(
                    when (dlFont) {
                        -2 -> "很小"; -1 -> "偏小"; 0 -> "标准"; 1 -> "偏大"; else -> "很大"
                    },
                    fontSize = 12.sp,
                    color = p.text3
                )
                Text(
                    "A+",
                    fontSize = 14.sp,
                    color = if (dlFont < 2) p.accent2 else p.text3.copy(alpha = 0.5f),
                    modifier = Modifier
                        .inkClickable { DesktopLyrics.adjustFontStep(1) }
                        .padding(horizontal = 6.dp, vertical = 2.dp)
                )
                Spacer(Modifier.weight(1f))
                Text(
                    if (dlLocked) "已锁定" else "可拖动",
                    fontSize = 12.sp,
                    color = p.text3,
                    modifier = Modifier
                        .inkClickable { DesktopLyrics.toggleLock() }
                        .padding(vertical = 2.dp)
                )
            }
            Spacer(Modifier.height(6.dp))
            Text(
                "点一下歌词栏会浮出工具条：上一句 / 暂停 / 下一句 / 字号 / 锁定 / 关闭，3 秒不操作自动收起。" +
                    "长句会自动缩字号或折行，不再出现省略号。",
                fontSize = 12.sp,
                color = p.text3
            )
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "去授权",
                    fontSize = 13.sp,
                    color = p.accent2,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier
                        .inkClickable {
                            if (!DesktopLyrics.openOverlaySettings(ctx)) {
                                toast("没找到系统权限页，请到「设置-应用-权限」里手动开启")
                            }
                        }
                        .padding(vertical = 2.dp)
                )
                Spacer(Modifier.weight(1f))
                Text(
                    "重置位置",
                    fontSize = 13.sp,
                    color = p.text3,
                    modifier = Modifier
                        .inkClickable {
                            DesktopLyrics.resetPosition()
                            toast("桌面歌词已恢复默认位置")
                        }
                        .padding(vertical = 2.dp)
                )
            }
        }
        Spacer(Modifier.height(20.dp))

        // 后台连播 / 电池优化白名单：v2.1.73 起常驻设置页，随时可自查与补授权。
        // 首次启动仍会自动弹系统授权框，这里只是兜底入口（也方便换机后自己确认状态）。
        val powerMgr = remember { ctx.getSystemService(android.os.PowerManager::class.java) }
        var ignoringBattery by remember {
            mutableStateOf(
                runCatching { powerMgr?.isIgnoringBatteryOptimizations(ctx.packageName) == true }
                    .getOrDefault(true)
            )
        }
        LaunchedEffect(Unit) {
            while (true) {
                delay(1500)
                runCatching {
                    val v = powerMgr?.isIgnoringBatteryOptimizations(ctx.packageName) == true
                    if (v != ignoringBattery) ignoringBattery = v
                }
            }
        }
        Text("后台连播", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.text)
        Spacer(Modifier.height(8.dp))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(p.surface2, RoundedCornerShape(12.dp))
                .padding(12.dp)
        ) {
            Text("电池优化白名单", fontSize = 14.sp, color = p.text, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(4.dp))
            Text(
                if (ignoringBattery) "已允许不受电池限制：息屏后仍可联网取流，一首播完会照常切下一首。"
                else "未允许：锁屏久了系统会限制后台联网，播完一首后可能取不到下一首。",
                fontSize = 12.sp,
                color = if (ignoringBattery) p.text2 else Color(0xFF9A4A24)
            )
            Spacer(Modifier.height(8.dp))
            Text(
                if (ignoringBattery) "查看系统电池设置" else "去允许",
                fontSize = 13.sp,
                color = if (ignoringBattery) p.text3 else p.accent2,
                fontWeight = FontWeight.Medium,
                modifier = Modifier
                    .inkClickable {
                        runCatching {
                            val intent = if (ignoringBattery) {
                                android.content.Intent(
                                    android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
                                )
                            } else {
                                android.content.Intent(
                                    android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    android.net.Uri.parse("package:" + ctx.packageName)
                                )
                            }
                            ctx.startActivity(intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
                        }
                    }
                    .padding(vertical = 2.dp)
            )
        }
        Spacer(Modifier.height(20.dp))

        // 关于
        Text("关于", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.text)
        Spacer(Modifier.height(8.dp))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(p.surface2, RoundedCornerShape(12.dp))
                .padding(12.dp)
        ) {
            Text("JZ的音乐助手 v2.1.92", fontSize = 14.sp, color = p.text)
            Spacer(Modifier.height(6.dp))
            Text("本版更新", fontSize = 12.sp, color = p.text3)
            Spacer(Modifier.height(3.dp))
            Text(
                "听歌识曲改成「两条通道都跑完，再按统一评分选最可信的一条」。以前是酷狗一有结果就直接返回，" +
                    "于是酷狗把歌认成别人的翻唱时，网易手里的原唱根本没机会参与比较——张杰《我们都一样》一直播成翻唱就是这个原因。" +
                    "现在等酷狗与网易都回来（约 12 秒），把两边候选按同一首歌归并后统一打分：酷狗的原唱标记、歌名是否裸名、" +
                    "专辑是否正式发行（同名合集与现场综艺专辑扣分）、时长互证、两条通道是否互证、通道内位次，各占一份权重，取最高分。" +
                    "例：酷狗给《我们都一样》的翻唱（无原唱标记、专辑名就叫《我们都一样》）得负分，网易给张杰《明天过后》302s 与" +
                    "《One Chance》303s 两条正式专辑互相印证，得 62 分，于是采用网易。结果卡上会写明「识别依据：酷狗 xx ／ 网易 xx」，" +
                    "同批候选也按分数排列。",
                fontSize = 12.sp,
                color = p.text2
            )
            Spacer(Modifier.height(10.dp))
            Text("上一版（v2.1.91）", fontSize = 12.sp, color = p.text3)
            Spacer(Modifier.height(3.dp))
            Text(
                "识曲改成酷狗＋网易两条通道互为兜底：先录 6 秒就问一次酷狗，认出就立刻出结果；" +
                    "6 秒没对上，继续录满 12 秒，再用完整片段同时打酷狗与网易——酷狗优先，酷狗找不到才用网易，" +
                    "网易也没结果时酷狗已经用更长的片段又跑了一遍，两边互为后手。" +
                    "网易这一路不需要 key：指纹由端上网易自家的 afp 引擎算出来（随包带约 400KB 引擎资源），" +
                    "再用它召回网易曲库的中文元数据；候选会按「非现场／非改编、专辑不等于歌名、标题最短」排序后再取第一。" +
                    "识曲时长档位同步收成 12／15／20 秒，旧设置里的 5 秒、10 秒按 12 秒处理。",
                fontSize = 12.sp,
                color = p.text2
            )
            Spacer(Modifier.height(10.dp))
            Text("上一版（v2.1.90）", fontSize = 12.sp, color = p.text3)
            Spacer(Modifier.height(3.dp))
            Text(
                "「原唱」判定重做：① 恢复只标「原唱」这一处小印，上一版把「录音室版」当成独立标记，结果同名翻唱几乎全被标上；" +
                    "② 识曲命中的本身就是录音室版时，按识曲歌手标（这种情形可信）；③ 命中的是综艺／现场／改编版时，改用" +
                    "「同一位歌手有 ≥2 张不同的正式专辑、且这几条时长互相 ≤3 秒」推断：同一版录音被反复收录才算原唱，" +
                    "专辑名就等于歌名的同名合集（橘子妹、胡小斐、解昕怡这类）不会再被误标；推不出来就不标，宁可不标也不标错。" +
                    "另外识曲改为先读指纹接口返回的多条候选、优先取非综艺／非改编的那条（原来直接取第 1 条）。",
                fontSize = 12.sp,
                color = p.text2
            )
            Spacer(Modifier.height(10.dp))
            Text("上一版（v2.1.89）", fontSize = 12.sp, color = p.text3)
            Spacer(Modifier.height(3.dp))
            Text(
                "识曲不再被综艺／翻唱版锁死：旧逻辑用「歌名＋全部歌手」检索，网易对这个词只回一条节目 Live，" +
                    "原唱进不了候选池。现在先按「歌名＋第一位歌手」检索，并在识别命中综艺／现场／DJ 版时不再锁定那位翻唱歌手，" +
                    "改在同曲的录音室版里择优起播。",
                fontSize = 12.sp,
                color = p.text2
            )
            Spacer(Modifier.height(10.dp))
            Text("上一版（v2.1.88）", fontSize = 12.sp, color = p.text3)
            Spacer(Modifier.height(3.dp))
            Text(
                "① 识曲命中即可播：同曲判定从「歌名整串相等」改为「核心歌名相等」（剥掉 (feat. xxx)、" +
                    "「- Orchestra Ver. -」这类括号/后缀）。② 搜索平台行标出每个平台本次返回的条数，" +
                    "「N 平台并发」按实际注册平台自动计数。③ 修酷我英文关键词匹配的大小写问题。",
                fontSize = 12.sp,
                color = p.text2
            )
            Spacer(Modifier.height(10.dp))
            Text("上一版（v2.1.87）", fontSize = 12.sp, color = p.text3)
            Spacer(Modifier.height(3.dp))
            Text(
                "补齐酷我源的封面与歌词：① 搜索结果直接取酷我返回的 MVPIC 曲图（img1 的 wmvpic 路径），" +
                    "约八成酷我歌曲现在有真封面；字段为空时仍走原兜底。" +
                    "② 酷我歌曲改用酷我官方歌词接口（平台 ID 精确匹配、行级时间），取不到词再回退 LDDC 双源。",
                fontSize = 12.sp,
                color = p.text2
            )
            Spacer(Modifier.height(10.dp))
            Text("声明", fontSize = 12.sp, color = p.text3)
            Spacer(Modifier.height(3.dp))
            Text(
                "1. 音乐源为酷我 / QQ / 网易等第三方接口的聚合结果，仅供个人学习与测试，请支持正版音乐。\n" +
                    "2. 本应用不存储、不传播任何音频文件，仅提供检索、试听与本地缓存。\n" +
                    "3. 曲库版权与接口可用性随时变化，个别歌曲缺少某档音质属正常现象。",
                fontSize = 12.sp,
                color = p.text2,
                lineHeight = 18.sp
            )
        }
        Spacer(Modifier.height(24.dp))
    }
}

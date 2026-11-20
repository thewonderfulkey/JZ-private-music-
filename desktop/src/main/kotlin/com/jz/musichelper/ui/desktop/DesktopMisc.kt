package com.jz.musichelper.ui.desktop

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.clip
import com.jz.musichelper.ui.desktop.handCursor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jz.musichelper.data.AppEnv
import com.jz.musichelper.data.DesktopLyrics
import com.jz.musichelper.data.HistoryStore
import com.jz.musichelper.model.QualityLevel
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette

// ============================================================================================
// 设置
// ============================================================================================

@Composable
fun SettingsPage() {
    val p = LocalPalette.current
    var quality by remember { mutableStateOf(HistoryStore.loadQuality()) }
    val dlOn by DesktopLyrics.enabled.collectAsState()
    val dlTheme by DesktopLyrics.theme.collectAsState()
    val dlFont by DesktopLyrics.fontStep.collectAsState()
    val dlLocked by DesktopLyrics.locked.collectAsState()
    val lastError = remember { AppEnv.prefs("jz_music_prefs").getString("last_error", null) }

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 26.dp, end = 26.dp, top = 16.dp, bottom = 24.dp)
    ) {
        item {
            Text("设置", fontSize = 22.sp, color = p.text, fontFamily = InkTitleFont, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(16.dp))
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(20.dp), modifier = Modifier.fillMaxWidth()) {
                // 左列
                Column(Modifier.weight(1f)) {
                    SettingsCard("窗口与托盘") {
                        val prefs = AppEnv.prefs("jz_music_prefs")
                        var closeAction by remember { mutableStateOf(prefs.getString("close_action", "tray") ?: "tray") }
                        Text("关闭主窗口时", fontSize = 12.sp, color = p.text2)
                        Spacer(Modifier.height(6.dp))
                        listOf("tray" to "收进托盘继续播放（推荐）", "exit" to "直接退出程序").forEach { (key, label) ->
                            Row(
                                Modifier.fillMaxWidth().handCursor()
                                    .clickable {
                                        closeAction = key
                                        prefs.edit().putString("close_action", key).apply()
                                    }
                                    .padding(vertical = 3.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                RadioButton(
                                    selected = closeAction == key,
                                    onClick = {
                                        closeAction = key
                                        prefs.edit().putString("close_action", key).apply()
                                    },
                                    colors = RadioButtonDefaults.colors(
                                        selectedColor = p.heartOn,
                                        unselectedColor = p.text3
                                    )
                                )
                                Text(label, fontSize = 13.sp, color = p.text)
                            }
                        }
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "点 × = 收进托盘：窗口和任务栏按钮一起消失，音乐继续播放；" +
                                "托盘图标出现在右下角，左键单击唤回窗口，右键有菜单（含退出）。" +
                                "点 − 是普通最小化，保留任务栏按钮。修改后立即生效。",
                            fontSize = 11.sp,
                            color = p.text3
                        )
                    }
                    Spacer(Modifier.height(16.dp))
                    SettingsCard("下载音质") {
                        QualityLevel.entries.forEach { q ->
                            Row(
                                Modifier.fillMaxWidth().clickable { quality = q; HistoryStore.saveQuality(q) }.padding(vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                RadioButton(
                                    selected = quality == q,
                                    onClick = { quality = q; HistoryStore.saveQuality(q) },
                                    colors = RadioButtonDefaults.colors(
                                        selectedColor = p.heartOn,
                                        unselectedColor = p.text3
                                    )
                                )
                                Text(q.displayName, fontSize = 13.sp, color = p.text)
                            }
                        }
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "拿不到所选音质会自动换源，每条都按文件体积复核；仍不达标就按可得最高档保存。",
                            fontSize = 11.sp,
                            color = p.text3
                        )
                    }
                    Spacer(Modifier.height(16.dp))
                    SettingsCard("下载位置") {
                        Text(AppEnv.downloadDir.absolutePath, fontSize = 11.5.sp, color = p.text2)
                        Spacer(Modifier.height(8.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            InkButton("更改目录", primary = false) { pickDownloadDir() }
                            InkButton("打开目录", primary = false) { AppEnv.openDir(AppEnv.downloadDir) }
                            if (AppEnv.downloadDir.absolutePath != AppEnv.musicDir.absolutePath) {
                                InkButton("恢复默认", primary = false) {
                                    AppEnv.resetDownloadDir(); DeskToast.show("已恢复默认下载目录")
                                }
                            }
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            if (AppEnv.portable) {
                                "默认就是安装目录里的 Download 文件夹：下载完成的音乐直接落在这里，跟程序在同一个文件夹里。"
                            } else {
                                "下载完成的文件会直接落在这个目录；换目录不影响已下载的歌。"
                            },
                            fontSize = 11.sp, color = p.text3
                        )
                    }
                    Spacer(Modifier.height(16.dp))
                    SettingsCard("数据与备份") {
                        DirRow("下载的音乐", AppEnv.downloadDir)
                        DirRow("运行日志", AppEnv.logsDir)
                        DirRow("播放缓存", AppEnv.cacheDir)
                        DirRow("配置与记录", AppEnv.dataDir)
                        DirRow("备份", AppEnv.backupDir)
                        Spacer(Modifier.height(10.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            InkButton("立即备份", primary = true) {
                                val r = com.jz.musichelper.data.BackupManager.backupNow()
                                DeskToast.show(
                                    if (r != null) "已备份到 Backup\\${r.dir.name}（配置 ${r.copied} 份，歌曲 ${r.songs} 首）"
                                    else "备份失败，详情见日志"
                                )
                            }
                            InkButton("打开备份目录", primary = false) { AppEnv.openDir(AppEnv.backupDir) }
                            InkButton("清空搜索历史", primary = false) {
                                HistoryStore.clearSearchHistory(); DeskToast.show("已清空搜索历史")
                            }
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "备份只拷配置、收藏、历史与歌单（很小），不复制音乐文件；缓存可随时清，删了不影响听歌。",
                            fontSize = 11.sp, color = p.text3
                        )
                    }
                }
                // 右列
                Column(Modifier.weight(1f)) {
                    SettingsCard("桌面歌词") {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text("在桌面显示滚动歌词", fontSize = 13.sp, color = p.text)
                                Spacer(Modifier.height(3.dp))
                                Text("切到别的应用时，屏幕下方浮出一栏歌词跟着播放滚动", fontSize = 11.sp, color = p.text3)
                            }
                            Switch(
                                checked = dlOn,
                                onCheckedChange = { DesktopLyrics.toggleFromUi(it) },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = p.surface,
                                    checkedTrackColor = p.accent,
                                    uncheckedThumbColor = p.surface,
                                    uncheckedTrackColor = p.text3.copy(alpha = 0.4f)
                                )
                            )
                        }
                        Spacer(Modifier.height(12.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("纸色", fontSize = 12.sp, color = p.text2)
                            Spacer(Modifier.width(10.dp))
                            listOf("素纸", "旧黄", "夜墨").forEachIndexed { i, name ->
                                Text(
                                    name,
                                    fontSize = 11.5.sp,
                                    color = if (dlTheme == i) Color(0xFFF7F5F0) else p.text2,
                                    modifier = Modifier
                                        .padding(end = 6.dp)
                                        .clip(RoundedCornerShape(8.dp))
                                        .background(if (dlTheme == i) p.accent2 else p.surface2)
                                        .clickable { DesktopLyrics.setTheme(i) }
                                        .padding(horizontal = 9.dp, vertical = 4.dp)
                                )
                            }
                        }
                        Spacer(Modifier.height(10.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("字号", fontSize = 12.sp, color = p.text2)
                            Spacer(Modifier.width(10.dp))
                            Text("A-", fontSize = 13.sp, color = p.text2, modifier = Modifier
                                .clip(RoundedCornerShape(6.dp))
                                .clickable { DesktopLyrics.adjustFontStep(-1) }
                                .padding(horizontal = 8.dp, vertical = 3.dp))
                            Text(
                                when (dlFont) { -2 -> "很小"; -1 -> "偏小"; 0 -> "标准"; 1 -> "偏大"; else -> "很大" },
                                fontSize = 11.5.sp,
                                color = p.text3,
                                modifier = Modifier.padding(horizontal = 6.dp)
                            )
                            Text("A+", fontSize = 13.sp, color = p.text2, modifier = Modifier
                                .clip(RoundedCornerShape(6.dp))
                                .clickable { DesktopLyrics.adjustFontStep(1) }
                                .padding(horizontal = 8.dp, vertical = 3.dp))
                            Spacer(Modifier.weight(1f))
                            Text(
                                if (dlLocked) "已锁定" else "可拖动",
                                fontSize = 11.5.sp,
                                color = p.text3,
                                modifier = Modifier.clip(RoundedCornerShape(6.dp))
                                    .clickable { DesktopLyrics.toggleLock() }
                                    .padding(horizontal = 6.dp, vertical = 3.dp)
                            )
                            Text(
                                "重置位置",
                                fontSize = 11.5.sp,
                                color = p.text3,
                                modifier = Modifier.clip(RoundedCornerShape(6.dp))
                                    .clickable { DesktopLyrics.resetPosition() }
                                    .padding(horizontal = 6.dp, vertical = 3.dp)
                            )
                        }
                        Spacer(Modifier.height(8.dp))
                        // 悬浮窗收不到鼠标事件，位置改用预设（竖向 3 档 × 横向 3 档）
                        Text("位置", fontSize = 11.5.sp, color = p.text2)
                        Spacer(Modifier.height(4.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            listOf("上" to 0, "中" to 1, "下" to 2).forEach { (label, vy) ->
                                val cur = DesktopLyrics.currentPositionPreset()
                                val on = cur.second == vy
                                Text(
                                    label,
                                    fontSize = 11.5.sp,
                                    color = if (on) p.heartOn else p.text2,
                                    modifier = Modifier.clip(RoundedCornerShape(6.dp))
                                        .background(if (on) p.heartOn.copy(alpha = 0.12f) else androidx.compose.ui.graphics.Color.Transparent)
                                        .clickable { DesktopLyrics.setPositionPreset(DesktopLyrics.currentPositionPreset().first, vy) }
                                        .padding(horizontal = 10.dp, vertical = 4.dp)
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                            listOf("左" to 0, "中" to 1, "右" to 2).forEach { (label, hx) ->
                                val cur = DesktopLyrics.currentPositionPreset()
                                val on = cur.first == hx
                                Text(
                                    label,
                                    fontSize = 11.5.sp,
                                    color = if (on) p.heartOn else p.text2,
                                    modifier = Modifier.clip(RoundedCornerShape(6.dp))
                                        .background(if (on) p.heartOn.copy(alpha = 0.12f) else androidx.compose.ui.graphics.Color.Transparent)
                                        .clickable { DesktopLyrics.setPositionPreset(hx, DesktopLyrics.currentPositionPreset().second) }
                                        .padding(horizontal = 10.dp, vertical = 4.dp)
                                )
                            }
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    SettingsCard("关于") {
                        Text("JZ Music · Windows 版 v2.4.35", fontSize = 13.sp, color = p.text)
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "四平台检索（QQ / 网易云 / 酷我 / 酷狗）+ 多后端取流兜底 + 逐字歌词。"
                                + "本机播放不需要电池白名单，窗口最小化也照常连播。",
                            fontSize = 11.sp,
                            color = p.text3
                        )
                        Spacer(Modifier.height(10.dp))
                        Text("日志目录：${AppEnv.logsDir.absolutePath}", fontSize = 10.5.sp, color = p.text3)
                        Spacer(Modifier.height(8.dp))
                        InkButton("打开日志目录", primary = false) { AppEnv.openDir(AppEnv.logsDir) }
                        if (lastError != null) {
                            Spacer(Modifier.height(12.dp))
                            Text("最近一次异常", fontSize = 11.5.sp, color = Color(0xFF9A4A24))
                            Spacer(Modifier.height(4.dp))
                            Text(lastError.take(600), fontSize = 10.sp, color = p.text2, maxLines = 12)
                        }
                    }
                }
            }
        }
    }
}

/** 设置页「目录」一行：名称 + 路径 + 打开 */
@Composable
private fun DirRow(name: String, dir: java.io.File) {
    val p = LocalPalette.current
    Row(
        Modifier.fillMaxWidth().padding(vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(name, fontSize = 12.sp, color = p.text2, modifier = Modifier.width(74.dp))
        Text(
            dir.absolutePath,
            fontSize = 10.5.sp,
            color = p.text3,
            maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )
        Text(
            "打开",
            fontSize = 11.5.sp,
            color = p.accent2,
            modifier = Modifier.handCursor().clickable { AppEnv.openDir(dir) }.padding(horizontal = 8.dp, vertical = 2.dp)
        )
    }
}

/**
 * 选下载目录：打开应用内自绘的 [DirPicker] 浮层（原来用 Swing 的 JFileChooser，
 * 在 Windows 上弹出来是系统老式目录框，跟纸墨界面完全不搭）。
 * 选完立刻生效，下载页/设置页会跟着刷新。
 */
internal fun pickDownloadDir() {
    DirPicker.request(AppEnv.downloadDir) { dir ->
        AppEnv.setDownloadDir(dir)
        DeskToast.show("下载目录已改为 ${dir.absolutePath}")
    }
}

@Composable
private fun SettingsCard(title: String, content: @Composable () -> Unit) {
    val p = LocalPalette.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(p.surface)
            .padding(16.dp)
    ) {
        Text(title, fontSize = 13.sp, color = p.text2, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(10.dp))
        content()
    }
}

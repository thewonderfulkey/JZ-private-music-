package com.jz.musichelper.ui.theme

import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight

/**
 * 字体装载（桌面版）。
 *
 * Android 用 `Font(R.font.lxgw_wenkai_regular)` 走资源系统；桌面版用 Compose 的
 * `androidx.compose.ui.text.platform.Font(resource)` 直接读 classpath 里的 TTF ——
 * 与 APK 里那两份文件是同一份，字形、字重完全一致。
 */
private fun bundled(path: String, weight: FontWeight) =
    androidx.compose.ui.text.platform.Font(resource = path, weight = weight)

val InkKaiFont: FontFamily = FontFamily(
    bundled("font/lxgw_wenkai_regular.ttf", FontWeight.Normal),
    bundled("font/lxgw_wenkai_regular.ttf", FontWeight.Medium),
    bundled("font/lxgw_wenkai_regular.ttf", FontWeight.SemiBold),
    bundled("font/lxgw_wenkai_regular.ttf", FontWeight.Bold)
)

val InkTitleFont: FontFamily = InkKaiFont

/** 书法体：只留给首页品牌栏题字「发现音乐」+ 朱砂印章这一处 */
val InkBrushFont: FontFamily = FontFamily(
    bundled("font/mashanzheng_regular.ttf", FontWeight.Normal)
)

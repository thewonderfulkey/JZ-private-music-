package com.jz.musichelper.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import com.jz.musichelper.R

// ===== 纸本 · 简（v2.1.59 首页改版后的口径）：浅纸底 + 墨色层级 + 朱砂一点红，山水退为材质 =====

// v2.1.63：全 App 字体换回"正楷"——霞鹜文楷（LXGW WenKai），即 v2.1.2–v2.1.10 用过的那一版。
// 唯一例外是首页品牌栏「发现音乐」的毛笔题字（InkBrushFont），按用户口径保留。
val InkKaiFont: FontFamily = FontFamily(
    Font(R.font.lxgw_wenkai_regular, FontWeight.Normal),
    Font(R.font.lxgw_wenkai_regular, FontWeight.Medium),
    Font(R.font.lxgw_wenkai_regular, FontWeight.SemiBold),
    Font(R.font.lxgw_wenkai_regular, FontWeight.Bold)
)

val InkTitleFont: FontFamily = InkKaiFont

// 书法体：只留给首页品牌栏题字「发现音乐」+ 朱砂印章这一处（全 App 唯一的毛笔字）
val InkBrushFont: FontFamily = FontFamily(
    Font(R.font.mashanzheng_regular, FontWeight.Normal)
)

// 全局默认字体：MaterialTheme 的每一档文字样式都指向正楷，
// 没有显式声明 fontFamily 的 Text（正文/meta/按钮/底栏标签）也会自动跟随，不必逐处改。
private val KaiTypography: Typography = with(Typography()) {
    copy(
        displayLarge = displayLarge.copy(fontFamily = InkKaiFont),
        displayMedium = displayMedium.copy(fontFamily = InkKaiFont),
        displaySmall = displaySmall.copy(fontFamily = InkKaiFont),
        headlineLarge = headlineLarge.copy(fontFamily = InkKaiFont),
        headlineMedium = headlineMedium.copy(fontFamily = InkKaiFont),
        headlineSmall = headlineSmall.copy(fontFamily = InkKaiFont),
        titleLarge = titleLarge.copy(fontFamily = InkKaiFont),
        titleMedium = titleMedium.copy(fontFamily = InkKaiFont),
        titleSmall = titleSmall.copy(fontFamily = InkKaiFont),
        bodyLarge = bodyLarge.copy(fontFamily = InkKaiFont),
        bodyMedium = bodyMedium.copy(fontFamily = InkKaiFont),
        bodySmall = bodySmall.copy(fontFamily = InkKaiFont),
        labelLarge = labelLarge.copy(fontFamily = InkKaiFont),
        labelMedium = labelMedium.copy(fontFamily = InkKaiFont),
        labelSmall = labelSmall.copy(fontFamily = InkKaiFont)
    )
}

data class AppPalette(
    val accent: Color,        // 强调主色（墨）
    val accent2: Color,       // 强调亮色（淡墨褐）
    val glow: Color,          // 顶部淡墨色晕
    val bgTop: Color,         // 背景渐变顶部（纸色）
    val bgBottom: Color,      // 背景渐变底部（纸色略深）
    val surface: Color,       // 卡片/浮层（米白）
    val surface2: Color,      // 次级浮层（淡墨底/输入框）
    val text: Color,          // 主文字（墨）
    val text2: Color,         // 次级文字
    val text3: Color,         // 弱文字
    val heartOn: Color        // 已收藏爱心（朱砂）
)

val InkInk = AppPalette(
    accent = Color(0xFF2E2A24),
    accent2 = Color(0xFF5A5346),
    glow = Color(0x1A2E2A24),
    bgTop = Color(0xFFFAF8F3),
    bgBottom = Color(0xFFF1EDE2),
    surface = Color(0xFFFDFCF9),
    surface2 = Color(0xFFEFEBE1),
    text = Color(0xFF2E2A24),
    text2 = Color(0xFF5C5446),
    // v2.1.59：弱文字由 #A9A294（对纸底 ≈2.3:1，实测 meta 1.3:1 / 艺人名 2.4:1）压深到 #746C60（≈4.8:1），
    // 次要信息也满足正文对比度；不再靠"淡到看不清"来分级
    text3 = Color(0xFF746C60),
    heartOn = Color(0xFFB03A2E)
)

// 当前主题的调色板，供所有界面读取（全 App 统一水墨风格）
val LocalPalette = staticCompositionLocalOf { InkInk }

@Composable
fun AppTheme(content: @Composable () -> Unit) {
    val p = InkInk
    val scheme = lightColorScheme(
        primary = p.accent,
        onPrimary = Color(0xFFF7F5F0),
        secondary = p.accent2,
        background = p.bgBottom,
        surface = p.surface,
        onBackground = p.text,
        onSurface = p.text,
        surfaceVariant = p.surface2,
        error = Color(0xFFC0392B)
    )
    CompositionLocalProvider(LocalPalette provides p) {
        MaterialTheme(colorScheme = scheme, typography = KaiTypography, content = content)
    }
}

// v2.1.59：页面底改为"纸"而不是"画"——整幅山水位图（ink_bg_main）从全 App 撤下，只保留纸色与极轻的上下纸阶。
// 山水只在播放页保留一幅（PlayerScreen 自带的 ink_bg_player），其余页面靠留白、字号与纸阶分层。
//
// v2.1.60：纸底抽成一份共用 Brush。Tab 页滑动时两页会短暂同屏，页面自身若是透明底，
// 新旧两页的文字就会互相穿透（首页「发现音乐」压在收藏页「我喜欢的音乐」上）。
// 页内各铺一层这份不透明纸底，滑入的新页才能完全盖住旧页。
val PaperBrush: Brush = Brush.verticalGradient(
    listOf(
        Color(0xFFFAF8F3),
        Color(0xFFFAF8F3),
        Color(0xFFF7F2E8),
        Color(0xFFF1EDE2)
    )
)

@Composable
fun AppBackground(content: @Composable () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(PaperBrush)
    ) {
        content()
    }
}

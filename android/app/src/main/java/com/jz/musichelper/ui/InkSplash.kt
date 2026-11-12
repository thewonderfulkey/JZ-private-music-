package com.jz.musichelper.ui

import android.graphics.BitmapFactory
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Canvas as AndroidCanvas
import android.provider.Settings
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect as GeoRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ClipOp
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jz.musichelper.R
import com.jz.musichelper.ui.theme.InkTitleFont
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 首页"已就绪"信号：首页首帧真正画出来之后置真。
 * 开场动画在"墨满"阶段等它——首页没画出来就压着黑，不让用户看到纸底空窗（最多到兜底上限）。
 */
internal object SplashGate {
    val homeReady = mutableStateOf(false)
    fun markReady() { homeReady.value = true }
}

// ===== 设计坐标系：与《开场动画预览-v53.html》的 viewBox 完全一致（390×844）=====
private const val DW = 390f
private const val DH = 844f
// v2.1.73：山水位图在设计坐标里画 633×844（素材原生 1773×2364，比例正好 0.75），
// 宽度多出来的 243 是留给宽屏的"溢墨"——手机上被屏幕右缘裁掉，平板/宽屏则正好露出来。
private const val INK_W = 633f

// ===== 时间轴（毫秒，逐条对齐预览脚本）=====
private const val T_LONG = 180f        // 山：湿边前缘起推
private const val T_FLOW = 1150f       // 飞瀑：水起身
private const val T_POOL = 3170f       // 落水：水雾荡开
private const val T_SND = 3330f        // 流水成音
private const val T_GROW = 3950f       // 瀑底音符升起（收尾起势）
private const val T_VEIL = 4030f       // 墨开始从四周合拢（音符开口起收）
private const val T_OUT = 4030f        // 主循环跑到这里，交给"缩小 → 放大"两段
private const val T_CLOSE_DUR = 330f   // 第一段：墨合拢，山水收成一枚音符（音符缩小）
private const val T_OPEN_DUR = 360f    // 第二段：音符放大，把音乐界面让出来
private const val CLOSE_SHARE = T_CLOSE_DUR / (T_CLOSE_DUR + T_OPEN_DUR)
private const val HOLE_K0 = 44f        // 音符开口最小高度（设计单位，收拢/放大共用）
private const val HOLE_KFULL = 3400f   // 开口盖满整屏的高度（实测 3200 即 100%，留 6% 余量）
private const val HOLE_KMID = 600f     // 缩放曲线的分界：小于它时慢慢等比放大（音符轮廓看得清）
private const val HOLE_KBIG = 1700f    // 合拢段"一大枚音符"的高度（墨压到位后从这里开始等比收）
private const val HOLE_CX = 195f       // 开口中心 x（=DW/2，与符头中心重合）
private const val HOLE_CY = 405f       // 开口中心 y（符头中心，略高于正中）
private const val T_TXT = 1480f        // 题字逐字落
private const val T_SUB = 2140f
private const val T_SEAL = 2560f
private const val T_SKIP = 900f
private const val T_STAFF = 520f
private const val T_STAFF2 = 1720f
private const val T_NOTE2 = 1900f
private const val MAX_HOLD_MS = 6500f  // 兜底：墨满后最多压 6.5s
private const val HOLD_CAP = 380f      // 等首页就绪最多再等 0.38s（等太久会显"黑屏卡住"）
private const val TOTAL_MS = 5280f     // 全片时长（末时序 ≈4.98s，留 0.3s 余量）

// 纸色：新画卷（ink_main.png）四角实测 ≈ #FAF5EC，与主题 windowBackground 同色
private val SplashPaper = Color(0xFFFAF5EC)
private val SplashInk = Color(0xFF2A2622)
private val SplashSeal = Color(0xFFB4453A)
private val SplashDark = Color(0xFF1A1612)
private val SplashSoak = Color(0xFF151210)
private val SplashPress = Color(0xFF181410)   // 收尾墨环（合拢后压在音符外的一切）

private fun cl(x: Float): Float = if (x < 0f) 0f else if (x > 1f) 1f else x
private fun easeOut(t: Float): Float { val c = cl(t); val m = 1f - c; return 1f - m * m * m }
private fun easeIO(t: Float): Float {
    val c = cl(t)
    return if (c < 0.5f) 4f * c * c * c else {
        val p = -2f * c + 2f
        1f - (p * p * p) / 2f
    }
}
private fun lin(a: Float, b: Float, t: Float): Float = a + (b - a) * cl(t)

/** 三羽淡墨：自右向左横过雾带，各扇各的翅 */
private class Bird(
    val fx: Float, val tx: Float, val sy: Float, val dy: Float,
    val dur: Float, val t0: Float, val sc: Float, val ph: Float
)

private val BIRDS = listOf(
    Bird(1.22f, -0.14f, 0.298f, -0.012f, 4400f, 1180f, 0.78f, 0.00f),
    Bird(1.15f, -0.08f, 0.268f, 0.009f, 4950f, 1560f, 0.63f, 2.20f),
    Bird(1.28f, -0.16f, 0.334f, -0.006f, 5300f, 2010f, 0.52f, 4.10f)
)

/** 脊上三株墨树：整株绕根轻转，相位各不相同 */
private class Tree(val bx: Float, val by: Float, val amp: Float, val ph: Float, val per: Float)

private val TREES = listOf(
    Tree(77f, 459f, 6.0f, 0.00f, 4200f),
    Tree(126f, 452f, 6.6f, 2.30f, 4700f),
    Tree(190f, 404f, 5.2f, 4.10f, 5200f)
)

private class Rect2(val x: Float, val y: Float, val w: Float, val h: Float)

private val TREE_RECTS = listOf(
    Rect2(52.13f, 407.01f, 63.91f, 72.12f),
    Rect2(86.04f, 379.87f, 72.12f, 79.97f),
    Rect2(153.88f, 339.17f, 79.97f, 83.90f)
)

/** 画面静止的那一段（雾带里的淡墨）：给写实水练让位，涟漪与水雾在瀑底 */
private val WAVES = listOf(Triple(0f, 760f, 0f), Triple(150f, 820f, 0f), Triple(310f, 880f, 0f))
private val RIPPLE_START = listOf(3120f, 3460f, 3790f)

/** 按设计坐标铺一层图（内部做整型取整，避免 dst 尺寸走浮点） */
private fun DrawScope.put(
    img: ImageBitmap?, x: Float, y: Float, w: Float, h: Float,
    alpha: Float = 1f, blend: BlendMode = BlendMode.SrcOver
) {
    if (img == null || alpha <= 0.001f) return
    drawImage(
        image = img,
        srcOffset = IntOffset.Zero,
        srcSize = IntSize(img.width, img.height),
        dstOffset = IntOffset(x.roundToInt(), y.roundToInt()),
        dstSize = IntSize(w.roundToInt(), h.roundToInt()),
        alpha = alpha,
        blendMode = blend
    )
}

/** v2.1.73：等比映射——按屏高等比缩放（k = 高/DH），不再横向拉伸；
 *  横向以"墨图左对齐"落位，手机裁掉右侧溢墨、平板正好露出，峰值始终贴在设计位。 */
private inline fun DrawScope.design(k: Float, ox: Float, crossinline block: DrawScope.() -> Unit) {
    translate(ox, 0f) { scale(scaleX = k, scaleY = k, pivot = Offset.Zero) { block() } }
}

/** v2.1.73：墨图的横向落位（墨图比屏宽就左对齐裁右缘，比屏宽窄就居中），
 *  山水 / 题字 / 印章 / 跳过 / 音符洞口全部共用这一处口径。 */
private fun inkOx(w: Float, h: Float): Float {
    val s = h / DH
    return if (INK_W * s >= w) 0f else (w - INK_W * s) / 2f
}

/**
 * 山水水墨开场（v2.1.52 落码版）：整条时间轴与《开场动画预览-v53.html》一一对应。

 * 图层（自下而上）：
 *  ① 纸底 → ②-a 远山雾带（y 330→374 那一条，与山体共用同一道墨前，只在墨走过处出现）
 *  → ②-b 山体 + 三株脊树（湿边自左推入，前缘 46px 纸色羽化）→ ②-c 飞瀑墨丝（离屏 DST_IN 裁进水练形状）
 *  → ②-d 瀑底水面 → ③④⑤ 水雾 / 涟漪 / 三羽飞鸟 → ⑥ 题字（四字逐字、知音常在、朱印、跳过）
 *  → ⑦ 谱线与墨音符 → ⑧ 墨环（收拢段压开口以外）→ ⑨ 纸色转角（开口内最后 22% 转纸色）
 *
 * 收尾（v2.1.56 起）：一条音符路径两段用 —— 墨从四周合拢＝音符缩小（330ms）→ 纸音符 → 音符放大＝
 * 首页从音符形状里出来（360ms）；放大段用根层 `ClipOp.Difference` 挖掉开口，不依赖任何混合模式。

 * 与预览的唯一差别：预览里的"首页"是假图；App 里首页是真页面，所以"墨退"直接淡出整层（同时等
 * SplashGate.homeReady），不做假首页的错峰浮现。
 */
@Composable
fun InkSplash(onFinished: () -> Unit) {
    val ctx = LocalContext.current

    // —— 素材（同一套位图，一次解码；遮罩一律转成 alpha 图，Android 的 DstIn 取 alpha 不取亮度）——
    val bmpMain = remember { decode(ctx, R.drawable.splash_ink_main) }
    val bmpTreeA = remember { decode(ctx, R.drawable.splash_tree_a) }
    val bmpTreeB = remember { decode(ctx, R.drawable.splash_tree_b) }
    val bmpTreeC = remember { decode(ctx, R.drawable.splash_tree_c) }
    val bmpFlow = remember { decode(ctx, R.drawable.splash_flow) }
    val bmpFlowMask = remember { decode(ctx, R.drawable.splash_flow_mask) }
    val bmpPool = remember { decode(ctx, R.drawable.splash_pool) }

    // 飞瀑的"水练形状"改成在离屏 Bitmap 里用 android.graphics 的 PorterDuff.DST_IN 合成：
    // 实测 Compose 的 BlendMode.DstIn 在本机运行时不生效（白遮罩被当白图贴、纹理溢出），
    // 而 android.graphics 的 xfermode 是同一套 Skia、行为恒定。画布只有 104×184 设计像素 ×3。
    val FLOW_K = 3f
    val flowTile = remember(bmpFlow) { bmpFlow?.asAndroidBitmap() }
    val flowMaskLayer = remember(bmpFlowMask) { bmpFlowMask?.asAndroidBitmap() }
    val flowLayer = remember {
        android.graphics.Bitmap.createBitmap(
            (104f * 3f).toInt(), (184f * 3f).toInt(),
            android.graphics.Bitmap.Config.ARGB_8888
        )
    }
    val flowCanvas = remember(flowLayer) { AndroidCanvas(flowLayer) }
    val flowPaint = remember { Paint(Paint.FILTER_BITMAP_FLAG) }
    val flowXfer = remember { PorterDuffXfermode(PorterDuff.Mode.DST_IN) }
    val flowTileRect = remember { Rect() }
    val flowTileDst = remember { RectF() }
    val flowLayerRect = remember { RectF(0f, 0f, flowLayer.width.toFloat(), flowLayer.height.toFloat()) }
    val flowDstRect = remember { RectF(252f, 458f, 356f, 642f) }

    // 飞鸟双翼：左翼长一分、右翼短一分（对称的 V 字就是"贴上去的符号"）
    val wingL = remember {
        Path().apply {
            moveTo(0f, 0f)
            quadraticTo(-6.6f, -5.4f, -12.4f, -0.4f)
        }
    }
    val wingR = remember {
        Path().apply {
            moveTo(0f, 0f)
            quadraticTo(5.4f, -4.3f, 10.2f, -1.9f)
        }
    }

    val reduceMotion = remember {
        try {
            Settings.Global.getFloat(ctx.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
        } catch (e: Exception) {
            false
        }
    }
    val scope = rememberCoroutineScope()

    var t by remember { mutableStateOf(0f) }     // 片内时间（ms）
    var vf by remember { mutableStateOf(0f) }    // 收尾进度 0→1：0→CLOSE_SHARE 是"音符缩小"，之后是"音符放大"
    val finished = remember { mutableStateOf(false) }
    val finish: () -> Unit = {
        if (!finished.value) {
            finished.value = true
            onFinished()
        }
    }

    LaunchedEffect(Unit) {
        if (reduceMotion) {
            vf = 1f          // 减弱动效：不做收尾两段，直接交回首页
            finish()
            return@LaunchedEffect
        }
        // 等首帧真正上屏再起表（冷启动时 LaunchedEffect 先跑，画面要过几百毫秒才出第一帧）
        var t0 = 0L
        withFrameNanos { }
        withFrameNanos { t0 = it }
        var now = t0
        while (true) {
            now = withFrameNanos { it }
            val ms = (now - t0) / 1_000_000f
            t = if (ms > TOTAL_MS) TOTAL_MS else ms
            if (ms >= T_OUT || finished.value) break
        }
        if (finished.value) return@LaunchedEffect
        // 第一段：墨从四周合拢，把山水收成一枚音符（这一段就是用户要"看得出音符在缩小"）
        Animatable(0f).animateTo(CLOSE_SHARE, tween(T_CLOSE_DUR.toInt(), easing = LinearEasing)) { vf = value }
        if (finished.value) return@LaunchedEffect
        // 收成一枚纸色音符后，等首页真画出帧——最多再等 HOLD_CAP(0.38s)，
        // 这段停住的是"黑底上一枚纸音符"，看着是有意为之，不是卡住
        if (!SplashGate.homeReady.value) {
            val holdFrom = System.nanoTime()
            while (!SplashGate.homeReady.value) {
                withFrameNanos { }
                if ((System.nanoTime() - holdFrom) / 1_000_000f > HOLD_CAP) break
            }
        }
        // 第二段：音符放大，界面从音符形状里被让出来（这一段要慢到能看出音符轮廓）
        Animatable(CLOSE_SHARE).animateTo(1f, tween(T_OPEN_DUR.toInt(), easing = LinearEasing)) { vf = value }
        finish()
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            // 收尾两段共用一条"音符开口"路径：
            //   收拢段（vf ≤ CLOSE_SHARE）：整层照常画，墨环只压开口以外，开口里留着山水；
            //   放大段（vf > CLOSE_SHARE）：把开口从这一层里减掉，音乐界面就从音符形状里露出来。
            // 用 ClipOp.Difference，不依赖任何混合模式，也不依赖路径布尔运算。
            .drawWithContent {
                if (vf > CLOSE_SHARE + 0.002f) {
                    val layer = this
                    // 这一层在 content 之外，取不到 ox → 用同一个 helper 现算（横纵同一套映射）
                    clipPath(
                        noteHolePath(size, tailK(vf), inkOx(size.width, size.height)),
                        ClipOp.Difference
                    ) { layer.drawContent() }
                } else {
                    drawContent()
                }
            }
    ) {
        val wPx = constraints.maxWidth.toFloat()
        val hPx = constraints.maxHeight.toFloat()
        // v2.1.73 自适应：k = 屏高 / 设计高 —— 全画面等比缩放，横纵同倍，永不拉伸。
        // 横向落位：墨图（633 设计宽）比屏幕宽时左对齐裁右侧，比屏幕窄时居中（横屏场景）。
        val density = LocalDensity.current
        val k = hPx / DH
        val ox = inkOx(wPx, hPx)
        // 屏幕宽度折算成"设计 dp"，减去设计稿的 390 → 「跳过」回到真实右缘所需补位
        val skipDx = (wPx - ox) / k - DW

        // ⓪ 触摸拦截层：开场期间首页不可点（不消费滑动，只吞点按）；「跳过」在它上层，仍可点
        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(Unit) { detectTapGestures { } }
        )

        // ① 纸底（收尾交给音符洞口，这里不再淡出）
        Canvas(modifier = Modifier.fillMaxSize()) {
            drawRect(SplashPaper)
        }

        // ② 画卷（整层随收束极轻微推近 + 墨满时再推 10%，并在墨满后淡出）
        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    val drift = easeIO(cl(t / T_OUT))
                    val s = (1.04f - 0.04f * drift) * (1f + 0.10f * cl((t - T_VEIL) / 400f))
                    scaleX = s
                    scaleY = s
                    transformOrigin = TransformOrigin(0.5f, 0.40f)
                    alpha = (1f - cl((t - (T_VEIL + 30f)) / 260f))
                }
        ) {
            // ②-a 远山与雾带：只取 y 330→374 这一条。它必须与山体共用同一道"墨前"向右推进——
            //      v2.1.56 真机反馈：这一条原来是整幅宽度一起淡入，结果画面中右侧的山脊比墨提前浮出来，
            //      "不是由空白到显现"。现在只在墨已经走过的地方才出现（前缘同样 46px 纸色羽化）。
            Box(
                modifier = Modifier.fillMaxSize().graphicsLayer {
                    alpha = easeIO(cl((t - 200f) / 1000f))
                }
            ) {
                Canvas(Modifier.fillMaxSize()) {
                    design(k, ox) {
                        val front = INK_W * easeIO(cl((t - T_LONG) / 1440f))
                        if (front > 0.5f) {
                            clipRect(0f, 330f, min(INK_W, front), 374f) {
                                put(bmpMain, 0f, 0f, INK_W, 844f)
                            }
                            if (front < INK_W) {
                                val x0 = max(0f, front - 46f)
                                drawRect(
                                    brush = Brush.horizontalGradient(
                                        0f to SplashPaper.copy(alpha = 0f),
                                        1f to SplashPaper,
                                        startX = x0,
                                        endX = front
                                    ),
                                    topLeft = Offset(x0, 330f),
                                    size = Size(front - x0, 44f)
                                )
                            }
                        }
                    }
                }
            }

            // ②-b 山体 + 三株脊树：湿边前缘自左边缘（x=0）推到右（x=470）。起点归零是要求之一——
            //      首帧整纸空白，墨从左沿一点点长进来；前缘 46px 用纸色渐变把墨"洇"下去
            Box(
                modifier = Modifier.fillMaxSize().graphicsLayer {
                    alpha = 0.92f
                }
            ) {
                Canvas(Modifier.fillMaxSize()) {
                    design(k, ox) {
                        val front = INK_W * easeIO(cl((t - T_LONG) / 1440f))
                        clipRect(0f, 0f, min(INK_W, max(0f, front)), DH) {
                            put(bmpMain, 0f, 0f, INK_W, 844f)
                            val treeBmps = listOf(bmpTreeA, bmpTreeB, bmpTreeC)
                            TREES.forEachIndexed { i, tr ->
                                val an = tr.amp * (
                                    0.74f * sin(t * 6.2832f / tr.per + tr.ph) +
                                        0.26f * sin(t * 11.4f / tr.per + tr.ph * 1.7f)
                                    )
                                val r = TREE_RECTS[i]
                                rotate(an, pivot = Offset(tr.bx, tr.by)) {
                                    put(treeBmps[i], r.x, r.y, r.w, r.h)
                                }
                            }
                        }
                        // 前缘羽化：46px 内纸色由 0 加深到 1，墨迹向前缘"渗进纸里"（长满后不再羽化）
                        if (front < INK_W) {
                            val x0 = max(0f, front - 46f)
                            drawRect(
                                brush = Brush.horizontalGradient(
                                    0f to SplashPaper.copy(alpha = 0f),
                                    1f to SplashPaper,
                                    startX = x0,
                                    endX = front
                                ),
                                topLeft = Offset(x0, 0f),
                                size = Size(front - x0, DH)
                            )
                        }
                    }
                }
            }

            // ②-c 飞瀑：两层同一张 2×2 无缝水痕瓦片，错速**向下**落（瀑布是往下坠的），
            //      在 104×184 的离屏画布里按 splash_flow_mask 做 DST_IN，水丝一律裁在水练形状内
            Box(
                modifier = Modifier.fillMaxSize().graphicsLayer {
                    val flA = cl((t - T_FLOW) / 700f)
                    val flOut = 1f - cl((t - (T_VEIL - 40f)) / 300f)
                    alpha = 0.80f * flA * flOut
                }
            ) {
                Canvas(Modifier.fillMaxSize()) {
                    design(k, ox) {
                        val tile = flowTile
                        val mask = flowMaskLayer
                        if (tile != null && mask != null && flowTileRect.width() == 0) {
                            flowTileRect.set(0, 0, tile.width, tile.height)
                        }
                        if (tile != null && mask != null) {
                            val c = flowCanvas
                            c.drawColor(0, PorterDuff.Mode.CLEAR)
                            val p = flowPaint
                            // y 递增 = 纹理向下走；单格 208×416，铺 3 格保证 184 高的水练无缝
                            val ph1 = (t * 0.340f) % 208f
                            val ph2 = (t * 0.620f) % 208f
                            for (pass in 0..1) {
                                val ph = if (pass == 0) ph1 else ph2
                                p.alpha = if (pass == 0) 255 else (255 * 0.48f).toInt()
                                p.xfermode = null
                                for (k in -1..1) {
                                    val top = (ph + k * 416f) * FLOW_K
                                    flowTileDst.set(0f, top, 208f * FLOW_K, top + 416f * FLOW_K)
                                    c.drawBitmap(tile, flowTileRect, flowTileDst, p)
                                }
                            }
                            p.alpha = 255
                            p.xfermode = flowXfer
                            c.drawBitmap(mask, null, flowLayerRect, p)
                            p.xfermode = null
                            drawIntoCanvas { cv ->
                                cv.nativeCanvas.drawBitmap(flowLayer, null, flowDstRect, p)
                            }
                        }
                    }
                }
            }

            // ②-d 瀑底水面：一版稀疏短横笔（12 笔，横向无缝），上缘渐隐已烘进贴图 alpha，
            //      只做极慢的横向游走 —— 不再叠遮罩、不再往上飘，也不再铺 46 笔把水面画成"栅格"
            Box(
                modifier = Modifier.fillMaxSize().graphicsLayer {
                    val flOut = 1f - cl((t - (T_VEIL - 40f)) / 300f)
                    alpha = if (bmpPool == null) 0f
                            else 0.55f * cl((t - (T_FLOW + 420f)) / 900f) * flOut
                }
            ) {
                Canvas(Modifier.fillMaxSize()) {
                    design(k, ox) {
                        val bmp = bmpPool ?: return@design
                        val dx = (t * 0.160f) % DW
                        put(bmp, -dx, 610f, DW, 140f)
                        put(bmp, DW - dx, 610f, DW, 140f)
                    }
                }
            }
        }

        // ③ 瀑底水雾：三圈淡墨自落水处荡开，越远越淡
        Canvas(
            modifier = Modifier.fillMaxSize().graphicsLayer {
                alpha = (1f - cl((t - (T_VEIL - 100f)) / 260f))
            }
        ) {
            design(k, ox) {
                WAVES.forEach { wv ->
                    val wp = cl((t - (T_POOL + wv.first)) / wv.second)
                    if (wp <= 0f || wp >= 1f) return@forEach
                    val op = 0.22f * (1f - wp) * (1f - wp)
                    val s = 0.28f + 1.85f * easeOut(wp)
                    val cy = 601f - 3f * wp
                    drawOval(
                        color = Color(0xFF221D18).copy(alpha = 0.26f),
                        topLeft = Offset(303f - 43f * s, cy - 26f * s * 0.40f),
                        size = Size(86f * s, 52f * s * 0.40f),
                        style = Stroke(1.2f),
                        alpha = op
                    )
                }
            }
        }

        // ④ 水面涟漪：落水处一圈圈推到远处的水面上
        Canvas(
            modifier = Modifier.fillMaxSize().graphicsLayer {
                alpha = (1f - cl((t - (T_VEIL - 100f)) / 260f))
            }
        ) {
            design(k, ox) {
                RIPPLE_START.forEachIndexed { i, start ->
                    val rp = cl((t - start) / 1400f)
                    if (rp <= 0f || rp >= 1f) return@forEachIndexed
                    val w = 40f + 150f * easeOut(rp)
                    val h = 7f + 20f * easeOut(rp)
                    val cy = 844f - (152f + i * 15f) - h / 2f
                    drawOval(
                        color = SplashInk.copy(alpha = 0.26f),
                        topLeft = Offset(304f - w / 2f, cy - h / 2f),
                        size = Size(w, h),
                        style = Stroke(1f),
                        alpha = 0.30f * (1f - rp) * (1f - rp)
                    )
                }
            }
        }

        // ⑤ 三羽飞鸟
        Canvas(
            modifier = Modifier.fillMaxSize().graphicsLayer {
                alpha = (1f - cl((t - (T_VEIL - 100f)) / 260f))
            }
        ) {
            design(k, ox) {
                BIRDS.forEach { b ->
                    val bp = cl((t - b.t0) / b.dur)
                    if (bp <= 0f || bp >= 1f) return@forEach
                    val fadeIn = cl(bp / 0.14f)
                    val fadeOut = cl((1f - bp) / 0.18f)
                    val op = min(fadeIn, fadeOut) * 0.48f
                    val x = lin(b.fx * DW, b.tx * DW, bp) + 2.0f * sin(bp * PI.toFloat() * 3f + b.ph)
                    val y = b.sy * DH + b.dy * DH * sin(bp * PI.toFloat())
                    val flap = sin(t * 0.0172f + b.ph)
                    translate(x, y + 0.9f * flap * b.sc) {
                        rotate(-2.5f + bp * 2.5f + 1.6f * flap, pivot = Offset.Zero) {
                            scale(b.sc, b.sc, Offset.Zero) {
                                rotate(-9f * flap, Offset.Zero) {
                                    drawPath(
                                        wingL, SplashInk.copy(alpha = 0.72f),
                                        alpha = op, style = Stroke(1.05f, cap = StrokeCap.Round)
                                    )
                                }
                                rotate(9f * flap, Offset.Zero) {
                                    drawPath(
                                        wingR, SplashInk.copy(alpha = 0.72f),
                                        alpha = op, style = Stroke(1.05f, cap = StrokeCap.Round)
                                    )
                                }
                                drawOval(
                                    color = SplashInk.copy(alpha = 0.55f),
                                    topLeft = Offset(-1.9f, -0.65f),
                                    size = Size(3.8f, 2.3f),
                                    alpha = op
                                )
                            }
                        }
                    }
                }
            }
        }

        // ⑥ 题字层：整层按 390×844 设计稿**等比**缩放（v2.1.73：原来横纵各自拉伸，
        //   平板 800×1280 上横向比纵向多 35%，题字/印章被拉扁——现在只用屏高算一个比例 r）
        val r = k / density.density                       // 设计 dp → 设备 dp 的比例
        val textOut = cl((t - (T_VEIL - 60f)) / 240f)
        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    alpha = (1f - textOut)
                    translationY = -14.dp.toPx() * textOut
                }
        ) {
            Box(
                modifier = Modifier
                    .requiredSize(390.dp, 844.dp)
                    .graphicsLayer {
                        scaleX = r
                        scaleY = r
                        translationX = ox
                        transformOrigin = TransformOrigin(0f, 0f)
                    }
            ) {
                // 「高山流水」四字逐字落纸
                Row(modifier = Modifier.offset(x = 26.dp, y = 104.dp)) {
                    "高山流水".forEachIndexed { i, c ->
                        val cp = cl((t - (T_TXT + i * 120f)) / 520f)
                        Text(
                            c.toString(),
                            color = SplashInk,
                            fontSize = 34.sp,
                            fontFamily = InkTitleFont,
                            letterSpacing = 4.4.sp,
                            modifier = Modifier.graphicsLayer {
                                alpha = cp
                                translationY = (1f - easeOut(cp)) * 15.dp.toPx()
                            }
                        )
                    }
                }

                // 「知 音 常 在」
                val sA = cl((t - T_SUB) / 380f)
                Text(
                    "知 音 常 在",
                    color = SplashInk.copy(alpha = 0.58f),
                    fontSize = 11.sp,
                    letterSpacing = 2.9.sp,
                    modifier = Modifier
                        .offset(x = 29.dp, y = 166.dp)
                        .graphicsLayer {
                            alpha = sA * 0.92f
                            translationY = (1f - easeOut(sA)) * 6.dp.toPx()
                        }
                )

                // 朱印
                val kA = cl((t - T_SEAL) / 240f)
                Box(
                    modifier = Modifier
                        .offset(x = 29.dp, y = 200.dp)
                        .size(30.dp)
                        .graphicsLayer {
                            alpha = kA
                            val s = 0.86f + 0.14f * easeOut(kA)
                            scaleX = s
                            scaleY = s
                            rotationZ = -4f + 2f * easeOut(kA)
                        }
                        .clip(RoundedCornerShape(4.dp))
                        .background(SplashSeal),
                    contentAlignment = Alignment.Center
                ) {
                    Text("JZ", color = Color(0xFFFFF6F0), fontSize = 10.sp, letterSpacing = 0.6.sp)
                }

                // 「跳过」：立即可用，点一下直接交回首页。
                //   2026-11-08 反馈"太小、太不引人注目" → 外观 26→34dp 高、字 10.5→13sp、
                //   纸底 0.5→0.86、墨字 0.42→0.80、描边 0.13→0.26；外面再包一个 44dp 的透明热区。
                //   同日第二条反馈"位置有点问题" → 竖向与「高山流水」齐平：标题墨色包围盒在设计坐标
                //   y 110.5→141.5dp、中心 126dp（按已验收基准帧 k62_b.png 量的），所以胶囊中心也要落在
                //   126dp：热区 44dp 居中 → 顶上沿 = 126-22 = 104dp（原来 64dp，整整高出一行标题）
                Box(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .offset(x = ((-18).dp + skipDx.dp), y = 104.dp)
                        .size(width = 96.dp, height = 44.dp)
                        .graphicsLayer { alpha = cl((t - T_SKIP) / 300f) }
                        .inkClickable {
                            scope.launch {
                                if (!finished.value) {
                                    // 跳过也走同一条"收成一枚音符 → 音符放大"的路，只是快一倍
                                    Animatable(vf).animateTo(CLOSE_SHARE, tween(140, easing = LinearEasing)) {
                                        vf = value
                                    }
                                    Animatable(CLOSE_SHARE).animateTo(1f, tween(160, easing = LinearEasing)) {
                                        vf = value
                                    }
                                    finish()
                                }
                            }
                        },
                    contentAlignment = Alignment.Center
                ) {
                    Box(
                        modifier = Modifier
                            .height(34.dp)
                            .clip(RoundedCornerShape(17.dp))
                            .background(SplashPaper.copy(alpha = 0.86f))
                            .border(1.dp, SplashInk.copy(alpha = 0.26f), RoundedCornerShape(17.dp))
                            .padding(horizontal = 15.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            "跳 过",
                            color = SplashInk.copy(alpha = 0.80f),
                            fontSize = 13.sp,
                            letterSpacing = 2.sp
                        )
                    }
                }
            }
        }

        // ⑦ 谱线与墨音符：一条墨线 → 五条谱线，小音符自左走到墨漫开始（可见的"加载"）
        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    alpha = (1f - cl((t - (T_VEIL - 80f)) / 220f))
                    compositingStrategy = CompositingStrategy.Offscreen
                }
        ) {
            Canvas(Modifier.fillMaxSize()) {
                design(k, ox) {
                    val sp1 = cl((t - T_STAFF) / 1120f)
                    val lineW = 260f * easeOut(sp1)
                    val lineOp = 1f - cl((t - (T_STAFF2 - 60f)) / 260f)
                    if (lineW > 0.5f) {
                        drawLine(
                            color = SplashInk.copy(alpha = 0.22f),
                            start = Offset(195f - lineW / 2f, 736f),
                            end = Offset(195f + lineW / 2f, 736f),
                            strokeWidth = 1f,
                            alpha = lineOp
                        )
                    }
                    val sp2 = cl((t - T_STAFF2) / 300f)
                    for (si in 0..4) {
                        val sj = cl((sp2 - si * 0.09f) / 0.72f)
                        if (sj <= 0f) continue
                        val y = 736f + (si - 2) * 5.8f
                        drawLine(
                            color = SplashInk.copy(alpha = 0.52f * sj),
                            start = Offset(65f, y),
                            end = Offset(65f + 260f * easeOut(sj), y),
                            strokeWidth = 1f
                        )
                    }

                    // 墨音符：从谱线左端一路走到墨漫开始
                    val lp = 0.97f * cl((t - T_NOTE2) / (T_VEIL - T_NOTE2))
                    val noteOp = cl((t - T_NOTE2) / 220f) * (1f - cl((t - T_VEIL) / 200f))
                    if (noteOp > 0f) {
                        val sndP = cl((t - T_SND) / 420f)
                        val grow = cl((t - T_GROW) / 400f)
                        val rise = easeOut(cl((t - T_SND) / 900f))
                        val sndX = 300f + 40f * rise - 4f * grow
                        val sndY = 598f - 238f * rise + sin(t / 260f) * 1.2f
                        val sndScale = 0.72f + 0.28f * easeOut(sndP)
                        val bob = sin(t / 190f) * 1.1f
                        // 谱线上的小音符
                        translate(195f + (-130f + 236f * lp), 724f + bob) {
                            rotate(-2.5f, pivot = Offset(9f, 14.6f)) {
                                drawNote(alpha = noteOp)
                            }
                        }
                        // 水声升起的墨音符（瀑底 → 瀑布右上方）
                        translate(sndX - 15f, sndY - 20f) {
                             translate(-4f * grow, 0f) {
                                scale(sndScale, sndScale, pivot = Offset(15f, 24.8f)) {
                                    rotate(-3f + 2f * grow, pivot = Offset(15f, 24.8f)) {
                                        drawNote(alpha = noteOp)
                                    }
                                }
                            }
                        }
                    }
                    // 谱线区左右两端渐隐（避免线条在 x=65/325 处硬切）
                    drawRect(
                        brush = Brush.horizontalGradient(
                            0f to Color.Transparent,
                            0.17f to Color.Transparent,
                            0.25f to Color.White,
                            0.75f to Color.White,
                            0.83f to Color.Transparent,
                            1f to Color.Transparent,
                            startX = 0f,
                            endX = DW
                        ),
                        topLeft = Offset(0f, 690f),
                        size = Size(DW, 110f),
                        blendMode = BlendMode.DstIn
                    )
                }
            }
        }

        // ⑧ 收尾：墨从四周合拢——音符开口以外一律压成墨。收拢段里开口内留着山水，
        //    放大段里开口内是下层首页（本层已被外层 Difference 挖掉，这里只是把外面再兜一遍）。
        Canvas(modifier = Modifier.fillMaxSize()) {
            if (vf > 0.002f) {
                clipPath(noteHolePath(size, tailK(vf), ox), ClipOp.Difference) {
                    drawRect(color = SplashPress)
                }
            }
        }

        // ⑨ 开口内收拢末段转纸色：山水最后一小块变成"纸音符"，接上放大段从纸上展开
        Canvas(modifier = Modifier.fillMaxSize()) {
            if (vf > 0.002f && vf <= CLOSE_SHARE + 0.002f) {
                val paperA = cl((vf / CLOSE_SHARE - 0.78f) / 0.22f)
                if (paperA > 0.002f) {
                    clipPath(noteHolePath(size, tailK(vf), ox), ClipOp.Intersect) {
                        drawRect(color = SplashPaper, alpha = paperA)
                    }
                }
            }
        }
    }
}

/**
 * 收尾的"洞口"：一个不断放大的墨音符（与谱线上的小音符同构：符头 + 符干 + 符尾）。
 * k = 音符高度（设计单位）；返回设备像素坐标下的实心路径。
 * v2.1.73：横纵同用"屏高比例"，与山水图层同一套等比映射，不再横向拉伸。
 */
private fun noteHolePath(size: Size, k: Float, ox: Float = 0f): Path {
    val s = size.height / DH                        // 设计单位 → 设备像素（等比）
    val u = (k / 22f) * s                          // 音符格子 1 格的边长（横纵同比，不走形）
    val cx = ox + HOLE_CX * s
    val cy = HOLE_CY * s
    fun gx(v: Float) = cx + (v - 9.6f) * u            // 以"符头中心"对齐洞心：放大到底时符头盖满整屏
    fun gy(v: Float) = cy + (v - 14.8f) * u
    val p = Path()
    // 符头
    p.addOval(GeoRect(gx(4.6f), gy(11.2f), gx(14.6f), gy(18.4f)))
    // 符干
    p.addRect(GeoRect(gx(12.5f), gy(2.2f), gx(14.3f), gy(15.4f)))
    // 符尾：一笔向右下的弧
    p.moveTo(gx(14.3f), gy(2.0f))
    p.quadraticTo(gx(17.7f), gy(3.3f), gx(17.1f), gy(7.8f))
    p.lineTo(gx(14.3f), gy(6.1f))
    p.close()
    return p
}

/**
 * 收拢段：起点墨已铺满整屏，先快速压到"一大枚音符"（前 22%，约 70ms，墨到位不拖），
 * 再用等比速度收到最小音符（后 78%，约 260ms，每帧缩同样的比例，一路都看得出是音符在缩）。
 */
private fun closeK(u: Float): Float {
    val uu = cl(u)
    return if (uu < 0.22f) {
        HOLE_KFULL - (HOLE_KFULL - HOLE_KBIG) * smoothO(uu / 0.22f)
    } else {
        val s = cl((uu - 0.22f) / 0.78f)
        HOLE_KBIG * (HOLE_K0 / HOLE_KBIG).pow(s)
    }
}

/**
 * 放大段：u=0 → 最小音符，u=1 → 盖满整屏。
 *   前 42%：从最小音符按等比放大到 HOLE_KMID —— 音符轮廓一路看得见，不会一帧跳大；
 *   后 58%：按"面积匀速"（k 的平方线性）涨到盖满整屏 —— 收手均匀，不会到最后猛地一铺。
 */
private fun openK(u: Float): Float {
    val uu = cl(u)
    return if (uu < 0.42f) {
        val s = smoothO(uu / 0.42f)
        HOLE_K0 * (HOLE_KMID / HOLE_K0).pow(s)
    } else {
        val s = smoothO((uu - 0.42f) / 0.58f)
        val areaLo = HOLE_KMID * HOLE_KMID
        val areaHi = HOLE_KFULL * HOLE_KFULL
        sqrt(areaLo + (areaHi - areaLo) * s)
    }
}

private fun tailK(vf: Float): Float {
    return if (vf <= CLOSE_SHARE) {
        closeK(cl(vf / CLOSE_SHARE))
    } else {
        openK(cl((vf - CLOSE_SHARE) / (1f - CLOSE_SHARE)))
    }
}

private fun smoothO(p: Float): Float = p * p * (3f - 2f * p)

/** 墨音符：符干 + 符尾 + 符头（画在一个 18×22 的小格里） */
private fun DrawScope.drawNote(alpha: Float = 1f) {
    val ink = SplashInk.copy(alpha = 0.80f)
    drawLine(
        color = ink, start = Offset(13.2f, 2.6f), end = Offset(13.2f, 13.7f),
        strokeWidth = 1.5f, cap = StrokeCap.Round, alpha = alpha
    )
    val flag = Path().apply {
        moveTo(13.2f, 2.6f)
        quadraticTo(15.7f, 2.9f, 15.7f, 6.2f)
    }
    drawPath(flag, ink, alpha = alpha, style = Stroke(1.3f, cap = StrokeCap.Round))
    rotate(-14f, pivot = Offset(9.6f, 14.6f)) {
        drawOval(color = ink, topLeft = Offset(5.4f, 11.3f), size = Size(8.4f, 6.6f), alpha = alpha)
    }
}

private fun decode(ctx: android.content.Context, resId: Int): ImageBitmap? =
    try {
        BitmapFactory.decodeResource(ctx.resources, resId)?.asImageBitmap()
    } catch (e: Throwable) {
        null
    }

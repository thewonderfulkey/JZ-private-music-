# -*- coding: utf-8 -*-
import io

p = r"JZMusicHelperAndroid\app\src\main\java\com\jz\musichelper\ui\RecognizeScreen.kt"
s = io.open(p, encoding="utf-8").read()

def rep(old, new, count=1):
    global s
    assert s.count(old) >= 1, old[:60]
    s = s.replace(old, new, count)

# 1) MicField 支持缩放：出结果后麦克风缩小，把版面让给结果
rep(
"""private fun MicField(phase: RecPhase, level: Float, onClick: () -> Unit) {
    val p = LocalPalette.current
    val active = phase == RecPhase.LISTEN || phase == RecPhase.THINK""",
"""private fun MicField(phase: RecPhase, level: Float, scale: Float = 1f, onClick: () -> Unit) {
    val p = LocalPalette.current
    val active = phase == RecPhase.LISTEN || phase == RecPhase.THINK""")

rep("""    Box(
        modifier = Modifier.size(236.dp).inkClickable { onClick() },
        contentAlignment = Alignment.Center
    ) {""",
"""    Box(
        modifier = Modifier.size(236.dp * scale).inkClickable { onClick() },
        contentAlignment = Alignment.Center
    ) {""")

rep("""            val base = 62.dp.value * density""",
"""            val base = 62.dp.value * density * scale""")

rep("""        Box(
            modifier = Modifier
                .size(146.dp)""",
"""        Box(
            modifier = Modifier
                .size(146.dp * scale)""")

rep("""                modifier = Modifier.size(54.dp)""",
"""                modifier = Modifier.size(54.dp * scale)""")

# 2) 舞台高度 & 缩放：识别结果态收窄到 0.72
rep("""        val listening = listeningNow
        Box(
            modifier = Modifier.fillMaxWidth().height(252.dp),
            contentAlignment = Alignment.Center
        ) {
            MicField(phase = phase, level = level) {""",
"""        val listening = listeningNow
        // v2.1.86：出结果后麦克风缩到 0.72，把竖轴上方那 70dp 还给结果与版本列表（重听仍点这里）
        val micScale = if (phase == RecPhase.RESULT) 0.72f else 1f
        Box(
            modifier = Modifier.fillMaxWidth().height(252.dp * micScale),
            contentAlignment = Alignment.Center
        ) {
            MicField(phase = phase, level = level, scale = micScale) {""")

# 3) 结果签更紧凑
rep("""                .background(p.surface)
                .border(1.dp, p.text.copy(alpha = 0.10f))
                .padding(start = 18.dp, end = 18.dp, top = 14.dp, bottom = 16.dp)""",
"""                .background(p.surface)
                .border(1.dp, p.text.copy(alpha = 0.10f))
                .padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 12.dp)""")

rep("""            Spacer(Modifier.height(12.dp))
            Text(
                hit.title,
                fontSize = 28.sp,
                lineHeight = 36.sp,""",
"""            Spacer(Modifier.height(10.dp))
            Text(
                hit.title,
                fontSize = 26.sp,
                lineHeight = 33.sp,""")

rep("""            Spacer(Modifier.height(11.dp))
            Box(Modifier.width(28.dp).height(1.dp).background(p.text.copy(alpha = 0.30f)))
            Spacer(Modifier.height(10.dp))""",
"""            Spacer(Modifier.height(9.dp))
            Box(Modifier.width(28.dp).height(1.dp).background(p.text.copy(alpha = 0.30f)))
            Spacer(Modifier.height(9.dp))""")

rep("""            if (hit.album.isNotBlank()) {
                Spacer(Modifier.height(4.dp))""",
"""            if (hit.album.isNotBlank()) {
                Spacer(Modifier.height(3.dp))""")

rep("""        Spacer(Modifier.height(14.dp))

        // ---- 主操作：整条墨块，只此一处实心 ----""",
"""        Spacer(Modifier.height(12.dp))

        // ---- 主操作：整条墨块，只此一处实心 ----""")

rep("""                .fillMaxWidth()
                .height(46.dp)
                .background(p.text.copy(alpha = if (primaryEnabled) 1f else 0.42f))""",
"""                .fillMaxWidth()
                .height(44.dp)
                .background(p.text.copy(alpha = if (primaryEnabled) 1f else 0.42f))""")

rep("""        // ---- 次级动作：文字链，不再用第二个矩形 ----
        Spacer(Modifier.height(12.dp))""",
"""        // ---- 次级动作：文字链，不再用第二个矩形 ----
        Spacer(Modifier.height(10.dp))""")

rep("""        if (versions.isNotEmpty()) {
            Spacer(Modifier.height(18.dp))""",
"""        if (versions.isNotEmpty()) {
            Spacer(Modifier.height(14.dp))""")

rep("""            Spacer(Modifier.height(18.dp))
            SectionHead("同批候选", null)""",
"""            Spacer(Modifier.height(14.dp))
            SectionHead("同批候选", null)""")

rep("""            .then(if (enabled) Modifier.inkClickable { onClick() } else Modifier)
            .padding(vertical = 6.dp),""",
"""            .then(if (enabled) Modifier.inkClickable { onClick() } else Modifier)
            .padding(vertical = 4.dp),""")

io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("patched ok")

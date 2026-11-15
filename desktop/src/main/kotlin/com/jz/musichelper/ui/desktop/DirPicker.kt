package com.jz.musichelper.ui.desktop

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.DesktopWindows
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jz.musichelper.data.AppEnv
import com.jz.musichelper.data.JzLog
import com.jz.musichelper.ui.theme.InkTitleFont
import com.jz.musichelper.ui.theme.LocalPalette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.text.Collator
import java.util.Locale

/**
 * 应用内自绘的「选文件夹」浮层，替代 Swing 的 JFileChooser。
 *
 * 为什么自己画：JFileChooser 在 Windows 上弹的是系统 98 年那套目录框（灰底、无主题、
 * 还带「文件类型」下拉），放在纸墨界面里像另一个软件。这里改成主窗口内的一层浮层
 * （不另开系统窗口 —— 桌面版的历史教训：独立窗口容易触发 AWT 关停 / 收不到鼠标事件），
 * 配色、圆角、字体全部取自 [LocalPalette]。
 *
 * 交互：左栏常用位置/磁盘，中间面包屑 + 文件夹列表（单击进入），底部路径可直接编辑（回车跳转），
 * 「新建文件夹」就地起名，Esc 关闭，主按钮把当前文件夹作为下载目录。
 */
object DirPicker {

    var open by mutableStateOf(false)
        private set

    /** 当前所在的文件夹（列表里展示的是它的子文件夹） */
    var current by mutableStateOf(File(""))
        private set

    /** 底部路径框的内容；与 [current] 分开，用户改到一半不作数 */
    var pathDraft by mutableStateOf("")

    /** 底部红字提示（路径无效 / 无权限 / 整盘不能作目录） */
    var pathError by mutableStateOf<String?>(null)

    var creating by mutableStateOf(false)
    var newName by mutableStateOf("")

    /** 列表刷新信号：新建文件夹后即使 current 不变也要重读 */
    var revision by mutableStateOf(0)
        private set

    private var onPick: (File) -> Unit = {}

    fun request(from: File, pick: (File) -> Unit) {
        val start = when {
            from.isDirectory -> from
            from.parentFile?.isDirectory == true -> from.parentFile!!
            else -> File(System.getProperty("user.home") ?: "C:\\")
        }
        onPick = pick
        current = start
        pathDraft = start.absolutePath
        pathError = null
        creating = false
        newName = ""
        open = true
        JzLog.i("JZ_DIR", "picker open at ${start.absolutePath}")
    }

    fun close() {
        open = false
        creating = false
        newName = ""
    }

    fun navigate(dir: File) {
        val target = dir.absoluteFile
        if (!target.isDirectory) {
            pathError = "找不到这个文件夹"
            return
        }
        current = target
        pathDraft = target.absolutePath
        pathError = null
        creating = false
        newName = ""
        revision++
    }

    fun refresh() {
        revision++
    }

    /** 路径框回车：跳到手输的路径 */
    fun submitPath() {
        val text = pathDraft.trim()
        if (text.isEmpty()) return
        val dir = File(text)
        if (dir.isDirectory) navigate(dir) else pathError = "这个路径不是一个文件夹"
    }

    /**
     * 回车键的唯一入口（由 Main.kt 的窗口级 onPreviewKeyEvent 转进来）。
     *
     * 桌面版实测：没有输入框焦点时，回车能到窗口预览；一旦光标在输入框里，
     * 回车会被输入法/文本组件先吃掉（连窗口预览都收不到），那种情况走输入框自己的
     * IME Done 回调。两条路都收口到这一处，保证"回车"不会没反应。
     */
    fun enterPressed() {
        if (creating) createFolder() else submitPath()
    }

    fun goUp() {
        current.parentFile?.let { navigate(it) }
    }

    /** 整盘根目录当下载目录会把歌直接丢进 D:\，[AppEnv.downloadDir] 也会忽略这种值 */
    fun canConfirm(): Boolean = current.isDirectory && current.parentFile != null

    fun confirm() {
        val dir = current
        if (!dir.isDirectory) {
            pathError = "请先选一个存在的文件夹"
            return
        }
        if (dir.parentFile == null) {
            pathError = "整块磁盘不能直接当作下载目录，请进去选一个文件夹"
            return
        }
        val cb = onPick
        open = false
        creating = false
        JzLog.i("JZ_DIR", "picked ${dir.absolutePath}")
        cb(dir)
    }

    /** 就地新建：重名自动加 (2)(3)，建完直接进去 */
    fun createFolder() {
        val base = newName.trim().ifBlank { "新建文件夹" }
        val safe = base.map { if (it in "\\/:*?\"<>|\r\n\t") '_' else it }
            .joinToString("")
            .trimEnd('.', ' ')
        if (safe.isBlank()) {
            pathError = "文件夹名称无效"
            return
        }
        var target = File(current, safe)
        var i = 2
        while (target.exists() && i <= 99) {
            target = File(current, "$safe ($i)")
            i++
        }
        val ok = runCatching { target.mkdirs() || target.isDirectory }.getOrDefault(false)
        if (!ok) {
            pathError = "新建失败：这个位置可能没有写入权限"
            return
        }
        JzLog.i("JZ_DIR", "mkdir ${target.absolutePath}")
        creating = false
        newName = ""
        navigate(target)
    }

    /** Esc：先收掉"新建文件夹"，再关整个浮层 */
    fun escape() {
        if (creating) {
            creating = false
            newName = ""
        } else {
            close()
        }
    }
}

// ============================================================================================
// 视觉常量：全部从纸墨色板派生，不引入另一套配色
// ============================================================================================

private val PickerScrim = Color(0x8A262018)
private val CardTop = Color(0xFFFDFBF4)
private val CardBottom = Color(0xFFF4EEDF)
private val RailBg = Color(0xFFF7F2E6)
private val SelectedBg = Color(0xFFFCF7EA)
private val ListFade = Color(0xFFF9F4E8)
private val FolderTint = Color(0xFF9C8558)
private val Hairline = Color(0x242E2A24)
private val FieldBg = Color(0xFFFBF8F1)

private val fsv: javax.swing.filechooser.FileSystemView by lazy {
    javax.swing.filechooser.FileSystemView.getFileSystemView()
}

/** 不进列表的目录：系统垃圾目录，点进去也没意义，还会拖慢列目录 */
private val JUNK_DIRS = setOf(
    "\$recycle.bin", "system volume information", "config.msi", "recovery",
    "\$windows.~bt", "\$windows.~ws", "perflogs", "msocache", "documents and settings"
)

private data class DirEntry(val file: File, val hidden: Boolean)

private data class Place(val label: String, val icon: ImageVector, val dir: File)

private fun listDirs(dir: File): Result<List<DirEntry>> = runCatching {
    val all = dir.listFiles() ?: throw IllegalStateException("没有权限读取这个文件夹")
    val collator = Collator.getInstance(Locale.CHINA)
    all.asSequence()
        .filter { runCatching { it.isDirectory }.getOrDefault(false) }
        .filterNot { it.name.lowercase() in JUNK_DIRS }
        .map { DirEntry(it, runCatching { it.isHidden }.getOrDefault(false)) }
        .sortedWith { a, b -> collator.compare(a.file.name, b.file.name) }
        .toList()
}

/** 常用位置：优先 user.home，其次 桌面/文档/音乐 被 OneDrive 接管的情况 */
private fun quickPlaces(): List<Place> {
    val home = File(System.getProperty("user.home") ?: "C:\\")
    val bases = listOf(home, File(home, "OneDrive"))
    fun pick(vararg names: String): File? =
        bases.asSequence().flatMap { b -> names.asSequence().map { File(b, it) } }
            .firstOrNull { runCatching { it.isDirectory }.getOrDefault(false) }

    return buildList {
        pick("Downloads", "下载")?.let { add(Place("下载", Icons.Filled.Download, it)) }
        pick("Music", "音乐")?.let { add(Place("音乐", Icons.Filled.MusicNote, it)) }
        pick("Desktop", "桌面")?.let { add(Place("桌面", Icons.Filled.DesktopWindows, it)) }
        pick("Documents", "文档")?.let { add(Place("文档", Icons.Filled.Description, it)) }
        pick("Pictures", "图片")?.let { add(Place("图片", Icons.Filled.Image, it)) }
        pick("Videos", "视频")?.let { add(Place("视频", Icons.Filled.Movie, it)) }
    }
}

private fun driveLabel(root: File): String =
    runCatching { fsv.getSystemDisplayName(root) }.getOrNull()
        ?.takeIf { it.isNotBlank() }
        ?: root.absolutePath

private fun sameDir(a: File, b: File): Boolean =
    runCatching { a.absolutePath.equals(b.absolutePath, ignoreCase = true) }.getOrDefault(false)

/** 从盘符到当前目录的整条链 */
private fun ancestors(dir: File): List<File> {
    val chain = ArrayList<File>(8)
    var f: File? = dir.absoluteFile
    while (f != null) {
        chain.add(f)
        f = f.parentFile
    }
    chain.reverse()
    return chain
}

// ============================================================================================
// 浮层
// ============================================================================================

@Composable
fun DirPickerOverlay() {
    if (!DirPicker.open) return
    val shape = RoundedCornerShape(18.dp)
    Box(
        Modifier
            .fillMaxSize()
            .background(PickerScrim)
            // 点空白处关闭
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null
            ) { DirPicker.close() },
        contentAlignment = Alignment.Center
    ) {
        Column(
            Modifier
                .padding(26.dp)
                .widthIn(max = 860.dp)
                .heightIn(max = 578.dp)
                .fillMaxWidth()
                .fillMaxHeight()
                .shadow(
                    elevation = 34.dp,
                    shape = shape,
                    ambientColor = Color(0x55201C16),
                    spotColor = Color(0x55201C16)
                )
                .clip(shape)
                .background(Brush.verticalGradient(listOf(CardTop, CardBottom)))
                .border(1.dp, Color(0x3D2E2A24), shape)
                // 吞掉落在卡片上的点击，别让遮罩收到
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null
                ) { }
        ) {
            PickerHeader()
            Divider()
            Row(Modifier.weight(1f).fillMaxWidth()) {
                PickerRail(Modifier.fillMaxHeight().width(188.dp))
                Column(Modifier.weight(1f).fillMaxHeight()) {
                    PickerToolbar()
                    Divider()
                    PickerList(Modifier.weight(1f).fillMaxWidth())
                    Divider()
                    PickerFooter()
                }
            }
        }
    }
}

@Composable
private fun Divider() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Hairline))
}

@Composable
private fun PickerHeader() {
    val p = LocalPalette.current
    Row(
        Modifier.fillMaxWidth().padding(start = 20.dp, end = 14.dp, top = 16.dp, bottom = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 朱砂窄签：与「编辑精选」卡片同一套记号
        Box(Modifier.width(3.dp).height(24.dp).background(p.heartOn, RoundedCornerShape(2.dp)))
        Spacer(Modifier.width(11.dp))
        Column(Modifier.weight(1f)) {
            Text(
                "更改下载位置",
                fontSize = 18.sp,
                color = p.text,
                fontFamily = InkTitleFont,
                fontWeight = FontWeight.SemiBold
            )
            Spacer(Modifier.height(2.dp))
            Text("选一个文件夹，之后下载的歌曲都存到这里", fontSize = 11.sp, color = p.text3)
        }
        CloseButton { DirPicker.close() }
    }
}

@Composable
private fun CloseButton(onClick: () -> Unit) {
    val p = LocalPalette.current
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val bg by animateColorAsState(
        if (hovered) Color(0x142E2A24) else Color.Transparent,
        animationSpec = tween(90),
        label = "closeBg"
    )
    Box(
        Modifier
            .size(30.dp)
            .clip(CircleShape)
            .background(bg)
            .handCursor()
            .clickable(interactionSource = interaction, indication = null) { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Icon(Icons.Filled.Close, "关闭", tint = p.text2, modifier = Modifier.size(16.dp))
    }
}

// ---------------------------------------------------------------- 左栏

@Composable
private fun PickerRail(modifier: Modifier = Modifier) {
    val places = remember { quickPlaces() }
    val drives = remember { runCatching { File.listRoots().toList() }.getOrDefault(emptyList()) }
    val download = AppEnv.downloadDir
    val music = AppEnv.musicDir

    Column(modifier.background(RailBg).verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
        RailLabel("常用位置")
        places.forEach { pl ->
            RailItem(pl.icon, pl.label, sameDir(DirPicker.current, pl.dir)) { DirPicker.navigate(pl.dir) }
        }

        RailLabel("本应用")
        RailItem(Icons.Filled.Folder, "默认位置", sameDir(DirPicker.current, music)) { DirPicker.navigate(music) }
        // 默认位置就是当前下载目录时只留一条，不重复高亮
        if (!sameDir(music, download)) {
            RailItem(Icons.Filled.Folder, "当前下载目录", sameDir(DirPicker.current, download)) { DirPicker.navigate(download) }
        }

        RailLabel("此电脑")
        drives.forEach { root ->
            RailItem(Icons.Filled.Storage, driveLabel(root), sameDir(DirPicker.current, root)) { DirPicker.navigate(root) }
        }
        Spacer(Modifier.height(4.dp))
    }
}

@Composable
private fun RailLabel(text: String) {
    val p = LocalPalette.current
    Text(
        text,
        fontSize = 10.sp,
        color = p.text3,
        letterSpacing = 1.1.sp,
        modifier = Modifier.padding(start = 16.dp, top = 10.dp, bottom = 4.dp)
    )
}

@Composable
private fun RailItem(icon: ImageVector, label: String, selected: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val pressed by interaction.collectIsPressedAsState()
    val bg by animateColorAsState(
        when {
            pressed -> DeskColors.hoverStrong
            selected -> SelectedBg
            hovered -> DeskColors.hover
            else -> Color.Transparent
        },
        animationSpec = tween(90),
        label = "railBg"
    )
    Row(
        Modifier
            .fillMaxWidth()
            .height(34.dp)
            .padding(horizontal = 6.dp)
            .clip(RoundedCornerShape(7.dp))
            .background(bg)
            .handCursor()
            .clickable(interactionSource = interaction, indication = null) { onClick() },
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 选中态：左侧朱砂竖条（不换底色的第二重信号）
        Box(Modifier.width(3.dp).height(16.dp).clip(RoundedCornerShape(2.dp))
            .background(if (selected) p.heartOn else Color.Transparent))
        Spacer(Modifier.width(9.dp))
        Icon(
            icon,
            null,
            tint = if (selected) p.heartOn else p.text3,
            modifier = Modifier.size(15.dp)
        )
        Spacer(Modifier.width(9.dp))
        Text(
            label,
            fontSize = 12.sp,
            color = if (selected) p.text else p.text2,
            fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

// ---------------------------------------------------------------- 面包屑工具条

@Composable
private fun PickerToolbar() {
    val p = LocalPalette.current
    Row(
        Modifier.fillMaxWidth().height(46.dp).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SquareIcon(Icons.Filled.ArrowUpward, "上一级", enabled = DirPicker.current.parentFile != null) {
            DirPicker.goUp()
        }
        Spacer(Modifier.width(4.dp))
        SquareIcon(Icons.Filled.Refresh, "刷新", enabled = true) { DirPicker.refresh() }
        Spacer(Modifier.width(10.dp))
        Breadcrumbs(Modifier.weight(1f))
        Spacer(Modifier.width(8.dp))
        Text("仅显示文件夹", fontSize = 10.5.sp, color = p.text3.copy(alpha = 0.8f))
    }
}

@Composable
private fun SquareIcon(icon: ImageVector, desc: String, enabled: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val bg by animateColorAsState(
        if (hovered && enabled) Color(0x142E2A24) else Color.Transparent,
        animationSpec = tween(90),
        label = "sqBg"
    )
    Box(
        Modifier
            .size(28.dp)
            .clip(RoundedCornerShape(7.dp))
            .background(bg)
            .then(if (enabled) Modifier.handCursor().clickable(interactionSource = interaction, indication = null) { onClick() } else Modifier),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            icon,
            desc,
            tint = if (enabled) p.text2 else p.text3.copy(alpha = 0.35f),
            modifier = Modifier.size(15.dp)
        )
    }
}

@Composable
private fun Breadcrumbs(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val chain = remember(DirPicker.current) { ancestors(DirPicker.current) }
    // 太深只留"盘符 … 最后两级"，剩下靠底部路径框看全貌，避免面包屑把工具条撑爆
    val shown: List<File?> = if (chain.size <= 3) chain else listOf(chain.first(), null, chain[chain.size - 2], chain.last())

    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        shown.forEachIndexed { index, crumb ->
            if (index > 0) {
                Text("›", fontSize = 12.sp, color = p.text3.copy(alpha = 0.55f), modifier = Modifier.padding(horizontal = 5.dp))
            }
            if (crumb == null) {
                Text("…", fontSize = 12.sp, color = p.text3, modifier = Modifier.padding(horizontal = 2.dp))
            } else {
                val isLast = index == shown.lastIndex
                val label = if (crumb.parentFile == null) {
                    crumb.absolutePath.removeSuffix("\\").removeSuffix("/").ifBlank { crumb.absolutePath }
                } else {
                    crumb.name
                }
                Text(
                    label,
                    fontSize = 12.sp,
                    color = if (isLast) p.text else p.text2,
                    fontWeight = if (isLast) FontWeight.Medium else FontWeight.Normal,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .widthIn(max = 150.dp)
                        .clip(RoundedCornerShape(5.dp))
                        .then(if (isLast) Modifier else Modifier.handCursor().clickable { DirPicker.navigate(crumb) })
                        .padding(horizontal = 4.dp, vertical = 3.dp)
                )
            }
        }
    }
}

// ---------------------------------------------------------------- 文件夹列表

@Composable
private fun PickerList(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    var entries by remember { mutableStateOf<List<DirEntry>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }

    LaunchedEffect(DirPicker.current, DirPicker.revision) {
        loading = true
        error = null
        val dir = DirPicker.current
        val result = withContext(Dispatchers.IO) { listDirs(dir) }
        result
            .onSuccess { entries = it }
            .onFailure {
                entries = emptyList()
                error = it.message ?: "读取这个文件夹失败"
            }
        loading = false
    }

    Box(modifier.padding(horizontal = 8.dp, vertical = 6.dp)) {
        when {
            loading -> CenterHint("正在读取…")
            error != null -> CenterHint("⚠ $error", Color(0xFF9A4A24))
            entries.isEmpty() && !DirPicker.creating -> EmptyFolderHint()
            else -> {
                LazyColumn(Modifier.fillMaxSize()) {
                    if (DirPicker.creating) {
                        item { NewFolderRow() }
                    }
                    items(entries, key = { it.file.absolutePath }) { entry ->
                        FolderRow(entry)
                    }
                }
                // 底部渐隐：列表能滚时最后一行不会被生硬切断
                Box(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .height(18.dp)
                        .background(Brush.verticalGradient(listOf(Color.Transparent, ListFade)))
                )
            }
        }
    }
}

@Composable
private fun EmptyFolderHint() {
    val p = LocalPalette.current
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            // 淡墨空文件夹：既不空荡，也不抢字
            Icon(
                Icons.Filled.Folder,
                null,
                tint = p.heartOn.copy(alpha = 0.09f),
                modifier = Modifier.size(86.dp)
            )
            Spacer(Modifier.height(10.dp))
            Text("这里没有子文件夹", fontSize = 12.5.sp, color = p.text2)
            Spacer(Modifier.height(5.dp))
            Text("可以直接点「下载到这里」", fontSize = 11.sp, color = p.text3)
        }
    }
}

@Composable
private fun CenterHint(text: String, color: Color? = null) {
    val p = LocalPalette.current
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, fontSize = 12.sp, color = color ?: p.text3, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun FolderRow(entry: DirEntry) {
    val p = LocalPalette.current
    HoverRow(
        modifier = Modifier.fillMaxWidth().height(36.dp),
        onClick = { DirPicker.navigate(entry.file) }
    ) { hovered ->
        Row(
            Modifier.fillMaxSize().padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Filled.Folder,
                null,
                tint = if (hovered) p.heartOn else FolderTint,
                modifier = Modifier.size(16.dp)
            )
            Spacer(Modifier.width(10.dp))
            Text(
                entry.file.name,
                fontSize = 12.5.sp,
                color = if (entry.hidden) p.text2.copy(alpha = 0.72f) else p.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            Icon(
                Icons.Filled.ChevronRight,
                null,
                tint = if (hovered) p.heartOn else p.text3.copy(alpha = 0.45f),
                modifier = Modifier.size(14.dp)
            )
        }
    }
}

@Composable
private fun NewFolderRow() {
    val p = LocalPalette.current
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }

    Row(
        Modifier
            .fillMaxWidth()
            .height(36.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(Color(0x0F2E2A24))
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(Icons.Filled.CreateNewFolder, null, tint = p.heartOn, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(10.dp))
        BasicTextField(
            value = DirPicker.newName,
            onValueChange = { DirPicker.newName = it },
            singleLine = true,
            textStyle = TextStyle(fontSize = 12.5.sp, color = p.text),
            cursorBrush = SolidColor(p.heartOn),
            // 输入框有焦点时回车被输入法吃掉（窗口级预览收不到），走 IME Done 才是可靠路径
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { DirPicker.createFolder() }),
            modifier = Modifier
                .weight(1f)
                .focusRequester(focus),
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (DirPicker.newName.isEmpty()) {
                        Text("文件夹名称", fontSize = 12.5.sp, color = p.text3.copy(alpha = 0.7f))
                    }
                    inner()
                }
            }
        )
        Spacer(Modifier.width(8.dp))
        Text(
            "创建",
            fontSize = 12.sp,
            color = p.heartOn,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.handCursor().clickable { DirPicker.createFolder() }
                .padding(horizontal = 6.dp, vertical = 4.dp)
        )
        Text(
            "取消",
            fontSize = 12.sp,
            color = p.text3,
            modifier = Modifier.handCursor().clickable { DirPicker.creating = false; DirPicker.newName = "" }
                .padding(horizontal = 6.dp, vertical = 4.dp)
        )
    }
}

// ---------------------------------------------------------------- 底部

@Composable
private fun PickerFooter() {
    val p = LocalPalette.current
    val canPick = DirPicker.canConfirm()
    Column(Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 12.dp, bottom = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            PathField(Modifier.weight(1f))
            Spacer(Modifier.width(10.dp))
            InkButton("新建文件夹", primary = false) {
                DirPicker.creating = true
                DirPicker.newName = ""
            }
            Spacer(Modifier.width(8.dp))
            InkButton("取消", primary = false) { DirPicker.close() }
            Spacer(Modifier.width(8.dp))
            InkButton("下载到这里", primary = true, enabled = canPick) { DirPicker.confirm() }
        }
        Spacer(Modifier.height(7.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            val error = DirPicker.pathError
            Text(
                when {
                    error != null -> error
                    !canPick -> "这是整块磁盘的根目录，请进入其中一个文件夹再选"
                    else -> "将保存到：" + DirPicker.current.absolutePath
                },
                fontSize = 10.5.sp,
                color = if (error != null || !canPick) Color(0xFF9A4A24) else p.text3,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            Text("Esc 关闭", fontSize = 10.5.sp, color = p.text3.copy(alpha = 0.8f))
        }
    }
}

@Composable
private fun PathField(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val bad = DirPicker.pathError != null
    Row(
        modifier
            .height(34.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(FieldBg)
            .border(1.dp, if (bad) p.heartOn.copy(alpha = 0.65f) else DeskColors.inkSoft, RoundedCornerShape(9.dp)),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            "路径",
            fontSize = 10.sp,
            color = p.text3,
            modifier = Modifier.padding(start = 11.dp, end = 9.dp)
        )
        BasicTextField(
            value = DirPicker.pathDraft,
            onValueChange = {
                DirPicker.pathDraft = it
                DirPicker.pathError = null
            },
            singleLine = true,
            textStyle = TextStyle(fontSize = 12.sp, color = p.text),
            cursorBrush = SolidColor(p.heartOn),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { DirPicker.submitPath() }),
            modifier = Modifier.weight(1f)
        )
        Spacer(Modifier.width(6.dp))
        Text(
            "前往",
            fontSize = 11.sp,
            color = p.accent2,
            modifier = Modifier.handCursor().clickable { DirPicker.submitPath() }
                .padding(horizontal = 8.dp, vertical = 4.dp)
        )
    }
}

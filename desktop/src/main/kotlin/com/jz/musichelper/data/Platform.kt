package com.jz.musichelper.data

import org.json.JSONObject
import java.awt.GraphicsEnvironment
import java.awt.Toolkit
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Windows 桌面运行环境：路径、偏好、屏幕尺寸。
 *
 * Android 侧对应的是 `Context`（filesDir / cacheDir / getSharedPreferences / resources.displayMetrics），
 * 桌面版把这些收拢到这一个对象里，业务代码只跟它打交道。
 *
 * 两种目录布局，由「能不能找到 jpackage 安装根」自动决定：
 *
 * ① **安装版**（安装器装出来的 `JZ Music\JZ Music.exe`，且目录可写）——数据全在安装目录里：
 *  - `<安装目录>\Download\`   下载的音乐（默认下载目录）
 *  - `<安装目录>\Log\`        desktop.log / play.log / crash.log
 *  - `<安装目录>\Cache\`      播放缓存 / 预取缓存 / 下载临时文件（可随时清）
 *  - `<安装目录>\Data\`       prefs_*.json（收藏 / 历史 / 下载记录 / 设置）
 *  - `<安装目录>\Backup\`     数据备份
 *
 * ② **开发模式 / 装到只读位置**——退回旧布局：
 *  - `%APPDATA%\JZ Music\`            配置根（cache / files 子目录）
 *  - `<项目根>\logs` 或 `<应用目录>\logs`  日志
 *  - `%USERPROFILE%\Music\JZ Music\`  下载成品
 */
object AppEnv {

    // ---------------- 安装根（jpackage app-image） ----------------

    /** jpackage 打出来的安装根目录（里面有 `JZ Music.exe`）；开发模式下为 null */
    val installDir: File? by lazy { detectInstallRoot() }

    /**
     * 「绿色安装」布局：数据就放在安装目录里（Download / Log / Cache / Data / Backup）。
     * 拷走整个文件夹就能搬机，卸载时删文件夹即可。
     *
     * 装到 Program Files 这类只读位置时自动退回旧布局，不会因为建不了目录把应用带崩。
     */
    val portable: Boolean by lazy {
        val root = installDir ?: return@lazy false
        canWrite(root)
    }

    private fun canWrite(dir: File): Boolean = runCatching {
        val probe = File(dir, ".jz-write-probe")
        probe.writeText("ok")
        probe.delete()
        true
    }.getOrDefault(false)

    /**
     * 找安装根，按可靠性依次尝试：
     *  1. `jpackage.app-path`（jpackage 启动器自己写的，就是 `<安装根>\JZ Music.exe`）；
     *  2. `java.home` 正好是 `<安装根>\runtime`（自带 JRE）；
     *  3. 代码位置在 `<安装根>\app\` 里。
     *
     * 开发模式（gradle run / IDE）三条都不成立，返回 null 走旧布局。
     */
    private fun detectInstallRoot(): File? {
        fun looksLikeAppImage(dir: File?): Boolean {
            if (dir == null || !dir.isDirectory) return false
            return File(dir, "JZ Music.exe").isFile ||
                (File(dir, "app").isDirectory && File(dir, "runtime").isDirectory)
        }
        System.getProperty("jpackage.app-path")?.takeIf { it.isNotBlank() }?.let {
            val f = File(it).absoluteFile
            val root = if (f.isFile) f.parentFile else f
            if (looksLikeAppImage(root)) return root
        }
        System.getProperty("java.home")?.let {
            val jre = File(it).absoluteFile
            if (jre.name.equals("runtime", ignoreCase = true) && looksLikeAppImage(jre.parentFile)) {
                return jre.parentFile
            }
        }
        runCatching {
            val cs = File(AppEnv::class.java.protectionDomain.codeSource.location.toURI()).absoluteFile
            val dir = if (cs.isFile) cs.parentFile else cs
            if (dir != null && dir.name.equals("app", ignoreCase = true) && looksLikeAppImage(dir.parentFile)) {
                return dir.parentFile
            }
        }
        return null
    }

    // ---------------- 旧布局（开发 / 只读安装） ----------------

    private fun appDataBase(): File {
        val appData = System.getenv("APPDATA")
        return if (!appData.isNullOrBlank()) File(appData)
        else File(System.getProperty("user.home"), "AppData/Roaming")
    }

    /** `%APPDATA%\JZ Music`：旧布局的配置根；安装版只用来做一次性迁移 */
    private val appDataRoot: File by lazy {
        val base = appDataBase()
        val dir = File(base, "JZ Music").apply { mkdirs() }
        // 旧版本叫「JZ音乐助手」：把配置**拷**过来（不 rename——rename 遇到被 Defender/搜索
        // 占用句柄的目录会静默失败，留下两个半截目录更难查）。旧目录原样留着，不影响新版本。
        val legacy = File(base, "JZ音乐助手")
        if (legacy.isDirectory) {
            runCatching {
                legacy.listFiles()?.filter { it.isFile && it.name.startsWith("prefs_") }?.forEach { old ->
                    val target = File(dir, old.name)
                    if (!target.exists()) old.copyTo(target, overwrite = false)
                }
            }
        }
        dir
    }

    val dataDir: File by lazy {
        val dir = if (portable) File(installDir!!, "Data") else appDataRoot
        dir.mkdirs()
        if (portable) adoptLegacyData(dir)
        dir
    }

    val cacheDir: File by lazy {
        (if (portable) File(installDir!!, "Cache") else File(dataDir, "cache")).apply { mkdirs() }
    }

    val filesDir: File by lazy { File(dataDir, "files").apply { mkdirs() } }

    /** 旧日志目录（升级前放在 C 盘的那个），只用于一次性迁移，不再往里写 */
    val legacyLogDir: File get() = File(dataDir, "files")

    /**
     * 安装版第一次启动：把旧 `%APPDATA%\JZ Music`（以及更早的「JZ音乐助手」）里的
     * `prefs_*.json` 拷进 `Data\`，老用户升级过来收藏/历史/下载记录都还在。
     *
     * 只拷不删。`download_dir` 如果指向被换掉的旧默认目录（音乐\JZ Music）或是
     * `D:\` 这种磁盘根目录（早先测试留下的脏值），顺手清掉，让新的「安装目录\Download」生效。
     */
    private fun adoptLegacyData(target: File) {
        val marker = File(target, ".migrated-from-appdata")
        if (marker.exists()) return
        runCatching {
            listOf("JZ Music", "JZ音乐助手").forEach { name ->
                val src = File(appDataBase(), name)
                if (!src.isDirectory) return@forEach
                src.listFiles()?.filter { it.isFile && it.name.startsWith("prefs_") }?.forEach { old ->
                    val dest = File(target, old.name)
                    if (!dest.exists()) runCatching { old.copyTo(dest, overwrite = false) }
                }
            }
            runCatching {
                val f = File(target, "prefs_jz_music_prefs.json")
                if (f.isFile) {
                    val p = Prefs(f)
                    val custom = p.getString("download_dir", null)
                    if (custom != null && shouldDropDownloadDir(File(custom))) {
                        p.edit().remove("download_dir").apply()
                    }
                }
            }
            target.mkdirs()
            marker.writeText("migrated " + Date())
        }.onFailure { println("JZ AppEnv: adopt legacy data failed: $it") }
    }

    /** 老配置里可能存着「D:\」这类无效下载目录（当年测试留下的），迁过来只会把歌丢进根目录 */
    private fun shouldDropDownloadDir(dir: File): Boolean {
        val abs = dir.absoluteFile
        return isDriveRoot(abs) || abs.path.equals(legacyMusicDir.absolutePath, true)
    }

    private fun isDriveRoot(f: File): Boolean {
        val p = f.absolutePath.trimEnd('\\', '/')
        return p.length == 2 && p[1] == ':'
    }

    /** 旧版默认下载目录：`音乐\JZ Music`（安装版不再往这里写，只用于迁移与兜底） */
    private val legacyMusicDir: File by lazy {
        val home = File(System.getProperty("user.home"))
        val m = File(home, "Music")
        File(if (m.isDirectory) m else home, "JZ Music")
    }

    /**
     * 日志目录：
     *  - 安装版 → `<安装目录>\Log`（desktop.log / play.log / crash.log）
     *  - 开发模式 → 项目根 `<项目根>\logs`，不再往 C 盘写
     *
     * 下面这段是开发模式的解析顺序（命中即用）：
     *  1. `JZ_LOG_DIR` 环境变量 / `-Djz.log.dir=`（相对路径相对当前工作目录）；
     *  2. 从"启动位置"向上找项目根：便携启动器传进来的 `--launch-dir`（它自己所在的目录）
     *     → 代码所在目录 → 当前工作目录；
     *     项目根的判定：目录里同时能看到 `tools/build-desktop.ps1` / `desktop/build.gradle.kts` / `.git`；
     *  3. 都找不到（比如被拷到别的机器上单独运行）→ 退到应用所在目录下的 `logs`。
     *
     * 目录不可写时再退到旧的 `files/`，保证日志不会因为路径问题把应用带崩。
     */
    val logsDir: File by lazy {
        (if (portable) File(installDir!!, "Log") else resolveLogsDir()).apply { mkdirs() }
    }

    private fun looksLikeProjectRoot(dir: File): Boolean =
        File(dir, "tools/build-desktop.ps1").exists() ||
            File(dir, "desktop/build.gradle.kts").exists() ||
            File(dir, ".git").exists()

    private fun resolveLogsDir(): File {
        val explicit = System.getenv("JZ_LOG_DIR")?.takeIf { it.isNotBlank() }
            ?: System.getProperty("jz.log.dir")?.takeIf { it.isNotBlank() }
        if (explicit != null) {
            val f = File(explicit)
            val abs = if (f.isAbsolute) f else File(System.getProperty("user.dir"), explicit)
            return usable(abs.absoluteFile) ?: abs.absoluteFile
        }
        val starts = buildList {
            System.getProperty("jz.launch.dir")?.takeIf { it.isNotBlank() }?.let { add(File(it)) }
            System.getenv("JZ_LAUNCH_DIR")?.takeIf { it.isNotBlank() }?.let { add(File(it)) }
            runCatching {
                File(AppEnv::class.java.protectionDomain.codeSource.location.toURI())
            }.getOrNull()?.let { add(it) }
            System.getProperty("user.dir")?.takeIf { it.isNotBlank() }?.let { add(File(it)) }
        }
        for (start in starts) {
            var d: File? = start.absoluteFile
            var guard = 0
            while (d != null && guard++ < 16) {
                if (looksLikeProjectRoot(d)) {
                    usable(File(d, "logs"))?.let { return it }
                    break
                }
                d = d.parentFile
            }
        }
        // 兜底：应用（jar/exe）所在目录下的 logs
        val appDir = runCatching {
            File(AppEnv::class.java.protectionDomain.codeSource.location.toURI()).let { f ->
                if (f.isFile) f.parentFile else f
            }
        }.getOrNull() ?: File(System.getProperty("user.dir"))
        usable(File(appDir, "logs"))?.let { return it }
        // 实在写不了才回到旧位置
        return File(filesDir, "logs").apply { mkdirs() }
    }

    /** 试写一次，能写就把目录建好返回 */
    private fun usable(dir: File): File? = runCatching {
        dir.mkdirs()
        val probe = File(dir, ".write-test")
        probe.writeText("ok")
        probe.delete()
        dir
    }.getOrNull()

    /**
     * 默认下载目录：
     *  - 安装版 → `<安装目录>\Download`（用户要的：下载的音乐自动落在这个文件夹里）
     *  - 旧布局 → `音乐\JZ Music`（跟随系统「音乐」文件夹）
     */
    val musicDir: File by lazy {
        if (portable) {
            File(installDir!!, "Download").apply { mkdirs() }
        } else {
            val dir = legacyMusicDir
            // 旧下载目录里的歌拷过来，避免升级后"下载列表有、文件没了"
            val legacy = File(dir.parentFile, "JZ音乐助手")
            if (legacy.isDirectory && dir.listFiles().isNullOrEmpty()) {
                runCatching {
                    legacy.listFiles()?.filter { it.isFile }?.forEach { old ->
                        val target = File(dir, old.name)
                        if (!target.exists()) old.copyTo(target, overwrite = false)
                    }
                }
            }
            dir.apply { mkdirs() }
        }
    }

    /** 备份目录：安装版在安装目录下的 `Backup\`，旧布局在配置目录下 */
    val backupDir: File by lazy {
        (if (portable) File(installDir!!, "Backup") else File(dataDir, "Backup")).apply { mkdirs() }
    }

    /** 下载目录：默认见 [musicDir]，设置页可改到任意目录（存在偏好里） */
    // Compose 能观察的版本：改目录后下载页/设置页会立刻刷新，而不是等到下次进页面
    private val downloadDirRevision = androidx.compose.runtime.mutableIntStateOf(0)

    val downloadDir: File
        get() {
            // 订阅这个 revision：读一次即建立依赖，setDownloadDir 时 +1 触发重组
            downloadDirRevision.intValue
            val custom = prefs("jz_music_prefs").getString("download_dir", null)
            if (!custom.isNullOrBlank()) {
                val d = File(custom)
                // 磁盘根目录当下载目录一定是脏数据（会把歌直接丢进 D:\），忽略它
                if (d.isAbsolute && !isDriveRoot(d)) return d.apply { mkdirs() }
            }
            return musicDir
        }

    fun setDownloadDir(dir: File) {
        prefs("jz_music_prefs").edit().putString("download_dir", dir.absolutePath).apply()
        dir.mkdirs()
        downloadDirRevision.intValue = downloadDirRevision.intValue + 1
        JzLog.i("JZ_DLM", "downloadDir -> ${dir.absolutePath}")
    }

    fun resetDownloadDir() {
        prefs("jz_music_prefs").edit().remove("download_dir").apply()
        downloadDirRevision.intValue = downloadDirRevision.intValue + 1
    }

    /**
     * 启动时把该有的目录都建出来（安装器已经建过一次，这里兜底）：
     * Download / Log / Cache / Data / Backup。
     */
    fun ensureLayout() {
        runCatching {
            dataDir
            cacheDir
            logsDir
            backupDir
            musicDir
            downloadDir.mkdirs()
        }
    }

    /** 启动日志里打一行，排障时一眼看出这次用的是哪种布局 */
    fun layoutText(): String = buildString {
        append(if (portable) "install(portable)" else "user-profile")
        append(" root=").append(installDir?.absolutePath ?: "-")
        append(" data=").append(dataDir.absolutePath)
        append(" download=").append(downloadDir.absolutePath)
    }

    private val prefsCache = java.util.concurrent.ConcurrentHashMap<String, Prefs>()

    /** 同名多次调用返回同一个实例（与 SharedPreferences 语义一致） */
    fun prefs(name: String): Prefs = prefsCache.getOrPut(name) { Prefs(File(dataDir, "prefs_$name.json")) }

    /** 系统「移除动画」等价物：桌面版按 Windows 的精简动画设置判断，取不到就当 false */
    val reduceMotion: Boolean by lazy {
        runCatching {
            val desktop = Toolkit.getDefaultToolkit().getDesktopProperty("win.animation.enabled")
            desktop == false
        }.getOrDefault(false)
    }

    /** 主屏逻辑尺寸（用于桌面歌词栏定位/吸边，与密度无关） */
    val screenWidth: Int by lazy {
        runCatching { GraphicsEnvironment.getLocalGraphicsEnvironment().maximumWindowBounds.width }
            .getOrDefault(1920)
    }

    val screenHeight: Int by lazy {
        runCatching { GraphicsEnvironment.getLocalGraphicsEnvironment().maximumWindowBounds.height }
            .getOrDefault(1080)
    }

    val screenBounds: java.awt.Rectangle by lazy {
        runCatching { GraphicsEnvironment.getLocalGraphicsEnvironment().maximumWindowBounds }
            .getOrDefault(java.awt.Rectangle(0, 0, 1920, 1080))
    }

    /** 资源管理器里打开某个目录（设置页「打开缓存/下载目录」用） */
    fun openDir(dir: File) {
        runCatching {
            dir.mkdirs()
            java.awt.Desktop.getDesktop().open(dir)
        }.onFailure { JzLog.w("JZ", "open dir failed: ${dir.absolutePath} $it") }
    }
}

/**
 * SharedPreferences 的桌面替身：一个 JSON 文件 + 内存镜像，写入即落盘。
 * 只实现业务用到的那些方法（getString / getInt / getBoolean / getFloat / getLong、edit().putXxx()、remove）。
 */
class Prefs(private val file: File) {

    private val map = java.util.concurrent.ConcurrentHashMap<String, Any>()

    init {
        runCatching {
            if (file.exists()) {
                val o = JSONObject(file.readText())
                o.keys().forEach { k ->
                    when (val v = o.get(k)) {
                        is Boolean -> map[k] = v
                        is Int -> map[k] = v
                        is Long -> map[k] = v
                        is Double -> map[k] = v.toFloat()
                        is String -> map[k] = v
                    }
                }
            }
        }
    }

    @Synchronized
    fun getString(key: String, def: String?): String? = map[key] as? String ?: def

    @Synchronized
    fun getInt(key: String, def: Int): Int = (map[key] as? Number)?.toInt() ?: def

    @Synchronized
    fun getLong(key: String, def: Long): Long = (map[key] as? Number)?.toLong() ?: def

    @Synchronized
    fun getFloat(key: String, def: Float): Float = (map[key] as? Number)?.toFloat() ?: def

    @Synchronized
    fun getBoolean(key: String, def: Boolean): Boolean = map[key] as? Boolean ?: def

    @Synchronized
    fun contains(key: String): Boolean = map.containsKey(key)

    fun edit(): Editor = Editor()

    inner class Editor {
        private val puts = LinkedHashMap<String, Any>()
        private val removes = mutableListOf<String>()

        fun putString(key: String, value: String?): Editor = apply { if (value == null) removes += key else puts[key] = value }
        fun putInt(key: String, value: Int): Editor = apply { puts[key] = value }
        fun putLong(key: String, value: Long): Editor = apply { puts[key] = value }
        fun putFloat(key: String, value: Float): Editor = apply { puts[key] = value }
        fun putBoolean(key: String, value: Boolean): Editor = apply { puts[key] = value }
        fun remove(key: String): Editor = apply { removes += key }

        fun apply() { commit() }

        @Synchronized
        fun commit() {
            removes.forEach { map.remove(it) }
            map.putAll(puts)
            persist()
        }
    }

    @Synchronized
    private fun persist() {
        runCatching {
            val o = JSONObject()
            map.forEach { (k, v) -> o.put(k, v) }
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(o.toString())
            if (file.exists()) file.delete()
            if (!tmp.renameTo(file)) {
                tmp.copyTo(file, overwrite = true)
                tmp.delete()
            }
        }
    }
}

/**
 * 在 UI 线程（AWT EDT）上执行；已经在 EDT 上就同步执行。
 *
 * Compose 的 Snapshot 状态（mutableStateOf / SnapshotStateList）**只能**在 UI 线程改，
 * 后台线程直接改会触发 Unsupported concurrent change during composition 并整个进程退出——
 * 下载进度这类高频后台写入必须经过这里。
 */
fun onUiThread(block: () -> Unit) {
    if (javax.swing.SwingUtilities.isEventDispatchThread()) block()
    else javax.swing.SwingUtilities.invokeLater { block() }
}

/** android.util.Log 的替身：只打控制台，不写文件 */
object JzLog {
    private val fmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    @Volatile var enabled = true

    // 打包后的 exe 没有控制台：日志同时写一份到 <项目根>/logs/desktop.log（排障用，超 400KB 滚动）
    private val logFile: File? by lazy {
        runCatching {
            File(AppEnv.logsDir, "desktop.log").also { f ->
                if (f.exists() && f.length() > 400_000L) {
                    f.writeText(f.readLines().takeLast(600).joinToString("\n") + "\n")
                }
            }
        }.getOrNull()
    }

    private fun write(level: String, tag: String, msg: String) {
        if (!enabled) return
        val line = "${fmt.format(Date())} $level/$tag: $msg"
        println(line)
        runCatching { logFile?.appendText(line + "\n") }
    }

    fun i(tag: String, msg: String) = write("I", tag, msg)
    fun w(tag: String, msg: String) = write("W", tag, msg)
    fun e(tag: String, msg: String, t: Throwable? = null) {
        if (!enabled) return
        write("E", tag, msg)
        t?.let { ex ->
            val sw = java.io.StringWriter()
            ex.printStackTrace(java.io.PrintWriter(sw))
            runCatching { logFile?.appendText(sw.toString() + "\n") }
            println(sw.toString())
        }
    }
}

import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("jvm") version "2.1.0"
    id("org.jetbrains.compose") version "1.7.3"
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.0"
}

group = "com.jz.musichelper"
version = "2.1.95"

repositories {
    mavenCentral()
    google()
    maven("https://maven.pkg.jetbrains.space/public/p/compose/dev")
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.8.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.json:json:20240303")

    // 音频：javacv 的 FFmpegFrameGrabber 统一解 mp3/flac/m4a/ogg/wav（Android MediaPlayer 的桌面替代）
    implementation("org.bytedeco:javacv:1.5.12") {
        // 只要 ffmpeg，不要 opencv / openblas / 其它大件
        exclude(group = "org.bytedeco", module = "opencv")
        exclude(group = "org.bytedeco", module = "opencv-platform")
        exclude(group = "org.bytedeco", module = "openblas")
        exclude(group = "org.bytedeco", module = "openblas-platform")
        exclude(group = "org.bytedeco", module = "flycapture")
        exclude(group = "org.bytedeco", module = "flycapture-platform")
        exclude(group = "org.bytedeco", module = "libdc1394")
        exclude(group = "org.bytedeco", module = "libdc1394-platform")
        exclude(group = "org.bytedeco", module = "libfreenect")
        exclude(group = "org.bytedeco", module = "libfreenect-platform")
        exclude(group = "org.bytedeco", module = "libfreenect2")
        exclude(group = "org.bytedeco", module = "libfreenect2-platform")
        exclude(group = "org.bytedeco", module = "librealsense")
        exclude(group = "org.bytedeco", module = "librealsense-platform")
        exclude(group = "org.bytedeco", module = "videoinput")
        exclude(group = "org.bytedeco", module = "videoinput-platform")
        exclude(group = "org.bytedeco", module = "artoolkitplus")
        exclude(group = "org.bytedeco", module = "artoolkitplus-platform")
        exclude(group = "org.bytedeco", module = "leptonica")
        exclude(group = "org.bytedeco", module = "leptonica-platform")
        exclude(group = "org.bytedeco", module = "tesseract")
        exclude(group = "org.bytedeco", module = "tesseract-platform")
        exclude(group = "org.bytedeco", module = "flandmark")
        exclude(group = "org.bytedeco", module = "flandmark-platform")
    }
    implementation("org.bytedeco:javacpp:1.5.12")
    implementation("org.bytedeco:javacpp:1.5.12:windows-x86_64")
    implementation("org.bytedeco:ffmpeg:7.1.1-1.5.12")
    implementation("org.bytedeco:ffmpeg:7.1.1-1.5.12:windows-x86_64")
}

kotlin {
    jvmToolchain(17)
    compilerOptions {
        freeCompilerArgs.add("-Xjvm-default=all")
    }
}

compose.desktop {
    application {
        mainClass = "com.jz.musichelper.MainKt"

        // 诊断用：反射 sun.awt.AWTAutoShutdown（JZ_PEER_TRACE=1 时才实际启用）
        jvmArgs += listOf(
            "--add-opens=java.desktop/sun.awt=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.awt.windows=ALL-UNNAMED"
        )


        nativeDistributions {
            targetFormats(TargetFormat.Exe, TargetFormat.AppImage)
            packageName = "JZ Music"
            packageVersion = "2.1.95"
            description = "JZ Music（Windows 桌面版）"
            vendor = "JZ"
            windows {
                menu = true
                shortcut = true
                dirChooser = true
                perUserInstall = true
                upgradeUuid = "7c4f2f5e-2f3a-4a2f-9f18-1a6a2f2c9b71"
                iconFile.set(project.file("icons/app.ico"))
            }
        }
    }
}

// 诊断入口（不打进界面、不进分发包）：gradle debugRun -Pargs="search 周深"
tasks.register<JavaExec>("debugRun") {
    group = "verification"
    description = "跑 DebugKt：search / lyrics / probe"
    classpath = sourceSets["main"].runtimeClasspath
    mainClass.set("com.jz.musichelper.DebugKt")
    val raw = (project.findProperty("args") as String?) ?: ""
    // 既支持 "search 周深"，也支持用分号分隔带空格的参数："song;Red Bean|方大同|QQ|id|专辑|240"
    args(
        (if (raw.contains(";")) raw.split(";") else raw.split(" "))
            .map { it.trim() }
            .filter { it.isNotBlank() }
    )
    standardInput = System.`in`
}
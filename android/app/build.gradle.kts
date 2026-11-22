plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.jz.musichelper"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.jz.musichelper"
        minSdk = 26
        targetSdk = 34
        versionCode = 259
        versionName = "2.4.81"
    }

    buildTypes {
        // 本机调试：MainActivity 里那段「测试注入入口」用的是编译期常量 BuildConfig.RECOG_TEST_HOOK，
        // release / smoke 都定义了，唯独 debug 没定义 → assembleDebug 会报 Unresolved reference。
        // 这里补上（false，正式行为），让 assembleDebug 也能直接用。
        debug {
            buildConfigField("boolean", "RECOG_TEST_HOOK", "false")
        }
        release {
            isMinifyEnabled = false
            // 用 debug 签名：保证发布产物可直接安装（个人分发场景），且 release 体积远小于 debug
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // v2.1.93：测试注入入口不进正式包（编译期常量，MainActivity 里那段会被折叠掉）
            buildConfigField("boolean", "RECOG_TEST_HOOK", "false")
        }
        // v2.1.93 冒烟包：与 release 同源同签，只多一个「用 assets 里的固定 PCM 走识曲」的入口，
        // 让模拟器在没有真实声源的情况下也能跑通「识别 → 双通道打分 → 结果卡」。
        // 产物：app/build/outputs/apk/smoke/app-smoke.apk（不发布，只给冒烟脚本用）
        create("smoke") {
            initWith(getByName("release"))
            buildConfigField("boolean", "RECOG_TEST_HOOK", "true")
            matchingFallbacks += listOf("release")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.09.03"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.animation:animation")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("io.coil-kt:coil-compose:2.7.0")
}


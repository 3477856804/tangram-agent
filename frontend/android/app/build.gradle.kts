import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// OTA 固定签名：keystore.properties 只含非敏感项(storeFile/keyAlias)，
// 口令一律来自 CI Secret 环境变量 STORE_PASSWORD / KEY_PASSWORD
// (兼容 TANGRAM_KEYSTORE_* 命名)。密钥绝不入仓库。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("keystore.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}
fun otaSecret(propKey: String, vararg envKeys: String): String? {
    for (k in envKeys) {
        val v = System.getenv(k)
        if (!v.isNullOrEmpty()) return v
    }
    return keystoreProperties.getProperty(propKey)
}

// 版本单一真源：仓库根 VERSION（harness/version.py 校验的产品版本）。
// android/version.properties 只作为「CI 发版递增」的覆盖值：CI 写入非零
// major/minor/patch 时以它为准（保证 Play/OTA versionCode 单调递增），
// 否则回退到 VERSION。此前 version.properties 初始化为全 0，导致
// versionCode=0 被 AGP 直接判为非法，全新 checkout 无法出 release 包。
val versionProps = Properties()
val versionPropsFile = rootProject.file("version.properties")
if (versionPropsFile.exists()) {
    FileInputStream(versionPropsFile).use { versionProps.load(it) }
}
val pMajor = (versionProps.getProperty("major") ?: "0").trim().toInt()
val pMinor = (versionProps.getProperty("minor") ?: "0").trim().toInt()
val pPatch = (versionProps.getProperty("patch") ?: "0").trim().toInt()
val pBuild = (versionProps.getProperty("build") ?: "0").trim().toInt()

val repoVersionText = rootProject.file("../../VERSION")
    .takeIf { it.isFile }?.readText()?.trim().orEmpty()
val repoParts = repoVersionText.split(".")
val rMajor = repoParts.getOrNull(0)?.toIntOrNull() ?: 0
val rMinor = repoParts.getOrNull(1)?.toIntOrNull() ?: 0
val rPatch = repoParts.getOrNull(2)?.toIntOrNull() ?: 0

val propsInitialized = (pMajor + pMinor + pPatch) > 0
val vMajor = if (propsInitialized) pMajor else rMajor
val vMinor = if (propsInitialized) pMinor else rMinor
val vPatch = if (propsInitialized) pPatch else rPatch
val vBuild = pBuild
val vName = if (propsInitialized) {
    when {
        vPatch == 0 -> "$vMajor.$vMinor.0"
        vMinor == 0 -> "$vMajor.$vMinor.$vPatch"
        else -> String.format("%d.%d.%02d", vMajor, vMinor, vPatch)
    }
} else {
    repoVersionText.ifEmpty { "$vMajor.$vMinor.$vPatch" }
}
// versionCode 必须是正整数：全 0 的旧配置会让 assembleRelease 直接失败。
val vCode = maxOf(vMajor * 10_000_000 + vMinor * 100_000 + vPatch * 1_000 + vBuild, 1)

val ksPathValue = otaSecret("storeFile", "TANGRAM_KEYSTORE_PATH")
val ksPwdValue = otaSecret("storePassword", "STORE_PASSWORD", "TANGRAM_KEYSTORE_PASSWORD")
val ksAliasValue = otaSecret("keyAlias", "TANGRAM_KEY_ALIAS")
val ksKeyPwdValue = otaSecret("keyPassword", "KEY_PASSWORD", "TANGRAM_KEY_PASSWORD")
val hasReleaseSigning = ksPathValue != null && ksPwdValue != null &&
    ksAliasValue != null && ksKeyPwdValue != null

android {
    namespace = "com.tangram.agent.tangram"
    compileSdk = 36 // tangram:compile-sdk-app
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.tangram.agent.tangram"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // 沙箱终端「Debian 用户态（proot）」依赖：Android 10+ 对 targetSdk≥29
        // 的应用禁止 exec 私有目录里的文件（SELinux app_data_file noexec）。
        // 本 App 走自有 OTA 分发、不上 Google Play，故按 Termux 同款方案
        // 固定 targetSdk=28，使运行时下载/解包的 proot + rootfs 可执行。
        // 若改回 flutter.targetSdkVersion，安卓本地 apt 链路将不可用
        // （沙箱终端会如实报错并引导用「远端沙箱（SSH）」）。
        targetSdk = 28
        versionCode = vCode
        versionName = vName
        // 通用包：arm64-v8a（主流真机 + 端侧 llama.cpp 原生库）与 armeabi-v7a
        // （老设备，核心功能可用；端侧 GGUF 推理仅在 arm64 提供预编译库）。
        // x86/x86_64 不纳入：llamadart 无对应 Android 预编译库，只会在构建期
        // 触发联网下载或直接失败。
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    signingConfigs {
        // 固定 release keystore（OTA 覆盖安装的前提：新旧 APK 必须同签名）。
        // CI 从 Secret 还原 jks 并生成 keystore.properties（仅非敏感项），
        // 口令经 STORE_PASSWORD / KEY_PASSWORD 环境变量注入。
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(ksPathValue!!)
                storePassword = ksPwdValue!!
                keyAlias = ksAliasValue!!
                keyPassword = ksKeyPwdValue!!
            }
        }
    }

    buildTypes {
        release {
            // 有完整签名材料 → 固定 release keystore；没有 → 回退 debug 签名
            // （本地 `flutter run --release` 仍可用；CI 发布必须配齐 Secret）。
            val releaseSigning = signingConfigs.findByName("release")
            signingConfig = releaseSigning ?: signingConfigs.getByName("debug")
        }
    }

    lint {
        // 本 App 走自有 OTA 分发、不上 Google Play；targetSdk=28 是沙箱
        // proot 用户态可执行的硬前提，禁用「targetSdk 过期」这条 Play 专用 lint。
        disable += "ExpiredTargetSdkVersion"
        // release 构建不跑 lintVital：AGP 自带的 lint 在解析依赖里的 JavaDoc
        // 时会抛 NoSuchMethodError（JavaDocParser.parseDataItem）直接把构建打断，
        // 与被检代码无关。静态检查由 `flutter analyze` + 单测承担。
        checkReleaseBuilds = false
        abortOnError = false
    }
}

// 发布防呆：assembleRelease 缺口令直接失败，不产出 debug 签名包混入发布。
tasks.matching { it.name == "assembleRelease" }.configureEach {
    doFirst {
        if (!hasReleaseSigning) {
            throw GradleException(
                "release 签名缺少 STORE_PASSWORD / KEY_PASSWORD（CI Secret）——" +
                    "发布构建必须配置 ANDROID_KEYSTORE_BASE64 / STORE_PASSWORD / KEY_PASSWORD"
            )
        }
    }
}

dependencies {
    // MainActivity 的 installApk 用 androidx.core FileProvider 生成 content:// URI。
    implementation("androidx.core:core-ktx:1.13.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

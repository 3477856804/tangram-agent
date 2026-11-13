allprojects {
    repositories {
        // 国内镜像优先，境外官方仓库作 fallback（与 settings.gradle.kts 对齐）。
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

// Flutter 3.50 的 flutter.compileSdkVersion = 36，且 flutter_plugin_android_lifecycle
// 2.0.35 的 AAR 元数据要求所有依赖方 compileSdk >= 36。部分第三方插件
// （file_picker 8.3.7 / share_plus 10.1.4 / sign_in_with_apple 6.1.4）仍在各自
// build.gradle 写死 compileSdk 34，会在 checkReleaseAarMetadata 阶段冲突。
// 用 afterEvaluate 在插件脚本执行完之后统一把 compileSdk 抬到 36（plugins.withId
// 太早、会被脚本里的 compileSdk 34 覆盖回去）。注册必须在下方
// evaluationDependsOn 之前，否则 Gradle 9 会报「项目已评估」。用反射兼容
// newDsl=false 的 BaseExtension 与新 DSL 的 LibraryExtension，不改 pub cache，
// 可随仓库复现。
subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        val setters = listOf(
            // 旧 DSL（BaseExtension，newDsl=false）
            runCatching { androidExt.javaClass.getMethod("compileSdkVersion", Integer.TYPE) }.getOrNull(),
            runCatching { androidExt.javaClass.getMethod("setCompileSdkVersion", Integer.TYPE) }.getOrNull(),
            // 新 DSL（LibraryExtension）
            runCatching { androidExt.javaClass.getMethod("setCompileSdk", Integer::class.java) }.getOrNull(),
        ).filterNotNull()
        for (m in setters) {
            try {
                m.invoke(androidExt, 36)
                break
            } catch (_: Exception) {
                // 尝试下一个候选 setter
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

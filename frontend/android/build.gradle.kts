// tangram:compile-sdk-plugins (generated)
// 统一所有 Flutter 插件子模块的 compileSdk：部分老插件把 compileSdk 写死为 34，
// 与 flutter_plugin_android_lifecycle(36) 的 AAR metadata 要求冲突。
// 反射同时覆盖旧 DSL (BaseExtension) 与新 DSL (CommonExtension)。
gradle.beforeProject(org.gradle.api.Action<org.gradle.api.Project> {
    afterEvaluate(org.gradle.api.Action<org.gradle.api.Project> {
        val androidExt = extensions.findByName("android")
        if (androidExt != null) {
            val cls = androidExt.javaClass
            for (sig in listOf(
                "setCompileSdk|int",
                "setCompileSdk|java.lang.Integer",
                "compileSdkVersion|int",
                "compileSdkVersion|java.lang.Integer",
                "setCompileSdkVersion|int"
            )) {
                val parts = sig.split("|")
                val param: Class<*> =
                    if (parts[1] == "int") java.lang.Integer.TYPE
                    else java.lang.Integer::class.java
                try {
                    cls.getMethod(parts[0], param).invoke(androidExt, 36)
                } catch (_: Throwable) {
                }
            }
        }
    })
})

allprojects {
    repositories {
        // tangram:build-mirrors (generated, 官方源优先,国内镜像兜底)
        google()
        mavenCentral()
        gradlePluginPortal()
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
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
// tangram:build-mirrors
